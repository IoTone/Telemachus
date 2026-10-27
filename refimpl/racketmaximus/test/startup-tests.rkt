#lang racket/base

;; #128 job 2: operator-facing variables are read through ONE accessor,
;; which tries TMACH_<name> and falls back to TELEMACHUS_<name>.
(require (only-in "../config.rkt" tmach-env))

;; test/startup-tests.rkt — the checks an instance runs before it serves
;; (issue #89).  raco test test/startup-tests.rkt
;;
;; These exist as a unit test rather than a smoke assertion for the reason
;; test/peer-tests.rkt exists: a harness running on localhost with a writable
;; data directory satisfies every one of these by construction, so it can only
;; ever exercise the ALLOWED side. The refusals have to be stated here.

(require rackunit racket/file racket/list racket/string racket/port
         db-kit/portable db-kit/migrate
         "../domain/db/migrations.rkt"
         "db-fixture.rkt"
         "../server/startup.rkt")

(define (keys ps) (map startup-problem-key ps))
(define (sev ps k)
  (let ([p (findf (lambda (p) (eq? (startup-problem-key p) k)) ps)])
    (and p (startup-problem-severity p))))

;; ---- which addresses are private ---------------------------------------------

(test-case "loopback is the whole 127/8 block, ::1 and the name — 0.0.0.0 is not"
  (for ([ip (in-list '("127.0.0.1" "127.0.0.53" "127.1.2.3" "::1" "[::1]"
                       "localhost" "LOCALHOST" " 127.0.0.1 "))])
    (check-true (loopback-bind? ip) (format "~s is loopback" ip)))
  ;; 0.0.0.0 is EVERY interface, which is the case the TLS warning exists for —
  ;; and it is the value the container image sets, so getting this wrong would
  ;; either warn on every loopback dev run or never warn in production.
  (for ([ip (in-list '("0.0.0.0" "::" "10.0.0.5" "192.168.1.10" "100.64.1.2"
                       "203.0.113.7" "" #f))])
    (check-false (loopback-bind? ip) (format "~s is NOT loopback" ip))))

;; ---- the blob store ----------------------------------------------------------

(test-case "a writable root passes, and the probe leaves nothing behind"
  (define root (make-temporary-file "telemachus-startup-ok-~a" 'directory))
  (check-false (blob-store-problem root))
  ;; the probe file is deleted however the check exits — a directory that
  ;; accumulated one file per boot would be a slow, puzzling leak
  (check-equal? (filter (lambda (p) (regexp-match? #px"write-probe"
                                                   (path->string p)))
                        (directory-list root))
                '()))

(test-case "a root that cannot be created is an ERROR, naming what to set"
  ;; The parent is a FILE, so make-directory* cannot succeed — and unlike
  ;; chmod 000 this is true whatever uid the suite runs as, which matters
  ;; because `nix build` runs it as nixbld and a container may run it as root.
  (define f (make-temporary-file "telemachus-startup-file-~a"))
  (define bad (build-path f "blobs"))
  (define p (blob-store-problem bad))
  (check-true (startup-problem? p))
  (check-eq? (startup-problem-severity p) 'error)
  (check-eq? (startup-problem-key p) 'blob-store)
  ;; the message has to say what to change, not just what failed
  (check-true (regexp-match? #px"TMACH_DATA_DIR" (startup-problem-message p)))
  (delete-file f))

(test-case "a root that does not exist yet is CREATED, not refused"
  ;; First boot on a fresh volume: the directory is legitimately absent, and
  ;; refusing there would make every new deployment fail once.
  (define base (make-temporary-file "telemachus-startup-new-~a" 'directory))
  (define root (build-path base "deep" "nested" "blobs"))
  (check-false (blob-store-problem root))
  (check-true (directory-exists? root)))

;; ---- the schema -------------------------------------------------------------

(test-case "a fully migrated database is fine"
  (define c (fresh-db))
  (check-false (schema-problem c all-migrations))
  (close-db! c))

(test-case "a half-migrated database is schema-pending"
  (define c (fresh-db #:migrate? #f))
  (migrate! c (take all-migrations 3))
  (define p (schema-problem c all-migrations))
  (check-eq? (startup-problem-key p) 'schema-pending)
  (check-eq? (startup-problem-severity p) 'error)
  (close-db! c))

(test-case "a database migrated by a NEWER build refuses, and says to deploy it"
  ;; The dangerous direction, and the one nothing else in the system notices:
  ;; old code against a new schema writes rows the new code will misread. A
  ;; rolling deployment that half-rolled back is exactly how this happens.
  (define c (fresh-db))
  (query-exec c "INSERT INTO schema_migrations (id) VALUES (?)" "9999-from-the-future")
  (define p (schema-problem c all-migrations))
  (check-eq? (startup-problem-key p) 'schema-ahead)
  (check-eq? (startup-problem-severity p) 'error)
  (check-true (regexp-match? #px"9999-from-the-future" (startup-problem-message p)))
  (close-db! c))

;; ---- severity, which is the whole design ------------------------------------

(test-case "a loopback instance with no secrets and no TLS is CLEAN"
  ;; The ordinary development case must produce no noise at all, or the warnings
  ;; stop being read.
  (define ps (startup-problems #:bind-ip "127.0.0.1" #:tls? #f #:secrets? #f
                               #:strict? #f))
  (check-equal? (keys ps) '(no-secret-key)
                "only the plaintext-at-rest note, because the bind is private"))

(test-case "a public bind with no TLS warns by default and REFUSES under strict"
  (define loose (startup-problems #:bind-ip "0.0.0.0" #:tls? #f #:secrets? #f
                                  #:strict? #f))
  (check-equal? (sev loose 'no-tls) 'warning)
  (check-equal? (sev loose 'no-secret-key) 'warning)
  ;; …and nothing here is fatal, so an existing deployment keeps booting. This
  ;; is the compatibility promise of the whole slice.
  (check-true (report-startup-problems! loose #:out (open-output-nowhere)))

  (define strict (startup-problems #:bind-ip "0.0.0.0" #:tls? #f #:secrets? #f
                                   #:strict? #t))
  (check-equal? (sev strict 'no-tls) 'error)
  (check-equal? (sev strict 'no-secret-key) 'error)
  (check-false (report-startup-problems! strict #:out (open-output-nowhere))))

(test-case "TLS on, or a secret key set, removes exactly its own problem"
  (check-equal? (keys (startup-problems #:bind-ip "0.0.0.0" #:tls? #t #:secrets? #t
                                        #:strict? #t))
                '())
  (check-equal? (keys (startup-problems #:bind-ip "0.0.0.0" #:tls? #t #:secrets? #f
                                        #:strict? #f))
                '(no-secret-key))
  (check-equal? (keys (startup-problems #:bind-ip "0.0.0.0" #:tls? #f #:secrets? #t
                                        #:strict? #f))
                '(no-tls)))

(test-case "errors are listed before warnings, and an error is always fatal"
  ;; An operator reads the top of the block; the thing that stops the boot
  ;; belongs there rather than under two paragraphs of advice.
  (define f (make-temporary-file "telemachus-startup-order-~a"))
  (define ps (startup-problems #:bind-ip "0.0.0.0" #:tls? #f #:secrets? #f
                               #:blob-root (build-path f "blobs")
                               #:strict? #f))
  (check-equal? (car (keys ps)) 'blob-store)
  (check-eq? (startup-problem-severity (car ps)) 'error)
  ;; …even though the other two are only warnings in this configuration
  (check-false (report-startup-problems! ps #:out (open-output-nowhere)))
  (delete-file f))

;; ---- encrypting content without a key (issue #83) -------------------------------
;; The one combination that silently does the opposite of what was asked:
;; `secret-wrap` passes plaintext through when no key is configured (#19, so that
;; adopting a key needs no migration), so the switch would write exactly the
;; plaintext it was turned on to prevent — and report success.
(test-case "TMACH_ENCRYPT_CONTENT without a key is FATAL, not advisory"
  (define saved (tmach-env "ENCRYPT_CONTENT"))
  (dynamic-wind
    (lambda () (putenv "TMACH_ENCRYPT_CONTENT" "1"))
    (lambda ()
      (define ps (startup-problems #:bind-ip "127.0.0.1" #:tls? #f #:secrets? #f))
      (define p (findf (lambda (x) (eq? (startup-problem-key x) 'encrypt-without-key)) ps))
      (check-true (and p #t) "the combination must be reported")
      (check-eq? (startup-problem-severity p) 'error
                 "and it is an ERROR even without strict mode, unlike no-secret-key")
      (check-true (regexp-match? #px"PLAINTEXT" (startup-problem-message p))
                  "the message has to say what actually happens")
      ;; with a key present it is not a problem at all
      (define ok (startup-problems #:bind-ip "127.0.0.1" #:tls? #f #:secrets? #t))
      (check-false (findf (lambda (x) (eq? (startup-problem-key x) 'encrypt-without-key)) ok)))
    (lambda () (putenv "TMACH_ENCRYPT_CONTENT" (or saved "")))))
