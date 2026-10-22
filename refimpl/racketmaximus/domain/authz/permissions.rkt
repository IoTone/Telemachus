#lang racket/base

;; domain/authz/permissions.rkt — the permission catalog + built-in roles.
;;
;; Permissions are "resource:action" strings. Roles are named permission sets.
;; Wildcards: "documents:*", "*:read", "*:*". `instance:*` is the operator tier —
;; the authorization check grants it ONLY to is_operator principals, never via a
;; team role (decision RBAC-5), so owner's "*:*" does not reach it.

(require racket/string)

(provide perm-matches? instance-perm? org-perm?
         builtin-role-keys builtin-role-names builtin-role-perms
         org-role-key?
         permission-doc permission-tier all-permissions
         DATA-READ-PERMS)

;; the team-tier reads `org:read-data` unlocks across a company's teams (TEN-2h)
(define DATA-READ-PERMS '("notes:read" "documents:read" "files:read"))

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
      ;; issue #124: `instance:manage` implies `instance:read`. Stated by name
      ;; because the wildcard rule cannot see it — `manage` and `read` are two
      ;; different actions — and WITHOUT it an operator whose token is scoped
      ;; `instance:manage` would be refused the very read routes this permission
      ;; was added to open up. The implication only goes this way: a monitoring
      ;; token scoped `instance:read` is refused `instance:manage`, which is the
      ;; whole point. TEN-2h had to special-case the OPPOSITE direction for
      ;; `org:read-data`, so getting this backwards is a silent privilege change
      ;; either way — there is a test for both.
      (and (string=? required "instance:read") (string=? granted "instance:manage"))
      ;; TEN-2h: `org:*` is the company-ADMINISTRATION wildcard; it does not
      ;; reach `org:read-data`, which is granted by name (the org_reader role)
      ;; so that reading a company's data is always a deliberate assignment
      (and (not (string=? required "org:read-data"))
           (let-values ([(gr ga) (split-perm granted)]
                        [(rr ra) (split-perm required)])
             (and (or (string=? gr "*") (string=? gr rr))
                  (or (string=? ga "*") (string=? ga ra)))))))

(define builtin-org-role-keys '("org_owner" "org_admin" "org_reader"))
(define (org-role-key? k) (and (member k builtin-org-role-keys) #t))

;; team roles + the two org roles. Org roles live in the same `roles` table with
;; team_id NULL, so a deployer can retune what a company admin may do without a
;; release — the tier is enforced in code, its contents are data.
(define builtin-role-keys
  (append '("owner" "admin" "member" "viewer") builtin-org-role-keys))

(define builtin-role-names
  (hash "owner" "Owner" "admin" "Admin" "member" "Member" "viewer" "Viewer"
        "org_owner" "Organization Owner" "org_admin" "Organization Admin"
        "org_reader" "Organization Reader"))

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
              "reviews:read" "reviews:decide"
              "jobs:cancel"
              ;; jobs:purge (issue #59): clear a SETTLED job's payload and result.
              ;; Separate from jobs:cancel because the authorities differ —
              ;; stopping a colleague's work is reversible in the sense that
              ;; nothing is lost, and destroying the input and output it recorded
              ;; is not. Owner-ok covers your own job, so a member needs neither.
              "jobs:purge"
              ;; jobs:schedule (#135): commit the team to RECURRING work. Not a
              ;; member's call — a schedule spends the team's budget on a timer
              ;; with nobody watching, which is a stewardship act in the way
              ;; enqueueing one job is not. Owner holds it through "*:*".
              "jobs:schedule"
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
              ;; Reviewing is the specialist's job, not a stewardship act — unlike
              ;; localization:review, where approving a colleague's translation is
              ;; an admin act. Integrity here comes from four_eyes, not the role.
              "reviews:read" "reviews:decide"
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
   ;; TEN-2h: the one org role that READS. `org:read-data` reaches every team's
   ;; team-visible notes, documents and search hits in the company — never a
   ;; private one, never AI spend, never management. Granted deliberately by
   ;; assigning THIS role; org_admin and org_owner do not carry it (TEN-2a stays
   ;; the default), so a team can still enumerate who sees its work.
   "org_reader" '("org:read" "org:read-data" "team:read")
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
   ;; SCHED-8. Cancelling a QUEUED job needs no permission — an owner may always
   ;; stop their own — but stopping work already RUNNING is a different act: it
   ;; discards a result somebody is waiting for, and may cut a tool call in half.
   "jobs:cancel"    "Cancel a job that is already RUNNING, not only a queued one. Cancellation is cooperative: the job stops at its next step boundary, and its result is discarded even if it finishes first."
   "jobs:schedule"  "Create, retune, pause and delete JOB SCHEDULES — recurring work. A schedule enqueues an ordinary job on an interval, running as whoever created it, so it commits the team's AI and storage budget to spending on a timer with nobody present to watch it. Reading one is held to the same permission as writing it, because a schedule's payload is the input of every job it fires."
   "jobs:purge"     "Clear the payload and result of SOMEBODY ELSE'S settled job, destroying the input it was given and the output it produced. You may always purge your own. The row, its status, its timings and the audit trail survive — the audit log is the record of what happened, so a purged job stays accountable while its content does not."
   "reviews:read"   "See the team's review queue and the decisions already recorded."
   "reviews:decide" "Approve, send back or reject an item waiting for review, with a rationale."
   "models:serve"   "Register a model executor for the team."
   "roles:read"     "See the team's roles and what they grant."
;; RBAC-5b (decided 12 Oct 2026): team-defined roles are NOT in v1. The
   ;; permission exists and is granted; nothing consumes it. Said plainly so it
   ;; reads as a deliberate omission rather than an unfinished feature.
   "roles:manage"   "Reserved for team-defined roles, which are not in v1 — the four built-in roles are the vocabulary. Granted, but nothing reads it yet."
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
   "jobs:execute"    "Claim, heartbeat, complete and fail jobs offered to a pull executor. Held only by a worker token, bound to one executor; reaches no team data and starts no run."
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
   "org:read-data" "Read team-visible notes, documents and search results across every team in the company (TEN-2h). Never private ones; never a write; never AI spend. Held by the org_reader role."
   "instance:*"      "Everything at the instance tier; the operator (superadmin)."
   "instance:manage" "Instance administration: branding, localization policy, quotas, orgs, metrics."
   ;; issue #124: the operational READS, so a monitoring credential need not be
   ;; able to reset a password. An operator issues a token scoped to this and
   ;; nothing else; `instance:manage` implies it, so an operator keeps every
   ;; route they had. It carries no tenant names and no document content.
   "instance:read"   "Read-only instance operations: status, metrics, the worker fleet, the queue, and verifying the audit chain. Not the audit EXPORT, which hands over the log itself."))

(define (permission-doc p)
  (hash-ref PERMISSION-DOCS p
            (lambda () (error 'permissions "permission ~s has no description — add it to PERMISSION-DOCS" p))))

(define (permission-tier p)
  (cond [(instance-perm? p) "instance"] [(org-perm? p) "org"] [else "team"]))

(define (all-permissions) (sort (hash-keys PERMISSION-DOCS) string<?))

;; every permission a built-in role grants must be described — at load, not at doc time
(for* ([(role perms) (in-hash builtin-role-perms)] [p (in-list perms)])
  (permission-doc p))
