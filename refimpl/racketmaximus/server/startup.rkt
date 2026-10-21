#lang racket/base

;; server/startup.rkt — the checks an instance runs before it serves (issue #89).
;;
;; A container is handed its whole configuration as environment variables by
;; something that is not a person, and the failures that follow are the quiet
;; kind: an instance that boots healthy and then cannot write a document, or
;; serves plaintext on a public address because nobody set TLS, or runs OLD code
;; against a schema a newer replica already migrated. Each of those used to
;; surface much later as a 500, a leak, or a corrupted row.
;;
;; The rules live here, away from main.rkt, so they are unit-testable without a
;; live server — the move `domain/authz/peer.rkt` made for the peer gate, for the
;; same reason: a smoke running on localhost can never be a stranger, and a smoke
;; with a writable data dir can never prove the refusal.
;;
;; **Severity is the whole design.** Every existing deployment must keep booting,
;; so the checks that a working instance can legitimately fail are WARNINGS by
;; default and become refusals only under TELEMACHUS_STRICT_STARTUP. Two of them
;; are deliberately in that class:
;;
;;   • no secret key. Plaintext at rest is a SUPPORTED position (issue #19, "the
;;     trusted database") and the boot line already says which it is. Refusing
;;     here would break every instance that chose it.
;;   • a non-loopback bind with no TLS. The demo box serves HTTP on 0.0.0.0
;;     across a tailnet, which is a real and reasonable deployment; the thing
;;     that would be wrong is doing it on the open internet without knowing.
;;
;; The two that are ALWAYS errors are the ones where no configuration could want
;; the outcome: a blob store that cannot be written to, and a database migrated
;; by a newer build than this one.

(require racket/string racket/file racket/list
         db-kit/portable db-kit/migrate
         ;; "is this address loopback" is ONE question and has one implementation.
         ;; peer.rkt owns it for the peer gate (#40); a bind address simply admits
         ;; a couple of spellings a connected peer never arrives as, which is what
         ;; loopback-bind? normalizes before delegating. Do not grow a second
         ;; predicate here — the two would drift and the TLS warning would start
         ;; disagreeing with the identity-header gate about what is private.
         (only-in "../domain/authz/peer.rkt" loopback-address?)
         ;; issue #83: the switch, so the one combination that silently does
         ;; nothing can be refused here rather than discovered later
         (only-in "../config.rkt" content-encryption-enabled?))

(provide startup-problems
         blob-store-problem
         schema-problem
         loopback-bind?
         report-startup-problems!
         (struct-out startup-problem))

;; severity : 'error | 'warning   — 'error refuses to serve
;; key      : a short symbol, for tests and for grepping a log
;; message  : one or more lines, already wrapped, naming what to set
(struct startup-problem (severity key message) #:transparent)

(define (strict-startup?)
  (and (member (or (getenv "TELEMACHUS_STRICT_STARTUP") "") '("1" "true" "yes" "on")) #t))

;; Is the address we BIND to one only this host can reach? 0.0.0.0 is NOT
;; loopback — it is every interface, which is the whole case the TLS check
;; exists for. A bind address may also be written as a hostname or bracketed,
;; neither of which a connected peer ever arrives as; normalize those and let
;; peer.rkt answer the actual question.
(define (loopback-bind? ip)
  (define s (string-downcase (string-trim (or ip ""))))
  (or (string=? s "localhost")
      (loopback-address? (if (regexp-match? #px"^\\[.*\\]$" s)
                             (substring s 1 (sub1 (string-length s)))
                             s))))

;; ---- the blob store is writable ---------------------------------------------

;; Probe by actually writing, because every cheaper answer has been wrong here:
;; the directory may not exist yet (first boot on a fresh volume), it may exist
;; and be owned by root while the server runs as nobody (the read-only-rootfs
;; container), or it may be a read-only mount. `file-exists?` and a permission
;; bit cannot tell those apart, and the symptom in all three cases arrives as a
;; 500 on the first document save, long after a boot that looked healthy — the
;; exact failure the relative-blob-root refusal was added for.
;;
;; -> #f, or a startup-problem
(define (blob-store-problem root)
  (define (problem fmt . args)
    (startup-problem 'error 'blob-store
                     (string-append
                      (apply format fmt args)
                      "\n  Documents could not be stored. Point TELEMACHUS_DATA_DIR"
                      "\n  (or TELEMACHUS_RS3_ROOT) at a writable directory, and on a"
                      "\n  read-only root filesystem make sure it is a mounted volume.")))
  (with-handlers ([exn:fail? (lambda (e) (problem "blob store root ~a is not usable: ~a"
                                                  root (exn-message e)))])
    (unless (directory-exists? root)
      (make-directory* root))
    (define probe (build-path root (format ".telemachus-write-probe-~a" (current-milliseconds))))
    (dynamic-wind
     void
     (lambda ()
       (call-with-output-file probe #:exists 'replace (lambda (o) (write-bytes #"ok" o)))
       ;; read it back: a write that silently goes nowhere is the failure mode of
       ;; a full or exotic filesystem, and a successful open proves neither
       (define back (file->bytes probe))
       (if (equal? back #"ok")
           #f
           (problem "blob store root ~a did not return what was written to it" root)))
     (lambda () (with-handlers ([exn:fail? void])
                  (when (file-exists? probe) (delete-file probe)))))))

;; ---- the schema is this build's ---------------------------------------------

;; After `migrate!`, two things can still be wrong, and they are opposites:
;;
;;   • something is PENDING — migrate! did not finish (a partial failure, or a
;;     connection whose search_path hid the table it had just made).
;;   • something is APPLIED that this build does not know about — the database
;;     was migrated by a NEWER Telemachus. That is the dangerous one for a
;;     rolling deployment: old code against a new schema writes rows the new
;;     code will misread, and nothing anywhere else notices. It is an error, not
;;     a warning, because the remedy is to deploy the newer build, and carrying
;;     on would corrupt data rather than merely fail.
;;
;; -> #f, or a startup-problem
(define (schema-problem conn migrations)
  (define known (map migration-id migrations))
  (define applied (applied-migrations conn))
  (define pending (map migration-id (pending-migrations conn migrations)))
  (define ahead (filter (lambda (id) (not (member id known))) applied))
  (cond
    [(pair? pending)
     (startup-problem 'error 'schema-pending
                      (format (string-append
                               "the database is not fully migrated — ~a migration(s) still pending:"
                               "\n  ~a"
                               "\n  Migration runs at boot, so this means one FAILED. The log above"
                               "\n  names it; fix the cause rather than restarting into the same state.")
                              (length pending) (string-join pending ", ")))]
    [(pair? ahead)
     (startup-problem 'error 'schema-ahead
                      (format (string-append
                               "this database was migrated by a NEWER Telemachus — ~a migration(s)"
                               "\n  are applied that this build does not know about:"
                               "\n  ~a"
                               "\n  Running older code against a newer schema writes rows the newer"
                               "\n  build will misread. Deploy that version, or restore a backup"
                               "\n  taken before the upgrade.")
                              (length ahead) (string-join ahead ", ")))]
    [else #f]))

;; ---- everything, in one list -------------------------------------------------

;; The facts come in as arguments rather than being read from the environment
;; here, so a test can state a configuration without setting process-global
;; variables — and so main.rkt stays the one place that decides what the
;; environment MEANS.
;;
;;   #:conn / #:migrations   when both are given, the schema is checked
;;   #:blob-root            when given, the store is probed by writing
;;
;; -> (listof startup-problem), worst first
(define (startup-problems #:bind-ip bind-ip
                          #:tls? tls?
                          #:secrets? secrets?
                          #:blob-root [blob-root #f]
                          #:conn [conn #f]
                          #:migrations [migrations #f]
                          #:strict? [strict? (strict-startup?)])
  ;; Under strict these two become refusals; by default they are advice. See the
  ;; note at the top for why each one is legitimately survivable.
  (define advisory (if strict? 'error 'warning))
  (define found
    (list
     (and conn migrations (schema-problem conn migrations))
     (and blob-root (blob-store-problem blob-root))
     ;; ALWAYS FATAL, unlike the two advisories below: an operator who set
     ;; TELEMACHUS_ENCRYPT_CONTENT has said they want derived document content
     ;; sealed, and without a key `secret-wrap` passes plaintext STRAIGHT THROUGH
     ;; by design (#19, so that adopting a key needs no migration). So this
     ;; combination writes exactly the plaintext the operator asked to prevent,
     ;; reports healthy, and loses content search into the bargain. Refusing is
     ;; the only answer that is not a lie.
     (and (content-encryption-enabled?) (not secrets?)
          (startup-problem 'error 'encrypt-without-key
                           (string-append
                            "TELEMACHUS_ENCRYPT_CONTENT is on but there is no TELEMACHUS_SECRET_KEY."
                            "\n  Derived document content would be written in PLAINTEXT anyway — a"
                            "\n  wrap with no key passes the value through, so the switch would do"
                            "\n  nothing while reporting success. Set a key, or unset the switch.")))
     (and (not secrets?)
          (startup-problem advisory 'no-secret-key
                           (string-append
                            "no TELEMACHUS_SECRET_KEY — stored secrets (TOTP seeds, S3 and"
                            "\n  executor keys) are written in PLAINTEXT. A dump, a replica or a"
                            "\n  volume snapshot of this database is replayable. This is a supported"
                            "\n  position (the trusted-database one); set a key to seal them, and see"
                            "\n  docs/ops/secrets-at-rest-runbook.md.")))
     (and (not (loopback-bind? bind-ip)) (not tls?)
          (startup-problem advisory 'no-tls
                           (format (string-append
                                    "serving PLAINTEXT HTTP on ~a, which is not loopback — tokens and"
                                    "\n  document bytes cross the network in the clear. Terminate TLS in"
                                    "\n  front of this instance and set TELEMACHUS_TLS=1 so HSTS is sent,"
                                    "\n  or bind to 127.0.0.1 and reach it through a proxy. Safe to ignore"
                                    "\n  only if the network itself is private (a tailnet, a pod network).")
                                   bind-ip)))))
  (define problems (filter startup-problem? found))
  (append (filter (lambda (p) (eq? (startup-problem-severity p) 'error)) problems)
          (filter (lambda (p) (eq? (startup-problem-severity p) 'warning)) problems)))

;; Print them the way the plugin failures already print, and answer whether any
;; was fatal. Printing is separate from deciding so a test can assert on the
;; decision without capturing output.
;;
;; -> #t when the instance may serve
(define (report-startup-problems! problems #:out [out (current-output-port)])
  (define errors (filter (lambda (p) (eq? (startup-problem-severity p) 'error)) problems))
  (for ([p (in-list problems)])
    (fprintf out "\n~a: ~a\n"
             (if (eq? (startup-problem-severity p) 'error) "STARTUP ERROR" "WARNING")
             (startup-problem-message p)))
  (cond
    [(pair? errors)
     (fprintf out "\nRefusing to start: ~a startup check(s) failed.\n" (length errors))
     #f]
    [else
     (when (pair? problems)
       (fprintf out
                (string-append
                 "\n  (Set TELEMACHUS_STRICT_STARTUP=1 to make the warnings above refuse"
                 "\n   to start instead — recommended for an unattended deployment.)\n\n")))
     #t]))
