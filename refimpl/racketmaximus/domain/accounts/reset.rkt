#lang racket/base

;; domain/accounts/reset.rkt — "I cannot sign in" (RESET-5…11).
;;
;; `POST /api/admin/users/:id/password` has been the ONLY way back in for a
;; person who cannot sign in, and its own route doc says why: "there is no mail
;; transport to send a reset link." That sentence was true when it was written
;; and is the thing this module makes false. An operator-assisted reset is the
;; honest answer for an instance that cannot send mail; it is not an answer for
;; onboarding anybody onto a service.
;;
;; It is NOT in `domain/saas/onboarding.rkt`, although it redeems the same token
;; family: that module is hosted provisioning, gated by `saas-mode?`, and every
;; instance needs a password reset. It is not in `domain/authz/` either, because
;; it composes a message and the composer lives in `domain/mail`, which requires
;; authz — a reset there would close a cycle. So it sits above all three and is
;; required only by the endpoint, which is `domain/help/answer.rkt`'s shape.

(require db-kit/portable
         racket/string
         "../authz/authz.rkt"            ; set-password!/revoke-user-sessions!/login-lock-clear!/has-second-factor?/issue-token!/first-team-for/audit!/SESSION-KIND
         "../authz/mailed-tokens.rkt"    ; mint-mailed-token!/claim-mailed-token!/mailed-token-holder
         "../mail/addresses.rkt"         ; user-by-verified-address
         "../mail/transport.rkt"         ; transport-configured?
         "../mail/mail.rkt")             ; mail-enqueue-password-reset!

(provide RESET-TTL-HOURS request-password-reset! reset-password!)

;; AN HOUR, where a verification gets a day and an invitation may get several.
;; The horizons differ because the risk does: a verification link proves a
;; mailbox and grants nothing, while this one SETS A PASSWORD. Somebody asked for
;; it a moment ago and will act on it a moment later, so an hour costs a real
;; person nothing — and it is the window in which a shared or later-read mailbox
;; turns a stale link into somebody else's account.
(define RESET-TTL-HOURS 1)

;; THE FLOOR IS NOT CHOSEN HERE ANY MORE (0.13.0). This module carried its own 6,
;; which made the mailbox path the way to set a password the ordinary path would
;; refuse — and every other path carried a copy too. The rule, and the two numbers
;; in it, live in `domain/authz/passwords.rkt`; the account-dependent part of it
;; (12 for an account that can change somebody else's credential) is asked through
;; `require-password!` below, before the token is spent.

;; ---- asking for one ---------------------------------------------------------
;;
;; Answers a SYMBOL saying what really happened, and the caller is expected not
;; to pass it on: `'queued` | `'no-transport` | `'unknown`.
;;
;; THE TRUTH IS REPORTED HERE AND FLATTENED AT THE ENDPOINT (RESET-8), which is
;; `mail-send-test!`'s split — the domain says what occurred so a test and the
;; audit log can assert on it, and the route answers the same thing either way so
;; a stranger cannot use it to ask whether an address has an account. #117 closed
;; a 168-millisecond timing oracle on exactly this question at the sign-in
;; screen; answering it in plain words one route along would be worse than the
;; oracle, because it needs no measurement.
;;
;; THE COST OF THAT IS STATED: a person who mistypes their address is told the
;; same thing as a person who typed it correctly, and waits for a message that
;; will never arrive. The alternative is an endpoint that enumerates accounts for
;; anybody who can type, so the honest mitigation is wording — the console says
;; "if that address has an account, a link is on its way" rather than "sent".
(define (request-password-reset! conn address)
  (define uid (user-by-verified-address conn address))
  (cond
    ;; THE ORDER IS LOAD-BEARING. The unknown-address answer comes FIRST, before
    ;; the transport is consulted, so that an instance with no transport cannot
    ;; be asked to distinguish the two: if "no transport" were reported for a
    ;; known address and "unknown" for the rest, the endpoint would leak exactly
    ;; what the flattening exists to hide the moment an operator removed the
    ;; transport. Both are refusals and neither says which.
    [(not uid) 'unknown]
    [(not (transport-configured? conn)) 'no-transport]
    [else
     (define addr (user-by-address-exact conn uid))
     (define tok (mint-mailed-token! conn uid RESET-TTL-HOURS #:purpose "reset"))
     (mail-enqueue-password-reset! conn #:user uid #:address addr #:token tok
                                   #:ttl-hours RESET-TTL-HOURS)
     ;; Audited at the REQUEST, not only at the redemption, because a reset
     ;; nobody completes is the interesting one: a burst of requests for one
     ;; account is somebody trying, and a link that was sent and never used is
     ;; what a person asks about afterwards. `#:team-id` is deliberately absent
     ;; for `address-verify!`'s reason — a reset belongs to a PERSON, not to one
     ;; of their teams, and guessing one would file it in a trail where it does
     ;; not belong. The consequence is the stated one: it is in the instance's
     ;; trail and not a team's. The address is NOT in the meta; the user id is,
     ;; and the address is one join away for anybody entitled to it.
     (audit! conn #:action "user.password.reset.requested"
             #:actor-type "user" #:actor-id uid
             #:resource-type "user" #:resource-id uid)
     'queued]))

;; The verified address as STORED, which is what the message is sent to — never
;; the string the caller typed. They differ by case whenever somebody capitalises
;; their own address, and mailing the typed form would put a caller-supplied
;; string in the envelope of a message this instance composes.
(define (user-by-address-exact conn uid)
  (define v (query-maybe-value conn "SELECT email FROM users WHERE id = ?" uid))
  (and v (not (sql-null? v)) (format "~a" v)))

;; ---- redeeming one ----------------------------------------------------------
;;
;; -> (values user-id sessions-revoked session-token-or-#f), or #f when the token
;; is unknown, spent, expired, or minted for some other purpose.
;;
;; IT IS NOT `activate!`, AND THE FIVE WAYS IT DIFFERS ARE THE WHOLE POINT OF THE
;; MODULE (RESET-2, RESET-9…11). Reusing that function would have been one line
;; and wrong in every one of them:
;;
;;  1. NO SESSION WHEN THE ACCOUNT HAS A SECOND FACTOR. TOTP is enforced in
;;     `authenticate` and this path does not go through it, so minting a `*:*`
;;     session here hands anybody who can read the mailbox a complete 2FA bypass.
;;     With a seed the password is set and the person signs in with their code.
;;  2. EVERY SESSION IS REVOKED. #54's rule for a password CHANGE, and it matters
;;     more here: the case a reset exists for is an account somebody else may be
;;     holding a session on, and leaving those alive makes the reset cosmetic.
;;  3. THE LOGIN LOCK IS CLEARED. #116's hard lock refuses the sign-in that would
;;     otherwise clear the counter, so without this a person resets their
;;     password and still cannot get in — and the documented way back from a lock
;;     is an operator, which is what this exists to stop needing.
;;  4. `users.status` IS NOT TOUCHED. `activate!` sets it to 'active'
;;     unconditionally, which is how an invited person becomes real and is also,
;;     on an account somebody SUSPENDED, a privilege restoration reachable from
;;     the mailbox. Nor is `provisioning`, for the same reason one layer up.
;;  5. ITS OWN AUDIT ACTION, so a reset and an onboarding are not one event in a
;;     chained, exported log.
(define (reset-password! conn #:token raw #:password pw)
  ;; BEFORE THE CLAIM, for `activate!`'s reason: the floor depends on the account,
  ;; and a claim is single-use — so a weak password must be refused while the link
  ;; is still good. The endpoint's own check can only apply the BASELINE (it has no
  ;; account yet), and this is where the higher floor for an operator's reset is
  ;; enforced. `mailed-token-holder` is the read half of the claim, in the same
  ;; order, so a token it answers for is one the claim accepts a moment later.
  (define holder (mailed-token-holder conn raw #:purpose "reset"))
  (cond
    [(not holder) #f]
    [else
     (require-password! conn holder pw)
     (define uid (claim-mailed-token! conn raw #:purpose "reset"))
     (cond
       [(not uid) #f]
       ;; RE-CHECKED AT REDEMPTION, not trusted from the request. An account can be
       ;; suspended in the hour between asking and clicking, and the token outlives
       ;; that change — so the state is read now. It is spent either way: a token
       ;; that failed this check must not be presentable again.
       [(not (active-user? conn uid)) #f]
       [else
        (set-password! conn uid pw)
        (define revoked (revoke-user-sessions! conn uid))
        (login-lock-clear! conn (username-of conn uid))
        (define tid (first-team-for conn uid))
        (define tok
          (and (not (has-second-factor? conn uid))
               (let-values ([(t _t) (issue-token! conn #:user uid #:team tid
                                                  #:name "login" #:scopes '("*:*")
                                                  #:kind SESSION-KIND)])
                 t)))
        (audit! conn #:action "user.password.reset"
                #:actor-type "user" #:actor-id uid
                #:resource-type "user" #:resource-id uid
                #:meta (format "{\"sessions_revoked\":~a,\"second_factor\":~a}"
                               revoked (if tok "false" "true")))
        (values uid revoked tok)])]))

(define (active-user? conn uid)
  (equal? (let ([v (query-maybe-value conn "SELECT status FROM users WHERE id = ?" uid)])
            (and v (not (sql-null? v)) (format "~a" v)))
          "active"))

(define (username-of conn uid)
  (define v (query-maybe-value conn "SELECT username FROM users WHERE id = ?" uid))
  (if (and v (not (sql-null? v))) (format "~a" v) ""))
