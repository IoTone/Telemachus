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
         "../domain/branding/branding.rkt"
         "../domain/notes/notes.rkt"
         "../domain/apps/search.rkt")

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

;; ---- TEN-2h: the org READER ---------------------------------------------------
(test-case "an org_reader reads team-visible data across its company's teams — never private, never elsewhere"
  (define-values (conn root acme globex) (instance))
  (define owner (hash-ref acme 'owner-p))
  ;; a reader who is a member of OPS only, with the org_reader role
  (define reader-id (hash-ref (org-attach-member! conn owner (hash-ref acme 'org)
                                                  #:username "auditor@acme" #:team (hash-ref acme 'ops)
                                                  #:role "viewer" #:org-role "org_reader")
                              'user_id))
  (define reader (user-principal conn reader-id (hash-ref acme 'ops)))
  ;; engineering's team-visible note: readable; its private one: not
  (check-true  (can? conn reader "notes:read" #:resource (note-res conn (hash-ref acme 'tv-id))))
  (check-false (can? conn reader "notes:read" #:resource (note-res conn (hash-ref acme 'note-id))))
  ;; read only: no write, no management, no AI spend at the org tier
  (check-false (can? conn reader "notes:write" #:resource (note-res conn (hash-ref acme 'tv-id))))
  (check-false (can? conn reader "members:manage" #:resource (hasheq 'team_id (hash-ref acme 'eng))))
  (check-false (can? conn reader "chat:use" #:resource (hasheq 'team_id (hash-ref acme 'eng))))
  ;; the admin and the owner still do NOT read (TEN-2a is the default; org:* does not imply org:read-data)
  (check-false (can? conn (hash-ref acme 'admin-p) "notes:read" #:resource (note-res conn (hash-ref acme 'tv-id))))
  ;; the owner is a MEMBER of engineering, so it reads that note through its team
  ;; role; the org tier itself gives it nothing — org:* does not imply org:read-data
  (check-false (org-data-reader? conn owner "notes:read") "org_owner's org:* is administration, not reading")
  (check-false (org-data-reader? conn (hash-ref acme 'admin-p) "notes:read"))
  (check-true  (org-data-reader? conn reader "notes:read"))
  (check-false (org-data-reader? conn reader "notes:write") "…and only the READ permissions")
  ;; and never another company
  (check-false (can? conn reader "notes:read" #:resource (note-res conn (hash-ref globex 'tv-id))))
  ;; the org-scoped listing: both teams' team-visible notes, nobody's private ones
  (define listed (map (lambda (n) (hash-ref n 'title)) (notes-list conn reader #:scope 'org)))
  (check-true (and (member "sprint" listed) #t) "engineering's team-visible note is listed")
  (check-false (member "secret" listed) "…the private one is not")
  (check-equal? (notes-list conn reader) '() "the team-scoped listing is still the reader's own (empty) team")
  ;; a plain member asking for the org scope sees only what they could anyway
  (define dev (hash-ref acme 'dev-p))
  (check-equal? (length (notes-list conn dev #:scope 'org)) 2 "the dev sees their own team's two notes and nothing new")
  ;; search follows the same rule
  (check-true (for/or ([h (in-list (search-all conn reader "sprint" #:scope 'org))]) (equal? (hash-ref h 'type) "note")))
  (check-false (for/or ([h (in-list (search-all conn reader "secret" #:scope 'org))]) (equal? (hash-ref h 'type) "note")))
  (check-equal? (search-all conn reader "sprint") '() "without the org scope, nothing — the reader's own team has no notes")
  ;; the role can be given to and taken from an existing user
  (set-user-org-role! conn reader-id #f)
  (check-false (can? conn (user-principal conn reader-id (hash-ref acme 'ops)) "notes:read"
                     #:resource (note-res conn (hash-ref acme 'tv-id))) "without the role, the read is gone"))

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
  ;; the world before orgs existed: every migration up to 0016, none after — a
  ;; later migration may touch `orgs` (0029 does), so "all but 0016" is not it
  (define old-world (takef all-migrations (lambda (m) (not (equal? (migration-id m) "0016-orgs")))))
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

;; ---- TEN-2d: a company's hostname and branding --------------------------------
(test-case "TEN-2d: a hostname routes to one company; branding is the company's own or the instance's"
  (define-values (conn root acme globex) (instance))
  (define a (hash-ref acme 'org)) (define g (hash-ref globex 'org))
  ;; normalization: case, whitespace, a port; only a hostname
  (check-equal? (normalize-domain " Acme.Test:8835 ") "acme.test")
  (check-false (normalize-domain ""))
  (check-false (normalize-domain 'null))
  (check-exn #rx"not a hostname" (lambda () (normalize-domain "https://acme.test/x")))
  (check-exn #rx"not a hostname" (lambda () (normalize-domain "*.acme.test")))
  ;; set, look up, unique
  (check-equal? (hash-ref (org-set-domain! conn root a "Acme.Test") 'domain) "acme.test")
  (check-equal? (org-by-domain conn "acme.test:8835") a)
  (check-false (org-by-domain conn "globex.test"))
  (check-false (org-by-domain conn "not a host"))
  (check-exn #rx"already assigned" (lambda () (org-set-domain! conn root g "acme.test")))
  (check-equal? (hash-ref (org-get conn a) 'domain) "acme.test")
  ;; clearing frees it
  (org-set-domain! conn root a 'null)
  (check-false (org-by-domain conn "acme.test"))
  (check-equal? (hash-ref (org-get conn a) 'domain) 'null)
  (check-equal? (hash-ref (org-set-domain! conn root g "acme.test") 'domain) "acme.test")
  ;; branding: unset = the instance's, field for field; set = the company's own
  (branding-set! conn (hasheq 'title "Instance Co" 'tagline "one box"))
  (check-false (org-branding-get conn a))
  (check-equal? (hash-ref (branding-for conn a) 'title) "Instance Co")
  (org-branding-set! conn a (hasheq 'title "Acme Portal" 'tagline "" 'logo "not-an-asset-id!"))
  (check-equal? (hash-ref (branding-for conn a) 'title) "Acme Portal")
  (check-equal? (hash-ref (branding-for conn a) 'logo) "" "the logo whitelist applies to a company too")
  ;; the other company is untouched, and so is the instance
  (check-equal? (hash-ref (branding-for conn g) 'title) "Instance Co")
  (check-equal? (hash-ref (branding-get conn) 'title) "Instance Co")
  (org-branding-clear! conn a)
  (check-equal? (hash-ref (branding-for conn a) 'title) "Instance Co"))
