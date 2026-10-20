#lang racket/base

;; test/instance-features-tests.rkt — issue #63: a feature switch above the team.
;;
;;   raco test test/instance-features-tests.rkt
;;   DATABASE_URL="postgres://…" raco test test/instance-features-tests.rkt
;;
;; The one decision this file has to pin is the RESOLUTION ORDER, which #63 asked
;; to be made deliberately: a team may tighten what a layer above allows and may
;; never loosen it. Everything else follows from that.

(require rackunit db-kit/portable
         db-kit/migrate
         "../domain/db/migrations.rkt"
         "db-fixture.rkt"
         "../domain/authz/authz.rkt"
         "../domain/features/features.rkt")

(define (fresh)
  (define c (fresh-db #:migrate? #f))
  (migrate! c all-migrations)
  c)

(define (setup c)
  (define-values (u team)
    (bootstrap! c #:username "root" #:org-name "Acme" #:org-slug "acme"
                #:team-name "Engineering" #:team-slug "engineering"))
  (values u team (team-org c team)))

;; ---- 1. nothing configured behaves exactly as before ----------------------------
(test-case "absence means enabled, at every layer"
  (define c (fresh))
  (define-values (u team org) (setup c))
  (for ([f (in-list known-features)])
    (check-true (feature-enabled? c team f) f))
  ;; and the listing says nothing about WHY, because nothing is off
  (for ([row (in-list (features-for c team))])
    (check-true (hash-ref row 'enabled))
    (check-false (hash-has-key? row 'disabled_by)
                 "`disabled_by` is absent when the feature is on, never reported as a layer"))
  (close-db! c))

;; ---- 2. each layer can turn a feature off, and the listing NAMES which ----------
(test-case "the team layer still works, and says it was the team"
  (define c (fresh))
  (define-values (u team org) (setup c))
  (set-feature-enabled! c team "search" #f)
  (check-false (feature-enabled? c team "search"))
  (check-equal? (feature-scope c team "search") "team")
  (close-db! c))

(test-case "the org layer turns it off for its teams"
  (define c (fresh))
  (define-values (u team org) (setup c))
  (org-features-set! c org (hasheq 'translate #f))
  (check-false (feature-enabled? c team "translate"))
  (check-equal? (feature-scope c team "translate") "org")
  ;; …and only that feature
  (check-true (feature-enabled? c team "search"))
  (close-db! c))

(test-case "the instance layer turns it off everywhere"
  (define c (fresh))
  (define-values (u team org) (setup c))
  (instance-features-set! c (hasheq 'agent #f))
  (check-false (feature-enabled? c team "agent"))
  (check-equal? (feature-scope c team "agent") "instance")
  (close-db! c))

;; ---- 3. THE DECISION: tighten only, and the order the layers are named in -------
(test-case "a team cannot loosen what the instance disabled"
  (define c (fresh))
  (define-values (u team org) (setup c))
  (instance-features-set! c (hasheq 'workflows #f))
  ;; the team's own row says ON — and it does not matter
  (set-feature-enabled! c team "workflows" #t)
  (check-false (feature-enabled? c team "workflows")
               "the instance owns the floor; this is the whole point of having one")
  (check-equal? (feature-scope c team "workflows") "instance")
  (close-db! c))

(test-case "an org cannot loosen what the instance disabled"
  (define c (fresh))
  (define-values (u team org) (setup c))
  (instance-features-set! c (hasheq 'chat #f))
  (org-features-set! c org (hasheq 'chat #t))
  (check-false (feature-enabled? c team "chat"))
  (check-equal? (feature-scope c team "chat") "instance")
  (close-db! c))

(test-case "the layer NAMED is the furthest one that objects"
  (define c (fresh))
  (define-values (u team org) (setup c))
  ;; all three disable it at once, which is a legitimate state
  (instance-features-set! c (hasheq 'search #f))
  (org-features-set! c org (hasheq 'search #f))
  (set-feature-enabled! c team "search" #f)
  ;; The one an operator cannot change from where they are standing comes first:
  ;; a team admin reading "instance" knows not to look in their own settings,
  ;; which is the whole value of the field.
  (check-equal? (feature-scope c team "search") "instance")
  ;; peel the layers back and the answer moves outward-in
  (instance-features-set! c (hasheq))
  (check-equal? (feature-scope c team "search") "org")
  (org-features-set! c org (hasheq))
  (check-equal? (feature-scope c team "search") "team")
  (set-feature-enabled! c team "search" #t)
  (check-true (feature-enabled? c team "search"))
  (close-db! c))

;; ---- 4. a team's own OFF survives the instance flipping back --------------------
(test-case "a team's own decision is remembered under a layer that also says no"
  (define c (fresh))
  (define-values (u team org) (setup c))
  (set-feature-enabled! c team "agent" #f)
  (instance-features-set! c (hasheq 'agent #f))
  (check-equal? (feature-scope c team "agent") "instance")
  ;; the instance changes its mind; the team's own intention still stands
  (instance-features-set! c (hasheq))
  (check-false (feature-enabled? c team "agent")
               "turning the instance switch back on must not silently re-enable a team that opted out")
  (check-equal? (feature-scope c team "agent") "team")
  (close-db! c))

;; ---- 5. an unknown feature is REFUSED, not stored -------------------------------
(test-case "an unknown feature, and a non-boolean, are refused"
  (define c (fresh))
  (check-true (string? (feature-problem (hasheq 'nosuchthing #f)))
              "a flag that silently does nothing is how an operator concludes it is broken")
  (check-true (string? (feature-problem (hasheq 'chat "yes"))) "only true or false")
  (check-true (string? (feature-problem '())) "a document must be an object")
  (check-false (feature-problem (hasheq 'chat #f)))
  (check-false (feature-problem (hasheq)) "an empty document is a valid 'nothing disabled'")
  (check-exn exn:fail? (lambda () (instance-features-set! c (hasheq 'nope #f))))
  ;; …and the refusal left nothing behind
  (check-equal? (instance-features c) (hasheq))
  (close-db! c))

;; ---- 6. a stored TRUE is not the same as absence, and neither blocks ------------
(test-case "only an explicit false blocks; true and absent both allow"
  (define c (fresh))
  (define-values (u team org) (setup c))
  (instance-features-set! c (hasheq 'chat #t))
  (check-true (feature-enabled? c team "chat")
              "`true` is a layer saying it does not object, which is not the same as not deciding")
  (close-db! c))

;; ---- 7. an instance with no orgs at all ------------------------------------------
(test-case "a team with no org skips the org layer rather than failing"
  (define c (fresh))
  ;; single-tenant bootstrap: `team-org` answers #f
  (define-values (u team) (bootstrap! c #:username "solo"))
  (check-true (feature-enabled? c team "chat"))
  (instance-features-set! c (hasheq 'chat #f))
  (check-equal? (feature-scope c team "chat") "instance")
  (close-db! c))
