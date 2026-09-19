#lang racket/base

;; cli/telemachus-secrets.rkt — the operator side of secrets at rest (issue #19).
;;
;;   racket cli/telemachus-secrets.rkt status     # is this database replayable?
;;   racket cli/telemachus-secrets.rkt keygen     # print a fresh 256-bit key
;;   racket cli/telemachus-secrets.rkt rewrap     # seal every stored secret with the current key
;;
;; `rewrap` is the only stateful one, and it does two jobs with the same code:
;; ADOPTING a key (plaintext rows become sealed) and ROTATING one (rows sealed by
;; TELEMACHUS_SECRET_KEY_OLD are re-sealed with TELEMACHUS_SECRET_KEY). Both are
;; row-by-row and idempotent — a row already sealed by the current key is left
;; alone — so it is safe to re-run after an interruption.
;;
;; It is deliberately NOT automatic at boot. Rewrapping is a write over every
;; credential in the database, and a server that did it on startup with a
;; mistyped key would seal rows with a key nobody has.
;;
;;   DATABASE_URL=… TELEMACHUS_SECRET_KEY=… racket cli/telemachus-secrets.rkt rewrap

(require racket/string racket/list db-kit/portable db-kit racket/random
         (only-in file/sha1 bytes->hex-string)
         "../config.rkt"
         "../domain/authz/secretbox.rkt")

;; the same connector the server uses — sqlite:/// or postgres://, resolved
;; against the implementation root exactly as main.rkt resolves it
(define (open-db) ((db-connector (database-url) #:base-dir impl-root)))

(define (die msg) (eprintf "~a\n" msg) (exit 2))

;; Every replayable secret in the database, as (table, column, id-column, context).
;; Adding a secret to the platform means adding a row here — the CLI is the list.
(define SECRETS
  (list (list "users"             "totp_secret" "id" "users.totp_secret")
        (list "repo_credentials"  "secret_key"  "id" "repo_credentials.secret_key")
        (list "executors"         "secret_key"  "id" "executors.secret_key")))

(define (rows-of conn table col idcol)
  (query-rows conn (format "SELECT ~a, ~a FROM ~a WHERE ~a IS NOT NULL" idcol col table col)))

(define (status conn)
  (printf "secret key : ~a\n" (if (secrets-enabled?) (format "configured (id ~a)" (secret-key-id)) "NOT configured"))
  (when (current-previous-secret-key)
    (printf "previous   : configured — a rotation is in progress\n"))
  (define totals
    (for/list ([spec (in-list SECRETS)])
      (define rows (rows-of conn (car spec) (cadr spec) (caddr spec)))
      (define sealed (for/sum ([r (in-list rows)]) (if (wrapped-secret? (vector-ref r 1)) 1 0)))
      (printf "~a.~a: ~a stored, ~a sealed, ~a in the clear\n"
              (car spec) (cadr spec) (length rows) sealed (- (length rows) sealed))
      (- (length rows) sealed)))
  (define plain (apply + totals))
  (cond
    [(and (zero? plain) (secrets-enabled?)) (printf "\nA dump of this database carries no replayable secret.\n")]
    [(secrets-enabled?) (printf "\n~a secret(s) are still in the clear — run `rewrap`.\n" plain)]
    [else (printf (string-append "\nNo key is configured, so every stored secret is readable from a dump. "
                                 "That is a supported choice; set TELEMACHUS_SECRET_KEY and run `rewrap` "
                                 "if it is not the one you meant to make.\n"))]))

(define (rewrap conn)
  (unless (secrets-enabled?)
    (die "TELEMACHUS_SECRET_KEY is not set — there is nothing to seal secrets with."))
  (define changed
    (for/sum ([spec (in-list SECRETS)])
      (define-values (table col idcol prefix) (apply values spec))
      (for/sum ([r (in-list (rows-of conn table col idcol))])
        (define id (vector-ref r 0))
        (define stored (vector-ref r 1))
        (define context (string-append prefix ":" id))
        (cond
          ;; already sealed by the CURRENT key — leave it alone (idempotent)
          [(and (wrapped-secret? stored)
                (string-prefix? stored (string-append "enc:v1:" (secret-key-id) ":"))) 0]
          [else
           ;; unwrap with whichever key sealed it (the previous one, during a
           ;; rotation), then seal with the current. An unreadable row STOPS the
           ;; run: carrying on would quietly leave secrets nobody can decrypt.
           (define plain
             (with-handlers ([exn:fail? (lambda (e)
                                          (die (format "~a ~a: ~a\nNothing further was written."
                                                       table id (exn-message e))))])
               (secret-unwrap context stored)))
           (query-exec conn (format "UPDATE ~a SET ~a = ? WHERE ~a = ?" table col idcol)
                       (secret-wrap context plain) id)
           (printf "  ~a.~a ~a\n" table col id)
           1]))))
  (printf "rewrapped ~a secret(s) with key ~a\n" changed (secret-key-id)))

(define (keygen)
  (printf "~a\n" (bytes->hex-string (crypto-random-bytes KEY-BYTES)))
  (eprintf (string-append "\nSet it as TELEMACHUS_SECRET_KEY, keep it OUT of the database and out of the\n"
                          "same backup as the database, and run `telemachus-secrets rewrap`.\n"
                          "Losing it means losing every TOTP seed and S3 secret it sealed.\n")))

(module+ main
  (define args (vector->list (current-command-line-arguments)))
  (define cmd (if (null? args) "status" (car args)))
  (case cmd
    [("keygen") (keygen)]
    [("status" "rewrap")
     (define conn (open-db))
     (case cmd [("status") (status conn)] [else (rewrap conn)])
     (disconnect conn)]
    [else (die "usage: telemachus-secrets <status|rewrap|keygen>")]))
