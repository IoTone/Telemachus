#lang racket/base

;; domain/samples/tenants.rkt — the multi-tenancy demo fixture (slice 45).
;;
;; Seeds two complete, unrelated companies so the isolation properties can be
;; validated against something real rather than an empty database. Superadmin-only
;; (POST /api/admin/seed-tenants), refuses to run twice, and DEV PASSWORDS ARE
;; KNOWN AND PRINTED — this is a demo fixture, never a production path.
;;
;; Both companies get a team slugged `engineering`, which is itself the proof that
;; team slugs are per-org unique (they were globally unique before slice 45), and
;; each team gets a private note so cross-org reads have something to fail against.

(require db-kit/portable
         "../authz/authz.rkt"
         "../orgs/orgs.rkt"
         "../notes/notes.rkt")

(provide seed-tenants! demo-tenants tenants-seeded?)

;; (org-name slug plan owner-username owner-password member-username member-password)
(define demo-tenants
  '(("Acme Robotics" "acme"   "starter" "admin@acme.test"   "acme-admin1"
                                        "dev@acme.test"     "acme-dev1"
     "Acme rocket telemetry — battery chemistry vendor terms. CONFIDENTIAL to Acme.")
    ("Globex Media"  "globex" "trial"   "admin@globex.test" "globex-admin1"
                                        "dev@globex.test"   "globex-dev1"
     "Globex Q4 ad-buy rates and the renewal list. CONFIDENTIAL to Globex.")))

(define (tenants-seeded? conn)
  (and (for/or ([t (in-list demo-tenants)])
         (query-maybe-value conn "SELECT id FROM orgs WHERE slug = ?" (cadr t)))
       #t))

;; Returns a list of per-company hashes: ids, logins, and one-shot tokens for both
;; the org owner and the team member, so a demo script can act as either.
(define (seed-tenants! conn actor)
  (for/list ([t (in-list demo-tenants)])
    (define name (list-ref t 0))
    (define slug (list-ref t 1))
    (define plan (list-ref t 2))
    (define own-u (list-ref t 3)) (define own-p (list-ref t 4))
    (define mem-u (list-ref t 5)) (define mem-p (list-ref t 6))
    (define secret (list-ref t 7))

    ;; the company + its org_owner (an org admin, NOT an instance operator)
    (define org (org-create! conn actor #:name name #:slug slug #:plan plan
                             #:owner-username own-u #:owner-password own-p
                             #:owner-name (string-append name " Admin")
                             #:team-name "Engineering" #:team-slug "engineering"))
    (define oid (hash-ref org 'org_id))
    (define tid (hash-ref org 'team_id))

    ;; an ordinary employee in that company's engineering team
    (define mem (org-attach-member! conn actor oid
                                    #:username mem-u #:password mem-p
                                    #:display-name (string-append name " Engineer")
                                    #:team tid #:role "member"))

    ;; a private note owned by the employee — the thing the other company (and,
    ;; per TEN-2a, this company's own org admin) must not be able to read
    (define emp (user-principal conn (hash-ref mem 'user_id) tid))
    (define note (notes-create conn emp #:title (string-append name " — internal")
                               #:body secret #:visibility "private"))

    (hasheq 'org_id oid 'org_slug (hash-ref org 'org_slug) 'org_name name 'plan plan
            'team_id tid 'team_slug "engineering"
            'owner (hasheq 'user_id (hash-ref org 'owner_user_id)
                           'username own-u 'password own-p
                           'org_role "org_owner" 'token (hash-ref org 'token))
            'member (hasheq 'user_id (hash-ref mem 'user_id)
                            'username mem-u 'password mem-p
                            'team_role "member" 'token (hash-ref mem 'token))
            'private_note_id (hash-ref note 'id))))
