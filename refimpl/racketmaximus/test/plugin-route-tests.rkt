#lang racket/base

;; test/plugin-route-tests.rkt — what a plugin route lets a handler read and
;; return.  raco test test/plugin-route-tests.rkt

(require rackunit
         racket/port
         web-server/http
         web-kit
         "../server/plugin-route.rkt"
         ;; G13: the loader's route contract, which decides the door. Requiring it
         ;; here is what `test/plugin-dirs-tests.rkt` already does; neither
         ;; instantiates the connection pool (server/kit.rkt), which is the rule
         ;; #123 records — CI's SQLite leg sets DATABASE_URL to the empty string
         ;; and a test that required kit would fail there and nowhere else.
         "../domain/agent/plugins.rkt")

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

;; ---- the two doors (G13) ----------------------------------------------------
;; A route is 'bearer or 'public, and the whole difference is which arguments its
;; handler is called with. The loader refuses a handler whose arity does not fit
;; the declaration, so these two cases together say that a public handler cannot
;; be handed a principal — it has nowhere to put one.

(define (body-of r)
  (define o (open-output-string))
  ((response-output r) o)
  (get-output-string o))

(test-case "a public handler is called with (conn args) and keeps its own media type"
  (define seen #f)
  (define r (plugin-route-call 'public
                               (lambda (conn args)
                                 (set! seen args)
                                 (response/output #:code 200 #:mime-type #"text/calendar; charset=utf-8"
                                                  (lambda (out) (write-string "BEGIN:VCALENDAR" out))))
                               'the-connection #f (hasheq 'params (hasheq))))
  (check-equal? (response-code r) 200)
  (check-equal? (response-mime r) #"text/calendar; charset=utf-8")
  (check-equal? (body-of r) "BEGIN:VCALENDAR")
  ;; two arguments, and the second is the args hash: there is no third to hold a
  ;; principal, which is the property rather than a convention — and `check-route!`
  ;; refuses a three-argument handler declared public (case below).
  (check-true (hash? seen)))

(test-case "a bearer route still gets its principal and still answers JSON"
  (define r (plugin-route-call 'bearer
                               (lambda (conn principal args)
                                 (response/output #:code 200 #:mime-type #"text/plain; charset=utf-8"
                                                  (lambda (out) (write-string principal out))))
                               'the-connection "user-1" (hasheq)))
  (check-equal? (body-of r) "user-1")
  ;; and a jsexpr is still a 200 application/json, unchanged
  (define j (plugin-route-call 'bearer (lambda (c p a) (hasheq 'ok #t)) 'conn "u" (hasheq)))
  (check-equal? (response-code j) 200)
  (check-equal? (response-mime j) #"application/json; charset=utf-8"))

;; ---- what the loader refuses at LOAD, not at request time -------------------

(test-case "a route that says nothing about auth is a bearer route"
  (define r (check-route! "demo" (list "GET" "/x" #f (lambda (c p a) (hasheq)) "doc")))
  (check-equal? (hash-ref r 'auth) 'bearer)
  (check-equal? (hash-ref r 'doc) "doc"))

(test-case "a permission that is not a string is refused, and the message names it"
  ;; This branch existed before G13 and had never been exercised: its format
  ;; string had one directive for two arguments, so it would have failed with a
  ;; format error instead of naming the route. Pinned from the outside.
  (check-exn #rx"not 7"
             (lambda () (check-route! "demo" (list "GET" "/x" 7 (lambda (c p a) #t) "")))))

(test-case "a route may declare itself public"
  (define r (check-route! "demo" (list "GET" "/feed.ics" #f (lambda (c a) (hasheq 'ok #t)) "doc" 'public)))
  (check-equal? (hash-ref r 'auth) 'public))

(test-case "an auth value outside the closed vocabulary is refused, naming it"
  (check-exn #rx"must be one of"
             (lambda () (check-route! "demo" (list "GET" "/x" #f (lambda (c p a) #t) "" 'oauth)))))

(test-case "a public route may not name a permission: there is no principal to check it against"
  (check-exn #rx"public and names permission"
             (lambda () (check-route! "demo" (list "GET" "/x" "files:read" (lambda (c a) #t) "" 'public)))))

(test-case "a public route whose handler takes a principal is refused at load"
  (check-exn #rx"not a principal"
             (lambda () (check-route! "demo" (list "GET" "/x" #f (lambda (c p a) #t) "" 'public)))))

(test-case "a bearer route whose handler cannot take a principal is refused at load"
  (check-exn #rx"must take .conn principal args."
             (lambda () (check-route! "demo" (list "GET" "/x" #f (lambda (c a) #t) "")))))
