#lang racket/base

;; domain/orgs/orgs.rkt — organizations: the tenancy layer ABOVE teams (slice 45).
;;
;; One instance, many companies. An org owns teams; a team owns resources. The
;; isolation itself lives in `authz.rkt` (the org gate in `can?`); this module is
;; the *management surface* — create/list/suspend a company, run its teams and
;; people, and nest its quota above the team quotas.
;;
;; Tiers (docs/design/multi-tenancy.md):
;;   superadmin  instance:*  — the whole instance, all orgs
;;   org admin   org:*       — exactly one company; MANAGES but does not READ (TEN-2a)
;;   team roles              — unchanged
;;
;; The org row always exists, even single-tenant (exactly one). The feature flag
;; switches surface area, not semantics — there is no second code path.

(require db-kit/portable
         racket/string
         "../db/id.rkt"
         "../authz/authz.rkt"
         "../quota/quota.rkt")

(provide org-slugify
         org-create! org-list org-get org-get-by-slug
         org-set-status! org-suspended? tenant-read-only?
         org-teams org-members org-audit org-add-team! org-attach-member!
         org-usage set-org-limit! org-quota
         tenant-quota-check tenant-quota-record!
         org-plan-quotas)

;; ---- helpers ----------------------------------------------------------------
(define (nz x) (if (sql-null? x) 'null x))

(define (org-slugify s)
  (define base (regexp-replace* #rx"[^a-z0-9]+" (string-downcase (format "~a" s)) "-"))
  (define trimmed (regexp-replace* #rx"(^-+|-+$)" base ""))
  (if (string=? trimmed "") "org" trimmed))

;; a slug free across orgs (companies are named by humans; collisions happen)
(define (unique-org-slug conn wanted)
  (let loop ([n 0])
    (define cand (if (zero? n) wanted (format "~a-~a" wanted n)))
    (if (query-maybe-value conn "SELECT id FROM orgs WHERE slug = ?" cand)
        (loop (add1 n))
        cand)))

;; what a company gets when the superadmin provisions it. Mirrors the hosted
;; plan table (saas/onboarding.rkt) but applied to the ORG subject, so it is a
;; cap the company then divides across its teams.
(define org-plan-quotas
  (hash "trial"      (list (cons "ai.tokens.total" 100000)   (cons "ai.requests" 1000)   (cons "ai.concurrency" 2))
        "starter"    (list (cons "ai.tokens.total" 1000000)  (cons "ai.requests" 10000)  (cons "ai.concurrency" 4))
        "pro"        (list (cons "ai.tokens.total" 10000000) (cons "ai.requests" 100000) (cons "ai.concurrency" 8))
        "enterprise" (list (cons "ai.tokens.total" 99000000) (cons "ai.requests" 990000) (cons "ai.concurrency" 16))))

(define (apply-org-plan! conn org-id plan)
  (for ([kv (in-list (hash-ref org-plan-quotas plan (hash-ref org-plan-quotas "trial")))])
    (set-limit! conn "org" org-id (car kv) (cdr kv)
                #:window (if (string=? (car kv) "ai.concurrency") "instant" "day"))))

;; ---- provisioning a company -------------------------------------------------
;; Creates the org, its first team, and its org_owner — the company's own
;; administrator, who is NOT an instance operator. Returns a hash with the ids and
;; a login token for the owner (shown once).
(define (org-create! conn actor
                     #:name name #:slug [slug #f] #:plan [plan "trial"]
                     #:owner-username owner-username #:owner-password [owner-pw #f]
                     #:owner-name [owner-name #f]
                     #:team-name [team-name "General"] #:team-slug [team-slug "general"])
  (define oslug (unique-org-slug conn (org-slugify (or slug name))))
  (define oid (create-org! conn #:name name #:slug oslug #:plan plan))
  (apply-org-plan! conn oid plan)
  (define tid (create-team! conn #:name team-name #:slug team-slug #:org oid))
  (default-policy! conn tid)                       ; a starter team budget inside the org cap
  (define uid (create-user! conn #:username owner-username
                            #:display-name (or owner-name owner-username)
                            #:password owner-pw
                            #:org oid #:org-role "org_owner"))
  (add-member! conn #:user uid #:team tid #:role "owner")
  (audit! conn #:action "org.create" #:actor-type "user"
          #:actor-id (if actor (principal-user-id actor) "system")
          #:team-id tid #:resource-type "org" #:resource-id oid)
  (define-values (tok _t)
    (issue-token! conn #:user uid #:team tid #:name "org-owner" #:scopes '("*:*")))
  (hasheq 'org_id oid 'org_slug oslug 'org_name name 'plan plan
          'team_id tid 'team_slug team-slug
          'owner_user_id uid 'owner_username owner-username 'token tok))

;; ---- reading ----------------------------------------------------------------
(define (org-row->jsexpr conn r)
  (define oid (vector-ref r 0))
  (hasheq 'id oid 'slug (vector-ref r 1) 'name (vector-ref r 2)
          'status (vector-ref r 3) 'plan (vector-ref r 4) 'created_at (vector-ref r 5)
          'teams (query-value conn "SELECT COUNT(*) FROM teams WHERE org_id = ?" oid)
          'users (query-value conn "SELECT COUNT(*) FROM users WHERE org_id = ?" oid)))

(define ORG-COLS "SELECT id, slug, name, status, plan, created_at FROM orgs ")

(define (org-list conn)
  (for/list ([r (in-list (query-rows conn (string-append ORG-COLS "ORDER BY created_at, slug")))])
    (org-row->jsexpr conn r)))

(define (org-get conn org-id)
  (define r (query-maybe-row conn (string-append ORG-COLS "WHERE id = ?") org-id))
  (and r (hash-set* (org-row->jsexpr conn r)
                    'team_list (org-teams conn org-id)
                    'member_list (org-members conn org-id)
                    'quota (org-quota conn org-id)
                    'usage (org-usage conn org-id))))

(define (org-get-by-slug conn slug)
  (define oid (query-maybe-value conn "SELECT id FROM orgs WHERE slug = ?" slug))
  (and oid (org-get conn oid)))

(define (org-teams conn org-id)
  (for/list ([r (in-list (query-rows conn
     (string-append "SELECT id, slug, name, status, created_at FROM teams "
                    "WHERE org_id = ? ORDER BY created_at, slug") org-id))])
    (hasheq 'id (vector-ref r 0) 'slug (vector-ref r 1) 'name (vector-ref r 2)
            'status (vector-ref r 3) 'created_at (vector-ref r 4)
            'members (query-value conn "SELECT COUNT(*) FROM memberships WHERE team_id = ?" (vector-ref r 0)))))

;; every human in the company, with their org tier and their team roles
(define (org-members conn org-id)
  (for/list ([r (in-list (query-rows conn
     (string-append "SELECT id, username, display_name, status, org_role_key FROM users "
                    "WHERE org_id = ? ORDER BY username") org-id))])
    (define uid (vector-ref r 0))
    (hasheq 'user_id uid 'username (vector-ref r 1)
            'display_name (nz (vector-ref r 2)) 'status (vector-ref r 3)
            'org_role (nz (vector-ref r 4))
            'teams (query-list conn
              (string-append "SELECT t.slug || ':' || m.role_key FROM memberships m "
                             "JOIN teams t ON t.id = m.team_id WHERE m.user_id = ? ORDER BY t.slug") uid))))

;; audit across every team in the company (TEN-2a: the org admin's window into
;; what happened, without reading the data itself)
(define (org-audit conn org-id #:limit [lim 50] #:offset [off 0])
  (for/list ([r (in-list (query-rows conn
     (string-append "SELECT a.id, a.action, a.actor_type, a.actor_id, a.resource_type, "
                    "       a.resource_id, a.result, a.at, t.slug "
                    "FROM audit_log a JOIN teams t ON t.id = a.team_id "
                    "WHERE t.org_id = ? ORDER BY a.at DESC, a.id DESC LIMIT ? OFFSET ?")
     org-id lim off))])
    (hasheq 'id (vector-ref r 0) 'action (vector-ref r 1)
            'actor_type (nz (vector-ref r 2)) 'actor_id (nz (vector-ref r 3))
            'resource_type (nz (vector-ref r 4)) 'resource_id (nz (vector-ref r 5))
            'result (nz (vector-ref r 6)) 'at (vector-ref r 7) 'team (vector-ref r 8))))

;; ---- mutating ---------------------------------------------------------------
;; a team slug is unique WITHIN the org, so two companies may both run "engineering"
(define (org-add-team! conn actor org-id #:name name #:slug [slug #f])
  (define s (org-slugify (or slug name)))
  (cond
    [(query-maybe-value conn "SELECT id FROM teams WHERE org_id = ? AND slug = ?" org-id s) #f]
    [else
     (define tid (create-team! conn #:name name #:slug s #:org org-id))
     (default-policy! conn tid)
     (audit! conn #:action "org.team.create" #:actor-type "user"
             #:actor-id (principal-user-id actor) #:team-id tid
             #:resource-type "team" #:resource-id tid)
     (hasheq 'id tid 'slug s 'name name 'org_id org-id)]))

;; add a person to the company (and optionally straight into one of its teams).
;; `add-member!` settles users.org_id, which is what seals them into this org.
(define (org-attach-member! conn actor org-id
                            #:username username #:password [pw #f] #:display-name [dn #f]
                            #:team [team-id #f] #:role [role "member"]
                            #:org-role [org-role #f])
  (define tid (or team-id
                  (query-maybe-value conn
                    "SELECT id FROM teams WHERE org_id = ? ORDER BY created_at LIMIT 1" org-id)))
  (cond
    [(not tid) #f]
    [(not (equal? (team-org conn tid) org-id)) #f]        ; never place a user outside the org
    [else
     (define uid (create-user! conn #:username username #:display-name (or dn username)
                               #:password pw #:org org-id #:org-role org-role))
     (add-member! conn #:user uid #:team tid #:role role)
     (audit! conn #:action "org.member.add" #:actor-type "user"
             #:actor-id (principal-user-id actor) #:team-id tid
             #:resource-type "user" #:resource-id uid)
     (define-values (tok _t) (issue-token! conn #:user uid #:team tid #:scopes '("*:*")))
     (hasheq 'user_id uid 'username username 'team_id tid 'role role
             'org_role (or org-role 'null) 'token tok)]))

(define (org-set-status! conn actor org-id status)
  (define exists (query-maybe-value conn "SELECT id FROM orgs WHERE id = ?" org-id))
  (and exists
       (begin
         (query-exec conn "UPDATE orgs SET status = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ?"
                     status org-id)
         (audit! conn #:action (format "org.~a" status) #:actor-type "user"
                 #:actor-id (if actor (principal-user-id actor) "system")
                 #:resource-type "org" #:resource-id org-id)
         #t)))

(define (org-suspended? conn org-id)
  (and org-id
       (let ([st (query-maybe-value conn "SELECT status FROM orgs WHERE id = ?" org-id)])
         (and (string? st) (string=? st "suspended")))))

;; Read-only if the COMPANY is frozen or the team itself is. Suspension is a
;; status read, never a cascade write — so resuming an org cannot accidentally
;; un-suspend a team that was individually suspended.
(define (tenant-read-only? conn team-id)
  (or (let ([st (query-maybe-value conn "SELECT status FROM teams WHERE id = ?" team-id)])
        (and (string? st) (string=? st "suspended")))
      (org-suspended? conn (team-org conn team-id))))

;; ---- quotas: the company cap, divided by the company ------------------------
(define (set-org-limit! conn org-id dimension limit #:window [w "day"])
  (set-limit! conn "org" org-id dimension limit #:window w))

(define (org-quota conn org-id)
  (for/list ([dim (in-list '("ai.requests" "ai.tokens.total" "ai.concurrency"))])
    (define-values (lim w) (get-limit conn "org" org-id dim))
    (hasheq 'dimension dim 'limit (or lim 'null) 'window (or w 'null))))

(define (org-usage conn org-id)
  (for/list ([dim (in-list '("ai.requests" "ai.tokens.total"))])
    (hash-set (quota-check conn "org" org-id dim 0) 'dimension dim)))

;; Admission requires BOTH to pass: a team under its own limit but inside a
;; company that has burned its budget is refused. Returns the FAILING decision
;; (with 'subject naming which tier said no), else the team decision.
(define (tenant-quota-check conn p dimension amount)
  (define team-id (principal-team-id p))
  (define org-id (team-org conn team-id))
  (define od (and org-id (quota-check conn "org" org-id dimension amount)))
  (define td (quota-check conn "team" team-id dimension amount))
  (cond
    [(and od (not (hash-ref od 'allowed))) (hash-set od 'subject "org")]
    [else (hash-set td 'subject "team")]))

;; meter at both tiers, so the company's ledger is the sum of its teams'
(define (tenant-quota-record! conn p dimension amount)
  (define team-id (principal-team-id p))
  (quota-record! conn "team" team-id dimension amount)
  (define org-id (team-org conn team-id))
  (when org-id (quota-record! conn "org" org-id dimension amount)))
