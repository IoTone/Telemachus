#lang racket/base

;; test/dbkit-tests.rkt — the PostgreSQL-portability logic: the ?→$n placeholder
;; rewriter and the postgres:// URL parser. (Live Postgres E2E needs a running
;; server, which isn't available in this environment; the SQLite path is covered by
;; the full suite, which stays green after the portability sweep.)
;; raco test test/dbkit-tests.rkt

(require rackunit db-kit            ; postgres-params
         db-kit/portable)  ; pg-rewrite

(test-case "pg-rewrite: ? -> $n, skipping quoted string literals"
  (check-equal? (pg-rewrite "SELECT * FROM t WHERE a = ? AND b = ?")
                "SELECT * FROM t WHERE a = $1 AND b = $2")
  (check-equal? (pg-rewrite "INSERT INTO t VALUES (?, ?, ?)")
                "INSERT INTO t VALUES ($1, $2, $3)")
  (check-equal? (pg-rewrite "SELECT '?', ? FROM t")          ; ? inside a literal untouched
                "SELECT '?', $1 FROM t")
  (check-equal? (pg-rewrite "SELECT 'a''b?', ?")             ; doubled '' escape handled
                "SELECT 'a''b?', $1")
  (check-equal? (pg-rewrite "SELECT 1") "SELECT 1"))         ; no placeholders unchanged

(test-case "postgres-params: parse connection URLs"
  (define p (postgres-params "postgres://alice:secret@db.example.com:6543/telemachus"))
  (check-equal? (hash-ref p 'user) "alice")
  (check-equal? (hash-ref p 'password) "secret")
  (check-equal? (hash-ref p 'server) "db.example.com")
  (check-equal? (hash-ref p 'port) 6543)
  (check-equal? (hash-ref p 'database) "telemachus")
  (define q (postgres-params "postgresql://localhost/mydb"))  ; no creds, default port, alt scheme
  (check-equal? (hash-ref q 'user) "postgres")
  (check-equal? (hash-ref q 'password) #f)
  (check-equal? (hash-ref q 'server) "localhost")
  (check-equal? (hash-ref q 'port) 5432)
  (check-equal? (hash-ref q 'database) "mydb"))
