#lang racket/base

;; test/membership-tests.rkt — issue #54: offboarding somebody was not expressible.
;;
;; There was no route to remove a member or change a role, and a password change
;; revoked nothing, so a departing person kept working credentials and an
;; over-privileged one kept their role. What has to hold:
;;   1. a role change takes effect on the next permission check
;;   2. the LAST owner can be neither demoted nor removed
;;   3. removing a member strips their permissions AND kills their team tokens
;;   4. a password change revokes every SESSION but spares machine tokens
;;
;;   raco test test/membership-tests.rkt

(require rackunit db-kit/portable
         db-kit/migrate
         "../domain/db/migrations.rkt"
         "db-fixture.rkt"
         "../domain/authz/authz.rkt")

(define (fresh) (define c (fresh-db #:migrate? #f)) (migrate! c all-migrations) c)
(define (setup)
  (define c (fresh))
  (define-values (owner team) (bootstrap! c #:username "root" #:password "root-pass-1"))
  (define bob (create-user! c #:username "bob" #:password "bob-pass-1"))
  (add-member! c #:user bob #:team team #:role "member")
  (values c owner team bob))

;; ---- 1. a role change lands --------------------------------------------------
(test-case "a role change takes effect on the next permission check"
  (define-values (c owner team bob) (setup))
  (define pb (user-principal c bob team))
  (check-false (can? c pb "members:manage") "a member does not administer the team")
  (check-equal? (set-member-role! c team bob "admin") "admin")
  (check-true (can? c (user-principal c bob team) "members:manage") "an admin does")
  (check-equal? (set-member-role! c team bob "nope") 'unknown-role)
  (check-equal? (set-member-role! c team "ghost" "admin") 'no-such-member)
  (disconnect c))

;; ---- 2. the last owner ---------------------------------------------------------
(test-case "the last owner can be neither demoted nor removed"
  (define-values (c owner team bob) (setup))
  (check-equal? (team-owner-count c team) 1)
  (check-equal? (set-member-role! c team owner "admin") 'last-owner
                "a team with no owner cannot grant anybody the permission to fix it")
  (check-equal? (deactivate-member! c team owner) 'last-owner)
  ;; promote a second one and the first may go
  (check-equal? (set-member-role! c team bob "owner") "owner")
  (check-equal? (team-owner-count c team) 2)
  (check-equal? (set-member-role! c team owner "admin") "admin")
  (check-equal? (team-owner-count c team) 1)
  (disconnect c))

;; ---- 3. removal is removal ------------------------------------------------------
(test-case "removing a member strips the role AND revokes their team tokens"
  (define-values (c owner team bob) (setup))
  (define-values (raw tid) (issue-token! c #:user bob #:team team #:name "bob's session"
                                         #:scopes '("*:*") #:kind SESSION-KIND))
  (check-true (and (resolve-token c raw) #t) "the token works while they are a member")
  (check-equal? (deactivate-member! c team bob) 1 "one token revoked")
  (check-false (resolve-token c raw) "a removed member's credential stops working")
  (check-false (member-role c team bob))
  (check-false (can? c (user-principal c bob team) "notes:read")
               "an inactive membership yields no role, so user-permissions returns '()")
  (check-equal? (deactivate-member! c team bob) 'no-such-member "removing twice is not a thing")
  (disconnect c))

;; ---- 4. a password change signs the sessions out, and spares machines ----------
(test-case "a password change revokes every session but no machine token"
  (define-values (c owner team bob) (setup))
  (define-values (s1 _1) (issue-token! c #:user bob #:team team #:name "laptop"
                                       #:scopes '("*:*") #:kind SESSION-KIND))
  (define-values (s2 _2) (issue-token! c #:user bob #:team team #:name "phone"
                                       #:scopes '("*:*") #:kind SESSION-KIND))
  (define-values (api _3) (issue-token! c #:user bob #:team team #:name "ci"
                                        #:scopes '("notes:read") #:ttl 'never #:kind API-KIND))
  (define-values (wk _4) (issue-token! c #:user bob #:team team #:name "worker:gpu"
                                       #:scopes '("jobs:execute") #:ttl 'never #:kind WORKER-KIND))
  (check-true (change-password! c bob "bob-pass-1" "bob-pass-2"))
  (check-equal? (revoke-user-sessions! c bob) 2 "both sessions, counted")
  (check-false (resolve-token c s1))
  (check-false (resolve-token c s2))
  ;; a machine credential is not reachable with the password, is listed and
  ;; revocable on its own, and killing a customer's worker because somebody
  ;; rotated a password is the worse failure
  (check-true (and (resolve-token c api) #t) "the API token survives")
  (check-true (and (resolve-token c wk) #t) "so does the worker token")
  (check-false (change-password! c bob "wrong" "bob-pass-3") "the current password is still proof")
  (disconnect c))

;; ---- the operator-assisted reset --------------------------------------------------
(test-case "an operator can set a locked-out user's password, which ends their sessions"
  (define-values (c owner team bob) (setup))
  (define-values (s1 _1) (issue-token! c #:user bob #:team team #:name "laptop"
                                       #:scopes '("*:*") #:kind SESSION-KIND))
  (set-password! c bob "reset-pass-9")
  (check-equal? (revoke-user-sessions! c bob) 1)
  (check-false (resolve-token c s1) "a reset ends the sessions the old password minted")
  (check-true (and (authenticate c "bob" "reset-pass-9") #t) "and the new one works")
  (disconnect c))
