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
;;   plugin→host  {"type":"result","id","text"[,"result":<jsexpr>]}

(require (only-in "../../config.rkt" impl-root max-upload-bytes) json
         racket/string
         racket/port
         racket/system
         net/base64
         "../agent/registry.rkt"
         "../authz/authz.rkt"
         "../notes/notes.rkt"
         "../repo/repo.rkt"
         (only-in "../repo/extract.rkt" extract-text))

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

;; ---- the repository capabilities (LAY-6) --------------------------------------
;; An out-of-process plugin could reach `notes.create` and `notes.list` and
;; nothing else, so a Python OCR or image-classification pipeline could read no
;; bytes and write no result — while an IN-PROCESS Racket tool read blobs freely.
;; The asymmetry was the bug: every domain pipeline this platform is for is
;; out-of-process.
;;
;; Bytes travel BASE64 over the existing pipe rather than as a path or a URL. A
;; path would couple the plugin to the local store and leak its layout — the blob
;; store is deliberately never handed a principal, only a namespace and a digest,
;; so a backend has no authorization to get wrong. A presigned URL would need the
;; S3 listener running and a second credential. The pipe already carries the
;; double gate, and at the document volumes this is for the inflation is paid once.
;;
;; The ceiling is the SAME one an HTTP upload has: a plugin must not be a way to
;; move something past a limit the front door enforces.
(define (b64 bs) (bytes->string/utf-8 (base64-encode bs #"")))
(define (unb64 s) (base64-decode (string->bytes/utf-8 s)))

(define (cap-object conn p args)
  (define id (jget args 'object))
  (when (string=? id "") (error 'repo "an object id is required"))
  (define-values (o in) (repo-open conn p id #:version (let ([v (jget args 'version)])
                                                         (and (not (string=? v "")) v))))
  (unless in (error 'repo "no such document, or not yours to read: ~a" id))
  (values o in))

(define repo-capabilities
  (hash
   "repo.get"
   (cons "files:read"
         (lambda (conn p args)
           (define-values (o in) (cap-object conn p args))
           (define bs (dynamic-wind void (lambda () (port->bytes in)) (lambda () (close-input-port in))))
           (when (> (bytes-length bs) (max-upload-bytes))
             (error 'repo "document is ~a bytes, over the ~a-byte ceiling for an inline read"
                    (bytes-length bs) (max-upload-bytes)))
           (hasheq 'id (hash-ref o 'id) 'key (hash-ref o 'key)
                   'content_type (hash-ref o 'content_type) 'filename (hash-ref o 'filename "")
                   'version_id (hash-ref o 'version_id) 'size (bytes-length bs)
                   'bytes_b64 (b64 bs))))
   "repo.text"
   (cons "files:read"
         (lambda (conn p args)
           (define-values (o in) (cap-object conn p args))
           (define-values (text reason)
             (dynamic-wind void
                           (lambda () (extract-text in (hash-ref o 'content_type)))
                           (lambda () (close-input-port in))))
           ;; "this PDF is a scan" is a legitimate ANSWER to "what is the text",
           ;; not a failure — and it is precisely the branch an OCR plugin exists
           ;; to take. A plugin should not have to match on an error string to
           ;; find it, so the reason comes back beside a null text.
           (hasheq 'id (hash-ref o 'id) 'key (hash-ref o 'key)
                   'content_type (hash-ref o 'content_type)
                   'text (or text 'null)
                   'reason (if reason (symbol->string reason) 'null))))
   "repo.put"
   (cons "files:write"
         (lambda (conn p args)
           (define key (jget args 'key))
           (define b64s (jget args 'bytes_b64))
           (when (string=? key "") (error 'repo "a key is required"))
           (when (string=? b64s "") (error 'repo "bytes_b64 is required"))
           (define bs (with-handlers ([exn:fail? (lambda (_) (error 'repo "bytes_b64 is not valid base64"))])
                        (unb64 b64s)))
           (when (> (bytes-length bs) (max-upload-bytes))
             (error 'repo "~a bytes, over the ~a-byte ceiling" (bytes-length bs) (max-upload-bytes)))
           (define from (let ([v (jget args 'derived_from)]) (and (not (string=? v "")) v)))
           (define src (and from (repo-get conn p from)))
           (when (and from (not src)) (error 'repo "derived_from names no document you can read: ~a" from))
           ;; A derived document is PRIVATE FROM ITS FIRST BYTE: repo-put! takes the
           ;; source's visibility, and only then does repo-inherit! copy the grants
           ;; and write the derivation row. Do not reorder those.
           ;; #:derived? keeps an opted-in trigger from firing on this plugin's own
           ;; output, which is the loop that bit the pipeline once already.
           (define o (repo-put! conn p #:key key #:port (open-input-bytes bs)
                                #:content-type (let ([c (jget args 'content_type)])
                                                 (if (string=? c "") "application/octet-stream" c))
                                #:filename (let ([f (jget args 'filename)])
                                             (if (string=? f "") key f))
                                #:visibility (and src (hash-ref src 'visibility))
                                #:max-bytes (max-upload-bytes)
                                #:derived? (and src #t)))
           (when src (repo-inherit! conn p #:source (hash-ref src 'id) #:target (hash-ref o 'id)))
           (hasheq 'object_id (hash-ref o 'id) 'version_id (hash-ref o 'version_id)
                   'key (hash-ref o 'key) 'version (hash-ref o 'version)
                   'derived_from (if src (hash-ref src 'id) 'null))))))

(define capability-table
  (for/fold ([h capabilities]) ([(k v) (in-hash repo-capabilities)]) (hash-set h k v)))

(define (capability-names) (sort (hash-keys capability-table) string<?))

;; run a capability with the double gate (declared scope ∩ user RBAC).
;; returns (hasheq 'ok result) or (hasheq 'error reason)
(define (run-capability scopes conn principal cap args)
  (define entry (hash-ref capability-table cap #f))
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
             ;; issue #46: an out-of-process tool may answer with STRUCTURE beside
             ;; its text. Returning only `text` made every such result a JSON
             ;; string by the time a workflow saw it, so a later step could not
             ;; bind `…output.result.status` without an in-process shim whose
             ;; whole job was to parse what the platform had just stringified.
             ;; An in-process tool has been able to return a jsexpr for slices;
             ;; this closes the gap. `text` alone still behaves exactly as before,
             ;; and the platform never GUESSES that a string was meant to be JSON
             ;; — the plugin says so by sending `result`.
             [(equal? (hash-ref m 'type #f) "result")
              (if (hash-has-key? m 'result)
                  (hash-ref m 'result)
                  (format "~a" (hash-ref m 'text "")))]
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
