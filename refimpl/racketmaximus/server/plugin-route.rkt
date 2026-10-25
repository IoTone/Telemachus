#lang racket/base

;; server/plugin-route.rkt — what a plugin handler may read and may return.
;;
;; Kept apart from main.rkt so both can be unit tested without a server and
;; without instantiating the connection pool (requiring kit.rkt does that, which
;; is why CI's SQLite leg sets DATABASE_URL to the empty string).

(require web-server/http
         web-kit)

(provide headers->hash plugin-route-response)

;; The request's headers as a hash of lowercase field name to string value.
;; A repeated field keeps the first value, the same rule `req-header` uses
;; (server/errors.rkt). Header bytes are not always UTF-8, so decoding replaces
;; what it cannot read rather than raising inside a route. The accumulator is
;; `hash`, not `hasheq`: the keys are strings built by `string-downcase`, so an
;; `eq?` table would give every insertion its own key and no lookup would match.
(define (headers->hash headers/raw)
  (for/fold ([h (hash)]) ([raw (in-list headers/raw)])
    (define k (string-downcase (bytes->string/utf-8 (header-field raw) #\uFFFD)))
    (if (hash-has-key? h k)
        h
        (hash-set h k (bytes->string/utf-8 (header-value raw) #\uFFFD)))))

;; A handler may return a response, which keeps full control of the status, the
;; headers and the media type. Anything else keeps the contract that existed
;; before: a jsexpr is a 200, and a value that is not JSON-shaped is stringified
;; under `result`.
(define (plugin-route-response result)
  (cond
    [(response? result) result]
    [(or (hash? result) (list? result) (string? result) (number? result) (boolean? result))
     (json-response result)]
    [else (json-response (hasheq 'result (format "~a" result)))]))
