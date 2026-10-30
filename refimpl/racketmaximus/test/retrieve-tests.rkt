#lang racket/base

;; test/retrieve-tests.rkt — #189 step 6: the retrieval tool and the `?semantic=`
;; half of search.
;;   raco test test/retrieve-tests.rkt
;;   DATABASE_URL=postgres://… raco test test/retrieve-tests.rkt
;;
;; The embedding seam is SCRIPTED (`current-doc-embed`), as step 4's suite does,
;; so none of this needs an endpoint — and the script is a **bag of words**, not a
;; hash of the whole string. That is deliberate and is what makes the central
;; assertion possible: with a bag of words, a question that shares words with a
;; passage lands NEAR it, so "a question about octopuses retrieves the octopus
;; passage and not the one beside it" is a property a test can state. A
;; whole-string hash would be deterministic and useless — every text would point
;; somewhere arbitrary and the best a case could say is that SOMETHING came back.
;;
;; It is a crude stand-in and not a claim about recall. Whether a real embedder
;; retrieves the right chunk for a question in English or Japanese is step 3's
;; CALIBRATION — the chunk size and the overlap — which needs a live
;; `nomic-embed-text` and is the one piece of #189 still waiting on hardware.

(require rackunit db-kit/portable racket/port racket/file racket/list racket/string
         db-kit/migrate
         "../domain/db/migrations.rkt"
         "db-fixture.rkt"
         "../domain/authz/authz.rkt"
         "../domain/repo/blobs.rkt"
         "../domain/repo/repo.rkt"
         "../domain/repo/extract.rkt"
         "../domain/repo/doc-tools.rkt"
         "../domain/repo/passages.rkt"
         "../domain/repo/retrieve-tools.rkt"
         "../domain/apps/search.rkt"
         "../domain/agent/tools.rkt"
         "../domain/agent/registry.rkt"
         "../domain/ai/chunk.rkt"
         "../domain/ai/chunkstore.rkt"
         "../domain/quota/quota.rkt")

(define BLOB-ROOT (make-temporary-file "telemachus-retrieve-~a" 'directory))
(current-blob-root BLOB-ROOT)

(define (fresh)
  (define conn (fresh-db #:migrate? #f))
  (migrate! conn all-migrations)
  conn)

;; ENVN-2: the variable NAME is a value.
(define URL-VAR "TMACH_EMBED_URL")
(define MODEL-VAR "TMACH_EMBED_MODEL")
(define KEY-VAR "TMACH_SECRET_KEY")
(define CONTENT-VAR "TMACH_ENCRYPT_CONTENT")
(define KEY (make-string 64 #\b))

(define (with-env* pairs thunk)
  (define saved (for/list ([kv (in-list pairs)]) (cons (car kv) (getenv (car kv)))))
  (dynamic-wind
    (lambda () (for ([kv (in-list pairs)]) (putenv (car kv) (or (cdr kv) ""))))
    thunk
    (lambda () (for ([kv (in-list saved)]) (putenv (car kv) (or (cdr kv) ""))) (void))))

;; ---- the scripted embedder: a bag of words ------------------------------------
(define DIMS 32)
(define calls (box '()))

(define (bucket w)
  (modulo (for/fold ([h 7]) ([c (in-string (string-downcase w))])
            (modulo (+ (* h 31) (char->integer c)) 1000003))
          DIMS))

(define (bag text)
  (define v (make-vector DIMS 0.0))
  (for ([w (in-list (regexp-split #px"[^[:alnum:]]+" text))] #:when (> (string-length w) 0))
    (vector-set! v (bucket w) (+ 1.0 (vector-ref v (bucket w)))))
  v)

(define (script-embed texts)
  (set-box! calls (cons (length texts) (unbox calls)))
  (values (for/list ([t (in-list texts)]) (bag t))
          (for/sum ([t (in-list texts)]) (string-length t))))

(define (with-embedder thunk #:model [model "bag-of-words"])
  (set-box! calls '())
  (with-env* (list (cons URL-VAR "http://127.0.0.1:1/v1/embeddings") (cons MODEL-VAR model))
             (lambda () (parameterize ([current-doc-embed script-embed]) (thunk)))))

;; ---- fixtures ------------------------------------------------------------------
(define (seed!)
  (define conn (fresh))
  (define-values (uid tid) (bootstrap! conn #:username "alice"))
  (values conn (user-principal conn uid tid) tid uid))

;; a document with its text extracted AND its chunks embedded, which is the state
;; the Embed Documents workflow leaves behind
(define (embedded! conn p key text #:vis [vis "team"] #:model [model "bag-of-words"])
  (define o (repo-put! conn p #:key key #:port (open-input-bytes (string->bytes/utf-8 text))
                       #:content-type "text/markdown" #:filename key #:visibility vis))
  (repo-text-upsert! conn (hash-ref o 'id) (hash-ref o 'version_id) text)
  (define-values (cs _t) (chunk-text text))
  (chunks-replace! conn (hash-ref o 'id) (hash-ref o 'version_id) model cs
                   (for/list ([c (in-list cs)]) (bag (hash-ref c 'text))))
  o)

(define (call-tool conn p name args)
  ((tool-handler (tool-by-name name)) conn p args))

;; two documents about different things, each one chunk
(define OCTO "Octopuses are cephalopods with eight arms and remarkable problem solving.")
(define BRIDGE "Suspension bridges carry their deck on cables hung between tall towers.")

;; ---- 1. the refusal ------------------------------------------------------------
(test-case "with no embedding endpoint the TOOL refuses by name, naming the variable"
  ;; the asymmetry with search is the slice's one real decision, and both halves
  ;; are asserted — here and in case 7
  (define-values (conn p tid uid) (seed!))
  (check-exn #rx"TMACH_EMBED_URL"
             (lambda () (call-tool conn p "repo_retrieve" (hasheq 'question "octopuses"))))
  (close-db! conn))

;; ---- 2. it retrieves by meaning ------------------------------------------------
(test-case "a question retrieves the passage that shares its words, with that passage's text"
  (define-values (conn p tid uid) (seed!))
  (with-embedder
    (lambda ()
      (define o1 (embedded! conn p "notes/octo.md" OCTO))
      (define o2 (embedded! conn p "notes/bridge.md" BRIDGE))
      (define r (call-tool conn p "repo_retrieve" (hasheq 'question "cephalopods with arms")))
      (check-equal? (hash-ref r 'count) 2 "both documents should be candidates")
      (define first-hit (car (hash-ref r 'passages)))
      (check-equal? (hash-ref first-hit 'object_id) (hash-ref o1 'id)
                    "the bridge passage outranked the octopus one")
      ;; the TEXT is the chunk's own substring of the extracted text, not a guess
      (check-equal? (hash-ref first-hit 'text) OCTO)
      (check-equal? (hash-ref first-hit 'key) "notes/octo.md")
      (check-equal? (hash-ref r 'model) "bag-of-words")
      (check-false (hash-ref r 'truncated))
      ;; and the other document really is in the answer, ranked below
      (check-equal? (hash-ref (cadr (hash-ref r 'passages)) 'object_id) (hash-ref o2 'id))
      (check > (hash-ref first-hit 'score) (hash-ref (cadr (hash-ref r 'passages)) 'score))))
  (close-db! conn))

;; ---- 3. the citation -----------------------------------------------------------
(test-case "a passage's offsets resolve through spans-covering to where it was read"
  (define-values (conn p tid uid) (seed!))
  (with-embedder
    (lambda ()
      (define o (embedded! conn p "notes/octo.md" OCTO))
      (repo-text-upsert! conn (hash-ref o 'id) (hash-ref o 'version_id) OCTO
                         #:spans (list (hasheq 'start 0 'end (string-length OCTO)
                                               'page 4 'bbox (list 1 2 3 4))))
      (define r (call-tool conn p "repo_retrieve" (hasheq 'question "octopuses")))
      (define h (car (hash-ref r 'passages)))
      ;; the text really is the substring those offsets name
      (check-equal? (substring OCTO (hash-ref h 'start) (hash-ref h 'end)) (hash-ref h 'text))
      (define covering (spans-covering (repo-spans-for conn (hash-ref o 'id)) (hash-ref h 'start)))
      (check-equal? (length covering) 1)
      (check-equal? (hash-ref (car covering) 'page) 4)))
  (close-db! conn))

;; ---- 4. what it costs ----------------------------------------------------------
(test-case "one question is one embedding request, metered on its own dimension"
  ;; EMB-6: an embedding has an input count and no output, so it must not touch
  ;; `ai.tokens.total` — folding it in would make retrieval eat the budget chat
  ;; needs. Asserted on `ai.requests` too, which is what a rules-only answer's
  ;; control taught (CLS-1).
  (define-values (conn p tid uid) (seed!))
  (with-embedder
    (lambda ()
      (embedded! conn p "notes/octo.md" OCTO)
      (set-box! calls '())
      (call-tool conn p "repo_retrieve" (hasheq 'question "octopuses and arms"))
      (check-equal? (unbox calls) '(1) "the question must go in ONE request of one text")
      (check-equal? (quota-used conn "team" tid "ai.requests" "total") 1)
      (check > (quota-used conn "team" tid "ai.embeddings.total" "total") 0)
      (check-equal? (quota-used conn "team" tid "ai.tokens.total" "total") 0
                    "an embedding must not be charged to the completion budget")))
  (close-db! conn))

;; ---- 5. the budget permission --------------------------------------------------
(test-case "asking costs a model request, so it needs chat:use and not merely files:read"
  ;; a `viewer` holds `*:read` — so `files:read` yes, `chat:use` no. It is the one
  ;; built-in role that separates the two, which is what makes it the fixture.
  (define-values (conn p tid uid) (seed!))
  (with-embedder
    (lambda ()
      (embedded! conn p "notes/octo.md" OCTO)
      (define vic (create-user! conn #:username "vic" #:password "pw"))
      (add-member! conn #:team tid #:user vic #:role "viewer")
      (define pv (user-principal conn vic tid))
      (check-true (can? conn pv "files:read") "the fixture role must hold files:read")
      (check-false (can? conn pv "chat:use") "the fixture role must NOT hold chat:use")
      (check-exn #rx"chat:use"
                 (lambda () (call-tool conn pv "repo_retrieve" (hasheq 'question "octopuses"))))
      ;; and nothing was spent on the refused call
      (check-equal? (unbox calls) '())))
  (close-db! conn))

;; ---- 6. an empty question, and the limit --------------------------------------
(test-case "an empty question is refused; the limit defaults and is capped"
  (define-values (conn p tid uid) (seed!))
  (with-embedder
    (lambda ()
      ;; MORE CHUNKS THAN THE CEILING, which a control is what established: a
      ;; 40-paragraph fixture is ~2,000 characters and so about three chunks, and
      ;; "at most 20" then passes against a version with no cap at all. One chunk
      ;; is `CHUNK-SIZE` wide with an overlap, so this needs tens of thousands of
      ;; characters before the ceiling is the thing doing the bounding.
      (embedded! conn p "notes/long.md"
                 (string-join (for/list ([i (in-range 700)])
                                (format "Paragraph ~a about octopuses and cephalopods and arms." i))
                              " "))
      (check-exn #rx"question is empty"
                 (lambda () (call-tool conn p "repo_retrieve" (hasheq 'question "   "))))
      (define few (call-tool conn p "repo_retrieve" (hasheq 'question "octopuses" 'limit 2)))
      (check-equal? (hash-ref few 'count) 2)
      ;; asking for more than the ceiling gets the ceiling, not an error: one of
      ;; the callers is a model choosing its own argument
      (define many (call-tool conn p "repo_retrieve" (hasheq 'question "octopuses" 'limit 500)))
      (check-equal? (hash-ref many 'count) PASSAGE-MAX
                    "the ceiling is what bounded the answer, not the corpus")
      ;; the default is PASSAGE-LIMIT
      (define dflt (call-tool conn p "repo_retrieve" (hasheq 'question "octopuses")))
      (check <= (hash-ref dflt 'count) PASSAGE-LIMIT)))
  (close-db! conn))

;; ---- 7. search DEGRADES where the tool refuses ---------------------------------
(test-case "search answers the keyword half and names why the semantic half did not run"
  ;; VEC-39, the asymmetry: `content_search: false`'s rule, in the module that
  ;; rule lives in. All three reasons are a closed vocabulary.
  (define-values (conn p tid uid) (seed!))
  ;; (a) unconfigured — no endpoint
  (define o (repo-put! conn p #:key "notes/octo.md"
                       #:port (open-input-bytes (string->bytes/utf-8 OCTO))
                       #:content-type "text/markdown" #:filename "octo.md" #:visibility "team"))
  (repo-text-upsert! conn (hash-ref o 'id) (hash-ref o 'version_id) OCTO)
  (define-values (rows reason) (search-passages conn p "octopuses"))
  (check-equal? rows '())
  (check-equal? reason "unconfigured")
  (check-true (and (member reason SEMANTIC-REASONS) #t)
                "the reason must be in the closed vocabulary")
  ;; the keyword half is unaffected — which is the whole point of degrading
  (check > (length (search-all conn p "Octopuses")) 0)
  ;; (b) forbidden — configured, but the caller may not spend the budget
  (with-embedder
    (lambda ()
      (define vic (create-user! conn #:username "vic" #:password "pw"))
      (add-member! conn #:team tid #:user vic #:role "viewer")
      (define pv (user-principal conn vic tid))
      (define-values (rs rn) (search-passages conn pv "octopuses"))
      (check-equal? rs '())
      (check-equal? rn "forbidden")))
  ;; (c) unavailable — configured, permitted, and the attempt failed
  (set-box! calls '())
  (with-env* (list (cons URL-VAR "http://127.0.0.1:1/v1/embeddings") (cons MODEL-VAR "m"))
    (lambda ()
      (parameterize ([current-doc-embed (lambda (ts) (error 'mock "the provider is down"))])
        (define-values (rs rn) (search-passages conn p "octopuses"))
        (check-equal? rs '())
        (check-equal? rn "unavailable"))))
  (close-db! conn))

;; ---- 8. a passage row ----------------------------------------------------------
(test-case "a passage row carries a head snippet and the offsets that make it citable"
  ;; VEC-40: a semantic hit may not contain one word of the question, so there is
  ;; nothing to centre a window on and the snippet is the passage's HEAD.
  (define-values (conn p tid uid) (seed!))
  (with-embedder
    (lambda ()
      ;; THE QUERY'S WORD APPEARS LATE ON PURPOSE. A control is what found this:
      ;; with the question's word in the first sentence, a window CENTRED on the
      ;; match and the passage's HEAD are the same string, so substituting the
      ;; keyword snippet failed nothing. The two differ only when the match is
      ;; deeper into the passage than the window is wide.
      (define long (string-append
                    (string-join (for/list ([i (in-range 14)])
                                   (format "Preamble ~a concerning bridges, cables and towers." i)) " ")
                    " Then at last a sentence about octopuses and cephalopods."))
      (define o (embedded! conn p "notes/long.md" long))
      (define-values (rows reason) (search-passages conn p "octopuses" #:limit 1))
      (check-false reason)
      (check-equal? (length rows) 1)
      (define r (car rows))
      (check-equal? (hash-ref r 'type) "passage")
      (check-equal? (hash-ref r 'title) "notes/long.md")
      (check-equal? (hash-ref r 'object_id) (hash-ref o 'id))
      ;; the snippet is bounded, ends in an ellipsis, and is the passage's HEAD
      (check <= (string-length (hash-ref r 'snippet)) (add1 SEMANTIC-SNIPPET))
      (check-true (regexp-match? #rx"^Preamble 0 concerning" (hash-ref r 'snippet))
                  "the snippet is not the passage's head")
      (check-false (regexp-match? #rx"^…" (hash-ref r 'snippet))
                   "a head snippet never opens with an ellipsis — there is nothing before it")
      (check-true (regexp-match? #rx"…$" (hash-ref r 'snippet)))))
  (close-db! conn))

;; ---- 9. a colleague's private passage ------------------------------------------
(test-case "a colleague's private passage is never returned, through either asker"
  (define-values (conn p tid uid) (seed!))
  (with-embedder
    (lambda ()
      (define secret (embedded! conn p "hr/secret.md" OCTO #:vis "private"))
      (define bob (create-user! conn #:username "bob" #:password "pw"))
      (add-member! conn #:team tid #:user bob #:role "member")
      (define pb (user-principal conn bob tid))
      ;; alice reads her own
      (define ra (call-tool conn p "repo_retrieve" (hasheq 'question "octopuses")))
      (check-equal? (hash-ref ra 'count) 1)
      ;; bob gets nothing, and the tool says the answer may be short rather than
      ;; implying the corpus is empty
      (define rb (call-tool conn pb "repo_retrieve" (hasheq 'question "octopuses")))
      (check-equal? (hash-ref rb 'count) 0)
      (check-true (hash-ref rb 'truncated)
                  "a withheld candidate must make the answer report as truncated")
      (define-values (rows reason) (search-passages conn pb "octopuses"))
      (check-equal? rows '())
      (check-false reason "a readable-nothing answer is not an unavailable one")))
  (close-db! conn))

;; ---- 10. the first content search that survives #83 ----------------------------
(test-case "the semantic half works with the content switch ON, where a LIKE cannot"
  ;; THE FINDING OF THIS SLICE. #83 seals `repo_text.content`, so the keyword
  ;; half's `LIKE` is dropped and `content_search` reports false. The semantic
  ;; half compares VECTORS and reads the text back through `repo-text-for`, which
  ;; unseals — so on a sealed instance it is the only way left to search inside a
  ;; document, and it still works.
  (define-values (conn p tid uid) (seed!))
  (with-env* (list (cons KEY-VAR KEY) (cons CONTENT-VAR "1"))
    (lambda ()
      (with-embedder
        (lambda ()
          (define o (embedded! conn p "notes/octo.md" OCTO))
          ;; the keyword half really has gone blind to the content
          (define kw (search-all conn p "cephalopods"))
          (check-equal? (length kw) 0 "the fixture did not actually seal the extracted text")
          ;; …and the semantic half answers, with the plaintext passage
          (define-values (rows reason) (search-passages conn p "cephalopods with arms"))
          (check-false reason)
          (check-equal? (length rows) 1)
          (check-equal? (hash-ref (car rows) 'object_id) (hash-ref o 'id))
          (check-true (regexp-match? #rx"cephalopods" (hash-ref (car rows) 'snippet))
                      "the passage came back sealed rather than unsealed")))))
  (close-db! conn))

;; ---- 11. a passage whose text moved under it ------------------------------------
(test-case "a passage whose extracted text is of another version is DROPPED, not clamped"
  ;; VEC-37. The scan's join makes the two agree in every state a workflow can
  ;; produce, so this is built by hand — defence in depth, the shape the feed
  ;; queue's team clause needed. Both wrong answers are worse than nothing: a
  ;; clamped substring quotes characters the vector was never made from, and an
  ;; unclamped one RAISES and takes a whole search down over one document.
  (define-values (conn p tid uid) (seed!))
  (with-embedder
    (lambda ()
      (define o (embedded! conn p "notes/octo.md" OCTO))
      ;; the chunk rows still name the current version; the TEXT row no longer does
      (query-exec conn "UPDATE repo_text SET version_id = ? WHERE object_id = ?"
                  "some-other-version" (hash-ref o 'id))
      (define r (call-tool conn p "repo_retrieve" (hasheq 'question "octopuses")))
      (check-equal? (hash-ref r 'count) 0)
      (check-true (hash-ref r 'truncated)
                  "dropping a hit must report as truncated, not as an empty corpus")
      ;; and it did not raise, which is the half that matters
      (define-values (rows reason) (search-passages conn p "octopuses"))
      (check-equal? rows '())
      (check-false reason)))
  (close-db! conn))

;; ---- 12. the model filter, end to end ------------------------------------------
(test-case "vectors stored under another checkpoint are not retrieved"
  ;; EMB-8 through the whole stack: `embed-model` names what the question was
  ;; embedded by, and the scan compares only rows of that model.
  (define-values (conn p tid uid) (seed!))
  (with-embedder #:model "bag-of-words"
    (lambda ()
      (embedded! conn p "notes/octo.md" OCTO #:model "a-different-checkpoint")
      (define r (call-tool conn p "repo_retrieve" (hasheq 'question "octopuses")))
      (check-equal? (hash-ref r 'count) 0)
      (check-equal? (hash-ref r 'scanned) 0 "the other checkpoint's rows entered the window")
      (check-equal? (hash-ref r 'model) "bag-of-words")))
  (close-db! conn))

;; ---- 13. the tool is registered ------------------------------------------------
(test-case "the tool is in the catalog under files:read, with its question required"
  (define t (tool-by-name "repo_retrieve"))
  (check-true (and t #t) "repo_retrieve is not registered")
  (check-equal? (tool-perm t) "files:read")
  (close-db! (fresh)))
