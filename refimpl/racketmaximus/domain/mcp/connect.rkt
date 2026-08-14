#lang racket/base

;; domain/mcp/connect.rkt — connect to configured MCP servers and register their
;; tools into the platform registry, so the agent can use them like any other
;; tool (RBAC + per-team activation apply, source = "mcp:<server>").
;;
;; Config (JSON):
;;   { "servers": [ { "name": "fs", "command": "npx", "args": ["-y", "@…/server"] } ] }
;;
;; A tool `t` on server `s` registers as `mcp__<s>__<t>` and dispatches to the
;; live MCP connection.

(require json
         "client.rkt"
         "../agent/registry.rkt")

(provide connect-mcp-servers! mcp-servers)

(define *servers* (box '()))
(define (mcp-servers) (unbox *servers*))

(define (mcp-tool->schema full-name t)
  (hasheq 'type "function"
          'function (hasheq 'name full-name
                            'description (hash-ref t 'description "")
                            'parameters (let ([p (hash-ref t 'inputSchema #f)])
                                          (if (hash? p) p (hasheq 'type "object" 'properties (hasheq)))))))

(define (register-server! server conn tools #:log [log void])
  (define names
    (for/list ([t (in-list tools)] #:when (and (hash? t) (string? (hash-ref t 'name #f))))
      (define orig (hash-ref t 'name))
      (define full (string-append "mcp__" server "__" orig))
      (register-tool! full (mcp-tool->schema full t) "tools:invoke"
                      (lambda (_conn _p args) (mcp-call-tool conn orig args))
                      #:source (string-append "mcp:" server))
      full))
  (set-box! *servers* (append (unbox *servers*) (list (hasheq 'name server 'tools names))))
  (log (format "~a — ~a tool(s)" server (length names)))
  names)

(define (connect-mcp-servers! config-path #:log [log void])
  (set-box! *servers* '())
  (when (file-exists? config-path)
    (define cfg (with-handlers ([exn:fail? (lambda (_) (hasheq))])
                  (call-with-input-file config-path read-json)))
    (for ([s (in-list (let ([ss (hash-ref cfg 'servers '())]) (if (list? ss) ss '())))]
          #:when (and (hash? s) (or (hash-ref s 'command #f) (hash-ref s 'url #f))))
      (define name (hash-ref s 'name "mcp"))
      (with-handlers ([exn:fail? (lambda (e) (log (format "~a: failed — ~a" name (exn-message e))))])
        (define conn
          (cond
            [(hash-ref s 'url #f) => (lambda (u) (mcp-connect-http (format "~a" u)))]      ; Streamable HTTP
            [else (mcp-connect-stdio (format "~a" (hash-ref s 'command))                  ; stdio subprocess
                                     (let ([a (hash-ref s 'args '())])
                                       (if (list? a) (map (lambda (x) (format "~a" x)) a) '())))]))
        (register-server! name conn (mcp-list-tools conn) #:log log))))
  (unbox *servers*))
