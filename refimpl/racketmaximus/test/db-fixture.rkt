#lang racket/base

;; test/db-fixture.rkt — one migrated, isolated database per test, on either dialect.
;;
;; Unit tests used to hardcode `(sqlite3-connect #:database 'memory)`, which meant
;; the whole suite could only ever prove things about SQLite. Two real Postgres bugs
;; had to be found the slow way — through the HTTP smoke suites — because of it.
;; Now the same tests run against either backend:
;;
;;   raco test test/*-tests.rkt                                   # in-memory SQLite (default, fast)
;;   DATABASE_URL=postgres://u@host:5432/db raco test test/*-tests.rkt
;;
;; ISOLATION is the whole problem. `:memory:` gives every connection a private,
;; empty database for free; a Postgres database is shared by every test file in the
;; run — and `raco test` runs them concurrently. So each fixture gets its OWN SCHEMA
;; and a `search_path` pointing at it. Unqualified DDL from the migrations lands
;; there, and two tests cannot see each other's rows any more than two in-memory
;; SQLite connections can.
;;
;; `#:shared` covers the one case where two connections must see the SAME data — the
;; workflow test that proves a run resumes in a second process. On SQLite that is a
;; file instead of `:memory:`; on Postgres it is the same schema twice. The test does
;; not have to know which.
;;
;; The Postgres database is DISPOSABLE: schemas are dropped by `close-db!`, but a
;; test that never disconnects simply leaves one behind. Drop and recreate the
;; database between runs — which you must do anyway, because `bootstrap!` is
;; first-run-only.

(require db db-kit db-kit/migrate racket/string racket/file
         "../domain/db/migrations.rkt"
         "../domain/db/id.rkt")

(provide fresh-db close-db! fixture-dialect postgres-fixture?)

(define (url) (getenv "DATABASE_URL"))

(define (postgres-fixture?)
  (define u (url))
  (and u (regexp-match? #rx"^postgres(?:ql)?://" u) #t))

(define (fixture-dialect) (if (postgres-fixture?) 'postgresql 'sqlite))

;; a schema name Postgres will accept unquoted, unique per fixture
(define (new-schema-name)
  (string-append "tmxtest_" (string-replace (new-id) "-" "")))

;; The schema (Postgres) or file (SQLite) backing a `#:shared` key, so a second
;; `fresh-db` with the same key reopens the SAME data rather than a fresh one.
(define shared-backing (make-hash))

;; -> a connection with every migration applied.
;;
;;   #:shared k    two calls with the same k share one database (see above)
;;   #:migrate? #f apply nothing — for tests that replay migrations themselves
;;                 (the tenancy upgrade test builds an older world first)
(define (fresh-db #:shared [shared #f] #:migrate? [migrate? #t])
  (define conn
    (cond
      [(postgres-fixture?)
       (define c ((db-connector (url))))
       (define schema
         (cond
           [(and shared (hash-ref shared-backing shared #f)) => values]
           [else (let ([s (new-schema-name)])
                   (when shared (hash-set! shared-backing shared s))
                   (query-exec c (string-append "CREATE SCHEMA IF NOT EXISTS " s))
                   s)]))
       ;; every unqualified name in the migrations and the app resolves here
       (query-exec c (string-append "SET search_path TO " schema))
       c]
      [shared
       ;; SQLite: a real file, so a second connection sees the first one's writes
       (define path
         (cond [(hash-ref shared-backing shared #f) => values]
               [else (let ([p (make-temporary-file "telemachus-shared-~a.db")])
                       (delete-file p)          ; let sqlite create it
                       (hash-set! shared-backing shared p)
                       p)]))
       (sqlite3-connect #:database path #:mode 'create)]
      [else (sqlite3-connect #:database 'memory)]))
  (when migrate? (migrate! conn all-migrations))
  conn)

;; Drop what this fixture created, then disconnect. Safe to call on either dialect
;; and safe to skip — an undropped schema in a disposable test database costs
;; nothing.
(define (close-db! conn)
  (when (and conn (not (eq? (fixture-dialect) 'sqlite)))
    (with-handlers ([exn:fail? void])
      (define s (query-maybe-value conn "SELECT current_schema()"))
      (when (and (string? s) (string-prefix? s "tmxtest_"))
        ;; leave the search_path pointing somewhere valid while we drop
        (query-exec conn "SET search_path TO public")
        (query-exec conn (string-append "DROP SCHEMA IF EXISTS " s " CASCADE")))))
  (with-handlers ([exn:fail? void]) (disconnect conn)))
