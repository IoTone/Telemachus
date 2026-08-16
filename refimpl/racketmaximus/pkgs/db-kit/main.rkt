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
         sql-or-empty sql-or-null sql->str sql->bool sql->int sqlite-datetime->iso
         db-connector postgres-params)

;; ---- SQL value coercion helpers (shared by DB-backed CLIs) -----------------
(define (sql-or-empty v) (if (sql-null? v) "" v))         ; NULL -> ""
(define (sql-or-null  v) (if (sql-null? v) 'null v))      ; NULL -> JSON null
(define (sql->str v) (if (sql-null? v) "" (format "~a" v)))
(define (sql->bool v) (cond [(sql-null? v) #f]
                            [(number? v) (not (zero? v))]
                            [else (and v #t)]))
(define (sql->int v) (cond [(sql-null? v) 0] [(number? v) v] [else 0]))

;; SQLAlchemy stores DateTime in SQLite as TEXT "YYYY-MM-DD HH:MM:SS[.ffffff]".
;; Match Python's datetime.isoformat(): space->T, and drop a zero ".000000"
;; fraction (isoformat omits microseconds when they're zero). NULL -> "".
(define (sqlite-datetime->iso v)
  (cond [(sql-null? v) ""]
        [(not (string? v)) (format "~a" v)]
        [else (regexp-replace #rx"\\.000000$"
                              (regexp-replace #rx" " v "T") "")]))

;; Resolve a sqlite URL to a filesystem path, mirroring SQLAlchemy's
;; `DATABASE_URL.replace("sqlite:///", "")`. Relative paths resolve against
;; base-dir.
(define (sqlite-path url #:base-dir [base-dir (current-directory)])
  (unless (string-prefix? url "sqlite:")
    (error 'sqlite-path "only sqlite URLs are supported, got: ~a" url))
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

;; ---- backend dispatch: sqlite OR postgres from one DATABASE_URL --------------
;; postgres://[user[:pass]@]host[:port]/dbname   (or postgresql://…)
(define (postgres-params url)
  (define m (regexp-match #rx"^postgres(?:ql)?://(?:([^:@/]+)(?::([^@/]+))?@)?([^:/@]+)(?::([0-9]+))?/(.+)$" url))
  (unless m (error 'db-connector "malformed postgres URL: ~a" url))
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
    [else (error 'db-connector "unsupported DATABASE_URL (need sqlite:/// or postgres://): ~a" url)]))
