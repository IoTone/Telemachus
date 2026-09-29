#lang racket/base

;; test/peer-tests.rkt — who may log in with a header (issue #40).
;;   raco test test/peer-tests.rkt

(require rackunit "../domain/authz/peer.rkt")

(test-case "loopback, in the forms a listener actually reports"
  (check-true (loopback-address? "127.0.0.1"))
  (check-true (loopback-address? "127.0.0.53"))        ; the whole 127/8 block
  (check-true (loopback-address? "::1"))
  (check-true (loopback-address? "::ffff:127.0.0.1"))  ; v4-mapped, dual-stack listener
  (check-false (loopback-address? "10.0.0.5"))
  (check-false (loopback-address? "192.168.1.20"))
  (check-false (loopback-address? "1.127.0.0"))        ; not a prefix match on the wrong end
  (check-false (loopback-address? ""))
  (check-false (loopback-address? #f)))

(test-case "a remote peer is not trusted, however private its address looks"
  (check-true (peer-trusted? "127.0.0.1" '()))
  ;; the bug this closes: an instance bound to 0.0.0.0 took identity headers from
  ;; anyone who could reach it
  (check-false (peer-trusted? "10.0.0.5" '()) "a LAN address is still a stranger")
  (check-false (peer-trusted? "192.168.1.20" '()))
  (check-false (peer-trusted? "203.0.113.7" '()))
  (check-false (peer-trusted? #f '()) "no peer address at all is not a licence")
  ;; …unless the operator named it
  (check-true (peer-trusted? "10.0.0.5" '("10.0.0.5")))
  (check-false (peer-trusted? "10.0.0.6" '("10.0.0.5")) "one address, not its neighbours"))

(test-case "the allowlist is a list, forgiving of spacing"
  (check-equal? (parse-peer-allowlist "10.0.0.5") '("10.0.0.5"))
  (check-equal? (parse-peer-allowlist " 10.0.0.5 , 10.0.0.6 ") '("10.0.0.5" "10.0.0.6"))
  (check-equal? (parse-peer-allowlist "") '())
  (check-equal? (parse-peer-allowlist #f) '())
  (check-equal? (parse-peer-allowlist ",,") '()))
