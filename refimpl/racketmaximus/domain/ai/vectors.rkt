#lang racket/base

;; domain/ai/vectors.rkt — the arithmetic a document-vector scan needs
;; (issue #189, build-plan step 1; decisions VEC-11…17).
;;
;; `docs/design/vector-store.md` is the evaluation this module is the first
;; piece of, and the two numbers that made it a module rather than a function:
;;
;;   100,000 comparisons at 768 dimensions
;;     `cosine` over boxed `vector`s   1,272 ms
;;     an `flvector` dot product         150 ms
;;
;; 8×, and the reason is not the algorithm: every component of a boxed vector is
;; a heap-allocated flonum, and `cosine` recomputes BOTH norms on every
;; comparison — for a query compared against N stored vectors that is N+1 norms
;; where one would do. For EMB-7's handful of labels that is exactly the right
;; trade and `cosine` is unchanged (VEC-14). For a scan it would be the whole
;; cost.
;;
;; NOTHING CALLS THIS YET, AND THAT IS THE BUILD PLAN'S OWN ORDERING. Step 4 is
;; the table and the write step in `plugins/doc-indexer`, step 5 the
;; nearest-chunk read; step 3 — the chunker — is the decision that wants a live
;; `nomic-embed-text` before anybody commits to a number. The arithmetic has no
;; such dependency and is measurable on its own, so it lands first, with its
;; tests, changing no behaviour.

(require racket/flonum)

(provide VEC-COMPONENT-BYTES
         vec-pack vec-unpack vec-width
         vec-normalize vec-unit? vec-dot vec-nearest)

;; ---- the stored form ---------------------------------------------------------
;;
;; VEC-13: FLOAT32 AT REST, FLONUM IN THE REGISTER. An embedding server answers
;; float32 — `nomic-embed-text` and every other checkpoint this would talk to —
;; so storing float64 would double the disk for digits the embedder never
;; produced. Racket has no f32vector arithmetic worth the name, so the decode
;; widens to a flonum `flvector` and the dot product runs there.
;;
;; 768 float32 is 3,072 bytes: the 39.2 MiB measured for 10,000 chunks, and the
;; reason VEC-2 could price one-row-per-chunk against paging at all.
(define VEC-COMPONENT-BYTES 4)

;; LITTLE-ENDIAN, PINNED, and not `(system-big-endian?)`. These bytes go into a
;; database file that is backed up, restored and replicated — #83's own argument
;; for why a column is the layer that survives being `SELECT`ed — and a dump
;; moved between architectures must decode to the same vectors or it decodes to
;; confident nonsense, which is EMB-8's failure mode with no model name to catch
;; it. Every machine this runs on is little-endian natively, so the pin costs
;; nothing today and is the whole protection on the day it does not.
(define LE #f)

(define (vec-pack fv)
  (define n (flvector-length fv))
  (define out (make-bytes (* n VEC-COMPONENT-BYTES)))
  (for ([i (in-range n)])
    (real->floating-point-bytes (flvector-ref fv i) VEC-COMPONENT-BYTES LE
                                out (* i VEC-COMPONENT-BYTES)))
  out)

;; A length that is not a whole number of components is not a vector of anything,
;; so it raises rather than truncating: a short read is the one corruption that
;; would otherwise produce a usable-looking answer of the wrong width, and
;; `vec-dot` would then report a mismatch somewhere far from the cause.
(define (vec-unpack bs)
  (unless (bytes? bs) (raise-argument-error 'vec-unpack "bytes?" bs))
  (define len (bytes-length bs))
  (unless (zero? (remainder len VEC-COMPONENT-BYTES))
    (error 'vec-unpack "~a byte(s) is not a whole number of float32 components" len))
  (define n (quotient len VEC-COMPONENT-BYTES))
  (define fv (make-flvector n 0.0))
  (for ([i (in-range n)])
    (flvector-set! fv i (real->double-flonum
                         (floating-point-bytes->real bs LE (* i VEC-COMPONENT-BYTES)
                                                     (* (add1 i) VEC-COMPONENT-BYTES)))))
  fv)

;; The width WITHOUT decoding, for a caller that only needs to know whether a row
;; belongs to this model's coordinate system — which in a scan is most rows, and
;; decoding one to find out is the cost the question exists to avoid.
(define (vec-width bs)
  (and (bytes? bs)
       (zero? (remainder (bytes-length bs) VEC-COMPONENT-BYTES))
       (quotient (bytes-length bs) VEC-COMPONENT-BYTES)))

;; ---- normalization -----------------------------------------------------------
;;
;; VEC-11: THE STORE IS NORMALIZED AT WRITE, SO THE READ IS A DOT PRODUCT.
;; For unit vectors the cosine IS the inner product, so normalizing once when a
;; chunk is written removes both square roots and both norm loops from every
;; later comparison — which is the half of the 8× that is not the boxing. It also
;; moves the one case that has no answer to the one place that can refuse it.
;;
;; A ZERO VECTOR HAS NO DIRECTION, so this answers #f rather than a vector of
;; zeros. Storing zeros would make it compare 0.0 against everything and read as
;; the WORST match, which is a claim; #f lets the write path refuse the chunk and
;; say why. `cosine`'s own rule (EMB-9's sibling), and reachable for the same
;; reason: providers really do answer a zero vector for empty input, and a
;; chunker will eventually hand one whitespace-only chunk to an embedder.
(define (vec-normalize fv)
  (define n (flvector-length fv))
  (cond
    [(zero? n) #f]
    [else
     (define norm
       (flsqrt (for/fold ([acc 0.0]) ([i (in-range n)])
                 (define x (flvector-ref fv i))
                 (fl+ acc (fl* x x)))))
     ;; `fl>` is false for +nan.0, so this one test covers a NaN component too — a
     ;; second explicit NaN guard would be #110 r1's redundant guard, the shape
     ;; that makes a reader believe the first one is missing.
     (and (fl> norm 0.0)
          (let ([out (make-flvector n 0.0)])
            (for ([i (in-range n)])
              (flvector-set! out i (fl/ (flvector-ref fv i) norm)))
            out))]))

;; The precondition `vec-dot` cannot check per comparison without paying for the
;; norm it exists to avoid. It is here for the WRITE path and for the tests, so
;; that "the store is normalized" is an assertion somebody makes rather than a
;; sentence in a comment. The tolerance is float32's, not float64's: the stored
;; form is float32, so a round-tripped unit vector is unit to about 1e-7.
(define (vec-unit? fv [tol 1e-6])
  (define n (flvector-length fv))
  (and (positive? n)
       (let ([sq (for/fold ([acc 0.0]) ([i (in-range n)])
                   (define x (flvector-ref fv i))
                   (fl+ acc (fl* x x)))])
         (< (abs (- sq 1.0)) tol))))

;; ---- the comparison ----------------------------------------------------------
;;
;; VEC-12: THIS IS A DOT PRODUCT AND IT IS ONLY A SIMILARITY WHEN BOTH SIDES ARE
;; UNIT VECTORS, which is why that is the store's invariant and not a hope. On
;; un-normalized input it answers the inner product, honestly and uselessly —
;; the two are different mathematical objects, and this one is the cheap one.
;; That is the whole reason `cosine` stays where it is rather than being replaced
;; by this (VEC-14): a shared implementation would have to be the general one,
;; which is the slow one, and the drift `executor-can-run?` warns about does not
;; apply to two functions that compute different things and say so.
;;
;; VEC-15: A WIDTH MISMATCH ANSWERS #f AND NEVER RAISES. In a scan one row of
;; the wrong width is a row from before a model change — EMB-8 discards a
;; mismatched cache whole, and the store is keyed by model, so by the time a
;; mismatch is seen at read it is a survivor rather than a surprise. It must not
;; take a query down with it; `vec-nearest` counts them instead, because a scan
;; that silently returned fewer results would be a recall problem nobody could
;; see.
(define (vec-dot a b)
  (define n (flvector-length a))
  (and (= n (flvector-length b))
       (positive? n)
       (for/fold ([acc 0.0]) ([i (in-range n)])
         (fl+ acc (fl* (flvector-ref a i) (flvector-ref b i))))))

;; `rows` is a sequence of `(cons key packed-bytes)`; the query is an flvector.
;; -> (values hits skipped), hits a list of `(cons key score)`, highest first.
;;
;; VEC-16: ONE PASS WITH A BOUNDED INSERTION, NOT A SORT OF N. At 100,000 chunks
;; the scan itself is 150 ms of arithmetic; sorting 100,000 scored pairs to take
;; ten of them would add allocation of the same order for an answer the loop
;; already has. The kept list is at most `k` long, so the insertion is bounded by
;; k and not by N.
;;
;; The authorization rule is deliberately NOT here (VEC-9): the window is bounded
;; in SQL and `can?` is applied per row AFTER the scan, which is `search.rkt`'s
;; rule and CLS-27's consequence. This function is given rows and knows nothing
;; about who asked — the same reason the blob store is never handed a principal.
(define (vec-nearest query rows k)
  (define qn (flvector-length query))
  (cond
    [(or (not (exact-positive-integer? k)) (zero? qn)) (values '() 0)]
    [else
     (let loop ([rows rows] [kept '()] [n 0] [skipped 0])
       (cond
         [(null? rows)
          (values (sort kept > #:key cdr) skipped)]
         [else
          (define row (car rows))
          (define key (car row))
          (define bs (cdr row))
          (define w (vec-width bs))
          (cond
            ;; the width check is on the BYTES, so a row from another model costs
            ;; a remainder and not a decode
            [(not (equal? w qn))
             (loop (cdr rows) kept n (add1 skipped))]
            [else
             (define s (vec-dot query (vec-unpack bs)))
             (cond
               [(not s) (loop (cdr rows) kept n (add1 skipped))]
               [(< n k) (loop (cdr rows) (cons (cons key s) kept) (add1 n) skipped)]
               [else
                (define worst (for/fold ([w #f]) ([e (in-list kept)])
                                (if (or (not w) (< (cdr e) (cdr w))) e w)))
                (if (> s (cdr worst))
                    (loop (cdr rows) (cons (cons key s) (remq worst kept)) n skipped)
                    (loop (cdr rows) kept n skipped))])])]))]))
