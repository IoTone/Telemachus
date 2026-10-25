#lang racket/base

;; test/plugin-route-tests.rkt — what a plugin route lets a handler read and
;; return.  raco test test/plugin-route-tests.rkt

(require rackunit
         web-server/http
         web-kit
         "../server/plugin-route.rkt")

;; ---- request headers ---------------------------------------------------------

(test-case "headers are lowercased, and a repeated field keeps the first value"
  (define h (headers->hash (list (make-header #"If-Match" #"\"3\"")
                                 (make-header #"X-Ops-Key" #"abc")
                                 (make-header #"if-match" #"\"9\""))))
  (check-equal? (hash-ref h "if-match") "\"3\"")
  (check-equal? (hash-ref h "x-ops-key") "abc")
  (check-equal? (hash-count h) 2))

(test-case "no headers is an empty hash, not #f"
  (check-equal? (headers->hash '()) (hash)))

(test-case "a header that is not UTF-8 does not raise inside the route"
  (define h (headers->hash (list (make-header #"X-Bin" #"\xff\xfe"))))
  (check-true (hash-has-key? h "x-bin")))

;; ---- what a handler may return ----------------------------------------------

(test-case "a returned response keeps its status and headers"
  (define r (plugin-route-response
             (json-response (hasheq 'error "conflict: revision is stale")
                            #:code 409
                            #:headers (list (make-header #"Retry-After" #"5")))))
  (check-equal? (response-code r) 409)
  (check-equal? (header-value (headers-assq* #"Retry-After" (response-headers r)) ) #"5"))

(test-case "a jsexpr is still a 200"
  (check-equal? (response-code (plugin-route-response (hasheq 'ok #t))) 200))

(test-case "a value that is not JSON-shaped is stringified under result"
  (define r (plugin-route-response 'sym))
  (check-equal? (response-code r) 200))

(test-case "a boolean is JSON, not a string"
  (check-equal? (response-code (plugin-route-response #t)) 200))
