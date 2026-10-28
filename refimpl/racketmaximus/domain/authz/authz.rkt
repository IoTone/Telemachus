#lang racket/base

;; #128 job 2: operator-facing variables are read through ONE accessor,
;; which tries TMACH_<name> and falls back to TELEMACHUS_<name>.
(require (only-in "../../config.rkt" tmach-env))

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

(require racket/date db-kit/portable
         json
         racket/random          ; crypto-random-bytes — recovery codes (issue #26)
         file/sha1
         "../db/id.rkt"
         "permissions.rkt"
         "passwords.rkt"
         sha2-kit                 ; hmac-sha256 (libcrypto) — the token hash
         (only-in "secretbox.rkt" secret-wrap secret-unwrap)   ; secrets at rest (issue #19)
         "session-policy.rkt"     ; idle + absolute session timeouts (issue #38)
         (only-in "crypto.rkt" constant-time=?)
         ;; #110 r5: `nz`, `nz/false` and `nz/string` were three hand-written
         ;; copies in THIS file alone — and two of them were both called `nz`,
         ;; the module-level one answering #f and a local one inside
         ;; `audit-list` answering 'null.
         "../db/nulls.rkt")

(provide (struct-out principal)
         (struct-out exn:fail:forbidden)
         user-principal principal-for
         create-user! create-team! add-member!
         create-org! team-org user-org set-user-org-role!
         seed-builtin-roles! bootstrap!
         user-permissions
         can? require-perm
         issue-token! resolve-token list-tokens revoke-token! API-TOKEN-TTL
         ;; issue #118: a person's own browser sessions, which are their own rows
         token-id-for-bearer user-sessions revoke-session! revoke-other-sessions!
         max-sessions enforce-session-cap!
         ;; issue #116: the sign-in attempt throttle
         login-throttle login-failed! login-succeeded! login-lock-clear!
         login-delay-for login-lock-after
         ;; issue #38: callers name the kind of credential they are minting
         (all-from-out "session-policy.rkt")
         hash-token legacy-hash-token token-pepper-is-default?
         grant! revoke!
         audit! audit-list
         set-password! change-password! authenticate enable-2fa! reset-2fa! first-team-for
         member-role team-owner-count set-member-role! deactivate-member!
         revoke-user-sessions!
         issue-recovery-codes! recovery-codes-remaining RECOVERY-CODE-COUNT
         user-locale set-user-locale! org-data-reader? org-teams-of)

;; every team id in an org, for an org-scoped listing (TEN-2h)
(define (org-teams-of conn org-id)
  (query-list conn "SELECT id FROM teams WHERE org_id = ? ORDER BY created_at, slug" org-id))

;; ---- principal --------------------------------------------------------------
;; token-scopes: #f = direct user (uncapped by scopes); (listof string) = token.
;; org-id:   the principal's HOME organization (#f = instance-level, i.e. the
;;           superadmin, who belongs to no company and may cross orgs).
;; org-role: #f | "org_admin" | "org_owner" — the company-administration tier.
(struct principal (user-id is-operator team-id token-scopes org-id org-role) #:transparent)

(struct exn:fail:forbidden exn:fail (permission) #:transparent)


(define (user-principal conn user-id team-id)
  (define row (query-maybe-row conn
    "SELECT is_operator, org_id, org_role_key FROM users WHERE id = ?" user-id))
  (define op (and row (vector-ref row 0)))
  (principal user-id (and (number? op) (not (zero? op))) team-id #f
             (and row (nz/false (vector-ref row 1)))
             (and row (nz/false (vector-ref row 2)))))

;; resolve a trusted (username, team-slug) pair to a direct-user principal
;; team slugs are unique per ORG (slice 45), so resolve the slug inside the user's
;; own org first; fall back to a global match only when the user has no org yet.
(define (principal-for conn username team-slug)
  (define row (query-maybe-row conn "SELECT id, org_id FROM users WHERE username = ?" username))
  (define uid (and row (vector-ref row 0)))
  (define oid (and row (nz/false (vector-ref row 1))))
  (define tid (or (and oid (query-maybe-value conn
                             "SELECT id FROM teams WHERE slug = ? AND org_id = ?" team-slug oid))
                  (query-maybe-value conn "SELECT id FROM teams WHERE slug = ?" team-slug)))
  (and uid tid (user-principal conn uid tid)))

;; ---- creation ---------------------------------------------------------------
;; the user's own language (slice 47) — bound by workflows as ${principal.locale}
(define (user-locale conn user-id)
  (define v (query-maybe-value conn "SELECT locale FROM users WHERE id = ?" user-id))
  (if (or (not v) (sql-null? v) (equal? v "")) "en" v))

(define (set-user-locale! conn user-id locale)
  (query-exec conn "UPDATE users SET locale = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ?" locale user-id)
  locale)

(define (create-user! conn #:username username #:operator? [operator? #f]
                      #:display-name [display-name sql-null] #:password [pw #f]
                      #:org [org-id #f] #:org-role [org-role #f])
  (define uid (new-id))
  (query-exec conn
    (string-append "INSERT INTO users (id, username, display_name, is_operator, password_hash, "
                   "org_id, org_role_key) VALUES (?, ?, ?, ?, ?, ?, ?)")
    uid username display-name (if operator? 1 0) (if pw (hash-password pw) sql-null)
    (or org-id sql-null) (or org-role sql-null))
  uid)

;; ---- organizations (slice 45) ----------------------------------------------
;; The org is the tenancy layer ABOVE teams. It always exists — single-tenant
;; deployments simply have exactly one. See docs/design/multi-tenancy.md.
(define (create-org! conn #:name name #:slug slug #:plan [plan "trial"])
  (define oid (new-id))
  (query-exec conn "INSERT INTO orgs (id, slug, name, plan) VALUES (?, ?, ?, ?)" oid slug name plan)
  oid)

(define (team-org conn team-id)
  (and team-id (nz/false (query-maybe-value conn "SELECT org_id FROM teams WHERE id = ?" team-id))))

(define (user-org conn user-id)
  (and user-id (nz/false (query-maybe-value conn "SELECT org_id FROM users WHERE id = ?" user-id))))

;; promote/demote a user within their company. role-key: #f | org_admin | org_owner
(define (set-user-org-role! conn user-id role-key)
  (query-exec conn "UPDATE users SET org_role_key = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ?"
              (or role-key sql-null) user-id))

(define (create-team! conn #:name name #:slug slug #:org [org-id #f])
  (define tid (new-id))
  (query-exec conn "INSERT INTO teams (id, slug, name, org_id) VALUES (?, ?, ?, ?)"
              tid slug name (or org-id sql-null))
  tid)

;; Joining a team also settles the user's home org: a user belongs to exactly one
;; org (TEN-2c), so this is the single seam where org membership is established.
;; Raises if the user is already in a DIFFERENT org — that would break the gate.
(define (add-member! conn #:user user-id #:team team-id #:role role-key)
  (define torg (team-org conn team-id))
  (define uorg (user-org conn user-id))
  (when (and torg uorg (not (equal? torg uorg)))
    (error 'add-member! "user ~a belongs to org ~a; cannot join a team in org ~a" user-id uorg torg))
  (when (and torg (not uorg))
    (query-exec conn "UPDATE users SET org_id = ? WHERE id = ?" torg user-id))
  (define mid (new-id))
  (query-exec conn
    "INSERT INTO memberships (id, user_id, team_id, role_key) VALUES (?, ?, ?, ?)"
    mid user-id team-id role-key)
  mid)

;; ---- membership stewardship (issue #54) --------------------------------------
;; There was no way to change a member's role, and no way to remove one at all,
;; so a team could be joined and never left. Combined with a password change that
;; revoked nothing, offboarding somebody was not expressible.

(define (member-role conn team-id user-id)
  (define v (query-maybe-value conn
    "SELECT role_key FROM memberships WHERE team_id = ? AND user_id = ? AND status = 'active'"
    team-id user-id))
  (and v (not (sql-null? v)) v))

(define (team-owner-count conn team-id)
  (query-value conn
    "SELECT COUNT(*) FROM memberships WHERE team_id = ? AND role_key = 'owner' AND status = 'active'"
    team-id))

;; Revoke a person's tokens FOR ONE TEAM. Removing somebody whose credentials go
;; on working is not removing them.
(define (revoke-user-team-tokens! conn user-id team-id)
  (define n (query-value conn
    "SELECT COUNT(*) FROM api_tokens WHERE user_id = ? AND team_id = ? AND status = 'active'"
    user-id team-id))
  (query-exec conn
    "UPDATE api_tokens SET status = 'revoked' WHERE user_id = ? AND team_id = ? AND status = 'active'"
    user-id team-id)
  n)

;; A password change invalidates every SESSION, across teams — the reason a person
;; changes a password is that they think it is known, and every session it minted
;; is then suspect. Machine credentials (api, worker) are deliberately spared:
;; they are not reachable with the password, they are listed and revocable on
;; their own, and silently killing a customer's worker because somebody rotated a
;; password is the worse failure — the same call issue #13's NULL expiry made.
(define (revoke-user-sessions! conn user-id)
  (define n (query-value conn
    "SELECT COUNT(*) FROM api_tokens WHERE user_id = ? AND status = 'active' AND kind = ?"
    user-id SESSION-KIND))
  (query-exec conn
    "UPDATE api_tokens SET status = 'revoked' WHERE user_id = ? AND status = 'active' AND kind = ?"
    user-id SESSION-KIND)
  n)

;; A team must always have an owner: a team with none cannot grant anybody the
;; permission to fix it, and `roles:manage` lives at the team tier. So the last
;; owner can be neither demoted nor removed.
;; -> 'no-such-member | 'unknown-role | 'last-owner | the new role
(define (set-member-role! conn team-id user-id role)
  (define cur (member-role conn team-id user-id))
  (cond
    [(not cur) 'no-such-member]
    [(not (query-maybe-value conn
            "SELECT id FROM roles WHERE key = ? AND (team_id IS NULL OR team_id = ?)" role team-id))
     'unknown-role]
    [(and (equal? cur "owner") (not (equal? role "owner")) (<= (team-owner-count conn team-id) 1))
     'last-owner]
    [else
     (query-exec conn "UPDATE memberships SET role_key = ? WHERE team_id = ? AND user_id = ?"
                 role team-id user-id)
     role]))

;; Deactivate, never delete: the row is the record that this person was on the
;; team, which an audit needs, and what they own still points at the user. An
;; inactive membership yields no role, and `user-permissions` returns '() without
;; one, so the deny is the one that already existed rather than a new code path.
;; -> 'no-such-member | 'last-owner | the number of tokens revoked
(define (deactivate-member! conn team-id user-id)
  (define cur (member-role conn team-id user-id))
  (cond
    [(not cur) 'no-such-member]
    [(and (equal? cur "owner") (<= (team-owner-count conn team-id) 1)) 'last-owner]
    [else
     (query-exec conn "UPDATE memberships SET status = 'inactive' WHERE team_id = ? AND user_id = ?"
                 team-id user-id)
     (revoke-user-team-tokens! conn user-id team-id)]))

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
                    #:team-name [team-name "Default"] #:team-slug [team-slug "default"]
                    #:org-name [org-name "Default Organization"] #:org-slug [org-slug "default"])
  (when (query-maybe-value conn "SELECT id FROM users LIMIT 1")
    (error 'bootstrap! "already bootstrapped"))
  (seed-builtin-roles! conn)
  ;; the org always exists — single-tenant is "exactly one org", not "no org", so
  ;; the schema and the authorization path are identical in both modes.
  (define oid (or (query-maybe-value conn "SELECT id FROM orgs WHERE slug = ?" org-slug)
                  (create-org! conn #:name org-name #:slug org-slug #:plan "self-hosted")))
  (define uid (create-user! conn #:username username #:operator? #t #:password pw))
  (define tid (create-team! conn #:name team-name #:slug team-slug #:org oid))
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

;; The seed is the one secret here that cannot be reissued by the person who owns
;; it without help, so it is also the one worth encrypting at rest (issue #19) and
;; the one worth being able to REVOKE — see reset-2fa! below.
(define (totp-context user-id) (string-append "users.totp_secret:" user-id))

;; ---- recovery codes (issue #26) -----------------------------------------------
;; The way back in when the authenticator is gone. Unlike the seed, a code is
;; COMPARED rather than computed from, so it is stored as a hash — the same
;; peppered HMAC-SHA-256 an API token uses, so rotating the pepper retires
;; outstanding codes along with outstanding tokens, which is the behaviour an
;; operator rotating a leaked pepper wants.
;;
;; Single use: a spent code's row is kept with `used_at` set rather than deleted,
;; so "you have already used this one" is distinguishable from "that is not a
;; code" in an audit, and a re-issue can say how many were spent.
(define RECOVERY-CODE-COUNT 10)
(define CODE-ALPHABET "abcdefghjkmnpqrstuvwxyz23456789")   ; no l/i/o/0/1 — these get read aloud

(define (new-recovery-code)
  (define (chunk n)
    (list->string (for/list ([b (in-bytes (crypto-random-bytes n))])
                    (string-ref CODE-ALPHABET (modulo b (string-length CODE-ALPHABET))))))
  (string-append (chunk 5) "-" (chunk 5)))

;; Codes are matched case-insensitively and with dashes optional: they are typed
;; by a person, off paper, usually badly.
(define (normalize-code s)
  (string-downcase (regexp-replace* #px"[^0-9a-zA-Z]" (if (string? s) s "") "")))
(define (hash-recovery-code s) (hash-token (string-append "recovery:" (normalize-code s))))

;; Issue a fresh set, invalidating any outstanding ones, and return the plaintext
;; ONCE. Replacing rather than topping up is deliberate: a set printed on paper
;; should be the whole truth about what opens this account.
(define (issue-recovery-codes! conn user-id #:count [n RECOVERY-CODE-COUNT])
  (query-exec conn "DELETE FROM user_recovery_codes WHERE user_id = ?" user-id)
  (for/list ([_ (in-range n)])
    (define code (new-recovery-code))
    (query-exec conn "INSERT INTO user_recovery_codes (id, user_id, code_hash) VALUES (?, ?, ?)"
                (new-id) user-id (hash-recovery-code code))
    code))

(define (recovery-codes-remaining conn user-id)
  (query-value conn "SELECT COUNT(*) FROM user_recovery_codes WHERE user_id = ? AND used_at IS NULL" user-id))

;; Spend one. -> #t if it was valid and unspent; the row is burned in the same
;; statement it is matched by, so two simultaneous sign-ins cannot both spend it.
(define (spend-recovery-code! conn user-id code)
  (define h (hash-recovery-code code))
  (define r (query conn
    (string-append "UPDATE user_recovery_codes SET used_at = CURRENT_TIMESTAMP "
                   "WHERE user_id = ? AND code_hash = ? AND used_at IS NULL RETURNING id")
    user-id h))
  (and (rows-result? r) (pair? (rows-result-rows r))))

(define (enable-2fa! conn user-id #:account [account "user"])
  (define secret (new-totp-secret))
  (query-exec conn "UPDATE users SET totp_secret = ? WHERE id = ?"
              (secret-wrap (totp-context user-id) secret) user-id)
  ;; enrolling issues the way back in at the same time — a second factor handed
  ;; out without one is how people get locked out of their own instance
  (define codes (issue-recovery-codes! conn user-id))
  (values secret (totp-uri secret #:account account) codes))

;; Clear a user's second factor so they must enrol again, and the old seed — a
;; seed that may sit in a database dump somebody took — stops working. An operator
;; may do this for anyone; anyone may do it for themselves. Returns #t if 2FA was
;; on. This is what makes a leaked seed a recoverable incident rather than a
;; permanent one: a TOTP seed cannot be rotated by using it, the way a password or
;; an access key can.
(define (reset-2fa! conn user-id)
  (define had (query-maybe-value conn "SELECT totp_secret FROM users WHERE id = ?" user-id))
  (query-exec conn "UPDATE users SET totp_secret = NULL WHERE id = ?" user-id)
  ;; the codes go with the seed: they exist to open this second factor, and a
  ;; revoked factor's codes must not survive into the next enrolment
  (query-exec conn "DELETE FROM user_recovery_codes WHERE user_id = ?" user-id)
  (and had (not (sql-null? had)) (string? had) (not (string=? had "")) #t))

(define (first-team-for conn user-id)
  (query-maybe-value conn
    "SELECT team_id FROM memberships WHERE user_id = ? AND status = 'active' ORDER BY created_at LIMIT 1"
    user-id))

;; verify username + password (+ TOTP code if 2FA is enabled) → user-id or #f
(define (authenticate conn username password #:code [code #f])
  (define row (query-maybe-row conn
    "SELECT id, password_hash, totp_secret FROM users WHERE username = ? AND status = 'active'" username))
  (cond
    ;; issue #117: BOTH of these used to be a bare #f, which returned before any
    ;; KDF work and so told a caller by timing whether the account existed. They
    ;; verify against a dummy hash of the same cost now; `verify-absent-password`
    ;; always answers #f, so it is the branch's result rather than a side effect
    ;; somebody can drop. A NULL `password_hash` is the second case and is not
    ;; hypothetical — `POST /api/orgs` without `owner_password` creates one.
    [(not row) (verify-absent-password password)]
    [else
     (define uid (vector-ref row 0))
     (define ph (vector-ref row 1))
     (define secret (vector-ref row 2))
     (cond
       [(sql-null? ph) (verify-absent-password password)]
       [(not (verify-password password ph)) #f]
       [(and (not (sql-null? secret)) (string? secret) (not (string=? secret "")))
        ;; the stored seed may be sealed (issue #19); a row written before a key was
        ;; configured is plaintext and passes through unchanged
        (and code
             (or (totp-valid? (secret-unwrap (totp-context uid) secret) code)
                 ;; …or a recovery code, spent as it is checked (issue #26)
                 (spend-recovery-code! conn uid code))
             uid)]   ; 2FA required
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

;; a user's ORG-level permissions (slice 45), from users.org_role_key. Org roles
;; are rows in the same `roles` table (team_id NULL), so their contents are data.
;; Empty for an ordinary user — the tier is opt-in, never implied by a team role.
(define (user-org-permissions conn p)
  (define rk (principal-org-role p))
  (cond
    [(not rk) '()]
    [else
     (define rid (query-maybe-value conn "SELECT id FROM roles WHERE key = ? AND team_id IS NULL" rk))
     (if rid (query-list conn "SELECT permission FROM role_permissions WHERE role_id = ?" rid) '())]))

;; The org this check happens in: the resource's team's org, else the principal's
;; acting team's org, else their home org.
;; does the principal's ORG role (not its team role) cover this permission?
(define (org-tier-covers? conn p required)
  (for/or ([g (in-list (user-org-permissions conn p))]) (perm-matches? g required)))

;; TEN-2h: an org role holding `org:read-data` covers the team-tier data READS
;; (and only those) across the company
(define (org-data-reader? conn p required)
  (and (member required DATA-READ-PERMS)
       (org-tier-covers? conn p "org:read-data")
       #t))

(define (target-org conn p resource)
  (define rteam (and resource (hash-ref resource 'team_id #f)))
  (or (and rteam (team-org conn rteam))
      (team-org conn (principal-team-id p))
      (principal-org-id p)))

;; STEP 0 — the tenancy gate. Runs BEFORE permissions, owner-ok, scopes and
;; grants, and denies unconditionally, so no sharing path can tunnel out of an
;; org. Superadmins cross orgs by design; everyone else is sealed in.
(define (org-gate-ok? conn p resource)
  (or (principal-is-operator p)
      (let ([t (target-org conn p resource)])
        (or (not t) (equal? t (principal-org-id p))))))

;; ---- the check --------------------------------------------------------------
(define (can? conn p required #:resource [resource #f])
  (define gate-ok (org-gate-ok? conn p resource))
  (define base-ok
    (cond
      [(not gate-ok) #f]                                                ; step 0: tenancy gate
      [(instance-perm? required) (and (principal-is-operator p) #t)]   ; operator tier only
      [(org-perm? required)                                             ; company-admin tier only
       (or (principal-is-operator p)
           (for/or ([g (in-list (user-org-permissions conn p))]) (perm-matches? g required)))]
      [(principal-is-operator p) #t]                                    ; operator supersedes team roles
      [else
       ;; an org admin manages every team in its own org without a membership
       ;; there — its grants are unioned with whatever team role it may hold.
       (define granted (append (user-permissions conn (principal-user-id p) (principal-team-id p))
                               (user-org-permissions conn p)))
       (or (for/or ([g (in-list granted)]) (perm-matches? g required))
           ;; TEN-2h: an org reader holds the team-tier READ permissions on data in
           ;; every team of its company — reachability below still keeps private
           ;; resources private and the org gate keeps it inside the company
           (org-data-reader? conn p required)
           ;; A resource grant is a DELEGATION (slice 56, DSH-1): a steward handed
           ;; this principal a permission on ONE resource, and it holds even when
           ;; the team role lacks it — that is what sharing an editable document
           ;; with a viewer, or delegating `manage` to a member, means. It reaches
           ;; only the team tier (never instance:* / org:*), only that resource,
           ;; and it is still capped by token scopes below.
           (and resource (has-grant? conn resource p required)))]))
  ;; a resource owner has full rights on their own resource (non-instance)
  (define owner-ok
    (and resource (not (instance-perm? required))
         (equal? (hash-ref resource 'owner_user_id #f) (principal-user-id p))))
  ;; a token caps its issuer: the scope list must also cover the permission
  (define scope-ok
    (or (not (principal-token-scopes p))
        (for/or ([s (in-list (principal-token-scopes p))]) (perm-matches? s required))))
  (and gate-ok (or base-ok owner-ok) scope-ok (resource-reachable? conn p resource required)))

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
        ;; cross-team. The org gate above has already confirmed same-org.
        (or (principal-is-operator p)
            ;; an org admin reaches SIBLING teams in its own company for the
            ;; permissions its ORG role grants — that is what "administers the
            ;; company" means. Team-tier permissions never cross a team boundary,
            ;; and nothing at this tier reaches a `private` resource (TEN-2a).
            (and (or (org-tier-covers? conn p required)
                     (org-data-reader? conn p required))              ; TEN-2h
                 (not (equal? (hash-ref res 'visibility "team") "private")))
            (has-grant? conn res p required))]
       [(or (equal? vis "private") (equal? vis "shared"))
        (or (equal? owner (principal-user-id p))
            (principal-is-operator p)
            (has-grant? conn res p required))]
       [else #t])]))                                                          ; team-visible

(define (has-grant? conn res p required)
  (define rtype (hash-ref res 'resource_type #f))
  (define rid   (hash-ref res 'resource_id #f))
  (cond
    ;; a resource_grant never crosses an org boundary, even if the row exists
    [(not (org-gate-ok? conn p res)) #f]
    [(or (not rtype) (not rid)) #f]
    [else
     (define rows (query-list conn
       (string-append
        "SELECT permission FROM resource_grants "
        "WHERE resource_type = ? AND resource_id = ? "
        "  AND ((principal_type = 'user' AND principal_id = ?) "
        "    OR (principal_type = 'team' AND principal_id = ?)) "
        ;; DSH-3: an expired grant is ignored, not deleted — the row stays as the
        ;; record of who was given what; it just no longer opens anything.
        "  AND (expires_at IS NULL OR expires_at > ?)")
       rtype rid (principal-user-id p) (or (principal-team-id p) "") (current-seconds)))
     (for/or ([g (in-list rows)]) (perm-matches? g required))]))

;; ---- API tokens (issuer-perms ∩ scopes) ------------------------------------
;; ---- the token hash ---------------------------------------------------------
;; A bearer is 24 random bytes, so the hash exists to make a database dump
;; worthless, not to slow a brute force. It is HMAC-SHA-256 keyed by a PEPPER
;; from the environment (TELEMACHUS_TOKEN_PEPPER, else TELEMACHUS_SECRET, else a
;; dev default the server warns about at boot): a dump without the process's
;; environment cannot be replayed. Stored as "v1:<hex>" so the rows written by
;; the prototype scheme — bare SHA-1 with a compiled-in salt, 40 hex chars — are
;; recognized, still resolve, and are REHASHED ON FIRST USE; nobody signs in
;; again because of the upgrade. Rotating the pepper invalidates every v1 token
;; at once, which is the point of having one.
(define LEGACY-TOKEN-SALT "telemachus-token-v0")
(define (legacy-hash-token tok) (sha1 (open-input-string (string-append LEGACY-TOKEN-SALT tok))))
(define DEV-PEPPER "telemachus-dev-secret")
(define (token-pepper)
  (define (env k) (let ([v (getenv k)]) (and v (not (string=? v "")) v)))
  (or (tmach-env "TOKEN_PEPPER") (tmach-env "SECRET") DEV-PEPPER))
(define (token-pepper-is-default?) (string=? (token-pepper) DEV-PEPPER))
(define (hash-token tok)
  (string-append "v1:" (bytes->hex-lower (hmac-sha256 (string->bytes/utf-8 (token-pepper)) (string->bytes/utf-8 tok)))))
(define TOKEN-SELECT
  (string-append "SELECT user_id, team_id, scopes, status, expires_at, token_hash, "
                 "kind, created_epoch, last_used_epoch FROM api_tokens WHERE token_hash = ?"))
;; the row for a bearer: the current hash first, then the legacy one — and a legacy
;; hit is rewritten to the current scheme before it is used
(define (token-row conn bearer)
  (define h (hash-token bearer))
  (or (query-maybe-row conn TOKEN-SELECT h)
      (let ([r (query-maybe-row conn TOKEN-SELECT (legacy-hash-token bearer))])
        (and r
             (begin (query-exec conn "UPDATE api_tokens SET token_hash = ? WHERE token_hash = ?" h (legacy-hash-token bearer))
                    (vector-set! r 5 h)
                    r)))))

;; returns (values raw-token token-id); raw-token is shown once and never stored.
;; Expiry (issue #13): `expires_at` existed from migration 0001 and nothing ever
;; read it, so every token — the console's own session included — lived forever.
;; Stored as EPOCH SECONDS in the TEXT column (the column predates the epoch
;; convention; a text integer sorts and compares fine, and stays dialect-neutral).
;; `#:ttl` is seconds from now; #f means "the default for this kind of token";
;; 'never means no expiry — for a machine token an operator explicitly wants
;; long-lived. The defaults are deliberately different: a session (login,
;; bootstrap, member-add) is 30 days, an API token issued from the console 90 days.
(define SESSION-TTL (* 30 24 3600))
(define API-TOKEN-TTL (* 90 24 3600))
;; #:kind is what decides whether the session timeouts apply at all (issue #38):
;; "session" for an interactive sign-in, "api" for a credential a program holds,
;; "worker" for a pull executor. It defaults to "api" — the exempt value — so a
;; caller that forgets it produces a token that behaves exactly as tokens did
;; before, rather than one that silently starts idling out.
(define (issue-token! conn #:user user-id #:team team-id #:name [name sql-null] #:scopes [scopes '()]
                      #:ttl [ttl #f] #:kind [kind API-KIND])
  (define raw (random-token))
  (define tid (new-id))
  (define now (current-seconds))
  (define expires
    (cond [(eq? ttl 'never) sql-null]
          [(and (real? ttl) (positive? ttl)) (number->string (+ now (inexact->exact (floor ttl))))]
          [else (number->string (+ now SESSION-TTL))]))
  (query-exec conn
    (string-append "INSERT INTO api_tokens (id, user_id, team_id, name, token_hash, prefix, scopes, expires_at, "
                   "kind, created_epoch, last_used_epoch) "
                   "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)")
    tid user-id team-id name (hash-token raw)
    (substring raw 0 (min 11 (string-length raw)))
    (jsexpr->string scopes) expires
    kind now
    ;; the idle clock starts at issue, not at first use: a session minted and then
    ;; abandoned should lapse on the same schedule as one that was used once
    now)
  ;; The per-identity cap is NOT applied here, on purpose: `issue-token!` has 25
  ;; call sites and the cap is a property of interactive SIGN-IN, not of minting
  ;; a token. `ep-login` calls `enforce-session-cap!` itself, which also lets it
  ;; audit what the eviction removed — a session that ends by itself with no
  ;; record is indistinguishable, to its owner, from one that was stolen.
  (values raw tid))

;; the row's expires_at as epoch seconds, or #f for never. Tolerates the empty
;; string and garbage (treated as never) so a hand-edited row cannot lock anyone out.
(define (token-expiry row-value)
  (and (not (sql-null? row-value))
       (let ([n (string->number (format "~a" row-value))]) (and (exact-integer? n) n))))
(define (token-expired? row-value)
  (let ([e (token-expiry row-value)]) (and e (<= e (current-seconds)))))

;; list a team's tokens for management — prefixes only, never the raw token.
(define (list-tokens conn team-id)
  (for/list ([r (in-list (query-rows conn
     (string-append "SELECT id, name, prefix, scopes, status, last_used_at, created_at, expires_at, kind "
                    "FROM api_tokens WHERE team_id = ? ORDER BY created_at DESC") team-id))])
    (define exp (token-expiry (vector-ref r 7)))
    (hasheq 'id (vector-ref r 0)
            'name (let ([n (vector-ref r 1)]) (if (sql-null? n) 'null n))
            'prefix (vector-ref r 2)
            'scopes (with-handlers ([exn:fail? (lambda (_) '())]) (string->jsexpr (vector-ref r 3)))
            ;; an expired token reads as `expired` here even though the row says
            ;; `active` — the list is for a person deciding what to revoke
            'status (if (and (equal? (vector-ref r 4) "active") (token-expired? (vector-ref r 7)))
                        "expired" (vector-ref r 4))
            'last_used_at (let ([x (vector-ref r 5)]) (if (sql-null? x) 'null x))
            'created_at (vector-ref r 6)
            'expires_at (if exp (epoch->iso8601 exp) 'null)
            ;; issue #38: which credential this is, so an operator can tell a
            ;; browser session from a machine token before revoking one
            'kind (nz/string (vector-ref r 8)))))

(define (epoch->iso8601 secs)
  (define d (seconds->date secs #f))
  (define (two n) (if (< n 10) (format "0~a" n) (number->string n)))
  (format "~a-~a-~aT~a:~a:~aZ" (date-year d) (two (date-month d)) (two (date-day d))
          (two (date-hour d)) (two (date-minute d)) (two (date-second d))))

;; revoke a token by id within a team. Returns #t if it existed.
(define (revoke-token! conn token-id team-id)
  (define exists (query-maybe-value conn "SELECT id FROM api_tokens WHERE id = ? AND team_id = ?" token-id team-id))
  (and exists (begin (query-exec conn "UPDATE api_tokens SET status = 'revoked' WHERE id = ?" token-id) #t)))

;; ---- the caller's own sessions (issue #118) ---------------------------------
;; #38 bounded how long a session CAN live and gave nobody a way to end one. The
;; console's sign-out cleared localStorage and called no route, so on a shared
;; machine a valid bearer sat in that browser and a valid row sat here for up to
;; the absolute cap.
;;
;; These are deliberately NOT on `list-tokens`/`revoke-token!`, which are the
;; TEAM's API tokens behind `settings:manage`. A person's own browser sessions
;; are their own rows — owner-ok, the rule notes and documents already live by —
;; and widening the team route would have handed a member the team's machine
;; credentials to look at. `kind` (migration 0032) is what makes the two
;; separable: SESSION-KIND here, and nothing else.

;; the id of the row a bearer names, for "which of these is the one I am holding"
;; and for a logout that ends exactly this session. A separate query rather than a
;; wider TOKEN-SELECT: `resolve-token` reads that row BY POSITION, so adding a
;; column there would shift every index.
(define (token-id-for-bearer conn bearer)
  (and (string? bearer)
       (let ([h (hash-token bearer)])
         (or (query-maybe-value conn "SELECT id FROM api_tokens WHERE token_hash = ?" h)
             (query-maybe-value conn "SELECT id FROM api_tokens WHERE token_hash = ?"
                                (legacy-hash-token bearer))))))

(define (user-sessions conn user-id #:current [current-id #f])
  (for/list ([r (in-list (query-rows conn
     (string-append "SELECT id, name, prefix, status, created_at, last_used_at, expires_at, "
                    "created_epoch, last_used_epoch FROM api_tokens "
                    ;; `created_epoch` is SECONDS, so two sessions minted inside
                    ;; one second tie and come back in whatever order the engine
                    ;; gives — cosmetic for a list a person reads, and the reason
                    ;; a test must age its rows rather than assert on insertion
                    ;; order (the trap doc_trigger_fires named with fired_ms).
                    "WHERE user_id = ? AND kind = ? ORDER BY created_epoch DESC, created_at DESC")
     user-id SESSION-KIND))])
    (define exp (token-expiry (vector-ref r 6)))
    (hasheq 'id (vector-ref r 0)
            'name (nz (vector-ref r 1))
            ;; the prefix, never the token: it is enough to tell two sessions
            ;; apart in a list and useless as a credential
            'prefix (vector-ref r 2)
            'status (if (and (equal? (vector-ref r 3) "active") (token-expired? (vector-ref r 6)))
                        "expired" (vector-ref r 3))
            'created_at (vector-ref r 4)
            'last_used_at (nz (vector-ref r 5))
            'expires_at (if exp (epoch->iso8601 exp) 'null)
            ;; which row the caller is holding right now, so a UI can label it and
            ;; refuse to let somebody end it by accident while meaning another
            'current (and current-id (equal? (vector-ref r 0) current-id)))))

;; end ONE of the caller's own sessions. Scoped by user_id AND kind in the
;; statement, not checked beforehand: a member must not be able to revoke a
;; colleague's session or the team's worker token by guessing an id.
(define (revoke-session! conn user-id session-id)
  (define hit (query-maybe-value conn
    "SELECT id FROM api_tokens WHERE id = ? AND user_id = ? AND kind = ?"
    session-id user-id SESSION-KIND))
  (and hit
       (begin (query-exec conn "UPDATE api_tokens SET status = 'revoked' WHERE id = ?" session-id) #t)))

;; end every OTHER session of this user — the "sign out everywhere else" case.
;; `keep-id` #f ends them all, which is what a plain logout of the last one does.
(define (revoke-other-sessions! conn user-id keep-id)
  ;; TWO STATEMENTS, NOT ONE WITH AN INTERPOLATED CLAUSE. The first version of
  ;; this built `" AND id <> ?"` conditionally and passed a fixed argument list,
  ;; so the clause and its parameter came apart and every call raised "wrong
  ;; number of parameters" — the exact trap #86 slice 1 paid for in
  ;; `blob-referenced?`, written here in a comment two lines above the bug.
  ;; test/signin-tests.rkt is what caught it.
  (cond
    [keep-id
     (define n (query-value conn
       (string-append "SELECT COUNT(*) FROM api_tokens WHERE user_id = ? AND kind = ? "
                      "AND status = 'active' AND id <> ?")
       user-id SESSION-KIND keep-id))
     (query-exec conn
       (string-append "UPDATE api_tokens SET status = 'revoked' WHERE user_id = ? AND kind = ? "
                      "AND status = 'active' AND id <> ?")
       user-id SESSION-KIND keep-id)
     n]
    [else
     (define n (query-value conn
       "SELECT COUNT(*) FROM api_tokens WHERE user_id = ? AND kind = ? AND status = 'active'"
       user-id SESSION-KIND))
     (query-exec conn
       "UPDATE api_tokens SET status = 'revoked' WHERE user_id = ? AND kind = ? AND status = 'active'"
       user-id SESSION-KIND)
     n]))

;; How many sessions one identity may hold at once. The cap EVICTS THE OLDEST
;; rather than refusing the newest, and that is the whole decision: "refuse the
;; N+1th sign-in" turns a full session table into a lockout, and since nothing
;; ended a session early before this slice, an ordinary person on a laptop, a
;; phone and a second browser would have reached it within a week. Evicting
;; bounds what a stolen token is worth without ever refusing a legitimate
;; sign-in. `never`/0 disables it; anything unparseable falls back to the
;; default, never to 0 — the platform's rule for every knob.
(define DEFAULT-MAX-SESSIONS 10)
(define (max-sessions)
  (define raw (tmach-env "MAX_SESSIONS"))
  (cond
    [(or (not raw) (string=? raw "")) DEFAULT-MAX-SESSIONS]
    [(member raw '("never" "0" "unlimited")) #f]
    [(let ([n (string->number raw)]) (and (exact-integer? n) (positive? n) n))]
    [else DEFAULT-MAX-SESSIONS]))

;; -> list of evicted session ids (so the caller can audit them)
(define (enforce-session-cap! conn user-id)
  (define cap (max-sessions))
  (cond
    [(not cap) '()]
    [else
     (define rows (query-rows conn
       (string-append "SELECT id FROM api_tokens WHERE user_id = ? AND kind = ? AND status = 'active' "
                      "ORDER BY created_epoch DESC, created_at DESC")
       user-id SESSION-KIND))
     (define extra (if (> (length rows) cap) (list-tail rows cap) '()))
     (for/list ([r (in-list extra)])
       (query-exec conn "UPDATE api_tokens SET status = 'revoked' WHERE id = ?" (vector-ref r 0))
       (vector-ref r 0))]))

;; ---- sign-in attempt throttling (issue #116) --------------------------------
;; A GROWING DELAY expressed as a 429 with a retry-after, not a sleep: a sleep
;; holds a request thread, which is a resource an unauthenticated caller could
;; exhaust on purpose. The counter is a row (migration 0049) because a restart
;; must not clear it and two replicas must not each grant the full allowance —
;; the funnel's in-memory limiter is right for a public funnel and wrong for an
;; account control.
(define LOGIN-WINDOW 900)          ; failures older than this are forgotten
(define LOGIN-FREE-TRIES 3)        ; typos are normal; the fourth starts costing
(define LOGIN-MAX-DELAY 60)
;; A HARD LOCK IS OFF BY DEFAULT, deliberately. A lock only an operator can clear
;; is a denial-of-service primitive against a known username, so it is something
;; an operator opts into — the shape TELEMACHUS_STRICT_STARTUP and the retention
;; rules already use for a one-way door. Unset means "throttle only".
(define (login-lock-after)
  (define raw (tmach-env "LOGIN_LOCK_FAILURES"))
  (and raw (not (string=? raw ""))
       (let ([n (string->number raw)]) (and (exact-integer? n) (positive? n) n))))
(define LOCK-FOREVER (* 100 365 24 3600))   ; "until an operator clears it"

(define (login-delay-for failures)
  (if (<= failures LOGIN-FREE-TRIES)
      0
      (min LOGIN-MAX-DELAY (expt 2 (- failures LOGIN-FREE-TRIES)))))

;; #f to proceed, 'locked, or (cons 'wait seconds)
(define (login-throttle conn username)
  (define now (current-seconds))
  (define row (query-maybe-row conn
    "SELECT failures, last_failure_epoch, locked_until_epoch FROM login_throttle WHERE username = ?"
    username))
  (cond
    [(not row) #f]
    [else
     (define failures (let ([v (vector-ref row 0)]) (if (sql-null? v) 0 v)))
     (define last (let ([v (vector-ref row 1)]) (and (not (sql-null? v)) v)))
     (define locked (let ([v (vector-ref row 2)]) (and (not (sql-null? v)) v)))
     (cond
       [(and locked (> locked now)) 'locked]
       ;; past the window the count is forgotten — an honest person who mistyped
       ;; twice last Tuesday starts clean
       [(or (not last) (< last (- now LOGIN-WINDOW))) #f]
       [else
        (define wait (- (+ last (login-delay-for failures)) now))
        (if (> wait 0) (cons 'wait wait) #f)])]))

(define (login-failed! conn username)
  (define now (current-seconds))
  (define row (query-maybe-row conn
    "SELECT failures, last_failure_epoch FROM login_throttle WHERE username = ?" username))
  (define prior
    (cond [(not row) 0]
          [else (define f (let ([v (vector-ref row 0)]) (if (sql-null? v) 0 v)))
                (define last (let ([v (vector-ref row 1)]) (and (not (sql-null? v)) v)))
                ;; the window applies to the COUNT as well as to the delay, or a
                ;; lock would eventually trip on failures weeks apart
                (if (and last (>= last (- now LOGIN-WINDOW))) f 0)]))
  (define failures (add1 prior))
  (define lock-at (login-lock-after))
  (define locked (and lock-at (>= failures lock-at) (+ now LOCK-FOREVER)))
  (if row
      (query-exec conn
        (string-append "UPDATE login_throttle SET failures = ?, last_failure_epoch = ?, "
                       "locked_until_epoch = ? WHERE username = ?")
        failures now (or locked sql-null) username)
      (query-exec conn
        (string-append "INSERT INTO login_throttle (username, failures, first_failure_epoch, "
                       "last_failure_epoch, locked_until_epoch) VALUES (?, ?, ?, ?, ?)")
        username failures now now (or locked sql-null)))
  (values failures (and locked #t)))

;; a success forgets the history. Also the ONLY thing that does, apart from an
;; operator's password reset — which is the documented way back in for somebody
;; a hard lock has shut out (#54 built that route for exactly this).
(define (login-succeeded! conn username)
  (query-exec conn "DELETE FROM login_throttle WHERE username = ?" username))

(define (login-lock-clear! conn username)
  (query-exec conn "DELETE FROM login_throttle WHERE username = ?" username))

;; bearer token -> principal (capped by scopes), or #f if unknown/inactive.
(define (resolve-token conn bearer)
  (define row (token-row conn bearer))
  (cond
    [(not row) #f]
    ;; the database matched by equality; recheck in constant time so nothing in
    ;; THIS process compares a secret byte by byte with an early exit
    [(not (constant-time=? (vector-ref row 5) (hash-token bearer))) #f]
    [(not (equal? (vector-ref row 3) "active")) #f]
    ;; issue #13: enforced here, at the one place a bearer becomes a principal
    [(token-expired? (vector-ref row 4)) #f]
    [else
     (define user-id (vector-ref row 0))
     (define team-id (vector-ref row 1))
     (define scopes (with-handlers ([exn:fail? (lambda (_) '())])
                      (string->jsexpr (vector-ref row 2))))
     (define urow (query-maybe-row conn
       "SELECT is_operator, org_id, org_role_key FROM users WHERE id = ?" user-id))
     (define op (and urow (vector-ref urow 0)))
     (define org-id (and urow (nz/false (vector-ref urow 1))))
     ;; issue #38: the session clocks, evaluated against the policy in force RIGHT
     ;; NOW rather than against anything frozen into the row at issue time — so
     ;; tightening the policy takes effect on the next request, not on the next
     ;; sign-in. OWASP: server-side invalidation is the mandatory half.
     (define reason
       (session-timeout-reason (session-policy-for conn org-id)
                               (nz/string (vector-ref row 6))
                               (epoch-col (vector-ref row 7))
                               (epoch-col (vector-ref row 8))))
     (cond
       [reason
        ;; revoke, so the next request does not have to recompute the same verdict
        ;; and so `list-tokens` can show an operator why the session ended
        (query-exec conn "UPDATE api_tokens SET status = ? WHERE token_hash = ?"
                    (if (eq? reason 'idle) "expired-idle" "expired-absolute")
                    (vector-ref row 5))
        #f]
       [else
        (query-exec conn
          (string-append "UPDATE api_tokens SET last_used_at = CURRENT_TIMESTAMP, last_used_epoch = ? "
                         "WHERE token_hash = ?")
          (current-seconds) (vector-ref row 5))
        (principal user-id (and (number? op) (not (zero? op))) team-id
                   (if (list? scopes) scopes '())
                   org-id
                   (and urow (nz/false (vector-ref urow 2))))])]))

;; a TEXT column that should hold a word, as a string ("" when NULL)
;; a BIGINT epoch column, as an integer or #f. Postgres hands back an integer and
;; SQLite may hand back a string for the same column, so both are accepted.
(define (epoch-col v)
  (cond [(or (not v) (sql-null? v)) #f]
        [(and (real? v) (integer? v)) (inexact->exact v)]
        [else (let ([n (string->number (format "~a" v))]) (and (exact-integer? n) n))]))

;; ---- resource grants (sharing) ---------------------------------------------
(define (grant! conn #:resource-type rtype #:resource-id rid
                #:principal-type ptype #:principal-id pid #:permission perm #:by [by sql-null]
                ;; epoch seconds, or #f for a grant that never lapses (DSH-3)
                #:expires-at [expires-at #f])
  (query-exec conn
    (string-append "INSERT INTO resource_grants "
                   "(id, resource_type, resource_id, principal_type, principal_id, permission, granted_by, expires_at) "
                   "VALUES (?, ?, ?, ?, ?, ?, ?, ?) "
                   ;; portable upsert (sqlite 3.24+ and postgres both support this):
                   ;; granting again RENEWS — a new expiry and a new grantor replace
                   ;; the old, so re-sharing a lapsed contractor works without a revoke.
                   "ON CONFLICT (resource_type, resource_id, principal_type, principal_id, permission) "
                   "DO UPDATE SET expires_at = excluded.expires_at, granted_by = excluded.granted_by")
    (new-id) rtype rid ptype pid perm by (or expires-at sql-null)))

(define (revoke! conn #:resource-type rtype #:resource-id rid
                 #:principal-type ptype #:principal-id pid #:permission perm)
  (query-exec conn
    (string-append "DELETE FROM resource_grants WHERE resource_type = ? AND resource_id = ? "
                   "AND principal_type = ? AND principal_id = ? AND permission = ?")
    rtype rid ptype pid perm))

;; ---- audit ------------------------------------------------------------------
;; The four trailing keywords are issue #84's (migration 0046) and every one of
;; them DEFAULTS TO ABSENT, so the ~90 existing call sites are unchanged and a
;; pre-0046 entry and a new entry from a path with no client are the same shape.
;; `#f` is accepted as well as `sql-null` because the context those come from
;; carries #f for "no client" (a scheduler job has no address).
(define (audit! conn #:action action
                #:actor-type [actor-type sql-null] #:actor-id [actor-id sql-null]
                #:team-id [team-id sql-null] #:resource-type [resource-type sql-null]
                #:resource-id [resource-id sql-null] #:result [result "ok"] #:meta [meta sql-null]
                #:org-id [org-id sql-null] #:ip [ip sql-null]
                #:user-agent [user-agent sql-null] #:request-id [request-id sql-null])
  (define (orn v) (if (or (not v) (eq? v 'null)) sql-null v))
  (query-exec conn
    (string-append "INSERT INTO audit_log "
                   "(id, actor_type, actor_id, team_id, action, resource_type, resource_id, result, meta, at_us, "
                   "org_id, client_ip, user_agent, request_id) "
                   "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)")
    (new-id) actor-type actor-id team-id action resource-type resource-id result meta (audit-stamp!)
    (orn org-id) (orn ip) (orn user-agent) (orn request-id)))

;; issue #47: the ordering key, and the reason it is not simply a clock reading —
;; a burst of events lands inside one tick whatever the unit, and then the order
;; is back to whatever the storage feels like. Microseconds, never repeating
;; within this process: a later write always sorts after an earlier one, and
;; across processes the wall clock still puts them in the right order.
(define audit-clock (make-semaphore 1))
(define last-audit-us (box 0))
(define (audit-stamp!)
  (call-with-semaphore audit-clock
    (lambda ()
      (define now (inexact->exact (round (* 1000 (current-inexact-milliseconds)))))
      (define prev (unbox last-audit-us))
      (define v (if (> now prev) now (add1 prev)))
      (set-box! last-audit-us v)
      v)))

;; recent audit events for a team (newest first), for the management UI.
(define (audit-list conn team-id #:limit [lim 50] #:offset [off 0])
  (for/list ([r (in-list (query-rows conn
     (string-append "SELECT id, action, actor_type, actor_id, resource_type, resource_id, result, at, "
                    "client_ip, user_agent, request_id "
                    ;; `at` first — it is right for rows written before at_us
                    ;; existed — then the microsecond within that second, then the
                    ;; id so the order is at least stable when neither can say
                    ;; (issue #47)
                    "FROM audit_log WHERE team_id = ? ORDER BY at DESC, at_us DESC, id DESC LIMIT ? OFFSET ?")
     team-id lim off))])
    (hasheq 'id (vector-ref r 0) 'action (vector-ref r 1)
            'actor_type (nz (vector-ref r 2)) 'actor_id (nz (vector-ref r 3))
            'resource_type (nz (vector-ref r 4)) 'resource_id (nz (vector-ref r 5))
            'result (nz (vector-ref r 6)) 'at (vector-ref r 7)
            ;; #84 r2: who, from where. Absent on a pre-0046 entry and on any
            ;; event with no client in front of it — never a guess.
            'client_ip (nz (vector-ref r 8)) 'user_agent (nz (vector-ref r 9))
            'request_id (nz (vector-ref r 10)))))
