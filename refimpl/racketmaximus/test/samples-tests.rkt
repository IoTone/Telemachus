#lang racket/base

;; test/samples-tests.rkt — the Admin "Load sample data" seed.
;; raco test test/samples-tests.rkt

(require rackunit
         db
         db-kit/migrate
         "../domain/db/migrations.rkt"
         "../domain/authz/authz.rkt"
         "../domain/samples/samples.rkt")

(define (fresh) (define c (sqlite3-connect #:database 'memory)) (migrate! c all-migrations) c)

(test-case "seed-samples! populates notes, documents, and queued jobs for the team"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice"))
  (define alice (user-principal c uid tid))
  (define r (seed-samples! c alice))
  (check-equal? (hash-ref r 'notes) 3)
  (check-equal? (hash-ref r 'documents) 2)
  (check-equal? (hash-ref r 'jobs) 3)
  (check-equal? (query-value c "SELECT COUNT(*) FROM notes WHERE team_id=?" tid) 3)
  (check-equal? (query-value c "SELECT COUNT(*) FROM documents WHERE team_id=?" tid) 2)
  (check-equal? (query-value c "SELECT COUNT(*) FROM jobs WHERE team_id=? AND status='queued'" tid) 3)
  (check-true (for/or ([k (in-list (query-list c "SELECT kind FROM jobs WHERE team_id=?" tid))]) (equal? k "agent"))))
