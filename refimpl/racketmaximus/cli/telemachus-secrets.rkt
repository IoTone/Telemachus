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
(define CREDENTIAL-SECRETS
  (list (list "users"             "totp_secret" "id" "users.totp_secret")
        (list "repo_credentials"  "secret_key"  "id" "repo_credentials.secret_key")
        (list "executors"         "secret_key"  "id" "executors.secret_key")
        ;; #85: a webhook's signing secret. A CREDENTIAL, not content — it is an
        ;; HMAC key a receiver verifies with — so it is here rather than in
        ;; CONTENT-SECRETS and `rewrap` rotates it unconditionally.
        (list "webhooks"          "secret"      "id" "webhooks.secret")
        ;; #114: a feed's API token, replayed against somebody else's source.
        ;; Nullable — a public feed has none — and `rows-of` filters NULLs out.
        (list "feeds"             "secret"      "id" "feeds.secret")
        ;; #91: a redaction's token -> value map. NOT a credential, and here
        ;; nonetheless, because what `#:credential` really names is "seal whenever
        ;; a key is configured" and this column needs that more than anything else
        ;; in the schema: it is a concordance of the identifiers a redaction took
        ;; OUT of a model request. Under the content switch, whose documented
        ;; default is off, the ordinary instance would store them in the clear.
        ;; Listed here rather than in CONTENT-SECRETS for the second reason the
        ;; schedule payload gives: a sealed column `rewrap` does not walk is
        ;; silently unrotatable, and an unopenable map is a redacted document that
        ;; can never be rehydrated again.
        (list "repo_redactions"   "token_map"   "id" "repo_redactions.token_map")))

;; Document-derived CONTENT (issue #83), which is a different kind of thing and
;; is therefore conditional. The three above are replayable credentials: if a key
;; exists they should be sealed, always, and `rewrap` sealing them is the whole
;; point. Content is sealed only when the operator asked for it, because sealing
;; it COSTS CONTENT SEARCH — so a `rewrap` that swept these in unconditionally
;; would silently remove a capability from an instance that had deliberately
;; chosen to keep it. `status` lists them separately for the same reason: an
;; instance with the switch off is not "leaking" its extracted text, it is
;; running the documented default.
(define CONTENT-SECRETS
  (list (list "repo_text" "content" "object_id" "repo_text.content")
        (list "repo_text" "spans"   "object_id" "repo_text.spans")
        ;; #135: a schedule's payload is the input of every job it fires, sealed
        ;; under the same switch as `jobs.payload` and for the same reason. It is
        ;; LISTED here where `jobs.payload` is not, and the difference is
        ;; LIFETIME: a job row settles in minutes and #59 purges it, while a
        ;; schedule is configuration that outlives key rotations. A sealed column
        ;; `rewrap` does not walk is silently unrotatable — here that means every
        ;; schedule stops firing for ever the first time the key is rotated.
        (list "job_schedules" "payload" "id" "job_schedules.payload")
        ;; #189 step 4: one chunk's embedding, as packed float32. THE FIRST
        ;; BINARY SECRET IN THIS LIST, which is why every row above carries a
        ;; 'text form and this one carries 'bytes — see `rows-of` and `rewrap`.
        ;; VEC-3 requires it to be here, and the requirement is not a formality:
        ;; a sealed column `rewrap` does not walk is silently unrotatable, and
        ;; here that means every vector becomes undecodable on the first key
        ;; rotation while the text they were made from is rotated fine, so
        ;; retrieval would return nothing and nothing would say why.
        (list "repo_chunks" "vector" "id" "repo_chunks.vector" 'bytes)))

(define (SECRETS)
  (append CREDENTIAL-SECRETS
          (if (content-encryption-enabled?) CONTENT-SECRETS '())))

(define (rows-of conn table col idcol)
  (query-rows conn (format "SELECT ~a, ~a FROM ~a WHERE ~a IS NOT NULL" idcol col table col)))

;; A spec is (table column id-column context) and may carry a fifth element, the
;; STORED FORM: 'text (the default, and every column until #189) or 'bytes.
;;
;; THE TWO FORMS ARE NOT INTERCHANGEABLE AND CONFUSING THEM IS SILENT. The text
;; path tests `wrapped-secret?`, which is a `enc:v1:` PREFIX test on a string; a
;; packed float32 vector may contain any byte, so it has no prefix to test and
;; `string-prefix?` on it is a contract violation rather than a wrong answer —
;; loud, and therefore the harmless half. The half that would NOT be loud is
;; `secret-wrap` on bytes: it is total, so it would pass them straight through
;; and `rewrap` would report having sealed a row it had left in the clear.
(define (spec-form spec) (if (> (length spec) 4) (list-ref spec 4) 'text))
(define (sealed-by? form stored)
  (case form
    [(bytes) (wrapped-bytes-key-id stored)]
    [else (and (wrapped-secret? stored)
               (string-prefix? stored (string-append "enc:v1:" (secret-key-id) ":"))
               (secret-key-id))]))
(define (unwrap-of form context stored)
  (case form [(bytes) (secret-unwrap/bytes context stored)] [else (secret-unwrap context stored)]))
(define (wrap-of form context plain)
  (case form [(bytes) (secret-wrap/bytes context plain)] [else (secret-wrap context plain)]))
(define (is-sealed? form stored)
  (case form [(bytes) (wrapped-bytes? stored)] [else (wrapped-secret? stored)]))

(define (status conn)
  (printf "secret key : ~a\n" (if (secrets-enabled?) (format "configured (id ~a)" (secret-key-id)) "NOT configured"))
  (when (current-previous-secret-key)
    (printf "previous   : configured — a rotation is in progress\n"))
  (define totals
    (for/list ([spec (in-list (SECRETS))])
      (define rows (rows-of conn (car spec) (cadr spec) (caddr spec)))
      (define form (spec-form spec))
      (define sealed (for/sum ([r (in-list rows)]) (if (is-sealed? form (vector-ref r 1)) 1 0)))
      (printf "~a.~a: ~a stored, ~a sealed, ~a in the clear\n"
              (car spec) (cadr spec) (length rows) sealed (- (length rows) sealed))
      (- (length rows) sealed)))
  (define plain (apply + totals))
  (cond
    [(and (zero? plain) (secrets-enabled?)) (printf "\nA dump of this database carries no replayable secret.\n")]
    [(secrets-enabled?) (printf "\n~a secret(s) are still in the clear — run `rewrap`.\n" plain)]
    [else (printf (string-append "\nNo key is configured, so every stored secret is readable from a dump. "
                                 "That is a supported choice; set TMACH_SECRET_KEY and run `rewrap` "
                                 "if it is not the one you meant to make.\n"))]))

(define (rewrap conn)
  (unless (secrets-enabled?)
    (die "TMACH_SECRET_KEY is not set — there is nothing to seal secrets with."))
  (define changed
    (for/sum ([spec (in-list (SECRETS))])
      (define-values (table col idcol prefix) (apply values (take spec 4)))
      (define form (spec-form spec))
      (for/sum ([r (in-list (rows-of conn table col idcol))])
        (define id (vector-ref r 0))
        (define stored (vector-ref r 1))
        (define context (string-append prefix ":" id))
        (cond
          ;; already sealed by the CURRENT key — leave it alone (idempotent)
          [(equal? (sealed-by? form stored) (secret-key-id)) 0]
          [else
           ;; unwrap with whichever key sealed it (the previous one, during a
           ;; rotation), then seal with the current. An unreadable row STOPS the
           ;; run: carrying on would quietly leave secrets nobody can decrypt.
           (define plain
             (with-handlers ([exn:fail? (lambda (e)
                                          (die (format "~a ~a: ~a\nNothing further was written."
                                                       table id (exn-message e))))])
               (unwrap-of form context stored)))
           (query-exec conn (format "UPDATE ~a SET ~a = ? WHERE ~a = ?" table col idcol)
                       (wrap-of form context plain) id)
           (printf "  ~a.~a ~a\n" table col id)
           1]))))
  (printf "rewrapped ~a secret(s) with key ~a\n" changed (secret-key-id)))

(define (keygen)
  (printf "~a\n" (bytes->hex-string (crypto-random-bytes KEY-BYTES)))
  (eprintf (string-append "\nSet it as TMACH_SECRET_KEY, keep it OUT of the database and out of the\n"
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
