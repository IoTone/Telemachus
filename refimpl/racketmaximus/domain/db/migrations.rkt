#lang racket/base

;; domain/db/migrations.rkt — the app schema, as ordered db-kit migrations.
;; sqlite dialect today (booleans as INTEGER 0/1, timestamps as TEXT with a
;; CURRENT_TIMESTAMP default, JSON as TEXT). A Postgres backend would branch the
;; `up` steps by dialect; the runner is already dialect-agnostic.

(require db-kit/portable db-kit/migrate racket/string
         "id.rkt"
         "../repo/blobs.rkt")   ; 0022 moves document bodies into the blob store

(provide all-migrations)

(define (exec* conn . stmts)
  (for ([s (in-list stmts)]) (query-exec conn s)))

;; 0001 — RBAC & core (slice 1): users, teams, memberships, roles,
;; role_permissions, api_tokens, resource_grants, audit_log.
(define m-0001-core
  (migration "0001-core"
    (lambda (conn)
      (exec* conn
       (string-append
        "CREATE TABLE users ("
        "  id TEXT PRIMARY KEY,"
        "  username TEXT NOT NULL UNIQUE,"
        "  display_name TEXT,"
        "  email TEXT,"
        "  password_hash TEXT,"
        "  totp_secret TEXT,"
        "  is_operator INTEGER NOT NULL DEFAULT 0,"
        "  status TEXT NOT NULL DEFAULT 'active',"
        "  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,"
        "  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP)")

       (string-append
        "CREATE TABLE teams ("
        "  id TEXT PRIMARY KEY,"
        "  slug TEXT NOT NULL UNIQUE,"
        "  name TEXT NOT NULL,"
        "  status TEXT NOT NULL DEFAULT 'active',"
        "  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,"
        "  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP)")

       (string-append
        "CREATE TABLE memberships ("
        "  id TEXT PRIMARY KEY,"
        "  user_id TEXT NOT NULL,"
        "  team_id TEXT NOT NULL,"
        "  role_key TEXT NOT NULL,"
        "  status TEXT NOT NULL DEFAULT 'active',"
        "  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,"
        "  UNIQUE(user_id, team_id))")
       "CREATE INDEX idx_memberships_user ON memberships(user_id)"
       "CREATE INDEX idx_memberships_team ON memberships(team_id)"

       (string-append
        "CREATE TABLE roles ("
        "  id TEXT PRIMARY KEY,"
        "  team_id TEXT,"                          ; NULL = built-in / global
        "  key TEXT NOT NULL,"
        "  name TEXT NOT NULL,"
        "  is_builtin INTEGER NOT NULL DEFAULT 0,"
        "  UNIQUE(team_id, key))")

       (string-append
        "CREATE TABLE role_permissions ("
        "  role_id TEXT NOT NULL,"
        "  permission TEXT NOT NULL,"
        "  UNIQUE(role_id, permission))")
       "CREATE INDEX idx_role_perms_role ON role_permissions(role_id)"

       (string-append
        "CREATE TABLE api_tokens ("
        "  id TEXT PRIMARY KEY,"
        "  user_id TEXT NOT NULL,"
        "  team_id TEXT NOT NULL,"
        "  name TEXT,"
        "  token_hash TEXT NOT NULL,"
        "  prefix TEXT NOT NULL,"
        "  scopes TEXT NOT NULL DEFAULT '[]',"     ; JSON array of permission strings
        "  status TEXT NOT NULL DEFAULT 'active',"
        "  expires_at TEXT,"
        "  last_used_at TEXT,"
        "  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP)")
       "CREATE INDEX idx_tokens_hash ON api_tokens(token_hash)"

       (string-append
        "CREATE TABLE resource_grants ("
        "  id TEXT PRIMARY KEY,"
        "  resource_type TEXT NOT NULL,"
        "  resource_id TEXT NOT NULL,"
        "  principal_type TEXT NOT NULL,"          ; user | team
        "  principal_id TEXT NOT NULL,"
        "  permission TEXT NOT NULL,"
        "  granted_by TEXT,"
        "  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,"
        "  UNIQUE(resource_type, resource_id, principal_type, principal_id, permission))")
       "CREATE INDEX idx_grants_res ON resource_grants(resource_type, resource_id)"

       (string-append
        "CREATE TABLE audit_log ("
        "  id TEXT PRIMARY KEY,"
        "  actor_type TEXT,"
        "  actor_id TEXT,"
        "  team_id TEXT,"
        "  action TEXT NOT NULL,"
        "  resource_type TEXT,"
        "  resource_id TEXT,"
        "  result TEXT,"
        "  at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,"
        "  meta TEXT)")
       "CREATE INDEX idx_audit_team ON audit_log(team_id)"))))

;; 0002 — notes: a first ownable/shareable resource (slice 5). Carries the
;; through-line every app resource has: team_id + owner_user_id + visibility.
(define m-0002-notes
  (migration "0002-notes"
    (lambda (conn)
      (exec* conn
       (string-append
        "CREATE TABLE notes ("
        "  id TEXT PRIMARY KEY,"
        "  team_id TEXT NOT NULL,"
        "  owner_user_id TEXT NOT NULL,"
        "  visibility TEXT NOT NULL DEFAULT 'team',"   ; team | private | shared
        "  title TEXT NOT NULL DEFAULT '',"
        "  body TEXT NOT NULL DEFAULT '',"
        "  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,"
        "  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP)")
       "CREATE INDEX idx_notes_team ON notes(team_id)"
       "CREATE INDEX idx_notes_owner ON notes(owner_user_id)"))))

;; 0003 — quotas & usage metering (slice 6). Per-subject limits + an append-only
;; usage ledger; concurrency limits are read by the governor.
(define m-0003-quota
  (migration "0003-quota"
    (lambda (conn)
      (exec* conn
       (string-append
        "CREATE TABLE quota_limits ("
        "  id TEXT PRIMARY KEY,"
        "  subject_type TEXT NOT NULL,"                ; team | user
        "  subject_id TEXT NOT NULL,"
        "  dimension TEXT NOT NULL,"                   ; ai.tokens.total | ai.requests | ai.concurrency
        "  limit_value INTEGER NOT NULL,"
        "  \"window\" TEXT NOT NULL DEFAULT 'day',"     ; day | minute | instant ("window" is reserved in PG)
        "  UNIQUE(subject_type, subject_id, dimension))")
       (string-append
        "CREATE TABLE usage_ledger ("
        "  id TEXT PRIMARY KEY,"
        "  subject_type TEXT NOT NULL,"
        "  subject_id TEXT NOT NULL,"
        "  dimension TEXT NOT NULL,"
        "  amount INTEGER NOT NULL,"
        "  at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP)")
       "CREATE INDEX idx_usage_subj ON usage_ledger(subject_type, subject_id, dimension)"))))

;; 0004 — per-team tool activation (plugin SDK: every tool can be turned off).
;; Absence of a row = enabled (default on).
(define m-0004-tools
  (migration "0004-tools"
    (lambda (conn)
      (exec* conn
       (string-append
        "CREATE TABLE tool_settings ("
        "  id TEXT PRIMARY KEY,"
        "  team_id TEXT NOT NULL,"
        "  tool_name TEXT NOT NULL,"
        "  enabled INTEGER NOT NULL DEFAULT 1,"
        "  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,"
        "  UNIQUE(team_id, tool_name))")))))

;; 0005 — translation app (slice 17): a team-scoped translation history and a
;; team glossary (consistent terminology per target language). Same through-line:
;; team_id + owner_user_id. The app meters AI spend through the usual quotas.
(define m-0005-translate
  (migration "0005-translate"
    (lambda (conn)
      (exec* conn
       (string-append
        "CREATE TABLE translations ("
        "  id TEXT PRIMARY KEY,"
        "  team_id TEXT NOT NULL,"
        "  owner_user_id TEXT NOT NULL,"
        "  source_lang TEXT NOT NULL DEFAULT 'auto',"
        "  target_lang TEXT NOT NULL,"
        "  source_text TEXT NOT NULL,"
        "  result_text TEXT NOT NULL DEFAULT '',"
        "  model TEXT,"
        "  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP)")
       "CREATE INDEX idx_translations_team ON translations(team_id)"
       (string-append
        "CREATE TABLE glossary ("
        "  id TEXT PRIMARY KEY,"
        "  team_id TEXT NOT NULL,"
        "  target_lang TEXT NOT NULL,"
        "  term TEXT NOT NULL,"
        "  translation TEXT NOT NULL,"
        "  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,"
        "  UNIQUE(team_id, target_lang, term))")
       "CREATE INDEX idx_glossary_team ON glossary(team_id, target_lang)"))))

;; 0006 — hosted onboarding (slice 19): idempotent tenant provisioning + one-time
;; activation tokens. users.status ('invited' | 'active' | 'suspended') already
;; exists as TEXT; no column change needed. See docs/design/saas-onboarding.md.
(define m-0006-saas
  (migration "0006-saas"
    (lambda (conn)
      (exec* conn
       (string-append
        "CREATE TABLE provisioning ("
        "  id TEXT PRIMARY KEY,"
        "  provision_id TEXT NOT NULL UNIQUE,"          ; external id (subscription/vm/signup)
        "  source TEXT NOT NULL,"                       ; signup | subscription | vm
        "  plan TEXT NOT NULL DEFAULT 'trial',"
        "  status TEXT NOT NULL DEFAULT 'seeded',"      ; seeded | activated | suspended | deprovisioned
        "  owner_user_id TEXT,"
        "  team_id TEXT,"
        "  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,"
        "  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP)")
       (string-append
        "CREATE TABLE activation_tokens ("
        "  id TEXT PRIMARY KEY,"
        "  user_id TEXT NOT NULL,"
        "  token_hash TEXT NOT NULL,"
        "  prefix TEXT NOT NULL,"
        "  expires_at TEXT,"
        "  used_at TEXT,"
        "  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP)")
       "CREATE INDEX idx_activation_hash ON activation_tokens(token_hash)"))))

;; 0007 — per-team feature activation (slice 24). Absence of a row = enabled
;; (default on), mirroring tool_settings. Lets a team turn whole features off.
(define m-0007-features
  (migration "0007-features"
    (lambda (conn)
      (exec* conn
       (string-append
        "CREATE TABLE feature_settings ("
        "  id TEXT PRIMARY KEY,"
        "  team_id TEXT NOT NULL,"
        "  feature TEXT NOT NULL,"
        "  enabled INTEGER NOT NULL DEFAULT 1,"
        "  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,"
        "  UNIQUE(team_id, feature))")))))

;; 0008 — documents (slice 26): the ownable resource behind the research /
;; document-translation apps. Same through-line as notes (team_id + owner_user_id
;; + visibility), with a larger `content` body; listing is offset-paginated.
(define m-0008-documents
  (migration "0008-documents"
    (lambda (conn)
      (exec* conn
       (string-append
        "CREATE TABLE documents ("
        "  id TEXT PRIMARY KEY,"
        "  team_id TEXT NOT NULL,"
        "  owner_user_id TEXT NOT NULL,"
        "  visibility TEXT NOT NULL DEFAULT 'team',"
        "  title TEXT NOT NULL DEFAULT '',"
        "  content TEXT NOT NULL DEFAULT '',"
        "  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,"
        "  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP)")
       "CREATE INDEX idx_documents_team ON documents(team_id)"))))

;; 0009 — AI workload jobs (slice 27): the async scheduler's queue. Work is
;; claimed atomically and run by a bounded worker pool. See
;; docs/design/ai-queue-and-concurrency.md.
(define m-0009-jobs
  (migration "0009-jobs"
    (lambda (conn)
      (exec* conn
       (string-append
        "CREATE TABLE jobs ("
        "  id TEXT PRIMARY KEY,"
        "  team_id TEXT NOT NULL,"
        "  user_id TEXT NOT NULL,"
        "  kind TEXT NOT NULL,"
        "  status TEXT NOT NULL DEFAULT 'queued',"     ; queued|running|done|error|canceled
        "  priority INTEGER NOT NULL DEFAULT 0,"
        "  payload TEXT NOT NULL DEFAULT '{}',"
        "  result TEXT,"
        "  error TEXT,"
        "  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,"
        "  started_at TEXT,"
        "  finished_at TEXT)")
       "CREATE INDEX idx_jobs_team ON jobs(team_id)"
       "CREATE INDEX idx_jobs_status ON jobs(status)"))))

;; 0010 — beta onboarding (slice 33): pre-sales prospect capture for qualifying beta
;; customers. NOT users/accounts — just leads an internal team reviews, each vetted
;; by an LLM judge. Public signup writes here; owners review. See docs/design.
(define m-0010-prospects
  (migration "0010-prospects"
    (lambda (conn)
      (exec* conn
       (string-append
        "CREATE TABLE prospects ("
        "  id TEXT PRIMARY KEY,"
        "  team_id TEXT NOT NULL,"                       ; the internal team that owns the pipeline
        "  name TEXT NOT NULL DEFAULT '',"
        "  email TEXT NOT NULL DEFAULT '',"
        "  company TEXT NOT NULL DEFAULT '',"
        "  job_title TEXT NOT NULL DEFAULT '',"
        "  revenue TEXT NOT NULL DEFAULT '',"            ; self-reported range
        "  use_case TEXT NOT NULL DEFAULT '',"
        "  source TEXT NOT NULL DEFAULT 'beta',"
        "  status TEXT NOT NULL DEFAULT 'new',"          ; new|verifying|reviewed|qualified|rejected
        "  judge TEXT,"                                  ; JSON verdict from the LLM judge
        "  decided_by TEXT,"
        "  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,"
        "  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP)")
       "CREATE INDEX idx_prospects_team ON prospects(team_id)"))))

;; 0011 — anti-abuse hardening (slice 36): a portable epoch column for velocity
;; windows (dialect-neutral, numeric) + a signals blob the LLM judge weighs.
(define m-0011-prospect-signals
  (migration "0011-prospect-signals"
    (lambda (conn)
      (exec* conn
       "ALTER TABLE prospects ADD COLUMN created_epoch INTEGER NOT NULL DEFAULT 0"
       "ALTER TABLE prospects ADD COLUMN signals TEXT"))))

;; 0012 — company qualifying details (slice 38): more B2B signal for the LLM judge
;; to weigh — a company address and phone (both optional). company is now optional
;; too (individuals can still apply); the fields' required flags live in the
;; onboarding provider, not the schema.
(define m-0012-prospect-company
  (migration "0012-prospect-company"
    (lambda (conn)
      (exec* conn
       "ALTER TABLE prospects ADD COLUMN company_address TEXT NOT NULL DEFAULT ''"
       "ALTER TABLE prospects ADD COLUMN phone TEXT NOT NULL DEFAULT ''"))))

;; 0013 — extensible prospect model (slice 39): custom, program-specific fields land
;; in a generic JSON blob keyed by field key, so new fields need no per-deployment
;; migration. Typed columns remain only for what core logic queries (email/velocity,
;; name, status, judge, signals). See docs/design/beta-onboarding-experience.md §1.
(define m-0013-prospect-attributes
  (migration "0013-prospect-attributes"
    (lambda (conn)
      (exec* conn
       "ALTER TABLE prospects ADD COLUMN attributes TEXT"))))

;; 0014 — onboarding experiences (slice 40): the beta landing experience becomes
;; admin-editable data with a draft/publish workflow, per (team, key). Source of
;; truth moves from code/env to storage; ENV still seeds first-boot defaults via a
;; base experience when nothing is published. See docs/design/beta-onboarding-experience.md §2.
(define m-0014-onboarding-experiences
  (migration "0014-onboarding-experiences"
    (lambda (conn)
      (exec* conn
       (string-append
        "CREATE TABLE onboarding_experiences ("
        "  id TEXT PRIMARY KEY,"
        "  team_id TEXT NOT NULL,"
        "  key TEXT NOT NULL DEFAULT 'beta',"
        "  status TEXT NOT NULL DEFAULT 'draft',"     ; draft | published
        "  config TEXT NOT NULL,"                     ; full experience JSON (judge_system included)
        "  updated_by TEXT,"
        "  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP)")
       "CREATE INDEX idx_onboarding_exp ON onboarding_experiences(team_id, key, status)"))))

;; 0015 — onboarding assets (slice 42): locally-hosted brand assets (logo, hero
;; image, custom font) for the skinnable landing. Stored base64 in a dialect-neutral
;; TEXT column and served from our own origin — no external URLs (privacy: a public
;; beta page must not leak a prospect's IP to a CDN). See docs/design/beta-onboarding-experience.md §4.
(define m-0015-onboarding-assets
  (migration "0015-onboarding-assets"
    (lambda (conn)
      (exec* conn
       (string-append
        "CREATE TABLE onboarding_assets ("
        "  id TEXT PRIMARY KEY,"
        "  team_id TEXT NOT NULL,"
        "  kind TEXT NOT NULL DEFAULT 'image',"      ; image | font
        "  mime TEXT NOT NULL,"
        "  filename TEXT NOT NULL DEFAULT '',"
        "  size INTEGER NOT NULL DEFAULT 0,"          ; decoded byte length
        "  data TEXT NOT NULL,"                       ; base64-encoded bytes
        "  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP)")
       "CREATE INDEX idx_onboarding_assets_team ON onboarding_assets(team_id)"))))

;; 0016 — organizations (slice 45): the tenancy layer ABOVE teams, so one instance
;; can serve several companies. Supersedes decision TEN (single implicit org).
;; See docs/design/multi-tenancy.md.
;;
;; The org row always exists — even single-tenant, where it is the one implicit
;; org. Same schema, same authorization path in both modes; the feature flag
;; switches surface area, not semantics.
;;
;; `teams.slug` must become per-org unique (two companies may both want an
;; "engineering" team). SQLite cannot drop an inline UNIQUE, so this branches on
;; dialect: rebuild-and-copy on SQLite, DROP/ADD CONSTRAINT on PostgreSQL.
(define m-0016-orgs
  (migration "0016-orgs"
    (lambda (conn)
      (exec* conn
       (string-append
        "CREATE TABLE orgs ("
        "  id TEXT PRIMARY KEY,"
        "  slug TEXT NOT NULL UNIQUE,"
        "  name TEXT NOT NULL,"
        "  status TEXT NOT NULL DEFAULT 'active',"    ; active | suspended
        "  plan TEXT NOT NULL DEFAULT 'trial',"
        "  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,"
        "  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP)")
       ;; users: home org (NULL = instance-level, i.e. the superadmin belongs to no
       ;; company) + the org-level role key (NULL = ordinary user, no org rights)
       "ALTER TABLE users ADD COLUMN org_id TEXT"
       "ALTER TABLE users ADD COLUMN org_role_key TEXT"
       "CREATE INDEX idx_users_org ON users(org_id)")

      ;; ---- teams.org_id + UNIQUE(org_id, slug) --------------------------------
      (case (db-dialect conn)
        [(postgresql)
         (exec* conn
          "ALTER TABLE teams ADD COLUMN org_id TEXT"
          "ALTER TABLE teams DROP CONSTRAINT IF EXISTS teams_slug_key"
          "ALTER TABLE teams ADD CONSTRAINT teams_org_slug_key UNIQUE (org_id, slug)")]
        [else
         ;; SQLite: rebuild. `teams` is small (one row per team) and this runs
         ;; inside the migration runner's transaction.
         (exec* conn
          (string-append
           "CREATE TABLE teams_new ("
           "  id TEXT PRIMARY KEY,"
           "  org_id TEXT,"
           "  slug TEXT NOT NULL,"
           "  name TEXT NOT NULL,"
           "  status TEXT NOT NULL DEFAULT 'active',"
           "  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,"
           "  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,"
           "  UNIQUE(org_id, slug))")
          (string-append
           "INSERT INTO teams_new (id, org_id, slug, name, status, created_at, updated_at) "
           "SELECT id, NULL, slug, name, status, created_at, updated_at FROM teams")
          "DROP TABLE teams"
          "ALTER TABLE teams_new RENAME TO teams")])
      (query-exec conn "CREATE INDEX idx_teams_org ON teams(org_id)")

      ;; ---- backfill: every pre-existing team/user joins the implicit org ------
      ;; An upgraded single-tenant deployment keeps working unchanged: one org,
      ;; everyone in it.
      (when (query-maybe-value conn "SELECT id FROM teams LIMIT 1")
        (define oid "org-default-0000000000000000000")
        (query-exec conn
          "INSERT INTO orgs (id, slug, name, plan) VALUES (?, 'default', 'Default Organization', 'self-hosted')"
          oid)
        (query-exec conn "UPDATE teams SET org_id = ? WHERE org_id IS NULL" oid)
        (query-exec conn "UPDATE users SET org_id = ? WHERE org_id IS NULL AND is_operator = 0" oid)))))

;; 0017 — workflow engine (slice 46): plugins that process in steps. Three tables:
;; the published DEFINITION (a validated spec document — the public contract, see
;; docs/design/workflow-engine.md), a RUN of one, and that run's STEPS. Each step
;; is executed as a scheduler job, so `jobs` carries the durability and `job_id`
;; is the join back to it. No org_id: a team belongs to exactly one org (TEN-2),
;; so the org is derivable and a second source of truth would only drift.
(define m-0017-workflows
  (migration "0017-workflows"
    (lambda (conn)
      (exec* conn
       (string-append
        "CREATE TABLE workflow_defs ("
        "  id TEXT PRIMARY KEY,"
        "  team_id TEXT NOT NULL,"
        "  slug TEXT NOT NULL,"
        "  version INTEGER NOT NULL DEFAULT 1,"
        "  source TEXT NOT NULL DEFAULT 'db',"          ; db | plugin:<id> | builtin
        "  spec TEXT NOT NULL,"                          ; the validated spec document
        "  status TEXT NOT NULL DEFAULT 'active',"       ; active | archived
        "  created_by TEXT,"
        "  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,"
        "  UNIQUE(team_id, slug, version))")
       "CREATE INDEX idx_wf_defs_team ON workflow_defs(team_id)"

       (string-append
        "CREATE TABLE workflow_runs ("
        "  id TEXT PRIMARY KEY,"
        "  def_id TEXT NOT NULL,"
        "  team_id TEXT NOT NULL,"
        "  user_id TEXT NOT NULL,"                       ; the pinned principal
        "  status TEXT NOT NULL DEFAULT 'running',"      ; running|waiting|done|error|canceled
        "  input TEXT NOT NULL DEFAULT '{}',"
        "  output TEXT,"
        "  error TEXT,"
        "  cursor_json TEXT NOT NULL DEFAULT '{}',"      ; not `cursor` — reserved-word-adjacent
        "  steps_used INTEGER NOT NULL DEFAULT 0,"
        "  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,"
        "  started_at TEXT,"
        "  finished_at TEXT)")
       "CREATE INDEX idx_wf_runs_team ON workflow_runs(team_id)"
       "CREATE INDEX idx_wf_runs_def ON workflow_runs(def_id)"

       (string-append
        "CREATE TABLE workflow_steps ("
        "  id TEXT PRIMARY KEY,"
        "  run_id TEXT NOT NULL,"
        "  parent_id TEXT,"                              ; set on a `map` child: its fan-out step row
        "  step_id TEXT NOT NULL,"                       ; the id inside the spec ("<map>#<i>" for a child)
        "  seq INTEGER NOT NULL DEFAULT 0,"
        "  status TEXT NOT NULL DEFAULT 'queued',"       ; queued|running|done|error
        "  attempt INTEGER NOT NULL DEFAULT 1,"
        "  job_id TEXT,"
        "  input TEXT,"
        "  output TEXT,"
        "  error TEXT,"
        "  started_at TEXT,"
        "  finished_at TEXT)")
       "CREATE INDEX idx_wf_steps_run ON workflow_steps(run_id)"
       "CREATE INDEX idx_wf_steps_parent ON workflow_steps(parent_id)"))))

;; 0018 — the user's own language (slice 47). i18n has always been request-scoped
;; (Accept-Language); this is the durable preference a workflow can bind to as
;; ${principal.locale}, so "translate back into the user's language" is a property
;; of the profile rather than of whichever browser started the run.
(define m-0018-user-locale
  (migration "0018-user-locale"
    (lambda (conn)
      (exec* conn "ALTER TABLE users ADD COLUMN locale TEXT NOT NULL DEFAULT 'en'"))))

;; 0019 — the document repository (slice 49). Binary documents of any format, with
;; the same ownable-resource shape as notes and documents (team_id + owner_user_id +
;; visibility) so `can?` governs them with no new authorization code.
;;
;; Two tables, because an overwrite must not destroy what it replaces: the object is
;; the stable identity a grant and a URL point at, and each write appends a version.
;; `current_version_id` is what a plain read resolves to.
;;
;; The bytes are NOT here. A version stores the sha-256 of its content and the blob
;; store holds it under that digest (DOC-5) — which is why two identical uploads cost
;; one copy, and why the database stays small enough to back up.
;;
;; `key` is the path within the team, unique per team among live objects. SQLite and
;; PostgreSQL both honour a partial unique index, which is what lets a deleted key be
;; reused without a tombstone dance.
(define m-0019-repo
  (migration "0019-repo"
    (lambda (conn)
      (exec* conn
       (string-append
        "CREATE TABLE repo_objects ("
        "  id TEXT PRIMARY KEY,"
        "  org_id TEXT NOT NULL,"                      ; the dedup + isolation namespace (DOC-6)
        "  team_id TEXT NOT NULL,"
        "  owner_user_id TEXT NOT NULL,"
        "  visibility TEXT NOT NULL DEFAULT 'team',"   ; private | team | shared
        "  key TEXT NOT NULL,"
        "  current_version_id TEXT,"
        "  deleted_at TEXT,"
        "  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,"
        "  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP)")
       "CREATE INDEX idx_repo_objects_team ON repo_objects(team_id)"
       "CREATE UNIQUE INDEX idx_repo_objects_key ON repo_objects(team_id, key) WHERE deleted_at IS NULL"

       (string-append
        "CREATE TABLE repo_versions ("
        "  id TEXT PRIMARY KEY,"
        "  object_id TEXT NOT NULL,"
        "  seq INTEGER NOT NULL DEFAULT 1,"
        "  digest TEXT NOT NULL,"                      ; sha-256, lowercase hex — the blob's address
        "  size INTEGER NOT NULL DEFAULT 0,"
        "  content_type TEXT NOT NULL DEFAULT 'application/octet-stream',"
        "  filename TEXT NOT NULL DEFAULT '',"
        "  created_by TEXT NOT NULL,"
        "  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP)")
       "CREATE INDEX idx_repo_versions_object ON repo_versions(object_id)"
       ;; the refcount query behind "is this blob still referenced by anyone?"
       "CREATE INDEX idx_repo_versions_digest ON repo_versions(digest)"))))

;; 0020 — S3 credentials and multipart uploads (slice 52).
;;
;; SigV4 is an HMAC keyed by the secret, so VERIFYING a signature requires holding
;; the secret. The api_tokens scheme — SHA-1 of the token, prefix kept for display —
;; cannot be reused: there is no way to check an HMAC against a hash. So this is a
;; separate credential kind with a recoverable secret, and that is a real and stated
;; downgrade. Precedent and trust boundary are the same as users.totp_secret, which
;; is recoverable for exactly the same reason (TOTP also needs the raw value).
;; Scopes work as they do for api_tokens (RBAC-4): issuer permissions ∩ scopes.
;;
;; Multipart is not optional — aws-cli switches to it above 8 MiB, so `aws s3 cp` of
;; any real document uses it. Parts arrive concurrently and OUT OF ORDER, so each is
;; its own row and the object is assembled at Complete; nothing is ever appended to a
;; growing blob.
(define m-0020-s3
  (migration "0020-s3"
    (lambda (conn)
      (exec* conn
       (string-append
        "CREATE TABLE repo_credentials ("
        "  id TEXT PRIMARY KEY,"
        "  user_id TEXT NOT NULL,"
        "  team_id TEXT NOT NULL,"
        "  name TEXT,"
        "  access_key_id TEXT NOT NULL UNIQUE,"
        "  secret_key TEXT NOT NULL,"
        "  scopes TEXT NOT NULL DEFAULT '[]',"
        "  status TEXT NOT NULL DEFAULT 'active',"
        "  last_used_at TEXT,"
        "  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP)")
       "CREATE INDEX idx_repo_creds_team ON repo_credentials(team_id)"

       (string-append
        "CREATE TABLE repo_uploads ("
        "  id TEXT PRIMARY KEY,"                     ; the S3 UploadId
        "  org_id TEXT NOT NULL,"
        "  team_id TEXT NOT NULL,"
        "  user_id TEXT NOT NULL,"
        "  key TEXT NOT NULL,"
        "  content_type TEXT NOT NULL DEFAULT 'application/octet-stream',"
        "  visibility TEXT,"                         ; NULL = leave an existing object alone
        "  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP)")
       "CREATE INDEX idx_repo_uploads_team ON repo_uploads(team_id)"

       (string-append
        "CREATE TABLE repo_upload_parts ("
        "  id TEXT PRIMARY KEY,"
        "  upload_id TEXT NOT NULL,"
        "  part_number INTEGER NOT NULL,"
        "  digest TEXT NOT NULL,"                    ; each part is a blob in its own right
        "  size INTEGER NOT NULL DEFAULT 0,"
        "  created_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP,"
        "  UNIQUE(upload_id, part_number))")         ; a retried part replaces, never duplicates
       "CREATE INDEX idx_repo_parts_upload ON repo_upload_parts(upload_id)"))))

;; 0021 — extracted document text (slice 54). One row per repository object,
;; holding the text pulled out of its CURRENT version so search can match a PDF by
;; what it says, not just what it is called. Re-extraction replaces the row when the
;; version changes; deleting the object deletes the row (repo-delete! does it — no
;; FK cascade, SQLite portability).
;;
;; The text lives HERE and not in a blob because it is a search index, not a
;; document: it is derived, capped, and disposable — dropping the table loses
;; nothing that a re-run of the indexing workflow cannot rebuild.
(define m-0021-repo-text
  (migration "0021-repo-text"
    (lambda (conn)
      (exec* conn
       (string-append
        "CREATE TABLE repo_text ("
        "  object_id TEXT PRIMARY KEY,"
        "  version_id TEXT NOT NULL,"       ; which version this text came from
        "  content TEXT NOT NULL DEFAULT '',"
        "  extracted_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP)")))))

;; 0022 — the DOC-14 fold (slice 55): `documents` rows become repository objects.
;;
;; A text document IS a document — an object whose content type is text/markdown.
;; Keeping two tables meant two permission families, two tabs, and a search that had
;; to know both. This migration ends that: each live row becomes a repo_object (SAME
;; id, so resource grants and every client-held reference survive), its body becomes
;; a content-addressed blob, its title rides in the version's `filename`, and its
;; text lands in repo_text so search never skips a beat. Then the table is dropped —
;; /api/documents lives on as a shim over the repository.
;;
;; This is the one migration that touches the FILESYSTEM, and deliberately so: the
;; body has to become a blob, and pretending otherwise would leave megabytes of
;; markdown in a TEXT column forever. On a fresh database the loop body never runs
;; and no file is written. The blob store in effect at migration time is the
;; built-in one — plugins (rs3) load later — and both write the identical layout.
(define m-0022-fold-documents
  (migration "0022-fold-documents"
    (lambda (conn)
      ;; probe before joining: on an EMPTY table there is nothing to fold, and the
      ;; org join must not even be prepared — a test that replays migrations out of
      ;; order can reach this with a pre-0016 teams table, and an empty fold should
      ;; be a no-op there, not a missing-column error
      (define n (query-value conn "SELECT COUNT(*) FROM documents"))
      (define rows
        (if (zero? n) '()
            (query-rows conn
              (string-append "SELECT d.id, d.team_id, d.owner_user_id, d.visibility, d.title, "
                             "d.content, d.created_at, d.updated_at, t.org_id "
                             "FROM documents d JOIN teams t ON t.id = d.team_id"))))
      (for ([r (in-list rows)])
        (define id    (vector-ref r 0))
        (define team  (vector-ref r 1))
        (define owner (vector-ref r 2))
        (define vis   (vector-ref r 3))
        (define title (let ([v (vector-ref r 4)]) (if (sql-null? v) "" v)))
        (define body  (let ([v (vector-ref r 5)]) (if (sql-null? v) "" v)))
        (define created (vector-ref r 6))
        (define updated (vector-ref r 7))
        (define org   (vector-ref r 8))
        ;; documents/<slug>-<id8>.md — the slug is for humans, the id suffix is what
        ;; makes it unique (titles never were)
        (define slug
          (let* ([lo (string-downcase title)]
                 [cleaned (regexp-replace* #px"[^a-z0-9]+" lo "-")]
                 [trimmed (string-trim cleaned "-")])
            (if (string=? trimmed "")
                "untitled"
                (substring trimmed 0 (min 60 (string-length trimmed))))))
        (define key (format "documents/~a-~a.md" slug (substring id 0 8)))
        (define bytes (string->bytes/utf-8 body))
        (define digest (digest-of-bytes bytes))
        (blob-put! org digest (open-input-bytes bytes) (bytes-length bytes))
        (define vid (new-id))
        (query-exec conn
          (string-append "INSERT INTO repo_objects "
                         "(id, org_id, team_id, owner_user_id, visibility, key, "
                         " current_version_id, created_at, updated_at) "
                         "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)")
          id org team owner vis key vid created updated)
        (query-exec conn
          (string-append "INSERT INTO repo_versions "
                         "(id, object_id, seq, digest, size, content_type, filename, created_by, created_at) "
                         "VALUES (?, ?, 1, ?, ?, 'text/markdown', ?, ?, ?)")
          vid id digest (bytes-length bytes) title owner created)
        ;; markdown extracts to itself: the content stays searchable across the fold
        (query-exec conn
          "INSERT INTO repo_text (object_id, version_id, content) VALUES (?, ?, ?)"
          id vid body))
      ;; grants follow the resource — the object kept its id, so only the type moves
      (query-exec conn
        "UPDATE resource_grants SET resource_type = 'repo' WHERE resource_type = 'documents'")
      (exec* conn "DROP TABLE documents"))))

;; 0023 — instance settings (branding). A generic key/value document store for
;; instance-wide configuration, so the NEXT such setting needs code, not a
;; migration. `key` is the primary key; `value` is a JSON document.
(define m-0023-instance-settings
  (migration "0023-instance-settings"
    (lambda (conn)
      (exec* conn
       (string-append
        "CREATE TABLE instance_settings ("
        "  key TEXT PRIMARY KEY,"
        "  value TEXT NOT NULL,"
        "  updated_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP)")))))

(define all-migrations (list m-0001-core m-0002-notes m-0003-quota m-0004-tools m-0005-translate m-0006-saas m-0007-features m-0008-documents m-0009-jobs m-0010-prospects m-0011-prospect-signals m-0012-prospect-company m-0013-prospect-attributes m-0014-onboarding-experiences m-0015-onboarding-assets m-0016-orgs
                             m-0017-workflows m-0018-user-locale m-0019-repo m-0020-s3 m-0021-repo-text m-0022-fold-documents
                             m-0023-instance-settings))
