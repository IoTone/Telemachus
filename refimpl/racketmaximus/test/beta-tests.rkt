#lang racket/base

;; test/beta-tests.rkt — beta onboarding: public prospect capture, LLM-judge verdict,
;; owner review/decision, RBAC, and the pluggable onboarding provider registry.
;; raco test test/beta-tests.rkt

(require rackunit
         db
         db-kit/migrate
         "../domain/db/migrations.rkt"
         "../domain/authz/authz.rkt"
         "../domain/beta/beta.rkt")

(define (fresh) (define c (sqlite3-connect #:database 'memory)) (migrate! c all-migrations) c)

(test-case "prospect lifecycle: public create → owner list/judge/decide; RBAC-gated"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice"))
  (define alice (user-principal c uid tid))
  (check-equal? (default-team c) tid)
  (check-equal? (team-owner-id c tid) uid)

  (define pid (prospect-create! c #:team tid #:name "Dana" #:email "dana@acme.com"
                                #:company "Acme" #:use-case "team chat" #:revenue "$10M–$100M"))
  (check-equal? (length (prospect-list c alice)) 1)
  (check-equal? (hash-ref (car (prospect-list c alice)) 'status) "new")

  (set-prospect-judge! c pid (hasheq 'valid #t 'score 82 'revenue_estimate "$50M" 'reasoning "real co"))
  (define g (prospect-get c alice pid))
  (check-equal? (hash-ref g 'status) "reviewed")
  (check-equal? (hash-ref (hash-ref g 'judge) 'score) 82)

  (check-true (prospect-decide! c alice pid "qualified"))
  (check-equal? (hash-ref (prospect-get c alice pid) 'status) "qualified")
  (check-exn exn:fail? (lambda () (prospect-decide! c alice pid "maybe")))

  ;; a viewer cannot review the pipeline
  (define bob (create-user! c #:username "bob"))
  (add-member! c #:user bob #:team tid #:role "viewer")
  (check-exn exn:fail:forbidden? (lambda () (prospect-list c (user-principal c bob tid)))))

(test-case "onboarding provider registry (SDK seam)"
  (define cfg (onboarding-config))
  (check-equal? (hash-ref cfg 'name) "beta")
  (check-true (pair? (hash-ref cfg 'fields)))
  (check-true (string? (judge-system-prompt)))
  (register-onboarding! "custom" (hasheq 'name "custom" 'title "Custom" 'subtitle "" 'fields '() 'judge-system "judge X"))
  (check-true (and (member "custom" (onboarding-names)) #t)))
