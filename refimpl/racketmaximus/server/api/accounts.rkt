#lang racket/base

;; server/api/accounts.rkt — who the caller is, sign-in, 2FA, passwords and
;; membership stewardship
;;
;; Split out of main.rkt by #110 r3. The shared surface every handler here
;; needs — the pool, the request accessors, with-auth/with-mt, the response
;; constructors — is server/kit.rkt.

(provide ep-whoami ep-profile ep-timezones ep-member-role ep-member-remove
         ep-admin-password-reset ep-members-list ep-add-member
         ep-admin-status ep-login ep-password ep-2fa-reset ep-admin-2fa-reset
         ep-2fa-enable ep-2fa-codes-new ep-2fa-codes-get
         ;; issue #118: a person's own sessions
         ep-sessions-list ep-logout ep-session-revoke ep-sessions-revoke-others
         ;; the self-service way back in, which needed a mail transport to exist
         ep-password-reset-request ep-password-reset-confirm
         ;; onboarding by address, which is what a transport makes possible
         ep-member-resend-invite)

(require db-kit/portable
         json
         web-kit
         (only-in "../../config.rkt" app-version app-build)
         "../../domain/authz/authz.rkt"
         (only-in "../startup.rkt" strict-startup? well-known-secret-key?)
         (only-in "../../domain/authz/passwords.rkt" kdf-name)
         (only-in "../../domain/beta/antispam.rkt" make-limiter limiter-allow?)
         "../../domain/accounts/reset.rkt"
         "../../domain/accounts/invite.rkt"
         racket/string
         web-server/http
         (only-in "../../domain/authz/secretbox.rkt" secret-key-id secrets-enabled?)
         ;; #137: whose clock applies, and what it reads right now
         (only-in "../../domain/time/tz-policy.rkt" set-user-timezone! timezone-problem timezone-report)
         (only-in "../../domain/time/zones.rkt" available-zones)
         ;; #179: the facts an operator needs to answer "is this instance
         ;; healthy" that nothing exposed anywhere — the dialect, whether the
         ;; schema is fully migrated, which blob store is active, and how long a
         ;; stop will take. Each already exists; none was readable over HTTP.
         (only-in "../../domain/db/migrations.rkt" all-migrations)
         (only-in db-kit/migrate applied-migrations pending-migrations migration-id)
         (only-in "../../domain/repo/blobs.rkt" active-blob-store-name)
         (only-in "../../domain/sched/scheduler.rkt" drain-seconds)
         ;; #183: can in-product help answer, and in which languages
         (only-in "../../domain/help/helpsearch.rkt" help-available?)
         (only-in "../../domain/help/helpstore.rkt" help-locales)
         (only-in "../../domain/ai/executor.rkt" embed-configured?)
         "../admission.rkt"
         "../kit.rkt")

(define (ep-whoami req)
  (define p (current-principal req))
  (if (not p) (unauthorized)
      (json-response (hasheq 'user_id (principal-user-id p)
                             ;; Which build is this? Nothing in the UI said, and
                             ;; two instances a day apart are identical on
                             ;; screen. It rides here rather than on a route of
                             ;; its own because the console already fetches
                             ;; whoami on every render pass, and because #11's
                             ;; rule stands: a version is for someone who has
                             ;; signed in, never for a public front door.
                             'build (app-build)
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
                             'session_policy (session-policy-for db-conn (principal-org-id p))
                             ;; The effective zone AND which layer answered it:
                             ;; "why is this showing me Tokyo" should not need
                             ;; three documents diffed by hand.
                             'timezone (timezone-report db-conn #:user (principal-user-id p)
                                                        #:org (principal-org-id p))
                             ;; #183: whether in-product help can answer at all,
                             ;; and if not WHICH half is missing. It rides here
                             ;; for the same reason `build` does — the console
                             ;; already fetches whoami on every render pass, so a
                             ;; panel that cannot work is hidden without a fourth
                             ;; sequential request. `help-any?` is an existence
                             ;; test, not a count: a COUNT(*) over the corpus for
                             ;; a boolean would be a scan on every pass.
                             'help (hasheq 'reason (or (help-available? db-conn (embed-configured?)
                                                                        (request-locale req))
                                                       'null)
                                           'locales (help-locales db-conn))))))

;; The user's own language and their own TIMEZONE — the durable preferences a
;; workflow binds to as ${principal.locale} / ${principal.timezone}, as opposed
;; to a per-request Accept-Language header. #137 added the second, and either
;; field may be sent alone: a body carrying only a timezone must not be refused
;; for lacking a locale the caller never meant to change.
(define (ep-profile req)
  (with-auth req (lambda (p)
    (define b (read-json-body req))
    (define loc (hash-ref b 'locale #f))
    (define tz (hash-ref b 'timezone #f))
    (define loc-bad?
      (and loc (not (and (string? loc)
                         (regexp-match #px"^[a-zA-Z]{2,3}([-_][A-Za-z0-9]{2,8})*$" loc)))))
    (define tz-problem (and tz (timezone-problem (format "~a" tz))))
    (cond
      [(and (not loc) (not tz)) (err "locale or timezone required" 400)]
      [loc-bad? (err "locale required, e.g. \"es\" or \"es-419\"" 400)]
      ;; An unknown zone is REFUSED, never silently substituted: somebody given
      ;; UTC for a typo finds out from a report that arrives at the wrong hour.
      [tz-problem (err tz-problem 400)]
      [else
       (when loc (set-user-locale! db-conn (principal-user-id p) loc))
       (when tz (set-user-timezone! db-conn (principal-user-id p) (format "~a" tz)))
       (json-response (hasheq 'ok #t
                              'locale (or loc (user-locale db-conn (principal-user-id p)))
                              'timezone (timezone-report db-conn #:user (principal-user-id p)
                                                         #:org (principal-org-id p))))]))))

;; The zones this instance has data for, DERIVED FROM DISK. A client cannot
;; offer a picker without it, and hardcoding the list in a console would drift
;; from the tzdata the server actually reads — the same argument that keeps
;; `available` locales out of the source.
(define (ep-timezones req)
  (with-auth req (lambda (p)
    (json-response (hasheq 'timezones (available-zones))))))

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
       ;; issue #116: this is the documented way back in for somebody a hard lock
       ;; has shut out (#54 built the route for exactly that), so it is also the
       ;; one thing besides a successful sign-in that clears the attempt counter.
       ;; Without this a locked account would have no recovery path at all: the
       ;; lock refuses the sign-in that would otherwise clear it.
       (let ([u (query-maybe-value db-conn "SELECT username FROM users WHERE id = ?" uid)])
         (when (string? u) (login-lock-clear! db-conn u)))
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
      (string-append "SELECT u.id, u.username, m.role_key, u.email, u.email_verified_epoch "
                     "FROM memberships m JOIN users u ON u.id = m.user_id "
                     "WHERE m.team_id = ? AND m.status = 'active' ORDER BY u.username")
      (principal-team-id p)))
    ;; The address is NOT in the reply — a list of a team is not a mailing list —
    ;; but whether one exists and whether it is proven is, because an account
    ;; with no proven address cannot receive a recovery link and the administrator
    ;; staring at it needs to know that instead of guessing.
    (json-response (hasheq 'members (for/list ([r (in-list rows)])
                                      (hasheq 'user_id (vector-ref r 0)
                                              'username (vector-ref r 1)
                                              'role (vector-ref r 2)
                                              'has_email (not (sql-null? (vector-ref r 3)))
                                              'email_verified (not (sql-null? (vector-ref r 4))))))))))


;; THE INVITATION ANSWERS WITH NO TOKEN (INVITE-1). The username form hands the
;; CALLER a `*:*` session for somebody else's account, which is fine for a script
;; and is not how a person is onboarded: the invitee proves the mailbox and
;; chooses their own password. The one exception is an instance that cannot send
;; mail, where the link comes back so it can be handed over — `provision!`'s
;; precedent, and the alternative is an invitation nobody can act on.
(define (invite-branch p email username role)
  (define team (principal-team-id p))
  (define addr (format "~a" email))
  (define uname (if (and username (not (equal? (format "~a" username) ""))) (format "~a" username) addr))
  (cond
    [(invite-problem addr) => (lambda (m) (err m 400))]
    ;; Usernames are instance-global (TEN-2b), so the check is not team-scoped —
    ;; and the same 409 the username form answers, because #123 established that
    ;; a duplicate must not reach the INSERT and become a 500 carrying the SQL.
    [(query-maybe-value db-conn "SELECT id FROM users WHERE username = ?" uname)
     (err "username already exists on this instance" 409)]
    [else
     (define res (call-with-values
                  (lambda ()
                    (invite-member! db-conn #:team team #:role role #:address addr
                                    #:username username
                                    #:inviter (principal-user-id p)))
                  list))
     (define uid (car res))
     (define outcome (cadr res))
     (define link (caddr res))
     ;; The reply is the DOMAIN's (`invite-answer`), so the team plane and the
     ;; company plane cannot come to describe the same invitation differently.
     (json-response (invite-answer uid uname role #f outcome link) #:code 201)]))

;; Send it again (INVITE-6). Without it an expired invitation leaves somebody
;; unreachable except through an operator's password reset, and re-posting the
;; invitation is a 409 because the username now exists.
(define (ep-member-resend-invite req id)
  (define p (current-principal req))
  (cond
    [(not p) (unauthorized)]
    [else
     (require-perm db-conn p "members:manage")
     (define res (call-with-values
                  (lambda ()
                    (resend-invitation! db-conn (format "~a" id)
                                        #:inviter (principal-user-id p)))
                  list))
     (cond
       [(equal? res '(#f)) (err "no such member" 404)]
       [(equal? res '(not-invited))
        ;; A REFUSAL RATHER THAN A CONVENIENCE: on an active account this would
        ;; mint a link that sets a password, which is a password reset — and that
        ;; has its own route, its own throttle, its own shorter horizon and an
        ;; enumeration-safe answer. Offering it here would be a second way to do
        ;; it with none of those.
        (err "that member has already accepted — a password reset is the other route" 409)]
       [(equal? res '(no-address)) (err "that invitation has no address to send to" 409)]
       [else
        (json-response (hasheq 'ok #t
                               'queued (eq? (car res) 'queued)
                               'activation_token (or (cadr res) 'null)))])]))

(define (ep-add-member req)
  (define p (current-principal req))
  (cond
    [(not p) (unauthorized)]
    [else
     (require-perm db-conn p "members:manage")           ; → localized 403 on failure
     (define body (read-json-body req))
     (define username (hash-ref body 'username #f))
     (define email (hash-ref body 'email #f))
     (define role (hash-ref body 'role "member"))
     (cond
       ;; AN `email` ASKS FOR AN INVITATION; its absence is today's behaviour,
       ;; byte for byte. Every fixture, smoke block and demo in this tree creates
       ;; members by username and is answered with a token, and a flag day for
       ;; them buys nothing — so the two forms live side by side and the branch
       ;; is one field.
       [email (invite-branch p email username role)]
       [(not username) (err "username or email required" 400)]
       ;; #123: this went straight to `create-user!`, so a username that exists
       ;; raised the UNIQUE violation and the dispatcher turned it into a 500
       ;; carrying the INSERT. `POST /api/org/members` has always checked first
       ;; and answered 409 — the same string and code, so the two planes agree.
       ;; Usernames are instance-global (TEN-2b), which is why the check is not
       ;; scoped to a team.
       [(query-maybe-value db-conn "SELECT id FROM users WHERE username = ?" (format "~a" username))
        (err "username already exists on this instance" 409)]
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
     ;; #124: `instance:read`. A monitoring credential needs the version, the KDF
     ;; and the TLS state; it does not need to be able to reset a password, which
     ;; `instance:manage` also permits. `instance:manage` implies this one, so an
     ;; operator keeps the route.
     (require-perm db-conn p "instance:read")            ; → localized 403
     (json-response (hasheq 'ok #t
      ;; issue #11: what /health used to say, now behind instance:read
      'service "telemachus" 'version app-version 'build (app-build)
                            'tls (tls-on?) 'kdf (kdf-name)
                            ;; issue #19: is a dump of this database replayable?
                            'secrets (if (secrets-enabled?) "sealed" "plaintext")
                            'secret_key_id (or (secret-key-id) 'null)
                            ;; Three posture facts that existed only in the boot
                            ;; log, where nobody reading a dashboard sees them.
                            ;; `token_pepper` is "default" while tokens and
                            ;; recovery codes are hashed with the published
                            ;; development pepper; `secret_key` is "well-known"
                            ;; for the all-zeros evaluation key, under which
                            ;; `secrets: sealed` protects nothing.
                            'token_pepper (if (token-pepper-is-default?) "default" "configured")
                            'secret_key (cond [(not (secrets-enabled?)) "none"]
                                              [(well-known-secret-key?) "well-known"]
                                              [else "configured"])
                            'strict_startup (strict-startup?)
                            'multitenant (multitenant?)
                            ;; #179. Five facts that existed only in the boot log
                            ;; or in a Racket function nothing served, and that
                            ;; an operator asked "is it slow?" needs first.
                            ;;
                            ;; `dialect` because half this file's own traps are
                            ;; dialect-dependent and "which engine is this"
                            ;; was not answerable without the DATABASE_URL.
                            ;;
                            ;; The schema is reported as counts PLUS the pending
                            ;; ids: migration runs at boot, so a pending one
                            ;; means one FAILED, and the id is the only part of
                            ;; that an operator can act on. A plugin's id (`x.`)
                            ;; is included in `applied` and excluded from
                            ;; nothing — unlike `schema-problem`, which must
                            ;; ignore them to decide whether to boot, this is a
                            ;; report and a reader wants to see them.
                            ;;
                            ;; `blob_store` carries the NAME and deliberately no
                            ;; probe result. `blob-store-probe` writes, reads and
                            ;; deletes a blob, so running it per status read is a
                            ;; PUT/GET/DELETE against somebody's bucket on every
                            ;; dashboard refresh — and this route is
                            ;; `instance:read`, which must not perform a write.
                            ;; The honest signal already exists and is stronger:
                            ;; startup refuses to serve on a failed probe, so an
                            ;; instance that is ANSWERING has already proven its
                            ;; store once. A field claiming that here would be a
                            ;; claim about main.rkt made from another module, so
                            ;; the console says it in prose instead.
                            'dialect (format "~a" (db-dialect db-conn))
                            'schema (let* ([known all-migrations]      ; a LIST, not a thunk
                                           [pending (map migration-id
                                                         (pending-migrations db-conn known))])
                                      (hasheq 'known (length known)
                                              'applied (length (applied-migrations db-conn))
                                              'pending pending))
                            'blob_store (hasheq 'name (format "~a" (active-blob-store-name)))
                            ;; How long a stop takes, which is what an operator
                            ;; about to restart wants. The server's own drain
                            ;; LATCH is deliberately not reported: it lives for
                            ;; at most this many seconds and the process exits
                            ;; immediately after, so a field for it would be
                            ;; blank in every reading anybody ever takes. A
                            ;; HOST's drain is a different thing and is on the
                            ;; Workers card already (FLEET-3).
                            'drain_seconds (drain-seconds)
                            'users (query-value db-conn "SELECT COUNT(*) FROM users")
                            'teams (query-value db-conn "SELECT COUNT(*) FROM teams")
                            'orgs (query-value db-conn "SELECT COUNT(*) FROM orgs")))]))

;; ---- sign-in (issues #116, #117, #118) --------------------------------------
;; What this handler did NOT do before: limit attempts, and leave any record at
;; all — not of a failure and not of a SUCCESS, which is the more serious half.
;; The audit log is this platform's record of who did what (DEL-7 keeps it
;; through an erasure, #84 r3 chains and exports it) and "who signed in, from
;; where" was absent from it entirely.
;; SEC-13: MOVED to `server/admission.rkt`, which is where the throttle that
;; needs it now lives and is required by both askers. One definition, because
;; "which header do we believe about who is calling" is a question two copies
;; must never answer differently.

;; The per-ADDRESS limiter is in memory and per process, deliberately, and the
;; per-ACCOUNT one (a row, migration 0049) is not. An address is a throttle: a
;; restart clearing it costs nothing and an attacker changing address defeats it
;; anyway. An account lock is a control, so it has to survive a restart the
;; attacker can cause, and must not grant each replica its own allowance.
(define login-ip-limiter (make-limiter))
(define LOGIN-IP-MAX 20)
(define LOGIN-IP-WINDOW 60)

;; `username` is recorded on a failure because an operator investigating a
;; credential-stuffing run needs to know WHICH accounts were targeted, and it is
;; the one field the caller supplied. Nothing else from the attempt is: never the
;; password, never the body — #83 r4 sealed four stored `error` columns precisely
;; because this platform's own code quotes what it choked on, and a login record
;; is the last place to start a new copy of a credential.
(define (audit-login! #:result result #:username u #:uid [uid #f] #:team [team #f] #:ip ip
                      #:meta [extra (hasheq)])
  (audit! db-conn #:action "user.login" #:actor-type "user"
          #:actor-id (or uid sql-null)
          #:team-id (or team sql-null)
          #:result result
          #:meta (jsexpr->string (hash-set* extra 'username (format "~a" u) 'ip ip))))

;; ---- "I cannot sign in" -----------------------------------------------------
;;
;; TWO LIMITERS, AND NEITHER IS THE LOGIN'S (RESET-12). They are separate because
;; what they protect is different: this endpoint makes THIS INSTANCE SEND MAIL to
;; an address a stranger typed, so it is an amplification primitive aimed at a
;; third party's mailbox as well as a guessing surface. The login's allowance of
;; 20 a minute is far too generous for that.
;;
;; THE PER-ADDRESS ONE IS WHAT STOPS SOMEBODY BEING MAILBOMBED by repeated
;; requests for an address that is not theirs, and the per-source one bounds a
;; run across many addresses. Both in memory, for the reason the login's own note
;; gives: a restart clearing a throttle costs nothing and an attacker changes
;; address anyway. Neither is a control, so neither needs a row.
;;
;; The numbers are deliberately small. A real person asks once, reads their mail,
;; and asks again only if it did not arrive.
(define reset-ip-limiter (make-limiter))
(define reset-addr-limiter (make-limiter))
(define RESET-IP-MAX 5)
(define RESET-ADDR-MAX 3)
(define RESET-WINDOW 900)

;; ONE ANSWER, WHATEVER HAPPENED (RESET-8). `request-password-reset!` reports the
;; truth — queued, no transport, or no such account — and this is where it is
;; flattened, which is `mail-send-test!`'s split: the domain says what occurred so
;; a test and the audit log can assert on it, and the route says the same thing
;; either way so a stranger cannot ask whether an address has an account. #117
;; closed a 168-millisecond timing oracle on that exact question one route along;
;; answering it in words here would be worse, because it needs no measurement.
;;
;; THE THROTTLE IS THE ONE THING THAT ANSWERS DIFFERENTLY, and it has to: a 429
;; tells the caller to wait rather than silently dropping a request a real person
;; is waiting on. It says nothing about the address, because it is reached before
;; the address is looked up at all.
;;
;; THE WORDING IS THE MITIGATION for what the flattening costs — a person who
;; mistypes their address is told the same as one who did not, so the message is
;; conditional ("if that address has an account") rather than a claim that
;; something was sent.
(define (ep-password-reset-request req)
  (define body (read-json-body req))
  (define address (hash-ref body 'address #f))
  (define ip (client-ip-of req))
  (define now (current-seconds))
  (define (same-answer)
    (json-response (hasheq 'ok #t
                           'message "if that address has an account, a reset link is on its way")))
  (cond
    [(not address) (err "address required" 400)]
    [(not (limiter-allow? reset-ip-limiter ip now #:max RESET-IP-MAX #:window RESET-WINDOW))
     (err "too many reset requests from this address — wait a few minutes" 429)]
    [(not (limiter-allow? reset-addr-limiter (string-downcase (format "~a" address)) now
                          #:max RESET-ADDR-MAX #:window RESET-WINDOW))
     ;; Deliberately the SAME refusal as the per-source one. Two distinguishable
     ;; 429s would turn the throttle itself into the oracle the body refuses to
     ;; be: "you are being limited on this ADDRESS" says the address is known.
     (err "too many reset requests from this address — wait a few minutes" 429)]
    [else
     (define outcome (request-password-reset! db-conn (format "~a" address)))
     ;; Recorded on the instance's own trail whatever happened, because "somebody
     ;; asked and nothing was sent" is the case an operator is asked about — and
     ;; it is the one place the outcome is kept, since the caller is not told.
     ;; The ADDRESS is not in the meta: it is a string a stranger supplied, and
     ;; the audit log is chained, exported and kept through an erasure.
     (audit! db-conn #:action "user.password.reset.asked" #:actor-type "system"
             #:actor-id "password-reset" #:result (format "~a" outcome)
             #:meta (jsexpr->string (hasheq 'ip ip)))
     (same-answer)]))

;; Redeeming is public and carries no bearer, and it cannot be otherwise: the
;; person asking is by definition one who cannot sign in. That is the whole
;; difference from MAIL-19's verification, which IS authenticated because the
;; caller there already holds a session.
;;
;; THE SESSION MAY BE WITHHELD, and the body says which. With a second factor
;; enrolled no token is issued — TOTP is enforced in `authenticate` and this path
;; does not go through it — so `signed_in` is false and the console sends the
;; person to sign in, where the code is demanded.
(define (ep-password-reset-confirm req)
  (define body (read-json-body req))
  (define tok (hash-ref body 'token #f))
  (define pw (hash-ref body 'password #f))
  (cond
    ;; SEC-13, and it is FIRST on purpose: the point is that no keyed hash and no
    ;; query happen for a caller over the bound, so a clause that validated the
    ;; body first would leave the cheap half free.
    [(redeem-throttled? (client-ip-of req))
     (err "too many attempts from this address — wait a few minutes" 429)]
    [(not tok) (err "token required" 400)]
    [(reset-password-problem (and (string? pw) pw)) => (lambda (p) (err p 400))]
    [else
     (define res (call-with-values
                  (lambda () (reset-password! db-conn #:token (format "~a" tok) #:password pw))
                  list))
     (if (equal? res '(#f))
         ;; ONE REFUSAL FOR EVERY WAY IT CAN FAIL — unknown, spent, expired,
         ;; minted for another purpose, or an account suspended since it was
         ;; asked for. Distinguishing them tells whoever holds a stale link
         ;; something about the account it belongs to.
         (err "this reset link is no longer valid — ask for a new one" 400)
         (json-response (hasheq 'ok #t
                                'token (or (caddr res) 'null)
                                'signed_in (and (caddr res) #t)
                                'sessions_revoked (cadr res))))]))

(define (ep-login req)
  (define body (read-json-body req))
  (define username (hash-ref body 'username #f))
  (define password (hash-ref body 'password #f))
  (define code (hash-ref body 'code #f))
  (define ip (client-ip-of req))
  (cond
    [(or (not username) (not password)) (err "username and password required" 400)]
    ;; the address throttle comes FIRST and is not per-account, so a run against
    ;; a thousand usernames from one host is bounded by something
    [(not (limiter-allow? login-ip-limiter ip (current-seconds)
                          #:max LOGIN-IP-MAX #:window LOGIN-IP-WINDOW))
     (audit-login! #:result "throttled" #:username username #:ip ip)
     (err "too many sign-in attempts from this address — wait a minute and try again" 429)]
    [else
     (define u (format "~a" username))
     (define hold (login-throttle db-conn u))
     (cond
       ;; A LOCK, which only an operator's password reset clears (#54 built that
       ;; route as the way back in). Off unless TELEMACHUS_LOGIN_LOCK_FAILURES is
       ;; set, because a lock on a known username is a denial-of-service
       ;; primitive — see `login-lock-after`.
       [(eq? hold 'locked)
        (audit-login! #:result "locked" #:username username #:ip ip)
        (err "this account is locked after repeated failed sign-ins — ask an operator to reset it" 423)]
       ;; the growing delay, as a 429 with a retry-after rather than a sleep: a
       ;; sleep holds a request thread, which is a resource an unauthenticated
       ;; caller could exhaust on purpose
       [(pair? hold)
        (audit-login! #:result "throttled" #:username username #:ip ip
                      #:meta (hasheq 'retry_after (cdr hold)))
        (json-response (hasheq 'error "too many failed sign-ins — try again shortly"
                               'retry_after (cdr hold))
                       #:code 429
                       #:headers (list (make-header #"Retry-After"
                                                    (string->bytes/utf-8 (number->string (cdr hold))))))]
       [else
        (define uid (authenticate db-conn u password #:code code))
        (cond
          [(not uid)
           ;; bad password, unknown account, or a missing/bad second factor — one
           ;; answer for all three, as before. The RECORD distinguishes nothing
           ;; either: telling the log which of the three it was would hand an
           ;; attacker who can read it the account-existence oracle #117 closed.
           (define-values (failures locked?) (login-failed! db-conn u))
           (audit-login! #:result "failed" #:username username #:ip ip
                         #:meta (hasheq 'failures failures))
           (when locked?
             (audit-login! #:result "locked" #:username username #:ip ip
                           #:meta (hasheq 'failures failures)))
           (unauthorized)]
          [else
           (login-succeeded! db-conn u)
           (define tid (first-team-for db-conn uid))
           (define-values (tok _t)
             (issue-token! db-conn #:user uid #:team tid #:name "login" #:scopes '("*:*") #:kind SESSION-KIND))
           ;; #118: the cap EVICTS THE OLDEST rather than refusing this sign-in,
           ;; and each eviction is audited — a session that ends by itself with no
           ;; record is indistinguishable, to its owner, from one that was stolen.
           (for ([ev (in-list (enforce-session-cap! db-conn uid))])
             (audit! db-conn #:action "user.session.evicted" #:actor-type "system"
                     #:actor-id uid #:team-id tid #:resource-type "token" #:resource-id ev
                     #:meta (jsexpr->string (hasheq 'reason "session cap" 'cap (max-sessions)))))
           (audit-login! #:result "ok" #:username username #:uid uid #:team tid #:ip ip)
           (json-response (hasheq 'token tok 'user_id uid 'team_id tid))])])]))

;; ---- the caller's own sessions (#118) ---------------------------------------
;; A member could not see or end a single one of their own sessions: GET
;; /api/tokens is the TEAM's API tokens behind settings:manage, and there was no
;; logout route at all — the console's sign-out cleared localStorage and called
;; nothing, so on a shared machine the bearer and the row both stayed valid.
;;
;; These need no permission: they are the caller's own rows, scoped by user_id
;; AND kind in the statement itself.
(define (bearer-of req)
  (define auth (req-header req #"authorization"))
  (and auth (string-prefix? auth "Bearer ") (substring auth 7)))

(define (ep-sessions-list req)
  (with-auth req (lambda (p)
    (define cur (token-id-for-bearer db-conn (bearer-of req)))
    (json-response (hasheq 'sessions (user-sessions db-conn (principal-user-id p) #:current cur)
                           'max (or (max-sessions) 'null))))))

;; ends THIS session — what the console's sign-out button should always have done
(define (ep-logout req)
  (with-auth req (lambda (p)
    (define cur (token-id-for-bearer db-conn (bearer-of req)))
    (cond
      ;; a caller authenticated by the trusted identity HEADERS holds no token,
      ;; so there is nothing to revoke and saying "ok" would be a lie
      [(not cur) (err "no session to end — this request carries no bearer token" 400)]
      [else
       (revoke-session! db-conn (principal-user-id p) cur)
       (audit! db-conn #:action "user.logout" #:actor-type "user" #:actor-id (principal-user-id p)
               #:team-id (principal-team-id p) #:resource-type "token" #:resource-id cur)
       (json-response (hasheq 'ok #t))]))))

(define (ep-session-revoke req id)
  (with-auth req (lambda (p)
    (cond
      [(revoke-session! db-conn (principal-user-id p) id)
       (audit! db-conn #:action "user.session.revoke" #:actor-type "user" #:actor-id (principal-user-id p)
               #:team-id (principal-team-id p) #:resource-type "token" #:resource-id id)
       (json-response (hasheq 'ok #t 'id id))]
      ;; a session that is not the caller's own and one that does not exist are
      ;; ONE answer: whether somebody else holds a given token id is not a
      ;; question this route should answer
      [else (err "not found" 404)]))))

;; "sign out everywhere else" — deliberately NOT everywhere. A password change
;; already ends every session including this one, and making the ordinary button
;; do that would be a surprise on a shared account.
(define (ep-sessions-revoke-others req)
  (with-auth req (lambda (p)
    (define cur (token-id-for-bearer db-conn (bearer-of req)))
    (define n (revoke-other-sessions! db-conn (principal-user-id p) cur))
    (audit! db-conn #:action "user.sessions.revoke_others" #:actor-type "user"
            #:actor-id (principal-user-id p) #:team-id (principal-team-id p)
            #:meta (jsexpr->string (hasheq 'ended n)))
    (json-response (hasheq 'ok #t 'ended n)))))

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
