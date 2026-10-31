#lang racket/base

;; test/saas-tests.rkt — hosted onboarding: seed-one-owner, activation, idempotency,
;; and suspend/resume.  raco test test/saas-tests.rkt

(require rackunit db-kit/portable
         db-kit/migrate
         file/sha1
         "../domain/saas/onboarding.rkt"
         "../domain/db/migrations.rkt"
         "db-fixture.rkt"
         "../domain/authz/authz.rkt")

(define (fresh) (define c (fresh-db #:migrate? #f)) (migrate! c all-migrations) c)
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

(test-case "set-tenant-quota! adjusts a tenant limit by provision_id (billing lifecycle)"
  (define c (fresh))
  (define-values (tok uid tid _s) (provision! c #:provision-id "sub_q" #:owner-email "q@x.com" #:plan "trial"))
  (check-equal? (provisioned-team c "sub_q") tid)
  (check-equal? (set-tenant-quota! c #:provision-id "sub_q" #:dimension "ai.tokens.total" #:limit 999999) tid)
  (check-equal? (query-value c "SELECT limit_value FROM quota_limits WHERE subject_id = ? AND dimension = 'ai.tokens.total'" tid) 999999)
  (check-false (set-tenant-quota! c #:provision-id "nope" #:dimension "ai.tokens.total" #:limit 1)))

(test-case "suspend / resume flips tenant status"
  (define c (fresh))
  (define-values (tok uid tid _s) (provision! c #:provision-id "sub_4" #:owner-email "s@t.com"))
  (check-false (team-suspended? c tid))
  (check-true (suspend! c #:provision-id "sub_4"))
  (check-true (team-suspended? c tid))
  (check-true (resume! c #:provision-id "sub_4"))
  (check-false (team-suspended? c tid)))

;; ---- the activation token's storage (#186) ----------------------------------
;;
;; This credential family kept the pre-#13 scheme — bare SHA-1 over a COMPILED-IN
;; salt, in a clean-MIT tree on GitHub — while `api_tokens` moved to a peppered
;; HMAC-SHA-256. Two token-hashing rules, and the weaker one was the one nobody
;; looked at.
;;
;; The claim is narrow on purpose: a `random-token` is 24 bytes of
;; `crypto-random-bytes`, so neither guessing one over the network nor recovering
;; one from a leaked hash was ever feasible. What the pepper buys is that rotating
;; `TMACH_TOKEN_PEPPER` retires every outstanding activation link, which a
;; compiled-in salt cannot do.

(test-case "an activation token is stored under the peppered rule, not the prototype"
  (define c (fresh))
  (define-values (tok uid tid _s)
    (provision! c #:provision-id "sub_hash" #:owner-email "h@b.com"))
  (define stored (query-value c "SELECT token_hash FROM activation_tokens WHERE user_id = ?" uid))
  (check-equal? stored (hash-token tok) "the ONE token-hashing rule, shared with api_tokens")
  ;; …and the control that gives that assertion teeth: the old scheme produced a
  ;; bare 40-hex SHA-1, so a stored value of that shape means the prototype is
  ;; still in use.
  (check-false (regexp-match? #px"^[0-9a-f]{40}$" stored)
               "a bare 40-hex digest is the prototype scheme")
  (check-true (and (regexp-match? #rx"^v1:" stored) #t) "versioned, so a third scheme can follow")
  (disconnect c))

(test-case "a link minted under the OLD scheme still works, and is migrated on use"
  ;; #13's rule for #13's reason: an unclaimed activation link in somebody's
  ;; inbox must survive the upgrade. The row is seeded by hand with the legacy
  ;; digest, because no code path produces one any more — which is what makes
  ;; this a test of the compatibility read rather than of the writer.
  (define c (fresh))
  (define-values (tok uid tid _s)
    (provision! c #:provision-id "sub_legacy" #:owner-email "l@b.com"))
  (define legacy (sha1 (open-input-string (string-append "telemachus-activation-v0" tok))))
  (query-exec c "UPDATE activation_tokens SET token_hash = ? WHERE user_id = ?" legacy uid)
  (define-values (auid atid session) (activate! c #:token tok #:password "legacy99x"))
  (check-equal? auid uid "the old link still activates")
  (check-true (string? session))
  ;; and it was REWRITTEN, so the legacy path drains by itself rather than
  ;; becoming a permanent second scheme
  (check-equal? (query-value c "SELECT token_hash FROM activation_tokens WHERE user_id = ?" uid)
                (hash-token tok)
                "a legacy hit is migrated the moment it is used")
  (disconnect c))

(test-case "a token that was never issued is refused under either scheme"
  (define c (fresh))
  ;; `provision!` answers FOUR values, so `(void (provision! …))` is an arity
  ;; error rather than a discard — the shape these notes have now recorded five
  ;; times. `call-with-values`, or name them.
  (define-values (_t _u _tm _s) (provision! c #:provision-id "sub_neg" #:owner-email "n@b.com"))
  (check-false (activate! c #:token "tk_deadbeef" #:password "nope1234"))
  (disconnect c))
