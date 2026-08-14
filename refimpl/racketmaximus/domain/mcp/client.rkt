#lang racket/base

;; domain/mcp/client.rkt — a minimal Model Context Protocol client (stdio
;; transport, JSON-RPC 2.0, newline-delimited). Connects to an MCP server
;; subprocess, does the initialize handshake, and can list + call tools.
;;
;; Calls on one connection are serialized (a semaphore) so concurrent agent
;; requests don't interleave on the shared pipe.

(require json
         racket/string
         racket/port
         racket/system)

(provide (struct-out mcp-conn)
         mcp-connect mcp-close mcp-list-tools mcp-call-tool)

(struct mcp-conn (proc out in err lock id-box) #:transparent)

(define (resolve-cmd command)
  (cond [(absolute-path? command) command]
        [(find-executable-path command) => values]
        [else command]))

(define (mcp-connect command args #:init-timeout [t 15])
  (define exe (resolve-cmd command))
  (define-values (proc out in err) (apply subprocess #f #f #f exe args))
  (define c (mcp-conn proc out in err (make-semaphore 1) (box 0)))
  (request c "initialize"
           (hasheq 'protocolVersion "2024-11-05" 'capabilities (hasheq)
                   'clientInfo (hasheq 'name "telemachus" 'version "0.5.0"))
           t)
  (notify c "notifications/initialized" (hasheq))
  c)

(define (mcp-close c)
  (with-handlers ([exn:fail? void])
    (close-output-port (mcp-conn-in c))
    (subprocess-kill (mcp-conn-proc c) #t)))

;; ---- JSON-RPC over the pipe -------------------------------------------------
(define (send-obj c obj)
  (write-json obj (mcp-conn-in c))
  (write-char #\newline (mcp-conn-in c))
  (flush-output (mcp-conn-in c)))

(define (notify c method params)
  (call-with-semaphore (mcp-conn-lock c)
    (lambda () (send-obj c (hasheq 'jsonrpc "2.0" 'method method 'params params)))))

(define (read-line/timeout port secs)
  (define r (sync/timeout secs (read-line-evt port 'any)))
  (if r r eof))

(define (request c method params [secs 20])
  (call-with-semaphore (mcp-conn-lock c)
    (lambda ()
      (define id (add1 (unbox (mcp-conn-id-box c))))
      (set-box! (mcp-conn-id-box c) id)
      (send-obj c (hasheq 'jsonrpc "2.0" 'id id 'method method 'params params))
      (let loop ()
        (define line (read-line/timeout (mcp-conn-out c) secs))
        (cond
          [(eof-object? line) (error 'mcp "no response from server (~a)" method)]
          [(string=? (string-trim line) "") (loop)]
          [else
           (define msg (with-handlers ([exn:fail? (lambda (_) #f)]) (string->jsexpr line)))
           (cond
             [(not (hash? msg)) (loop)]
             [(not (equal? (hash-ref msg 'id #f) id)) (loop)]     ; skip notifications / other ids
             [(hash-has-key? msg 'error)
              (error 'mcp "~a" (hash-ref (hash-ref msg 'error) 'message "error"))]
             [else (hash-ref msg 'result (hasheq))])])))))

;; ---- tools ------------------------------------------------------------------
(define (mcp-list-tools c)
  (define r (request c "tools/list" (hasheq)))
  (let ([ts (hash-ref r 'tools '())]) (if (list? ts) ts '())))

;; returns the text content of the tool result
(define (mcp-call-tool c name args)
  (define r (request c "tools/call" (hasheq 'name name 'arguments args)))
  (define content (let ([x (hash-ref r 'content '())]) (if (list? x) x '())))
  (string-join
   (for/list ([blk (in-list content)] #:when (and (hash? blk) (equal? (hash-ref blk 'type #f) "text")))
     (format "~a" (hash-ref blk 'text "")))
   "\n"))
