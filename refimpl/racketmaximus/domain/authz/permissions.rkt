#lang racket/base

;; domain/authz/permissions.rkt — the permission catalog + built-in roles.
;;
;; Permissions are "resource:action" strings. Roles are named permission sets.
;; Wildcards: "documents:*", "*:read", "*:*". `instance:*` is the operator tier —
;; the authorization check grants it ONLY to is_operator principals, never via a
;; team role (decision RBAC-5), so owner's "*:*" does not reach it.

(require racket/string)

(provide perm-matches? instance-perm? split-perm
         builtin-role-keys builtin-role-names builtin-role-perms)

(define (split-perm p)
  (define parts (string-split p ":"))
  (values (if (pair? parts) (car parts) "")
          (if (and (pair? parts) (pair? (cdr parts))) (cadr parts) "")))

(define (instance-perm? p) (string-prefix? p "instance:"))

;; does a granted permission (possibly wildcarded) cover a required one?
(define (perm-matches? granted required)
  (or (string=? granted required)
      (string=? granted "*:*")
      (let-values ([(gr ga) (split-perm granted)]
                   [(rr ra) (split-perm required)])
        (and (or (string=? gr "*") (string=? gr rr))
             (or (string=? ga "*") (string=? ga ra))))))

(define builtin-role-keys '("owner" "admin" "member" "viewer"))

(define builtin-role-names
  (hash "owner" "Owner" "admin" "Admin" "member" "Member" "viewer" "Viewer"))

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
              "files:read" "files:write"
              "localization:read" "localization:translate" "localization:review"
              "localization:manage")
   ;; use AI + own resources
   "member" '("chat:use" "tools:invoke" "research:use"
              "documents:read" "documents:write"
              "notes:read" "notes:write"
              "tasks:read" "tasks:write"
              "memory:read" "memory:write"
              "files:read" "files:write"
              "localization:read" "localization:translate")
   ;; read team-visible resources; no AI spend, no mutation
   "viewer" '("*:read")))
