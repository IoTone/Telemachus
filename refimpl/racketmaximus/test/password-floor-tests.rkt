#lang racket/base

;; test/password-floor-tests.rkt — ONE password floor, on every path (0.13.0).
;;
;; Before this the tree had three floors and a fourth path with none: 6 in the
;; change-password endpoint, 6 in the operator's reset, 6 in the mailed reset, 8 at
;; activation, and NOTHING when an account was created with a password — which
;; included the operator's own bootstrap. So the highest-privileged account on an
;; instance was the one whose password nothing checked.
;;
;; The rule is one function (`password-problem`) asked with one of two floors
;; (`password-floor`), and every write goes through `set-password!` or
;; `create-user!`, both of which enforce it. This file asserts each PATH, because
;; "the function is right" and "every path calls it" are different claims and the
;; second is the one that was false before.
;;
;; 12 FOR AN ACCOUNT THAT CAN CHANGE SOMEBODY ELSE'S CREDENTIAL, which on this
;; platform is `instance:manage` (the operator's password reset) or
;; `members:manage` (add members, set their roles). The test is by PERMISSION, so a
;; role built over the same permission gets the higher floor with no code change.
;;
;;   raco test test/password-floor-tests.rkt

(require rackunit racket/file racket/list racket/string
         db-kit/portable
         db-kit/migrate
         "../domain/db/migrations.rkt"
         "db-fixture.rkt"
         "../domain/authz/authz.rkt"
         "../domain/authz/passwords.rkt"
         "../domain/authz/mailed-tokens.rkt"
         "../domain/saas/onboarding.rkt"
         "../domain/accounts/reset.rkt")

(define (fresh)
  (define c (fresh-db #:migrate? #f))
  (migrate! c all-migrations)
  (seed-builtin-roles! c)
  c)

;; a team with an owner, and a member / an admin added to it
(define (scene)
  (define c (fresh))
  (define-values (owner-uid tid) (bootstrap! c #:username "owner" #:password "owner-password-1"))
  (define member-uid (create-user! c #:username "mem"))
  (add-member! c #:user member-uid #:team tid #:role "member")
  (define admin-uid (create-user! c #:username "adm"))
  (add-member! c #:user admin-uid #:team tid #:role "admin")
  (values c tid owner-uid member-uid admin-uid))

;; ---------------------------------------------------------------------------
;; 1. the rule itself
(test-case "password-problem: the baseline floor, and the privileged one"
  (check-false (password-problem "12345678"))
  (check-true (string? (password-problem "1234567")))
  (check-true (and (regexp-match? #rx"min 8" (password-problem "1234567")) #t))
  (check-false (password-problem "123456789012" MIN-PRIVILEGED-PASSWORD-LENGTH))
  (check-true (string? (password-problem "12345678901" MIN-PRIVILEGED-PASSWORD-LENGTH)))
  ;; the privileged message says WHY, or an operator reading it thinks the platform
  ;; is inconsistent with the 8 the dialog told them
  (check-true (and (regexp-match? #rx"min 12" (password-problem "12345678901" 12)) #t))
  (check-true (and (regexp-match? #rx"other people's credentials" (password-problem "12345678901" 12)) #t))
  ;; not a string is refused, never coerced
  (check-true (string? (password-problem #f)))
  (check-true (string? (password-problem 12345678))))

;; ---------------------------------------------------------------------------
;; 2. whose account is held to which floor
(test-case "password-floor: by PERMISSION, so an admin and an owner get 12 and a member 8"
  (define-values (c tid owner-uid member-member admin-uid) (scene))
  (check-equal? (password-floor c member-member) MIN-PASSWORD-LENGTH)
  (check-equal? (password-floor c admin-uid) MIN-PRIVILEGED-PASSWORD-LENGTH)   ; members:manage
  (check-equal? (password-floor c owner-uid) MIN-PRIVILEGED-PASSWORD-LENGTH)   ; owner, and an operator
  ;; and the role form, which is what an add-member has before a membership exists
  (check-equal? (password-floor-for-role c "member") MIN-PASSWORD-LENGTH)
  (check-equal? (password-floor-for-role c "admin") MIN-PRIVILEGED-PASSWORD-LENGTH)
  (check-equal? (password-floor-for-role c "owner") MIN-PRIVILEGED-PASSWORD-LENGTH)
  (check-equal? (password-floor-for-role c "no-such-role") MIN-PASSWORD-LENGTH))

;; ---------------------------------------------------------------------------
;; 3. path: the write itself, which every other path goes through
(test-case "set-password! refuses below the ACCOUNT's floor, whatever path called it"
  (define-values (c tid owner-uid member-member admin-uid) (scene))
  (check-exn exn:fail:user? (lambda () (set-password! c member-member "1234567")))
  (check-true (void? (set-password! c member-member "12345678")))
  (check-exn exn:fail:user? (lambda () (set-password! c admin-uid "12345678901")))
  (check-true (void? (set-password! c admin-uid "123456789012")))
  ;; the operator, whose permissions are not rows at all
  (check-exn exn:fail:user? (lambda () (set-password! c owner-uid "12345678")))
  ;; and the floor is checked BEFORE the hash: a refused password changes nothing,
  ;; which is also what keeps the old one working
  (check-true (equal? owner-uid (authenticate c "owner" "owner-password-1"))))

;; ---------------------------------------------------------------------------
;; 4. path: creation, where there was no floor at all
(test-case "create-user! holds a password given at creation — the hole this closes"
  (define c (fresh))
  ;; the bootstrap account IS an operator, and its password came through this
  ;; argument: 12, or the highest-privileged account is the easiest to guess
  (check-exn exn:fail:user? (lambda () (create-user! c #:username "op" #:operator? #t #:password "12345678901")))
  (check-true (string? (create-user! c #:username "op" #:operator? #t #:password "123456789012")))
  ;; an ordinary account is held to 8
  (check-exn exn:fail:user? (lambda () (create-user! c #:username "u" #:password "1234567")))
  (check-true (string? (create-user! c #:username "u2" #:password "12345678")))
  ;; and a user created with NO password (the invitation path) is untouched
  (check-true (string? (create-user! c #:username "invited"))))

;; ---------------------------------------------------------------------------
;; 5. path: a password change
(test-case "change-password! applies the caller's own floor and leaves the old one working"
  (define-values (c tid owner-uid member-member admin-uid) (scene))
  (set-password! c admin-uid "admin-password-1")
  ;; a short NEW password is refused for an admin, and the old one still works —
  ;; the refusal must not be a half-applied write
  (check-exn exn:fail:user?
             (lambda () (change-password! c admin-uid "admin-password-1" "12345678")))
  (check-true (and (authenticate c "adm" "admin-password-1") #t) "the old password is untouched")
  (check-true (change-password! c admin-uid "admin-password-1" "admin-password-2"))
  ;; a member is content with 8
  (set-password! c member-member "member-password-1")
  (check-true (change-password! c member-member "member-password-1" "12345678")))

;; ---------------------------------------------------------------------------
;; 6. path: activation, and the link must survive a refusal
(test-case "activate!: an invited ADMIN needs 12, and a refused password does NOT spend the link"
  (define c (fresh))
  (define-values (owner-uid tid) (bootstrap! c #:username "owner" #:password "owner-password-1"))
  (define uid (create-user! c #:username "newadmin"))
  (add-member! c #:user uid #:team tid #:role "admin")
  (define tok (mint-mailed-token! c uid 1 #:purpose "activate"))
  (check-exn exn:fail:user? (lambda () (activate! c #:token tok #:password "12345678")))
  ;; the link still works — this is the reason the floor is asked BEFORE the claim
  (define res (call-with-values (lambda () (activate! c #:token tok #:password "123456789012")) list))
  (check-true (and (string? (car res)) #t) "the same link redeems once the password is long enough")
  ;; a member invited on the same instance is content with 8
  (define uid2 (create-user! c #:username "newmember"))
  (add-member! c #:user uid2 #:team tid #:role "member")
  (define tok2 (mint-mailed-token! c uid2 1 #:purpose "activate"))
  (check-true (and (string? (car (call-with-values (lambda () (activate! c #:token tok2 #:password "12345678")) list))) #t)))

;; ---------------------------------------------------------------------------
;; 7. path: the mailed reset
(test-case "reset-password!: an operator's reset needs 12, and a refusal does not spend the link"
  (define-values (c tid owner-uid member-member admin-uid) (scene))
  (define tok (mint-mailed-token! c owner-uid 1 #:purpose "reset"))
  (check-exn exn:fail:user? (lambda () (reset-password! c #:token tok #:password "12345678")))
  (define res (call-with-values (lambda () (reset-password! c #:token tok #:password "123456789012")) list))
  (check-true (and (string? (car res)) #t) "the link survives the refusal")
  (check-true (equal? owner-uid (authenticate c "owner" "123456789012")))
  ;; a member's reset is content with 8
  (set-password! c member-member "member-password-1")
  (define tok2 (mint-mailed-token! c member-member 1 #:purpose "reset"))
  (check-true (and (string? (car (call-with-values (lambda () (reset-password! c #:token tok2 #:password "12345678")) list))) #t)))

;; ---------------------------------------------------------------------------
;; 8. the peek the two redemptions use
(test-case "mailed-token-holder answers the account, checks the purpose, and spends nothing"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "owner" #:password "owner-password-1"))
  (define tok (mint-mailed-token! c uid 1 #:purpose "reset"))
  (check-equal? (mailed-token-holder c tok #:purpose "reset") uid)
  ;; the wrong purpose is no answer, exactly as the claim refuses it
  (check-false (mailed-token-holder c tok #:purpose "activate"))
  (check-false (mailed-token-holder c "not-a-token" #:purpose "reset"))
  ;; and it did not spend it
  (check-equal? (claim-mailed-token! c tok #:purpose "reset") uid)
  (check-false (mailed-token-holder c tok #:purpose "reset") "…and after the claim the link is gone"))

;; ---------------------------------------------------------------------------
;; 9. the number is ONE home, not four
(test-case "no endpoint decides a password's length for itself any more"
  ;; The defect this closes was the same NUMBER written where it was needed, so
  ;; the check is that the old shape is gone from the surfaces: an inline
  ;; `(string-length new)`/`(string-length pw)` against a password. Asking
  ;; `password-problem` with a floor is the only allowed form.
  (for ([f (in-list '("../server/api/accounts.rkt" "../server/api/instance.rkt" "../server/api/orgs.rkt"))])
    (define s (file->string f))
    (check-false (regexp-match? #px"\\(string-length (new|pw|password)\\)" s)
                 (format "~a computes a password floor itself" f)))
  ;; and the two numbers live in exactly one place
  (define p (file->string "../domain/authz/passwords.rkt"))
  (check-true (and (regexp-match? #rx"MIN-PASSWORD-LENGTH 8" p) #t))
  (check-true (and (regexp-match? #rx"MIN-PRIVILEGED-PASSWORD-LENGTH 12" p) #t)))
