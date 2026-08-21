#lang racket/base

;; test/samples-tests.rkt — the Admin "Load sample data" seed.
;; raco test test/samples-tests.rkt

(require racket/file
         rackunit
         db-kit/portable
         db-kit/migrate
         "../domain/db/migrations.rkt"
         "db-fixture.rkt"
         "../domain/repo/blobs.rkt"
         "../domain/authz/authz.rkt"
         "../domain/samples/samples.rkt")

;; seeded documents write blobs; keep them out of the checkout
(define BLOB-ROOT (make-temporary-file "telemachus-samples-blobs-~a" 'directory))
(current-blob-root BLOB-ROOT)

(define (fresh) (define c (fresh-db #:migrate? #f)) (migrate! c all-migrations) c)

(test-case "seed-samples! populates notes, documents, and queued jobs for the team"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice"))
  (define alice (user-principal c uid tid))
  (define r (seed-samples! c alice))
  (check-equal? (hash-ref r 'notes) 3)
  (check-equal? (hash-ref r 'documents) 2)
  (check-equal? (hash-ref r 'jobs) 3)
  (check-equal? (query-value c "SELECT COUNT(*) FROM notes WHERE team_id=?" tid) 3)
  ;; documents are repository objects since migration 0022
  (check-equal? (query-value c
     "SELECT COUNT(*) FROM repo_objects WHERE team_id=? AND key LIKE 'documents/%' AND deleted_at IS NULL" tid) 2)
  (check-equal? (query-value c "SELECT COUNT(*) FROM jobs WHERE team_id=? AND status='queued'" tid) 3)
  (check-true (for/or ([k (in-list (query-list c "SELECT kind FROM jobs WHERE team_id=?" tid))]) (equal? k "agent"))))

(delete-directory/files BLOB-ROOT #:must-exist? #f)
