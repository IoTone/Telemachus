#lang racket/base

;; domain/repo/voice-tools.rkt — voice notes (#192, decisions VOICE‑8…14).
;;
;; #192 asks for four things: a built-in tool for voice notes, a way to upload
;; offline ones, an API for streamed capture, and a pipeline that transcribes and
;; then lets you converse with the result. This module is the first, the fourth,
;; and the half of the second that was not already true.
;;
;; WHAT WAS ALREADY TRUE, which is most of it (VOICE‑8). Uploading an offline
;; voice note is `PUT /api/repo/<key>` with `Content-Type: audio/…` — the
;; repository takes any format in and gives it back byte-identical, and
;; `web-kit/http1`'s data plane is what moves it. So requirement 2 needed no
;; code; what it needed was for the thing to be worth uploading, which is the
;; transcript. And once the transcript is in `repo_text`, requirement 4's "a
;; pipeline to converse with data" is already built FOUR TIMES OVER — keyword
;; search covers it, the knowledge graph extracts from it, `?semantic=1` finds it
;; by meaning, and `doc_extract_fields` reads structure out of it. None of that
;; needed a line here.
;;
;; VOICE‑9 — SO THE TRANSCRIPT GOES IN `repo_text`, AND NOT INTO A DERIVED
;; DOCUMENT. `doc_redact` writes `<key>.redacted.txt` because RED‑8's point was
;; that a person must be able to audit what would have been sent; a transcript is
;; not a copy of anything, it is the text OF the recording — which is exactly
;; what `repo_text` is for, and what every one of those four readers already
;; looks at. A second document would double the storage and give search two hits
;; for one recording.
;;
;; VOICE‑10 — IT IS A TOOL, NOT AN EXTRACTOR, AND THE REASON IS METERING.
;; LAY‑7's registry is the obvious home: register `audio/mpeg` and a voice note
;; becomes searchable through the indexing workflow nobody has to change. But an
;; extractor's contract is `(port content-type) -> (values text reason)` — no
;; connection and no principal — and a transcription is a model request against
;; somebody's budget. `chunkstore.rkt` has the same shape for the same reason:
;; the vectors arrive as an argument because the metering can only happen where
;; the principal is. So transcription is a tool beside `doc_text`, and the
;; workflow that drives it is `transcribe-documents`.

(require db-kit/portable racket/string racket/port
         "../tools/dsl.rkt"
         "../agent/registry.rkt"
         "../authz/authz.rkt"
         (only-in "../orgs/orgs.rkt" tenant-quota-record!)
         (only-in "../ai/executor.rkt" transcribe-exchange transcribe-configured? transcribe-model)
         (only-in "repo.rkt" repo-open repo-get repo-readable? repo-fields-declare!
                  repo-set-attributes!)
         (only-in "extract.rkt" repo-text-upsert! EXTRACT-CAP)
         "voice.rkt")

(provide current-doc-transcribe meter-transcribe! VOICE-LIST-BATCH)

;; ---- the seam ----------------------------------------------------------------
;;
;; Its own parameter beside `current-doc-chat` and `current-doc-embed`, for the
;; reason each of those is its own: a transcription model is a third model on a
;; third endpoint, so a test that scripts one of the others says nothing about
;; this one and must not accidentally satisfy it.
;;
;; bytes content-type filename -> (values text duration-or-#f language-or-#f)
(define (default-transcribe payload ct filename)
  (define-values (text duration language _u _m)
    (transcribe-exchange payload #:filename filename #:content-type ct #:who 'doc_transcribe))
  (values text duration language))

(define current-doc-transcribe (make-parameter default-transcribe))

;; VOICE‑11 — `ai.transcriptions.total`, ITS OWN DIMENSION, COUNTING RECORDINGS.
;; EMB‑6's and JUDGE‑10's shape a third time: a cost with no sensible home gets a
;; dimension rather than being folded into somebody else's budget. A transcription
;; returns NO tokens at all — whisper has none to report — so `ai.tokens.total`
;; could not measure it even if it should, and the unit an operator can reason
;; about is recordings ("two hundred voice notes a day"). Seconds of audio was the
;; alternative and is worse: the duration is only known if the endpoint reports
;; it, so the dimension would read 0 for every server that answers plain `json`.
;;
;; `ai.requests` is charged too, exactly as the chat and embedding meters do: the
;; dimension counts calls to a model and this is one.
(define (meter-transcribe! conn p)
  (tenant-quota-record! conn p "ai.requests" 1)
  (tenant-quota-record! conn p "ai.transcriptions.total" 1))

;; ---- the tools ---------------------------------------------------------------

(define VOICE-LIST-BATCH 20)

(define-tool doc_transcribe
  #:description
  "Transcribe a repository audio document — a voice note — into the search index. Needs TMACH_TRANSCRIBE_URL. The transcript becomes the document's text, so search, the knowledge graph, ?semantic=1 and the field extractor all read it afterwards with nothing further to run. Refuses a document that is not audio by name rather than sending it."
  (object string #:description "The repository object id")
  (language string #:optional #:description "The spoken language as a two-letter code, if it is known; omitted means let the model detect it"))

(define-tool voice_list_untranscribed
  #:description
  "List the team's audio documents that have no transcript yet — the input to a transcription pass. Returns object ids, capped at a batch; run the workflow again to continue. A recording that has already been transcribed is skipped, which is what makes a re-run free."
  (prefix string #:optional #:description "Only documents whose key starts with this (default: every one in the team)"))

;; VOICE‑12 — A LISTER OF ITS OWN, AND `repo_list_unindexed` IS WHY IT IS NEEDED
;; RATHER THAN REUSED. That one lists every document with no text and filters on
;; `extractable?`, which audio is not — so a voice note is invisible to it, which
;; is correct: the indexing workflow would fan out over recordings it cannot read
;; and fail a step on each. This window is the same question narrowed to the
;; types `AUDIO-TYPES` names, and it applies `can?` per row for the reason step 4
;; found the hard way: a window selected by `team_id` alone hands a member a
;; colleague's private document, and the next step then fails the whole run on a
;; permission.
(define (list-untranscribed conn p args)
  (require-perm conn p "files:read")
  (define prefix (let ([v (hash-ref args 'prefix #f)]) (and (string? v) (> (string-length v) 0) v)))
  (define rows
    (if prefix
        (query-rows conn (string-append (untranscribed-sql) "AND o.key LIKE ? " (untranscribed-tail))
                    (principal-team-id p) (string-append prefix "%") VOICE-LIST-BATCH)
        (query-rows conn (string-append (untranscribed-sql) (untranscribed-tail))
                    (principal-team-id p) VOICE-LIST-BATCH)))
  (for/list ([r (in-list rows)]
             #:when (and (audio-type? (vector-ref r 1))
                         (repo-readable? conn p (vector-ref r 0))))
    (vector-ref r 0)))

;; Two statements rather than one with an interpolated clause: a conditional
;; clause built into a shared string with a fixed argument list is how a clause
;; and its parameter come apart, which this codebase has paid for five times.
(define (untranscribed-sql)
  (string-append
   "SELECT o.id, COALESCE(v.content_type, '') "
   "FROM repo_objects o "
   "JOIN repo_versions v ON v.id = o.current_version_id "
   "LEFT JOIN repo_text t ON t.object_id = o.id AND t.version_id = o.current_version_id "
   "WHERE o.team_id = ? AND o.deleted_at IS NULL AND t.object_id IS NULL "))

(define (untranscribed-tail) "ORDER BY o.updated_at ASC LIMIT ?")

(define (transcribe-one conn p args)
  (define id (hash-ref args 'object ""))
  (define language (let ([v (hash-ref args 'language #f)])
                     (and (string? v) (> (string-length v) 0) v)))
  (unless (transcribe-configured?)
    ;; Refused BY NAME and before the document is read: failing at step one beats
    ;; failing once per recording for one unset variable (`require-embedder!`'s
    ;; rule).
    (raise-user-error
     'doc_transcribe
     (string-append "no transcription model configured — set TMACH_TRANSCRIBE_URL (and "
                    "TMACH_TRANSCRIBE_MODEL) to an OpenAI-compatible "
                    "/v1/audio/transcriptions endpoint, such as whisper.cpp's own server")))
  (define-values (o in) (repo-open conn p id))
  (unless in (error 'doc_transcribe "no such document: ~a" id))
  (define ct (hash-ref o 'content_type))
  (define payload
    (dynamic-wind void (lambda () (port->bytes in)) (lambda () (close-input-port in))))
  ;; VOICE‑13 — THE TYPE IS CHECKED BEFORE THE WIRE, AND THE CHECK IS THE CLOSED
  ;; LIST. A PDF posted to a transcription endpoint comes back as whatever that
  ;; server says about a file it cannot decode, which names its internals rather
  ;; than the caller's mistake (`doc_fill_form`'s reason for refusing by content
  ;; type first). And it would have spent the request.
  (unless (audio-type? ct)
    (raise-user-error 'doc_transcribe
                      "~a is ~a, which is not audio this build will transcribe — ~a"
                      (hash-ref o 'key) ct (string-join AUDIO-TYPES ", ")))
  (when (> (bytes-length payload) VOICE-MAX-BYTES)
    (raise-user-error 'doc_transcribe
                      "~a is ~a bytes, over the ~a-byte transcription ceiling"
                      (hash-ref o 'key) (bytes-length payload) VOICE-MAX-BYTES))
  (define-values (text duration detected)
    ((current-doc-transcribe) payload ct (audio-filename-for ct)))
  (meter-transcribe! conn p)
  (define capped (if (> (string-length text) EXTRACT-CAP) (substring text 0 EXTRACT-CAP) text))
  ;; No spans. A transcript HAS positions — every segment carries a time — and
  ;; LAY‑5's span is a page and a bbox, which a renderer draws. A time range is
  ;; not a region, and putting one in `bbox` would make
  ;; `GET /api/repo-obj/:id/spans?at=` answer with coordinates something would
  ;; try to draw on a page that does not exist. If "jump to where this was said"
  ;; is wanted, that is LAY‑5 gaining an optional time range, which is its own
  ;; decision and not this slice's to make quietly.
  (repo-text-upsert! conn id (hash-ref o 'version_id) capped)
  ;; LAY‑4 refuses an undefined key, so the fields are declared before the write —
  ;; additively, never over a team's own label (`record-type!`'s rule).
  (repo-fields-declare! conn (principal-team-id p) VOICE-FIELDS
                        #:subject "voice notes"
                        #:advice "transcription writes these")
  (define attrs
    (for/fold ([h (hasheq 'voice_model (transcribe-model))])
              ([pair (in-list (list ;; an INTEGER string: `(round 3.5)` on a flonum is `4.0`, and
                                    ;; `?attr=voice_duration:4` is what somebody
                                    ;; would type — an equality filter (CLS-8)
                                    (cons 'voice_duration
                                          (and duration
                                               (number->string (inexact->exact (round duration)))))
                                    (cons 'voice_language detected)))])
      (if (cdr pair) (hash-set h (car pair) (cdr pair)) h)))
  (repo-set-attributes! conn p id attrs)
  ;; VOICE‑14 — AN EMPTY TRANSCRIPT IS RECORDED, NOT RAISED. Silence transcribes
  ;; to "", and a recording of a quiet room is a legitimate voice note; raising
  ;; would fail the step, and the next run would list the same object and fail
  ;; again — one silent recording wedging the team's transcription for ever,
  ;; which is the indexer's own rule (`repo_extract_text`'s `else` branch). The
  ;; row keyed to this version is what stops it being offered again, and a
  ;; re-upload makes it eligible.
  (hasheq 'object_id id
          'key (hash-ref o 'key)
          'characters (string-length capped)
          'duration (or duration 'null)
          'language (or detected 'null)
          'model (transcribe-model)
          'empty (string=? (string-trim capped) "")))

(register-tool! "doc_transcribe" doc_transcribe "files:write" transcribe-one)
(register-tool! "voice_list_untranscribed" voice_list_untranscribed "files:read" list-untranscribed)
