#lang racket/base

;; oop-plugins/notes-helper/main.rkt — an out-of-process, sandboxed plugin.
;;
;; It has NO database handle and NO platform imports. It declares the scope it
;; needs ("notes:write") and does its work by asking the host for a capability
;; ("notes.create"). The host runs it only if the plugin declared the scope AND
;; the calling user has the matching RBAC permission.
;;
;; Speaks newline-delimited JSON over stdio (see domain/oop/host.rkt).

(require json racket/string)

(define (emit obj) (write-json obj) (newline) (flush-output))

(define (next)                              ; read one JSON message (skip blanks/junk)
  (let loop ()
    (define l (read-line))
    (cond [(eof-object? l) eof]
          [(string=? (string-trim l) "") (loop)]
          [else (with-handlers ([exn:fail? (lambda (_) (loop))]) (string->jsexpr l))])))

(define manifest
  (hasheq 'type "manifest" 'name "notes-helper" 'version "0.1.0"
          'scopes '("notes:write")
          'tools (list (hasheq 'name "save_idea"
                               'description "Save a short idea as a private note for the current user."
                               'permission "notes:write"
                               'inputSchema (hasheq 'type "object"
                                                    'properties (hasheq 'idea (hasheq 'type "string" 'description "the idea to save"))
                                                    'required '("idea"))))))

(let loop ()
  (define m (next))
  (unless (eof-object? m)
    (when (hash? m)
      (case (hash-ref m 'type "")
        [("describe") (emit manifest)]
        [("call")
         (define idea (hash-ref (hash-ref m 'args (hasheq)) 'idea ""))
         ;; ask the host to create a note — the host enforces scope ∩ RBAC
         (emit (hasheq 'type "host" 'id 1 'cap "notes.create"
                       'args (hasheq 'title "Idea" 'body idea 'visibility "private")))
         (define hr (next))
         (define text
           (cond
             [(and (hash? hr) (equal? (hash-ref hr 'type #f) "host_result"))
              (format "Saved your idea as private note #~a." (hash-ref (hash-ref hr 'result (hasheq)) 'id "?"))]
             [(hash? hr) (format "Couldn't save the idea: ~a" (hash-ref hr 'error "denied"))]
             [else "Couldn't save the idea."]))
         (emit (hasheq 'type "result" 'id (hash-ref m 'id 1) 'text text))]
        [else (void)]))
    (loop)))
