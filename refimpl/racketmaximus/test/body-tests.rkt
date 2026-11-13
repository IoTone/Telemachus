#lang racket/base

;; test/body-tests.rkt — what a JSON request body reads as (server/body.rkt).
;;
;;   raco test test/body-tests.rkt
;;
;; The HTTP half is test/body-shape-sweep.py, driven by server-smoke.sh over
;; every write route in the table; this file pins the rule itself, with no server.

(require rackunit "../server/body.rkt")

(define (b s) (string->bytes/utf-8 s))

(test-case "a core handler always reads an object"
  (check-equal? (json-body-object (b "{\"a\":1}")) (hasheq 'a 1))
  ;; the four shapes that used to reach a `hash-ref` and answer 500
  (for ([s (in-list '("\"x\"" "[1]" "1" "null" "true"))])
    (check-equal? (json-body-object (b s)) (hasheq) s))
  ;; …and what already read as empty still does
  (check-equal? (json-body-object (b "{not json")) (hasheq) "malformed")
  (check-equal? (json-body-object #"") (hasheq) "empty")
  (check-equal? (json-body-object #f) (hasheq) "absent"))

(test-case "a plugin route still receives whatever JSON value was sent"
  ;; its 'body is a published contract that never promised an object
  (check-equal? (json-body-value (b "[1,2]")) '(1 2))
  (check-equal? (json-body-value (b "\"x\"")) "x")
  (check-equal? (json-body-value (b "{\"a\":1}")) (hasheq 'a 1))
  (check-equal? (json-body-value (b "{not json")) (hasheq) "malformed is still empty")
  (check-equal? (json-body-value #f) (hasheq) "absent is still empty"))
