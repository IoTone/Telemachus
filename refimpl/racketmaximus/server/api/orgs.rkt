#lang racket/base

;; server/api/orgs.rkt — the two multi-tenancy management planes and the
;; audit chain
;;
;; Split out of main.rkt by #110 r3. The shared surface every handler here
;; needs — the pool, the request accessors, with-auth/with-mt, the response
;; constructors — is server/kit.rkt.

(provide ep-orgs-list ep-orgs-create ep-audit-verify ep-audit-export
         ep-org-get ep-org-status ep-org-update ep-org-quota ep-seed-tenants
         ep-my-org ep-my-org-teams ep-my-org-team-create ep-my-org-team-quota
         ep-my-org-member-role ep-my-org-member-add ep-my-org-audit)

(require racket/string
         db-kit/portable
         web-server/http
         json
         web-kit
         (only-in "../../domain/authz/authz.rkt" audit! principal-team-id principal-user-id require-perm set-user-org-role! user-org)
         (only-in "../../domain/authz/permissions.rkt" org-role-key?)
         "../../domain/orgs/orgs.rkt"
         (only-in "../../domain/samples/tenants.rkt" seed-tenants! tenants-seeded?)
         (only-in "../../domain/quota/quota.rkt" set-limit!)
         (only-in "../../domain/audit/chain.rkt" audit-chain-status audit-chain-verify audit-export-jsonl)
         (only-in "../../domain/i18n/i18n.rkt" t)
         "../kit.rkt")

;; ---- multi-tenancy: the two management planes (slice 45) --------------------
;; Superadmin plane (/api/orgs*, instance:manage) runs the INSTANCE; org-admin
;; plane (/api/org*, org:manage) runs ONE company. Both 404 when the flag is off —
;; the surface disappears, the authorization semantics do not change.
;; See docs/design/multi-tenancy.md.

;; ---- superadmin plane -------------------------------------------------------
(define (ep-orgs-list req)
  (with-mt req (lambda ()
    (with-auth req (lambda (p)
      (require-perm db-conn p "instance:manage")
      (json-response (hasheq 'orgs (org-list db-conn))))))))

(define (ep-orgs-create req)
  (with-mt req (lambda ()
    (with-auth req (lambda (p)
      (require-perm db-conn p "instance:manage")
      (define b (read-json-body req))
      (define name (hash-ref b 'name #f))
      (define owner (hash-ref b 'owner_username #f))
      (cond
        [(or (not name) (not owner)) (err "name and owner_username required" 400)]
        [(query-maybe-value db-conn "SELECT id FROM users WHERE username = ?" (format "~a" owner))
         (err "owner_username already exists on this instance" 409)]     ; TEN-2b: usernames are global
        [(and (hash-ref b 'plan #f) (not (org-plan? (format "~a" (hash-ref b 'plan)))))
         (err (format "unknown plan; expected one of ~a"
                      (string-join (sort (hash-keys org-plan-quotas) string<?) ", ")) 400)]
        [else
         (define created
          (org-create! db-conn p
                       #:name (format "~a" name)
                       #:slug (let ([sl (hash-ref b 'slug #f)]) (and sl (format "~a" sl)))
                       #:plan (format "~a" (hash-ref b 'plan "trial"))
                       #:owner-username (format "~a" owner)
                       #:owner-password (let ([pw (hash-ref b 'owner_password #f)]) (and pw (format "~a" pw)))
                       #:owner-name (let ([n (hash-ref b 'owner_name #f)]) (and n (format "~a" n)))
                       #:team-name (format "~a" (hash-ref b 'team_name "Engineering"))
                       #:team-slug (org-slugify (hash-ref b 'team_slug "engineering"))))
         ;; #f means the caller named a slug that is already a company. Refusing is
         ;; the whole point: a pipeline re-run must not mint `acme-1`. 409 + the
         ;; slug tells the caller to GET /api/orgs/<slug> instead.
         (if created
             (json-response created #:code 201)
             (err (format "an organization with slug '~a' already exists"
                          (org-slugify (hash-ref b 'slug "")))
                  409))]))))))

;; Every /api/orgs/<ref> route addresses a company by EITHER its id or its slug.
;; A devops caller holds the slug it declared in source control; it never saw the
;; id the server minted. Resolve once, here, so no endpoint has to remember.
(define (with-org req ref proc)
  (with-mt req (lambda ()
    (with-auth req (lambda (p)
      (require-perm db-conn p "instance:manage")
      (define id (org-resolve db-conn ref))
      (if id (proc p id) (err "not found" 404)))))))

;; ---- the audit chain and the export (#84 r3) --------------------------------
;; `instance:manage`, and NOT behind `with-mt`: a single-tenant instance has an
;; audit log too, and its entries carry no org. `?org=` takes an id or a slug as
;; every /api/orgs route does (`org-resolve`), and `-` names the no-org bucket,
;; which on a single-tenant box is the whole log. The default is `-` for that
;; reason.
(define (audit-org-ref req)
  (define ref (query-param req 'org "-"))
  (if (string=? ref "-") "-" (or (org-resolve db-conn ref) #f)))

(define (ep-audit-verify req)
  (with-auth req (lambda (p)
    (require-perm db-conn p "instance:manage")
    (define oid (audit-org-ref req))
    (cond
      [(not oid) (err "no such org" 404)]
      [else
       ;; verify SEALS first (the default), so an operator's own command never
       ;; reports an unsealed tail as if something were missing — and the status
       ;; beside it says how big that window currently is.
       (define v (audit-chain-verify db-conn oid))
       (json-response (hash-set v 'status (audit-chain-status db-conn oid)))]))))

(define (ep-audit-export req)
  (with-auth req (lambda (p)
    (require-perm db-conn p "instance:manage")
    (define oid (audit-org-ref req))
    (define (us k) (let ([v (query-param req k "")])
                     (and (not (string=? v "")) (string->number v))))
    (cond
      [(not oid) (err "no such org" 404)]
      [else
       (define lim (max 1 (min 1000000 (or (us 'limit) 100000))))
       (audit! db-conn #:action "audit.exported" #:actor-type "user"
               #:actor-id (principal-user-id p) #:team-id (principal-team-id p)
               #:org-id (if (string=? oid "-") 'null oid) #:result "ok"
               #:meta (jsexpr->string (hasheq 'from (or (us 'from) 'null)
                                              'to (or (us 'to) 'null) 'limit lim)))
       ;; streamed, not assembled: an org's year of document reads is not
       ;; something to hold in memory. `x-ndjson` is what the line-delimited
       ;; form is called, and `attachment` keeps a browser from rendering it.
       (response/output
        #:mime-type #"application/x-ndjson"
        #:headers (list (make-header #"X-Content-Type-Options" #"nosniff")
                        (make-header #"Content-Disposition"
                                     (string->bytes/utf-8
                                      (format "attachment; filename=\"audit-~a.jsonl\"" oid))))
         (lambda (out)
          (void (audit-export-jsonl db-conn oid out
                                    #:from (us 'from) #:to (us 'to) #:limit lim))))]))))

(define (ep-org-get req ref)
  (with-org req ref (lambda (p id) (json-response (org-get db-conn id)))))

(define (ep-org-status req ref status)
  (with-org req ref (lambda (p id)
    (org-set-status! db-conn p id status)
    (json-response (hasheq 'ok #t 'org_id id 'status status)))))

;; PATCH — rename, or move the company onto another plan. Partial: send only the
;; fields you mean. A plan change re-applies that plan's caps (see org-update!).
(define (ep-org-update req ref)
  (with-org req ref (lambda (p id)
    (define b (read-json-body req))
    (define name (let ([n (hash-ref b 'name #f)]) (and n (format "~a" n))))
    (define plan (let ([pl (hash-ref b 'plan #f)]) (and pl (format "~a" pl))))
    (define domain? (hash-has-key? b 'domain))          ; TEN-2d: a string, or null to clear
    (cond
      [(and (not name) (not plan) (not domain?)) (err "name, plan and/or domain required" 400)]
      [(and plan (not (org-plan? plan)))
       (err (format "unknown plan; expected one of ~a"
                    (string-join (sort (hash-keys org-plan-quotas) string<?) ", ")) 400)]
      [else
       (with-handlers ([exn:fail:user? (lambda (e) (err (exn-message e) 400))])
         (define d (and domain? (org-set-domain! db-conn p id (hash-ref b 'domain))))
         (define u (if (or name plan) (org-update! db-conn p id #:name name #:plan plan) (hasheq 'ok #t 'org_id id)))
         (json-response (if d (hash-set u 'domain (hash-ref d 'domain)) u)))]))))

(define (ep-org-quota req ref)
  (with-org req ref (lambda (p id)
    (define b (read-json-body req))
    (define dim (hash-ref b 'dimension #f))
    (define lim (hash-ref b 'limit #f))
    (cond
      [(or (not dim) (not lim)) (err "dimension and limit required" 400)]
      [else
       (set-org-limit! db-conn id (format "~a" dim) lim #:window (format "~a" (hash-ref b 'window "day")))
       (audit! db-conn #:action "org.quota.set" #:actor-type "user" #:actor-id (principal-user-id p)
               #:resource-type "org" #:resource-id id)
       (json-response (hasheq 'ok #t 'org_id id 'dimension dim 'limit lim))]))))

;; demo fixture: two complete companies with known dev logins (see
;; domain/samples/tenants.rkt). Superadmin-only, refuses to run twice.
(define (ep-seed-tenants req)
  (with-mt req (lambda ()
    (with-auth req (lambda (p)
      (require-perm db-conn p "instance:manage")
      (cond
        [(tenants-seeded? db-conn) (err "demo tenants already seeded" 409)]
        [else
         (define seeded (seed-tenants! db-conn p))
         (json-response (hasheq 'ok #t 'tenants seeded
                                'note "DEV FIXTURE — these passwords are public; never seed a production instance")
                        #:code 201)]))))))

;; ---- org-admin plane --------------------------------------------------------
(define (ep-my-org req)
  (with-mt req (lambda ()
    (with-auth req (lambda (p)
      (require-perm db-conn p "org:read")
      (define o (and (caller-org p) (org-get db-conn (caller-org p))))
      (if o (json-response o) (err "no organization for this principal" 404)))))))

(define (ep-my-org-teams req)
  (with-mt req (lambda ()
    (with-auth req (lambda (p)
      (require-perm db-conn p "org:read")
      (json-response (hasheq 'teams (org-teams db-conn (caller-org p)))))))))

(define (ep-my-org-team-create req)
  (with-mt req (lambda ()
    (with-auth req (lambda (p)
      (require-perm db-conn p "org:manage")      ; the tier gate
      (require-perm db-conn p "team:create")
      (define b (read-json-body req))
      (define name (hash-ref b 'name #f))
      (cond
        [(not name) (err "name required" 400)]
        [else
         (define t (org-add-team! db-conn p (caller-org p)
                                  #:name (format "~a" name)
                                  #:slug (let ([sl (hash-ref b 'slug #f)]) (and sl (format "~a" sl)))))
         (if t (json-response t #:code 201)
             (err "a team with that slug already exists in this organization" 409))]))))))

;; TEN-2h: promote or demote a person within the company — the only way to make an
;; existing user an org_reader (or take it away), since the org role is set on
;; creation otherwise. Only users of the caller's own org; never the caller.
(define (ep-my-org-team-quota req ref)
  (with-mt req (lambda ()
    (with-auth req (lambda (p)
      (require-perm db-conn p "org:manage")      ; the tier gate
      (require-perm db-conn p "quota:manage")
      (define b (read-json-body req))
      (define dim (hash-ref b 'dimension #f))
      (define limit (hash-ref b 'limit #f))
      (define tid (org-team-resolve db-conn (caller-org p) ref))
      (cond
        ;; the 404 comes FIRST: whether this team exists is the thing a caller
        ;; outside the company must not learn, and a 400 about a missing
        ;; `dimension` would confirm it.
        [(not tid) (err "not found" 404)]
        [(or (not dim) (not limit)) (err "dimension and limit required" 400)]
        [else
         (define w (hash-ref b 'window "day"))
         (set-limit! db-conn "team" tid (format "~a" dim) limit #:window (format "~a" w))
         ;; #:team-id is the team whose budget changed, not the caller's acting
         ;; team: `org-audit` INNER JOINs `teams` on it, so an entry without one
         ;; is written and then invisible in the company's own trail — the gap
         ;; QUOTA-3 names and `user.2fa.reset` still has. test/multitenant-demo.sh
         ;; caught it. Naming the subject team also puts the event in the trail of
         ;; the team it is about, which is where somebody would look for it.
         (audit! db-conn #:action "org.team.quota" #:actor-type "user" #:actor-id (principal-user-id p)
                 #:team-id tid #:resource-type "team" #:resource-id tid
                 #:meta (jsexpr->string (hasheq 'dimension dim 'limit limit 'window w)))
         (json-response (hasheq 'ok #t 'team_id tid 'dimension dim 'limit limit 'window w))]))))))

(define (ep-my-org-member-role req uid)
  (with-mt req (lambda ()
    (with-auth req (lambda (p)
      (require-perm db-conn p "org:manage")
      (define b (read-json-body req))
      (define role (let ([r (hash-ref b 'org_role 'null)]) (if (eq? r 'null) #f (format "~a" r))))
      (define target-org (user-org db-conn uid))
      (cond
        [(and role (not (org-role-key? role))) (err "unknown org_role" 400)]
        [(not (equal? target-org (caller-org p))) (err "not found" 404)]
        [(equal? uid (principal-user-id p)) (err "you cannot change your own org role" 400)]
        [else
         (set-user-org-role! db-conn uid role)
         (audit! db-conn #:action "org.member.role" #:actor-type "user" #:actor-id (principal-user-id p)
                 #:resource-type "user" #:resource-id uid
                 #:meta (jsexpr->string (hasheq 'org_role (or role 'null))))
         (json-response (hasheq 'ok #t 'user_id uid 'org_role (or role 'null)))]))))))

(define (ep-my-org-member-add req)
  (with-mt req (lambda ()
    (with-auth req (lambda (p)
      (require-perm db-conn p "org:manage")      ; the tier gate
      (require-perm db-conn p "members:manage")
      (define b (read-json-body req))
      (define u (hash-ref b 'username #f))
      (define org-role (let ([r (hash-ref b 'org_role #f)]) (and r (format "~a" r))))
      (cond
        [(not u) (err "username required" 400)]
        [(and org-role (not (org-role-key? org-role))) (err "unknown org_role" 400)]
        [(query-maybe-value db-conn "SELECT id FROM users WHERE username = ?" (format "~a" u))
         (err "username already exists on this instance" 409)]
        [else
         (define r (org-attach-member! db-conn p (caller-org p)
                                       #:username (format "~a" u)
                                       #:password (let ([pw (hash-ref b 'password #f)]) (and pw (format "~a" pw)))
                                       #:display-name (let ([d (hash-ref b 'display_name #f)]) (and d (format "~a" d)))
                                       #:team (let ([t (hash-ref b 'team_id #f)]) (and t (format "~a" t)))
                                       #:role (format "~a" (hash-ref b 'role "member"))
                                       #:org-role org-role))
         (if r (json-response r #:code 201)
             (err "no such team in this organization" 400))]))))))

(define (ep-my-org-audit req)
  (with-mt req (lambda ()
    (with-auth req (lambda (p)
      (require-perm db-conn p "org:read")        ; the tier gate
      (require-perm db-conn p "audit:read")
      (define lim (or (string->number (query-param req 'limit "50")) 50))
      (json-response (hasheq 'events (org-audit db-conn (caller-org p) #:limit lim))))))))
