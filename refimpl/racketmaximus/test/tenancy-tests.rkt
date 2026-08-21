#lang racket/base

;; test/tenancy-tests.rkt — slice 45: multi-tenancy (orgs above teams).
;; The demo (test/multitenant-demo.sh) proves it over HTTP; this proves the
;; authorization core directly, so `raco test test/*-tests.rkt` covers it.
;;   raco test test/tenancy-tests.rkt    (from refimpl/racketmaximus/, pkgs on PLTCOLLECTS)

(require rackunit db-kit/portable
         racket/list
         db-kit/migrate
         "../domain/db/migrations.rkt"
         "db-fixture.rkt"
         "../domain/authz/authz.rkt"
         "../domain/authz/permissions.rkt"
         "../domain/orgs/orgs.rkt"
         "../domain/notes/notes.rkt")

(define (fresh)
  (define conn (fresh-db #:migrate? #f))
  (migrate! conn all-migrations)
  conn)

;; An instance with a superadmin plus two unrelated companies. Each company has an
;; org_owner, an org_admin who is NOT in the engineering team, and an engineer who
;; owns a private note there.
(define (instance)
  (define conn (fresh))
  (define-values (root sys-team)
    (bootstrap! conn #:username "root" #:org-name "Instance" #:org-slug "system"
                #:team-name "Instance" #:team-slug "instance"))
  (define (company name slug)
    (define o (org-create! conn #f #:name name #:slug slug
                           #:owner-username (string-append "owner@" slug)
                           #:team-name "Engineering" #:team-slug "engineering"))
    (define oid (hash-ref o 'org_id))
    (define eng (hash-ref o 'team_id))
    ;; a second team, so "another team in my own org" is testable
    (define ops (hash-ref (org-add-team! conn (user-principal conn (hash-ref o 'owner_user_id) eng)
                                         oid #:name "Operations") 'id))
    (define admin (hash-ref (org-attach-member! conn (user-principal conn (hash-ref o 'owner_user_id) eng)
                                                oid #:username (string-append "admin@" slug)
                                                #:team ops #:role "admin" #:org-role "org_admin")
                            'user_id))
    (define dev (hash-ref (org-attach-member! conn (user-principal conn (hash-ref o 'owner_user_id) eng)
                                              oid #:username (string-append "dev@" slug) #:team eng)
                          'user_id))
    (define dev-p (user-principal conn dev eng))
    (define note (notes-create conn dev-p #:title "secret" #:body slug #:visibility "private"))
    ;; a plain team-visible note too — the org admin must not reach this either
    (define tv (notes-create conn dev-p #:title "sprint" #:body slug #:visibility "team"))
    (hasheq 'org oid 'eng eng 'ops ops 'tv-id (hash-ref tv 'id)
            'owner-p (user-principal conn (hash-ref o 'owner_user_id) eng)
            'admin-p (user-principal conn admin ops)
            'dev-p dev-p 'note-id (hash-ref note 'id)))
  (values conn (user-principal conn root sys-team) (company "Acme" "acme") (company "Globex" "globex")))

;; a resource hash as the endpoints build it, for can? / require-perm
(define (note-res conn nid)
  (define r (query-row conn "SELECT team_id, owner_user_id, visibility FROM notes WHERE id = ?" nid))
  (hasheq 'team_id (vector-ref r 0) 'owner_user_id (vector-ref r 1) 'visibility (vector-ref r 2)
          'resource_type "note" 'resource_id nid))

;; ---- the org tier is a distinct tier ----------------------------------------
(test-case "org:* is not reachable from a team role"
  (define-values (conn root acme globex) (instance))
  ;; the org owner also holds team `owner` (*:*) in engineering — but the org tier
  ;; comes from users.org_role_key, not from that
  (check-true  (can? conn (hash-ref acme 'owner-p) "org:manage"))
  (check-true  (can? conn (hash-ref acme 'admin-p) "org:manage"))
  ;; an engineer with a plain team role gets nothing at the org tier
  (check-false (can? conn (hash-ref acme 'dev-p) "org:read"))
  (check-false (can? conn (hash-ref acme 'dev-p) "org:manage")))

(test-case "instance:* is not reachable from an org role"
  (define-values (conn root acme globex) (instance))
  (check-true  (can? conn root "instance:manage"))
  (check-false (can? conn (hash-ref acme 'owner-p) "instance:manage"))   ; org_owner has org:*
  (check-false (can? conn (hash-ref acme 'admin-p) "instance:manage")))

;; ---- the gate ---------------------------------------------------------------
(test-case "the org gate blocks cross-org access unconditionally"
  (define-values (conn root acme globex) (instance))
  (define gnote (note-res conn (hash-ref globex 'note-id)))
  (for ([who (in-list (list 'owner-p 'admin-p 'dev-p))])
    (check-false (can? conn (hash-ref acme who) "notes:read" #:resource gnote)
                 (format "acme ~a must not read a Globex note" who)))
  ;; the superadmin crosses orgs by design
  (check-true (can? conn root "notes:read" #:resource gnote)))

(test-case "a cross-org resource_grant does not open access"
  (define-values (conn root acme globex) (instance))
  (define gnote (note-res conn (hash-ref globex 'note-id)))
  (grant! conn #:resource-type "note" #:resource-id (hash-ref globex 'note-id)
          #:principal-type "user" #:principal-id (principal-user-id (hash-ref acme 'dev-p))
          #:permission "notes:read")
  ;; the row exists — the gate still refuses, because it runs BEFORE grants
  (check-false (can? conn (hash-ref acme 'dev-p) "notes:read" #:resource gnote))
  ;; ...while the same grant inside one org does work (the mechanism is intact)
  (define anote (note-res conn (hash-ref acme 'note-id)))
  (check-false (can? conn (hash-ref acme 'admin-p) "notes:read" #:resource anote))
  (grant! conn #:resource-type "note" #:resource-id (hash-ref acme 'note-id)
          #:principal-type "user" #:principal-id (principal-user-id (hash-ref acme 'admin-p))
          #:permission "notes:read")
  (check-true (can? conn (hash-ref acme 'admin-p) "notes:read" #:resource anote)))

;; ---- TEN-2a: manage, do not read -------------------------------------------
(test-case "an org admin manages every team in its org but reads none of their data"
  (define-values (conn root acme globex) (instance))
  (define admin (hash-ref acme 'admin-p))
  ;; management reaches a team the admin is not a member of (engineering)
  (define eng-res (hasheq 'team_id (hash-ref acme 'eng)))
  (check-true (can? conn admin "members:manage" #:resource eng-res))
  (check-true (can? conn admin "settings:manage" #:resource eng-res))
  (check-true (can? conn admin "audit:read"))
  ;; data does not — neither a private note nor a merely team-visible one in a
  ;; team the admin is not a member of
  (check-false (can? conn admin "notes:read" #:resource (note-res conn (hash-ref acme 'note-id))))
  (check-false (can? conn admin "notes:read" #:resource (note-res conn (hash-ref acme 'tv-id))))
  ;; the org role itself carries no AI spend; whatever the admin can do in its OWN
  ;; team comes from its team role there, not from being a company administrator
  (check-false (can? conn admin "chat:use" #:resource (hasheq 'team_id (hash-ref acme 'eng)))))

;; ---- structural invariants --------------------------------------------------
(test-case "team slugs are unique per org, not globally"
  (define-values (conn root acme globex) (instance))
  (check-equal? (team-org conn (hash-ref acme 'eng)) (hash-ref acme 'org))
  (check-equal? (team-org conn (hash-ref globex 'eng)) (hash-ref globex 'org))
  (check-not-equal? (hash-ref acme 'eng) (hash-ref globex 'eng))
  ;; both companies really do have a team slugged "engineering"
  (check-equal? (query-value conn "SELECT COUNT(*) FROM teams WHERE slug = 'engineering'") 2)
  ;; ...and neither may have two
  (check-false (org-add-team! conn (hash-ref acme 'owner-p) (hash-ref acme 'org) #:name "Engineering")))

(test-case "a user belongs to exactly one org (TEN-2c)"
  (define-values (conn root acme globex) (instance))
  (check-equal? (user-org conn (principal-user-id (hash-ref acme 'dev-p))) (hash-ref acme 'org))
  ;; joining a team in another company is refused at the membership seam
  (check-exn exn:fail?
             (lambda () (add-member! conn #:user (principal-user-id (hash-ref acme 'dev-p))
                                     #:team (hash-ref globex 'eng) #:role "member"))))

;; ---- suspension + nested quotas --------------------------------------------
(test-case "suspending a company freezes all of its teams and no others"
  (define-values (conn root acme globex) (instance))
  (check-false (tenant-read-only? conn (hash-ref acme 'eng)))
  (org-set-status! conn root (hash-ref acme 'org) "suspended")
  (check-true  (tenant-read-only? conn (hash-ref acme 'eng)))
  (check-true  (tenant-read-only? conn (hash-ref acme 'ops)))     ; every team in the company
  (check-false (tenant-read-only? conn (hash-ref globex 'eng)))   ; the other company is untouched
  (org-set-status! conn root (hash-ref acme 'org) "active")
  (check-false (tenant-read-only? conn (hash-ref acme 'eng))))

(test-case "the org cap binds above the team budget"
  (define-values (conn root acme globex) (instance))
  (define dev (hash-ref acme 'dev-p))
  (set-org-limit! conn (hash-ref acme 'org) "ai.requests" 2)
  ;; the team's own limit is the generous default; the company's is 2
  (check-true (hash-ref (tenant-quota-check conn dev "ai.requests" 1) 'allowed))
  (tenant-quota-record! conn dev "ai.requests" 2)
  (define d (tenant-quota-check conn dev "ai.requests" 1))
  (check-false (hash-ref d 'allowed))
  (check-equal? (hash-ref d 'subject) "org")                      ; the ORG is what refused
  ;; a sibling team in the same company shares the exhausted budget
  (define admin (hash-ref acme 'admin-p))
  (check-false (hash-ref (tenant-quota-check conn admin "ai.requests" 1) 'allowed))
  ;; the other company is unaffected
  (check-true (hash-ref (tenant-quota-check conn (hash-ref globex 'dev-p) "ai.requests" 1) 'allowed)))

;; ---- single-tenant parity ---------------------------------------------------
(test-case "single-tenant still works: one implicit org, gate trivially true"
  (define conn (fresh))
  (define-values (uid tid) (bootstrap! conn #:username "alice"))
  (check-equal? (query-value conn "SELECT COUNT(*) FROM orgs") 1)
  (define alice (user-principal conn uid tid))
  (check-equal? (principal-org-id alice) (team-org conn tid))
  (define bob (create-user! conn #:username "bob"))
  (add-member! conn #:user bob #:team tid #:role "member")
  (define bob-p (user-principal conn bob tid))
  (check-true (can? conn bob-p "notes:write"))                     ; nothing changed for a plain member
  (check-false (can? conn bob-p "instance:manage"))
  (check-false (can? conn bob-p "org:manage"))                     ; the tier exists but nobody holds it
  (check-equal? (user-org conn bob) (team-org conn tid)))          ; joining settled the home org

;; ---- upgrading an EXISTING deployment ---------------------------------------
;; The one migration in this slice rebuilds `teams` on SQLite (to swap UNIQUE(slug)
;; for UNIQUE(org_id, slug)), so a pre-slice-45 database must survive it with its
;; data and its authorization behaviour intact. Rows here are written with raw SQL
;; in the OLD shape — no org_id anywhere — exactly as the old code left them.
(test-case "0016-orgs upgrades a pre-existing single-tenant database"
  (define conn (fresh-db #:migrate? #f))
  (define old-world (filter (lambda (m) (not (equal? (migration-id m) "0016-orgs"))) all-migrations))
  (migrate! conn old-world)
  (query-exec conn "INSERT INTO users (id, username, is_operator) VALUES ('u1','alice',1)")
  (query-exec conn "INSERT INTO users (id, username) VALUES ('u2','bob')")
  (query-exec conn "INSERT INTO teams (id, slug, name) VALUES ('t1','default','Default')")
  (query-exec conn "INSERT INTO teams (id, slug, name) VALUES ('t2','ops','Ops')")
  (query-exec conn "INSERT INTO memberships (id,user_id,team_id,role_key) VALUES ('m1','u1','t1','owner')")
  (query-exec conn "INSERT INTO memberships (id,user_id,team_id,role_key) VALUES ('m2','u2','t1','member')")
  (query-exec conn (string-append "INSERT INTO notes (id,team_id,owner_user_id,visibility,title,body) "
                                  "VALUES ('n1','t1','u2','private','old','pre-upgrade')"))
  (seed-builtin-roles! conn)

  (migrate! conn all-migrations)                                   ; <- the upgrade

  ;; nothing lost, and the rebuilt table kept its rows verbatim
  (check-equal? (query-value conn "SELECT COUNT(*) FROM teams") 2)
  (check-equal? (query-value conn "SELECT COUNT(*) FROM users") 2)
  (check-equal? (query-value conn "SELECT COUNT(*) FROM notes") 1)
  (check-equal? (query-value conn "SELECT COUNT(*) FROM memberships") 2)
  (check-equal? (query-list conn "SELECT slug || '=' || name FROM teams ORDER BY slug")
                '("default=Default" "ops=Ops"))
  ;; everyone lands in ONE implicit org — an upgraded deployment is single-tenant
  (check-equal? (query-value conn "SELECT COUNT(DISTINCT org_id) FROM teams") 1)
  (check-equal? (user-org conn "u2") (team-org conn "t1"))
  ;; ...and authorization behaves exactly as it did before
  (define bob (user-principal conn "u2" "t1"))
  (check-true  (can? conn bob "notes:read"
                     #:resource (hasheq 'team_id "t1" 'owner_user_id "u2" 'visibility "private")))
  (check-false (can? conn bob "instance:manage"))
  (check-true  (can? conn (user-principal conn "u1" "t1") "instance:manage"))
  ;; the new constraint is live on the rebuilt table
  (check-exn exn:fail?
             (lambda () (create-team! conn #:name "dup" #:slug "ops" #:org (team-org conn "t2"))))
  ;; re-running the migration list is a no-op
  (migrate! conn all-migrations)
  (check-equal? (query-value conn "SELECT COUNT(*) FROM orgs") 1))
