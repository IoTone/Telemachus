#lang racket/base

;; domain/authz/authz.rkt — the AuthzService over db-kit.
;;
;; Implements the RBAC contract from docs/design/rbac-and-teams.md:
;;   can? / require-perm, effective permissions, bootstrap, built-in-role seeding,
;;   API-token issue/resolve (issuer-perms ∩ scopes), resource grants, audit.
;;
;; Functions take a live `db` connection as their first argument. Principals are
;; plain structs; a user acting directly has token-scopes = #f, a token-backed
;; actor carries its scope list (which CAPS the issuer's live permissions).
;;
;; NOTE (prototype): token hashing uses salted SHA-1 (built-in) — adequate for a
;; high-entropy random token lookup, but the hashing seam (`hash-token`) is where
;; a production KDF drops in. Password auth (login/2FA) is a later slice.

(require db-kit/portable
         json
         file/sha1
         "../db/id.rkt"
         "permissions.rkt"
         "passwords.rkt")

(provide (struct-out principal)
         (struct-out exn:fail:forbidden)
         user-principal principal-for
         create-user! create-team! add-member!
         seed-builtin-roles! bootstrap!
         user-role-key user-permissions
         can? require-perm
         issue-token! resolve-token list-tokens revoke-token!
         grant! revoke!
         audit! audit-list
         set-password! change-password! authenticate enable-2fa! first-team-for)

;; ---- principal --------------------------------------------------------------
;; token-scopes: #f = direct user (uncapped by scopes); (listof string) = token.
(struct principal (user-id is-operator team-id token-scopes) #:transparent)

(struct exn:fail:forbidden exn:fail (permission) #:transparent)

(define (user-principal conn user-id team-id)
  (define op (query-maybe-value conn "SELECT is_operator FROM users WHERE id = ?" user-id))
  (principal user-id (and (number? op) (not (zero? op))) team-id #f))

;; resolve a trusted (username, team-slug) pair to a direct-user principal
(define (principal-for conn username team-slug)
  (define uid (query-maybe-value conn "SELECT id FROM users WHERE username = ?" username))
  (define tid (query-maybe-value conn "SELECT id FROM teams WHERE slug = ?" team-slug))
  (and uid tid (user-principal conn uid tid)))

;; ---- creation ---------------------------------------------------------------
(define (create-user! conn #:username username #:operator? [operator? #f]
                      #:display-name [display-name sql-null] #:password [pw #f])
  (define uid (new-id))
  (query-exec conn
    "INSERT INTO users (id, username, display_name, is_operator, password_hash) VALUES (?, ?, ?, ?, ?)"
    uid username display-name (if operator? 1 0) (if pw (hash-password pw) sql-null))
  uid)

(define (create-team! conn #:name name #:slug slug)
  (define tid (new-id))
  (query-exec conn "INSERT INTO teams (id, slug, name) VALUES (?, ?, ?)" tid slug name)
  tid)

(define (add-member! conn #:user user-id #:team team-id #:role role-key)
  (define mid (new-id))
  (query-exec conn
    "INSERT INTO memberships (id, user_id, team_id, role_key) VALUES (?, ?, ?, ?)"
    mid user-id team-id role-key)
  mid)

;; ---- built-in roles + bootstrap --------------------------------------------
(define (seed-builtin-roles! conn)
  (for ([key (in-list builtin-role-keys)])
    (unless (query-maybe-value conn "SELECT id FROM roles WHERE team_id IS NULL AND key = ?" key)
      (define rid (new-id))
      (query-exec conn
        "INSERT INTO roles (id, team_id, key, name, is_builtin) VALUES (?, NULL, ?, ?, 1)"
        rid key (hash-ref builtin-role-names key key))
      (for ([perm (in-list (hash-ref builtin-role-perms key))])
        (query-exec conn "INSERT INTO role_permissions (role_id, permission) VALUES (?, ?)" rid perm)))))

;; First-run: create the first user as operator, its team, and an owner
;; membership. Refuses if any user already exists. Returns (values user-id team-id).
(define (bootstrap! conn #:username username #:password [pw #f]
                    #:team-name [team-name "Default"] #:team-slug [team-slug "default"])
  (when (query-maybe-value conn "SELECT id FROM users LIMIT 1")
    (error 'bootstrap! "already bootstrapped"))
  (seed-builtin-roles! conn)
  (define uid (create-user! conn #:username username #:operator? #t #:password pw))
  (define tid (create-team! conn #:name team-name #:slug team-slug))
  (add-member! conn #:user uid #:team tid #:role "owner")
  (audit! conn #:action "bootstrap" #:actor-type "user" #:actor-id uid #:team-id tid)
  (values uid tid))

;; ---- password / 2FA login ---------------------------------------------------
(define (set-password! conn user-id pw)
  (query-exec conn "UPDATE users SET password_hash = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ?"
              (hash-password pw) user-id))

;; verify the current password, then set a new one. Returns #f if current wrong.
(define (change-password! conn user-id current new)
  (define ph (query-maybe-value conn "SELECT password_hash FROM users WHERE id = ?" user-id))
  (cond
    [(or (not ph) (sql-null? ph) (not (verify-password current ph))) #f]
    [else (set-password! conn user-id new) #t]))

(define (enable-2fa! conn user-id #:account [account "user"])
  (define secret (new-totp-secret))
  (query-exec conn "UPDATE users SET totp_secret = ? WHERE id = ?" secret user-id)
  (values secret (totp-uri secret #:account account)))

(define (first-team-for conn user-id)
  (query-maybe-value conn
    "SELECT team_id FROM memberships WHERE user_id = ? AND status = 'active' ORDER BY created_at LIMIT 1"
    user-id))

;; verify username + password (+ TOTP code if 2FA is enabled) → user-id or #f
(define (authenticate conn username password #:code [code #f])
  (define row (query-maybe-row conn
    "SELECT id, password_hash, totp_secret FROM users WHERE username = ? AND status = 'active'" username))
  (cond
    [(not row) #f]
    [else
     (define uid (vector-ref row 0))
     (define ph (vector-ref row 1))
     (define secret (vector-ref row 2))
     (cond
       [(or (sql-null? ph) (not (verify-password password ph))) #f]
       [(and (not (sql-null? secret)) (string? secret) (not (string=? secret "")))
        (and code (totp-valid? secret code) uid)]     ; 2FA required
       [else uid])]))

;; ---- permission resolution --------------------------------------------------
(define (user-role-key conn user-id team-id)
  (query-maybe-value conn
    "SELECT role_key FROM memberships WHERE user_id = ? AND team_id = ? AND status = 'active'"
    user-id team-id))

;; a user's granted permission strings in a team (team-specific role overrides the
;; global built-in of the same key)
(define (user-permissions conn user-id team-id)
  (define rk (user-role-key conn user-id team-id))
  (cond
    [(not rk) '()]
    [else
     (define rid (or (query-maybe-value conn "SELECT id FROM roles WHERE key = ? AND team_id = ?" rk team-id)
                     (query-maybe-value conn "SELECT id FROM roles WHERE key = ? AND team_id IS NULL" rk)))
     (if rid (query-list conn "SELECT permission FROM role_permissions WHERE role_id = ?" rid) '())]))

;; ---- the check --------------------------------------------------------------
(define (can? conn p required #:resource [resource #f])
  (define base-ok
    (cond
      [(instance-perm? required) (and (principal-is-operator p) #t)]   ; operator tier only
      [(principal-is-operator p) #t]                                    ; operator supersedes team roles
      [else
       (define granted (user-permissions conn (principal-user-id p) (principal-team-id p)))
       (for/or ([g (in-list granted)]) (perm-matches? g required))]))
  ;; a resource owner has full rights on their own resource (non-instance)
  (define owner-ok
    (and resource (not (instance-perm? required))
         (equal? (hash-ref resource 'owner_user_id #f) (principal-user-id p))))
  ;; a token caps its issuer: the scope list must also cover the permission
  (define scope-ok
    (or (not (principal-token-scopes p))
        (for/or ([s (in-list (principal-token-scopes p))]) (perm-matches? s required))))
  (and (or base-ok owner-ok) scope-ok (resource-reachable? conn p resource required)))

(define (require-perm conn p required #:resource [resource #f])
  (unless (can? conn p required #:resource resource)
    (raise (exn:fail:forbidden (format "forbidden: ~a" required)
                               (current-continuation-marks) required))))

;; resource: a hash with 'team_id 'owner_user_id 'visibility (+ 'resource_type
;; 'resource_id for grant lookups). #f means a team-level (non-resource) action.
(define (resource-reachable? conn p res required)
  (cond
    [(not res) #t]
    [else
     (define rteam (hash-ref res 'team_id #f))
     (define owner (hash-ref res 'owner_user_id #f))
     (define vis   (hash-ref res 'visibility "team"))
     (cond
       [(and rteam (principal-team-id p) (not (equal? rteam (principal-team-id p))))
        (or (principal-is-operator p) (has-grant? conn res p required))]     ; cross-team
       [(or (equal? vis "private") (equal? vis "shared"))
        (or (equal? owner (principal-user-id p))
            (principal-is-operator p)
            (has-grant? conn res p required))]
       [else #t])]))                                                          ; team-visible

(define (has-grant? conn res p required)
  (define rtype (hash-ref res 'resource_type #f))
  (define rid   (hash-ref res 'resource_id #f))
  (cond
    [(or (not rtype) (not rid)) #f]
    [else
     (define rows (query-list conn
       (string-append
        "SELECT permission FROM resource_grants "
        "WHERE resource_type = ? AND resource_id = ? "
        "  AND ((principal_type = 'user' AND principal_id = ?) "
        "    OR (principal_type = 'team' AND principal_id = ?))")
       rtype rid (principal-user-id p) (or (principal-team-id p) "")))
     (for/or ([g (in-list rows)]) (perm-matches? g required))]))

;; ---- API tokens (issuer-perms ∩ scopes) ------------------------------------
(define token-salt "telemachus-token-v0")   ; prototype pepper; swap with the KDF seam
(define (hash-token tok) (sha1 (open-input-string (string-append token-salt tok))))

;; returns (values raw-token token-id); raw-token is shown once and never stored.
(define (issue-token! conn #:user user-id #:team team-id #:name [name sql-null] #:scopes [scopes '()])
  (define raw (random-token))
  (define tid (new-id))
  (query-exec conn
    (string-append "INSERT INTO api_tokens (id, user_id, team_id, name, token_hash, prefix, scopes) "
                   "VALUES (?, ?, ?, ?, ?, ?, ?)")
    tid user-id team-id name (hash-token raw)
    (substring raw 0 (min 11 (string-length raw)))
    (jsexpr->string scopes))
  (values raw tid))

;; list a team's tokens for management — prefixes only, never the raw token.
(define (list-tokens conn team-id)
  (for/list ([r (in-list (query-rows conn
     (string-append "SELECT id, name, prefix, scopes, status, last_used_at, created_at "
                    "FROM api_tokens WHERE team_id = ? ORDER BY created_at DESC") team-id))])
    (hasheq 'id (vector-ref r 0)
            'name (let ([n (vector-ref r 1)]) (if (sql-null? n) 'null n))
            'prefix (vector-ref r 2)
            'scopes (with-handlers ([exn:fail? (lambda (_) '())]) (string->jsexpr (vector-ref r 3)))
            'status (vector-ref r 4)
            'last_used_at (let ([x (vector-ref r 5)]) (if (sql-null? x) 'null x))
            'created_at (vector-ref r 6))))

;; revoke a token by id within a team. Returns #t if it existed.
(define (revoke-token! conn token-id team-id)
  (define exists (query-maybe-value conn "SELECT id FROM api_tokens WHERE id = ? AND team_id = ?" token-id team-id))
  (and exists (begin (query-exec conn "UPDATE api_tokens SET status = 'revoked' WHERE id = ?" token-id) #t)))

;; bearer token -> principal (capped by scopes), or #f if unknown/inactive.
(define (resolve-token conn bearer)
  (define row (query-maybe-row conn
    "SELECT user_id, team_id, scopes, status FROM api_tokens WHERE token_hash = ?"
    (hash-token bearer)))
  (cond
    [(not row) #f]
    [(not (equal? (vector-ref row 3) "active")) #f]
    [else
     (define user-id (vector-ref row 0))
     (define team-id (vector-ref row 1))
     (define scopes (with-handlers ([exn:fail? (lambda (_) '())])
                      (string->jsexpr (vector-ref row 2))))
     (define op (query-maybe-value conn "SELECT is_operator FROM users WHERE id = ?" user-id))
     (query-exec conn "UPDATE api_tokens SET last_used_at = CURRENT_TIMESTAMP WHERE token_hash = ?"
                 (hash-token bearer))
     (principal user-id (and (number? op) (not (zero? op))) team-id
                (if (list? scopes) scopes '()))]))

;; ---- resource grants (sharing) ---------------------------------------------
(define (grant! conn #:resource-type rtype #:resource-id rid
                #:principal-type ptype #:principal-id pid #:permission perm #:by [by sql-null])
  (query-exec conn
    (string-append "INSERT INTO resource_grants "
                   "(id, resource_type, resource_id, principal_type, principal_id, permission, granted_by) "
                   "VALUES (?, ?, ?, ?, ?, ?, ?) "
                   ;; portable upsert-ignore (sqlite 3.24+ and postgres both support this)
                   "ON CONFLICT (resource_type, resource_id, principal_type, principal_id, permission) DO NOTHING")
    (new-id) rtype rid ptype pid perm by))

(define (revoke! conn #:resource-type rtype #:resource-id rid
                 #:principal-type ptype #:principal-id pid #:permission perm)
  (query-exec conn
    (string-append "DELETE FROM resource_grants WHERE resource_type = ? AND resource_id = ? "
                   "AND principal_type = ? AND principal_id = ? AND permission = ?")
    rtype rid ptype pid perm))

;; ---- audit ------------------------------------------------------------------
(define (audit! conn #:action action
                #:actor-type [actor-type sql-null] #:actor-id [actor-id sql-null]
                #:team-id [team-id sql-null] #:resource-type [resource-type sql-null]
                #:resource-id [resource-id sql-null] #:result [result "ok"] #:meta [meta sql-null])
  (query-exec conn
    (string-append "INSERT INTO audit_log "
                   "(id, actor_type, actor_id, team_id, action, resource_type, resource_id, result, meta) "
                   "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)")
    (new-id) actor-type actor-id team-id action resource-type resource-id result meta))

;; recent audit events for a team (newest first), for the management UI.
(define (audit-list conn team-id #:limit [lim 50] #:offset [off 0])
  (define (nz x) (if (sql-null? x) 'null x))
  (for/list ([r (in-list (query-rows conn
     (string-append "SELECT id, action, actor_type, actor_id, resource_type, resource_id, result, at "
                    "FROM audit_log WHERE team_id = ? ORDER BY at DESC, id DESC LIMIT ? OFFSET ?")
     team-id lim off))])
    (hasheq 'id (vector-ref r 0) 'action (vector-ref r 1)
            'actor_type (nz (vector-ref r 2)) 'actor_id (nz (vector-ref r 3))
            'resource_type (nz (vector-ref r 4)) 'resource_id (nz (vector-ref r 5))
            'result (nz (vector-ref r 6)) 'at (vector-ref r 7))))
