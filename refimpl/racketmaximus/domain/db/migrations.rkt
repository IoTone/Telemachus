#lang racket/base

;; domain/db/migrations.rkt — the app schema, as ordered db-kit migrations.
;; sqlite dialect today (booleans as INTEGER 0/1, timestamps as TEXT with a
;; CURRENT_TIMESTAMP default, JSON as TEXT). A Postgres backend would branch the
;; `up` steps by dialect; the runner is already dialect-agnostic.

(require db db-kit/migrate)

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

(define all-migrations (list m-0001-core m-0002-notes))
