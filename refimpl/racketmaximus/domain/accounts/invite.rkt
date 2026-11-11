#lang racket/base

;; domain/accounts/invite.rkt — asking somebody to join, by email (INVITE-1…8).
;;
;; `POST /api/members` has taken a USERNAME and answered with a `*:*` session
;; token for the new account, handed to the person who made the call. That is a
;; perfectly good scripted path and it is not onboarding: it means the inviter
;; holds a credential for somebody else's account, and it cannot reach anybody
;; who is not already sitting next to them.
;;
;; An `email` in the body is what asks for an invitation instead. BOTH planes
;; that add people have that form (`POST /api/members` and
;; `POST /api/org/members`), and both go through this module, so "what an
;; invitation is" has one home however the caller reached it.
;;
;; WHAT AN INVITATION ANSWERS WITH IS NOT A SESSION, and that is now the rule for
;; BOTH forms: a created account is never handed a token for itself. The caller
;; sets a password or sends an invitation, and either way the person signs in
;; with their own credential.

(require db-kit/portable
         racket/string
         "../authz/authz.rkt"            ; create-user!/add-member!/audit!
         "../authz/mailed-tokens.rkt"    ; mint-mailed-token!
         "../mail/addresses.rkt"         ; address-claim!
         "../mail/transport.rkt"         ; transport-configured!/mail-address-problem
         "../mail/mail.rkt")             ; mail-enqueue-invitation!

(provide INVITE-TTL-HOURS invite-member! resend-invitation! invite-problem invite-answer)

;; THREE DAYS, where a reset gets an hour and a verification a day. An
;; invitation is the one mailed link whose recipient was not expecting it and is
;; not waiting at their keyboard — somebody invited on a Friday should still be
;; able to join on Monday. It is bounded at all because an invitation is a
;; standing offer of access to a team, and one that never expires is a standing
;; offer nobody remembers making.
(define INVITE-TTL-HOURS 72)

(define (invite-problem address)
  (cond
    [(not (string? address)) "an email address is required"]
    [(mail-address-problem (string-trim address)) => values]
    [else #f]))

;; ---- who the message says it is from, and about ------------------------------
;;
;; THE MESSAGE NAMES THE INVITER AND THE TEAM, and that is the ONE place this
;; subsystem relaxes "ids, never content": an invitation that will not say who
;; sent it or what it is for is one a careful person is right to discard as
;; phishing. The lookup lives HERE rather than once per endpoint because both
;; planes compose this message — a second copy is how the team plane and the
;; company plane would come to word the same invitation differently.
(define (display-name-of conn user-id)
  (define r (query-maybe-row conn "SELECT display_name, username FROM users WHERE id = ?" user-id))
  (cond
    [(not r) "An administrator"]
    [(and (not (sql-null? (vector-ref r 0))) (not (equal? (format "~a" (vector-ref r 0)) "")))
     (format "~a" (vector-ref r 0))]
    [else (format "~a" (vector-ref r 1))]))

(define (team-name-of conn team-id)
  (define v (query-maybe-value conn "SELECT name FROM teams WHERE id = ?" team-id))
  (if (and v (not (sql-null? v))) (format "~a" v) "your team"))

;; -> (values user-id outcome link-or-#f)
;;
;; outcome: 'queued when a message is on its way, 'no-transport when the instance
;; cannot send one.
;;
;; WITH NO TRANSPORT THE LINK IS HANDED BACK TO THE INVITER (INVITE-5), which is
;; `provision!`'s precedent and the only honest answer: an invitation nobody can
;; act on is worse than one delivered by hand. It is returned ONLY in that case —
;; a token that was mailed has one copy and one reader, and putting a second in a
;; JSON response the inviter may paste anywhere would give it two.
;;
;; THE ACCOUNT IS CREATED `invited` AND SETS ITS OWN PASSWORD (INVITE-2).
;; `authenticate` admits `status = 'active'` alone, so an unredeemed invitee
;; cannot sign in; `activate!` is what makes them real, and it is also what
;; proves the address, since receiving the link is that proof (INVITE-4). So one
;; message does both jobs and nobody is asked to confirm an address they have
;; just demonstrated they can read.
(define (invite-member! conn #:team team #:role role #:address address
                        #:username [username #f] #:inviter inviter-user-id
                        #:inviter-name [inviter-name #f] #:team-name [team-name #f]
                        #:org [org-id #f] #:org-role [org-role #f])
  (define addr (string-trim (format "~a" address)))
  (define p (invite-problem addr))
  (when p (raise-user-error 'invite p))
  ;; THE USERNAME DEFAULTS TO THE ADDRESS, which is what `provision!` has always
  ;; done and what makes the invitation one field. An explicit one is accepted
  ;; because a deployment may want a username that is not an address, and because
  ;; usernames are instance-global (TEN-2b) while an address may legitimately be
  ;; reused across instances.
  (define uname (if (and username (not (equal? (format "~a" username) ""))) (format "~a" username) addr))
  ;; THE COMPANY AND ITS ORG ROLE ARE SET AT CREATION when the caller has them,
  ;; which is the company plane's whole difference. `users.org_id` is what
  ;; `caller-org` answers with, so an invitee created without it would join an
  ;; org's team while belonging to no company — and every org-tier route would
  ;; then answer for the wrong tier, or for none.
  (define uid (create-user! conn #:username uname #:org org-id #:org-role org-role))
  ;; `create-user!` defaults the status to 'active' — the column's own default
  ;; since 0001 — so an invitation has to say otherwise EXPLICITLY. Without this
  ;; line an invited person could sign in the moment somebody set a password for
  ;; them, which is the state the invitation exists to avoid.
  (query-exec conn "UPDATE users SET status = 'invited', updated_at = CURRENT_TIMESTAMP WHERE id = ?" uid)
  (add-member! conn #:user uid #:team team #:role role)
  ;; The address is PENDING, not verified: `users.email` holds a verified address
  ;; and nothing else (MAIL-5/PULL-11e), so it waits in `email_verifications`
  ;; until the redemption promotes it. `address-claim!` answers TWO values, so a
  ;; bare call is an arity error and not a discard.
  (define-values (_vtok _a) (address-claim! conn uid addr))
  (define tok (mint-mailed-token! conn uid INVITE-TTL-HOURS #:purpose "activate"))
  (define sendable? (transport-configured? conn))
  (when sendable?
    (mail-enqueue-invitation! conn #:user uid #:address addr #:token tok
                              #:team-name (or team-name (team-name-of conn team))
                              #:inviter (or inviter-name (display-name-of conn inviter-user-id))
                              #:ttl-hours INVITE-TTL-HOURS))
  (audit! conn #:action "member.invited" #:actor-type "user" #:actor-id inviter-user-id
          #:team-id team #:resource-type "user" #:resource-id uid
          #:result (if sendable? "queued" "no-transport"))
  (values uid (if sendable? 'queued 'no-transport) (and (not sendable?) tok)))

;; The reply an invitation answers with, built HERE so the two planes that add
;; people cannot disagree about what an invitation says. NO SESSION IS IN IT
;; (INVITE-1): the invitee proves the mailbox and chooses their own password, so
;; the inviter holds no credential for an account they did not create for
;; themselves.
;;
;; `activation_token` is present ONLY on an instance with no transport, where the
;; link comes back so it can be handed over. The note says which case this is,
;; because "nothing was sent" reading as success is the failure this avoids.
(define (invite-answer uid uname role org-role outcome link)
  (hasheq 'user_id uid 'username uname 'role role
          'org_role (or org-role 'null)
          'status "invited" 'invited #t
          'queued (eq? outcome 'queued)
          'note (if (eq? outcome 'queued)
                    "An invitation is on its way. The account cannot sign in until it is accepted."
                    "This instance has no email transport configured, so nothing was sent. Hand this link over yourself; it is shown once.")
          'activation_token (or link 'null)))

;; Send it again (INVITE-6). Without this an expired invitation leaves somebody
;; unreachable except through an operator's password reset, which is the thing
;; this whole slice exists to stop needing — and re-posting the invitation is a
;; 409, because the username already exists.
;;
;; -> (values outcome token-or-#f), or #f when there is nobody to re-invite.
;;
;; ONLY AN `invited` ACCOUNT, and that is a refusal rather than a convenience: on
;; an ACTIVE account this would mint a link that sets a password, which is a
;; password reset — and a reset has its own route, its own throttle, its own
;; shorter horizon and an enumeration-safe answer. Offering it here under a
;; members permission would be a second way to do it with none of those.
(define (resend-invitation! conn uid #:inviter inviter-user-id
                            #:inviter-name [inviter-name #f] #:team-name [team-name #f])
  (define row (query-maybe-row conn
                (string-append "SELECT u.status, m.team_id FROM users u "
                               "LEFT JOIN memberships m ON m.user_id = u.id AND m.status = 'active' "
                               "WHERE u.id = ?")
                uid))
  (cond
    [(not row) #f]
    [(not (equal? (format "~a" (vector-ref row 0)) "invited")) 'not-invited]
    [else
     (define team (let ([t (vector-ref row 1)]) (and (not (sql-null? t)) (format "~a" t))))
     ;; The address comes from the PENDING row, which is where an invitation put
     ;; it — never from `users.email`, which is empty by construction until the
     ;; redemption promotes it.
     (define pend (address-pending conn uid))
     (cond
       [(not pend) 'no-address]
       [else
        (define addr (hash-ref pend 'address))
        ;; Re-claiming REPLACES the pending row, which also renews its expiry —
        ;; `address-claim!`'s own rule, and what somebody who pressed "send it
        ;; again" expects.
        (define-values (_vtok _a) (address-claim! conn uid addr))
        (define tok (mint-mailed-token! conn uid INVITE-TTL-HOURS #:purpose "activate"))
        (define sendable? (transport-configured? conn))
        (when sendable?
          (mail-enqueue-invitation! conn #:user uid #:address addr #:token tok
                                    #:team-name (or team-name (team-name-of conn team))
                                    #:inviter (or inviter-name (display-name-of conn inviter-user-id))
                                    #:ttl-hours INVITE-TTL-HOURS))
        (audit! conn #:action "member.invite.resent" #:actor-type "user" #:actor-id inviter-user-id
                #:team-id (or team sql-null) #:resource-type "user" #:resource-id uid
                #:result (if sendable? "queued" "no-transport"))
        (values (if sendable? 'queued 'no-transport) (and (not sendable?) tok))])]))
