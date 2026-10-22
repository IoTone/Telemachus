#lang racket/base

;; test/plugin-migration-tests.rkt — a plugin that owns data (issue #121).
;;
;; A plugin had no connection at load time, so one that keeps data worked around
;; it with `CREATE TABLE IF NOT EXISTS` on first use — which on PostgreSQL lost a
;; duplicate-key race in 1 of 6 rounds at 48 concurrent first requests, and then
;; needed a hand-rolled lock.
;;
;; The fix is NOT a connection in `init!`, which would move the race rather than
;; remove it: `load-plugins!` runs once per process, so two replicas run the DDL
;; concurrently anyway. `(provide migrations)` goes through the platform's own
;; ordered, recorded, transactional runner instead.
;;
;; What has to hold:
;;   1. a plugin's tables are created once and recorded under its own prefix
;;   2. a migration that names a table OUTSIDE that prefix fails the plugin's
;;      LOAD, not a request later — this is the check that makes data-owning
;;      plugins safe to allow at all
;;   3. re-running is a no-op, on both dialects
;;
;;   raco test test/plugin-migration-tests.rkt

(require rackunit racket/string db-kit/portable
         db-kit/migrate
         "../domain/db/migrations.rkt"
         "db-fixture.rkt"
         (only-in "../domain/agent/plugins.rkt" check-migrations! plugin-table-prefix))

(define (fresh) (define c (fresh-db #:migrate? #f)) (migrate! c all-migrations) c)

(define (bad? id spec)
  (with-handlers ([exn:fail? (lambda (e) (exn-message e))])
    (check-migrations! id spec)
    #f))

;; ---- 1. the happy path ------------------------------------------------------
(test-case "a plugin's migration is recorded under its own prefixed id"
  (define c (fresh))
  (define ms (check-migrations! "demo"
    (list (list "init" "CREATE TABLE x_demo_things (id TEXT PRIMARY KEY, n INTEGER NOT NULL)"
                       "CREATE INDEX x_demo_things_n ON x_demo_things (n)"))))
  (check-equal? (map migration-id ms) '("x.demo.init")
                "the platform-fixed prefix job kinds and routes already carry")
  (migrate! c ms)
  (query-exec c "INSERT INTO x_demo_things (id, n) VALUES ('a', 1)")
  (check-equal? (query-value c "SELECT COUNT(*) FROM x_demo_things") 1)
  ;; recorded in the platform's own ledger, which is what makes it run once
  (check-true (and (member "x.demo.init" (applied-migrations c)) #t))
  ;; 3. re-running is a no-op rather than an error
  (check-not-exn (lambda () (migrate! c ms)))
  (check-equal? (query-value c "SELECT COUNT(*) FROM x_demo_things") 1
                "the row survived, so the table was not recreated")
  (disconnect c))

(test-case "the prefix turns dashes into underscores, because SQL identifiers do"
  (check-equal? (plugin-table-prefix "doc-pipeline") "x_doc_pipeline_")
  (check-equal? (plugin-table-prefix "ocr") "x_ocr_"))

;; ---- 2. the check that makes this safe to allow -----------------------------
(test-case "a migration that touches a CORE table fails the plugin's load"
  ;; the whole reason `migrations` is data and not a thunk: a procedure could
  ;; create `users` and nothing could tell
  (define e (bad? "evil" (list (list "grab" "CREATE TABLE users (id TEXT)"))))
  (check-true (string? e) "it must raise, not be accepted")
  (check-true (string-contains? e "users"))
  (check-true (string-contains? e "x_evil_") "…and say what the name should start with"))

(test-case "…and so does one that alters, indexes or drops somebody else's"
  (for ([sql (in-list (list "ALTER TABLE api_tokens ADD COLUMN sneaky TEXT"
                            "CREATE INDEX idx_users_x ON users (id)"
                            "DROP TABLE repo_objects"
                            "CREATE TABLE x_other_plugin_t (id TEXT)"))])
    (check-true (string? (bad? "evil" (list (list "m" sql))))
                (format "must be refused: ~a" sql))))

(test-case "a schema-qualified name cannot sidestep the prefix"
  ;; `public.users` would match no prefix check written on the bare name
  (define e (bad? "evil" (list (list "grab" "CREATE TABLE public.x_evil_t (id TEXT)"))))
  (check-true (string? e))
  (check-true (string-contains? e "schema-qualified")))

(test-case "the shape itself is validated, so a typo fails the load"
  (check-true (string? (bad? "demo" "not-a-list")))
  (check-true (string? (bad? "demo" (list "not-a-list"))))
  (check-true (string? (bad? "demo" (list (list "only-a-name")))) "a migration needs a statement")
  (check-true (string? (bad? "demo" (list (list "name" 42)))) "statements must be strings")
  (check-true (string? (bad? "demo" (list (list "Bad Name" "CREATE TABLE x_demo_t (id TEXT)"))))
              "a name becomes part of a recorded id, so it is constrained")
  (check-false (bad? "demo" '()) "no migrations at all is the normal case and must be fine"))

(test-case "a statement that creates nothing is allowed through"
  ;; an INSERT of seed data, or a backfill UPDATE, names no new table — the check
  ;; is about what a plugin CREATES, not about forbidding every verb
  (check-false (bad? "demo" (list (list "seed" "CREATE TABLE x_demo_s (k TEXT)"
                                               "INSERT INTO x_demo_s (k) VALUES ('hello')")))))

;; ---- the interaction with the "migrated by a NEWER build" check -------------
;; Found by running it: the example plugin's first migration made a healthy
;; instance refuse to start with "this database was migrated by a NEWER
;; Telemachus". A plugin's id is not the platform's schema, and that check is
;; about the PLATFORM's build — old core code against a new core schema writes
;; rows the new code misreads. A plugin's table says nothing about that.
(require (only-in "../server/startup.rkt" schema-problem startup-problem-key))

(test-case "a plugin's applied migration does not read as a newer platform build"
  (define c (fresh))
  (migrate! c (check-migrations! "demo" (list (list "init" "CREATE TABLE x_demo_q (id TEXT)"))))
  (check-false (schema-problem c all-migrations)
               "`x.demo.init` is applied and unknown to all-migrations, and that is fine")
  ;; …and it must stay fine when the plugin is REMOVED, which is the same state:
  ;; refusing to boot because somebody uninstalled a plugin would be a new way to
  ;; take an instance down
  (check-false (schema-problem c all-migrations))
  ;; the check still works for a real one: a core id this build does not know
  (query-exec c "INSERT INTO schema_migrations (id) VALUES ('9999-from-the-future')")
  (define p (schema-problem c all-migrations))
  (check-true (and p #t) "a CORE id from a newer build is still caught")
  (check-equal? (startup-problem-key p) 'schema-ahead)
  (disconnect c))
