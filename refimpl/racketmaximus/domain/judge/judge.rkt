#lang racket/base

;; domain/judge/judge.rkt — the typed-judgment seam (JUDGE-8, issue #57).
;;
;; ONE entry point, `judge` (JUDGE-1): a state and typed questions in, a
;; validated verdict out. The first backend is laya (JUDGE-7), reached with NO
;; new wire and NO plugin: `judge` enqueues remote job kind `judge.typed`
;; carrying the request JUDGE-13 composed, and a pull worker on an Apple Silicon
;; host forwards it to a loopback `laya_serve.py --port` (JUDGE-14) — so quota
;; admission, the org gate, cancel, the lease, the claim fence, PULL-11's state,
;; PULL-12's release and the whole FLEET surface are inherited from the job row,
;; which is why this is a kind and not a wire.
;;
;; The payload is `{request_json: <string>}` and the result is
;; `{verdict_json: <string>}` — both COMPOSED/RECEIVED BYTES, never re-serialized
;; on the way through (JUDGE-13). The kind's #:validate holds the WORKER to the
;; shape it alone controls: verdict_json is a string that parses to an object
;; naming a checkpoint and carrying answers. Whether those answers answer THIS
;; request is checked here at the read, where the request is in hand
;; (`verdict-problem`, the same validator, the full check) — a worker cannot be
;; failed over a question it never saw, and the seam must not trust a verdict
;; the validator has not held to its request.
;;
;; JUDGE-12: laya never runs in-process and never in CI. This module is
;; dialect-plain Racket with no MLX anywhere; CI exercises it against a worker
;; double, exactly as the pull tests drive infer.chat.

(require db-kit/portable json
         "wire.rkt"
         "../authz/authz.rkt"
         "../sched/scheduler.rkt")

(provide register-judge-kind! judge JUDGE-KIND JUDGE-WAIT-SECONDS
         judge-result-problem)   ; exported for its tests

(define JUDGE-KIND "judge.typed")
(define JUDGE-WAIT-SECONDS 120)   ; a judgment is ~10 ms on the box; 120 s is "no worker"

;; The worker's half of the contract, and only that half: a result is an object
;; whose `verdict_json` is a string parsing to an object with a checkpoint and
;; answers. A bad shape is the WORKER's mistake and fails the job by name
;; (remote kinds require a #:validate for exactly this reason). The
;; request-vs-verdict check deliberately does NOT live here — #:validate sees
;; the result alone, and a shape-only check that pretended to be the full one
;; would let drift in silently.
(define (judge-result-problem r)
  (cond
    [(not (hash? r)) "result must be an object"]
    [(not (string? (hash-ref r 'verdict_json #f))) "result.verdict_json must be a string (the verdict AS RECEIVED)"]
    [else
     (define v (with-handlers ([exn:fail? (lambda (_) #f)])
                 (string->jsexpr (hash-ref r 'verdict_json))))
     (cond
       [(not (hash? v)) "result.verdict_json is not a JSON object"]
       [(not (and (string? (hash-ref v 'model #f))
                  (not (string=? (hash-ref v 'model) ""))))
        "result.verdict_json: the verdict names no checkpoint (model)"]
       [(not (hash? (hash-ref v 'answers #f))) "result.verdict_json: answers must be an object"]
       [else #f])]))

(define (register-judge-kind!)
  (register-job-kind! JUDGE-KIND #f #:remote? #t #:validate judge-result-problem))

;; `judge`: compose, enqueue, wait, hold the verdict to the request.
;;
;;   questions — a list of (cons name question), from wire.rkt's constructors
;;   answers   — (values verdict-jsexpr verdict-json), the parsed verdict AND
;;               the received bytes, because JUDGE-11 stores and hashes the
;;               bytes while a caller branches on the values
;;
;; The dispatch is AUDITED (`judge.dispatched`): JUDGE-4's rule — the state
;; here leaves the process for another HOST, and the entry names that it did
;; and how much, under the team whose data it was. It does not carry the state
;; itself: the audit log is a record of acts, not a copy of the data they
;; touched (the job's payload row already holds the request).
(define (judge conn #:team team #:user user #:state state #:questions questions
               #:wait [wait-seconds JUDGE-WAIT-SECONDS])
  (define request-json (judge-request state questions))
  (define id (enqueue-job! conn #:team team #:user user #:kind JUDGE-KIND
                           #:payload (hasheq 'request_json request-json)))
  (audit! conn #:action "judge.dispatched" #:actor-type "user" #:actor-id user
          #:team-id team #:resource-type "job" #:resource-id id
          #:meta (jsexpr->string (hasheq 'kind JUDGE-KIND
                                         'questions (length questions)
                                         'bytes (string-length request-json))))
  (let loop ([waited 0])
    (define r (query-row conn "SELECT status, result, error FROM jobs WHERE id = ?" id))
    (define st (vector-ref r 0))
    (cond
      [(equal? st "done")
       (define verdict-json (hash-ref (string->jsexpr (vector-ref r 1)) 'verdict_json))
       ;; the FULL check, request in hand: a verdict that does not answer this
       ;; request is refused by path, never handed to the caller as an answer
       (define problem (verdict-problem request-json verdict-json))
       (when problem (error 'judge "the verdict does not answer the request — ~a" problem))
       (values (string->jsexpr verdict-json) verdict-json)]
      [(member st '("error" "canceled"))
       (error 'judge "~a: ~a" JUDGE-KIND
              (let ([e (vector-ref r 2)]) (if (sql-null? e) st e)))]
      [(> waited wait-seconds)
       (query-exec conn "UPDATE jobs SET status = 'canceled', finished_at = CURRENT_TIMESTAMP WHERE id = ? AND status IN ('queued','running')" id)
       (error 'judge "no worker answered the judgment within ~a s — is a judge worker claiming ~a?"
              wait-seconds JUDGE-KIND)]
      [else (sleep 0.25) (loop (+ waited 0.25))])))
