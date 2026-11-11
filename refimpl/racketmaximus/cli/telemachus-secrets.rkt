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
;; Exported FOR `test/sealed-coverage-tests.rkt`: the lists are what that gate
;; compares against the declarations, and `rewrap`/`status` are what it runs.
(provide CREDENTIAL-SECRETS CONTENT-SECRETS rewrap status)

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
        (list "repo_redactions"   "token_map"   "id" "repo_redactions.token_map")
        ;; The instance's SMTP password. A replayable credential, so it is here
        ;; rather than in CONTENT-SECRETS and `rewrap` rotates it unconditionally —
        ;; and it is listed IN THE SAME COMMIT AS ITS `CREATE TABLE`, which is
        ;; VEC-19's rule with a specific cost: a sealed column `rewrap` does not
        ;; walk is silently unrotatable, so forgetting this line means every
        ;; notification on the instance stops at the first key rotation while the
        ;; transport still reports itself configured, and the message an operator
        ;; would see is a relay's "authentication failed". Nullable — a relay that
        ;; wants no credential has none — and `rows-of` filters NULLs out.
        (list "email_transport"   "password"    "id" "email_transport.password")))

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
        (list "repo_chunks" "vector" "id" "repo_chunks.vector" 'bytes)
        ;; #191: why a bookmark's last fetch failed. Somebody else's server's
        ;; words about a URL a member chose, which is the class #83 r4 sealed
        ;; four `error` columns over. Listed here rather than left out for the
        ;; reason the schedule payload gives — LIFETIME: a job row settles in
        ;; minutes and #59 purges it, while a bookmark is configuration that
        ;; outlives key rotations, so a sealed column `rewrap` does not walk
        ;; would become unreadable on the first rotation. It is `#:forgiving`
        ;; (ENC-21), so the cost of that would be a diagnostic nobody can read
        ;; rather than a row nobody can open — which is exactly why it is easy
        ;; to forget and worth the line.
        (list "research_sources" "last_error" "id" "research_sources.last_error")
        ;; THE THIRTEEN THAT WERE DECLARED AND NOT WALKED. Each is sealed under
        ;; the content switch by `define-sealed-column`, and none was listed, on
        ;; the reasoning the schedule payload's note records: "a job row settles
        ;; in minutes and #59 purges it". That is true of the row's usefulness
        ;; and false of the row. Nothing deletes a job, a run, a step or a
        ;; translation unless a team configured retention, which is off by
        ;; default (DEL-9) — so on a content-encrypted instance they accumulate,
        ;; sealed under whichever key was current. A read falls back to
        ;; TMACH_SECRET_KEY_OLD while it is set, and the runbook's last step is
        ;; to drop it: from then on every earlier run, step, job and translation
        ;; raises on read, and "Processed by" on a document loses its history.
        ;; A payload that will not open RAISES by design (ENC-21), so this was
        ;; not a degraded read but a 500 on `GET /api/runs/:id`.
        ;;
        ;; `test/sealed-coverage-tests.rkt` now fails when a column is declared
        ;; through the macro and absent from this file, in both directions, so
        ;; the list cannot fall behind the declarations again.
        (list "jobs" "payload" "id" "jobs.payload")
        (list "jobs" "result"  "id" "jobs.result")
        (list "jobs" "error"   "id" "jobs.error")
        (list "workflow_runs" "input"  "id" "workflow_runs.input")
        (list "workflow_runs" "output" "id" "workflow_runs.output")
        ;; The CONTEXT is `workflow_runs.cursor` and the COLUMN is `cursor_json`.
        ;; The mismatch is history — rows exist under it — so both are spelled.
        (list "workflow_runs" "cursor_json" "id" "workflow_runs.cursor")
        (list "workflow_runs" "error"  "id" "workflow_runs.error")
        (list "workflow_steps" "input"  "id" "workflow_steps.input")
        (list "workflow_steps" "output" "id" "workflow_steps.output")
        (list "workflow_steps" "error"  "id" "workflow_steps.error")
        (list "translations" "source_text" "id" "translations.source_text")
        (list "translations" "result_text" "id" "translations.result_text")
        ;; The one column keyed by TWO values: its context is
        ;; `doc_trigger_fires.error:<trigger_id>:<version_id>`, so the id column
        ;; here is a LIST, in the order the declaration names its keys.
        (list "doc_trigger_fires" "error" (list "trigger_id" "version_id")
              "doc_trigger_fires.error")))

(define (SECRETS)
  (append CREDENTIAL-SECRETS
          (if (content-encryption-enabled?) CONTENT-SECRETS '())))

;; A spec's id column is one name or a LIST of names. A row comes back as
;; (ids . stored), `ids` always a list, so every caller has one shape.
(define (id-columns idcol) (if (list? idcol) idcol (list idcol)))
(define (rows-of conn table col idcol)
  (define ids (id-columns idcol))
  (for/list ([r (in-list (query-rows conn (format "SELECT ~a, ~a FROM ~a WHERE ~a IS NOT NULL"
                                                  (string-join ids ", ") col table col)))])
    (define n (length ids))
    (cons (for/list ([i (in-range n)]) (vector-ref r i)) (vector-ref r n))))
;; `<table>.<column>:<key>[:<key>…]` — sealed.rkt's `sealed-context`, by its
;; own rule: the string is authenticated data in every row ever written.
(define (context-of prefix ids) (string-append prefix ":" (string-join ids ":")))

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
  (define previous 0)
  (define totals
    (for/list ([spec (in-list (SECRETS))])
      (define rows (rows-of conn (car spec) (cadr spec) (caddr spec)))
      (define form (spec-form spec))
      (define sealed (for/sum ([r (in-list rows)]) (if (is-sealed? form (cdr r)) 1 0)))
      ;; Sealed, but not by the CURRENT key. During a rotation this is the figure
      ;; that says whether TMACH_SECRET_KEY_OLD may be dropped: while it is not
      ;; zero, dropping the previous key makes those rows unreadable.
      (define other (for/sum ([r (in-list rows)])
                      (if (and (is-sealed? form (cdr r))
                               (not (equal? (sealed-by? form (cdr r)) (secret-key-id))))
                          1 0)))
      (set! previous (+ previous other))
      (printf "~a.~a: ~a stored, ~a sealed, ~a in the clear~a\n"
              (car spec) (cadr spec) (length rows) sealed (- (length rows) sealed)
              (if (zero? other) "" (format ", ~a under ANOTHER key" other)))
      (- (length rows) sealed)))
  (define plain (apply + totals))
  (when (positive? previous)
    (printf (string-append "\n~a row(s) are sealed under a key that is not the current one. "
                           "Run `rewrap` with TMACH_SECRET_KEY_OLD set, and do not drop the "
                           "previous key until this reads zero.\n")
            previous))
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
        (define ids (car r))
        (define id (string-join ids ":"))
        (define stored (cdr r))
        (define context (context-of prefix ids))
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
           (apply query-exec conn
                  (format "UPDATE ~a SET ~a = ? WHERE ~a" table col
                          (string-join (for/list ([c (in-list (id-columns idcol))]) (format "~a = ?" c))
                                       " AND "))
                  (wrap-of form context plain) ids)
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
