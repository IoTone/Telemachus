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

(require db-kit/portable json racket/string racket/list
         "wire.rkt"
         "../authz/authz.rkt"
         "../sched/scheduler.rkt"
         (only-in "../ai/content.rkt" outer-json)
         (only-in "../orgs/orgs.rkt" tenant-quota-record!)
         (only-in "../repo/repo.rkt" repo-get repo-put! repo-inherit!))

(provide register-judge-kind! judge judge-via-chat JUDGE-KIND
         judge-result-problem    ; exported for its tests
         judgments-in-result)    ; what the biller counts (JUDGE-10)

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

;; JUDGE-10: what a completed judgment COSTS. `output_tokens` is always 0 on
;; this wire, so `ai.tokens.total` cannot bound it — a judgment has its own
;; dimension, `ai.judgments.total`, one per question answered. The count comes
;; from the RESULT (the verdict's `answers`), because the one biller the
;; scheduler and worker-complete! share sees only (conn team result); carrying
;; a verdict_json with answers IS this kind's result contract, so counting it
;; is counting the kind. Answers #f for every other kind's result.
(define (judgments-in-result r)
  (define vj (and (hash? r) (hash-ref r 'verdict_json #f)))
  (define v (and (string? vj)
                 (with-handlers ([exn:fail? (lambda (_) #f)]) (string->jsexpr vj))))
  (and (hash? v) (hash? (hash-ref v 'answers #f))
       (hash-count (hash-ref v 'answers))))

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
;; JUDGE-11's write, shared by both backends: the kept pair as a document
;; derived from what it judged. Both members are JSON STRING VALUES, so their
;; bytes escape and unescape exactly; ordered-json never touches the insides.
(define (keep-judgment! conn p src request-json verdict-json key)
  (define bytes (string->bytes/utf-8
                 (ordered-json (jobj (list (cons "request_json" request-json)
                                           (cons "verdict_json" verdict-json))))))
  (define doc-key (or key (string-append (hash-ref src 'key) ".judgment.json")))
  (define o (repo-put! conn p
                       #:key doc-key
                       #:port (open-input-bytes bytes)
                       #:content-type "application/json"
                       #:filename (last (string-split doc-key "/" #:trim? #f))
                       #:visibility (hash-ref src 'visibility)
                       #:derived? #t))
  (repo-inherit! conn p #:source (hash-ref src 'id) #:target (hash-ref o 'id))
  o)

(define (resolve-source conn p source-id)
  (or (with-handlers ([exn:fail? (lambda (_) #f)]) (repo-get conn p source-id))
      (error 'judge "no such document, or not one you may read: ~a" source-id)))

;; ---- the SECOND backend: a chat model behind the same validator (JUDGE-7) ------
;;
;; The only backend that runs in CI, and the fallback for an instance with no
;; Apple Silicon host (JUDGE-12). Same request bytes, same validator, same kept
;; document — what differs is who answers. `chat` is positional `(chat text sys)`,
;; the seam translate! already set; the caller supplies it (doc-tools' default
;; chat, a scripted double in tests) and the caller's chat seam meters the
;; TOKENS, while this meters the JUDGMENTS (JUDGE-10) — the job path's biller
;; cannot see a call that never becomes a job.
;;
;; `model-name` is required: a chat verdict still carries `model`, because a
;; judgment without the thing that answered it is unauditable (JUDGE-11). The
;; model's reply is read with `outer-json` (a fence or a sentence around the
;; JSON is fine — the DWF-5 rule) and must put every answer under `answers`
;; with the question's own type; a refusal names the path and the reply is
;; retried ONCE, like the pipeline's fields step.
(define JUDGE-CHAT-SYS
  (string-append
   "You are a typed decision engine. You receive a JSON request with a `state` "
   "and named `questions` of three types. Answer ONLY with a JSON object "
   "{\"answers\": {<name>: <answer>, ...}} — every question answered, no prose. "
   "A noul answer is {\"type\":\"noul\",\"noul\":<probability 0..1>,\"confidence\":<0..1>} "
   "judged against its criteria. A choice answer is "
   "{\"type\":\"choice\",\"choice\":<one of the question's own option keys>,\"confidence\":<0..1>}. "
   "A score answer is {\"type\":\"score\",\"score\":<position on the rubric, 0-based>,\"confidence\":<0..1>}."))

(define (judge-via-chat conn #:team team #:user user #:state state #:questions questions
                        #:chat chat #:model-name model-name
                        #:source [source-id #f] #:key [key #f])
  (unless (and (string? model-name) (not (string=? model-name "")))
    (error 'judge "the chat backend must name its model — a judgment without one is unauditable"))
  (define request-json (judge-request state questions))
  (define p (user-principal conn user team))
  (define src (and source-id (resolve-source conn p source-id)))
  ;; ask answers (cons 'ok verdict-json) or (cons 'problem what) — never a bare
  ;; string doing two jobs
  (define (ask)
    (define reply (chat request-json JUDGE-CHAT-SYS))
    (define j (outer-json (format "~a" reply)))
    (cond
      [(not (hash? j)) (cons 'problem "the model's reply carries no JSON object")]
      [(not (hash? (hash-ref j 'answers #f)))
       (cons 'problem "$.answers: the reply carries no answers object")]
      [else
       ;; the verdict is CONSTRUCTED here — the model's answers, plus the name
       ;; of what answered — and then held to the request by the SAME validator
       ;; the worker path uses. Composed once; this string is what is kept.
       (define verdict-json
         (jsexpr->string (hasheq 'model model-name 'answers (hash-ref j 'answers))))
       (let ([problem (verdict-problem request-json verdict-json)])
         (if problem (cons 'problem problem) (cons 'ok verdict-json)))]))
  ;; a refusal is retried once, the pipeline's rule; the second one is final
  (define verdict-json
    (let ([first-try (ask)])
      (cond [(eq? (car first-try) 'ok) (cdr first-try)]
            [else (let ([again (ask)])
                    (if (eq? (car again) 'ok)
                        (cdr again)
                        (error 'judge "the model's answer does not answer the request — ~a"
                               (cdr again))))])))
  (tenant-quota-record! conn p "ai.judgments.total" (length questions))
  (define doc (and src (keep-judgment! conn p src request-json verdict-json key)))
  (values (string->jsexpr verdict-json) verdict-json doc))

;; JUDGE-11, the KEPT judgment: `#:source` names the repository document the
;; judgment is ABOUT, and the settled verdict is then written as a document
;; DERIVED from it — `<source key>.judgment.json` (or `#:key`), content the
;; stored pair `{request_json, verdict_json}` AS COMPOSED/RECEIVED, each a JSON
;; string value whose bytes come back exactly. The verdict's `model` string
;; (checkpoint + revision + dtype, laya's G1) rides inside verdict_json, so the
;; document is the whole reproducibility record in one place. derive!'s rule to
;; the letter: the source's visibility at repo-put!, THEN repo-inherit! copies
;; the grants and writes the derivation row — a judgment of a private document
;; is private from its first byte, and "Processed by" finds it. Written as the
;; CALLER (the job's user), in-process, so `can?` and the storage quota decide;
;; a source the caller cannot read and a missing one are ONE answer. The job
;; row also holds both strings, but a row is #59's to purge — the document is
;; the home for a judgment somebody means to keep.
(define (judge conn #:team team #:user user #:state state #:questions questions
               #:wait [wait-seconds JUDGE-WAIT-SECONDS]
               #:source [source-id #f] #:key [key #f])
  (define request-json (judge-request state questions))
  (define p (and source-id (user-principal conn user team)))
  (define src (and source-id (resolve-source conn p source-id)))
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
       (define doc (and src (keep-judgment! conn p src request-json verdict-json key)))
       (values (string->jsexpr verdict-json) verdict-json doc)]
      [(member st '("error" "canceled"))
       (error 'judge "~a: ~a" JUDGE-KIND
              (let ([e (vector-ref r 2)]) (if (sql-null? e) st e)))]
      [(> waited wait-seconds)
       (query-exec conn "UPDATE jobs SET status = 'canceled', finished_at = CURRENT_TIMESTAMP WHERE id = ? AND status IN ('queued','running')" id)
       (error 'judge "no worker answered the judgment within ~a s — is a judge worker claiming ~a?"
              wait-seconds JUDGE-KIND)]
      [else (sleep 0.25) (loop (+ waited 0.25))])))
