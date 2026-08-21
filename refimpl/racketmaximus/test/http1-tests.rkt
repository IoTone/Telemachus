#lang racket/base

;; test/http1-tests.rkt — slice 51: the HTTP/1.1 listener web-kit owns.
;;   raco test test/http1-tests.rkt
;;
;; These talk raw TCP rather than using an HTTP client, because the things under
;; test are wire-level: when the 100-continue is emitted, how a body is framed, and
;; whether a connection is reusable afterwards. An HTTP client would hide all three.

(require rackunit racket/tcp racket/port racket/string web-kit/http1)

;; ---- harness --------------------------------------------------------------------
(define PORT 18836)

;; Each case gets its own listener on its own port, so a wedged connection in one
;; test cannot leak into the next.
(define next-port (let ([n (box PORT)]) (lambda () (set-box! n (add1 (unbox n))) (unbox n))))

(define (with-server handler proc #:quiet? [quiet? #f])
  (define port (next-port))
  (define stop (http1-listen handler #:port port #:listen-ip "127.0.0.1"
                             #:on-error (if quiet? void (lambda (e) ((error-display-handler) (exn-message e) e)))))
  (dynamic-wind void (lambda () (proc port)) (lambda () (stop))))

(define (connect port)
  (define-values (in out) (tcp-connect "127.0.0.1" port))
  (values in out))

(define (send! out . lines)
  (for ([l (in-list lines)]) (write-bytes (if (bytes? l) l (string->bytes/utf-8 l)) out))
  (flush-output out))

;; read a whole HTTP message (status line + headers + body per its framing)
(define (read-message in #:head? [head? #f])
  (define status (read-bytes-line in 'return-linefeed))
  (cond
    [(eof-object? status) (values #f '() #"")]
    [else
     (define headers
       (let loop ([acc '()])
         (define l (read-bytes-line in 'return-linefeed))
         (if (or (eof-object? l) (zero? (bytes-length l)))
             (reverse acc)
             (let* ([s (bytes->string/utf-8 l)] [i (car (regexp-match-positions #rx":" s))])
               (loop (cons (cons (string-downcase (substring s 0 (car i)))
                                 (string-trim (substring s (add1 (car i)))))
                           acc))))))
     (define (h k) (cond [(assoc k headers) => cdr] [else #f]))
     (define body
       (cond
         [head? #""]                       ; HEAD: headers only, by definition
         [(h "content-length") (read-bytes (string->number (h "content-length")) in)]
         [(equal? (h "transfer-encoding") "chunked")
          (let loop ([acc '()])
            (define n (string->number (string-trim (bytes->string/utf-8 (read-bytes-line in 'return-linefeed))) 16))
            (cond [(or (not n) (zero? n)) (void (read-bytes-line in 'return-linefeed))
                                          (apply bytes-append (reverse acc))]
                  [else (define d (read-bytes n in))
                        (void (read-bytes-line in 'return-linefeed))
                        (loop (cons d acc))]))]
         [else #""]))
     (values (bytes->string/utf-8 status) headers (or body #""))]))

(define (echo-handler req)
  (define body (port->bytes (http-req-body req)))
  (text-res 200 (format "~a ~a n=~a" (http-req-method req) (http-req-path req) (bytes-length body))))

;; ---- 1. the basics --------------------------------------------------------------
(with-server echo-handler
  (lambda (port)
    (define-values (in out) (connect port))
    (send! out "GET /hello HTTP/1.1\r\nHost: x\r\n\r\n")
    (define-values (status headers body) (read-message in))
    (check-equal? status "HTTP/1.1 200 OK")
    (check-equal? (bytes->string/utf-8 body) "GET /hello n=0")
    ;; keep-alive: a second request on the SAME connection
    (send! out "GET /again HTTP/1.1\r\nHost: x\r\n\r\n")
    (define-values (s2 h2 b2) (read-message in))
    (check-equal? (bytes->string/utf-8 b2) "GET /again n=0" "connection is reused")
    (check-equal? (cond [(assoc "connection" h2) => cdr] [else #f]) "keep-alive")
    (close-input-port in) (close-output-port out)))

;; ---- 2. the path and query stay percent-encoded ---------------------------------
;; A signature is computed over what was sent. Decoding before verification destroys
;; the evidence, and `?prefix=` with an empty value is part of the canonical string.
(with-server
  (lambda (req)
    (text-res 200 (format "~a | ~s" (http-req-path req) (http-req-query req))))
  (lambda (port)
    (define-values (in out) (connect port))
    (send! out "GET /b/a%20b%2Fc?list-type=2&prefix=&delimiter=%2F HTTP/1.1\r\nHost: x\r\n\r\n")
    (define-values (_s _h body) (read-message in))
    (define txt (bytes->string/utf-8 body))
    (check-true (regexp-match? #rx"/b/a%20b%2Fc \\|" txt) "path is not decoded")
    (check-true (regexp-match? #rx"\\(\"prefix\" \\. \"\"\\)" txt) "an empty query value survives")
    (check-true (regexp-match? #rx"\\(\"delimiter\" \\. \"%2F\"\\)" txt) "a query value is not decoded")
    (close-input-port in) (close-output-port out)))

;; ---- 3. Expect: 100-continue, sent when the body is read ------------------------
(with-server echo-handler
  (lambda (port)
    (define-values (in out) (connect port))
    (send! out "POST /up HTTP/1.1\r\nHost: x\r\nContent-Length: 5\r\nExpect: 100-continue\r\n\r\n")
    ;; the handler reads the body, so the continue must arrive BEFORE we send it
    (define line (sync/timeout 3 (read-bytes-line-evt in 'return-linefeed)))
    (check-equal? (and (bytes? line) (bytes->string/utf-8 line)) "HTTP/1.1 100 Continue"
                  "a reading handler releases the client promptly")
    (void (read-bytes-line in 'return-linefeed))           ; the blank line after it
    (send! out "hello")
    (define-values (status _h body) (read-message in))
    (check-equal? status "HTTP/1.1 200 OK")
    (check-equal? (bytes->string/utf-8 body) "POST /up n=5")
    (close-input-port in) (close-output-port out)))

;; ---- 4. …and NOT sent when the handler refuses first ---------------------------
;; This is the property the whole design is for: an unauthorized 2 GB upload must
;; never leave the client. The handler answers 401 without touching the body, so no
;; continue is emitted and the client is free to abandon the transfer.
(with-server
  (lambda (req) (text-res 401 "nope\n"))
  (lambda (port)
    (define-values (in out) (connect port))
    (send! out "PUT /big HTTP/1.1\r\nHost: x\r\nContent-Length: 2000000000\r\nExpect: 100-continue\r\n\r\n")
    (define-values (status _h body) (read-message in))
    (check-equal? status "HTTP/1.1 401 Unauthorized"
                  "the refusal arrives without a single body byte being sent")
    (check-equal? (bytes->string/utf-8 body) "nope\n")
    (close-input-port in) (close-output-port out)))

;; ---- 5. a body larger than any buffer, streamed, never materialized ------------
;; 8 MB is well past both web-server's 1 MiB default and any read buffer here.
(with-server
  (lambda (req)
    ;; count without ever holding the body: this is the whole point
    (define n (let loop ([total 0])
                (define buf (make-bytes 65536))
                (define k (read-bytes-avail! buf (http-req-body req)))
                (if (eof-object? k) total (loop (+ total k)))))
    (text-res 200 (number->string n)))
  (lambda (port)
    (define-values (in out) (connect port))
    (define payload (make-bytes 8000000 65))
    (send! out (format "PUT /huge HTTP/1.1\r\nHost: x\r\nContent-Length: ~a\r\n\r\n" (bytes-length payload)))
    (write-bytes payload out) (flush-output out)
    (define-values (status _h body) (read-message in))
    (check-equal? status "HTTP/1.1 200 OK")
    (check-equal? (bytes->string/utf-8 body) "8000000" "8 MB body arrives intact")
    (close-input-port in) (close-output-port out)))

;; ---- 6. chunked request bodies -------------------------------------------------
(with-server echo-handler
  (lambda (port)
    (define-values (in out) (connect port))
    (send! out "POST /chunked HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n"
               "5\r\nhello\r\n" "6\r\n world\r\n" "0\r\n\r\n")
    (define-values (status _h body) (read-message in))
    (check-equal? (bytes->string/utf-8 body) "POST /chunked n=11" "chunks are reassembled")
    ;; the connection survives a chunked body
    (send! out "GET /after HTTP/1.1\r\nHost: x\r\n\r\n")
    (define-values (_s2 _h2 b2) (read-message in))
    (check-equal? (bytes->string/utf-8 b2) "GET /after n=0" "…and stays usable afterwards")
    (close-input-port in) (close-output-port out)))

;; a chunk extension is legal and must be ignored, not parsed as part of the size
(with-server echo-handler
  (lambda (port)
    (define-values (in out) (connect port))
    (send! out "POST /ext HTTP/1.1\r\nHost: x\r\nTransfer-Encoding: chunked\r\n\r\n"
               "5;name=value\r\nhello\r\n" "0\r\n\r\n")
    (define-values (_s _h body) (read-message in))
    (check-equal? (bytes->string/utf-8 body) "POST /ext n=5")
    (close-input-port in) (close-output-port out)))

;; ---- 7. streamed responses ------------------------------------------------------
;; Without a length the response is chunked; with one it is framed and the client
;; gets a progress bar. Both must arrive byte-identical.
(with-server
  (lambda (req)
    (define payload (make-bytes 200000 66))
    (if (equal? (http-req-path req) "/known")
        (http-res* 200 '() (lambda (out) (write-bytes payload out)) #:content-length (bytes-length payload))
        (http-res* 200 '() (lambda (out)
                             (for ([_ (in-range 20)]) (write-bytes (make-bytes 10000 66) out))))))
  (lambda (port)
    (define-values (in out) (connect port))
    (send! out "GET /known HTTP/1.1\r\nHost: x\r\n\r\n")
    (define-values (_s h1 b1) (read-message in))
    (check-equal? (cond [(assoc "content-length" h1) => cdr] [else #f]) "200000")
    (check-equal? (bytes-length b1) 200000)
    (send! out "GET /unknown HTTP/1.1\r\nHost: x\r\n\r\n")
    (define-values (_s2 h2 b2) (read-message in))
    (check-equal? (cond [(assoc "transfer-encoding" h2) => cdr] [else #f]) "chunked"
                  "a length-less streamed body is chunked, not close-framed")
    (check-equal? (bytes-length b2) 200000)
    (check-equal? b1 b2 "both framings deliver identical bytes")
    (close-input-port in) (close-output-port out)))

;; ---- 8. HEAD sends headers and no body -----------------------------------------
(with-server
  (lambda (req) (bytes-res 200 (make-bytes 4096 67)))
  (lambda (port)
    (define-values (in out) (connect port))
    (send! out "HEAD /thing HTTP/1.1\r\nHost: x\r\n\r\n")
    (define-values (status headers _b) (read-message in #:head? #t))
    (check-equal? status "HTTP/1.1 200 OK")
    (check-equal? (cond [(assoc "content-length" headers) => cdr] [else #f]) "4096"
                  "HEAD still advertises the length it would have sent")
    ;; the connection is still framed correctly, which proves no body leaked
    (send! out "HEAD /thing HTTP/1.1\r\nHost: x\r\n\r\n")
    (define-values (s2 _h2 _b2) (read-message in #:head? #t))
    (check-equal? s2 "HTTP/1.1 200 OK" "no body was written, so the stream stayed in sync")
    (close-input-port in) (close-output-port out)))

;; ---- 9. failure modes answer, rather than dropping the connection ---------------
(with-server
  (lambda (req) (error 'handler "boom"))
  #:quiet? #t                                    ; this one raises on purpose
  (lambda (port)
    (define-values (in out) (connect port))
    (send! out "GET /x HTTP/1.1\r\nHost: x\r\n\r\n")
    (define-values (status _h _b) (read-message in))
    (check-equal? status "HTTP/1.1 500 Internal Server Error"
                  "a handler that raises produces a response, not a dropped socket")
    (close-input-port in) (close-output-port out)))

;; Connection: close is honoured
(with-server echo-handler
  (lambda (port)
    (define-values (in out) (connect port))
    (send! out "GET /once HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n")
    (define-values (_s headers _b) (read-message in))
    (check-equal? (cond [(assoc "connection" headers) => cdr] [else #f]) "close")
    (check-true (eof-object? (read-bytes-line in 'return-linefeed)) "…and the server hangs up")
    (close-input-port in) (close-output-port out)))

;; ---- 10. a handler that ignores a body must not desync the connection ----------
;; Without `Expect`, unread bytes are already in flight; reusing the connection
;; blindly would read them as the next request line. A SMALL remainder is drained so
;; the connection survives…
(with-server
  (lambda (req) (text-res 204 ""))
  (lambda (port)
    (define-values (in out) (connect port))
    (send! out "PUT /ignored HTTP/1.1\r\nHost: x\r\nContent-Length: 11\r\n\r\nhello world")
    (define-values (status headers _b) (read-message in))
    (check-equal? status "HTTP/1.1 204 No Content")
    (check-equal? (cond [(assoc "connection" headers) => cdr] [else #f]) "keep-alive"
                  "a small ignored body is drained, not fatal to the connection")
    (send! out "GET /after HTTP/1.1\r\nHost: x\r\n\r\n")
    (define-values (s2 _h2 _b2) (read-message in))
    (check-equal? s2 "HTTP/1.1 204 No Content" "…and the stream is still in sync")
    (close-input-port in) (close-output-port out)))

;; …but a LARGE one is not, because draining an upload the handler already refused
;; would spend unbounded time on a request we do not want.
(with-server
  (lambda (req) (text-res 413 "too big\n"))
  (lambda (port)
    (define-values (in out) (connect port))
    (define payload (make-bytes 200000 68))
    (send! out (format "PUT /toobig HTTP/1.1\r\nHost: x\r\nContent-Length: ~a\r\n\r\n"
                       (bytes-length payload)))
    (void (thread (lambda () (with-handlers ([(lambda (_) #t) void])
                               (write-bytes payload out) (flush-output out)))))
    (define-values (status headers _b) (read-message in))
    (check-equal? status "HTTP/1.1 413 Content Too Large")
    (check-equal? (cond [(assoc "connection" headers) => cdr] [else #f]) "close"
                  "a large unread body closes rather than draining")
    (close-input-port in) (close-output-port out)))

;; ---- 11. concurrent connections --------------------------------------------------
(with-server echo-handler
  (lambda (port)
    (define results
      (for/list ([i (in-range 12)])
        (thread
         (lambda ()
           (define-values (in out) (connect port))
           (send! out (format "GET /c~a HTTP/1.1\r\nHost: x\r\n\r\n" i))
           (define-values (_s _h b) (read-message in))
           (close-input-port in) (close-output-port out)
           (unless (equal? (bytes->string/utf-8 b) (format "GET /c~a n=0" i))
             (error 'concurrency "wrong answer on connection ~a" i))))))
    (for ([t (in-list results)]) (check-true (and (sync/timeout 10 t) #t) "connection completed"))))

;; ---- 12. limits are enforced with a status, not a hang up ----------------------
(with-server echo-handler
  (lambda (port)
    (define-values (in out) (connect port))
    (send! out (string-append "GET /" (make-string 9000 #\a) " HTTP/1.1\r\nHost: x\r\n\r\n"))
    ;; over max-line: the connection is dropped by design (we cannot trust the framing
    ;; of a request we could not parse) — assert that, rather than pretending otherwise
    (define-values (status _h _b) (read-message in))
    (check-false status "an unparseable request line closes the connection")
    (close-input-port in) (close-output-port out)))
