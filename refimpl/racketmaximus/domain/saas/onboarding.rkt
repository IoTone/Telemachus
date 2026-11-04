#lang racket/base

;; domain/saas/onboarding.rkt — hosted tenant provisioning (slice 19).
;;
;; Seed a fresh instance with EXACTLY ONE user (the account owner) in an `invited`
;; state, plus a one-time activation token; the owner claims it to set a password
;; and become `active`. Idempotent per external `provision_id` so retried webhooks
;; never double-seed. Provider actions (provision/suspend/resume) are authorized by
;; the per-instance provision token at the HTTP layer — no operator user is created,
;; so the tenant genuinely has one user. See docs/design/saas-onboarding.md.

(require db-kit/portable
         racket/string
         file/sha1
         "../db/id.rkt"
         "../authz/authz.rkt"       ; create-user!/create-team!/add-member!/seed-builtin-roles!/set-password!/issue-token!/first-team-for/audit!
         "../authz/mailed-tokens.rkt" ; mint-mailed-token!/claim-mailed-token! — the ONE rule for a token we mail
         "../quota/quota.rkt")      ; set-limit!

(provide provision! activate! suspend! resume! team-suspended?
         provisioned-team set-tenant-quota!)

;; ---- how an activation token is stored --------------------------------------
;;
;; IT MOVED. The hashing (#186/SEC-3, with #13's legacy read), the single
;; outstanding slot and the guarded spend are `domain/authz/mailed-tokens.rkt`
;; now, because the password reset is their second asker and a credential rule
;; kept in two places is the one kind of drift nobody sees until it matters.
;; This module is one of the two things that REDEEM such a token; what makes an
;; activation different from a reset is below, in `activate!`.

;; plan → limits applied at provision
(define plan-quotas
  (hash "trial"   (list (cons "ai.tokens.total" 50000)   (cons "ai.requests" 500)   (cons "ai.concurrency" 2))
        "starter" (list (cons "ai.tokens.total" 500000)  (cons "ai.requests" 5000)  (cons "ai.concurrency" 4))
        "pro"     (list (cons "ai.tokens.total" 5000000) (cons "ai.requests" 50000) (cons "ai.concurrency" 8))))

(define (apply-plan! conn team-id plan)
  (for ([kv (in-list (hash-ref plan-quotas plan (hash-ref plan-quotas "trial")))])
    (set-limit! conn "team" team-id (car kv) (cdr kv)
                #:window (if (string=? (car kv) "ai.concurrency") "instant" "day"))))

(define (slugify s)
  (define base (regexp-replace* #rx"[^a-z0-9]+" (string-downcase (format "~a" s)) "-"))
  (define trimmed (regexp-replace* #rx"(^-+|-+$)" base ""))
  (if (string=? trimmed "") "team" trimmed))

(define (mint-activation! conn uid ttl-hours)
  (mint-mailed-token! conn uid ttl-hours #:purpose "activate"))

;; Idempotent seed. Returns (values activation-token owner-user-id team-id state)
;; state: 'seeded (new or token re-issued) | 'active (already claimed → token #f).
(define (provision! conn #:provision-id pid #:owner-email email
                    #:owner-name [name #f] #:org [org #f]
                    #:plan [plan "trial"] #:source [source "signup"] #:ttl-hours [ttl 72])
  (define row (query-maybe-row conn
    "SELECT status, owner_user_id, team_id FROM provisioning WHERE provision_id = ?" pid))
  (cond
    [(and row (equal? (vector-ref row 0) "activated"))
     (values #f (vector-ref row 1) (vector-ref row 2) 'active)]           ; already claimed
    [row
     (define uid (vector-ref row 1))                                       ; still pending → re-issue token
     (values (mint-activation! conn uid ttl) uid (vector-ref row 2) 'seeded)]
    [else
     (seed-builtin-roles! conn)
     (define tid (create-team! conn #:name (or org email) #:slug (slugify (or org email))))
     (define uid (create-user! conn #:username email #:display-name (or name email)))  ; no password
     (query-exec conn "UPDATE users SET status = 'invited' WHERE id = ?" uid)
     (add-member! conn #:user uid #:team tid #:role "owner")
     (apply-plan! conn tid plan)
     (query-exec conn
       (string-append "INSERT INTO provisioning (id, provision_id, source, plan, status, owner_user_id, team_id) "
                      "VALUES (?, ?, ?, ?, 'seeded', ?, ?)")
       (new-id) pid source plan uid tid)
     (audit! conn #:action "provision" #:actor-type "system" #:actor-id "provision" #:team-id tid)
     (values (mint-activation! conn uid ttl) uid tid 'seeded)]))

;; Claim an activation token: set the owner's first password and make the account
;; real. Answers (values user-id team-id session-token-or-#f), or #f when the
;; token is unknown, spent, expired, or a token for some other purpose.
;;
;; THE SESSION IS WITHHELD WHEN THE ACCOUNT HAS A SECOND FACTOR (RESET-2), and
;; that rule is here rather than only in the reset because it costs one condition
;; and removes a whole class permanently. TOTP is enforced in `authenticate`;
;; this path does not go through it, so handing out a `*:*` session on a redeemed
;; link is a second-factor bypass for anybody who can read the mailbox. It is
;; unreachable from an invitation TODAY — nothing can enrol a seed before
;; activation — and "unreachable today" is exactly the kind of argument that
;; stops being true without anybody noticing. With a seed the caller is told the
;; password was set and sends them to sign in, where the code is demanded.
(define (activate! conn #:token raw #:password pw)
  (define uid (claim-mailed-token! conn raw #:purpose "activate"))
  (cond
    [(not uid) #f]
    [else
     (set-password! conn uid pw)
     (query-exec conn "UPDATE users SET status = 'active', updated_at = CURRENT_TIMESTAMP WHERE id = ?" uid)
     (query-exec conn "UPDATE provisioning SET status = 'activated', updated_at = CURRENT_TIMESTAMP WHERE owner_user_id = ?" uid)
     (define tid (first-team-for conn uid))
     (define tok
       (and (not (has-second-factor? conn uid))
            (let-values ([(t _t) (issue-token! conn #:user uid #:team tid
                                               #:name "login" #:scopes '("*:*")
                                               #:kind SESSION-KIND)])
              t)))
     (audit! conn #:action "activate" #:actor-type "user" #:actor-id uid #:team-id tid
             #:resource-type "user" #:resource-id uid)
     (values uid tid tok)]))

;; ---- lifecycle --------------------------------------------------------------
(define (set-tenant! conn pid team-status user-status prov-status action)
  (define row (query-maybe-row conn
    "SELECT owner_user_id, team_id FROM provisioning WHERE provision_id = ?" pid))
  (cond
    [(not row) #f]
    [else
     (define uid (vector-ref row 0)) (define tid (vector-ref row 1))
     (when tid (query-exec conn "UPDATE teams SET status = ? WHERE id = ?" team-status tid))
     (when uid (query-exec conn "UPDATE users SET status = ? WHERE id = ?" user-status uid))
     (query-exec conn "UPDATE provisioning SET status = ?, updated_at = CURRENT_TIMESTAMP WHERE provision_id = ?" prov-status pid)
     (audit! conn #:action action #:actor-type "system" #:actor-id "provision" #:team-id tid)
     #t]))

(define (suspend! conn #:provision-id pid) (set-tenant! conn pid "suspended" "suspended" "suspended" "suspend"))
(define (resume!  conn #:provision-id pid) (set-tenant! conn pid "active"    "active"    "activated"  "resume"))

;; ---- billing lifecycle: adjust a tenant's quota by provision_id (ONB follow-up)
(define (provisioned-team conn provision-id)
  (query-maybe-value conn "SELECT team_id FROM provisioning WHERE provision_id = ?" provision-id))

(define (set-tenant-quota! conn #:provision-id pid #:dimension dim #:limit lim #:window [w "day"])
  (define tid (provisioned-team conn pid))
  (and tid (begin (set-limit! conn "team" tid dim lim #:window w) tid)))

(define (team-suspended? conn team-id)
  (and team-id
       (let ([st (query-maybe-value conn "SELECT status FROM teams WHERE id = ?" team-id)])
         (and (string? st) (string=? st "suspended")))))
