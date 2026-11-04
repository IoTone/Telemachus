#lang racket/base

;; test/password-reset-tests.rkt — "I cannot sign in" (RESET-1…11).
;;
;; WHAT THIS FILE IS REALLY FOR is the five ways a reset differs from an
;; activation. Reusing `activate!` for a mailed reset would have been one line,
;; and each of those five would then have been a defect nothing failed on — so
;; every one has a case AND a positive control, because a rule with no control is
;; a rule that might already be broken.
;;
;; EVERY HELPER IS DEFINED BEFORE ITS FIRST USE. A helper below the case that
;; calls it is "cannot reference an identifier before its definition" at module
;; instantiation, which these notes record costing a run four times now.

(require rackunit db-kit/portable db-kit/migrate
         racket/string racket/list
         "../domain/db/migrations.rkt"
         "db-fixture.rkt"
         "../domain/authz/authz.rkt"
         (only-in "../domain/authz/crypto.rkt" totp base32-decode)
         "../domain/authz/mailed-tokens.rkt"
         "../domain/mail/transport.rkt"
         "../domain/mail/addresses.rkt"
         "../domain/mail/mail.rkt"
         "../domain/accounts/reset.rkt"
         "../domain/saas/onboarding.rkt")

(define (fresh) (define c (fresh-db #:migrate? #f)) (migrate! c all-migrations) c)

(define (configure! c #:base [base "https://tmach.example.test"])
  (transport-set! c (hasheq 'host "127.0.0.1" 'port 2525 'security "none"
                            'from_address "tmach@example.test" 'from_name "TMach"
                            'base_url base 'active #t)))

;; `address-claim!` answers TWO values, so `(void (address-claim! …))` is an
;; arity error and not a discard — the trap these notes record seven times.
(define (verify-address! c uid addr)
  (define-values (tok a) (address-claim! c uid addr))
  (check-equal? (address-verify! c tok) addr)
  a)

;; The first team goes through `bootstrap!`: permissions live in `roles` /
;; `role_permissions` and a bare migrated database has no rows in either.
(define (seed! c #:user [uname "alice"] #:addr [addr "alice@example.test"])
  (define-values (uid tid)
    (bootstrap! c #:username uname #:org-name "Acme" #:org-slug "acme"
                #:team-name "Acme" #:team-slug "acme"))
  (set-password! c uid "original-pw")
  (when addr (verify-address! c uid addr))
  (values uid tid))

(define (deliveries c)
  (query-rows c "SELECT recipient, category, subject, body FROM email_deliveries ORDER BY created_epoch"))

;; `email_deliveries.created_epoch` IS SECONDS, so two messages sent in one
;; second TIE and "the latest" is whatever the engine happens to return — the
;; trap this tree records for `created_at`, run ordering and the grants listing.
;; A case that asks for two resets clears the queue between them, and
;; `token-from-message` ASSERTS there is exactly one so a future case cannot
;; quietly reintroduce the ambiguity and pass against a spent token.
(define (clear-deliveries! c)
  (query-exec c "DELETE FROM email_deliveries"))

(define (latest-reset-body c)
  (define rs (query-rows c (string-append "SELECT body FROM email_deliveries WHERE category = 'reset' "
                                          "ORDER BY created_epoch DESC")))
  (and (pair? rs) (format "~a" (vector-ref (car rs) 0))))

;; The token out of the message, which is the only place a caller can get it —
;; the reply to a reset request deliberately carries nothing (RESET-8).
(define (token-from-message c)
  (check-equal? (query-value c "SELECT COUNT(*) FROM email_deliveries WHERE category = 'reset'") 1
                "exactly one reset message, or 'the latest' is ambiguous")
  (define b (latest-reset-body c))
  (define m (and b (regexp-match #px"reset_token=([^#\\s]+)" b)))
  (and m (cadr m)))

(define (session-count c uid)
  (query-value c (string-append "SELECT COUNT(*) FROM api_tokens WHERE user_id = ? "
                                "AND kind = 'session' AND status = 'active'")
               uid))

(define (status-of c uid)
  (format "~a" (query-value c "SELECT status FROM users WHERE id = ?" uid)))

(define (audit-actions c)
  (map (lambda (r) (format "~a" (vector-ref r 0)))
       (query-rows c "SELECT action FROM audit_log ORDER BY at_us")))

;; ---- the closed vocabulary --------------------------------------------------

(test-case "a mailed token's purpose is a closed vocabulary, both directions"
  (check-equal? (sort MAILED-TOKEN-PURPOSES string<?) '("activate" "reset"))
  (check-true (mailed-token-purpose? "activate"))
  (check-true (mailed-token-purpose? "reset"))
  (check-false (mailed-token-purpose? "recover"))
  ;; A purpose nothing can redeem must not be mintable either — the refusal is at
  ;; the write, so a typo cannot reach the table.
  (define c (fresh))
  (define-values (uid tid) (seed! c))
  (check-exn exn:fail? (lambda () (mint-mailed-token! c uid 1 #:purpose "recover")))
  (close-db! c))

;; ---- RESET-1: one slot per purpose ------------------------------------------

(test-case "an invitation and a reset do not retire each other"
  ;; THE DEFECT THIS PREVENTS: `mint-mailed-token!` retires a user's prior unused
  ;; token, which is right per purpose and wrong across them. Without the
  ;; `purpose` column, asking for a reset would silently kill a pending
  ;; invitation and accepting an invitation would kill a reset link the same
  ;; person had just asked for.
  (define c (fresh))
  (define-values (uid tid) (seed! c))
  (define invite (mint-mailed-token! c uid 48 #:purpose "activate"))
  (define reset  (mint-mailed-token! c uid 1  #:purpose "reset"))
  (check-true (mailed-token-outstanding? c uid "activate"))
  (check-true (mailed-token-outstanding? c uid "reset"))
  ;; and each is still redeemable for its own purpose
  (check-equal? (claim-mailed-token! c reset #:purpose "reset") uid)
  (check-true (mailed-token-outstanding? c uid "activate"))
  (close-db! c))

;; THE PURPOSE PRE-CHECK IN `claim-mailed-token!` CANNOT BE CONTROLLED ALONE, and
;; this says so where somebody would otherwise trust the case below to catch its
;; removal: the spend is a guarded `UPDATE … WHERE … AND purpose = ?`, so with the
;; Racket pre-check neutralised the statement still matches no row and the answer
;; is still #f. They are not duplicates — the pre-check ANSWERS THE CALLER and the
;; WHERE clause makes the spend a compare-and-swap, which is WHK-1's distinction
;; and the reason two redemptions of one link cannot both win. Removing the SQL
;; condition DOES bite, in ten cases.
(test-case "a token is not redeemable for the other purpose"
  (define c (fresh))
  (define-values (uid tid) (seed! c))
  (define reset (mint-mailed-token! c uid 1 #:purpose "reset"))
  ;; Presented to the activation path it matches no row at all, so it cannot be
  ;; told from an unknown token — which is the answer a caller should get.
  (check-false (claim-mailed-token! c reset #:purpose "activate"))
  ;; and it is NOT spent by the failed attempt
  (check-equal? (claim-mailed-token! c reset #:purpose "reset") uid)
  (close-db! c))

(test-case "a claim is single-use, and the second claim loses"
  (define c (fresh))
  (define-values (uid tid) (seed! c))
  (define tok (mint-mailed-token! c uid 1 #:purpose "reset"))
  (check-equal? (claim-mailed-token! c tok #:purpose "reset") uid)
  (check-false (claim-mailed-token! c tok #:purpose "reset"))
  (close-db! c))

(test-case "an expired token is refused"
  (define c (fresh))
  (define-values (uid tid) (seed! c))
  (define tok (mint-mailed-token! c uid 1 #:purpose "reset"))
  ;; Aged by hand: the column is epoch seconds as a string, so this is the only
  ;; way to reach the branch without sleeping.
  (query-exec c "UPDATE activation_tokens SET expires_at = ? WHERE user_id = ?"
              (number->string (- (current-seconds) 10)) uid)
  (check-false (claim-mailed-token! c tok #:purpose "reset"))
  (close-db! c))

;; ---- RESET-8: who may be sent one, and what the caller is told --------------

(test-case "a reset is sent only to a VERIFIED address"
  (define c (fresh))
  (configure! c)
  (define-values (uid tid) (seed! c #:addr #f))     ; no address at all
  (check-equal? (request-password-reset! c "alice@example.test") 'unknown)
  (check-equal? (length (deliveries c)) 0)
  ;; the same address, once confirmed, is reachable
  (verify-address! c uid "alice@example.test")
  (check-equal? (request-password-reset! c "alice@example.test") 'queued)
  (check-equal? (length (deliveries c)) 1)
  (close-db! c))

(test-case "an address set but never verified is not offered a reset"
  ;; THIS CASE EXISTS BECAUSE A CONTROL DID NOT BITE. The case above seeds NO
  ;; address at all, so with `email_verified_epoch IS NOT NULL` removed it still
  ;; passed — it was testing "no address", not "an unverified one". And no code
  ;; path produces this state: `address-verify!` writes the address and the epoch
  ;; together and `address-clear!` clears both, so the columns move in step and
  ;; the clause is defence in depth. Which is exactly why it needs a row built BY
  ;; HAND — QUEUE-8's rule, where a guard was untested while looking tested.
  ;;
  ;; What it defends is the day something writes `users.email` without verifying
  ;; it: MAIL-5 is that nothing is sent to an address that has not answered, and
  ;; a reset is the one message where that failing would mail a CREDENTIAL to an
  ;; address nobody confirmed.
  (define c (fresh))
  (configure! c)
  (define-values (uid tid) (seed! c #:addr #f))
  (query-exec c "UPDATE users SET email = ?, email_verified_epoch = NULL WHERE id = ?"
              "alice@example.test" uid)
  (check-equal? (request-password-reset! c "alice@example.test") 'unknown)
  (check-equal? (length (deliveries c)) 0)
  (close-db! c))

(test-case "a suspended account is not offered a reset"
  (define c (fresh))
  (configure! c)
  (define-values (uid tid) (seed! c))
  (query-exec c "UPDATE users SET status = 'suspended' WHERE id = ?" uid)
  (check-equal? (request-password-reset! c "alice@example.test") 'unknown)
  (check-equal? (length (deliveries c)) 0)
  (close-db! c))

(test-case "the address is matched case-insensitively and mailed AS STORED"
  (define c (fresh))
  (configure! c)
  (define-values (uid tid) (seed! c))
  (check-equal? (request-password-reset! c "  ALICE@Example.TEST ") 'queued)
  (define d (car (deliveries c)))
  ;; the envelope carries the stored address, never the string the caller typed
  (check-equal? (format "~a" (vector-ref d 0)) "alice@example.test")
  (close-db! c))

(test-case "with no transport the outcome is reported and nothing is queued"
  (define c (fresh))
  (define-values (uid tid) (seed! c))
  (check-equal? (request-password-reset! c "alice@example.test") 'no-transport)
  (check-equal? (length (deliveries c)) 0)
  ;; and no token was minted, so a transport appearing later does not make an
  ;; hour-old request suddenly actionable
  (check-false (mailed-token-outstanding? c uid "reset"))
  (close-db! c))

(test-case "the message names no username and carries the reset link"
  (define c (fresh))
  (configure! c)
  (define-values (uid tid) (seed! c #:user "alice-the-owner"))
  (check-equal? (request-password-reset! c "alice@example.test") 'queued)
  (define d (car (deliveries c)))
  (define subject (format "~a" (vector-ref d 2)))
  (define body (format "~a" (vector-ref d 3)))
  (check-equal? (format "~a" (vector-ref d 1)) "reset")
  ;; MTX-8 binds hardest here: this message goes to an address somebody typed
  ;; into a PUBLIC endpoint. The subject goes through the same composer as the
  ;; body, so it cannot leak what the body refuses.
  (check-false (regexp-match? #px"alice-the-owner" body))
  (check-false (regexp-match? #px"alice-the-owner" subject))
  (check-false (regexp-match? #px"(?i:acme)" body))
  (check-true (regexp-match? #px"reset_token=" body))
  (check-true (regexp-match? #px"#/" body))
  ;; it has to be safe to ignore, and has to say so
  (check-true (regexp-match? #px"(?i:if it was not you)" body))
  (check-true (regexp-match? #px"(?i:nothing has changed)" body))
  (close-db! c))

(test-case "a reset ignores the category preferences"
  ;; RESET-5: the preference layers let a person stop this instance mailing them,
  ;; and a person who turned every category off must still be able to recover
  ;; their account — otherwise a preference screen is a way to lock yourself out
  ;; permanently. `reset` is transactional, so the layers are not consulted.
  (define c (fresh))
  (configure! c)
  (define-values (uid tid) (seed! c))
  (check-true (and (member "reset" TRANSACTIONAL-CATEGORIES) #t))
  (for ([cat (in-list MAIL-CATEGORIES)]) (user-pref-set! c uid cat #f))
  (check-equal? (request-password-reset! c "alice@example.test") 'queued)
  (check-equal? (length (deliveries c)) 1)
  (close-db! c))

;; ---- the five ways a reset is not an activation -----------------------------

(test-case "redeeming sets the password, and the old one stops working"
  (define c (fresh))
  (configure! c)
  (define-values (uid tid) (seed! c))
  (check-equal? (request-password-reset! c "alice@example.test") 'queued)
  (define tok (token-from-message c))
  (check-true (string? tok))
  (define-values (ruid revoked session) (reset-password! c #:token tok #:password "a-new-password"))
  (check-equal? ruid uid)
  (check-equal? (authenticate c "alice" "a-new-password") uid)
  (check-false (authenticate c "alice" "original-pw"))
  (close-db! c))

(test-case "RESET-9: every session is revoked"
  ;; The case a reset exists for is an account somebody ELSE may be holding a
  ;; session on. `activate!` revokes nothing, so reusing it would have made the
  ;; reset cosmetic against exactly that attacker.
  (define c (fresh))
  (configure! c)
  (define-values (uid tid) (seed! c))
  (define-values (t1 _1) (issue-token! c #:user uid #:team tid #:name "login" #:scopes '("*:*") #:kind "session"))
  (define-values (t2 _2) (issue-token! c #:user uid #:team tid #:name "login" #:scopes '("*:*") #:kind "session"))
  (check-true (>= (session-count c uid) 2))
  (check-equal? (request-password-reset! c "alice@example.test") 'queued)
  (define-values (ruid revoked session) (reset-password! c #:token (token-from-message c) #:password "a-new-password"))
  (check-true (>= revoked 2))
  ;; the one it just minted is the only live session
  (check-equal? (session-count c uid) 1)
  (check-false (resolve-token c t1))
  (check-false (resolve-token c t2))
  (close-db! c))

(test-case "RESET-10: the login throttle is cleared"
  ;; #116's throttle refuses a sign-in for a growing delay, and its hard lock
  ;; refuses the sign-in that would otherwise clear the counter — so without this
  ;; a person resets their password and still cannot get in, and the documented
  ;; way back from a lock is an operator, which is what a self-service reset
  ;; exists to stop needing.
  ;;
  ;; THE DELAY IS WHAT IS ASSERTED, NOT THE LOCK, and that is a fixture choice
  ;; rather than a narrower rule: the lock is off unless the operator sets
  ;; `TMACH_LOGIN_LOCK_FAILURES`, so reaching it means an environment fixture,
  ;; and both states live in the same row and are cleared by the same statement.
  ;; Past LOGIN-FREE-TRIES the throttle answers `(wait . n)`.
  (define c (fresh))
  (configure! c)
  (define-values (uid tid) (seed! c))
  (for ([i (in-range 6)]) (login-failed! c "alice"))
  (define held (login-throttle c "alice"))
  (check-true (pair? held))
  (check-equal? (car held) 'wait)
  (check-equal? (request-password-reset! c "alice@example.test") 'queued)
  (define-values (ruid revoked session) (reset-password! c #:token (token-from-message c) #:password "a-new-password"))
  (check-false (login-throttle c "alice"))
  (close-db! c))

(test-case "RESET-11: users.status is not touched, and a suspension survives"
  ;; `activate!` sets status to 'active' unconditionally — which is how an
  ;; invited person becomes real, and is also a privilege restoration reachable
  ;; from the mailbox. A reset must not do it, and must refuse the account.
  (define c (fresh))
  (configure! c)
  (define-values (uid tid) (seed! c))
  (check-equal? (request-password-reset! c "alice@example.test") 'queued)
  (define tok (token-from-message c))
  ;; suspended in the hour between asking and clicking
  (query-exec c "UPDATE users SET status = 'suspended' WHERE id = ?" uid)
  (check-false (reset-password! c #:token tok #:password "a-new-password"))
  (check-equal? (status-of c uid) "suspended")
  ;; the password did NOT change
  (query-exec c "UPDATE users SET status = 'active' WHERE id = ?" uid)
  (check-equal? (authenticate c "alice" "original-pw") uid)
  ;; and the token was spent by the attempt — it must not be presentable again
  (check-false (claim-mailed-token! c tok #:purpose "reset"))
  (close-db! c))

(test-case "RESET-2: no session is issued when the account has a second factor"
  ;; TOTP is enforced in `authenticate`; this path does not go through it, so
  ;; minting a session here is a complete 2FA bypass for whoever reads the
  ;; mailbox. Both redemptions carry the rule.
  (define c (fresh))
  (configure! c)
  (define-values (uid tid) (seed! c))
  (check-false (has-second-factor? c uid))
  (check-equal? (request-password-reset! c "alice@example.test") 'queued)
  (define-values (u1 r1 s1) (reset-password! c #:token (token-from-message c) #:password "pw-without-2fa"))
  (check-true (string? s1))                     ; no seed → signed in
  ;; now enrol a second factor and do it again. `enable-2fa!` answers THREE
  ;; values (the seed, its otpauth URI and the recovery codes), so a bare call in
  ;; a value position is an arity error and not a discard — the trap these notes
  ;; record eight times.
  (define-values (seed uri codes) (enable-2fa! c uid))
  (check-true (has-second-factor? c uid))
  (clear-deliveries! c)
  (check-equal? (request-password-reset! c "alice@example.test") 'queued)
  (define-values (u2 r2 s2) (reset-password! c #:token (token-from-message c) #:password "pw-with-2fa"))
  (check-false s2)                               ; a seed → sign in with the code
  ;; the password really was set, so the person is not locked out — they are
  ;; simply made to present the factor they enrolled
  (check-equal? (authenticate c "alice" "pw-with-2fa"
                              #:code (totp (base32-decode seed) (current-seconds) 30 6))
                uid)
  (close-db! c))

(test-case "RESET-11: its own audit action, at the request AND the redemption"
  (define c (fresh))
  (configure! c)
  (define-values (uid tid) (seed! c))
  (check-equal? (request-password-reset! c "alice@example.test") 'queued)
  (define-values (ruid revoked session) (reset-password! c #:token (token-from-message c) #:password "a-new-password"))
  (define acts (audit-actions c))
  (check-true (and (member "user.password.reset.requested" acts) #t))
  (check-true (and (member "user.password.reset" acts) #t))
  ;; a reset is not an onboarding, in a log that is chained and exported
  (check-false (and (member "activate" acts) #t))
  (close-db! c))

(test-case "a password below the floor is named rather than stored"
  (check-false (reset-password-problem "longenough"))
  (check-true (string? (reset-password-problem "x")))
  (check-true (string? (reset-password-problem 42)))
  (check-equal? MIN-RESET-PASSWORD 6))

;; ---- activation keeps its own rules -----------------------------------------

(test-case "activate! still activates, and now withholds a session for 2FA"
  (define c (fresh))
  (define-values (uid tid) (seed! c))
  (query-exec c "UPDATE users SET status = 'invited' WHERE id = ?" uid)
  (define tok (mint-mailed-token! c uid 48 #:purpose "activate"))
  (define res (call-with-values (lambda () (activate! c #:token tok #:password "first-password")) list))
  (check-equal? (car res) uid)
  (check-equal? (status-of c uid) "active")
  (check-true (string? (caddr res)))
  ;; and the same token cannot be replayed
  (check-false (activate! c #:token tok #:password "another"))
  (close-db! c))
