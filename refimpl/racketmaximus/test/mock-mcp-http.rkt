#lang racket/base

;; test/mock-mcp-http.rkt — a minimal MCP server over Streamable HTTP: each POST
;; carries one JSON-RPC message; the reply is application/json. Exposes `add`.
;;   racket test/mock-mcp-http.rkt [PORT]

(require racket/tcp racket/string json)

(define argv (current-command-line-arguments))
(define port (string->number (if (> (vector-length argv) 0) (vector-ref argv 0)
                                 (or (getenv "MCP_HTTP_PORT") "8910"))))

(define add-schema
  (hasheq 'type "object"
          'properties (hasheq 'a (hasheq 'type "number") 'b (hasheq 'type "number"))
          'required '("a" "b")))

;; JSON-RPC message -> response jsexpr, or #f for a notification (no reply body)
(define (rpc-response msg)
  (define id (hash-ref msg 'id #f))
  (define method (hash-ref msg 'method ""))
  (define (ok r) (hasheq 'jsonrpc "2.0" 'id id 'result r))
  (cond
    [(string=? method "initialize")
     (ok (hasheq 'protocolVersion "2024-11-05" 'capabilities (hasheq 'tools (hasheq))
                 'serverInfo (hasheq 'name "mock-http" 'version "0.1.0")))]
    [(string=? method "notifications/initialized") #f]
    [(string=? method "tools/list")
     (ok (hasheq 'tools (list (hasheq 'name "add" 'description "Add two numbers over HTTP."
                                      'inputSchema add-schema))))]
    [(string=? method "tools/call")
     (define args (hash-ref (hash-ref msg 'params (hasheq)) 'arguments (hasheq)))
     (if (string=? (hash-ref (hash-ref msg 'params (hasheq)) 'name "") "add")
         (ok (hasheq 'content (list (hasheq 'type "text"
                                            'text (format "~a" (+ (hash-ref args 'a 0) (hash-ref args 'b 0)))))))
         (hasheq 'jsonrpc "2.0" 'id id 'error (hasheq 'code -32601 'message "unknown tool")))]
    [id (hasheq 'jsonrpc "2.0" 'id id 'error (hasheq 'code -32601 'message "unknown method"))]
    [else #f]))

(define (read-headers in)
  (let loop ([hs '()])
    (define l (read-line in 'return-linefeed))
    (if (or (eof-object? l) (string=? l "")) (reverse hs) (loop (cons l hs)))))

(define (content-length headers)
  (cond [(for/first ([h (in-list headers)] #:when (regexp-match? #rx"(?i:^content-length:)" h)) h)
         => (lambda (h) (or (string->number (string-trim (cadr (regexp-split #rx":" h)))) 0))]
        [else 0]))

(define (handle in out)
  (with-handlers ([exn:fail? (lambda (_) (void))])
    (read-line in 'return-linefeed)               ; request line
    (define headers (read-headers in))
    (define body (let ([b (read-bytes (content-length headers) in)]) (if (eof-object? b) #"" b)))
    (define msg (with-handlers ([exn:fail? (lambda (_) (hasheq))]) (string->jsexpr (bytes->string/utf-8 body #\?))))
    (define resp (and (hash? msg) (rpc-response msg)))
    (define payload (if resp (jsexpr->bytes resp) #""))
    (write-string (string-append "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
                                 "Content-Length: " (number->string (bytes-length payload)) "\r\n"
                                 "Connection: close\r\n\r\n") out)
    (write-bytes payload out)
    (flush-output out))
  (close-input-port in)
  (close-output-port out))

(define listener (tcp-listen port 64 #t "127.0.0.1"))
(printf "mock-mcp-http on 127.0.0.1:~a\n" port)
(flush-output)
(let loop ()
  (define-values (i o) (tcp-accept listener))
  (thread (lambda () (handle i o)))
  (loop))
