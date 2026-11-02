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
         enabled-tool-schemas agent-tool-schemas tool-settings-for)

;; ---- A WORKFLOW TOOL IS NOT A CONVERSATIONAL TOOL ----------------------------
;;
;; `agent?` is whether the conversational agent may be OFFERED this tool. It is
;; not a permission and not the per-team switch: a tool with `#:agent? #f` is
;; registered, documented, dispatchable, and callable by a workflow step exactly
;; as before — it is simply never put in front of a model that is talking to a
;; person.
;;
;; THE REASON IS THAT THE TOOL LIST HAS TO FIT THE WINDOW AND THE DRAIN LISTERS
;; WERE WINNING IT. `fit-tools` (run.rkt) offers what fits; measured on this
;; build the whole registry is 21,513 characters of JSON schema against a
;; 7,680-character budget at ollama's 4,096-token default, so what is offered is
;; decided by ORDER — and the order was module instantiation order, which is an
;; accident of main.rkt's require list. On the demo instance it spent 7,662 of
;; 7,680 characters on SEVEN document-pipeline tools and withheld all four the
;; agent's own system prompt names.
;;
;; The line is who the caller is. `repo_list_unindexed` exists to feed a `map`
;; step with a page of ids and `repo_extract_text` exists to be that map's child;
;; `doc_classify_eval` scores a fixture set. Not one of them is something a
;; person asks for in a sentence, and `doc_classify_eval`'s schema alone is 2,369
;; characters — 31% of the budget. Offering them is not a feature anybody loses.
;;
;; IT DEFAULTS TO #t, so a plugin's tool keeps appearing with no change, and the
;; per-team `tool_settings` lever is untouched and still works on every tool.
(struct tool (name schema perm handler source agent?) #:transparent)

(define *registry* (box '()))

;; register (or replace) a tool by name; preserves declaration order.
;; `source` is "built-in" for core tools, or a plugin id for loaded plugins.
(define (register-tool! name schema perm handler #:source [source "built-in"] #:agent? [agent? #t])
  (define without (filter (lambda (t) (not (string=? (tool-name t) name))) (unbox *registry*)))
  (set-box! *registry* (append without (list (tool name schema perm handler source agent?)))))

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

;; what the conversational agent may be offered: enabled AND agent-facing.
(define (agent-tool-schemas conn team-id)
  (map tool-schema (filter tool-agent? (enabled-tools conn team-id))))

;; for the management UI: every tool with its permission + current enabled state
(define (tool-settings-for conn team-id)
  (for/list ([t (in-list (all-tools))])
    (hasheq 'name (tool-name t) 'permission (tool-perm t) 'source (tool-source t)
            'agent (tool-agent? t)
            'enabled (tool-enabled? conn team-id (tool-name t)))))
