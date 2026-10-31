#lang racket/base

;; test/dbkit-tests.rkt — the PostgreSQL-portability logic: the ?→$n placeholder
;; rewriter and the postgres:// URL parser. (Live Postgres E2E needs a running
;; server, which isn't available in this environment; the SQLite path is covered by
;; the full suite, which stays green after the portability sweep.)
;; raco test test/dbkit-tests.rkt

(require rackunit db-kit            ; postgres-params, redact-db-url
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

(test-case "redact-db-url: the password never survives, everything else does"
  (check-equal? (redact-db-url "postgres://alice:secret@db.example.com:6543/telemachus")
                "postgres://alice:***@db.example.com:6543/telemachus")
  (check-equal? (redact-db-url "postgresql://u:p$s#99@host/db")       ; password with odd-but-legal chars
                "postgresql://u:***@host/db")
  (check-equal? (redact-db-url "postgres://localhost/mydb")           ; no credentials: unchanged
                "postgres://localhost/mydb")
  (check-equal? (redact-db-url "postgres://alice@host/db")            ; user, no password: unchanged
                "postgres://alice@host/db")
  (check-equal? (redact-db-url "sqlite:///./data/app.db")             ; not even a network URL
                "sqlite:///./data/app.db")
  (check-equal? (redact-db-url "not a url at all, just : and @ chars")  ; malformed input: no crash, no match
                "not a url at all, just : and @ chars"))

;; ---- what a refusal may say about a DATABASE_URL (#186, SEC-6) --------------
;;
;; `redact-db-url`'s own header says "never print or error on the raw string" and
;; THREE places did: this function, and the `with-db` message in
;; `telemachus-anchor` and `telemachus-help`. The one here is the sharpest,
;; because the only URL that can reach this refusal is a NON-sqlite one — i.e.
;; exactly the postgres case that carries `user:PASS@host`. A rule stated in a
;; header and bypassed by one path is ENC-23's shape.

(test-case "sqlite-path's refusal redacts the credential it was necessarily handed"
  (define msg
    (with-handlers ([exn:fail? exn-message])
      (sqlite-path "postgres://alice:s3cr3t@db.internal:6543/telemachus")))
  (check-true (string? msg) "a non-sqlite URL is refused")
  (check-false (regexp-match? #rx"s3cr3t" msg)
               "the password must not reach the log, the terminal or a sealed column")
  ;; and the rest survives, or the operator cannot see WHICH url was wrong —
  ;; which is the whole reason this is a redaction and not a removal
  (check-true (and (regexp-match? #rx"db.internal" msg) #t) "the host is still named")
  (check-true (and (regexp-match? #rx"telemachus" msg) #t) "and the database"))

(test-case "…and a sqlite URL is still resolved, so the guard did not become the answer"
  ;; the control for the case above: a version that refused everything, or one
  ;; that redacted by dropping the string, would pass the refutations alone.
  (check-true (path? (sqlite-path "sqlite:///./data/app.db" #:base-dir (current-directory)))))
