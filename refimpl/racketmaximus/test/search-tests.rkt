#lang racket/base

;; test/search-tests.rkt — keyword search across notes + translations, RBAC-filtered.
;; raco test test/search-tests.rkt

(require rackunit
         db
         db-kit/migrate
         "../domain/db/migrations.rkt"
         "../domain/authz/authz.rkt"
         "../domain/notes/notes.rkt"
         "../domain/apps/search.rkt"
         "../domain/db/id.rkt")

(define (fresh) (define c (sqlite3-connect #:database 'memory)) (migrate! c all-migrations) c)

(test-case "search matches notes + translations; RBAC filters private notes and gates translations"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice"))
  (define alice (user-principal c uid tid))
  (notes-create c alice #:title "Quarterly plan" #:body "launch the platform" #:visibility "team")
  (notes-create c alice #:title "Secret" #:body "hidden treasure" #:visibility "private")
  (query-exec c
    "INSERT INTO translations (id,team_id,owner_user_id,source_lang,target_lang,source_text,result_text) VALUES (?,?,?,?,?,?,?)"
    (new-id) tid uid "auto" "ja" "hello world" "こんにちは世界")

  (check-true (for/or ([x (in-list (search-all c alice "plan"))])
                (and (equal? (hash-ref x 'type) "note") (equal? (hash-ref x 'title) "Quarterly plan"))))
  (check-true (for/or ([x (in-list (search-all c alice "hello"))])
                (equal? (hash-ref x 'type) "translation")))

  ;; a viewer: cannot read alice's private note, and lacks chat:use → no translations
  (define bob (create-user! c #:username "bob"))
  (add-member! c #:user bob #:team tid #:role "viewer")
  (define pbob (user-principal c bob tid))
  (check-false (for/or ([x (in-list (search-all c pbob "hidden"))]) (equal? (hash-ref x 'title) "Secret")))
  (check-equal? (length (search-all c pbob "hello")) 0))
