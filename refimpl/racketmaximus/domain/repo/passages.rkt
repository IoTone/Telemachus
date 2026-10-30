#lang racket/base

;; domain/repo/passages.rkt — a question in, the team's most similar document
;; passages out (#189 step 6, decisions VEC‑33…40).
;;
;; `vector-store.md`'s build plan, step 6: "a retrieval tool and `?semantic=` on
;; search, which is where #183 and #191 pick it up." Those are TWO askers, and
;; this module is the one answer they share — `executor-can-run?`'s drift is what
;; two copies of this would be, and the copies would diverge in the worst place,
;; since one of them is a model request that spends somebody's budget.
;;
;; The division of labour, which is the whole reason this is three modules and
;; not one:
;;
;;   `chunksearch.rkt`   the scan: which chunks, where, and `can?` per row
;;   THIS MODULE         the question embedded, and the chunks turned into TEXT
;;   `retrieve-tools.rkt` the tool, and `search.rkt` the `?semantic=` half
;;
;; It is in `domain/repo/` rather than beside the scan in `domain/ai/` for the
;; reason `embed-tools.rkt` is: it reaches the metering seam in `doc-tools.rkt`
;; and the text in `extract.rkt`, so it belongs with the repository's own
;; model-backed code rather than with the arithmetic.

(require db-kit/portable
         (only-in racket/string string-trim)
         "../authz/authz.rkt"
         (only-in "../ai/executor.rkt" embed-configured? embed-model)
         (only-in "../ai/chunksearch.rkt" chunks-nearest)
         (only-in "doc-tools.rkt" current-doc-embed meter-embed!)
         (only-in "extract.rkt" repo-text-for repo-text-version-for))

(provide passages-for PASSAGE-LIMIT PASSAGE-MAX semantic-available?)

;; k's default and its ceiling. A chunk is up to `CHUNK-SIZE` characters, so 8
;; passages is ~8 KB of prompt — which is what #183 and #191 are going to do with
;; them — and 20 is where that stops being a retrieval and starts being the
;; document. The ceiling is here rather than left to the caller because one of
;; the callers is a model choosing its own argument.
(define PASSAGE-LIMIT 8)
(define PASSAGE-MAX 20)

;; VEC‑34 — THE TWO ASKERS DIFFER ON WHAT AN UNCONFIGURED INSTANCE SHOULD DO, so
;; the predicate is exported and the DECISION is not made here. A tool asked for
;; exactly this refuses by name (`repo_embed_chunks`'s rule); a search asked for a
;; search answers the keyword half and reports that the other one is unavailable
;; (`content_search: false`'s rule, in the very module that half lives in). Both
;; are right, for the same reason each is right where it already appears, and a
;; shared boolean is what keeps them from drifting into one.
(define (semantic-available? conn p)
  (and (embed-configured?) (can? conn p "chat:use") #t))

;; ---- the read ----------------------------------------------------------------
;;
;; VEC‑35 — IT COSTS A MODEL REQUEST, SO IT IS GATED ON `chat:use` AND METERED
;; THROUGH THE ONE SEAM. The question has to be embedded by the same checkpoint
;; the stored vectors are of, which is a call to a provider — so unlike every
;; other kind of search in this tree, asking this one spends the team's budget.
;; `chat:use` is the permission that already means "may spend the team's AI
;; allowance", and it is what `search.rkt` gates translations on, one `cond` arm
;; away. The metering goes through `current-doc-embed` + `meter-embed!` rather
;; than `embed-exchange` directly, so the egress policy, the request log and BOTH
;; dimensions (`ai.requests` and `ai.embeddings.total`) are the ones every other
;; embedding in the platform goes through — RED‑16's finding, that a second caller
;; of the wire is a second place all three can be forgotten.
;;
;; Answers ONE hash: 'passages, plus the scan's own report and the model the
;; comparison was made under.
(define (passages-for conn p question #:limit [k PASSAGE-LIMIT])
  (require-perm conn p "files:read")
  (require-perm conn p "chat:use")
  (unless (embed-configured?)
    (error 'passages-for
           (string-append "no embedding model configured — set TMACH_EMBED_URL "
                          "(and TMACH_EMBED_MODEL, e.g. nomic-embed-text). Keyword search "
                          "does not need it; searching by meaning does.")))
  (define q (string-trim (if (string? question) question "")))
  (when (string=? q "")
    (error 'passages-for "the question is empty — there is nothing to compare"))
  (define want (max 1 (min (if (exact-positive-integer? k) k PASSAGE-LIMIT) PASSAGE-MAX)))
  (define model (embed-model))
  ;; one request, for one string. `embed-exchange` reads its answer by `index`
  ;; (EMB's rule), so a single-element batch is still paired rather than assumed.
  (define embed (current-doc-embed))
  (define-values (vs toks) (embed (list q)))
  (meter-embed! conn p toks)
  (unless (and (list? vs) (= (length vs) 1))
    (error 'passages-for "the embedder answered ~a vector(s) for one question"
           (if (list? vs) (length vs) 0)))
  (define rep (chunks-nearest conn p (car vs) model #:k want))
  ;; VEC‑36 — THE TEXT COMES FROM `repo_text` AND IS MEMOISED PER DOCUMENT. The
  ;; store holds offsets and a vector and no text at all (VEC‑32), so a passage is
  ;; a substring of the extracted text — which also means the unseal happens
  ;; through `repo-text-for`, not a SQL `LIKE`.
  (define texts (make-hash))
  (define versions (make-hash))
  (define (text-of id) (hash-ref! texts id (lambda () (repo-text-for conn id))))
  (define (version-of id) (hash-ref! versions id (lambda () (repo-text-version-for conn id))))
  (define passages
    (for*/list ([h (in-list (hash-ref rep 'hits))]
                [t (in-value (passage-text (text-of (hash-ref h 'object_id))
                                           (version-of (hash-ref h 'object_id))
                                           h))]
                #:when t)
      (hash-set h 'text t)))
  (hasheq 'passages passages
          'model model
          'scanned (hash-ref rep 'scanned)
          'skipped (hash-ref rep 'skipped)
          'withheld (hash-ref rep 'withheld)
          ;; a hit dropped because its text moved is a third way of coming back
          ;; short, and it is folded into `truncated` rather than invented as a
          ;; fourth count: the remedy is the same as the headroom's — re-run the
          ;; embedding workflow, or ask again.
          'truncated (or (hash-ref rep 'truncated)
                         (< (length passages) (length (hash-ref rep 'hits))))))

;; VEC‑37 — A PASSAGE WHOSE TEXT HAS MOVED UNDER IT IS DROPPED, NOT CLAMPED.
;; The offsets are into the string the extractor returned for a PARTICULAR
;; version (CHUNK‑1), and `repo-text-for` is keyed by object alone. The scan's
;; join makes the two agree in every state a workflow can produce, so reaching
;; here means something raced — and the two wrong answers are both worse than
;; nothing: a clamped substring quotes characters the vector was never made from,
;; and an unclamped one RAISES and takes a whole search down over one document.
;; `embed-one` refuses the symmetric case at write time for the same reason, in
;; the same words ("the vectors would cite a string that has changed").
(define (passage-text text version h)
  (and (string? text)
       (equal? version (hash-ref h 'version_id))
       (let ([n (string-length text)]
             [s (hash-ref h 'start)]
             [e (hash-ref h 'end)])
         (and (exact-nonnegative-integer? s) (exact-nonnegative-integer? e)
              (<= s e) (<= e n)
              (substring text s e)))))
