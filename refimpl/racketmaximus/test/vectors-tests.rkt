#lang racket/base

;; test/vectors-tests.rkt — the document-vector arithmetic (issue #189 step 1).
;;
;;   raco test test/vectors-tests.rkt
;;
;; Nothing in production calls `domain/ai/vectors.rkt` yet — step 4 is the table
;; and the write step, step 5 the read — so this file is the only thing holding
;; it to its contract, and it is written on that understanding. The two
;; properties that matter most are the ones a later caller would otherwise
;; discover the expensive way:
;;
;;   * the STORED FORM is pinned byte for byte, because it goes into a database
;;     that is dumped, restored and replicated, and a decode that disagrees with
;;     the encode produces plausible numbers rather than an error
;;   * a dot product of two UNIT vectors equals `cosine` of the same two
;;     vectors, which is what makes the fast primitive and the general one two
;;     spellings of one answer rather than a drift (VEC-14)

(require rackunit racket/flonum
         "../domain/ai/vectors.rkt"
         (only-in "../domain/ai/embedstore.rkt" cosine))

(define (fv . xs) (for/flvector ([x (in-list xs)]) (real->double-flonum x)))
(define (boxed fv) (for/vector ([i (in-range (flvector-length fv))]) (flvector-ref fv i)))
(define (close? a b [tol 1e-6]) (and a b (< (abs (- a b)) tol)))

;; ---- the stored form ---------------------------------------------------------

(test-case "the packed form is float32, little-endian, and pinned"
  ;; 1.0 as IEEE-754 float32 is 0x3F800000; little-endian puts 0x3F last.
  ;; This literal is the on-disk contract: if it changes, every stored vector on
  ;; every instance decodes to something else.
  (check-equal? (vec-pack (fv 1.0)) (bytes #x00 #x00 #x80 #x3f))
  (check-equal? (vec-pack (fv 0.0)) (bytes 0 0 0 0))
  (check-equal? (vec-pack (fv 1.0 -2.0))
                (bytes #x00 #x00 #x80 #x3f #x00 #x00 #x00 #xc0))
  (check-equal? VEC-COMPONENT-BYTES 4)
  ;; NOTE ON WHAT THIS CANNOT CATCH: replacing the pinned `#f` with
  ;; `(system-big-endian?)` is undetectable on a little-endian machine, which is
  ;; every machine anybody runs this on. The literals above catch an inverted
  ;; pin; only a big-endian host could catch an unpinned one.
  )

(test-case "a vector round-trips through the stored form"
  (define v (fv 0.5 -0.25 0.125))
  (define back (vec-unpack (vec-pack v)))
  (check-equal? (flvector-length back) 3)
  ;; these three are exact in float32, so the round trip is exact
  (check-equal? (flvector-ref back 0) 0.5)
  (check-equal? (flvector-ref back 1) -0.25)
  (check-equal? (flvector-ref back 2) 0.125)
  ;; and an ordinary value survives to float32's precision, not float64's
  (define w (vec-unpack (vec-pack (fv 0.1))))
  (check-true (< (abs (- (flvector-ref w 0) 0.1)) 1e-7)))

(test-case "a length that is not a whole number of components raises"
  ;; the one corruption that would otherwise decode to a usable vector of the
  ;; wrong width, and then be reported as a mismatch far from its cause
  (check-exn exn:fail? (lambda () (vec-unpack (bytes 1 2 3))))
  (check-exn exn:fail? (lambda () (vec-unpack (bytes 1 2 3 4 5))))
  (check-equal? (flvector-length (vec-unpack (bytes))) 0))

(test-case "the width is answered without decoding"
  (check-equal? (vec-width (vec-pack (fv 1.0 2.0 3.0))) 3)
  (check-equal? (vec-width (bytes)) 0)
  (check-false (vec-width (bytes 1 2 3)))
  (check-false (vec-width "not bytes"))
  (check-false (vec-width #f)))

;; ---- normalization -----------------------------------------------------------

(test-case "normalize answers a unit vector"
  (define u (vec-normalize (fv 3.0 4.0)))
  (check-true (vec-unit? u))
  (check-true (close? (flvector-ref u 0) 0.6))
  (check-true (close? (flvector-ref u 1) 0.8))
  ;; direction is preserved, which is the whole point
  (check-true (close? (cosine (boxed (fv 3.0 4.0)) (boxed u)) 1.0)))

(test-case "a zero vector has no direction, so normalize answers #f"
  ;; NOT a vector of zeros: that would compare 0.0 against everything and read
  ;; as the WORST match, which is a claim. `cosine`'s own rule, and reachable —
  ;; a provider answers a zero vector for empty input.
  (check-false (vec-normalize (fv 0.0 0.0 0.0)))
  (check-false (vec-normalize (fv)))
  (check-false (vec-normalize (fv +nan.0 1.0))))

(test-case "a unit vector is still unit after a round trip through float32"
  ;; this is what lets the read be a bare dot product: the invariant has to
  ;; survive the stored form, not just the normalizer
  (define u (vec-normalize (fv 0.3 -0.7 0.21 0.9 -0.04)))
  (check-true (vec-unit? u))
  (check-true (vec-unit? (vec-unpack (vec-pack u))))
  ;; …and the tolerance really is float32's: float64's would be too tight
  (check-false (vec-unit? (vec-unpack (vec-pack u)) 1e-12)))

;; ---- the comparison ----------------------------------------------------------

(test-case "for unit vectors the dot product IS the cosine"
  ;; the property that makes VEC-14 a decision rather than a duplication
  (for ([pair (in-list (list (cons (fv 1.0 2.0 3.0) (fv -1.0 0.5 2.0))
                             (cons (fv 0.1 0.0 0.0) (fv 0.0 0.1 0.0))
                             (cons (fv 5.0 5.0) (fv -5.0 5.0))))])
    (define a (car pair))
    (define b (cdr pair))
    (check-true (close? (vec-dot (vec-normalize a) (vec-normalize b))
                        (cosine (boxed a) (boxed b)))
                "a unit dot product disagrees with cosine")))

(test-case "the dot product is NOT the cosine of un-normalized input"
  ;; stated as a test because it is the precondition the write path exists to
  ;; keep: somebody who drops normalization gets numbers, not an error
  (define a (fv 3.0 4.0))
  (define b (fv 6.0 8.0))
  (check-true (close? (cosine (boxed a) (boxed b)) 1.0))
  (check-true (close? (vec-dot a b) 50.0)))

(test-case "a width mismatch answers #f and does not raise"
  ;; VEC-15: in a scan this is a row from before a model change, and it must not
  ;; take the query down with it
  (check-false (vec-dot (fv 1.0 2.0) (fv 1.0 2.0 3.0)))
  (check-false (vec-dot (fv) (fv)))
  (check-true (close? (vec-dot (fv 1.0 0.0) (fv 1.0 0.0)) 1.0)))

;; ---- the scan ----------------------------------------------------------------

(define (row key fv) (cons key (vec-pack (vec-normalize fv))))

(test-case "the nearest rows come back highest first, bounded by k"
  (define q (vec-normalize (fv 1.0 0.0)))
  (define rows (list (row 'right (fv 1.0 0.0))         ; dot  1.0
                     (row 'diag  (fv 1.0 1.0))         ; dot  0.707
                     (row 'up    (fv 0.0 1.0))         ; dot  0.0
                     (row 'back  (fv -1.0 0.0))))      ; dot -1.0
  (define-values (hits skipped) (vec-nearest q rows 2))
  (check-equal? skipped 0)
  (check-equal? (map car hits) '(right diag))
  (check-true (close? (cdr (car hits)) 1.0))
  ;; k larger than the row count answers every row, still ordered
  (define-values (all _s) (vec-nearest q rows 10))
  (check-equal? (map car all) '(right diag up back))
  ;; and the whole ordering is non-increasing
  (check-true (for/and ([a (in-list all)] [b (in-list (cdr all))]) (>= (cdr a) (cdr b)))))

(test-case "a row of another width is skipped AND counted"
  ;; counted, because a scan that silently returned fewer results would be a
  ;; recall problem nobody could see
  (define q (vec-normalize (fv 1.0 0.0)))
  (define rows (list (row 'ok (fv 1.0 0.0))
                     (cons 'other-model (vec-pack (vec-normalize (fv 1.0 0.0 0.0))))
                     (cons 'truncated (bytes 1 2 3))
                     (row 'also-ok (fv 0.0 1.0))))
  (define-values (hits skipped) (vec-nearest q rows 10))
  (check-equal? skipped 2)
  (check-equal? (map car hits) '(ok also-ok)))

(test-case "the scan's degenerate cases answer nothing rather than raising"
  (define q (vec-normalize (fv 1.0 0.0)))
  (define-values (h0 s0) (vec-nearest q '() 5))
  (check-equal? h0 '())
  (check-equal? s0 0)
  (define-values (h1 s1) (vec-nearest q (list (row 'a (fv 1.0 0.0))) 0))
  (check-equal? h1 '())
  (define-values (h2 s2) (vec-nearest (fv) (list (row 'a (fv 1.0 0.0))) 5))
  (check-equal? h2 '()))

(test-case "the kept set is never larger than k, however the scores arrive"
  ;; VEC-16's bound, exercised in both orders: ascending scores make every row an
  ;; insertion, descending make every row after the first a rejection
  (define q (vec-normalize (fv 1.0 0.0)))
  (define (at angle) (vec-normalize (fv (cos angle) (sin angle))))
  (define asc (for/list ([i (in-range 50)]) (cons i (vec-pack (at (- 1.5 (* i 0.03)))))))
  (define-values (ha _a) (vec-nearest q asc 3))
  (check-equal? (length ha) 3)
  (check-equal? (map car ha) '(49 48 47))
  (define-values (hd _d) (vec-nearest q (reverse asc) 3))
  (check-equal? (map car hd) '(49 48 47)))
