#lang racket/base

;; test/plugin-tests.rkt — load a third-party plugin from the manifest dir and
;; verify it registers, is tracked, and dispatches.  raco test test/plugin-tests.rkt

(require rackunit
         racket/runtime-path
         db
         db-kit/migrate
         "../domain/db/migrations.rkt"
         "../domain/authz/authz.rkt"
         "../domain/agent/registry.rkt"
         "../domain/agent/run.rkt"          ; dispatch-tool (also registers built-ins)
         "../domain/agent/plugins.rkt"
         "../domain/beta/beta.rkt")         ; onboarding registry (populated by an init! plugin)

(define-runtime-path plugins-dir "../plugins")
(define (fresh) (define c (sqlite3-connect #:database 'memory)) (migrate! c all-migrations) c)

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
