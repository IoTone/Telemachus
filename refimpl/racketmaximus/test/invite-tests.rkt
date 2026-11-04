#lang racket/base

;; test/invite-tests.rkt — asking somebody to join, by email (INVITE-1…8).
;;
;; EVERY HELPER IS DEFINED BEFORE ITS FIRST USE.

(require rackunit db-kit/portable db-kit/migrate
         racket/string racket/list
         "../domain/db/migrations.rkt"
         "db-fixture.rkt"
         "../domain/authz/authz.rkt"
         "../domain/authz/mailed-tokens.rkt"
         "../domain/mail/transport.rkt"
         "../domain/mail/addresses.rkt"
         "../domain/mail/mail.rkt"
         "../domain/accounts/invite.rkt"
         "../domain/saas/onboarding.rkt")

(define (fresh) (define c (fresh-db #:migrate? #f)) (migrate! c all-migrations) c)

(define (configure! c)
  (transport-set! c (hasheq 'host "127.0.0.1" 'port 2525 'security "none"
                            'from_address "tmach@example.test" 'from_name "TMach"
                            'base_url "https://tmach.example.test" 'active #t)))

(define (seed! c)
  (define-values (uid tid)
    (bootstrap! c #:username "alice" #:org-name "Acme" #:org-slug "acme"
                #:team-name "Acme" #:team-slug "acme"))
  (values uid tid))

(define (deliveries c)
  (query-rows c "SELECT recipient, category, subject, body FROM email_deliveries ORDER BY created_epoch"))

(define (invite-body c)
  (define rs (query-rows c "SELECT body FROM email_deliveries WHERE category = 'invite'"))
  (and (pair? rs) (format "~a" (vector-ref (car rs) 0))))

(define (token-from-message c)
  (check-equal? (query-value c "SELECT COUNT(*) FROM email_deliveries WHERE category = 'invite'") 1
                "exactly one invitation, or 'the latest' is ambiguous")
  (define b (invite-body c))
  (define m (and b (regexp-match #px"activate\\?token=([^#\\s]+)" b)))
  (and m (cadr m)))

(define (status-of c uid)
  (format "~a" (query-value c "SELECT status FROM users WHERE id = ?" uid)))

(define (clear-deliveries! c) (query-exec c "DELETE FROM email_deliveries"))

(define (audit-actions c)
  (map (lambda (r) (format "~a" (vector-ref r 0)))
       (query-rows c "SELECT action FROM audit_log ORDER BY at_us")))

;; ---- what an invitation creates ---------------------------------------------

(test-case "INVITE-2: the account is created `invited` and cannot sign in"
  (define c (fresh))
  (configure! c)
  (define-values (aid tid) (seed! c))
  (define res (call-with-values
               (lambda () (invite-member! c #:team tid #:role "member"
                                          #:address "bob@example.test"
                                          #:inviter aid #:inviter-name "Alice"
                                          #:team-name "Acme"))
               list))
  (define uid (car res))
  (check-equal? (cadr res) 'queued)
  (check-equal? (status-of c uid) "invited")
  ;; `authenticate` admits `status = 'active'` alone, so even a password set by
  ;; some other path cannot sign this account in before it is accepted.
  (set-password! c uid "guessed-somehow")
  (check-false (authenticate c "bob@example.test" "guessed-somehow"))
  (close-db! c))

(test-case "INVITE-5: the username defaults to the address, and may be given"
  (define c (fresh))
  (configure! c)
  (define-values (aid tid) (seed! c))
  (define-values (u1 o1 l1)
    (invite-member! c #:team tid #:role "member" #:address "bob@example.test"
                    #:inviter aid))
  (check-equal? (format "~a" (query-value c "SELECT username FROM users WHERE id = ?" u1))
                "bob@example.test")
  (define-values (u2 o2 l2)
    (invite-member! c #:team tid #:role "member" #:address "carol@example.test"
                    #:username "carol" #:inviter aid))
  (check-equal? (format "~a" (query-value c "SELECT username FROM users WHERE id = ?" u2)) "carol")
  (close-db! c))

(test-case "MAIL-5: the address is PENDING, never written to users.email"
  ;; `users.email` holds a VERIFIED address and nothing else (PULL-11e): a field
  ;; a reader learns to distrust is worse than no field. So an invitation's
  ;; address waits in `email_verifications` until the redemption promotes it.
  (define c (fresh))
  (configure! c)
  (define-values (aid tid) (seed! c))
  (define-values (uid o l)
    (invite-member! c #:team tid #:role "member" #:address "bob@example.test" #:inviter aid))
  (check-true (sql-null? (query-value c "SELECT email FROM users WHERE id = ?" uid)))
  (check-true (sql-null? (query-value c "SELECT email_verified_epoch FROM users WHERE id = ?" uid)))
  (define p (address-pending c uid))
  (check-true (hash? p))
  (check-equal? (hash-ref p 'address) "bob@example.test")
  (close-db! c))

(test-case "INVITE-4: redeeming the invitation verifies the address"
  ;; Receiving the link is the same proof a confirmation token carries, arriving
  ;; in a different envelope — so one message does both jobs and nobody is asked
  ;; to confirm an address they have just demonstrated they can read.
  (define c (fresh))
  (configure! c)
  (define-values (aid tid) (seed! c))
  (define-values (uid o l)
    (invite-member! c #:team tid #:role "member" #:address "bob@example.test" #:inviter aid))
  (define tok (token-from-message c))
  (check-true (string? tok))
  (define res (call-with-values (lambda () (activate! c #:token tok #:password "bobs-password")) list))
  (check-equal? (car res) uid)
  (check-equal? (status-of c uid) "active")
  ;; the address is now verified, and nothing is pending
  (check-equal? (user-address c uid) "bob@example.test")
  (check-false (address-pending c uid))
  ;; and the account really can sign in with the password it chose
  (check-equal? (authenticate c "bob@example.test" "bobs-password") uid)
  (close-db! c))

(test-case "the message says who invited whom, and to what"
  ;; THE ONE PLACE "ids, never content" IS RELAXED, and deliberately: an
  ;; invitation that will not say who sent it or what it is for is one a careful
  ;; person is right to discard as phishing.
  (define c (fresh))
  (configure! c)
  (define-values (aid tid) (seed! c))
  (void (call-with-values
         (lambda () (invite-member! c #:team tid #:role "member" #:address "bob@example.test"
                                    #:inviter aid #:inviter-name "Alice Smith" #:team-name "Acme Civil"))
         list))
  (define d (car (deliveries c)))
  (define subject (format "~a" (vector-ref d 2)))
  (define body (format "~a" (vector-ref d 3)))
  (check-equal? (format "~a" (vector-ref d 1)) "invite")
  (check-true (regexp-match? #px"Alice Smith" body))
  (check-true (regexp-match? #px"Acme Civil" body))
  (check-true (regexp-match? #px"Alice Smith" subject))
  (check-true (regexp-match? #px"activate\\?token=" body))
  ;; it still has to be safe to ignore
  (check-true (regexp-match? #px"(?i:no account is)" body))
  (close-db! c))

(test-case "INVITE-5: with no transport the link comes back instead"
  ;; An invitation nobody can act on is worse than one delivered by hand —
  ;; `provision!`'s precedent. It is returned ONLY in that case: a token that was
  ;; mailed has one copy and one reader.
  (define c (fresh))
  (define-values (aid tid) (seed! c))
  (define-values (uid outcome link)
    (invite-member! c #:team tid #:role "member" #:address "bob@example.test" #:inviter aid))
  (check-equal? outcome 'no-transport)
  (check-true (string? link))
  (check-equal? (length (deliveries c)) 0)
  ;; and it really is the token that works
  (define res (call-with-values (lambda () (activate! c #:token link #:password "bobs-password")) list))
  (check-equal? (car res) uid)
  (close-db! c))

(test-case "a mailed invitation does NOT hand the token back"
  (define c (fresh))
  (configure! c)
  (define-values (aid tid) (seed! c))
  (define-values (uid outcome link)
    (invite-member! c #:team tid #:role "member" #:address "bob@example.test" #:inviter aid))
  (check-equal? outcome 'queued)
  (check-false link)
  (close-db! c))

(test-case "an invitation is transactional, so no category gates it"
  (define c (fresh))
  (configure! c)
  (define-values (aid tid) (seed! c))
  (check-true (and (member "invite" TRANSACTIONAL-CATEGORIES) #t))
  (define-values (uid o l)
    (invite-member! c #:team tid #:role "member" #:address "bob@example.test" #:inviter aid))
  ;; the instance has enabled NO category, which is the shipped default
  (check-equal? (length (deliveries c)) 1)
  (close-db! c))

(test-case "a malformed address is refused before anything is created"
  (define c (fresh))
  (configure! c)
  (define-values (aid tid) (seed! c))
  (define before (query-value c "SELECT COUNT(*) FROM users"))
  (check-exn exn:fail? (lambda ()
    (invite-member! c #:team tid #:role "member" #:address "not-an-address" #:inviter aid)))
  (check-equal? (query-value c "SELECT COUNT(*) FROM users") before)
  (check-true (string? (invite-problem "not-an-address")))
  (check-true (string? (invite-problem 42)))
  (check-false (invite-problem "bob@example.test"))
  (close-db! c))

;; ---- sending it again -------------------------------------------------------

(test-case "INVITE-6: an invitation can be sent again, and the old link dies"
  (define c (fresh))
  (configure! c)
  (define-values (aid tid) (seed! c))
  (define-values (uid o l)
    (invite-member! c #:team tid #:role "member" #:address "bob@example.test" #:inviter aid))
  (define first-tok (token-from-message c))
  (clear-deliveries! c)
  (define-values (o2 l2) (resend-invitation! c uid #:inviter aid))
  (check-equal? o2 'queued)
  (define second-tok (token-from-message c))
  (check-true (string? second-tok))
  (check-false (equal? first-tok second-tok))
  ;; ONE SLOT PER PURPOSE: re-minting retires the previous link, which is what
  ;; somebody who pressed "send it again" expects.
  (check-false (claim-mailed-token! c first-tok #:purpose "activate"))
  (check-equal? (claim-mailed-token! c second-tok #:purpose "activate") uid)
  (close-db! c))

(test-case "INVITE-6: resending is refused for an account that has accepted"
  ;; On an ACTIVE account this would mint a link that sets a password, which is a
  ;; password reset — and that has its own route, throttle, horizon and
  ;; enumeration-safe answer.
  (define c (fresh))
  (configure! c)
  (define-values (aid tid) (seed! c))
  (define-values (uid o l)
    (invite-member! c #:team tid #:role "member" #:address "bob@example.test" #:inviter aid))
  (void (call-with-values
         (lambda () (activate! c #:token (token-from-message c) #:password "bobs-password")) list))
  (check-equal? (status-of c uid) "active")
  (check-equal? (resend-invitation! c uid #:inviter aid) 'not-invited)
  (close-db! c))

(test-case "resending an unknown member answers #f rather than raising"
  (define c (fresh))
  (configure! c)
  (define-values (aid tid) (seed! c))
  (check-false (resend-invitation! c "no-such-user" #:inviter aid))
  (close-db! c))

(test-case "both events are audited, and name the team"
  ;; `audit-list` filters `WHERE team_id = ?`, so a membership event without one
  ;; is invisible to the team whose membership changed — the shape these notes
  ;; record eight times.
  (define c (fresh))
  (configure! c)
  (define-values (aid tid) (seed! c))
  (define-values (uid o l)
    (invite-member! c #:team tid #:role "member" #:address "bob@example.test" #:inviter aid))
  (clear-deliveries! c)
  (void (call-with-values (lambda () (resend-invitation! c uid #:inviter aid)) list))
  (define acts (audit-actions c))
  (check-true (and (member "member.invited" acts) #t))
  (check-true (and (member "member.invite.resent" acts) #t))
  (define teams (map (lambda (r) (format "~a" (vector-ref r 0)))
                     (query-rows c (string-append "SELECT team_id FROM audit_log "
                                                  "WHERE action IN ('member.invited','member.invite.resent')"))))
  (check-equal? (remove-duplicates teams) (list tid))
  (close-db! c))
