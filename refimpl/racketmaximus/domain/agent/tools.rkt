#lang racket/base

;; domain/agent/tools.rkt — the agent's tool catalog (fresh Telemachus schemas).
;; A small, real starting set that lets the model *operate the platform*. Each
;; tool maps to a permission checked at dispatch (RBAC), and to a handler in
;; agent/run.rkt. Adding a third-party tool later is: a define-tool schema + a
;; permission + a handler — the seed of the plugin SDK.

(require "../tools/dsl.rkt")

(provide agent-tool-schemas tool-permission)

(reset-tools!)   ; the DSL registry is a module global; start clean

(define-tool create_note
  #:description "Create a note for the current user's team."
  (title      string #:description "Short note title")
  (body       string #:description "Note body text")
  (visibility string #:optional #:enum ("team" "private" "shared")
              #:description "Who can see it; defaults to team"))

(define-tool list_notes
  #:description "List the current user's notes (title and visibility).")

(define-tool get_usage
  #:description "Report the team's current AI usage against its quota.")

(define (agent-tool-schemas) (all-tool-schemas))

;; tool name → the permission required to invoke it (checked at dispatch)
(define tool-permission
  (hash "create_note" "notes:write"
        "list_notes"  "notes:read"
        "get_usage"   "chat:use"))
