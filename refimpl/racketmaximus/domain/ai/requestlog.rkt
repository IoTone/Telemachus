#lang racket/base

;; domain/ai/requestlog.rkt — what left this process, without what was in it.
;; Issue #91 requirement 3.
;;
;; RED-15: THERE WAS NO MODEL-REQUEST LOG AT ALL. This is the first one, not a
;; narrowing of an existing one. `ai.requests` is a counter in the quota ledger:
;; it answers how MUCH a team spent and can never answer what was sent, where it
;; went, whose call it was, or whether it was refused. So a reviewer asking "did
;; this document's text cross the network, and to whose machine" had nothing to
;; read, which is the question a regulated integrator asks first.
;;
;; The defining property is what is NOT stored: no prompt, no reply, no excerpt.
;; The digest stands for the content and is a KEYED mac under the instance's own
;; key (`secret-digest`, RED-18) — a bare SHA-256 of a short prompt is reversible
;; from a word list, so a bare hash here would make this table a confirmation
;; oracle over exactly the identifiers requirement 1 exists to protect.
;;
;; This module touches the database, which is why the LOGGER IS A BOX that
;; `server/main.rkt` fills (RED-17): `domain/ai/executor.rkt` knows nothing of
;; the database, the same reason `pull-router` is a box in that module.

(require racket/string
         db-kit/portable
         (only-in "../authz/secretbox.rkt" secret-digest)
         ;; the pure half: where the backend is and what it declares. Kept in its
         ;; own module because executor.rkt asks it on the model path and must
         ;; not acquire a database (RED-20).
         (only-in "egress.rkt" CONTENT-LOGGING endpoint-host endpoint-hosted? content-logging-of)
         (only-in "../authz/authz.rkt" require-perm principal-team-id)
         (only-in "../db/nulls.rkt" nz)
         (only-in "../db/id.rkt" new-id))

(provide ERROR-KINDS REQUEST-STATUSES REQUEST-OPERATIONS
         model-request-record! model-requests-for model-request-digest)

;; ---- two CLOSED vocabularies, and this time something checks them -----------
;;
;; `READ-DOORS` and `QUESTION-TYPES` were each declared, commented as closed, and
;; referenced by NOTHING — #113's shape, caught by #110 r4 and then gated by a
;; static source scan. The scan was the right answer there because a
;; `read-context` is built on the path of every read, so raising would turn a
;; typo'd door into a 500 on a document download.
;;
;; HERE A RAISE IS THE RIGHT ANSWER, and the difference is the one property this
;; writer has that the constructor does not: the caller already wraps it so a
;; failure never fails the model call (RED-17). So an invented status costs a
;; row and a line on stderr naming it, and cannot cost anybody their answer —
;; which makes enforcement cheaper than a scan and stronger than one.
;;
;;   ok      — the backend answered
;;   error   — it was asked and did not answer usefully
;;   refused — this platform would not ask (RED-19/RED-20)
(define REQUEST-STATUSES '("ok" "error" "refused"))

;; Short labels, never an exception message (RED-19). #83 r4 sealed four `error`
;; columns because this platform's own refusals quote what they choked on by
;; design, and the diagnostic already has a sealed home on the job row.
(define ERROR-KINDS '("http" "timeout" "unreachable" "capability" "policy" "transport"))

;; EMB-5: WHAT was asked for, where `transport` says by which route it left. A
;; third closed vocabulary, enforced here for the same reason the other two are:
;; this writer's caller already swallows a failure (RED-17), so an invented
;; operation costs a row and a named line on stderr and can never cost anybody
;; their answer.
;;
;; `tokens_used` is NOT the same unit across these. A chat row counts prompt +
;; completion as the provider reported it; an embed row counts INPUT tokens and
;; there is no output. Reading the column without reading this one adds two
;; different things together.
(define REQUEST-OPERATIONS '("chat" "embed"))

;; ---- the row ----------------------------------------------------------------

(define (digest-domain) "model.prompt")

;; Exported for the test and for the ONE reader that has to reproduce a digest:
;; "was this text sent" is answered by digesting the text in hand and comparing,
;; which is the whole use of the column.
(define (model-request-digest text)
  (define-values (hex alg kid) (secret-digest (digest-domain) (or text "")))
  (values hex alg kid))

(define (bool->int b) (if b 1 0))

;; The messages a model request carries, reduced to the two shape signals the row
;; keeps: how many, and how many characters in total. Those are what tell a
;; forty-token question from a whole document, and neither can be read back as
;; content.
(define (messages-shape msgs)
  (define texts
    (for/list ([m (in-list (if (list? msgs) msgs '()))])
      (define c (and (hash? m) (hash-ref m 'content "")))
      (cond [(string? c) c]
            ;; content PARTS (issue #18): count the text, not the JSON around it
            [(list? c) (string-join (for/list ([p (in-list c)])
                                      (if (and (hash? p) (string? (hash-ref p 'text #f)))
                                          (hash-ref p 'text)
                                          ""))
                                    "")]
            [else ""])))
  (values (length texts) (for/sum ([t (in-list texts)]) (string-length t)) (string-join texts "\n")))

;; Write one row. Answers the id.
;;
;; A FAILURE HERE NEVER FAILS THE MODEL CALL — the caller wraps it, the trigger
;; seam's rule: an unwritable log is an operational problem and losing somebody's
;; answer is theirs.
(define (model-request-record! conn
                               #:team team #:user [user #f] #:org [org #f]
                               #:executor [executor #f]
                               #:transport transport
                               #:model [model #f]
                               #:endpoint [endpoint #f]
                               #:messages [msgs '()]
                               #:tokens [tokens #f]
                               #:status status
                               #:error-kind [error-kind #f]
                               #:http-status [http-status #f]
                               #:operation [operation "chat"]
                               #:ms [ms #f])
  (unless (member operation REQUEST-OPERATIONS)
    (error 'model-request-record! "operation ~s is not one of ~a" operation REQUEST-OPERATIONS))
  (unless (member status REQUEST-STATUSES)
    (error 'model-request-record! "status ~s is not one of ~a" status REQUEST-STATUSES))
  (unless (or (not error-kind) (member error-kind ERROR-KINDS))
    (error 'model-request-record! "error kind ~s is not one of ~a" error-kind ERROR-KINDS))
  (define cl (content-logging-of executor endpoint))
  (unless (member cl CONTENT-LOGGING)
    (error 'model-request-record! "content logging ~s is not one of ~a" cl CONTENT-LOGGING))
  (define-values (n chars text) (messages-shape msgs))
  (define-values (hex alg kid) (model-request-digest text))
  (define host (endpoint-host endpoint))
  (define id (new-id))
  (query-exec conn
    (string-append
     "INSERT INTO model_requests (id, org_id, team_id, user_id, executor, transport, operation,"
     " model, endpoint,"
     " hosted, content_logging, prompt_digest, digest_alg, digest_key_id, messages, prompt_chars,"
     " tokens_used, status, error_kind, http_status, ms, created_epoch)"
     " VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)")
    id
    (or org sql-null) (or team sql-null) (or user sql-null)
    (or executor sql-null) transport operation (or model sql-null) (or host sql-null)
    (bool->int (endpoint-hosted? endpoint))
    cl
    hex alg (or kid sql-null)
    n chars
    (if (number? tokens) (inexact->exact (round tokens)) sql-null)
    status (or error-kind sql-null)
    (if (number? http-status) http-status sql-null)
    (if (number? ms) (inexact->exact (round ms)) sql-null)
    (current-seconds))
  id)

;; ---- reading it (RED-22) ----------------------------------------------------

;; `audit:read`, not an operator permission and not a member's: it is this team's
;; own trail of its own calls, and the question it answers is an audit question.
;; The digest is information about CONTENT, which is why a plain member does not
;; get it — #84's rule, where who-read a document is behind `files:manage`
;; because it is information about people.
(define (model-requests-for conn p #:limit [limit 100] #:offset [offset 0] #:executor [executor #f])
  (require-perm conn p "audit:read")
  (define team (principal-team-id p))
  (define rows
    (if executor
        (query-rows conn (string-append
                          "SELECT id, executor, transport, model, endpoint, hosted, content_logging,"
                          " COALESCE(operation, 'chat') AS operation,"
                          " prompt_digest, digest_alg, digest_key_id, messages, prompt_chars,"
                          " tokens_used, status, error_kind, http_status, ms, created_epoch, user_id"
                          " FROM model_requests WHERE team_id = ? AND executor = ?"
                          " ORDER BY created_epoch DESC, id DESC LIMIT ? OFFSET ?")
                    team executor (min 500 (max 1 limit)) (max 0 offset))
        (query-rows conn (string-append
                          "SELECT id, executor, transport, model, endpoint, hosted, content_logging,"
                          " COALESCE(operation, 'chat') AS operation,"
                          " prompt_digest, digest_alg, digest_key_id, messages, prompt_chars,"
                          " tokens_used, status, error_kind, http_status, ms, created_epoch, user_id"
                          " FROM model_requests WHERE team_id = ?"
                          " ORDER BY created_epoch DESC, id DESC LIMIT ? OFFSET ?")
                    team (min 500 (max 1 limit)) (max 0 offset))))
  (for/list ([r (in-list rows)])
    (hasheq 'id (vector-ref r 0)
            'executor (nz (vector-ref r 1))
            'transport (vector-ref r 2)
            ;; EMB-5: the column is NULL on every row written before 0063, and
            ;; every one of those was a chat — read as such in the SQL rather
            ;; than rendered as a null the caller has to interpret.
            'operation (vector-ref r 7)
            'model (nz (vector-ref r 3))
            'endpoint (nz (vector-ref r 4))
            'hosted (not (zero? (vector-ref r 5)))
            'content_logging (vector-ref r 6)
            'prompt_digest (vector-ref r 8)
            'digest_alg (vector-ref r 9)
            'digest_key_id (nz (vector-ref r 10))
            'messages (vector-ref r 11)
            'prompt_chars (vector-ref r 12)
            'tokens_used (nz (vector-ref r 13))
            'status (vector-ref r 14)
            'error_kind (nz (vector-ref r 15))
            'http_status (nz (vector-ref r 16))
            'ms (nz (vector-ref r 17))
            'at (vector-ref r 18)
            'user_id (nz (vector-ref r 19)))))
