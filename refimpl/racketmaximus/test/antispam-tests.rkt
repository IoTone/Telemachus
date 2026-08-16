#lang racket/base

;; test/antispam-tests.rkt — the self-hosted anti-abuse layers, driven with an
;; explicit clock so they're fully deterministic.  raco test test/antispam-tests.rkt

(require rackunit "../domain/beta/antispam.rkt")

(test-case "rate limiter: sliding window per key"
  (define lim (make-limiter))
  (for ([i (in-range 5)]) (check-true (limiter-allow? lim "ip1" 100 #:max 5 #:window 60)))
  (check-false (limiter-allow? lim "ip1" 100 #:max 5 #:window 60))   ; 6th in-window → blocked
  (check-true (limiter-allow? lim "ip1" 200 #:max 5 #:window 60))    ; window elapsed → ok
  (check-true (limiter-allow? lim "ip2" 100 #:max 5 #:window 60)))   ; different key unaffected

(test-case "challenge: ok / replay / too-fast / expired / bad-sig / malformed"
  (define used (new-used-set))
  (define tok (hash-ref (issue-challenge #:secret "s" #:now 1000) 'challenge))
  (check-equal? (verify-challenge tok #:secret "s" #:now 1005 #:used used) 'ok)
  (check-equal? (verify-challenge tok #:secret "s" #:now 1006 #:used used) 'replay)      ; single-use
  (define t2 (hash-ref (issue-challenge #:secret "s" #:now 2000) 'challenge))
  (check-equal? (verify-challenge t2 #:secret "s" #:now 2000 #:used (new-used-set)) 'too-fast)
  (check-equal? (verify-challenge t2 #:secret "s" #:now 99999 #:used (new-used-set)) 'expired)
  (check-equal? (verify-challenge t2 #:secret "WRONG" #:now 2005 #:used (new-used-set)) 'bad-sig)
  (check-equal? (verify-challenge "garbage" #:secret "s" #:now 2005 #:used (new-used-set)) 'malformed))

(test-case "proof of work: solve + verify (deterministic)"
  (define n "abc123")
  (define sol (pow-of n 12))
  (check-true (verify-pow n sol 12))
  (check-true (verify-pow n 0 0))                       ; difficulty 0 → always valid
  (check-equal? (powhash "abc:5") (powhash "abc:5")))   ; hash is deterministic (matches the JS impl)

(test-case "email heuristics"
  (check-true (valid-email? "a@b.com"))
  (check-false (valid-email? "nope"))
  (check-false (valid-email? "a@b"))
  (check-true (disposable-email? "x@Mailinator.com"))
  (check-false (disposable-email? "cto@acme.com"))
  (check-true (free-email? "x@gmail.com"))
  (check-false (free-email? "cto@acme.com"))
  (check-equal? (email-domain "X@Foo.COM") "foo.com"))

(test-case "blocked counters"
  (bump-blocked! "rate") (bump-blocked! "rate") (bump-blocked! "honeypot")
  (check-equal? (hash-ref (blocked-stats) "rate") 2)
  (check-equal? (hash-ref (blocked-stats) "honeypot") 1))
