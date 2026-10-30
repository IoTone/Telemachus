#lang racket/base

;; test/voice-tests.rkt — voice notes (#192 slice 1).
;;   raco test test/voice-tests.rkt
;;   DATABASE_URL=postgres://… raco test test/voice-tests.rkt
;;
;; The transcription seam is SCRIPTED (`current-doc-transcribe`), as every
;; model-backed suite here scripts its own, so none of this needs an endpoint —
;; and it is a THIRD parameter beside the chat and embedding ones, which is what
;; makes "a transcription is not satisfied by a scripted chat" a thing a case can
;; rely on rather than hope for.
;;
;; `multipart-body` and `transcription-text` are tested directly, because they are
;; the two halves of the wire a scripted seam skips: the body a server has to
;; parse, and the answer it sends back. The end-to-end HTTP path is
;; `doc-pipeline-smoke.sh`'s.

(require rackunit db-kit/portable db-kit/migrate
         racket/file racket/list racket/string racket/port json
         "../domain/db/migrations.rkt"
         "db-fixture.rkt"
         "../domain/authz/authz.rkt"
         "../domain/repo/blobs.rkt"
         (only-in "../domain/repo/repo.rkt" repo-put! repo-fields repo-get)
         (only-in "../domain/repo/extract.rkt" repo-text-for EXTRACT-CAP)
         (only-in "../domain/ai/executor.rkt" multipart-body transcription-text)
         (only-in "../domain/quota/quota.rkt" quota-used)
         (only-in "../domain/agent/registry.rkt" tool-by-name tool-perm tool-handler)
         "../domain/repo/voice.rkt"
         "../domain/repo/voice-tools.rkt")

(define BLOB-ROOT (make-temporary-file "telemachus-voice-~a" 'directory))
(current-blob-root BLOB-ROOT)

(define (fresh)
  (define conn (fresh-db #:migrate? #f))
  (migrate! conn all-migrations)
  conn)

;; ENVN-2: the variable NAME is a value, never a literal inside a `getenv`.
(define URL-VAR "TMACH_TRANSCRIBE_URL")
(define MODEL-VAR "TMACH_TRANSCRIBE_MODEL")

(define (with-env* pairs thunk)
  (define saved (for/list ([kv (in-list pairs)]) (cons (car kv) (getenv (car kv)))))
  (dynamic-wind
    (lambda () (for ([kv (in-list pairs)]) (putenv (car kv) (or (cdr kv) ""))))
    thunk
    (lambda () (for ([kv (in-list saved)]) (putenv (car kv) (or (cdr kv) ""))) (void))))

(define (configured thunk #:model [m "whisper-test"])
  (with-env* (list (cons URL-VAR "http://127.0.0.1:1/v1/audio/transcriptions")
                   (cons MODEL-VAR m))
             thunk))

;; ---- the scripted seam ---------------------------------------------------------
(define calls (box '()))
(define (reset!) (set-box! calls '()))

;; The "audio" is UTF-8 text and the transcript is that text — the mock server's
;; own trick, for its reason: a hash would be deterministic and useless, where
;; this lets a case say WHICH recording came back.
(define (script-transcribe #:duration [duration 3.5] #:language [language "en"])
  (lambda (payload ct filename)
    (set-box! calls (cons (hasheq 'bytes (bytes-length payload) 'ct ct 'filename filename) (unbox calls)))
    (values (bytes->string/utf-8 payload #\?) duration language)))

(define (seed!)
  (define conn (fresh))
  (define-values (uid tid) (bootstrap! conn #:username "alice"))
  (values conn (user-principal conn uid tid) tid))

(define (put-audio! conn p key text #:ct [ct "audio/mpeg"])
  (repo-put! conn p #:key key #:port (open-input-bytes (string->bytes/utf-8 text))
             #:content-type ct))

(define (handler-of name) (tool-handler (tool-by-name name)))

(define (transcribe! conn p id #:args [extra (hasheq)] #:seam [seam (script-transcribe)])
  (parameterize ([current-doc-transcribe seam])
    ((handler-of "doc_transcribe") conn p (hash-set extra 'object id))))

(define (untranscribed conn p #:args [args (hasheq)])
  ((handler-of "voice_list_untranscribed") conn p args))

;; =============================================================================

(test-case "1. a voice note's transcript becomes the document's TEXT"
  (configured (lambda ()
    (define-values (conn p tid) (seed!))
    (define o (put-audio! conn p "notes/standup.mp3" "we shipped the feed adapters today"))
    (define id (hash-ref o 'id))
    (reset!)
    (define r (transcribe! conn p id))
    ;; VOICE-9: repo_text, not a derived document — which is what makes search,
    ;; the knowledge graph and ?semantic=1 read it with nothing further to run.
    (check-equal? (repo-text-for conn id) "we shipped the feed adapters today")
    (check-equal? (hash-ref r 'characters) 34)
    (check-false (hash-ref r 'empty))
    (check-equal? (hash-ref r 'language) "en")
    (check-equal? (hash-ref r 'duration) 3.5)
    ;; VOICE-6: the posted filename is derived from the CONTENT TYPE, never from
    ;; the key — a key is somebody else's string and it becomes a multipart header
    (check-equal? (hash-ref (car (unbox calls)) 'filename) "voice-note.mp3")
    (check-equal? (hash-ref (car (unbox calls)) 'ct) "audio/mpeg")
    (close-db! conn))))

(test-case "2. …and the duration, language and model land in LAY-4 attributes"
  (configured (lambda ()
    (define-values (conn p tid) (seed!))
    (define id (hash-ref (put-audio! conn p "notes/a.mp3" "hello") 'id))
    (transcribe! conn p id)
    (define attrs (hash-ref (repo-get conn p id) 'attributes))
    (check-equal? (hash-ref attrs 'voice_language) "en")
    (check-equal? (hash-ref attrs 'voice_duration) "4" "rounded — it is a string attribute")
    (check-equal? (hash-ref attrs 'voice_model) "whisper-test")
    ;; declared additively first, or LAY-4 refuses the write and
    ;; `repo-set-attributes!` answers a STRING rather than raising
    (define keys (for/list ([f (in-list (repo-fields conn tid))]) (hash-ref f 'key)))
    (for ([k (in-list '("voice_duration" "voice_language" "voice_model"))])
      (check-true (and (member k keys) #t) (format "~a is declared" k)))
    ;; a seam that reports NEITHER still writes the model, and writes no empty
    ;; attributes beside it — an attribute that is always "" is one a `?attr=`
    ;; filter can never use
    (define id2 (hash-ref (put-audio! conn p "notes/b.mp3" "hello") 'id))
    (transcribe! conn p id2 #:seam (script-transcribe #:duration #f #:language #f))
    (define a2 (hash-ref (repo-get conn p id2) 'attributes))
    (check-equal? (hash-ref a2 'voice_model) "whisper-test")
    (check-false (hash-ref a2 'voice_duration #f))
    (check-false (hash-ref a2 'voice_language #f))
    (close-db! conn))))

(test-case "3. VOICE-11: it charges ai.transcriptions.total and ai.requests, not tokens"
  (configured (lambda ()
    (define-values (conn p tid) (seed!))
    (define id (hash-ref (put-audio! conn p "notes/a.mp3" "hello") 'id))
    (transcribe! conn p id)
    (check-equal? (quota-used conn "team" tid "ai.transcriptions.total" "total") 1
                  "the unit an operator can reason about is RECORDINGS")
    (check-equal? (quota-used conn "team" tid "ai.requests" "total") 1)
    (check-equal? (quota-used conn "team" tid "ai.tokens.total" "total") 0
                  "a transcription returns no tokens at all, so the completion budget cannot measure it")
    (check-equal? (quota-used conn "team" tid "ai.embeddings.total" "total") 0)
    (close-db! conn))))

(test-case "4. VOICE-13: a document that is not audio is refused BEFORE the wire"
  (configured (lambda ()
    (define-values (conn p tid) (seed!))
    (define id (hash-ref (put-audio! conn p "docs/a.pdf" "%PDF-1.4" #:ct "application/pdf") 'id))
    (reset!)
    (check-exn #px"not audio this build will transcribe"
               (lambda () (transcribe! conn p id)))
    (check-equal? (length (unbox calls)) 0
                  "the request was never spent — a PDF posted to a transcription endpoint comes back naming its internals")
    (check-equal? (quota-used conn "team" tid "ai.requests" "total") 0)
    (close-db! conn))))

(test-case "5. with no endpoint it refuses by NAME, and reads nothing"
  (define-values (conn p tid) (seed!))
  (define id (hash-ref (put-audio! conn p "notes/a.mp3" "hello") 'id))
  (with-env* (list (cons URL-VAR "") (cons MODEL-VAR ""))
    (lambda ()
      (check-exn #px"TMACH_TRANSCRIBE_URL" (lambda () (transcribe! conn p id)))))
  (check-false (repo-text-for conn id) "and nothing was written")
  (close-db! conn))

(test-case "6. VOICE-14: an empty transcript is RECORDED, not raised"
  ;; Silence transcribes to "" and a recording of a quiet room is a legitimate
  ;; voice note. Raising would fail the step, and the next run would list the same
  ;; object and fail again — one silent recording wedging the team's transcription
  ;; for ever, which is `repo_extract_text`'s own rule.
  (configured (lambda ()
    (define-values (conn p tid) (seed!))
    ;; `repo-put!` refuses an EMPTY upload outright, so the fixture is whitespace —
    ;; which is what a recording of a quiet room transcribes to anyway.
    (define id2 (hash-ref (put-audio! conn p "notes/quiet2.mp3" "   ") 'id))
    (define r (transcribe! conn p id2))
    (check-true (hash-ref r 'empty))
    (check-equal? (repo-text-for conn id2) "   " "a row exists, keyed to this version")
    ;; …and it is not offered again
    (check-false (and (member id2 (untranscribed conn p)) #t))
    (close-db! conn))))

(test-case "7. VOICE-12: the lister offers audio with no transcript, and only that"
  (configured (lambda ()
    (define-values (conn p tid) (seed!))
    (define a (hash-ref (put-audio! conn p "notes/a.mp3" "one") 'id))
    (define b (hash-ref (put-audio! conn p "notes/b.ogg" "two" #:ct "audio/ogg") 'id))
    (define pdf (hash-ref (put-audio! conn p "docs/c.pdf" "%PDF" #:ct "application/pdf") 'id))
    (define l1 (untranscribed conn p))
    (check-equal? (length l1) 2)
    (check-false (and (member pdf l1) #t)
                 "`repo_list_unindexed` is for the readable types; this one is for the audio")
    ;; transcribing one takes it off the list, which is what makes a re-run free
    (transcribe! conn p a)
    (define l2 (untranscribed conn p))
    (check-equal? l2 (list b))
    ;; the prefix filter, and the two-statement form that stops a clause and its
    ;; parameter coming apart
    (check-equal? (untranscribed conn p #:args (hasheq 'prefix "notes/")) (list b))
    (check-equal? (untranscribed conn p #:args (hasheq 'prefix "docs/")) '())
    (close-db! conn))))

(test-case "8. a colleague's PRIVATE recording is never offered"
  ;; The shape #189 step 4 found from the other side: a window selected by
  ;; `team_id` alone hands a member what the next step cannot read, and
  ;; `doc_transcribe` then fails the step and the whole run on a permission —
  ;; which reads as a broken transcriber.
  (configured (lambda ()
    (define-values (conn p tid) (seed!))
    (define bob (create-user! conn #:username "bob" #:password "pw"))
    (add-member! conn #:team tid #:user bob #:role "member")
    (define pb (user-principal conn bob tid))
    (repo-put! conn p #:key "notes/secret.mp3" #:port (open-input-bytes #"private")
               #:content-type "audio/mpeg" #:visibility "private")
    (define shared (hash-ref (put-audio! conn p "notes/open.mp3" "shared") 'id))
    (define l (untranscribed conn pb))
    (check-equal? l (list shared) "alice's private recording is invisible to bob")
    (close-db! conn))))

(test-case "9. the transcript is capped at EXTRACT-CAP"
  (configured (lambda ()
    (define-values (conn p tid) (seed!))
    (define long (make-string (+ EXTRACT-CAP 500) #\a))
    (define id (hash-ref (put-audio! conn p "notes/long.mp3" long) 'id))
    (define r (transcribe! conn p id))
    (check-equal? (hash-ref r 'characters) EXTRACT-CAP)
    (check-equal? (string-length (repo-text-for conn id)) EXTRACT-CAP)
    (close-db! conn))))

(test-case "10. the two tools are registered under the permissions they need"
  (check-equal? (tool-perm (tool-by-name "doc_transcribe")) "files:write"
                "it writes the document's text and its attributes")
  (check-equal? (tool-perm (tool-by-name "voice_list_untranscribed")) "files:read"))

;; =============================================================================
;; the wire, which a scripted seam skips

(test-case "11. VOICE-5/6: the closed type list, and the filename it posts under"
  (check-true (audio-type? "audio/mpeg"))
  (check-true (audio-type? "AUDIO/MPEG") "case, and a charset parameter, are normalized")
  (check-true (audio-type? "audio/ogg; codecs=opus"))
  (check-false (audio-type? "audio/vnd.invented") "a closed list, not an `audio/*` prefix match")
  (check-false (audio-type? "video/webm")
               "a screen recording carries pictures this would be discarding silently")
  (check-false (audio-type? "application/pdf"))
  (check-equal? (audio-extension-for "audio/x-wav") "wav"
                "three spellings map to one extension, which is why it is a table")
  (check-equal? (audio-extension-for "audio/wave") "wav")
  (check-equal? (audio-filename-for "audio/mp4") "voice-note.m4a")
  (check-equal? (audio-filename-for "audio/vnd.invented") "voice-note.bin"))

(test-case "12. VOICE-2: the multipart body is well formed, and the boundary is CHECKED"
  (define-values (body ct)
    (multipart-body (list (cons "model" "whisper-1") (cons "response_format" "verbose_json"))
                    (list "file" "voice-note.mp3" "audio/mpeg" #"ID3rubbish")))
  (define s (bytes->string/utf-8 body #\?))
  (define b (cadr (regexp-match #px"boundary=(.+)$" ct)))
  (check-true (string-contains? s (string-append "--" b)) "the boundary appears as a delimiter")
  (check-true (string-contains? s "name=\"model\""))
  (check-true (string-contains? s "name=\"response_format\""))
  (check-true (string-contains? s "filename=\"voice-note.mp3\""))
  (check-true (string-contains? s "Content-Type: audio/mpeg"))
  (check-true (string-contains? s "ID3rubbish"))
  (check-true (string-suffix? s (string-append "--" b "--\r\n")) "and it closes")
  ;; the fields come BEFORE the file, so a server that streams the parse can
  ;; refuse an unknown model without reading a 40 MB body
  (check-true (< (let ([m (regexp-match-positions #px"name=\"model\"" s)]) (caar m))
                 (let ([m (regexp-match-positions #px"filename=" s)]) (caar m))))
  ;; A payload full of boundary-LIKE text still yields exactly three delimiters,
  ;; so nothing in the composition is confused by it.
  ;;
  ;; WHAT THIS CANNOT ESTABLISH IS THE COLLISION CHECK ITSELF, and that is worth
  ;; saying rather than leaving a reader to assume otherwise. `fresh-boundary`
  ;; refuses a boundary that occurs in the payload — the failure it prevents is a
  ;; truncated part, which is not an error but a SHORTER transcript that nothing
  ;; downstream can detect. But the boundary is 64 random bits, so a fixture
  ;; cannot contain one: neutralising the check changes no assertion here, and a
  ;; test that could falsify it would need the generator seeded. VEC-13's
  ;; unpinnable pin — a reason to write the check down, not a reason it is
  ;; redundant, and it costs one scan of bytes already in memory.
  (define-values (b2 ct2)
    (multipart-body (list (cons "model" "m"))
                    (list "file" "a.mp3" "audio/mpeg"
                          #"----TelemachusBoundary0 ----TelemachusBoundaryffff filler")))
  (define bb (cadr (regexp-match #px"boundary=(.+)$" ct2)))
  (check-equal? (length (regexp-match* (regexp (regexp-quote (string-append "--" bb)))
                                       (bytes->string/utf-8 b2 #\?)))
                3 "exactly three delimiters: the field, the file, and the close"))

(test-case "13. VOICE-4: an empty transcript is an answer; a missing `text` is not"
  (check-equal? (transcription-text (hasheq 'text "")) ""
                "silence really does transcribe to empty, and a quiet room is a legitimate note")
  (check-equal? (transcription-text (hasheq 'text "hello" 'duration 1.0)) "hello")
  (check-exn #px"no .text." (lambda () (transcription-text (hasheq 'duration 1.0))))
  (check-exn #px"proxy or a different API" (lambda () (transcription-text (hasheq))))
  (check-exn #px"no .text." (lambda () (transcription-text (hasheq 'text 42)))))
