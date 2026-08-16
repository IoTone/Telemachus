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
         "../quota/quota.rkt")      ; set-limit!

(provide provision! activate! suspend! resume! team-suspended? plan-quotas
         provisioned-team set-tenant-quota!)

(define tok-salt "telemachus-activation-v0")   ; prototype pepper; swap with the KDF seam
(define (hash-tok t) (sha1 (open-input-string (string-append tok-salt t))))

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
  (query-exec conn "UPDATE activation_tokens SET used_at = CURRENT_TIMESTAMP WHERE user_id = ? AND used_at IS NULL" uid)
  (define raw (random-token))
  ;; store expiry as an epoch-seconds string (portable across sqlite/postgres —
  ;; no dialect-specific datetime() arithmetic).
  (define expires (+ (current-seconds) (* ttl-hours 3600)))
  (query-exec conn
    (string-append "INSERT INTO activation_tokens (id, user_id, token_hash, prefix, expires_at) "
                   "VALUES (?, ?, ?, ?, ?)")
    (new-id) uid (hash-tok raw) (substring raw 0 (min 11 (string-length raw))) (number->string expires))
  raw)

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

(define (expired? conn expires-at)
  (and (not (sql-null? expires-at))
       (let ([e (string->number (format "~a" expires-at))])
         (and e (> (current-seconds) e)))))

;; Claim an activation token: set the owner's password + activate. Returns
;; (values owner-user-id team-id session-token) or #f on bad/used/expired token.
(define (activate! conn #:token raw #:password pw)
  (define row (query-maybe-row conn
    "SELECT id, user_id, used_at, expires_at FROM activation_tokens WHERE token_hash = ?" (hash-tok raw)))
  (cond
    [(not row) #f]
    [(not (sql-null? (vector-ref row 2))) #f]                 ; already used
    [(expired? conn (vector-ref row 3)) #f]
    [else
     (define uid (vector-ref row 1))
     (set-password! conn uid pw)
     (query-exec conn "UPDATE users SET status = 'active', updated_at = CURRENT_TIMESTAMP WHERE id = ?" uid)
     (query-exec conn "UPDATE activation_tokens SET used_at = CURRENT_TIMESTAMP WHERE id = ?" (vector-ref row 0))
     (query-exec conn "UPDATE provisioning SET status = 'activated', updated_at = CURRENT_TIMESTAMP WHERE owner_user_id = ?" uid)
     (define tid (first-team-for conn uid))
     (define-values (tok _t) (issue-token! conn #:user uid #:team tid #:name "login" #:scopes '("*:*")))
     (audit! conn #:action "activate" #:actor-type "user" #:actor-id uid #:team-id tid)
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
