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
         builtin-org-role-keys org-role-key?)

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
              "files:read" "files:write" "files:delete"
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
