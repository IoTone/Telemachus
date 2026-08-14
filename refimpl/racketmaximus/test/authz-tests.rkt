#lang racket/base

;; test/authz-tests.rkt — slice 1: persistence + RBAC.
;;   raco test test/authz-tests.rkt      (from refimpl/racketmaximus/, with pkgs on PLTCOLLECTS)

(require rackunit
         db
         db-kit/migrate
         "../domain/db/id.rkt"
         "../domain/db/migrations.rkt"
         "../domain/authz/authz.rkt"
         "../domain/authz/permissions.rkt")

;; a fresh in-memory database with the schema applied
(define (fresh)
  (define conn (sqlite3-connect #:database 'memory))
  (migrate! conn all-migrations)
  conn)

;; a two-team scenario: alice = operator+owner of team1; bob/carol/dave =
;; owner/member/viewer of team2 (all non-operator).
(define (scenario)
  (define conn (fresh))
  (define-values (uid tid) (bootstrap! conn #:username "alice"))
  (define bob   (create-user! conn #:username "bob"))
  (define carol (create-user! conn #:username "carol"))
  (define dave  (create-user! conn #:username "dave"))
  (define t2    (create-team! conn #:name "Team Two" #:slug "t2"))
  (add-member! conn #:user bob   #:team t2 #:role "owner")
  (add-member! conn #:user carol #:team t2 #:role "member")
  (add-member! conn #:user dave  #:team t2 #:role "viewer")
  (values conn (hasheq 'uid uid 'tid tid 'bob bob 'carol carol 'dave dave 't2 t2)))

;; ============================================================================
(test-case "uuid4 shape"
  (define u (uuid4))
  (check-equal? (string-length u) 36)
  (check-equal? (string-ref u 14) #\4)                       ; version nibble
  (check-equal? (length (regexp-match-positions* #rx"-" u)) 4))

(test-case "migrations apply once, idempotent"
  (define conn (fresh))
  (define applied (applied-migrations conn))
  (check-true (and (member "0001-core" applied) #t))
  (migrate! conn all-migrations)                              ; re-run is a no-op
  (check-equal? (applied-migrations conn) applied)
  ;; a known table exists
  (check-equal? (query-value conn "SELECT COUNT(*) FROM users") 0))

(test-case "bootstrap: first user is operator+owner, seeds roles, is one-shot"
  (define conn (fresh))
  (define-values (uid tid) (bootstrap! conn #:username "alice"))
  (check-equal? (query-value conn "SELECT COUNT(*) FROM users") 1)
  (check-equal? (query-value conn "SELECT is_operator FROM users WHERE id = ?" uid) 1)
  (check-equal? (query-value conn "SELECT role_key FROM memberships WHERE user_id = ?" uid) "owner")
  (check-true (>= (query-value conn "SELECT COUNT(*) FROM roles WHERE team_id IS NULL") 4))
  (check-true (>= (query-value conn "SELECT COUNT(*) FROM audit_log") 1))
  (check-exn exn:fail? (lambda () (bootstrap! conn #:username "eve"))))   ; already bootstrapped

(test-case "operator tier: owner ≠ operator for instance:*"
  (define-values (conn ids) (scenario))
  (define alice (user-principal conn (hash-ref ids 'uid) (hash-ref ids 'tid)))  ; operator
  (define bob   (user-principal conn (hash-ref ids 'bob) (hash-ref ids 't2)))   ; team owner, not operator
  (check-true  (can? conn alice "documents:write"))
  (check-true  (can? conn alice "instance:manage"))          ; operator only
  (check-true  (can? conn bob   "documents:write"))          ; owner *:* (team-scoped)
  (check-true  (can? conn bob   "team:delete"))              ; *:* reaches team:delete
  (check-false (can? conn bob   "instance:manage")))         ; ...but NOT instance:*

(test-case "role permissions: member vs viewer"
  (define-values (conn ids) (scenario))
  (define carol (user-principal conn (hash-ref ids 'carol) (hash-ref ids 't2)))  ; member
  (define dave  (user-principal conn (hash-ref ids 'dave)  (hash-ref ids 't2)))  ; viewer
  (check-true  (can? conn carol "documents:write"))
  (check-false (can? conn carol "documents:delete"))         ; member: write, not delete
  (check-false (can? conn carol "members:manage"))
  (check-true  (can? conn dave  "documents:read"))           ; viewer *:read
  (check-false (can? conn dave  "documents:write"))
  (check-false (can? conn dave  "chat:use")))                ; viewer: no AI spend

(test-case "require-perm raises forbidden"
  (define-values (conn ids) (scenario))
  (define dave (user-principal conn (hash-ref ids 'dave) (hash-ref ids 't2)))
  (check-not-exn (lambda () (require-perm conn dave "documents:read")))
  (check-exn exn:fail:forbidden? (lambda () (require-perm conn dave "documents:write"))))

(test-case "resource reachability: private + cross-team + grant"
  (define-values (conn ids) (scenario))
  (define carol (hash-ref ids 'carol))
  (define pcarol (user-principal conn carol (hash-ref ids 't2)))
  (define pdave  (user-principal conn (hash-ref ids 'dave) (hash-ref ids 't2)))
  (define palice (user-principal conn (hash-ref ids 'uid)  (hash-ref ids 'tid)))  ; operator, team1
  (define priv (hasheq 'resource_type "documents" 'resource_id "doc1"
                       'team_id (hash-ref ids 't2) 'owner_user_id carol 'visibility "private"))
  (check-true  (can? conn pcarol "documents:read" #:resource priv))   ; owner of the doc
  (check-false (can? conn pdave  "documents:read" #:resource priv))   ; viewer, not owner, private
  (check-true  (can? conn palice "documents:read" #:resource priv))   ; operator crosses team + private
  ;; share doc1 with dave
  (grant! conn #:resource-type "documents" #:resource-id "doc1"
          #:principal-type "user" #:principal-id (hash-ref ids 'dave) #:permission "documents:read")
  (check-true  (can? conn pdave "documents:read" #:resource priv))    ; now granted
  (revoke! conn #:resource-type "documents" #:resource-id "doc1"
           #:principal-type "user" #:principal-id (hash-ref ids 'dave) #:permission "documents:read")
  (check-false (can? conn pdave "documents:read" #:resource priv)))   ; revoked

(test-case "api tokens: capped by issuer-perms ∩ scopes"
  (define-values (conn ids) (scenario))
  (define carol (hash-ref ids 'carol))       ; member: has documents:read/write, not members:manage
  (define t2 (hash-ref ids 't2))
  ;; token scoped to read-only
  (define-values (ro _1) (issue-token! conn #:user carol #:team t2 #:scopes '("documents:read")))
  (define pro (resolve-token conn ro))
  (check-true  (can? conn pro "documents:read"))     ; issuer has it AND scope allows
  (check-false (can? conn pro "documents:write"))    ; issuer has write, scope excludes → capped
  ;; token requesting a scope the issuer lacks → intersection empty
  (define-values (esc _2) (issue-token! conn #:user carol #:team t2 #:scopes '("members:manage")))
  (define pesc (resolve-token conn esc))
  (check-false (can? conn pesc "members:manage"))
  ;; unknown token
  (check-false (resolve-token conn "tk_deadbeef")))
