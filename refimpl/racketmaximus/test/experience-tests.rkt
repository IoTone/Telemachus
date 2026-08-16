#lang racket/base

;; test/experience-tests.rkt — admin-editable onboarding experience (slice 40):
;; storage + draft/publish precedence, RBAC, judge-prompt stripping, and the ENV
;; launch-defaults path (TELEMACHUS_ONBOARDING_FILE). raco test test/experience-tests.rkt

(require rackunit
         db json racket/file
         db-kit/migrate
         "../domain/db/migrations.rkt"
         "../domain/authz/authz.rkt"
         "../domain/beta/beta.rkt"
         "../domain/beta/experience.rkt")

(define (fresh) (define c (sqlite3-connect #:database 'memory)) (migrate! c all-migrations) c)

(test-case "resolve falls back to the base experience; public slice hides the judge prompt"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice"))
  ;; no DB row yet → base (registered provider) is served
  (define eff (resolve-experience c tid))
  (check-equal? (hash-ref eff 'name) "beta")
  (check-true (pair? (hash-ref eff 'fields)))
  (check-true (string? (hash-ref eff 'judge-system)))            ; base carries the prompt
  ;; the public slice never leaks it
  (define pub (resolve-experience-public c tid))
  (check-false (hash-has-key? pub 'judge-system))
  (check-true (pair? (hash-ref pub 'fields))))

(test-case "draft → publish: DB wins over base only once published"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice"))
  (define alice (user-principal c uid tid))
  (define base-title (hash-ref (resolve-experience c tid) 'title))

  ;; save a draft with a changed title
  (check-true (experience-save! c alice (hasheq 'name "beta" 'title "Our Private Beta"
                                                'subtitle "hi" 'fields '() 'judge-system "j")))
  ;; serving is unchanged until publish
  (check-equal? (hash-ref (resolve-experience c tid) 'title) base-title)
  ;; but the editor sees the draft
  (check-equal? (hash-ref (experience-draft c alice) 'title) "Our Private Beta")

  ;; publish → serving now reflects the DB row
  (check-true (experience-publish! c alice))
  (check-equal? (hash-ref (resolve-experience c tid) 'title) "Our Private Beta")
  (check-false (hash-has-key? (resolve-experience-public c tid) 'judge-system))
  ;; the experience list shows both rows
  (check-equal? (length (experience-list c alice)) 2))

(test-case "publish with no draft is a no-op"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice"))
  (define alice (user-principal c uid tid))
  (check-false (experience-publish! c alice)))

(test-case "RBAC: a viewer cannot read or edit the experience"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice"))
  (define bob (create-user! c #:username "bob"))
  (add-member! c #:user bob #:team tid #:role "viewer")
  (define v (user-principal c bob tid))
  (check-exn exn:fail:forbidden? (lambda () (experience-draft c v)))
  (check-exn exn:fail:forbidden? (lambda () (experience-save! c v (hasheq 'name "beta"))))
  (check-exn exn:fail:forbidden? (lambda () (experience-publish! c v))))

(test-case "ENV launch defaults: TELEMACHUS_ONBOARDING_FILE seeds the base (judge_system normalized)"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice"))
  (define f (make-temporary-file "tmx-onb-~a.json"))
  (dynamic-wind
    (lambda ()
      (call-with-output-file f #:exists 'replace
        (lambda (o) (write-json (hasheq 'name "beta" 'title "ENV Beta" 'subtitle "from env"
                                        'fields (list (hasheq 'key "email" 'label "Email" 'type "email" 'required #t))
                                        'judge_system "env judge prompt") o)))
      (putenv "TELEMACHUS_ONBOARDING_FILE" (path->string f)))
    (lambda ()
      ;; base picks up ENV overrides; judge_system is normalized to 'judge-system
      (check-equal? (hash-ref (base-experience) 'title) "ENV Beta")
      (check-equal? (hash-ref (base-experience) 'judge-system) "env judge prompt")
      ;; served on first boot with no DB row
      (check-equal? (hash-ref (resolve-experience c tid) 'title) "ENV Beta")
      (check-equal? (experience-judge-system c tid) "env judge prompt")
      (check-false (hash-has-key? (resolve-experience-public c tid) 'judge-system)))
    (lambda ()
      (putenv "TELEMACHUS_ONBOARDING_FILE" "")
      (delete-file f))))
