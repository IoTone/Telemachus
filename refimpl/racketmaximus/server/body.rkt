#lang racket/base

;; server/body.rkt — what a JSON request body reads as.
;;
;; Its own module, with no database in it, so the rule is unit-testable: a test
;; that requires server/kit.rkt instantiates the connection pool, and CI's
;; SQLite leg sets DATABASE_URL to the empty string (#123's lesson).
;;
;; TWO READERS, because a core handler and a plugin handler want different
;; things from the same bytes:
;;
;;   `json-body-object` — every core handler. It `hash-ref`s the body, so a body
;;   that parses to a string, an array, a number or null used to reach that
;;   `hash-ref` and come back a 500: a server fault for a mistake that is wholly
;;   the caller's. The sweep in test/body-shape-sweep.py found 63 routes doing
;;   it, including `/api/login`, `/api/bootstrap` and `/api/beta/signup` — public
;;   doors where a 500 is also noise in an operator's log that anybody can make.
;;   A non-object now reads as `{}`, exactly what malformed JSON already read
;;   as, so each route refuses it with the 400 it gives a missing field.
;;
;;   `json-body-value` — the plugin-route mount only. A plugin's `'body` is a
;;   published contract (docs/integrators-guide.md: args = {params, query, body,
;;   headers}) and nothing there promises an object, so a downstream route that
;;   takes an array must still receive one. Malformed JSON is still `{}`.

(require json)

(provide json-body-object json-body-value)

(define (json-body-value raw)
  (if (and (bytes? raw) (> (bytes-length raw) 0))
      (with-handlers ([exn:fail? (lambda (_) (hasheq))]) (bytes->jsexpr raw))
      (hasheq)))

(define (json-body-object raw)
  (define v (json-body-value raw))
  (if (hash? v) v (hasheq)))
