#lang racket/base

;; domain/help/helpsearch.rkt — a question, and the passages of the product's own
;; documentation that answer it (#183, decisions HELP‑7/‑11/‑12/‑13).
;;
;; This is `chunksearch.rkt` + `passages.rkt` for the help corpus, and it is
;; markedly simpler than either for ONE reason: there is no `can?`. HELP‑7 — a
;; paragraph of `docs/ops/container.md` is the manual for the software the asker
;; is already signed in to, so there is no per-row filter, no VEC‑28
;; authorization headroom, and therefore none of the one approximation #189's
;; read had to make. `k` candidates are scored and `k` are answered.
;;
;; It composes and decides; the arithmetic is `vec-nearest`'s and the offsets are
;; CHUNK‑1's, so a hit cites a path, a heading and a character range in a file
;; anybody can open.

(require db-kit/portable racket/flonum
         (only-in "../ai/vectors.rkt" vec-normalize vec-nearest)
         (only-in "helpstore.rkt" help-text-for help-locales help-any?))

(provide help-nearest help-passages help-available?
         HELP-SCAN HELP-K HELP-MAX HELP-SNIPPET)

;; HELP‑11 — THE WINDOW CAP IS THE WHOLE CORPUS AND THEN SOME, which is a
;; different kind of number from VEC‑26's. That one is deliberately equal to the
;; scale at which `vector-store.md` says to reconsider the design, because a
;; team's document count is unbounded. This corpus is **the project's own
;; documentation**: 63 English Markdown files and 26 Japanese, measured at 1,227
;; chunks of English with the real chunker. 20,000 is sixteen times that — room
;; for the documentation to grow by an order of magnitude — and the scan at that
;; size is ~150 ms of arithmetic, interpolated from #189 step 1 (76 ms at 10,000,
;; 784 ms at 100,000). A truncating window
;; here would mean the documentation had outgrown the assumption, so `truncated`
;; is reported for the same reason it is there.
(define HELP-SCAN 20000)

(define HELP-K 6)
(define HELP-MAX 20)

;; How much of a passage a caller that wants a preview gets. A chunk is up to
;; `CHUNK-SIZE` characters; a list of six whole chunks is 6 KB, which is right
;; for a prompt and wrong for a list somebody reads.
(define HELP-SNIPPET 240)

;; Whether this instance can answer a help question at all: an embedder for the
;; question, and a corpus to compare it against. EXPORTED and making no decision
;; of its own — VEC‑34's rule, because the two askers differ. The console wants
;; to hide a panel that cannot work; the endpoint wants to say WHICH half is
;; missing, which is why this answers a reason rather than a boolean.
;;
;; `embed-configured?` is passed in rather than required, so this module reaches
;; no network and no environment and a test needs neither.
(define (help-available? conn embed-configured? [locale #f])
  (cond
    [(not embed-configured?) "unconfigured"]
    [(not (help-any? conn)) "empty"]
    [(and locale (not (help-any? conn locale))) "locale-empty"]
    [else #f]))

;; ---- the scan ----------------------------------------------------------------
;;
;; HELP‑12 — THE LOCALE IS A SQL FILTER WITH AN HONEST FALLBACK. The console
;; ships in Japanese and the documentation has a Japanese e-book and a Japanese
;; generated reference, so a Japanese operator asking a Japanese question should
;; be answered out of the Japanese pages. What this does NOT do is claim
;; cross-lingual retrieval: `nomic-embed-text` may or may not put a Japanese
;; question near its English answer, nothing here has measured it, and a design
;; that quietly relied on it would be the confident wrong answer CHUNK‑2 warns
;; about. So the filter is exact, and when the asked locale holds nothing the
;; scan falls back to the default locale and SAYS which locale answered — the
;; rule a missing screenshot caption already follows, where a silent English
;; fallback in a Japanese page is worse than an obviously untranslated one.
;;
;; The model filter is in SQL for VEC‑20's reason: a dot product between two
;; checkpoints' coordinate systems is a NUMBER, so mixing them answers
;; confidently and nobody can tell.
(define (help-nearest conn query model
                      #:k [k HELP-K]
                      #:locale [locale #f]
                      #:fallback-locale [fallback #f]
                      #:scan [scan HELP-SCAN])
  (unless (exact-positive-integer? k)
    (error 'help-nearest "k must be a positive integer, given ~e" k))
  (define q (vec-normalize (->flvector query)))
  (unless q
    (error 'help-nearest
           (string-append "the question embedded to a vector with no direction (all zeros, or "
                          "a NaN component) — an embedder answers one for empty input, so the "
                          "question text is the thing to look at")))
  (define-values (used rows) (window conn model locale fallback scan))
  (define-values (scored skipped)
    (vec-nearest q
                 (for/list ([r (in-list rows)]) (cons r (vector-ref r 7)))
                 k))
  (hasheq 'hits (for/list ([s (in-list scored)])
                  (define r (car s))
                  (hasheq 'chunk_id (vector-ref r 0)
                          'doc_id (vector-ref r 1)
                          'path (vector-ref r 2)
                          'title (vector-ref r 3)
                          'heading (vector-ref r 4)
                          'start (vector-ref r 5)
                          'end (vector-ref r 6)
                          'locale (vector-ref r 8)
                          'model model
                          'score (cdr s)))
          'locale used
          'scanned (length rows)
          'skipped skipped
          'truncated (>= (length rows) scan)))

;; One statement per shape rather than a clause built into a shared string: a
;; conditional clause with a fixed argument list is how a clause and its
;; parameter come apart, which this codebase has paid for four times.
(define (window conn model locale fallback scan)
  (define cols
    (string-append
     "SELECT c.id, d.id, d.path, d.title, c.heading, c.start_off, c.end_off, c.vector, d.locale "
     "FROM help_chunks c JOIN help_docs d ON d.id = c.doc_id "))
  ;; The cut, when there is one, takes the NEWEST ingest's rows first and a
  ;; document's PREFIX rather than a scatter of it — VEC‑30's key, for its
  ;; reasons, and the same caveat applies: the test can catch this being
  ;; inverted and cannot catch it being absent.
  (define order "ORDER BY c.created_epoch DESC, d.path ASC, c.idx ASC LIMIT ?")
  (define (rows-for loc)
    (if loc
        (query-rows conn (string-append cols "WHERE c.model = ? AND d.locale = ? " order)
                    model loc scan)
        (query-rows conn (string-append cols "WHERE c.model = ? " order) model scan)))
  (define first-try (rows-for locale))
  (cond
    [(pair? first-try) (values locale first-try)]
    [(and locale fallback (not (equal? fallback locale)))
     (define second-try (rows-for fallback))
     (if (pair? second-try) (values fallback second-try) (values locale '()))]
    [else (values locale first-try)]))

;; ---- the passages ------------------------------------------------------------
;;
;; HELP‑13 — THE TEXT IS RESOLVED HERE AND A HIT WHOSE DOCUMENT HAS MOVED UNDER
;; IT IS DROPPED, NOT CLAMPED. VEC‑37's rule: the offsets index the text that was
;; ingested, `help-replace-doc!` replaces a path's text and its chunks in one
;; transaction, so a mismatch means something raced an ingest. A clamped
;; substring quotes characters the vector was never made from — a citation that
;; is wrong in the one way a citation must not be — and an unclamped one raises
;; and takes a whole answer down over one file.
(define (help-passages conn query model
                       #:k [k HELP-K]
                       #:locale [locale #f]
                       #:fallback-locale [fallback #f])
  (define kk (min (max 1 k) HELP-MAX))
  (define rep (help-nearest conn query model #:k kk #:locale locale #:fallback-locale fallback))
  (define texts (make-hash))
  (define (text-of doc-id)
    (hash-ref! texts doc-id (lambda () (help-text-for conn doc-id))))
  (define-values (passages dropped)
    (for/fold ([out '()] [dropped 0] #:result (values (reverse out) dropped))
              ([h (in-list (hash-ref rep 'hits))])
      (define body (passage-text (text-of (hash-ref h 'doc_id)) h))
      (if body
          (values (cons (hash-set h 'text body) out) dropped)
          (values out (add1 dropped)))))
  (hasheq 'passages passages
          'locale (hash-ref rep 'locale)
          'model model
          'scanned (hash-ref rep 'scanned)
          'skipped (hash-ref rep 'skipped)
          'dropped dropped
          'truncated (or (hash-ref rep 'truncated) (> dropped 0))))

(define (passage-text text h)
  (and (string? text)
       (let ([n (string-length text)] [s (hash-ref h 'start)] [e (hash-ref h 'end)])
         (and (exact-nonnegative-integer? s) (exact-nonnegative-integer? e)
              (<= s e) (<= e n) (substring text s e)))))

(define (->flvector v)
  (cond
    [(flvector? v) v]
    [(vector? v)
     (define n (vector-length v))
     (define out (make-flvector n))
     (for ([i (in-range n)]) (flvector-set! out i (real->double-flonum (vector-ref v i))))
     out]
    [(list? v) (->flvector (list->vector v))]
    [else (error 'help-nearest "not a vector of numbers: ~e" v)]))
