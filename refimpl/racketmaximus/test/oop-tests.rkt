#lang racket/base

;; test/oop-tests.rkt — sandboxed out-of-process plugins: registration, the
;; capability API, and its double gate (declared scope ∩ caller RBAC).
;; Uses the real example plugin (oop-plugins/notes-helper).  raco test test/oop-tests.rkt

(require rackunit
         racket/runtime-path
         racket/file
         json
         db-kit/portable
         db-kit/migrate
         "../domain/oop/host.rkt"
         "../domain/agent/registry.rkt"
         "../domain/agent/run.rkt"           ; dispatch-tool
         "../domain/notes/notes.rkt"
         "../domain/db/migrations.rkt"
         "db-fixture.rkt"
         "../domain/authz/authz.rkt")

(define-runtime-path helper "../oop-plugins/notes-helper/main.rkt")
(define (fresh) (define c (fresh-db #:migrate? #f)) (migrate! c all-migrations) c)

(define (write-cfg path)
  (call-with-output-file path #:exists 'replace
    (lambda (o) (write-json (hasheq 'plugins (list (hasheq 'name "notes-helper" 'command "racket"
                                                           'args (list (path->string helper))))) o))))

(test-case "oop plugin: registers a tool, runs out-of-process, saves a note via the capability API"
  (define conn (fresh))
  (define-values (uid tid) (bootstrap! conn #:username "alice"))
  (define alice (user-principal conn uid tid))
  (define cfg (make-temporary-file "tmx-oop-~a.json"))
  (write-cfg cfg)
  (connect-oop-plugins! cfg)
  (define t (tool-by-name "oop__notes-helper__save_idea"))
  (check-true (and t #t))
  (check-equal? (tool-source t) "oop:notes-helper")
  (check-true (for/or ([pl (in-list (loaded-oop-plugins))]) (equal? (hash-ref pl 'name) "notes-helper")))
  ;; dispatch the plugin tool → it asks the host to create a note; the note appears
  (define out (dispatch-tool conn alice "oop__notes-helper__save_idea" (hasheq 'idea "ship telemachus")))
  (check-regexp-match #rx"Saved your idea as private note" out)
  (check-true (for/or ([n (in-list (notes-list conn alice))])
                (and (string=? (hash-ref n 'body) "ship telemachus")
                     (string=? (hash-ref n 'visibility) "private"))))
  (delete-file cfg))

(test-case "oop capability API: double gate — declared scope ∩ caller RBAC"
  (define conn (fresh))
  (define-values (uid tid) (bootstrap! conn #:username "alice"))
  (define alice (user-principal conn uid tid))                 ; has notes:write
  (define dave (create-user! conn #:username "dave"))
  (add-member! conn #:user dave #:team tid #:role "viewer")    ; read-only
  (define pdave (user-principal conn dave tid))
  ;; scope declared + caller authorized → runs
  (check-true (hash-has-key? (run-capability '("notes:write") conn alice "notes.create" (hasheq 'title "T" 'body "B")) 'ok))
  ;; plugin never declared the scope → denied even for a privileged caller
  (check-regexp-match #rx"not granted scope"
                      (hash-ref (run-capability '() conn alice "notes.create" (hasheq 'body "B")) 'error))
  ;; caller lacks the RBAC permission → denied even though the plugin declared the scope
  (check-regexp-match #rx"permission denied"
                      (hash-ref (run-capability '("notes:write") conn pdave "notes.create" (hasheq 'body "B")) 'error))
  ;; capability not in the host's whitelist → denied
  (check-regexp-match #rx"unknown capability"
                      (hash-ref (run-capability '("anything") conn alice "shell.exec" (hasheq)) 'error)))
