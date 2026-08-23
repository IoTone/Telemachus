#lang racket/base

;; web-kit/http1 — a small HTTP/1.1 server we own, for the data plane.
;;
;; WHY THIS EXISTS. `serve/servlet` is the right tool for the JSON control plane and
;; the wrong one for moving files. Three separate symptoms, one cause — it reads the
;; whole request body into memory before a handler runs, and it never speaks an
;; interim response:
;;
;;   * `Expect: 100-continue` is unimplemented anywhere in web-server-lib. Every AWS
;;     client sends it and waits; measured against a listener that reproduces that
;;     silence, `aws s3 cp` stalls 16.0 s before sending 17 bytes. There is no
;;     client-side opt-out — the CRT path and the botocore path both do it.
;;   * A body over `max-request-body-length` is refused by dropping the connection:
;;     no status, no log line, nothing the client can report but a transport error.
;;   * A 2 GB upload would need 2 GB of RAM.
;;
;; None of that is fixable above the handler, because by the time a handler exists
;; the body has already been read. So: this module.
;;
;; WHAT IT IS NOT. Not a general-purpose web server. No routing, no sessions, no
;; templating, no TLS (put a terminator in front, as with the servlet). It speaks
;; enough HTTP/1.1 to be talked to by curl, the AWS SDKs, and rclone, and nothing
;; more. Roughly: request line, headers, `Expect: 100-continue`, `Content-Length`
;; and `chunked` request bodies as an INPUT PORT, keep-alive, and responses that
;; either carry a length or stream.
;;
;; THE ONE INTERESTING CHOICE: `100 Continue` is sent lazily — on the first read of
;; the body, not when the headers are parsed. A handler that rejects a request
;; before touching the body (401, 403, quota) therefore causes the client never to
;; send it at all. The bytes of an unauthorized 2 GB upload stay on the client.
;; That is what the mechanism is *for*, and sending the continue eagerly throws it
;; away.

(require racket/tcp racket/port racket/string racket/list)

(provide (struct-out http-req) (struct-out http-res) http-res*
         serve-http1 http1-listen
         req-header req-header* req-query
         text-res bytes-res
         DEFAULT-LIMITS (struct-out http-limits))

;; ---- shapes -------------------------------------------------------------------
;; `path` is the RAW, still-percent-encoded path: a signature is computed over what
;; was sent, so decoding before anyone has verified it destroys evidence.
;; `headers` is an assoc list of (lowercase-name . value), in arrival order —
;; duplicates are preserved because they are meaningful.
;; `body` is an input port. It may be read once, and reading it is what releases the
;; client to send.
(struct http-req (method path query headers body client-ip) #:transparent)

;; `body` is bytes, or (output-port -> void) for a streamed response. When it is a
;; procedure and no content-length is given, the response is chunked.
(struct http-res (code headers body content-length) #:transparent)

;; the constructor handlers actually use; content-length is only needed when
;; streaming a body whose size is known in advance (a file, a blob)
(define (http-res* code headers body #:content-length [len #f])
  (http-res code headers body len))

(struct http-limits (max-line max-headers max-header-bytes read-timeout keep-alive-timeout)
  #:transparent)

(define DEFAULT-LIMITS
  (http-limits 8192      ; request line — longer than any real S3 key
               100       ; header count
               65536     ; total header bytes
               60        ; seconds to wait for a request to arrive/complete
               15))      ; seconds to wait for the NEXT request on a kept-alive conn

;; ---- header helpers -------------------------------------------------------------
(define (req-header r name)             ; first value, or #f
  (define k (string-downcase name))
  (cond [(assoc k (http-req-headers r)) => cdr] [else #f]))

(define (req-header* r name)            ; every value, in order
  (define k (string-downcase name))
  (for/list ([kv (in-list (http-req-headers r))] #:when (string=? (car kv) k)) (cdr kv)))

(define (req-query r name [default #f])
  (cond [(assoc name (http-req-query r)) => cdr] [else default]))

(define (text-res code s #:type [type #"text/plain; charset=utf-8"] #:headers [h '()])
  (http-res* code (cons (cons #"Content-Type" type) h) (string->bytes/utf-8 s)))

(define (bytes-res code bs #:type [type #"application/octet-stream"] #:headers [h '()])
  (http-res* code (cons (cons #"Content-Type" type) h) bs))

;; ---- parsing ---------------------------------------------------------------------
(define (read-crlf-line in limit who)
  (define bs (read-bytes-line in 'return-linefeed))
  (cond
    [(eof-object? bs) eof]
    [(> (bytes-length bs) limit) (error who "line exceeds ~a bytes" limit)]
    [else bs]))

;; "GET /a/b?x=1&y HTTP/1.1" -> (values "GET" "/a/b" '(("x" . "1") ("y" . "")) "HTTP/1.1")
(define (parse-request-line bs)
  (define parts (string-split (bytes->string/utf-8 bs #\?) " "))
  (unless (= 3 (length parts)) (error 'http1 "malformed request line"))
  (define target (cadr parts))
  (define i (for/first ([c (in-string target)] [n (in-naturals)] #:when (char=? c #\?)) n))
  (values (car parts)
          (if i (substring target 0 i) target)
          (if i (parse-query (substring target (add1 i))) '())
          (caddr parts)))

;; Values stay percent-encoded for the same reason the path does. An empty value is
;; kept (`?prefix=` is a real thing the AWS CLI sends and it is part of the signature),
;; and so is a bare key with no `=`.
(define (parse-query s)
  (for/list ([kv (in-list (string-split s "&"))] #:unless (string=? kv ""))
    (define i (for/first ([c (in-string kv)] [n (in-naturals)] #:when (char=? c #\=)) n))
    (if i (cons (substring kv 0 i) (substring kv (add1 i))) (cons kv ""))))

(define (read-headers in limits)
  (let loop ([acc '()] [n 0] [bytes-so-far 0])
    (define line (read-crlf-line in (http-limits-max-line limits) 'http1))
    (cond
      [(eof-object? line) (error 'http1 "connection closed inside headers")]
      [(zero? (bytes-length line)) (reverse acc)]
      [else
       (when (> (add1 n) (http-limits-max-headers limits)) (error 'http1 "too many headers"))
       (define total (+ bytes-so-far (bytes-length line)))
       (when (> total (http-limits-max-header-bytes limits)) (error 'http1 "headers too large"))
       (define s (bytes->string/utf-8 line #\?))
       (define i (for/first ([c (in-string s)] [k (in-naturals)] #:when (char=? c #\:)) k))
       (unless i (error 'http1 "header without a colon"))
       (loop (cons (cons (string-downcase (substring s 0 i))
                         (string-trim (substring s (add1 i))))
                   acc)
             (add1 n) total)])))

;; ---- request body ------------------------------------------------------------------
;; Both body kinds are ports over the live connection, so a handler that streams
;; never materializes the upload. `on-first-read` is where the 100-continue goes.
;;
;; The connection loop needs two facts afterwards — did the handler touch the body,
;; and is anything left — and it must learn them WITHOUT peeking, because a peek on
;; these ports would fire `on-first-read` and send a continue the handler never asked
;; for. Hence an explicit state record rather than inspecting the port.
(struct body-state (started? finished? remaining) #:mutable #:transparent)

(define (make-length-body in len on-first-read)
  (define st (body-state #f (zero? len) len))
  (values
   (make-input-port
    'http-body
    (lambda (bs)
      (unless (body-state-started? st) (set-body-state-started?! st #t) (on-first-read))
      (cond
        [(zero? (body-state-remaining st)) eof]
        [else
         (define n (read-bytes-avail! bs in 0 (min (bytes-length bs) (body-state-remaining st))))
         (cond [(eof-object? n)
                (error 'http1 "client closed with ~a body bytes outstanding"
                       (body-state-remaining st))]
               [else
                (set-body-state-remaining! st (- (body-state-remaining st) n))
                (when (zero? (body-state-remaining st)) (set-body-state-finished?! st #t))
                n])]))
    #f
    void)
   st))

;; RFC 7230 chunked: <hex-size>[;ext]CRLF <data> CRLF … 0CRLF <trailers> CRLF
(define (make-chunked-body in on-first-read)
  (define st (body-state #f #f 0))
  (define remaining 0)
  (define done? #f)
  (define (next-chunk!)
    (define line (read-bytes-line in 'return-linefeed))
    (when (eof-object? line) (error 'http1 "connection closed inside a chunked body"))
    (define s (car (string-split (string-trim (bytes->string/utf-8 line #\?)) ";")))
    (define n (string->number (if (string=? s "") "0" s) 16))
    (unless n (error 'http1 "bad chunk size: ~s" s))
    (cond
      [(zero? n)
       ;; consume trailers up to the blank line, then stop
       (let drain ()
         (define t (read-bytes-line in 'return-linefeed))
         (unless (or (eof-object? t) (zero? (bytes-length t))) (drain)))
       (set! done? #t)]
      [else (set! remaining n)]))
  (values
   (make-input-port
    'http-chunked-body
    (lambda (bs)
      (unless (body-state-started? st) (set-body-state-started?! st #t) (on-first-read))
      (let loop ()
        (cond
          [done? (set-body-state-finished?! st #t) eof]
          [(zero? remaining) (next-chunk!) (loop)]
          [else
           (define n (read-bytes-avail! bs in 0 (min (bytes-length bs) remaining)))
           (cond
             [(eof-object? n) (error 'http1 "connection closed inside a chunk")]
             [else
              (set! remaining (- remaining n))
              (when (zero? remaining)
                (void (read-bytes-line in 'return-linefeed)))   ; the CRLF after the data
              n])])))
    #f
    void)
   st))

;; ---- responses -----------------------------------------------------------------
(define REASONS
  (hash 100 "Continue" 200 "OK" 201 "Created" 202 "Accepted" 204 "No Content"
        206 "Partial Content" 301 "Moved Permanently" 304 "Not Modified"
        400 "Bad Request" 401 "Unauthorized" 403 "Forbidden" 404 "Not Found"
        405 "Method Not Allowed" 409 "Conflict" 411 "Length Required"
        413 "Content Too Large" 416 "Range Not Satisfiable" 431 "Request Header Fields Too Large"
        500 "Internal Server Error" 501 "Not Implemented" 503 "Service Unavailable"))
(define (reason code) (hash-ref REASONS code "Status"))

(define (write-status+headers out code headers)
  (write-bytes (bytes-append #"HTTP/1.1 " (string->bytes/utf-8 (number->string code))
                             #" " (string->bytes/utf-8 (reason code)) #"\r\n") out)
  (for ([kv (in-list headers)])
    (write-bytes (bytes-append (->bytes (car kv)) #": " (->bytes (cdr kv)) #"\r\n") out))
  (write-bytes #"\r\n" out))

(define (->bytes v) (if (bytes? v) v (string->bytes/utf-8 (format "~a" v))))

;; A response either knows its length (bytes, or an explicit content-length) or it is
;; chunked. Never "write until you close" — that would force connection-close framing
;; and cost a handshake per object.
(define (write-response out res head?)
  (define code (http-res-code res))
  (define body (http-res-body res))
  (define base (http-res-headers res))
  (define len (http-res-content-length res))
  (cond
    [(bytes? body)
     (write-status+headers out code (cons (cons #"Content-Length" (bytes-length body)) base))
     (unless head? (write-bytes body out))]
    [len
     ;; a streamed body of known size: no chunk framing, and the client gets a
     ;; progress bar
     (write-status+headers out code (cons (cons #"Content-Length" len) base))
     (unless head? (body out))]
    [else
     (write-status+headers out code (cons (cons #"Transfer-Encoding" #"chunked") base))
     (unless head?
       (define chunker (make-chunk-writer out))
       (body chunker)
       (flush-output chunker)
       (close-output-port chunker)
       (write-bytes #"0\r\n\r\n" out))])
  (flush-output out))

;; Wraps `out` so whatever a handler writes is framed as chunks. Handlers therefore
;; never learn that chunking exists.
(define (make-chunk-writer out)
  (make-output-port
   'chunked out
   (lambda (bs start end non-block? breakable?)
     (define n (- end start))
     (when (> n 0)
       (write-bytes (string->bytes/utf-8 (string-append (number->string n 16) "\r\n")) out)
       (write-bytes bs out start end)
       (write-bytes #"\r\n" out))
     n)
   void))

;; ---- the connection loop ----------------------------------------------------------
(define (handle-connection in out handler limits client-ip on-error)
  (let loop ([first? #t])
    (define deadline (* 1000 (if first?
                                 (http-limits-read-timeout limits)
                                 (http-limits-keep-alive-timeout limits))))
    (define ready (sync/timeout (/ deadline 1000.0) in))
    (cond
      [(not ready) (void)]                                  ; idle keep-alive: just close
      [else
       (define line (read-crlf-line in (http-limits-max-line limits) 'http1))
       (cond
         [(eof-object? line) (void)]
         [(zero? (bytes-length line)) (loop #f)]            ; tolerate a stray CRLF
         [else
          (define-values (method path query version) (parse-request-line line))
          (define headers (read-headers in limits))
          (define (hdr name) (cond [(assoc name headers) => cdr] [else #f]))

          ;; Lazy 100-continue: see the module comment. A handler that answers
          ;; without reading the body means the client never uploads it.
          (define expects-continue?
            (let ([e (hdr "expect")]) (and e (string-ci=? (string-trim e) "100-continue"))))
          (define (send-continue!)
            (when expects-continue?
              (write-bytes #"HTTP/1.1 100 Continue\r\n\r\n" out)
              (flush-output out)))

          (define te (hdr "transfer-encoding"))
          (define cl (let ([v (hdr "content-length")]) (and v (string->number (string-trim v)))))
          (define chunked? (and te (regexp-match? #px"(?i:chunked)" te)))
          (define-values (body bstate)
            (cond [chunked? (make-chunked-body in send-continue!)]
                  [(and cl (> cl 0)) (make-length-body in cl send-continue!)]
                  [else (values (open-input-bytes #"") (body-state #t #t 0))]))

          (define req (http-req method path query headers body client-ip))
          (define res
            (with-handlers ([exn:fail? (lambda (e)
                                         (on-error e)
                                         (text-res 500 "internal error\n"))])
              (handler req)))

          (define head? (string-ci=? method "HEAD"))

          ;; A handler that did not finish the body leaves the connection mid-message.
          ;; Three cases, and only one of them is a problem:
          ;;   * finished        -> the stream is at a message boundary. Reuse it.
          ;;   * never started, and the client is waiting on a 100-continue we never
          ;;     sent -> nothing was ever transmitted. Also clean. This is the payoff
          ;;     for the lazy continue: a rejected upload costs no bytes AND no
          ;;     connection.
          ;;   * bytes are in flight -> drain a small remainder to save the
          ;;     connection, but never spend unbounded time draining an upload the
          ;;     handler already refused. Past the threshold, close.
          (define drain-limit 65536)
          (define outstanding?
            (and (not (body-state-finished? bstate))
                 (not (and expects-continue? (not (body-state-started? bstate))))))
          (define drained?
            (and outstanding?
                 (let ([r (body-state-remaining bstate)])
                   (and (not chunked?) (<= r drain-limit)
                        (let ([got (read-bytes r body)])
                          (or (eof-object? got) (= (bytes-length got) r)))))))
          (define close?
            (or (equal? version "HTTP/1.0")
                (let ([c (hdr "connection")]) (and c (regexp-match? #px"(?i:close)" c)))
                (and outstanding? (not drained?))))
          (write-response out (add-connection-header res close?) head?)
          (if close? (void) (loop #f))])])))

(define (add-connection-header res close?)
  (struct-copy http-res res
               [headers (cons (cons #"Connection" (if close? #"close" #"keep-alive"))
                              (http-res-headers res))]))

;; ---- listener ---------------------------------------------------------------------
;; Returns a shutdown thunk. One green thread per connection: Racket's are cheap and
;; the alternative (an event loop over ports) buys nothing at this scale.
(define (default-on-error e) ((error-display-handler) (exn-message e) e))

(define (http1-listen handler
                      #:port [port 8836]
                      #:listen-ip [ip "127.0.0.1"]
                      #:limits [limits DEFAULT-LIMITS]
                      #:backlog [backlog 128]
                      ;; how a handler's exception is reported. The default writes it
                      ;; out; a test that raises on purpose passes `void`.
                      #:on-error [on-error default-on-error])
  (define listener (tcp-listen port backlog #t ip))
  (define accepting
    (thread
     (lambda ()
       (let loop ()
         (define-values (in out)
           (with-handlers ([exn:fail? (lambda (_) (values #f #f))]) (tcp-accept listener)))
         (when (and in out)
           (thread
            (lambda ()
              (define-values (_l _lp rhost _rp)
                (with-handlers ([exn:fail? (lambda (_) (values #f #f "?" #f))])
                  (tcp-addresses in #t)))
              (dynamic-wind
                void
                (lambda ()
                  (with-handlers ([exn:fail? (lambda (e)
                                               ;; a client that vanishes mid-request is
                                               ;; routine, not an error worth a stack
                                               (void))])
                    (handle-connection in out handler limits rhost on-error)))
                (lambda ()
                  (with-handlers ([exn:fail? void]) (close-input-port in))
                  (with-handlers ([exn:fail? void]) (close-output-port out))))))
           (loop))))))
  (lambda ()
    (with-handlers ([exn:fail? void]) (tcp-close listener))
    (kill-thread accepting)))

;; blocking form, for a `main` that has nothing else to do
(define (serve-http1 handler #:port [port 8836] #:listen-ip [ip "127.0.0.1"]
                     #:limits [limits DEFAULT-LIMITS]
                     #:on-error [on-error default-on-error])
  (define stop (http1-listen handler #:port port #:listen-ip ip #:limits limits
                             #:on-error on-error))
  (with-handlers ([exn:break? (lambda (_) (stop))])
    (sync never-evt)))
