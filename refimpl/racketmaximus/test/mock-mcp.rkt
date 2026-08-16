#lang racket/base

;; test/mock-mcp.rkt — a minimal MCP server over stdio (newline-delimited
;; JSON-RPC 2.0) for testing the client. Exposes one tool: `add`.
;;   racket test/mock-mcp.rkt

(require json racket/string)

(define add-schema
  (hasheq 'type "object"
          'properties (hasheq 'a (hasheq 'type "number") 'b (hasheq 'type "number"))
          'required '("a" "b")))

(define (send obj) (write-json obj) (newline) (flush-output))
(define (result id r) (send (hasheq 'jsonrpc "2.0" 'id id 'result r)))
(define (rpc-error id msg) (send (hasheq 'jsonrpc "2.0" 'id id 'error (hasheq 'code -32601 'message msg))))

(let loop ()
  (define line (read-line (current-input-port) 'any))
  (unless (eof-object? line)
    (unless (string=? (string-trim line) "")
      (define msg (with-handlers ([exn:fail? (lambda (_) #f)]) (string->jsexpr line)))
      (when (hash? msg)
        (define id (hash-ref msg 'id #f))
        (define method (hash-ref msg 'method ""))
        (cond
          [(string=? method "initialize")
           (result id (hasheq 'protocolVersion "2024-11-05"
                              'capabilities (hasheq 'tools (hasheq))
                              'serverInfo (hasheq 'name "mock-mcp" 'version "0.1.0")))]
          [(string=? method "notifications/initialized") (void)]     ; notification
          [(string=? method "tools/list")
           (result id (hasheq 'tools (list (hasheq 'name "add"
                                                   'description "Add two numbers and return the sum."
                                                   'inputSchema add-schema))))]
          [(string=? method "tools/call")
           (define params (hash-ref msg 'params (hasheq)))
           (define nm (hash-ref params 'name ""))
           (define args (hash-ref params 'arguments (hasheq)))
           (cond
             [(string=? nm "add")
              (define a (hash-ref args 'a 0)) (define b (hash-ref args 'b 0))
              (result id (hasheq 'content (list (hasheq 'type "text" 'text (format "~a" (+ a b))))))]
             [else (rpc-error id "unknown tool")])]
          [id (rpc-error id "unknown method")]
          [else (void)])))
    (loop)))
