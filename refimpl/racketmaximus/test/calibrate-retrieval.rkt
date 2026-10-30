#lang racket/base

;; test/calibrate-retrieval.rkt — the chunk size and overlap calibration
;; (#189 step 3, the one thing left on that issue).
;;
;; NOT a suite, and deliberately not named `*-tests.rkt`: `raco test
;; test/*-tests.rkt` must never pick it up, because it needs a LIVE embedder and
;; takes minutes. `mock-llm.rkt` and `make-acroform.py` live here on the same
;; terms — test-adjacent tools that are not tests.
;;
;;   TMACH_EMBED_URL=… TMACH_EMBED_MODEL=nomic-embed-text \
;;     racket test/calibrate-retrieval.rkt --docs /path/to/Telemachus
;;
;; WHAT IT MEASURES. `CHUNK-SIZE-DEFAULT` (1,024) and `CHUNK-OVERLAP-DEFAULT`
;; (154) say PROVISIONAL at their definition, with "what would change them is a
;; recall measurement, in both languages (CHUNK‑2)". This is that measurement.
;; For each (size, overlap) it ingests the whole documentation corpus, asks every
;; question in `calibration-questions.json`, and reports recall@1/3/5 at the FILE
;; level per locale.
;;
;; WHY FILE LEVEL AND NOT SECTION. A question's answer is unambiguously in a
;; file; which SECTION is often arguable, and the earlier probe showed the
;; section is the harder problem — "why does my container healthcheck report
;; unhealthy" found the right file and the wrong heading. Scoring sections would
;; mean adjudicating a hundred headings and would measure my judgement as much as
;; the retrieval. File level is the question an answer actually depends on: the
;; passages handed to the model have to come from the document that says it.
;;
;; WHY A SET OF ACCEPTABLE FILES. Several things are documented in a book chapter
;; AND a runbook, on purpose. A question answered out of either is answered;
;; insisting on one would score a correct retrieval as a miss and then
;; "improve" the chunker to fix a problem that was in the question set.
;;
;; WHAT IT CANNOT MEASURE, stated up front: 28 questions is not a benchmark, and
;; they were written by the same person who wrote most of the documentation, so
;; they share its vocabulary more than a stranger's would. What the sweep is for
;; is the SHAPE — whether recall moves with the size at all, and whether English
;; and Japanese want the same number — not an absolute figure anybody should
;; quote.

(require json racket/list racket/string racket/file racket/format racket/port
         db-kit db-kit/portable db-kit/migrate
         "../domain/db/migrations.rkt"
         (only-in "../config.rkt" impl-root)
         (only-in "../domain/ai/executor.rkt" embed-exchange embed-model embed-configured?)
         (only-in "../domain/help/helpstore.rkt" help-clear! help-stats help-chunk-count)
         (only-in "../domain/help/helpindex.rkt" help-ingest! current-help-embed)
         (only-in "../domain/help/helpsearch.rkt" help-nearest))

(define (arg-value name default)
  (define args (vector->list (current-command-line-arguments)))
  (let loop ([a args])
    (cond [(or (null? a) (null? (cdr a))) default]
          [(equal? (car a) name) (cadr a)]
          [else (loop (cdr a))])))

;; ---- the grid ------------------------------------------------------------------
;;
;; Sizes span a factor of four around today's default, and the overlap is a
;; FRACTION rather than a count — 154 characters means something different at 512
;; than at 2,048, and comparing a fixed count across sizes would confound the two
;; variables. 0.15 is today's.
;; `--sizes` / `--overlaps` narrow the grid, which is what makes a MODEL
;; comparison affordable: the question "is this model better at Japanese" wants
;; one cell per model, not eighteen, and sweeping the grid again would confound
;; the model with the chunking.
(define SIZES
  (let ([v (arg-value "--sizes" #f)])
    (if v (map string->number (string-split v ",")) '(384 512 768 1024 1536 2048))))
(define OVERLAPS
  (let ([v (arg-value "--overlaps" #f)])
    (if v (map string->number (string-split v ",")) '(0.0 0.15 0.30))))
(define KS '(1 3 5))

(define repo-root
  (arg-value "--docs" (path->string (simplify-path (build-path impl-root 'up 'up) #f))))

(define (roots)
  (append (list (path->string (build-path repo-root "docs")))
          (for/list ([n '("README.md" "README.ja.md")]
                     #:when (file-exists? (build-path repo-root n)))
            (path->string (build-path repo-root n)))))

(define questions
  (let ([d (call-with-input-file (build-path impl-root "test" "calibration-questions.json")
             read-json)])
    (hash-ref d 'questions)))

;; Every answer path must exist, checked BEFORE a run that takes minutes: a typo
;; in the question set would otherwise be measured as a retrieval failure, and
;; the sweep would report the chunker getting worse.
(define (verify!)
  (define missing
    (for*/list ([q (in-list questions)]
                [k (in-list '(en_files ja_files))]
                [f (in-list (hash-ref q k '()))]
                #:unless (file-exists? (build-path repo-root f)))
      (format "~a: ~a" (hash-ref q 'id) f)))
  (unless (null? missing)
    (error 'calibrate "answer paths that do not exist:\n  ~a" (string-join missing "\n  ")))
  (printf "question set: ~a questions, every answer path exists\n" (length questions)))

;; ---- asking --------------------------------------------------------------------
;;
;; The QUESTION's embedding is cached across the whole sweep. It does not depend
;; on the chunking at all, so re-embedding it per cell would multiply the model
;; requests by eighteen and measure nothing — and a provider that answered
;; slightly differently on a later call would add noise to a comparison between
;; cells.
(define q-cache (make-hash))

(define (embed-question text)
  (hash-ref! q-cache text
             (lambda ()
               (define-values (vs _t _u _m) (embed-exchange (list text) #:who 'calibrate))
               (car vs))))

;; A hit counts when any of the acceptable files appears in the top k.
;;
;; A QUESTION THE EMBEDDER CANNOT PLACE IS SKIPPED AND COUNTED, NOT RAISED, and
;; a dry run against `mock-llm.rkt` is what found that: its bag-of-words script
;; buckets ASCII words, so every Japanese question embedded to a zero vector and
;; `help-nearest` correctly refused — which killed the sweep on question one of
;; the ja half, after the English half had already been measured. The same thing
;; is reachable with a real embedder (an empty or odd question answers a zero
;; vector), and a run that dies halfway through eighteen cells throws away every
;; cell before it. So it is reported in the row rather than being allowed to end
;; the measurement.
(define skipped (box '()))

(define (asked conn q locale k)
  (define text (hash-ref q (if (equal? locale "en") 'en 'ja)))
  (define want (hash-ref q (if (equal? locale "en") 'en_files 'ja_files) '()))
  (and (pair? want)
       (with-handlers ([exn:fail?
                        (lambda (e)
                          (define key (format "~a/~a" (hash-ref q 'id) locale))
                          (unless (member key (unbox skipped))
                            (set-box! skipped (cons key (unbox skipped))))
                          #f)])
         (let* ([rep (help-nearest conn (embed-question text) (embed-model)
                                   #:k k #:locale locale)]
                [paths (for/list ([h (in-list (hash-ref rep 'hits))]) (hash-ref h 'path))])
           (cons (for/or ([w (in-list want)]) (and (member w paths) #t))
                 paths)))))

(define (recall conn locale k)
  (define scored (filter values (for/list ([q (in-list questions)]) (asked conn q locale k))))
  (values (for/sum ([s (in-list scored)]) (if (car s) 1 0)) (length scored)))

;; ---- one cell ------------------------------------------------------------------

(define (fresh-db path)
  (when (file-exists? path) (delete-file path))
  (define conn ((db-connector (string-append "sqlite:///" path))))
  (migrate! conn all-migrations)
  conn)

(define (run-cell path size overlap-fraction)
  (define overlap (inexact->exact (round (* size overlap-fraction))))
  (define conn (fresh-db path))
  (define t0 (current-inexact-milliseconds))
  (define rep (help-ingest! conn (roots)
                            #:locales '("en" "ja")
                            #:size size #:overlap overlap
                            #:model (embed-model)
                            #:relative-to repo-root))
  (define ingest-ms (- (current-inexact-milliseconds) t0))
  (define row
    (for*/hash ([locale (in-list '("en" "ja"))] [k (in-list KS)])
      (define-values (hit n) (recall conn locale k))
      (values (string->symbol (format "~a@~a" locale k)) (cons hit n))))
  (define stats (help-stats conn))
  (printf "~a  overlap ~a (~a%)  chunks ~a/~a  ~a req  ~as~a\n"
          (~a size #:width 5) (~a overlap #:width 4)
          (inexact->exact (round (* 100 overlap-fraction)))
          (help-chunk-count conn "en") (help-chunk-count conn "ja")
          (hash-ref rep 'requests)
          (~r (/ ingest-ms 1000.0) #:precision 1)
          (let ([d (hash-ref rep 'dropped '())])
            (if (null? d) ""
                (format "  DROPPED ~a chunk(s) in ~a file(s)"
                        (for/sum ([e (in-list d)]) (length (cdr e))) (length d)))))
  (for ([locale (in-list '("en" "ja"))])
    (printf "        ~a  " locale)
    (for ([k (in-list KS)])
      (define e (hash-ref row (string->symbol (format "~a@~a" locale k))))
      (printf "r@~a ~a/~a (~a%)  " k (car e) (cdr e)
              (if (zero? (cdr e)) 0 (inexact->exact (round (* 100.0 (/ (car e) (cdr e))))))))
    (newline))
  (define out (hasheq 'size size 'overlap overlap 'overlap_fraction overlap-fraction
                      'chunks_en (help-chunk-count conn "en")
                      'chunks_ja (help-chunk-count conn "ja")
                      'requests (hash-ref rep 'requests)
                      'ingest_seconds (/ (round (* 10 (/ ingest-ms 1000.0))) 10.0)
                      'dropped (for/list ([e (in-list (hash-ref rep 'dropped '()))])
                                 (hasheq 'path (car e) 'indices (cdr e)))
                      'recall (for/hasheq ([(k v) (in-hash row)])
                                (values k (hasheq 'hit (car v) 'asked (cdr v))))))
  (help-clear! conn)
  out)

;; ---- main ----------------------------------------------------------------------

(module+ main
  (unless (embed-configured?)
    (error 'calibrate "set TMACH_EMBED_URL (and TMACH_EMBED_MODEL) — this needs a live embedder"))
  (verify!)
  (printf "corpus: ~a\nmodel:  ~a\ngrid:   ~a sizes x ~a overlaps = ~a cells\n\n"
          (string-join (roots) ", ") (embed-model)
          (length SIZES) (length OVERLAPS) (* (length SIZES) (length OVERLAPS)))
  (define path (path->string (make-temporary-file "telemachus-calibrate-~a.db")))
  (define results
    (for*/list ([size (in-list SIZES)] [ov (in-list OVERLAPS)])
      (run-cell path size ov)))
  (when (file-exists? path) (delete-file path))
  (define dest (build-path impl-root "test" "calibration-result.json"))
  (call-with-output-file dest #:exists 'truncate
    (lambda (o) (write-json (hasheq 'model (embed-model)
                                    'questions (length questions)
                                    'skipped (sort (unbox skipped) string<?)
                                    'cells results) o)))
  (unless (null? (unbox skipped))
    ;; Loud, because a skipped question silently lowers the denominator and a
    ;; reader comparing two runs would be comparing different question sets.
    (printf "\nSKIPPED (the embedder could not place these): ~a\n"
            (string-join (sort (unbox skipped) string<?) ", ")))
  (printf "\nwrote ~a\n" (path->string dest)))
