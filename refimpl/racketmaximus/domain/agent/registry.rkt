#lang racket/base

;; domain/agent/registry.rkt — the tool registry: the plugin SDK contract.
;;
;; A tool is (name, schema, permission, handler). Registering one is all it takes
;; to extend the platform — first-party or third-party alike:
;;
;;   (register-tool! "create_note" <define-tool schema> "notes:write"
;;                   (lambda (conn principal args) -> result-string))
;;
;; Per-team activation lives in `tool_settings` (absent row = enabled). The agent
;; only offers ENABLED tools to the model, and dispatch refuses disabled ones.

(require db-kit/portable "../db/id.rkt")

(provide (struct-out tool)
         register-tool! all-tools tool-by-name
         tool-enabled? set-tool-enabled!
         enabled-tools enabled-tool-schemas tool-settings-for)

(struct tool (name schema perm handler source) #:transparent)

(define *registry* (box '()))

;; register (or replace) a tool by name; preserves declaration order.
;; `source` is "built-in" for core tools, or a plugin id for loaded plugins.
(define (register-tool! name schema perm handler #:source [source "built-in"])
  (define without (filter (lambda (t) (not (string=? (tool-name t) name))) (unbox *registry*)))
  (set-box! *registry* (append without (list (tool name schema perm handler source)))))

(define (all-tools) (unbox *registry*))
(define (tool-by-name name) (findf (lambda (t) (string=? (tool-name t) name)) (all-tools)))

;; per-team enable/disable — default enabled unless a row says otherwise
(define (tool-enabled? conn team-id name)
  (define v (query-maybe-value conn
    "SELECT enabled FROM tool_settings WHERE team_id = ? AND tool_name = ?" team-id name))
  (or (not v) (sql-null? v) (not (zero? v))))

(define (set-tool-enabled! conn team-id name on?)
  (query-exec conn
    (string-append "INSERT INTO tool_settings (id, team_id, tool_name, enabled) VALUES (?, ?, ?, ?) "
                   "ON CONFLICT(team_id, tool_name) DO UPDATE SET enabled = excluded.enabled, "
                   "updated_at = CURRENT_TIMESTAMP")
    (new-id) team-id name (if on? 1 0)))

(define (enabled-tools conn team-id)
  (filter (lambda (t) (tool-enabled? conn team-id (tool-name t))) (all-tools)))

(define (enabled-tool-schemas conn team-id) (map tool-schema (enabled-tools conn team-id)))

;; for the management UI: every tool with its permission + current enabled state
(define (tool-settings-for conn team-id)
  (for/list ([t (in-list (all-tools))])
    (hasheq 'name (tool-name t) 'permission (tool-perm t) 'source (tool-source t)
            'enabled (tool-enabled? conn team-id (tool-name t)))))
