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

(test-case "a loopback peer behind a proxy is not the box itself"
  ;; `tailscale serve`, nginx and caddy all connect from 127.0.0.1 on behalf of
  ;; whoever called them
  (check-true  (peer-trusted? "127.0.0.1" '() #:forwarded? #f))
  (check-false (peer-trusted? "127.0.0.1" '() #:forwarded? #t)
               "a forwarded request is not local, whatever its peer address")
  (check-false (peer-trusted? "::1" '() #:forwarded? #t))
  ;; a proxy the operator named is trusted to assert identity, and forwards as
  ;; a matter of course
  (check-true  (peer-trusted? "10.0.0.5" '("10.0.0.5") #:forwarded? #t))
  (check-true  (peer-trusted? "127.0.0.1" '("127.0.0.1") #:forwarded? #t)
               "naming loopback is the operator vouching for the proxy on it")
  ;; the switch withdraws loopback's standing, forwarded or not
  (check-false (peer-trusted? "127.0.0.1" '() #:loopback? #f))
  (check-true  (peer-trusted? "10.0.0.5" '("10.0.0.5") #:loopback? #f)
               "the allowlist does not depend on the switch"))

(test-case "the loopback switch is on unless switched off by name"
  (check-true  (loopback-trust-on? #f))
  (check-true  (loopback-trust-on? ""))
  (check-true  (loopback-trust-on? "1"))
  (check-true  (loopback-trust-on? "banana") "an unrecognised value keeps the default")
  (check-false (loopback-trust-on? "off"))
  (check-false (loopback-trust-on? " OFF "))
  (check-false (loopback-trust-on? "0"))
  (check-false (loopback-trust-on? "false"))
  (check-false (loopback-trust-on? "no")))

(test-case "the headers a proxy adds are lower-case bytes, as the reader matches them"
  (for ([h (in-list FORWARDING-HEADERS)])
    (check-true (bytes? h))
    (check-equal? h (string->bytes/utf-8 (string-downcase (bytes->string/utf-8 h)))))
  (check-true (and (member #"x-forwarded-for" FORWARDING-HEADERS) #t))
  (check-true (and (member #"forwarded" FORWARDING-HEADERS) #t)))

(test-case "the allowlist is a list, forgiving of spacing"
  (check-equal? (parse-peer-allowlist "10.0.0.5") '("10.0.0.5"))
  (check-equal? (parse-peer-allowlist " 10.0.0.5 , 10.0.0.6 ") '("10.0.0.5" "10.0.0.6"))
  (check-equal? (parse-peer-allowlist "") '())
  (check-equal? (parse-peer-allowlist #f) '())
  (check-equal? (parse-peer-allowlist ",,") '()))

(test-case "an address a proxy reports is believed only from a proxy the operator named"
  (define P '("127.0.0.1"))
  ;; nothing configured: the peer, whatever the header says
  (check-equal? (forwarded-client-ip "127.0.0.1" '("203.0.113.9") '()) "127.0.0.1")
  ;; a stranger sending the header directly gets no say in their own address
  (check-equal? (forwarded-client-ip "198.51.100.4" '("203.0.113.9") P) "198.51.100.4")
  (check-equal? (forwarded-client-ip #f '("203.0.113.9") P) #f)
  ;; from the named proxy, the address it reported
  (check-equal? (forwarded-client-ip "127.0.0.1" '("203.0.113.9") P) "203.0.113.9")
  ;; a trusted proxy that sent no header is still just the peer
  (check-equal? (forwarded-client-ip "127.0.0.1" '() P) "127.0.0.1"))

(test-case "the address is read from the right, so the caller cannot forge it"
  (define P '("127.0.0.1"))
  ;; the caller typed 10.9.9.9; our proxy appended where the request really came from
  (check-equal? (forwarded-client-ip "127.0.0.1" '("10.9.9.9, 203.0.113.9") P) "203.0.113.9")
  ;; the same when the caller's header arrived as a line of its own
  (check-equal? (forwarded-client-ip "127.0.0.1" '("10.9.9.9" "203.0.113.9") P) "203.0.113.9")
  ;; a chain of two trusted proxies: skip ours, take the first that is not
  (check-equal? (forwarded-client-ip "127.0.0.1" '("203.0.113.9, 10.0.0.5") '("127.0.0.1" "10.0.0.5"))
                "203.0.113.9")
  ;; every hop is one of ours: the request began on a proxy, so the peer
  (check-equal? (forwarded-client-ip "127.0.0.1" '("10.0.0.5") '("127.0.0.1" "10.0.0.5")) "127.0.0.1"))

(test-case "a hop that is not an address answers the peer, never a key the caller chose"
  (define P '("127.0.0.1"))
  (check-equal? (forwarded-client-ip "127.0.0.1" '("203.0.113.9, unknown") P) "127.0.0.1")
  (check-equal? (forwarded-client-ip "127.0.0.1" '("") P) "127.0.0.1")
  (check-equal? (forwarded-client-ip "127.0.0.1" '("x\r\nInjected: 1") P) "127.0.0.1"))

(test-case "one forwarded entry, in the forms proxies write"
  (check-equal? (forwarded-address " 203.0.113.9 ") "203.0.113.9")
  (check-equal? (forwarded-address "203.0.113.9:51234") "203.0.113.9")
  (check-equal? (forwarded-address "2001:DB8::1") "2001:db8::1")
  (check-equal? (forwarded-address "[2001:db8::1]:51234") "2001:db8::1")
  (check-equal? (forwarded-address "[2001:db8::1]") "2001:db8::1")
  (check-false (forwarded-address "unknown"))
  (check-false (forwarded-address "_hidden"))
  (check-false (forwarded-address ""))
  (check-false (forwarded-address (make-string 80 #\1)))
  (check-false (forwarded-address #f)))
