#lang racket/base

;; domain/agent/tools.rkt — the built-in tool catalog, registered through the
;; plugin SDK (registry.rkt). Each tool is defined in one place: a `define-tool`
;; schema, the permission it needs, and a handler. This is exactly how a
;; third-party plugin would add a tool.

(require racket/string
         "../tools/dsl.rkt"
         "registry.rkt"
         "../notes/notes.rkt"
         "../quota/quota.rkt"
         "../authz/authz.rkt")            ; principal-team-id

(reset-tools!)   ; the DSL schema-builder registry is a module global; start clean

;; ---- schemas ----------------------------------------------------------------
(define-tool create_note
  #:description "Create a note for the current user's team."
  (title      string #:description "Short note title")
  (body       string #:description "Note body text")
  (visibility string #:optional #:enum ("team" "private" "shared")
              #:description "Who can see it; defaults to team"))

(define-tool update_note
  #:description "Update a note's title and/or body by id."
  (id    string #:description "The note id")
  (title string #:optional #:description "New title (optional)")
  (body  string #:optional #:description "New body (optional)"))

(define-tool list_notes
  #:description "List the current user's notes (title and visibility).")

(define-tool get_usage
  #:description "Report the team's current AI usage against its quota.")

;; ---- handler helpers --------------------------------------------------------
(define (req args k [d ""]) (let ([v (hash-ref args k d)]) (if (eq? v 'null) d v)))
(define (opt args k) (let ([v (hash-ref args k #f)]) (if (or (not v) (eq? v 'null)) #f (format "~a" v))))

;; ---- registrations (schema + permission + handler) --------------------------
(register-tool! "create_note" create_note "notes:write"
  (lambda (conn p args)
    (define vis (let ([v (req args 'visibility "team")]) (if (string=? v "") "team" v)))
    (define n (notes-create conn p #:title (req args 'title) #:body (req args 'body) #:visibility vis))
    (format "Created note \"~a\" (~a), id ~a" (hash-ref n 'title) (hash-ref n 'visibility) (hash-ref n 'id))))

(register-tool! "update_note" update_note "notes:write"
  (lambda (conn p args)
    (define n (notes-update conn p (req args 'id) #:title (opt args 'title) #:body (opt args 'body)))
    (if n (format "Updated note \"~a\" (id ~a)" (hash-ref n 'title) (hash-ref n 'id)) "Note not found")))

(register-tool! "list_notes" list_notes "notes:read"
  (lambda (conn p args)
    (define ns (notes-list conn p))
    (if (null? ns) "You have no notes."
        (string-join (for/list ([n (in-list ns)]) (format "- ~a [~a]" (hash-ref n 'title) (hash-ref n 'visibility))) "\n"))))

(register-tool! "get_usage" get_usage "chat:use"
  (lambda (conn p args)
    (string-join
     (for/list ([d (in-list '("ai.tokens.total" "ai.requests"))])
       (define q (quota-check conn "team" (principal-team-id p) d 0))
       (format "~a: ~a/~a used" d (hash-ref q 'used) (hash-ref q 'limit))) "; ")))
