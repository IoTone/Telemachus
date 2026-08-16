#lang racket/base

;; domain/db/migrations.rkt — the app schema, as ordered db-kit migrations.
;; sqlite dialect today (booleans as INTEGER 0/1, timestamps as TEXT with a
;; CURRENT_TIMESTAMP default, JSON as TEXT). A Postgres backend would branch the
;; `up` steps by dialect; the runner is already dialect-agnostic.

(require db-kit/portable db-kit/migrate)

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

(define all-migrations (list m-0001-core m-0002-notes m-0003-quota m-0004-tools m-0005-translate m-0006-saas m-0007-features m-0008-documents m-0009-jobs m-0010-prospects m-0011-prospect-signals m-0012-prospect-company))
