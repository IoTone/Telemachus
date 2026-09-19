#lang racket/base

;; test/plugin-tests.rkt — load a third-party plugin from the manifest dir and
;; verify it registers, is tracked, and dispatches.  raco test test/plugin-tests.rkt

(require rackunit
         racket/runtime-path
         db-kit/portable
         db-kit/migrate
         "../domain/db/migrations.rkt"
         "db-fixture.rkt"
         "../domain/authz/authz.rkt"
         "../domain/agent/registry.rkt"
         "../domain/agent/run.rkt"          ; dispatch-tool (also registers built-ins)
         "../domain/agent/plugins.rkt"
         "../domain/beta/beta.rkt"          ; onboarding registry (populated by an init! plugin)
         "../domain/sched/scheduler.rkt")

(define-runtime-path plugins-dir "../plugins")
(define (fresh) (define c (fresh-db #:migrate? #f)) (migrate! c all-migrations) c)

(test-case "plugin loads from manifest dir: registered, tracked, dispatches"
  (load-plugins! plugins-dir)
  (define wc (tool-by-name "word_count"))
  (check-true (and wc #t))
  (check-equal? (tool-source wc) "example-tools")            ; tagged with plugin id
  (check-true (for/or ([p (in-list (loaded-plugins))]) (string=? (hash-ref p 'id) "example-tools")))
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice"))
  (check-equal? (dispatch-tool c (user-principal c uid tid) "word_count" (hasheq 'text "one two three")) "3 words"))

(test-case "init! hook: an SDK plugin registers an onboarding provider"
  (load-plugins! plugins-dir)
  (check-true (and (member "founders" (onboarding-names)) #t)))   ; from plugins/beta-onboarding

;; ---- a plugin's job kinds (issue #21) ----------------------------------------

(test-case "init! registers a job kind in the plugin's namespace, and it runs like a core one"
  (load-plugins! plugins-dir)
  (check-true (and (member "x.example-tools.word-count" (registered-job-kinds)) #t)
              "the example plugin's kind is registered")
  (check-true (for/or ([p (in-list (loaded-plugins))])
                (and (string=? (hash-ref p 'id) "example-tools")
                     (member "x.example-tools.word-count" (hash-ref p 'job_kinds '()))
                     #t))
              "…and is reported against the plugin that registered it")
  ;; it is an ordinary scheduler job: same team, same cap, same claim
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice"))
  (define j (enqueue-job! c #:team tid #:user uid #:kind "x.example-tools.word-count"
                          #:payload (hasheq 'text "one two three")))
  (check-equal? (process-one! c) j)
  (define done (get-job c j tid))
  (check-equal? (hash-ref done 'status) "done")
  (check-equal? (hash-ref (hash-ref done 'result) 'words) 3))

(test-case "a plugin may not name a kind outside its own prefix, or take one twice"
  (check-exn #rx"must be named x[.]acme[.]"
             (lambda () (parameterize ([current-plugin "acme"])
                          (register-job-kind! "flow.step" (lambda (c p pl) (hasheq))))))
  (check-exn #rx"must be named x[.]acme[.]"
             (lambda () (parameterize ([current-plugin "acme"])
                          (register-job-kind! "x.other.thing" (lambda (c p pl) (hasheq))))))
  (check-exn #rx"must be named x[.]acme[.]"
             (lambda () (parameterize ([current-plugin "acme"])          ; the prefix alone is not a name
                          (register-job-kind! "x.acme." (lambda (c p pl) (hasheq))))))
  ;; inside its prefix it is allowed, and registering it again is not an error —
  ;; the loader may run twice in one process and a reload must not fail the plugin
  (parameterize ([current-plugin "acme"])
    (register-job-kind! "x.acme.thing" (lambda (c p pl) (hasheq)))
    (register-job-kind! "x.acme.thing" (lambda (c p pl) (hasheq))))
  (check-equal? (job-kinds-of-plugin "acme") '("x.acme.thing"))
  ;; …but a name someone else already owns is refused
  (register-job-kind! "x.taken.already" (lambda (c p pl) (hasheq)))          ; core's
  (check-exn #rx"already registered"
             (lambda () (parameterize ([current-plugin "taken"])
                          (register-job-kind! "x.taken.already" (lambda (c p pl) (hasheq))))))
  ;; the core registers under its own names, as before
  (register-job-kind! "core.kind" (lambda (c p pl) (hasheq)))
  (check-true (and (member "core.kind" (registered-job-kinds)) #t)))

(test-case "a remote kind must carry a validator"
  (check-exn #rx"needs #:validate"
             (lambda () (register-job-kind! "x.acme.remote" #f #:remote? #t)))
  (register-job-kind! "x.acme.remote" #f #:remote? #t #:validate (lambda (r) #f))
  (check-true (remote-kind? "x.acme.remote")))
