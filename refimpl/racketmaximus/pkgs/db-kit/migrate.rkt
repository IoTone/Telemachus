#lang racket/base

;; db-kit/migrate — a minimal, ordered, idempotent migration runner.
;;
;; A migration is (migration id up), where `up` receives a live connection and
;; issues the schema changes. Applied ids are recorded in `schema_migrations`;
;; each migration runs once, inside a transaction. `up` may branch on dialect
;; later (sqlite today) — the runner itself is dialect-agnostic.
;;
;;   (migrate! conn (list (migration "0001-core" (lambda (c) (query-exec c "...")))))

(require db)

(provide (struct-out migration) migrate! applied-migrations pending-migrations)

(struct migration (id up) #:transparent)   ; up : (connection -> void)

(define (ensure-table! conn)
  (query-exec conn
    (string-append
     "CREATE TABLE IF NOT EXISTS schema_migrations ("
     "  id TEXT PRIMARY KEY,"
     "  applied_at TEXT NOT NULL DEFAULT CURRENT_TIMESTAMP)")))

;; ids of migrations already applied, in order
(define (applied-migrations conn)
  (ensure-table! conn)
  (query-list conn "SELECT id FROM schema_migrations ORDER BY id"))

;; migrations not yet applied, in declaration order
(define (pending-migrations conn migrations)
  (define done (applied-migrations conn))
  (for/list ([m (in-list migrations)] #:unless (member (migration-id m) done)) m))

;; apply all pending migrations, oldest first; each in its own transaction
(define (migrate! conn migrations #:log [log void])
  (define done (applied-migrations conn))
  (for ([m (in-list migrations)])
    (unless (member (migration-id m) done)
      (call-with-transaction conn
        (lambda ()
          ((migration-up m) conn)
          (query-exec conn "INSERT INTO schema_migrations (id) VALUES (?)" (migration-id m))))
      (log (migration-id m))))
  (void))
