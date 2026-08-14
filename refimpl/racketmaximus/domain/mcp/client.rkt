#lang racket/base

;; domain/mcp/client.rkt — a minimal Model Context Protocol client with two
;; transports behind one interface:
;;   • stdio          — subprocess, newline-delimited JSON-RPC 2.0
;;   • Streamable HTTP — POST JSON-RPC to a URL; response is application/json or
;;                       an SSE stream; Mcp-Session-Id header is echoed back.
;;
;; A connection is (rpc notify close): request/response, fire-and-forget notify,
;; teardown. Calls on one connection are serialized so concurrent agent requests
;; don't interleave.

(require json
         racket/string
         racket/port
         racket/system
         net/url
         net/http-client)

(provide (struct-out mcp-conn)
         mcp-connect mcp-connect-stdio mcp-connect-http
         mcp-close mcp-list-tools mcp-call-tool)

;; rpc    : (request-obj id secs) -> response-obj (the one whose id matches)
;; notify : (notif-obj) -> void
(struct mcp-conn (rpc notify close lock id-box) #:transparent)

(define (parse-json s) (with-handlers ([exn:fail? (lambda (_) #f)]) (string->jsexpr s)))

;; ---- transport-agnostic request/notify + handshake --------------------------
(define (request c method params [secs 20])
  (call-with-semaphore (mcp-conn-lock c)
    (lambda ()
      (define id (add1 (unbox (mcp-conn-id-box c))))
      (set-box! (mcp-conn-id-box c) id)
      (define resp ((mcp-conn-rpc c) (hasheq 'jsonrpc "2.0" 'id id 'method method 'params params) id secs))
      (cond
        [(not (hash? resp)) (error 'mcp "no/invalid response from ~a" method)]
        [(hash-has-key? resp 'error) (error 'mcp "~a" (hash-ref (hash-ref resp 'error) 'message "error"))]
        [else (hash-ref resp 'result (hasheq))]))))

(define (notify c method params)
  (call-with-semaphore (mcp-conn-lock c)
    (lambda () ((mcp-conn-notify c) (hasheq 'jsonrpc "2.0" 'method method 'params params)))))

(define (handshake c secs)
  (request c "initialize"
           (hasheq 'protocolVersion "2024-11-05" 'capabilities (hasheq)
                   'clientInfo (hasheq 'name "telemachus" 'version "0.6.0"))
           secs)
  (notify c "notifications/initialized" (hasheq)))

;; ---- stdio transport --------------------------------------------------------
(define (resolve-cmd command)
  (cond [(absolute-path? command) command]
        [(find-executable-path command) => values]
        [else command]))

(define (read-line/timeout port secs)
  (let ([r (sync/timeout secs (read-line-evt port 'any))]) (if r r eof)))

(define (mcp-connect-stdio command args #:init-timeout [t 15])
  (define-values (proc out in err) (apply subprocess #f #f #f (resolve-cmd command) args))
  (define (send obj) (write-json obj in) (write-char #\newline in) (flush-output in))
  (define (rpc obj id secs)
    (send obj)
    (let loop ()
      (define line (read-line/timeout out secs))
      (cond
        [(eof-object? line) (error 'mcp "no response from server")]
        [(string=? (string-trim line) "") (loop)]
        [else (define m (parse-json line))
              (if (and (hash? m) (equal? (hash-ref m 'id #f) id)) m (loop))])))
  (define c (mcp-conn rpc send
                      (lambda () (with-handlers ([exn:fail? void]) (close-output-port in) (subprocess-kill proc #t)))
                      (make-semaphore 1) (box 0)))
  (handshake c t) c)

(define (mcp-connect command args #:init-timeout [t 15])   ; back-compat: stdio
  (mcp-connect-stdio command args #:init-timeout t))

;; ---- Streamable HTTP transport ----------------------------------------------
(define (url-parts u)
  (define uu (string->url u))
  (define ssl? (equal? (url-scheme uu) "https"))
  (values (url-host uu) (or (url-port uu) (if ssl? 443 80)) ssl?
          (string-append "/" (string-join (map path/param-path (url-path uu)) "/"))))

(define (header-lookup hdrs name)   ; hdrs: list of bytes/strings "Key: v"; name lowercase
  (for/or ([h (in-list hdrs)])
    (define s (if (bytes? h) (bytes->string/utf-8 h) h))
    (define i (for/or ([k (in-naturals)] [ch (in-string s)]) (and (char=? ch #\:) k)))
    (and i (string-ci=? (substring s 0 i) name) (string-trim (substring s (add1 i))))))

;; parse an HTTP body (application/json OR text/event-stream) → the response for id
(define (parse-http-body body id)
  (cond
    [(regexp-match? #rx"(?m:^data:)" body)
     (for/or ([line (in-list (string-split body "\n"))] #:when (string-prefix? (string-trim line) "data:"))
       (define m (parse-json (string-trim (substring (string-trim line) 5))))
       (and (hash? m) (equal? (hash-ref m 'id #f) id) m))]
    [else (parse-json body)]))

(define (mcp-connect-http url #:init-timeout [t 20] #:headers [extra '()])
  (define session (box #f))
  (define (post obj)
    (define-values (host port ssl? path) (url-parts url))
    (define hdrs (append (list "Content-Type: application/json"
                               "Accept: application/json, text/event-stream")
                         (if (unbox session) (list (string-append "Mcp-Session-Id: " (unbox session))) '())
                         extra))
    (define-values (status rhdrs in)
      (http-sendrecv host path #:ssl? ssl? #:port port #:method #"POST" #:headers hdrs #:data (jsexpr->bytes obj)))
    (let ([sid (header-lookup rhdrs "mcp-session-id")]) (when sid (set-box! session sid)))
    (port->string in))
  (define c (mcp-conn (lambda (obj id secs) (parse-http-body (post obj) id))
                      (lambda (obj) (post obj) (void))
                      void (make-semaphore 1) (box 0)))
  (handshake c t) c)

;; ---- tools (transport-agnostic) ---------------------------------------------
(define (mcp-close c) ((mcp-conn-close c)))

(define (mcp-list-tools c)
  (let ([ts (hash-ref (request c "tools/list" (hasheq)) 'tools '())]) (if (list? ts) ts '())))

(define (mcp-call-tool c name args)
  (define r (request c "tools/call" (hasheq 'name name 'arguments args)))
  (define content (let ([x (hash-ref r 'content '())]) (if (list? x) x '())))
  (string-join
   (for/list ([blk (in-list content)] #:when (and (hash? blk) (equal? (hash-ref blk 'type #f) "text")))
     (format "~a" (hash-ref blk 'text "")))
   "\n"))
