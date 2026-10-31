#lang racket/base

;; db-kit — turn a SQLAlchemy-style sqlite DATABASE_URL into a Racket `db`
;; connection. App-agnostic; raises plain `error` on problems so the caller's
;; own error handling (e.g. cli-kit's run harness) can present it.
;;
;;   (require db-kit)
;;   (call-with-sqlite (sqlite-path "sqlite:///./data/app.db" #:base-dir root)
;;                     (lambda (c) (query-rows c "SELECT 1")))
;;
;; Only sqlite is handled for now (the prototyping default). A Postgres/MySQL
;; backend would extend THIS package, not the app — keep callers backend-neutral.

(require db racket/string)

(provide sqlite-path open-sqlite call-with-sqlite
         db-connector postgres-params redact-db-url)

;; SIX COERCION HELPERS LIVED HERE and are gone (#110 r4): sql-or-empty,
;; sql-or-null, sql->str, sql->bool, sql->int and sqlite-datetime->iso.
;; db-kit/portable superseded them — it rewrites the query and hands back values
;; the caller converts at the edge of its own read, which since #110 r5 is
;; domain/db/nulls.rkt. Nothing in the tree called any of the six.

;; Resolve a sqlite URL to a filesystem path, mirroring SQLAlchemy's
;; `DATABASE_URL.replace("sqlite:///", "")`. Relative paths resolve against
;; base-dir.
(define (sqlite-path url #:base-dir [base-dir (current-directory)])
  (unless (string-prefix? url "sqlite:")
    ;; REDACTED, and `redact-db-url`'s own header two screens below is the rule
    ;; this was breaking: "never print or error on the raw string". The one URL
    ;; that reaches this refusal is a NON-sqlite one, i.e. exactly the postgres
    ;; case that carries `user:PASS@host` — so of the three places a DATABASE_URL
    ;; is formatted into a message, the one that could only ever be handed a
    ;; credential was the one that did not mask it. ENC-23's shape (a rule stated
    ;; in a header and bypassed by one path) and FEED-6's (#186, SEC-6).
    (error 'sqlite-path "only sqlite URLs are supported, got: ~a" (redact-db-url url)))
  (define raw (regexp-replace #rx"^sqlite:///" url ""))   ; "./data/app.db" | "/abs" | "C:\\abs"
  ;; absolute-path? is platform-aware: matches POSIX "/x" AND Windows "C:\x"/"C:/x".
  ;; (A leading-"/" test mis-classifies Windows drive paths as relative, joining
  ;; them onto base-dir → broken DB path. This bit every DB CLI on Windows.)
  (if (absolute-path? raw)
      (simplify-path (string->path raw))
      (simplify-path (build-path base-dir raw))))

;; Open the db. By default fails loudly if it doesn't exist rather than silently
;; creating an empty one (#:create-missing? #t to allow creation).
(define (open-sqlite path #:mode [mode 'read/write] #:create-missing? [create? #f])
  (unless (or create? (file-exists? path))
    (error 'open-sqlite "database not found at ~a" path))
  ;; sqlite's 'read/write and 'read-only both REQUIRE the file to exist; only
  ;; 'create makes a missing file. So when creating is allowed, use 'create.
  (sqlite3-connect #:database path #:mode (if create? 'create mode)))

(define (call-with-sqlite path proc
                          #:mode [mode 'read/write]
                          #:create-missing? [create? #f])
  (define conn (open-sqlite path #:mode mode #:create-missing? create?))
  (dynamic-wind void
                (lambda () (proc conn))
                (lambda () (disconnect conn))))

;; A DATABASE_URL carries its password in the clear (scheme://user:PASS@host/db).
;; Never print or error on the raw string — mask the credential and leave the
;; rest, so a boot log or an error message never puts a real password on disk.
;; Works even on a URL that fails to parse otherwise (a plain string replace),
;; and is a no-op when there's no user:pass@ segment to find.
(define (redact-db-url url)
  (regexp-replace #rx"^([a-zA-Z][a-zA-Z0-9+.-]*://[^:/@]*):[^@/]*@" url "\\1:***@"))

;; ---- backend dispatch: sqlite OR postgres from one DATABASE_URL --------------
;; postgres://[user[:pass]@]host[:port]/dbname   (or postgresql://…)
(define (postgres-params url)
  (define m (regexp-match #rx"^postgres(?:ql)?://(?:([^:@/]+)(?::([^@/]+))?@)?([^:/@]+)(?::([0-9]+))?/(.+)$" url))
  (unless m (error 'db-connector "malformed postgres URL: ~a" (redact-db-url url)))
  (hasheq 'user     (or (list-ref m 1) "postgres")
          'password (list-ref m 2)                         ; #f = no password
          'server   (list-ref m 3)
          'port     (if (list-ref m 4) (string->number (list-ref m 4)) 5432)
          'database (list-ref m 5)))

;; Resolve a DATABASE_URL to a *connector thunk* (opens a fresh connection each
;; call — suitable for connection-pool). Backend-neutral: the app never branches.
(define (db-connector url #:base-dir [base-dir (current-directory)])
  (cond
    [(string-prefix? url "sqlite:")
     (define path (sqlite-path url #:base-dir base-dir))
     (lambda () (sqlite3-connect #:database path #:mode 'create))]
    [(regexp-match? #rx"^postgres(?:ql)?://" url)
     (define P (postgres-params url))
     (lambda () (postgresql-connect #:user (hash-ref P 'user) #:database (hash-ref P 'database)
                                    #:server (hash-ref P 'server) #:port (hash-ref P 'port)
                                    #:password (hash-ref P 'password)))]
    [else (error 'db-connector "unsupported DATABASE_URL (need sqlite:/// or postgres://): ~a" (redact-db-url url))]))
