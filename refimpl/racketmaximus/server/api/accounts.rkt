#lang racket/base

;; server/api/accounts.rkt — who the caller is, sign-in, 2FA, passwords and
;; membership stewardship
;;
;; Split out of main.rkt by #110 r3. The shared surface every handler here
;; needs — the pool, the request accessors, with-auth/with-mt, the response
;; constructors — is server/kit.rkt.

(provide ep-whoami ep-profile ep-member-role ep-member-remove
         ep-admin-password-reset ep-members-list ep-add-member
         ep-admin-status ep-login ep-password ep-2fa-reset ep-admin-2fa-reset
         ep-2fa-enable ep-2fa-codes-new ep-2fa-codes-get)

(require db-kit/portable
         json
         web-kit
         (only-in "../../config.rkt" app-version)
         "../../domain/authz/authz.rkt"
         (only-in "../../domain/authz/passwords.rkt" kdf-name)
         (only-in "../../domain/authz/secretbox.rkt" secret-key-id secrets-enabled?)
         "../kit.rkt")

(define (ep-whoami req)
  (define p (current-principal req))
  (if (not p) (unauthorized)
      (json-response (hasheq 'user_id (principal-user-id p)
                             'team_id (principal-team-id p)
                             'is_operator (principal-is-operator p)
                             'org_id (or (principal-org-id p) 'null)
                             'org_slug (let ([o (principal-org-id p)])
                                         (or (and o (query-maybe-value db-conn
                                               "SELECT slug FROM orgs WHERE id = ?" o)) 'null))
                             'org_role (or (principal-org-role p) 'null)
                             'multitenant (multitenant?)
                             'locale (user-locale db-conn (principal-user-id p))
                             'permissions (perms-of p)
                             'token_scopes (or (principal-token-scopes p) 'null)
                             ;; issue #38: the caller's OWN effective session
                             ;; policy, org tightening already applied. The console
                             ;; warns and signs out on these numbers; the server
                             ;; still enforces them independently in resolve-token,
                             ;; because a client-side timer is a courtesy.
                             'session_policy (session-policy-for db-conn (principal-org-id p))))))

;; the user's own language — the durable preference a workflow binds to as
;; ${principal.locale}, as opposed to the per-request Accept-Language header
(define (ep-profile req)
  (with-auth req (lambda (p)
    (define b (read-json-body req))
    (define loc (hash-ref b 'locale #f))
    (cond
      [(not (and (string? loc) (regexp-match #px"^[a-zA-Z]{2,3}([-_][A-Za-z0-9]{2,8})*$" loc)))
       (err "locale required, e.g. \"es\" or \"es-419\"" 400)]
      [else
       (set-user-locale! db-conn (principal-user-id p) loc)
       (json-response (hasheq 'ok #t 'locale loc))]))))

;; ---- membership stewardship (issue #54) ----------------------------------------
(define (ep-member-role req uid)
  (with-auth req (lambda (p)
    (require-perm db-conn p "members:manage")
    (define role (fmt (read-json-body req) 'role))
    (define out (set-member-role! db-conn (principal-team-id p) uid role))
    (cond
      [(eq? out 'no-such-member) (err "no such member" 404)]
      [(eq? out 'unknown-role) (err "unknown role" 400)]
      [(eq? out 'last-owner) (err "the last owner cannot be demoted" 409)]
      [else
       (audit! db-conn #:action "member.role" #:actor-type "user" #:actor-id (principal-user-id p)
               #:team-id (principal-team-id p) #:resource-type "user" #:resource-id uid
               #:meta (jsexpr->string (hasheq 'role role)))
       (json-response (hasheq 'ok #t 'user_id uid 'role role))]))))

(define (ep-member-remove req uid)
  (with-auth req (lambda (p)
    (require-perm db-conn p "members:manage")
    (define out (deactivate-member! db-conn (principal-team-id p) uid))
    (cond
      [(eq? out 'no-such-member) (err "no such member" 404)]
      [(eq? out 'last-owner) (err "the last owner cannot be removed" 409)]
      [else
       (audit! db-conn #:action "member.remove" #:actor-type "user" #:actor-id (principal-user-id p)
               #:team-id (principal-team-id p) #:resource-type "user" #:resource-id uid
               #:meta (jsexpr->string (hasheq 'tokens_revoked out)))
       (json-response (hasheq 'ok #t 'user_id uid 'tokens_revoked out))]))))

(define (ep-admin-password-reset req uid)
  (with-auth req (lambda (p)
    (require-perm db-conn p "instance:manage")
    (define new (hash-ref (read-json-body req) 'new_password #f))
    (cond
      [(or (not (string? new)) (< (string-length new) 6)) (err "new_password required (min 6)" 400)]
      [(not (query-maybe-value db-conn "SELECT id FROM users WHERE id = ?" uid)) (err "no such user" 404)]
      [else
       (set-password! db-conn uid new)
       (define n (revoke-user-sessions! db-conn uid))
       ;; attributed to the ACTING operator's team: audit-list filters by team, and
       ;; the operator's trail is where "what did the operator do" is looked for.
       ;; The target may be in another team entirely.
       (audit! db-conn #:action "user.password.reset" #:actor-type "user" #:actor-id (principal-user-id p)
               #:team-id (principal-team-id p)
               #:resource-type "user" #:resource-id uid
               #:meta (jsexpr->string (hasheq 'sessions_revoked n)))
       (json-response (hasheq 'ok #t 'user_id uid 'sessions_revoked n))]))))

(define (ep-members-list req)
  (with-auth req (lambda (p)
    (define rows (query-rows db-conn
      (string-append "SELECT u.id, u.username, m.role_key FROM memberships m "
                     "JOIN users u ON u.id = m.user_id "
                     "WHERE m.team_id = ? AND m.status = 'active' ORDER BY u.username")
      (principal-team-id p)))
    (json-response (hasheq 'members (for/list ([r (in-list rows)])
                                      (hasheq 'user_id (vector-ref r 0)
                                              'username (vector-ref r 1)
                                              'role (vector-ref r 2))))))))

(define (ep-add-member req)
  (define p (current-principal req))
  (cond
    [(not p) (unauthorized)]
    [else
     (require-perm db-conn p "members:manage")           ; → localized 403 on failure
     (define body (read-json-body req))
     (define username (hash-ref body 'username #f))
     (define role (hash-ref body 'role "member"))
     (cond
       [(not username) (err "username required" 400)]
       [else
         (define uid (create-user! db-conn #:username username #:password (hash-ref body 'password #f)))
         (add-member! db-conn #:user uid #:team (principal-team-id p) #:role role)
         (audit! db-conn #:action "member.add" #:actor-type "user" #:actor-id (principal-user-id p)
                #:team-id (principal-team-id p) #:resource-type "user" #:resource-id uid)
         (define-values (tok _t)
          (issue-token! db-conn #:user uid #:team (principal-team-id p) #:scopes '("*:*") #:kind SESSION-KIND))
         (json-response (hasheq 'user_id uid 'role role 'token tok) #:code 201)])]))

(define (ep-admin-status req)
  (define p (current-principal req))
  (cond
    [(not p) (unauthorized)]
    [else
     (require-perm db-conn p "instance:manage")          ; operator-only → localized 403
     (json-response (hasheq 'ok #t
      ;; issue #11: what /health used to say, now behind instance:manage
      'service "telemachus" 'version app-version 'tls (tls-on?) 'kdf (kdf-name)
                            ;; issue #19: is a dump of this database replayable?
                            'secrets (if (secrets-enabled?) "sealed" "plaintext")
                            'secret_key_id (or (secret-key-id) 'null)
                            'multitenant (multitenant?)
                            'users (query-value db-conn "SELECT COUNT(*) FROM users")
                            'teams (query-value db-conn "SELECT COUNT(*) FROM teams")
                            'orgs (query-value db-conn "SELECT COUNT(*) FROM orgs")))]))

(define (ep-login req)
  (define body (read-json-body req))
  (define username (hash-ref body 'username #f))
  (define password (hash-ref body 'password #f))
  (define code (hash-ref body 'code #f))
  (cond
    [(or (not username) (not password)) (err "username and password required" 400)]
    [else
     (define uid (authenticate db-conn username password #:code code))
     (cond
       [(not uid) (unauthorized)]                       ; bad password / missing-or-bad 2FA code
       [else
         (define tid (first-team-for db-conn uid))
         (define-values (tok _t) (issue-token! db-conn #:user uid #:team tid #:name "login" #:scopes '("*:*") #:kind SESSION-KIND))
         (json-response (hasheq 'token tok 'user_id uid 'team_id tid))])]))

(define (ep-password req)
  (with-auth req (lambda (p)
    (define b (read-json-body req))
    (define cur (hash-ref b 'current_password #f))
    (define new (hash-ref b 'new_password #f))
    (cond
      [(or (not cur) (not new)) (err "current_password and new_password required" 400)]
      [(< (string-length new) 6) (err "new password too short (min 6)" 400)]
      [(change-password! db-conn (principal-user-id p) cur new)
       ;; every session the old password could have minted goes, INCLUDING this
       ;; one: the caller signs in again. Issuing a fresh token here instead would
       ;; let a narrowly-scoped API token trade itself for a full session.
       (define n (revoke-user-sessions! db-conn (principal-user-id p)))
       (audit! db-conn #:action "user.password" #:actor-type "user" #:actor-id (principal-user-id p)
               #:team-id (principal-team-id p) #:resource-type "user" #:resource-id (principal-user-id p)
               #:meta (jsexpr->string (hasheq 'sessions_revoked n)))
       (json-response (hasheq 'ok #t 'sessions_revoked n 'signed_out #t))]
      [else (err "current password incorrect" 403)]))))

;; issue #19: a TOTP seed is the one credential its owner cannot rotate by using
;; it. Clearing it is what makes a leaked seed — from a database dump taken before
;; the instance had a secret key, say — a recoverable incident.
(define (ep-2fa-reset req)
  (define p (current-principal req))
  (cond
    [(not p) (unauthorized)]
    [else
     (define had (reset-2fa! db-conn (principal-user-id p)))
     (audit! db-conn #:action "user.2fa.reset" #:actor-type "user" #:actor-id (principal-user-id p)
             #:resource-type "user" #:resource-id (principal-user-id p))
     (json-response (hasheq 'ok #t 'was_enabled had))]))

;; the same, for someone else — an operator act, audited as one
(define (ep-admin-2fa-reset req id)
  (with-auth req (lambda (p)
    (require-perm db-conn p "instance:manage")
    (cond
      [(not (query-maybe-value db-conn "SELECT id FROM users WHERE id = ?" id)) (err "not found" 404)]
      [else
       (define had (reset-2fa! db-conn id))
       (audit! db-conn #:action "user.2fa.reset" #:actor-type "user" #:actor-id (principal-user-id p)
               #:resource-type "user" #:resource-id id)
       (json-response (hasheq 'ok #t 'user_id id 'was_enabled had))]))))

(define (ep-2fa-enable req)
  (define p (current-principal req))
  (cond
    [(not p) (unauthorized)]
    [else
     (define-values (secret uri codes) (enable-2fa! db-conn (principal-user-id p)))
     ;; the codes are shown HERE and never again — enrolling without a way back in
     ;; is how people lock themselves out of their own instance (issue #26)
     (json-response (hasheq 'secret secret 'otpauth_uri uri
                            'recovery_codes codes
                            'note "2FA enabled — future logins for this user require a TOTP code or one recovery code. The codes are shown once; keep them somewhere the authenticator is not."))]))

;; Re-issue: the outstanding set is invalidated and a new one returned once. A set
;; printed on paper should be the whole truth about what opens this account, so
;; this replaces rather than tops up.
(define (ep-2fa-codes-new req)
  (define p (current-principal req))
  (cond
    [(not p) (unauthorized)]
    [else
     (define codes (issue-recovery-codes! db-conn (principal-user-id p)))
     (audit! db-conn #:action "user.2fa.codes" #:actor-type "user" #:actor-id (principal-user-id p)
             #:resource-type "user" #:resource-id (principal-user-id p))
     (json-response (hasheq 'recovery_codes codes 'count (length codes)))]))

;; How many are left — the number worth warning about in a UI. Never the codes.
(define (ep-2fa-codes-get req)
  (define p (current-principal req))
  (cond
    [(not p) (unauthorized)]
    [else (json-response (hasheq 'remaining (recovery-codes-remaining db-conn (principal-user-id p))))]))
