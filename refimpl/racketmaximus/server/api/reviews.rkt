#lang racket/base

;; server/api/reviews.rkt — the human-review queue (LAY-1...3) and its
;; accuracy report
;;
;; Split out of main.rkt by #110 r3. The shared surface every handler here
;; needs — the pool, the request accessors, with-auth/with-mt, the response
;; constructors — is server/kit.rkt.

(provide ep-reviews-list ep-review-stats ep-review-verify ep-review-get
         ep-review-decide)

(require racket/string
         web-kit
         (only-in "../../domain/authz/authz.rkt" require-perm)
         (only-in "../../domain/flow/spec.rkt" REVIEW-VERDICTS)
         (only-in "../../domain/review/review.rkt" review-count-pending review-decide! review-get review-list review-stats review-verify)
         "../kit.rkt")

;; ---- reviews (LAY-1…3) ---------------------------------------------------------
(define (ep-reviews-list req)
  (with-auth req (lambda (p)
    (require-perm db-conn p "reviews:read")
    (define st (let ([v (query-param req "status" "pending")]) (if (string=? v "") "pending" v)))
    (json-response (hasheq 'reviews (review-list db-conn p #:status st)
                           'pending (review-count-pending db-conn p))))))

(define (ep-review-stats req)
  (with-auth req (lambda (p)
    (require-perm db-conn p "reviews:read")
    (define since (string->number (query-param req 'since "")))
    (json-response (hasheq 'stats (review-stats db-conn p #:since since)
                           'since (or since 0))))))

(define (ep-review-verify req)
  (with-auth req (lambda (p)
    (require-perm db-conn p "audit:read")
    (json-response (review-verify db-conn p)))))

(define (ep-review-get req id)
  (with-auth req (lambda (p)
    (require-perm db-conn p "reviews:read")
    (define r (review-get db-conn p id))
    (if r (json-response r) (err "no such review" 404)))))

(define (ep-review-decide req id)
  (with-auth req (lambda (p)
    (require-perm db-conn p "reviews:decide")
    (define b (read-json-body req))
    (define verdict (fmt b 'verdict))
    (define rationale (fmt b 'rationale))
    (define answers (let ([a (hash-ref b 'answers (hasheq))]) (if (hash? a) a (hasheq))))
    (define out (review-decide! db-conn p id verdict #:rationale rationale #:answers answers))
    (cond
      [(eq? out 'no-such-review) (err "no such review" 404)]
      [(eq? out 'already-decided) (err "this review has already been decided" 409)]
      [(eq? out 'bad-verdict) (err (format "verdict must be one of ~a" (string-join REVIEW-VERDICTS ", ")) 400)]
      ;; 403, not 400: the request is well-formed and the caller holds the
      ;; permission — they are simply the wrong person for this one item
      [(eq? out 'needs-another-reviewer)
       (err "this review needs a second pair of eyes: its author may not decide it" 403)]
      [(eq? out 'needs-rationale) (err "a rationale is required to send work back or reject it" 400)]
      [(string? out) (err out 400)]
      [else (json-response out)]))))
