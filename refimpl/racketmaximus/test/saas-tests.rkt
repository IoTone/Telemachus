#lang racket/base

;; test/saas-tests.rkt — hosted onboarding: seed-one-owner, activation, idempotency,
;; and suspend/resume.  raco test test/saas-tests.rkt

(require rackunit
         db
         db-kit/migrate
         "../domain/saas/onboarding.rkt"
         "../domain/db/migrations.rkt"
         "../domain/authz/authz.rkt")

(define (fresh) (define c (sqlite3-connect #:database 'memory)) (migrate! c all-migrations) c)
(define (users c) (query-value c "SELECT COUNT(*) FROM users"))

(test-case "provision seeds exactly one invited owner + plan quotas; token issued"
  (define c (fresh))
  (define-values (tok uid tid state)
    (provision! c #:provision-id "sub_1" #:owner-email "ceo@acme.com" #:org "Acme" #:plan "starter"))
  (check-equal? state 'seeded)
  (check-true (string? tok))
  (check-equal? (users c) 1)
  (check-equal? (query-value c "SELECT status FROM users WHERE id = ?" uid) "invited")
  (check-equal? (query-value c "SELECT role_key FROM memberships WHERE user_id = ?" uid) "owner")
  (check-equal? (query-value c "SELECT limit_value FROM quota_limits WHERE subject_id = ? AND dimension = 'ai.tokens.total'" tid) 500000)
  (check-false (authenticate c "ceo@acme.com" "whatever")))   ; invited → cannot log in yet

(test-case "activate sets password + activates + returns a session; login works; token single-use"
  (define c (fresh))
  (define-values (tok uid tid _s) (provision! c #:provision-id "sub_2" #:owner-email "a@b.com"))
  (define-values (auid atid session) (activate! c #:token tok #:password "hunter2xy"))
  (check-equal? auid uid)
  (check-equal? (query-value c "SELECT status FROM users WHERE id = ?" uid) "active")
  (check-true (string? session))
  (check-equal? (authenticate c "a@b.com" "hunter2xy") uid)
  (check-false (activate! c #:token tok #:password "again99")))   ; reused token rejected

(test-case "idempotent: same provision_id re-issues a token, never a second owner"
  (define c (fresh))
  (define-values (t1 uid1 _ta _s1) (provision! c #:provision-id "sub_3" #:owner-email "x@y.com"))
  (define-values (t2 uid2 _tb _s2) (provision! c #:provision-id "sub_3" #:owner-email "x@y.com"))
  (check-equal? uid1 uid2)
  (check-equal? (users c) 1)
  (check-true (and (string? t2) (not (string=? t1 t2))))
  (check-false (activate! c #:token t1 #:password "zzzzzz11"))   ; old token invalidated by re-issue
  (activate! c #:token t2 #:password "zzzzzz11")
  (define-values (t3 _u _t st3) (provision! c #:provision-id "sub_3" #:owner-email "x@y.com"))
  (check-equal? st3 'active)
  (check-false t3))

(test-case "suspend / resume flips tenant status"
  (define c (fresh))
  (define-values (tok uid tid _s) (provision! c #:provision-id "sub_4" #:owner-email "s@t.com"))
  (check-false (team-suspended? c tid))
  (check-true (suspend! c #:provision-id "sub_4"))
  (check-true (team-suspended? c tid))
  (check-true (resume! c #:provision-id "sub_4"))
  (check-false (team-suspended? c tid)))
