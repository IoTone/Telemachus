#lang racket/base

;; test/route-shape-tests.rkt — a route's declared request shape (#227 slice 2b).
;;
;; No server and no database: `body-problems` lives in server/body.rkt for the
;; reason that module exists (a test that requires kit.rkt instantiates the pool,
;; and CI's SQLite leg sets DATABASE_URL to the empty string — #123). That the
;; DISPATCHER asks it is established over HTTP, by test/server-smoke.sh's
;; "request shapes" block, and controlled there.

(require rackunit racket/list racket/string json
         "../server/body.rkt"
         "../server/routes.rkt")

(define (bytes-of v) (string->bytes/utf-8 (jsexpr->string v)))

;; the shape a declared route uses, written out rather than borrowed from the
;; table, so these cases test the CHECK and not one route's current declaration
(define shape
  (hasheq 'type "object"
          'properties (hasheq 'name (hasheq 'type "string")
                              'limit (hasheq 'type "integer")
                              'tags (hasheq 'type "array" 'items (hasheq 'type "string")))
          'required '("name")
          'additionalProperties #t))

(test-case "a conforming body has no problems, and an open shape ignores a field it does not name"
  (check-equal? (body-problems shape (bytes-of (hasheq 'name "x" 'limit 3 'tags '("a")))) '())
  (check-equal? (body-problems shape (bytes-of (hasheq 'name "x" 'extra (list 1 2)))) '()))

(test-case "the wrong KIND of value is refused by path and type, quoting nothing"
  (define ps (body-problems shape (bytes-of (hasheq 'name "x" 'limit "secret-1000"))))
  (check-equal? ps '("$.limit: expected integer, got string"))
  ;; SEC-7's rule: the refusal names the type it got, never the value
  (check-false (for/or ([p (in-list ps)]) (string-contains? p "secret")))
  (check-equal? (body-problems shape (bytes-of (hasheq 'name "x" 'tags '("a" 7))))
                '("$.tags[1]: expected string, got integer"))
  ;; JSON null is a value of type null, and is refused where a type was named —
  ;; which is what a console sending parseInt("") produces
  (check-equal? (body-problems shape (bytes-of (hasheq 'name "x" 'limit 'null)))
                '("$.limit: expected integer, got null")))

(test-case "a missing required field is named, and an EMPTY body is the empty object"
  (check-equal? (body-problems shape #"") '("$: missing required field 'name'"))
  (check-equal? (body-problems shape #f) '("$: missing required field 'name'"))
  (check-equal? (body-problems (hasheq 'type "object" 'properties (hasheq)
                                       'required '() 'additionalProperties #t)
                               #"")
                '()))

(test-case "a body that is not JSON, or not an object, is refused as exactly that"
  ;; the other two readers turn both into {} — right for an undeclared route,
  ;; wrong for one that has said what its body is
  (check-equal? (body-problems shape #"{not json") '("$: the body is not JSON"))
  (check-equal? (body-problems shape #"[1,2]") '("$: expected object, got array"))
  (check-equal? (body-problems shape #"\"x\"") '("$: expected object, got string")))

;; ---------------------------------------------------------------------------
;; every shape the TABLE declares is one the check can actually apply

(define KNOWN-TYPES '("string" "number" "integer" "boolean" "array" "object" "null"))

(define (types-of s)
  (define t (hash-ref s 'type #f))
  (cond [(string? t) (list t)] [(list? t) t] [else '()]))

(define (well-formed? s path)
  ;; a field with no type is a field the validator ACCEPTS ANYTHING for, which
  ;; is a declaration that enforces nothing — #113's shape inside a schema
  (check-true (pair? (types-of s)) (format "~a names no type" path))
  (for ([t (in-list (types-of s))])
    (check-not-false (member t KNOWN-TYPES) (format "~a: unknown type ~s" path t)))
  (when (member "array" (types-of s))
    (check-true (hash? (hash-ref s 'items #f)) (format "~a is an array of anything" path))
    (well-formed? (hash-ref s 'items) (string-append path "[]")))
  (when (member "object" (types-of s))
    (define props (hash-ref s 'properties #f))
    (check-true (hash? props) (format "~a declares no properties" path))
    (check-true (boolean? (hash-ref s 'additionalProperties 'missing))
                (format "~a does not SAY whether it is open" path))
    (for ([r (in-list (hash-ref s 'required '()))])
      (check-true (hash-has-key? props (string->symbol r))
                  (format "~a requires '~a', which it does not declare" path r)))
    (for ([(k v) (in-hash props)])
      (well-formed? v (format "~a.~a" path k)))))

(test-case "every declared body is an object that names a type for every field"
  (define declared (for/list ([r (in-list ROUTES)] #:when (rt-body r)) r))
  (check-true (>= (length declared) 5))
  (for ([r (in-list declared)])
    (define label (format "~a ~a" (rt-method r) (rt-path r)))
    (check-equal? (types-of (rt-body r)) '("object") label)
    (well-formed? (rt-body r) label)))

(test-case "a declared body is on a route that takes one"
  ;; a GET or DELETE with a body schema would be a shape the dispatcher checks
  ;; against bytes nobody sends, so every GET would 400 on its required fields
  (for ([r (in-list ROUTES)] #:when (rt-body r))
    (check-not-false (member (rt-method r) '("POST" "PUT" "PATCH"))
                     (format "~a ~a declares a body" (rt-method r) (rt-path r)))))
