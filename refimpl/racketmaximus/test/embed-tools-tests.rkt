#lang racket/base

;; test/embed-tools-tests.rkt — #189 step 4: the two chunk-embedding tools and
;; the workflow that composes them.
;;   raco test test/embed-tools-tests.rkt
;;
;; The model seam is SCRIPTED (`current-doc-embed`), so none of this needs an
;; embedding endpoint — which is the point of the seam existing: a test that
;; required `nomic-embed-text` would be a test nobody runs, and step 4's whole
;; claim is that it does not wait for hardware.
;;
;; `TMACH_EMBED_URL` is still SET in the cases that exercise the happy path,
;; because `embed-configured?` is what the refusal is made of and the tools ask it
;; before anything else. Scripting the seam does not configure the instance.

(require rackunit db-kit/portable racket/port racket/file racket/list racket/string
         db-kit/migrate
         "../domain/db/migrations.rkt"
         "db-fixture.rkt"
         "../domain/authz/authz.rkt"
         "../domain/repo/blobs.rkt"
         "../domain/repo/repo.rkt"
         "../domain/repo/extract.rkt"
         "../domain/repo/doc-tools.rkt"
         "../domain/repo/embed-tools.rkt"
         "../domain/repo/index-tools.rkt"
         "../domain/agent/tools.rkt"
         "../domain/agent/registry.rkt"
         "../domain/ai/chunk.rkt"
         "../domain/ai/chunkstore.rkt"
         "../domain/quota/quota.rkt"
         "../domain/sched/scheduler.rkt"
         "../domain/flow/run.rkt"
         (prefix-in indexer: "../plugins/doc-indexer/main.rkt"))

(define BLOB-ROOT (make-temporary-file "telemachus-embedtools-~a" 'directory))
(current-blob-root BLOB-ROOT)

(define (fresh)
  (define conn (fresh-db #:migrate? #f))
  (migrate! conn all-migrations)
  conn)

(define (drain! conn [limit 300])
  (let loop ([n 0]) (when (and (< n limit) (process-one! conn)) (loop (add1 n)))))

;; ---- the scripted embedder -----------------------------------------------------
;; It counts its CALLS as well as answering, because "one request per batch" is a
;; budget property (`ai.requests` defaults to 200/day) and a test that only looked
;; at the vectors could not see it.
(define calls (box '()))
(define (script-embed texts)
  (set-box! calls (cons (length texts) (unbox calls)))
  (values (for/list ([(t i) (in-indexed texts)])
            (for/vector ([j (in-range 8)]) (sin (+ i 1.0 (* 0.1 j)))))
          (for/sum ([t (in-list texts)]) (string-length t))))

;; The variable NAMES are values here, never literals inside a `getenv` call —
;; ENVN-2's gate forbids a second home for an operator variable's spelling, and
;; `content-encryption-tests` already does it this way.
(define URL-VAR "TMACH_EMBED_URL")
(define MODEL-VAR "TMACH_EMBED_MODEL")

(define (with-env* pairs thunk)
  (define saved (for/list ([kv (in-list pairs)]) (cons (car kv) (getenv (car kv)))))
  (dynamic-wind
    (lambda () (for ([kv (in-list pairs)]) (putenv (car kv) (or (cdr kv) ""))))
    thunk
    (lambda () (for ([kv (in-list saved)]) (putenv (car kv) (or (cdr kv) ""))) (void))))

(define (with-embedder thunk #:url [url "http://127.0.0.1:1/v1/embeddings"] #:model [model "test-embed"])
  (set-box! calls '())
  (with-env* (list (cons URL-VAR url) (cons MODEL-VAR model))
             (lambda () (parameterize ([current-doc-embed script-embed]) (thunk)))))

;; ---- fixtures ------------------------------------------------------------------
(define (seed!)
  (define conn (fresh))
  (define-values (uid tid) (bootstrap! conn #:username "alice"))
  (define p (user-principal conn uid tid))
  (values conn p tid))

(define (up! conn p key text #:vis [vis "team"])
  (define o (repo-put! conn p #:key key #:port (open-input-bytes (string->bytes/utf-8 text))
                       #:content-type "text/markdown" #:filename key #:visibility vis))
  o)

;; a document WITH its text already extracted, which is what the embed workflow
;; takes as given (CHUNK-1: the offsets are offsets into exactly this string)
(define (indexed! conn p key text #:vis [vis "team"])
  (define o (up! conn p key text #:vis vis))
  (repo-text-upsert! conn (hash-ref o 'id) (hash-ref o 'version_id) text)
  o)

(define (call-tool conn p name args)
  ((tool-handler (tool-by-name name)) conn p args))

;; ---- 1. the refusal names the variable ----------------------------------------
(test-case "with no embedding endpoint BOTH tools refuse, by name, at step one"
  (define-values (conn p tid) (seed!))
  (define o (indexed! conn p "notes/a.md" "octopuses are cephalopods."))
  (with-embedder #:url #f
    (lambda ()
      ;; The lister refuses rather than handing back 25 ids the map would fail on
      ;; one at a time — `repo_extract_text`'s call about a missing `pdftotext`.
      (check-exn #rx"TMACH_EMBED_URL"
                 (lambda () (call-tool conn p "repo_list_unembedded" (hasheq))))
      (check-exn #rx"TMACH_EMBED_URL"
                 (lambda () (call-tool conn p "repo_embed_chunks"
                                       (hasheq 'id (hash-ref o 'id)))))))
  (close-db! conn))

;; ---- 2. the lister ------------------------------------------------------------
(test-case "a document with text and no vectors is listed; one already embedded is not"
  (define-values (conn p tid) (seed!))
  (define o (indexed! conn p "notes/a.md" "octopuses are cephalopods."))
  (with-embedder
    (lambda ()
      (check-equal? (call-tool conn p "repo_list_unembedded" (hasheq)) (list (hash-ref o 'id)))
      (call-tool conn p "repo_embed_chunks" (hasheq 'id (hash-ref o 'id)))
      (check-equal? (call-tool conn p "repo_list_unembedded" (hasheq)) '()
                    "an embedded document is still listed — the drain would never finish")))
  (close-db! conn))

(test-case "vectors from ANOTHER model make the document eligible again (EMB-8)"
  (define-values (conn p tid) (seed!))
  (define o (indexed! conn p "notes/a.md" "octopuses are cephalopods."))
  (with-embedder #:model "old-embed"
    (lambda () (call-tool conn p "repo_embed_chunks" (hasheq 'id (hash-ref o 'id)))))
  ;; vectors from two checkpoints are not comparable and mixing them does not
  ;; raise — it answers confidently and wrongly — so changing the model has to
  ;; make every document eligible for a re-embed
  (with-embedder #:model "new-embed"
    (lambda ()
      (check-equal? (call-tool conn p "repo_list_unembedded" (hasheq)) (list (hash-ref o 'id)))))
  (close-db! conn))

(test-case "a document with BLANK extracted text is never listed, so the drain terminates"
  (define-values (conn p tid) (seed!))
  ;; `repo_extract_text` records an unreadable document as processed-with-nothing —
  ;; an EMPTY repo_text row, deliberately, so one corrupt file cannot wedge a
  ;; team's indexing. The chunker answers zero chunks for an empty string, so such
  ;; a document can never acquire a vector row: without VEC-23's filter it is
  ;; listed by every run for ever and an operator draining the backlog by running
  ;; the workflow until it finds nothing never finishes.
  (define o (up! conn p "broken/scan.md" "x"))
  (repo-text-upsert! conn (hash-ref o 'id) (hash-ref o 'version_id) "")
  (define blank (up! conn p "broken/space.md" "x"))
  (repo-text-upsert! conn (hash-ref blank 'id) (hash-ref blank 'version_id) "   \n  \t ")
  (with-embedder
    (lambda ()
      (check-equal? (call-tool conn p "repo_list_unembedded" (hasheq)) '()
                    "a blank-text document was offered for embedding")))
  (close-db! conn))

(test-case "the lister is capped at EMBED-BATCH"
  (define-values (conn p tid) (seed!))
  (for ([i (in-range (+ EMBED-BATCH 4))])
    (indexed! conn p (format "notes/~a.md" i) (format "octopus number ~a is a cephalopod." i)))
  (with-embedder
    (lambda ()
      (check-equal? (length (call-tool conn p "repo_list_unembedded" (hasheq))) EMBED-BATCH)))
  (close-db! conn))

;; ---- 3. the write -------------------------------------------------------------
(test-case "a document with no extracted text is a named refusal, not an empty write"
  (define-values (conn p tid) (seed!))
  (define o (up! conn p "notes/a.md" "octopuses are cephalopods."))   ; uploaded, NOT indexed
  (with-embedder
    (lambda ()
      (check-exn #rx"Index Documents"
                 (lambda () (call-tool conn p "repo_embed_chunks" (hasheq 'id (hash-ref o 'id))))
                 "a document with no text must say which workflow to run first")))
  (close-db! conn))

(test-case "text of an OLDER version is refused — the offsets would cite a changed string"
  (define-values (conn p tid) (seed!))
  (define o (indexed! conn p "notes/a.md" "octopuses are cephalopods."))
  ;; a new upload: the object's current version moves, the extracted text does not
  (repo-put! conn p #:key "notes/a.md" #:port (open-input-bytes #"walruses are pinnipeds.")
             #:content-type "text/markdown" #:filename "a.md")
  (with-embedder
    (lambda ()
      (check-exn #rx"older version"
                 (lambda () (call-tool conn p "repo_embed_chunks" (hasheq 'id (hash-ref o 'id))))
                 "embedding stale text would store offsets into a string that has changed")))
  (close-db! conn))

(test-case "the write stores one unit vector per chunk and meters BOTH dimensions"
  (define-values (conn p tid) (seed!))
  (define text (string-append (make-string 2000 #\a) ". " (make-string 2000 #\b)))
  (define o (indexed! conn p "notes/a.md" text))
  (with-embedder
    (lambda ()
      (define msg (call-tool conn p "repo_embed_chunks" (hasheq 'id (hash-ref o 'id))))
      (check-true (string-contains? msg "notes/a.md"))
      (define-values (cs _t) (chunk-text text))
      (check-equal? (length (chunk-rows-for conn (hash-ref o 'id) (hash-ref o 'version_id)))
                    (length cs))
      (check-equal? (chunks-model-for conn (hash-ref o 'id) (hash-ref o 'version_id)) "test-embed")
      ;; EMB-6: an embedding bills its own dimension and `ai.requests` too. The
      ;; completion budget is NOT touched — folding them would make a retrieval
      ;; index silently eat the budget the chat path needs.
      (check > (quota-used conn "team" tid "ai.embeddings.total" "total") 0)
      (check > (quota-used conn "team" tid "ai.requests" "total") 0)
      (check-equal? (quota-used conn "team" tid "ai.tokens.total" "total") 0
                    "an embedding must not spend the completion budget")))
  (close-db! conn))

(test-case "chunks go to the embedder in batches, not one request each"
  (define-values (conn p tid) (seed!))
  ;; enough chunks to need more than one request, and not so many that the cap bites
  (define text (make-string (* CHUNK-EMBED-BATCH 1200) #\x))
  (define o (indexed! conn p "notes/big.md" text))
  (with-embedder
    (lambda ()
      (call-tool conn p "repo_embed_chunks" (hasheq 'id (hash-ref o 'id)))
      (define sizes (reverse (unbox calls)))
      (define-values (cs _t) (chunk-text text))
      (check-equal? (apply + sizes) (length cs) "every chunk was embedded exactly once")
      (check > (length cs) CHUNK-EMBED-BATCH "the fixture must exceed one batch")
      (check > (length sizes) 1 "more than one request was needed")
      (check-true (for/and ([s (in-list sizes)]) (<= s CHUNK-EMBED-BATCH))
                  "a batch exceeded CHUNK-EMBED-BATCH — one request per chunk would spend ai.requests")
      ;; …and the requests are what the meter counted, not the chunks
      (check-equal? (quota-used conn "team" tid "ai.requests" "total") (length sizes))))
  (close-db! conn))

(test-case "a colleague cannot embed a private document, and nothing is written"
  (define-values (conn p tid) (seed!))
  (define o (indexed! conn p "hr/secret.md" "the zebra severance plan." #:vis "private"))
  (define bob (create-user! conn #:username "bob" #:password "pw"))
  (add-member! conn #:team tid #:user bob #:role "member")
  (define pbob (user-principal conn bob tid))
  (with-embedder
    (lambda ()
      ;; `repo-open` is the authorized read path, so the refusal is the
      ;; repository's own and needs no authorization code here (VEC-17)
      (check-exn exn:fail?
                 (lambda () (call-tool conn pbob "repo_embed_chunks" (hasheq 'id (hash-ref o 'id)))))
      (check-equal? (query-value conn "SELECT COUNT(*) FROM repo_chunks") 0)
      ;; …and it is not offered to them either
      (check-equal? (call-tool conn pbob "repo_list_unembedded" (hasheq)) '())))
  (close-db! conn))

;; ---- 4. the workflow, through the real engine ----------------------------------
(test-case "the embed-documents workflow runs end to end through the scheduler"
  (define-values (conn p tid) (seed!))
  (for ([w (in-list indexer:workflows)]) (register-plugin-workflow! "doc-indexer" w))
  (indexed! conn p "notes/a.md" "octopuses are cephalopods and they are clever.")
  (indexed! conn p "notes/b.md" "walruses are pinnipeds with notable tusks.")
  (with-embedder
    (lambda ()
      (define def (flow-def-by-slug conn p "embed-documents"))
      (check-true (and def #t) "the plugin's second workflow materialized")
      (define run (flow-run-start! conn p def))
      (drain! conn)
      (define done (flow-run-get conn p (hash-ref run 'id)))
      (check-equal? (hash-ref done 'status) "done"
                    (format "the run finished (error: ~a)" (hash-ref done 'error)))
      (define kids (filter (lambda (s) (regexp-match? #rx"embed#" (hash-ref s 'step_id)))
                           (hash-ref done 'steps)))
      (check-equal? (length kids) 2 "both documents fanned out")
      (check-equal? (chunks-count conn tid) 2 "one chunk each, stored")
      ;; and a second run finds nothing — the drain terminates, which is the
      ;; property an operator running this until it is quiet depends on
      (define run2 (flow-run-start! conn p (flow-def-by-slug conn p "embed-documents")))
      (drain! conn)
      (define done2 (flow-run-get conn p (hash-ref run2 'id)))
      (check-equal? (hash-ref done2 'status) "done")
      (check-equal? (chunks-count conn tid) 2 "a second run re-embedded what was already done")))
  (close-db! conn))

(test-case "index-documents is UNCHANGED by this slice — it needs no embedder"
  (define-values (conn p tid) (seed!))
  (for ([w (in-list indexer:workflows)]) (register-plugin-workflow! "doc-indexer" w))
  (up! conn p "notes/a.md" "octopuses are cephalopods.")
  ;; VEC-24: with NO embedding endpoint configured at all, text indexing must
  ;; still work exactly as before. This is the case that would have broken had the
  ;; two steps been appended to the published spec instead of given their own.
  (define done
    (with-env* (list (cons URL-VAR #f))
      (lambda ()
        (define def (flow-def-by-slug conn p "index-documents"))
        (define run (flow-run-start! conn p def))
        (drain! conn)
        (flow-run-get conn p (hash-ref run 'id)))))
  (check-equal? (hash-ref done 'status) "done"
                (format "text indexing broke without an embedder (error: ~a)" (hash-ref done 'error)))
  (close-db! conn))
