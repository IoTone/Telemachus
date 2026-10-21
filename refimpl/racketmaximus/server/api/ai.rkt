#lang racket/base

;; server/api/ai.rkt — chat, the agent, the executor fleet, model roles and
;; the worker protocol
;;
;; Split out of main.rkt by #110 r3. The shared surface every handler here
;; needs — the pool, the request accessors, with-auth/with-mt, the response
;; constructors — is server/kit.rkt.

(provide ep-ai-echo ep-executors ep-admin-workers ep-executor-create
         ep-org-executor-create ep-executor-retire ep-admin-queue
         ep-executor-drain ep-executor-resume ep-model-roles-get
         ep-model-roles-put ep-worker-claim ep-worker-heartbeat
         ep-worker-state ep-worker-complete ep-worker-document
         ep-worker-derive ep-worker-fail ep-worker-release ep-ai-chat
         ep-ai-model ep-ai-chat-stream ep-agent)

(require db-kit/portable
         json
         web-kit
         (only-in "../../domain/authz/authz.rkt" audit! can? hash-token principal-is-operator principal-team-id principal-user-id require-perm)
         (only-in "../../domain/orgs/orgs.rkt" tenant-quota-check tenant-quota-record!)
         (only-in "../../domain/quota/quota.rkt" get-limit quota-check)
         (only-in "../../domain/sched/governor.rkt" with-slot)
         (only-in "../../domain/ai/executor.rkt" chat-simulated? estimate-tokens model-configured? model-info run-chat run-chat-stream)
         (only-in "../../domain/ai/content.rkt" content->text content-problem response-format-parse response-format-problem response-format-verify)
         (only-in "../../domain/exec/federation.rkt" executor-config executor-exists? list-executors)
         "../../domain/exec/pull.rkt"
         (only-in "../../domain/exec/fleet.rkt" FLEET-WINDOW-HOURS fleet-report queue-listing)
         (only-in "../../domain/ai/roles.rkt" model-roles-get model-roles-set!)
         (only-in "../../domain/agent/run.rkt" agent-configured? run-agent-flow)
         (only-in "../../domain/i18n/i18n.rkt" t)
         "../kit.rkt"
         "../admission.rkt")

(define (ep-ai-echo req)
  (with-auth req (lambda (p)
    (require-perm db-conn p "chat:use")
    (define b (read-json-body req))
    (define prompt (hash-ref b 'prompt ""))
    (define est (max 1 (quotient (string-length prompt) 4)))       ; token estimate (chars/4)
    (define sid (principal-team-id p))
    (define rq (tenant-quota-check db-conn p "ai.requests" 1))
    (define tq (tenant-quota-check db-conn p "ai.tokens.total" est))
    (cond
      [(not (hash-ref rq 'allowed)) (quota-429 rq "ai.requests")]
      [(not (hash-ref tq 'allowed)) (quota-429 tq "ai.tokens.total")]
      [else
       (define-values (climit _w) (get-limit db-conn "team" sid "ai.concurrency"))
       (with-slot GOV (string-append "team:" sid) (or climit 2)
         (lambda (inflight)
           (sleep 0.12)                                             ; simulate model latency
           (tenant-quota-record! db-conn p "ai.requests" 1)
           (tenant-quota-record! db-conn p "ai.tokens.total" est)
           (define after (quota-check db-conn "team" sid "ai.tokens.total" 0))
           (json-response (hasheq 'reply (string-upcase prompt)
                                  'tokens_used est
                                  'concurrent inflight
                                  'remaining_tokens (hash-ref after 'remaining)))))]))))

;; federated executor selection: 'executor in the body picks a named backend;
;; #f (absent / "" / "local") means the local node.
(define (pick-executor b)
  (define e (hash-ref b 'executor #f))
  (and e (let ([n (format "~a" e)]) (and (not (member n '("" "local"))) n))))
(define (executor-model ex)
  (if ex
      (let ([c (executor-config ex)])
         (cond [c (cadr c)]
              [(executor-by-name db-conn ex) => (lambda (e) (let ([m (hash-ref e 'model)]) (if (string? m) m ex)))]
              [else ex]))
      (hash-ref (model-info) 'model)))
(define (executor-known? name) (or (executor-exists? name) (and (executor-by-name db-conn name) #t)))

;; ---- executors (slice 66) -----------------------------------------------------------
;; The env-configured push backends (executors.json) and the API-created ones (the
;; executors table: push, and PULL with a worker token) in ONE listing, once each.
;;
;; A DB push executor lives in both — the row is the record, the registry entry is
;; how a call resolves it — so concatenating the two listed it twice. The row is
;; the richer answer (mode, health, org, who created it), so the registry only
;; contributes what executors.json owns, which has no row at all.
(define (ep-executors req)
  (with-auth req (lambda (p)
    (define rows (executor-list db-conn p))
    (define named (for/list ([e (in-list rows)]) (hash-ref e 'name)))
    (define from-file
      (for/list ([e (in-list (list-executors))]
                 #:when (and (equal? (hash-ref e 'source "config") "config")
                             (not (member (hash-ref e 'name) named))))
         e))
    (json-response (hasheq 'local (hasheq 'name "local" 'model (hash-ref (model-info) 'model)
                                          'configured (model-configured?) 'remote #f)
                           'executors (append from-file rows))))))

;; FLEET-2: what the fleet is DOING, as against what each executor IS. Instance
;; scoped and instance:manage — a team-tier route widened to cross teams would
;; answer past the org gate, which is step 0 of `can?`.
;;
;; `hours` bounds the per-executor counts. Clamped rather than refused: a
;; nonsense value on a READ should answer with the default window, not a 400 an
;; operator has to decode, and there is nothing here to get wrong by guessing.
(define (ep-admin-workers req)
  (with-auth req (lambda (p)
    (require-perm db-conn p "instance:manage")
    (define h (let* ([raw (query-param req 'hours)]
                     [n (and (string? raw) (string->number raw))])
                (if (and (real? n) (> n 0)) (min 720 (inexact->exact (round n))) FLEET-WINDOW-HOURS)))
    (json-response (fleet-report db-conn p #:hours h)))))

;; create: the operator anywhere (org_id optional), an org admin for its own
;; company (TEN-2e). A pull executor's worker token is in THIS response and never again.
(define (create-executor! req p #:org [org #f])
  (with-handlers ([exn:fail:user? (lambda (e) (err (exn-message e) 400))])
    (define b (read-json-body req))
    (define caps (let ([c (hash-ref b 'capabilities #f)]) (if (hash? c) c (hasheq))))
    (define-values (ex raw)
      (executor-create! db-conn p #:name (fmt b 'name) #:mode (let ([m (fmt b 'mode)]) (if (string=? m "") "pull" m))
                        #:org org
                        #:url (let ([u (fmt b 'url)]) (and (not (string=? u "")) u))
                        #:model (let ([m (fmt b 'model)]) (and (not (string=? m "")) m))
                        #:key (let ([k (fmt b 'key)]) (and (not (string=? k "")) k))
                        #:capabilities caps))
    (json-response (if raw (hash-set ex 'worker_token raw) ex) #:code 201)))
(define (ep-executor-create req)
  (with-auth req (lambda (p)
    (require-perm db-conn p "instance:manage")
    (define b (read-json-body req))
    (define org (let ([o (hash-ref b 'org_id #f)]) (and (string? o) (not (string=? o "")) o)))
    (create-executor! req p #:org org))))
(define (ep-org-executor-create req)
  (with-mt req (lambda ()
    (with-auth req (lambda (p)
      (require-perm db-conn p "org:manage")
      (create-executor! req p #:org (caller-org p)))))))
(define (ep-executor-retire req id)
  (with-auth req (lambda (p)
    (unless (or (principal-is-operator p) (can? db-conn p "org:manage"))
      (require-perm db-conn p "instance:manage"))
    (if (executor-retire! db-conn p id) (json-response (hasheq 'ok #t)) (err "not found" 404)))))

;; FLEET-4: the queue, job by job. A filter that is IGNORED rather than refused
;; is invisible to the caller — the `query-param` assq bug that answered a
;; request for Dutch with Japanese — so an empty string is treated as "no
;; filter" and anything else is passed through to an equality test on a column.
;; A bad `limit` or `offset` is clamped, not refused: this is a read, and an
;; operator should not have to decode a 400 to see their queue.
(define (ep-admin-queue req)
  (with-auth req (lambda (p)
    (require-perm db-conn p "instance:manage")
    (define (f k) (let ([v (query-param req k)]) (and (string? v) (not (string=? v "")) v)))
    (define (num k d) (let* ([raw (query-param req k)]
                             [n (and (string? raw) (string->number raw))])
                        (if (and (real? n) (>= n 0)) (inexact->exact (round n)) d)))
    (json-response (queue-listing db-conn p
                                  #:kind (f 'kind) #:status (f 'status)
                                  #:executor (f 'executor) #:team (f 'team)
                                  #:limit (num 'limit 50) #:offset (num 'offset 0))))))

;; FLEET-3: the reversible lever. Until this the only way to take a flaky box out
;; of rotation was DELETE /api/executors/<id>, which revokes the worker token —
;; so a ten-minute drain meant re-provisioning the host afterwards.
;;
;; `instance:manage` only, not the org admin who may retire their own: draining
;; is day-to-day operations of the instance's compute, and the asymmetry is
;; deliberate rather than an oversight. Revisit it when an org runs its own fleet.
(define (set-admin-state req id state)
  (with-auth req (lambda (p)
    (require-perm db-conn p "instance:manage")
    (with-handlers ([exn:fail:user? (lambda (e) (err (exn-message e) 400))])
      (define r (executor-set-admin-state! db-conn p id state))
      (cond
        [(eq? r 'retired) (err "the executor is retired — a retired worker has no token to drain" 409)]
        [r (json-response (hasheq 'ok #t 'executor r))]
        [else (err "not found" 404)])))))
(define (ep-executor-drain req id) (set-admin-state req id "drained"))
(define (ep-executor-resume req id) (set-admin-state req id "active"))

;; ---- model roles (slice 67) ----------------------------------------------------------
(define (ep-model-roles-get req)
  (with-auth req (lambda (p) (json-response (model-roles-get db-conn (principal-team-id p))))))
(define (ep-model-roles-put req)
  (with-auth req (lambda (p)
    (require-perm db-conn p "settings:manage")
    (with-handlers ([exn:fail:user? (lambda (e) (err (exn-message e) 400))])
      (define b (read-json-body req))
      (define roles (let ([r (hash-ref b 'roles b)]) (if (hash? r) r (hasheq))))
      ;; an executor must exist to be named — a typo here would silently send
      ;; every extraction to the local model
      (for ([(k v) (in-hash roles)])
         (when (and (string? v) (not (string=? v "")) (not (executor-known? v)))
          (raise-user-error 'model-roles "unknown executor ~a" v)))
      (define out (model-roles-set! db-conn (principal-team-id p) roles))
      (audit! db-conn #:action "model-roles.set" #:actor-type "user" #:actor-id (principal-user-id p)
              #:team-id (principal-team-id p) #:meta (jsexpr->string (hash-ref out 'roles)))
      (json-response out)))))

;; the worker protocol — the bearer is a worker token; the executor it is bound
;; to is found through the token's id, so a token can never speak for another host
(define (with-worker req proc)
  (with-auth req (lambda (p)
    (require-perm db-conn p "jobs:execute")
    (define bearer (let ([h (req-header req #"authorization")])
                     (and h (regexp-match? #rx"^Bearer " h) (substring h 7))))
    (define tid (and bearer (query-maybe-value db-conn "SELECT id FROM api_tokens WHERE token_hash = ?" (hash-token bearer))))
    (define ex (and tid (executor-by-token db-conn tid)))
    (if ex (proc p ex) (err "this token is not bound to an executor" 403)))))

(define (ep-worker-claim req)
  (with-worker req (lambda (p ex)
    (define b (read-json-body req))
    (define (strs k) (let ([v (hash-ref b k '())]) (if (and (list? v) (andmap string? v)) v '())))
    (define max-wait (let ([w (hash-ref b 'max_wait 0)]) (if (real? w) (min 25 (max 0 w)) 0)))
    ;; issue #58: a claim may carry what the worker is doing, so the common loop
    ;; reports its state without a second request. An unknown value is IGNORED
    ;; here rather than refused — a claim is the call that fetches work, and
    ;; failing it over a cosmetic field would stop the queue. /api/workers/state
    ;; is the call that refuses, because there the state IS the request.
    (define state (let ([v (hash-ref b 'state #f)]) (and (member v WORKER-STATES) v)))
    ;; long-poll: try, then wait a little and try again until max_wait is spent
    (let loop ([waited 0])
      (define job (worker-claim! db-conn ex #:kinds (strs 'kinds) #:models (strs 'models) #:state state))
      (cond
        [job (json-response job)]
        [(>= waited max-wait) (json-response (hasheq 'job 'null) #:code 204)]
        [else (sleep 1) (loop (+ waited 1))])))))
(define (worker-verdict v job-id)
  (case v
    [(ok) (json-response (hasheq 'ok #t 'id job-id))]
    [(not-holder) (err "not the lease holder of this job" 409)]
    ;; SCHED-8: a remote worker has no handler to return, so the heartbeat is the
    ;; only channel back. A 409 here means "stop and drop the result" — and
    ;; posting to /complete or /fail afterwards is what settles the row, which is
    ;; what frees the team's concurrency slot without waiting out the lease.
    [(canceled) (err "the job was canceled — stop work and discard the result" 409)]
    [(not-running) (err "the job is not running" 409)]
    [(no-object) (err "an object id is required" 400)]
    [(not-in-job) (err "that document is not named by this job's payload" 403)]
    [(no-such-document) (err "no such document, or not one this job's user may read" 404)]
    [(too-large) (err "document is over the inline-read ceiling (TELEMACHUS_MAX_UPLOAD)" 413)]
    [(no-source) (err "a source object id is required — a worker's output must derive from a document its job names" 400)]
    [(no-key) (err "a key is required" 400)]
    [(no-bytes) (err "bytes_b64 is required" 400)]
    [(bad-bytes) (err "bytes_b64 is not valid base64" 400)]
    [else (err "not found" 404)]))
;; issue #24: every write about a claimed job carries the attempt's claim_token,
;; which the claim response handed the worker. A worker that sends none is refused
;; on any job claimed since migration 0031 — the fence is the point.
(define (claim-token-of b) (let ([v (hash-ref b 'claim_token #f)]) (and (string? v) v)))
(define (ep-worker-heartbeat req id)
  (with-worker req (lambda (p ex)
    (define b (read-json-body req))
    (define state (let ([v (hash-ref b 'state #f)]) (and (member v WORKER-STATES) v)))
    (define v (worker-heartbeat! db-conn ex id #:token (claim-token-of b) #:state state))
    (if (number? v) (json-response (hasheq 'ok #t 'id id 'lease_until v)) (worker-verdict v id)))))

;; issue #58: the standalone report, for a worker that holds no job. Unlike the
;; claim, this one REFUSES an unknown state (400) — the vocabulary is closed, and
;; here the state is the whole request rather than a field riding along with it.
(define (ep-worker-state req)
  (with-worker req (lambda (p ex)
    (with-handlers ([exn:fail:user? (lambda (e) (err (exn-message e) 400))])
      (define st (worker-report-state! db-conn ex (let ([v (hash-ref (read-json-body req) 'state #f)])
                                                    (if (string? v) v ""))))
      (json-response (hasheq 'ok #t 'state st))))))
(define (ep-worker-complete req id)
  (with-worker req (lambda (p ex)
    (define b (read-json-body req))
    (worker-verdict (worker-complete! db-conn ex id (hash-ref b 'result (hasheq))
                                      #:token (claim-token-of b)) id))))
;; PULL-9: a worker reads a document ITS OWN job names. The fence is in
;; pull.rkt (holder + claim_token, the object must appear in that job's payload,
;; and the read happens as the job's own user so `can?` decides); this is just
;; the wire. `as: "text"` asks the extractor instead of the bytes, and a scan
;; comes back as {text: null, reason: "needs-ocr"} — an ANSWER, since that is the
;; branch an OCR worker exists to take.
(define (ep-worker-document req id)
  (with-worker req (lambda (p ex)
    (define b (read-json-body req))
    (define v (worker-document db-conn ex id
                               (let ([o (hash-ref b 'object #f)]) (if (string? o) o ""))
                               #:token (claim-token-of b)
                               #:version (let ([x (hash-ref b 'version #f)]) (and (string? x) x))
                               #:as (let ([a (hash-ref b 'as #f)]) (if (string? a) a "bytes"))))
    (if (hash? v) (json-response v) (worker-verdict v id)))))

;; issue #62: the write counterpart. The fence and the derive rule are in
;; pull.rkt; a refusal from the write itself (files:write, an invalid key, a
;; storage quota) is the JOB USER's refusal and comes back verbatim as a 403.
(define (ep-worker-derive req id)
  (with-worker req (lambda (p ex)
    (define b (read-json-body req))
    (define (s k) (let ([v (hash-ref b k #f)]) (if (string? v) v "")))
    (define v (worker-derive! db-conn ex id #:token (claim-token-of b)
                              #:source (s 'source) #:key (s 'key) #:bytes-b64 (s 'bytes_b64)
                              #:content-type (s 'content_type) #:filename (s 'filename)))
    (cond [(hash? v) (json-response v)]
          [(and (pair? v) (eq? (car v) 'refused)) (err (cdr v) 403)]
          [else (worker-verdict v id)]))))

(define (ep-worker-fail req id)
  (with-worker req (lambda (p ex)
    (define b (read-json-body req))
    (worker-verdict (worker-fail! db-conn ex id (fmt b 'error) #:token (claim-token-of b)) id))))

;; issue #61: the blameless hand-back. `failed` is its own verdict because the
;; worker needs to know its release was the one that used the job up — it is the
;; difference between "try again later" and "a person has to look at this".
(define (ep-worker-release req id)
  (with-worker req (lambda (p ex)
    (define b (read-json-body req))
    (define v (worker-release! db-conn ex id #:token (claim-token-of b)
                               #:reason (let ([r (fmt b 'reason)]) (and (not (string=? r "")) r))))
    (if (eq? v 'failed)
         (json-response (hasheq 'ok #t 'id id 'status "error" 'released #t
                               'detail (format "released ~a times — the job has been failed" MAX-RELEASES)))
         (worker-verdict v id)))))

;; real model call (falls back to simulated when no model is configured)
(define (ep-ai-chat req)
  (with-auth req (lambda (p)
    (require-perm db-conn p "chat:use")
    (require-feature p "chat")
    (define b (read-json-body req))
    ;; `prompt` is a string or a list of content parts (issue #18)
    (define prompt (hash-ref b 'prompt ""))
    (define rf (let ([v (hash-ref b 'response_format #f)]) (and v (not (eq? v 'null)) v)))
    (define ex (pick-executor b))
    (when ex (require-perm db-conn p "instance:manage"))          ; routing to specific compute = operator
    (define prompt-text (let-values ([(t _p) (content->text prompt)]) t))
    (define est (estimate-tokens prompt-text))
    (define sid (principal-team-id p))
    (define rq (tenant-quota-check db-conn p "ai.requests" 1))
    (define tq (tenant-quota-check db-conn p "ai.tokens.total" est))
    (cond
      [(content-problem prompt) => (lambda (bad) (err bad 400))]
      [(and rf (response-format-problem rf)) => (lambda (bad) (err bad 400))]
      [(and ex (not (executor-known? ex))) (err "unknown executor" 400)]
      [(not (hash-ref rq 'allowed)) (quota-429 rq "ai.requests")]
      [(not (hash-ref tq 'allowed)) (quota-429 tq "ai.tokens.total")]
      [else
       (define-values (climit _w) (get-limit db-conn "team" sid "ai.concurrency"))
       (with-slot GOV (string-append "team:" sid) (or climit 2)
         (lambda (inflight)
           ;; run-chat refuses a reply that does not honour the format, so a
           ;; 200 here means the schema held; `parsed` is that reply as JSON.
           (define-values (reply tokens) (run-chat prompt #:executor ex #:response-format rf))
           (tenant-quota-record! db-conn p "ai.requests" 1)
           (tenant-quota-record! db-conn p "ai.tokens.total" tokens)
           (define after (quota-check db-conn "team" sid "ai.tokens.total" 0))
           ;; issue #64: say when NO MODEL ANSWERED. With TELEMACHUS_MODEL_URL
           ;; unset `run-chat` falls back to a deterministic upper-cased echo —
           ;; which keeps the platform demoable and is worth keeping — but
           ;; nothing in this response said so, so a caller got a
           ;; plausible-looking reply from a model that was never called. Asked
           ;; of `chat-simulated?`, the same seam run-chat decided with, rather
           ;; than re-derived here. The key is ABSENT on a real call, never
           ;; `simulated: false`: QUOTA-3's rule, a field that is there only when
           ;; it says something.
           (define base (hasheq 'reply reply 'tokens_used tokens
                                'parsed (response-format-parse rf reply)
                                'model (executor-model ex)
                                'executor (or ex "local")
                                'concurrent inflight
                                'remaining_tokens (hash-ref after 'remaining)))
           (json-response (if (chat-simulated? ex) (hash-set base 'simulated #t) base))))]))))

(define (ep-ai-model req)
  (with-auth req (lambda (p) (json-response (model-info)))))

;; streaming chat: same admission path, tokens streamed as SSE, metered at end.
(define (ep-ai-chat-stream req)
  (with-auth req (lambda (p)
    (require-perm db-conn p "chat:use")
    (require-feature p "chat")
    (define b (read-json-body req))
    (define prompt (hash-ref b 'prompt ""))
    (define rf (let ([v (hash-ref b 'response_format #f)]) (and v (not (eq? v 'null)) v)))
    (define ex (pick-executor b))
    (when ex (require-perm db-conn p "instance:manage"))
    (define prompt-text (let-values ([(t _p) (content->text prompt)]) t))
    (define est (estimate-tokens prompt-text))
    (define sid (principal-team-id p))
    (define rq (tenant-quota-check db-conn p "ai.requests" 1))
    (define tq (tenant-quota-check db-conn p "ai.tokens.total" est))
    (cond
      [(content-problem prompt) => (lambda (bad) (err bad 400))]
      [(and rf (response-format-problem rf)) => (lambda (bad) (err bad 400))]
      [(and ex (not (executor-known? ex))) (err "unknown executor" 400)]
      [(not (hash-ref rq 'allowed)) (quota-429 rq "ai.requests")]
      [(not (hash-ref tq 'allowed)) (quota-429 tq "ai.tokens.total")]
      [else
       (define-values (climit _w) (get-limit db-conn "team" sid "ai.concurrency"))
       (sse-response
         (lambda (emit)
          (with-slot GOV (string-append "team:" sid) (or climit 2)
            (lambda (inflight)
              (define-values (tokens text)
                (run-chat-stream prompt (lambda (tok) (emit (hasheq 'token tok))) #:executor ex
                                 #:response-format rf))
              (tenant-quota-record! db-conn p "ai.requests" 1)
              (tenant-quota-record! db-conn p "ai.tokens.total" tokens)
              (define after (quota-check db-conn "team" sid "ai.tokens.total" 0))
              ;; a format can only be judged once the stream has ended, so the
              ;; verdict rides in the final event rather than raising after the
              ;; answer has already gone out. `parsed` on success, `schema_error`
              ;; when the model did not honour it — never a silent pass.
              (define-values (parsed problem) (response-format-verify rf text))
              (emit (let* ([done (hasheq 'done #t 'tokens_used tokens
                                         'model (executor-model ex)
                                         'executor (or ex "local")
                                         'remaining_tokens (hash-ref after 'remaining))]
                           ;; issue #64, as on the non-streaming endpoint: the
                           ;; reader has just watched an upper-cased echo arrive
                           ;; token by token and deserves to be told no model
                           ;; produced it
                           [done (if (chat-simulated? ex) (hash-set done 'simulated #t) done)])
                      (cond [(not rf) done]
                            [problem (hash-set done 'schema_error problem)]
                            [else (hash-set done 'parsed parsed)])))))))]))))

;; agent mode: the model uses tools (RBAC-checked per tool) to operate the platform.
(define (ep-agent req)
  (with-auth req (lambda (p)
    (require-perm db-conn p "chat:use")
    (require-feature p "agent")
    (define b (read-json-body req))
    ;; the agent is routable now (it used to build its own HTTP call, so neither a
    ;; named backend nor a model role reached it); naming compute stays operator-only,
    ;; exactly as on /api/ai/chat
    (define ex (pick-executor b))
    (when ex (require-perm db-conn p "instance:manage"))
    (cond
      [(and (not ex) (not (agent-configured?)))
       (err "agent mode requires a configured model (set TELEMACHUS_MODEL_URL)" 503)]
      [(and ex (not (executor-known? ex))) (err "unknown executor" 400)]
      [else
       (define prompt (hash-ref b 'prompt ""))
       (define sid (principal-team-id p))
       (define rq (tenant-quota-check db-conn p "ai.requests" 1))
       ;; ai.tokens.total is admitted here too, as /api/ai/chat already did. The
       ;; agent used to bill (max (estimate-tokens prompt) 50) — one real run
       ;; measured 3,810 — so the budget was never reached and the missing check
       ;; never showed. Now that the count is real, admitting on requests alone
       ;; would let an over-budget team keep spending.
       (define tq (tenant-quota-check db-conn p "ai.tokens.total" (estimate-tokens (format "~a" prompt))))
       (cond
         [(not (hash-ref rq 'allowed)) (quota-429 rq "ai.requests")]
         [(not (hash-ref tq 'allowed)) (quota-429 tq "ai.tokens.total")]
         [else
          (define-values (climit _w) (get-limit db-conn "team" sid "ai.concurrency"))
          (sse-response
           (lambda (emit)
             (with-slot GOV (string-append "team:" sid) (or climit 2)
               (lambda (inflight)
                 (define-values (_result tokens)
                   (run-agent-flow db-conn p prompt (lambda (ev) (emit ev)) #:executor ex))
                 (tenant-quota-record! db-conn p "ai.requests" 1)
                 ;; the provider's own counts, summed over the loop's rounds. This was
                 ;; (max (estimate-tokens prompt) 50) — a guess — because the agent
                 ;; discarded `usage`; the estimate stays as a floor for a server that
                 ;; reports none.
                 (tenant-quota-record! db-conn p "ai.tokens.total"
                                       (if (> tokens 0) tokens (max (estimate-tokens prompt) 50)))))))])]))))
