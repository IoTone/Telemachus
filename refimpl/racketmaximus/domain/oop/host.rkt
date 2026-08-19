#lang racket/base

;; domain/oop/host.rkt — sandboxed, out-of-process plugins.
;;
;; A plugin runs as a SUBPROCESS and never touches the database. It declares its
;; tools and the capability SCOPES it needs; to do anything on the platform it
;; asks the host over the pipe, and the host mediates through a small capability
;; API that is DOUBLE-GATED: the plugin must have declared the scope, AND the
;; calling user must have the matching RBAC permission.
;;
;; Protocol (newline-delimited JSON over stdio):
;;   host→plugin  {"type":"describe"}
;;   plugin→host  {"type":"manifest","name","version","scopes":[…],
;;                 "tools":[{"name","description","inputSchema","permission"}]}
;;   host→plugin  {"type":"call","id","tool","args"}
;;   plugin→host  {"type":"host","id","cap":"notes.create","args":{…}}   (capability request)
;;   host→plugin  {"type":"host_result","id","result":{…}} | {"type":"host_error","id","error"}
;;   plugin→host  {"type":"result","id","text"}

(require (only-in "../../config.rkt" impl-root) json
         racket/string
         racket/port
         racket/system
         "../agent/registry.rkt"
         "../authz/authz.rkt"
         "../notes/notes.rkt")

(provide (struct-out oop-plugin)
         connect-oop-plugins! loaded-oop-plugins
         run-capability capability-names)

(struct oop-plugin (name scopes proc out in lock) #:transparent)

(define *loaded* (box '()))
(define (loaded-oop-plugins) (unbox *loaded*))

;; ---- the capability API (host operations a plugin may request) --------------
;; cap-name -> (permission . (conn principal args) -> jsexpr)
(define (jget h k [d ""]) (let ([v (hash-ref h k d)]) (if (eq? v 'null) d v)))

(define capabilities
  (hash
   "notes.create"
   (cons "notes:write"
         (lambda (conn p args)
           (define vis (let ([v (jget args 'visibility "team")]) (if (string=? v "") "team" v)))
           (define n (notes-create conn p #:title (jget args 'title "Note") #:body (jget args 'body) #:visibility vis))
           (hasheq 'id (hash-ref n 'id) 'title (hash-ref n 'title))))
   "notes.list"
   (cons "notes:read"
         (lambda (conn p args)
           (hasheq 'notes (for/list ([n (in-list (notes-list conn p))])
                            (hasheq 'id (hash-ref n 'id) 'title (hash-ref n 'title) 'visibility (hash-ref n 'visibility))))))))

(define (capability-names) (sort (hash-keys capabilities) string<?))

;; run a capability with the double gate (declared scope ∩ user RBAC).
;; returns (hasheq 'ok result) or (hasheq 'error reason)
(define (run-capability scopes conn principal cap args)
  (define entry (hash-ref capabilities cap #f))
  (cond
    [(not entry) (hasheq 'error (format "unknown capability: ~a" cap))]
    [(not (member (car entry) scopes)) (hasheq 'error (format "plugin not granted scope: ~a" (car entry)))]
    [(not (can? conn principal (car entry))) (hasheq 'error (format "permission denied: ~a" (car entry)))]
    [else (with-handlers ([exn:fail? (lambda (e) (hasheq 'error (exn-message e)))])
            (hasheq 'ok ((cdr entry) conn principal args)))]))

;; ---- pipe helpers -----------------------------------------------------------
(define (send-line p obj)
  (write-json obj (oop-plugin-in p)) (write-char #\newline (oop-plugin-in p)) (flush-output (oop-plugin-in p)))
(define (read-line/timeout port secs)
  (let ([r (sync/timeout secs (read-line-evt port 'any))]) (if r r eof)))
(define (parse s) (with-handlers ([exn:fail? (lambda (_) #f)]) (string->jsexpr s)))
(define (resolve command)
  (cond [(absolute-path? command) command] [(find-executable-path command) => values] [else command]))

;; …and the same for the script it is handed: relative means relative to the
;; implementation root, not to the server's current working directory.
(define (resolve-arg a)
  (if (and (string? a) (regexp-match #rx"[.]rkt$" a) (not (absolute-path? a))
           (file-exists? (build-path impl-root a)))
      (path->string (build-path impl-root a))
      a))

;; ---- call a plugin tool, servicing its capability requests ------------------
(define (oop-call plugin conn principal tool args #:timeout [secs 30])
  (call-with-semaphore (oop-plugin-lock plugin)
    (lambda ()
      (send-line plugin (hasheq 'type "call" 'id 1 'tool tool 'args args))
      (let loop ()
        (define line (read-line/timeout (oop-plugin-out plugin) secs))
        (cond
          [(eof-object? line) "Error: plugin closed the connection"]
          [(string=? (string-trim line) "") (loop)]
          [else
           (define m (parse line))
           (cond
             [(not (hash? m)) (loop)]
             [(equal? (hash-ref m 'type #f) "host")
              (define res (run-capability (oop-plugin-scopes plugin) conn principal
                                          (hash-ref m 'cap "") (hash-ref m 'args (hasheq))))
              (send-line plugin (if (hash-has-key? res 'error)
                                    (hasheq 'type "host_error" 'id (hash-ref m 'id #f) 'error (hash-ref res 'error))
                                    (hasheq 'type "host_result" 'id (hash-ref m 'id #f) 'result (hash-ref res 'ok))))
              (loop)]
             [(equal? (hash-ref m 'type #f) "result") (format "~a" (hash-ref m 'text ""))]
             [else (loop)])])))))

;; ---- connect + register -----------------------------------------------------
(define (oop-connect name command args #:timeout [secs 15])
  (define-values (proc out in err) (apply subprocess #f #f #f (resolve command) (map resolve-arg args)))
  (define p0 (oop-plugin name '() proc out in (make-semaphore 1)))
  (send-line p0 (hasheq 'type "describe"))
  (let loop ()
    (define line (read-line/timeout out secs))
    (cond
      [(eof-object? line) (error 'oop "no manifest from plugin")]
      [(string=? (string-trim line) "") (loop)]
      [else
       (define m (parse line))
       (cond
         [(and (hash? m) (equal? (hash-ref m 'type #f) "manifest"))
          (define scopes (let ([s (hash-ref m 'scopes '())]) (if (list? s) s '())))
          (values (struct-copy oop-plugin p0 [scopes scopes])
                  (let ([t (hash-ref m 'tools '())]) (if (list? t) t '())))]
         [else (loop)])])))

(define (tool->schema plugin-name t)
  (hasheq 'type "function"
          'function (hasheq 'name (string-append "oop__" plugin-name "__" (hash-ref t 'name))
                            'description (hash-ref t 'description "")
                            'parameters (let ([p (hash-ref t 'inputSchema #f)]) (if (hash? p) p (hasheq 'type "object" 'properties (hasheq)))))))

(define (register-oop! plugin tools)
  (for/list ([t (in-list tools)] #:when (and (hash? t) (string? (hash-ref t 'name #f))))
    (define orig (hash-ref t 'name))
    (define full (string-append "oop__" (oop-plugin-name plugin) "__" orig))
    (register-tool! full (tool->schema (oop-plugin-name plugin) t) (hash-ref t 'permission "tools:invoke")
                    (lambda (conn principal args) (oop-call plugin conn principal orig args))
                    #:source (string-append "oop:" (oop-plugin-name plugin)))
    full))

(define (connect-oop-plugins! config-path #:log [log void])
  (set-box! *loaded* '())
  (when (file-exists? config-path)
    (define cfg (with-handlers ([exn:fail? (lambda (_) (hasheq))]) (call-with-input-file config-path read-json)))
    (for ([s (in-list (let ([ps (hash-ref cfg 'plugins '())]) (if (list? ps) ps '())))]
          #:when (and (hash? s) (hash-ref s 'command #f)))
      (define name (hash-ref s 'name "oop"))
      (with-handlers ([exn:fail? (lambda (e) (log (format "~a: failed — ~a" name (exn-message e))))])
        (define args (let ([a (hash-ref s 'args '())]) (if (list? a) (map (lambda (x) (format "~a" x)) a) '())))
        (define-values (plugin tools) (oop-connect name (format "~a" (hash-ref s 'command)) args))
        (define names (register-oop! plugin tools))
        (set-box! *loaded* (append (unbox *loaded*)
                                   (list (hasheq 'name name 'scopes (oop-plugin-scopes plugin) 'tools names))))
        (log (format "~a — ~a tool(s), scopes ~a" name (length names) (oop-plugin-scopes plugin))))))
  (unbox *loaded*))
