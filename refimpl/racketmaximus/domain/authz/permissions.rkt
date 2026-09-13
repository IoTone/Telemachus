#lang racket/base

;; domain/authz/permissions.rkt — the permission catalog + built-in roles.
;;
;; Permissions are "resource:action" strings. Roles are named permission sets.
;; Wildcards: "documents:*", "*:read", "*:*". `instance:*` is the operator tier —
;; the authorization check grants it ONLY to is_operator principals, never via a
;; team role (decision RBAC-5), so owner's "*:*" does not reach it.

(require racket/string)

(provide perm-matches? instance-perm? org-perm? split-perm
         builtin-role-keys builtin-role-names builtin-role-perms
         builtin-org-role-keys org-role-key?
         permission-doc permission-tier all-permissions)

(define (split-perm p)
  (define parts (string-split p ":"))
  (values (if (pair? parts) (car parts) "")
          (if (and (pair? parts) (pair? (cdr parts))) (cadr parts) "")))

(define (instance-perm? p) (string-prefix? p "instance:"))

;; `org:*` is the company-administration tier (slice 45). Like instance:*, it is
;; NOT reachable from a team role — a team owner's "*:*" stewards one team, it does
;; not administer the company. Granted only via users.org_role_key.
(define (org-perm? p) (string-prefix? p "org:"))

;; does a granted permission (possibly wildcarded) cover a required one?
(define (perm-matches? granted required)
  (or (string=? granted required)
      (string=? granted "*:*")
      (let-values ([(gr ga) (split-perm granted)]
                   [(rr ra) (split-perm required)])
        (and (or (string=? gr "*") (string=? gr rr))
             (or (string=? ga "*") (string=? ga ra))))))

(define builtin-org-role-keys '("org_owner" "org_admin"))
(define (org-role-key? k) (and (member k builtin-org-role-keys) #t))

;; team roles + the two org roles. Org roles live in the same `roles` table with
;; team_id NULL, so a deployer can retune what a company admin may do without a
;; release — the tier is enforced in code, its contents are data.
(define builtin-role-keys
  (append '("owner" "admin" "member" "viewer") builtin-org-role-keys))

(define builtin-role-names
  (hash "owner" "Owner" "admin" "Admin" "member" "Member" "viewer" "Viewer"
        "org_owner" "Organization Owner" "org_admin" "Organization Admin"))

;; Built-in team roles (team_id NULL). Note: none includes `instance:*` — that
;; tier is operator-only and enforced in the authz check, not by role data.
(define builtin-role-perms
  (hash
   ;; team steward — everything team-scoped (incl. team:delete, quota:manage,
   ;; roles:manage). "*:*" never reaches instance:* (guarded in authz).
   "owner"  '("*:*")
   ;; manage without destroying — no team:delete / quota:manage / roles:manage
   "admin"  '("members:manage" "tokens:manage" "webhooks:manage" "settings:manage"
              "models:serve" "roles:read" "audit:read"
              "chat:use" "tools:invoke" "research:use"
              "documents:read" "documents:write" "documents:delete"
              "notes:read" "notes:write" "notes:delete"
              "tasks:read" "tasks:write" "tasks:delete"
              "memory:read" "memory:write"
              ;; files:manage (DSH-1): change visibility, share, revoke — the
              ;; stewardship of a document. An owner holds it by owner-ok; a team
              ;; admin holds it here; anyone else needs a `manage` grant.
              "files:read" "files:write" "files:delete" "files:manage"
              "localization:read" "localization:translate" "localization:review"
              "localization:manage"
              "workflows:read" "workflows:write" "workflows:run")
   ;; use AI + own resources
   "member" '("chat:use" "tools:invoke" "research:use"
              "documents:read" "documents:write"
              "notes:read" "notes:write"
              "tasks:read" "tasks:write"
              "memory:read" "memory:write"
              ;; files:delete is granted here too — a member may delete their OWN
              ;; documents (owner-ok), and resource-reachability still stops them
              ;; touching a colleague's private one.
              "files:read" "files:write" "files:delete"
              "localization:read" "localization:translate"
              "workflows:read" "workflows:run")
   ;; read team-visible resources; no AI spend, no mutation
   "viewer" '("*:read")
   ;; ---- org tier (slice 45) — company administration ------------------------
   ;; TEN-2a: an org admin MANAGES but does not READ. No documents:read /
   ;; notes:read / chat:use here — a company admin who needs a team's data joins
   ;; that team as a member, and the join is audited. Never `instance:*`.
   ;; WF-7: `workflows:read` and NOT `workflows:run` — running someone's workflow
   ;; is reading their data by proxy, which is exactly what TEN-2a forbids.
   "org_admin" '("org:read" "org:manage"
                 "team:read" "team:write" "team:create"
                 "members:manage" "roles:manage" "roles:read"
                 "quota:manage" "quota:read"
                 "settings:manage" "features:manage" "tokens:manage"
                 "audit:read" "workflows:read")
   ;; the org steward — everything org_admin has, plus destroying and paying for
   ;; the company. Still not `instance:*`.
   "org_owner" '("org:*"
                 "team:read" "team:write" "team:create" "team:delete"
                 "members:manage" "roles:manage" "roles:read"
                 "quota:manage" "quota:read"
                 "settings:manage" "features:manage" "tokens:manage"
                 "audit:read" "workflows:read")))

;; ---- the catalog, described (slice 60, DOCGEN-3) -----------------------------------
;; One line per permission, beside the declaration rather than in a table that
;; drifts. docs/reference/permissions.md is rendered from this, and the check at
;; the bottom makes a role permission with no description a LOAD error — the same
;; move as a console key in no review group.
(define PERMISSION-DOCS
  (hash
   "*:*"          "Everything at the team tier. Never reaches instance:* or org:*."
   "*:read"       "Read every team-visible resource; no AI spend, no mutation."
   "members:manage" "Add and remove team members and set their roles."
   "tokens:manage"  "Issue and revoke API tokens for the team."
   "webhooks:manage" "Configure outbound webhooks."
   "settings:manage" "Team settings: tokens, feature flags, tool activation, the glossary, seeding, the audit trail."
   "models:serve"   "Register a model executor for the team."
   "roles:read"     "See the team's roles and what they grant."
   "roles:manage"   "Create and edit team roles."
   "audit:read"     "Read the audit trail."
   "chat:use"       "Talk to the model: chat, the agent, translation, AI tools. Metered."
   "tools:invoke"   "Call tools from the agent or a workflow step; each tool then checks its own permission."
   "research:use"   "Use the research surfaces."
   "documents:read"   "Read text documents."
   "documents:write"  "Create and edit text documents."
   "documents:delete" "Delete text documents."
   "notes:read"     "Read notes."
   "notes:write"    "Create and edit notes."
   "notes:delete"   "Delete notes."
   "notes:manage"   "Share notes one does not own."
   "tasks:read"     "Read tasks."
   "tasks:write"    "Create and edit tasks."
   "tasks:delete"   "Delete tasks."
   "memory:read"    "Read the agent's memory."
   "memory:write"   "Write to the agent's memory."
   "files:read"     "Open, download and search repository documents; read provenance and the knowledge graph."
   "files:write"    "Upload documents and new versions."
   "files:delete"   "Delete repository documents."
   "files:manage"   "Steward a document: change visibility, share and revoke. Owners hold it by owner-ok; a manage grant delegates it for one document."
   "localization:read"      "See the Localization Manager's coverage and messages."
   "localization:translate" "Submit translations."
   "localization:review"    "Approve or send back a colleague's translation (never one's own)."
   "localization:manage"    "Import and export catalogs, queue AI drafts, discard machine drafts."
   "workflows:read"  "See workflow definitions, runs and triggers."
   "workflows:write" "Publish workflows and manage triggers."
   "workflows:run"   "Start and cancel runs. An S3 key needs this scope for its uploads to fire triggers."
   "team:read"    "See a team in the company."
   "team:write"   "Rename a team in the company."
   "team:create"  "Create a team in the company."
   "team:delete"  "Delete a team."
   "quota:read"   "See quotas."
   "quota:manage" "Set quotas."
   "features:manage" "Turn features on and off for teams."
   "org:*"      "Everything at the company tier. Never reaches instance:*."
   "org:read"   "See the company, its teams, members and audit trail."
   "org:manage" "Administer the company: teams and members. Manages, does not read, team data (TEN-2a)."
   "instance:*"      "Everything at the instance tier; the operator (superadmin)."
   "instance:manage" "Instance administration: branding, localization policy, quotas, orgs, metrics."))

(define (permission-doc p)
  (hash-ref PERMISSION-DOCS p
            (lambda () (error 'permissions "permission ~s has no description — add it to PERMISSION-DOCS" p))))

(define (permission-tier p)
  (cond [(instance-perm? p) "instance"] [(org-perm? p) "org"] [else "team"]))

(define (all-permissions) (sort (hash-keys PERMISSION-DOCS) string<?))

;; every permission a built-in role grants must be described — at load, not at doc time
(for* ([(role perms) (in-hash builtin-role-perms)] [p (in-list perms)])
  (permission-doc p))
