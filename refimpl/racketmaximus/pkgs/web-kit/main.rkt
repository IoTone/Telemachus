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
         web-server/http
         net/url
         json)

(provide json-response request-path serve)

(define (json-response jsx #:code [code 200] #:headers [headers '()])
  (response/output
   #:code code
   #:mime-type #"application/json; charset=utf-8"
   #:headers headers
   (lambda (out) (write-json jsx out))))

;; Path segments of the request as a list of strings, e.g. '("api" "health").
(define (request-path req)
  (map path/param-path (url-path (request-uri req))))

;; Route every request to `handler`; don't pop a browser. Pass both ssl-cert and
;; ssl-key (PEM paths) to serve over HTTPS.
(define (serve handler #:port [port 8099] #:listen-ip [ip "127.0.0.1"]
               #:ssl-cert [ssl-cert #f] #:ssl-key [ssl-key #f])
  (if (and ssl-cert ssl-key)
      (serve/servlet handler #:servlet-regexp #rx"" #:port port #:listen-ip ip
                     #:command-line? #t #:ssl-cert ssl-cert #:ssl-key ssl-key)
      (serve/servlet handler #:servlet-regexp #rx"" #:port port #:listen-ip ip
                     #:command-line? #t)))
