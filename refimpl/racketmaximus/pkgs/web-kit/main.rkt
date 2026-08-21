#lang racket/base

;; web-kit — minimal JSON-API helpers over Racket's built-in web-server.
;;
;; Intentionally thin. The server, routing primitives, and evented I/O are all
;; web-server's; this only spares each app from re-writing json-response /
;; path-extraction / serve boilerplate.
;;
;;   (require web-kit)
;;   (define (handle req)
;;     (case (request-path req)
;;       [(("health")) (json-response (hasheq 'ok #t))]
;;       [else (json-response (hasheq 'error "not found") #:code 404)]))
;;   (module+ main (serve handle #:port 8099))

(require web-server/servlet-env
         web-server/safety-limits
         web-server/http
         net/url
         json)

(provide json-response request-path serve default-max-body-length)

(define (json-response jsx #:code [code 200] #:headers [headers '()])
  (response/output
   #:code code
   #:mime-type #"application/json; charset=utf-8"
   #:headers headers
   (lambda (out) (write-json jsx out))))

;; Path segments of the request as a list of strings, e.g. '("api" "health").
(define (request-path req)
  (map path/param-path (url-path (request-uri req))))

;; web-server's default max-request-body-length is 1 MiB, and exceeding it does not
;; produce a 413 — the connection is dropped with no HTTP response at all, nothing
;; logged, and the client sees a transport error. Any upload path therefore has to
;; raise this deliberately; leaving the default in place makes a size check in the
;; handler unreachable, which is exactly what happened to the onboarding asset
;; upload (its 2 MiB cap could never be hit, because base64 inflates a 2 MiB image
;; to ~2.7 MB of body).
(define default-max-body-length (* 32 1024 1024))

;; Route every request to `handler`; don't pop a browser. Pass both ssl-cert and
;; ssl-key (PEM paths) to serve over HTTPS.
(define (serve handler #:port [port 8099] #:listen-ip [ip "127.0.0.1"]
               #:ssl-cert [ssl-cert #f] #:ssl-key [ssl-key #f]
               #:max-body-length [max-body default-max-body-length])
  (define limits (make-safety-limits #:max-request-body-length max-body))
  (if (and ssl-cert ssl-key)
      (serve/servlet handler #:servlet-regexp #rx"" #:port port #:listen-ip ip
                     #:command-line? #t #:safety-limits limits
                     #:ssl-cert ssl-cert #:ssl-key ssl-key)
      (serve/servlet handler #:servlet-regexp #rx"" #:port port #:listen-ip ip
                     #:command-line? #t #:safety-limits limits)))
