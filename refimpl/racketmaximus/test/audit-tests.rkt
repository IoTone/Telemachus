#lang racket/base

;; test/audit-tests.rkt — audit-log surfacing.  raco test test/audit-tests.rkt

(require rackunit db-kit/portable
         db-kit/migrate
         "../domain/db/migrations.rkt"
         "db-fixture.rkt"
         "../domain/authz/authz.rkt")

(define (fresh) (define c (fresh-db #:migrate? #f)) (migrate! c all-migrations) c)

(test-case "audit-list returns recent team events, newest first"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice"))     ; writes a 'bootstrap' entry
  (audit! c #:action "note.create" #:actor-type "user" #:actor-id uid #:team-id tid
          #:resource-type "notes" #:resource-id "n1")
  (define es (audit-list c tid))
  (check-true (>= (length es) 2))
  (check-true (for/or ([e (in-list es)]) (equal? (hash-ref e 'action) "bootstrap")))
  (check-true (for/or ([e (in-list es)])                           ; note.create carried its resource
                (and (equal? (hash-ref e 'action) "note.create") (equal? (hash-ref e 'resource_id) "n1"))))
  ;; another team's events are not visible
  (define other (create-team! c #:name "Other" #:slug "other"))
  (check-equal? (length (audit-list c other)) 0))
