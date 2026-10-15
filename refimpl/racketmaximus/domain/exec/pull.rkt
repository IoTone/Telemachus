#lang racket/base

;; domain/exec/pull.rkt — pull-model executors (slice 66, PULL-1…8): inference
;; hosts that come to the work.
;;
;; A pull executor is a row in `executors` plus a WORKER TOKEN — an API token
;; whose only scope is jobs:execute, bound to the row. The host runs a loop:
;;
;;   claim  → the next queued REMOTE job its capabilities satisfy, offered only if
;;            its executor is instance-wide or belongs to the job's team's org
;;   heartbeat, or the lease expires and the job goes back to the queue
;;   complete / fail  → accepted only from the current lease holder
;;
;; Nothing new lives above the scheduler: the job is the same row an in-process
;; worker would claim, with the same per-team cap, quota admission and cancel.
;; A job kind registered `#:remote? #t` has no in-process handler and is never
;; claimed by the pool; the first one is `infer.chat` — the exact wire run-chat
;; speaks — so every model-using tool works unchanged when its chat is routed to
;; a pull executor (run-chat enqueues an infer.chat sub-job and waits, PULL-5).

(require db-kit/portable
         racket/string racket/list
         json
         "../db/id.rkt"
         "../authz/authz.rkt"
         "../sched/scheduler.rkt"
         (only-in "../ai/content.rkt" content->text)
         (only-in "../repo/repo.rkt" repo-open)
         (only-in "../repo/extract.rkt" extract-text)
         (only-in "../../config.rkt" max-upload-bytes)
         racket/port net/base64
         (only-in "../authz/secretbox.rkt" secret-wrap secret-unwrap)
         "federation.rkt")

(provide executor-create! executor-list executor-retire! executor-by-token executor-by-name
         load-push-executors!
         worker-claim! worker-heartbeat! worker-complete! worker-fail! reap-leases!
         worker-document worker-report-state! executor-set-admin-state!
         executor-can-run? executor-secret executor-context
         LEASE-SECONDS MAX-ATTEMPTS STALE-AFTER WORKER-STATES ADMIN-STATES
         pull-dispatch!)

(define LEASE-SECONDS 120)      ; a worker heartbeats every LEASE/3
(define MAX-ATTEMPTS 3)         ; lease expiries before the job fails for good
(define STALE-AFTER (* 3 LEASE-SECONDS))
(define (now) (current-seconds))

;; What a worker may say about itself (issue #58). A CLOSED vocabulary, like
;; EXTRACT-REASONS and REVIEW-VERDICTS: an operator console switches on these,
;; so a worker inventing a fifth would arrive as a state nothing can explain.
;;
;;   ready   — polling, with capacity for another job
;;   busy    — alive and at its own capacity; do not read the silence as a fault
;;   paused  — alive and deliberately NOT taking work (an operator drained it)
;;
;; `draining` was considered and left out: the job rows already say what a
;; paused worker is still finishing, so it would be a state the database can
;; already answer.
(define WORKER-STATES '("ready" "busy" "paused"))

;; What an operator may intend for a host (FLEET-3). Two values, because the
;; question is binary: is this box in rotation or not. `retired` is deliberately
;; NOT one of them — retiring revokes the worker token and is irreversible, and
;; the whole point of draining is that it is neither.
(define ADMIN-STATES '("active" "drained"))
(define (nz x) (if (sql-null? x) 'null x))

;; ---- executors --------------------------------------------------------------------
;; a push executor's key is sealed at rest like the other replayable secrets
;; (issue #19); it is read back only by the rewrap CLI and a future push caller
(define (executor-context id) (string-append "executors.secret_key:" id))
(define (executor-secret conn id)
  (let ([v (query-maybe-value conn "SELECT secret_key FROM executors WHERE id = ?" id)])
    (and v (not (sql-null? v)) (secret-unwrap (executor-context id) v))))

;; Every worker call is a sign of life, and may carry a state. A call that names
;; no state leaves the stored one ALONE rather than overwriting it with a guess:
;; a worker written against the old wire must keep reading as "never reported",
;; not flip to `ready` on each poll.
(define (touch-executor! conn ex [state #f] #:kinds [kinds '()] #:models [models '()])
  (cond
    [state
     (query-exec conn "UPDATE executors SET last_seen_at = ?, worker_state = ?, state_epoch = ? WHERE id = ?"
                 (now) state (now) (hash-ref ex 'id))]
    [else
     (query-exec conn "UPDATE executors SET last_seen_at = ? WHERE id = ?" (now) (hash-ref ex 'id))])
  (observe-capabilities! conn ex kinds models))

;; What a worker DECLARES on a claim is the live capability record; what the
;; operator typed at create time is an intention (FLEET-2). They were not the
;; same field, so `executors.capabilities` was usually `{}` while the worker was
;; telling us its kinds and models on every poll — and a fleet view asking "can
;; anything here run this job" had nothing true to read. The claim's declaration
;; is merged into the SAME document LAY-9 reads for `tools` and `json_schema`,
;; rather than a second place to look.
;;
;; An EMPTY declaration leaves the stored one alone: a worker that names no
;; models means "any", not "none", and overwriting on silence is the mistake
;; PULL-11d avoided for `worker_state`. The write is skipped when nothing
;; changed, because this runs on every poll.
(define (observe-capabilities! conn ex kinds models)
  (define have (let ([c (hash-ref ex 'capabilities (hasheq))]) (if (hash? c) c (hasheq))))
  (define want
    (let* ([h have]
           [h (if (null? kinds) h (hash-set h 'kinds kinds))]
           [h (if (null? models) h (hash-set h 'models models))])
      h))
  (unless (equal? want have)
    (query-exec conn "UPDATE executors SET capabilities = ? WHERE id = ?"
                (jsexpr->string want) (hash-ref ex 'id))))

;; Can THIS executor, declaring these kinds and models, run THIS job?
;;
;; The CAPABILITY half of the claim's decision and nothing else: no concurrency
;; cap, no budget, no conditional UPDATE. One policy, two askers — `worker-claim!`
;; asks it to decide, and the fleet report asks it to explain (the shape QUOTA-3
;; settled for the admission seam, for the same reason: two implementations of one
;; rule drift, and here the drift would tell an operator to go and buy a machine
;; they already have).
;;
;; `kinds` or `models` empty means "any", which is what the claim has always
;; meant by an absent declaration — not "none".
(define (executor-can-run? conn ex #:kinds kinds #:models models #:kind kind #:team team
                           #:requirements [req (hasheq)])
  (define want-model (let ([m (hash-ref req 'model #f)]) (and (string? m) m)))
  (define want-exec (let ([e (hash-ref req 'executor #f)]) (and (string? e) e)))
  (and ;; the operator's intent is part of "can this box run it" (FLEET-3): a
       ;; drained host is an answer to nothing, and a fleet report that counted
       ;; it as one would say the queue can drain when nothing will touch it.
       (not (equal? (hash-ref ex 'admin_state "active") "drained"))
       (and (member kind (remote-kinds)) #t)
       (or (null? kinds) (and (member kind kinds) #t))
       (or (not want-model) (and (member want-model models) #t))
       (or (not want-exec) (equal? want-exec (hash-ref ex 'name)))
       ;; the org gate: an org-bound executor never sees another company's job
       (let ([eorg (hash-ref ex 'org_id)])
         (or (eq? eorg 'null) (equal? eorg (team-org conn team))))))

;; the one channel a worker with NO job can use. A paused host is the case the
;; claim loop cannot report: it has stopped claiming, and it holds no job to
;; heartbeat, so without this it would simply go stale — which is the gap this
;; whole issue is about.
(define (worker-report-state! conn ex state)
  (unless (member state WORKER-STATES)
    (raise-user-error 'workers (string-append "state must be one of " (string-join WORKER-STATES ", "))))
  (touch-executor! conn ex state)
  state)

(define ESELECT
  (string-append "SELECT id, org_id, name, mode, url, model, capabilities, token_id, status, last_seen_at, created_at, created_by, "
                 "worker_state, state_epoch, admin_state "
                 "FROM executors"))

(define (row->executor r)
  (define seen (let ([v (vector-ref r 9)]) (and (not (sql-null? v)) v)))
  ;; health is DERIVED: a pull worker that has not been heard from is stale
  (define status (cond [(equal? (vector-ref r 8) "retired") "retired"]
                       [(not (equal? (vector-ref r 3) "pull")) "active"]
                       [(not seen) "never-seen"]
                       [(> (- (now) seen) STALE-AFTER) "stale"]
                       [else "active"]))
  ;; What the worker SAID (issue #58), kept as its own key beside the derived
  ;; liveness rather than folded into `status`: the two answer different
  ;; questions and a paused host is alive and refusing. Nothing that switches on
  ;; `status` changes behaviour.
  ;;
  ;; A state is reported only while the row is otherwise live. A worker that
  ;; said `ready` an hour ago and then vanished is STALE, and repeating its last
  ;; word would be a claim nothing stands behind — the rule QUOTA-3 settled for
  ;; a held job's reason, where the key is ABSENT rather than guessed.
  (define said (let ([v (vector-ref r 12)]) (and (not (sql-null? v)) (member v WORKER-STATES) v)))
  (define fresh? (member status '("active")))
  ;; `source` is "db" on every row here, so a client reading GET /api/executors
  ;; sees the same field on every entry — the config-file entries say "config".
  (hasheq 'source "db"
          'id (vector-ref r 0) 'org_id (nz (vector-ref r 1)) 'name (vector-ref r 2) 'mode (vector-ref r 3)
          'url (nz (vector-ref r 4)) 'model (nz (vector-ref r 5))
          'capabilities (with-handlers ([exn:fail? (lambda (_) (hasheq))])
                          (let ([j (string->jsexpr (vector-ref r 6))]) (if (hash? j) j (hasheq))))
          'token_id (nz (vector-ref r 7))
          'status status
          'worker_state (if (and said fresh?) said 'null)
          'state_at (let ([v (vector-ref r 13)]) (if (or (sql-null? v) (not (and said fresh?))) 'null v))
          ;; The operator's INTENT, and unlike `worker_state` it is NOT withdrawn
          ;; when the row goes stale: a drained box that has gone quiet is still
          ;; drained, and it is still drained when it comes back. This is a
          ;; standing instruction, not a reading — the opposite case to PULL-11e,
          ;; where the thing withdrawn was a claim the worker could no longer
          ;; stand behind. NULL reads as `active`, so nothing backfilled changes.
          'admin_state (let ([v (vector-ref r 14)])
                         (if (and (not (sql-null? v)) (member v ADMIN-STATES)) v "active"))
          'last_seen_at (or seen 'null) 'created_at (format "~a" (vector-ref r 10))
          'created_by (nz (vector-ref r 11))))

;; -> (values executor worker-token-or-#f). A pull executor's token is returned
;; ONCE, here; it is an API token scoped jobs:execute that never expires (a host
;; is not a person; retire the executor to end it).
(define (executor-create! conn p #:name name #:mode [mode "pull"] #:org [org-id #f]
                          #:url [url #f] #:model [model #f] #:key [key #f]
                          #:capabilities [caps (hasheq)])
  (unless (and (string? name) (regexp-match? #px"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$" name))
    (raise-user-error 'executors "name must be 1-64 letters, digits, dots, dashes or underscores"))
  (unless (member mode '("pull" "push")) (raise-user-error 'executors "mode must be pull or push"))
  (when (and (equal? mode "push") (not (string? url))) (raise-user-error 'executors "a push executor needs a url"))
  (when (query-maybe-value conn "SELECT id FROM executors WHERE name = ? AND status <> 'retired'" name)
    (raise-user-error 'executors "an executor named ~a already exists" name))
  ;; executors.json owns its names. Registering over one would resolve differently
  ;; before and after a restart, since the file is re-read at boot and this is not.
  (when (eq? (executor-source name) 'config)
    (raise-user-error 'executors
                      "executors.json already defines an executor named ~a; pick another name or remove it from the file"
                      name))
  (define id (new-id))
  (define-values (raw tid)
    (if (equal? mode "pull")
        (issue-token! conn #:user (principal-user-id p) #:team (principal-team-id p)
                      #:name (string-append "worker:" name) #:scopes '("jobs:execute") #:ttl 'never #:kind WORKER-KIND)
        (values #f #f)))
  (query-exec conn
    (string-append "INSERT INTO executors (id, org_id, name, mode, url, model, secret_key, capabilities, token_id, created_by) "
                   "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)")
    id (or org-id sql-null) name mode (or url sql-null) (or model sql-null)
    (if key (secret-wrap (executor-context id) key) sql-null)
    (jsexpr->string caps) (or tid sql-null) (principal-user-id p))
  (when (equal? mode "push")
    (register-executor! name #:url url #:model (or model "local") #:key key #:source 'db #:caps caps))
  (audit! conn #:action "executor.create" #:actor-type "user" #:actor-id (principal-user-id p)
          #:resource-type "executor" #:resource-id id
          #:meta (jsexpr->string (hasheq 'name name 'mode mode 'org_id (or org-id 'null))))
  (values (row->executor (query-row conn (string-append ESELECT " WHERE id = ?") id)) raw))

;; Put every live PUSH row back into the in-memory registry. Without this a push
;; executor created through the API worked until the process restarted and then
;; silently stopped being a backend — `executor-known?` still said it existed and
;; the chat response still reported its name. Called once at boot, after
;; connect-executors!, so executors.json keeps its names.
;;
;; A row whose sealed key will not open is SKIPPED and reported rather than
;; raised: one unopenable executor must not stop the instance from starting, and
;; an operator who rotated TELEMACHUS_SECRET_KEY needs to be told which.
;; -> (values loaded-names skipped-count)
(define (load-push-executors! conn #:log [log void])
  (define rows (query-rows conn (string-append ESELECT " WHERE mode = 'push' AND status <> 'retired' ORDER BY name")))
  (for/fold ([loaded '()] [skipped 0]) ([r (in-list rows)])
    (define e (row->executor r))
    (define name (hash-ref e 'name))
    (define url (hash-ref e 'url))
    (cond
      [(eq? (executor-source name) 'config)
       (log (format "~a — SKIPPED: executors.json already defines this name" name))
       (values loaded (add1 skipped))]
      [(not (string? url))
       (log (format "~a — SKIPPED: a push executor needs a url" name))
       (values loaded (add1 skipped))]
      [else
       (define key
         (with-handlers ([exn:fail? (lambda (_) 'unopenable)])
           (executor-secret conn (hash-ref e 'id))))
       (cond
         [(eq? key 'unopenable)
          (log (format "~a — SKIPPED: its stored key could not be unsealed (did TELEMACHUS_SECRET_KEY change?)" name))
          (values loaded (add1 skipped))]
         [else
          (register-executor! name #:url url
                              #:model (let ([m (hash-ref e 'model)]) (if (string? m) m "local"))
                              #:key key #:source 'db
                              ;; LAY-9: the same capability document the claim
                              ;; matcher reads also says whether this backend can
                              ;; do tool calls or honour a JSON schema
                              #:caps (let ([c (hash-ref e 'capabilities (hasheq))])
                                       (if (hash? c) c (hasheq))))
          (values (cons name loaded) skipped)])])))

;; every executor the caller may see: the operator sees all; an org principal
;; its own org's and the instance-wide ones
;; Take a host out of rotation, or put it back (FLEET-3). Reversible and
;; non-destructive: the token lives, the worker keeps polling and heartbeating,
;; so a drained box stays VISIBLY alive instead of looking like one that died.
;;
;; A job it already holds is left alone. Draining says "start nothing new", and
;; killing work in flight is what cancel is for — an operator who meant that has
;; `POST /api/jobs/<id>/cancel` and should have to say so.
(define (executor-set-admin-state! conn p id state)
  (unless (member state ADMIN-STATES)
    (raise-user-error 'executors (string-append "state must be one of " (string-join ADMIN-STATES ", "))))
  (define r (query-maybe-row conn (string-append ESELECT " WHERE id = ?") id))
  (and r
       (let ([e (row->executor r)])
         (cond
           [(equal? (hash-ref e 'status) "retired") 'retired]
           [else
            (query-exec conn "UPDATE executors SET admin_state = ? WHERE id = ?" state id)
            (audit! conn #:action (if (equal? state "drained") "executor.drain" "executor.resume")
                    #:actor-type "user" #:actor-id (principal-user-id p)
                    #:resource-type "executor" #:resource-id id
                    #:meta (jsexpr->string (hasheq 'name (hash-ref e 'name) 'admin_state state)))
            (row->executor (query-row conn (string-append ESELECT " WHERE id = ?") id))]))))

(define (executor-list conn p)
  (define rows (query-rows conn (string-append ESELECT " ORDER BY created_at, name")))
  (define org (principal-org-id p))
  (for/list ([r (in-list rows)]
             #:when (or (principal-is-operator p)
                        (sql-null? (vector-ref r 1))
                        (equal? (vector-ref r 1) org)))
    (row->executor r)))

(define (executor-retire! conn p id)
  (define r (query-maybe-row conn (string-append ESELECT " WHERE id = ?") id))
  (and r
       (let ([e (row->executor r)])
         (unless (or (principal-is-operator p) (equal? (hash-ref e 'org_id) (principal-org-id p)))
           (raise (exn:fail:forbidden "forbidden: instance:manage" (current-continuation-marks) "instance:manage")))
         (query-exec conn "UPDATE executors SET status = 'retired' WHERE id = ?" id)
         ;; a push executor serves out of the in-memory registry, so the row alone
         ;; would leave it taking traffic until the next restart
         (when (equal? (hash-ref e 'mode) "push") (unregister-executor! (hash-ref e 'name)))
         (when (string? (hash-ref e 'token_id))
           (query-exec conn "UPDATE api_tokens SET status = 'revoked' WHERE id = ?" (hash-ref e 'token_id)))
         ;; a job this host holds goes back to the queue right away
         (query-exec conn (string-append "UPDATE jobs SET status = 'queued', executor_id = NULL, lease_until = NULL, "
                                         "claim_token = NULL WHERE executor_id = ? AND status = 'running'") id)
         (audit! conn #:action "executor.retire" #:actor-type "user" #:actor-id (principal-user-id p)
                 #:resource-type "executor" #:resource-id id)
         #t)))

(define (executor-by-token conn token-id)
  (define r (query-maybe-row conn (string-append ESELECT " WHERE token_id = ? AND status <> 'retired'") token-id))
  (and r (row->executor r)))

(define (executor-by-name conn name)
  (define r (query-maybe-row conn (string-append ESELECT " WHERE name = ? AND status <> 'retired'") name))
  (and r (row->executor r)))

;; ---- the worker protocol ------------------------------------------------------------
(define claim-lock (make-semaphore 1))

;; the next queued REMOTE job this worker can run, or #f. Atomic under the lock,
;; like the pool's claim; the same per-team cap and quota admission apply (a
;; sub-job spawned inside an admitted parent is exempt from the cap — its parent
;; holds the slot). Offered only inside the executor's org, or anywhere for an
;; instance-wide executor.
(define (worker-claim! conn ex #:kinds [kinds '()] #:models [models '()] #:state [state #f])
  (call-with-semaphore claim-lock
    (lambda ()
      (touch-executor! conn ex state #:kinds kinds #:models models)
      ;; issue #54: this used to take the oldest 64 queued jobs of ANY kind and
      ;; then filter in Racket, so a worker whose jobs sat behind 64 in-process
      ;; ones saw an empty queue and polled forever against work it could have
      ;; run. The kind filter belongs in the WHERE clause: the window then holds
      ;; only candidates, and the limit bounds the scan rather than the answer.
      ;; A drained host is heard from and offered nothing (FLEET-3). The touch
      ;; above happens FIRST and on purpose: the worker keeps polling, so it
      ;; keeps being seen, and the operator watches a live box that is taking
      ;; nothing rather than one that has gone stale. Returning no work is also
      ;; the answer the existing wire already has a meaning for — 204 — so a
      ;; third-party worker needs no change to be drainable.
      ;;
      ;; `executor-can-run?` below refuses a drained executor too, and is the
      ;; AUTHORITATIVE check — this one is the same answer reached without
      ;; touching the queue at all. Do not remove either: the predicate is what
      ;; keeps the fleet report honest, and this is what keeps a drained fleet's
      ;; polling free.
      (define want-kinds
        (if (equal? (hash-ref ex 'admin_state "active") "drained")
            '()
            (let ([rk (remote-kinds)])
              (if (null? kinds) rk (filter (lambda (k) (member k rk)) kinds)))))
      (define candidates
        (if (null? want-kinds)
            '()                      ; this worker declares nothing we run remotely
            (apply query-rows conn
                   (string-append "SELECT id, team_id, kind, requirements, parent_job_id FROM jobs "
                                  "WHERE status = 'queued' AND kind IN ("
                                  (string-join (make-list (length want-kinds) "?") ",")
                                  ") ORDER BY priority DESC, created_at ASC LIMIT 64")
                   want-kinds)))
      (for/or ([r (in-list candidates)])
        (define id (vector-ref r 0)) (define team (vector-ref r 1)) (define kind (vector-ref r 2))
        (define req (with-handlers ([exn:fail? (lambda (_) (hasheq))])
                      (let ([j (string->jsexpr (vector-ref r 3))]) (if (hash? j) j (hasheq)))))
        (define sub? (not (sql-null? (vector-ref r 4))))
        ;; the capability half, shared with the fleet report so the two cannot
        ;; disagree about what this box can run (FLEET-2). The kind is already
        ;; guaranteed by the IN clause above; asking again costs nothing and
        ;; keeps the rule in one place.
        (and (executor-can-run? conn ex #:kinds kinds #:models models
                                #:kind kind #:team team #:requirements req)
             ;; LIVE-IN, not `status='running'`: a job being canceled still has a
             ;; worker on it and still spends the team's budget (SCHED-8).
             (or sub? (< (query-value conn (string-append "SELECT COUNT(*) FROM jobs WHERE team_id = ? AND " LIVE-IN) team)
                         ((scheduler-cap-for) team)))
             ;; the quota gate, and the deferral is recorded (issue #55) — a
             ;; worker that polls an over-budget team's queue for ever otherwise
             ;; looks like a queue with no work in it
             (let ([hold ((scheduler-hold-reason) conn team)])
               (cond
                 [hold ((scheduler-on-hold) conn team id hold) #f]
                 [else #t]))
             ;; the same conditional claim the pool makes: the update names the
             ;; row it expects and is believed only when RETURNING hands one back,
             ;; so two workers scanning the same queue never both get this job.
             (let* ([lease (+ (now) LEASE-SECONDS)]
                    [token (claim-job! conn id #:lease lease #:executor (hash-ref ex 'id))])
               (and token
                    (let ([row (query-row conn "SELECT id, kind, payload, team_id, attempt FROM jobs WHERE id = ?" id)])
                      ;; claim_token fences this attempt (issue #24): the worker sends
                      ;; it back on every heartbeat and on the result, so a previous
                      ;; attempt that is still alive cannot complete this one — not
                      ;; even when the same executor re-claimed it.
                      ;; `attempt` and `max_attempts` so a worker can tell it is on
                      ;; its LAST try (issue #54): a job that will not be re-queued
                      ;; deserves a different decision from one that will — retry a
                      ;; flaky model call now, or fail loudly with the reason, and
                      ;; do not spend an hour on something about to be retried
                      ;; anyway. `attempt` is 0 on a first claim.
                      (hasheq 'id (vector-ref row 0) 'kind (vector-ref row 1)
                              'payload (with-handlers ([exn:fail? (lambda (_) (hasheq))]) (string->jsexpr (vector-ref row 2)))
                              'claim_token token
                              'attempt (vector-ref row 4) 'max_attempts MAX-ATTEMPTS
                              'lease_until lease 'lease_seconds LEASE-SECONDS)))))))))

;; is this job held by this executor, on THIS attempt, and still running?
;;   -> 'ok | 'canceled | 'not-holder | 'not-running | 'not-found
;;
;; 'canceled is how a REMOTE worker learns it was stopped (SCHED-8). There is no
;; handler to return here, so the heartbeat is the only channel back: a worker
;; whose heartbeat says `canceled` stops and drops its result. The holder and the
;; token are checked FIRST, so the verdict only ever goes to the worker actually
;; running the job.
;;
;; The token is what makes "this attempt" answerable (issue #24). Without it, an
;; executor whose lease lapsed mid-run — and which then re-claimed the same job —
;; could complete it with the older run's result, because executor_id and status
;; both matched. A caller that sends no token is refused whenever the row carries
;; one, which every claim since 0031 does.
(define (holder-check conn ex job-id [token #f])
  (define r (query-maybe-row conn "SELECT executor_id, status, claim_token FROM jobs WHERE id = ?" job-id))
  (define st (vector-ref r 1))
  (define stopping? (and (member st '("canceling" "canceled")) #t))
  (cond [(not r) 'not-found]
        ;; queued / done / error answer 'not-running exactly as they always have;
        ;; only the two cancellation states are held back for the holder check,
        ;; so a stranger can never learn that somebody's job was canceled.
        [(and (not stopping?) (not (equal? st "running"))) 'not-running]
        [(not (equal? (vector-ref r 0) (hash-ref ex 'id))) 'not-holder]
        [(let ([ct (vector-ref r 2)])
           (and (not (sql-null? ct)) (not (equal? ct token)))) 'not-holder]
        [stopping? 'canceled]
        [else 'ok]))

(define (worker-heartbeat! conn ex job-id #:token [token #f] #:state [state #f])
  (define v (holder-check conn ex job-id token))
  (cond
    [(eq? v 'ok)
     (define lease (+ (now) LEASE-SECONDS))
     (query-exec conn "UPDATE jobs SET lease_until = ? WHERE id = ?" lease job-id)
     (touch-executor! conn ex state)
     lease]
    [else v]))

;; a result is accepted only from the current holder; it is validated by the
;; kind's #:validate (a bad shape is the WORKER's mistake and fails the job)
(define (worker-complete! conn ex job-id result #:token [token #f])
  (define v (holder-check conn ex job-id token))
  (cond
    ;; the worker has stopped — that is what this call proves — so the slot is
    ;; genuinely free now and the row can settle. The result is discarded: it
    ;; answers a question the caller withdrew.
    [(eq? v 'canceled) (settle-canceling! conn job-id token) 'canceled]
    [(not (eq? v 'ok)) v]
    [else
     (define kind (query-value conn "SELECT kind FROM jobs WHERE id = ?" job-id))
     (define problem ((remote-kind-validator kind) result))
     (cond
       [problem
        (query-exec conn (string-append "UPDATE jobs SET status = 'error', error = ?, claim_token = NULL, "
                                        "finished_at = CURRENT_TIMESTAMP WHERE id = ?")
                    (string-append "worker returned a bad result: " problem) job-id)
        'ok]
       [else
        (query-exec conn (string-append "UPDATE jobs SET status = 'done', result = ?, claim_token = NULL, "
                                        "finished_at = CURRENT_TIMESTAMP WHERE id = ?")
                    (jsexpr->string result) job-id)
        (define team (query-value conn "SELECT team_id FROM jobs WHERE id = ?" job-id))
        ((scheduler-record!) conn team result)
        'ok])]))

(define (worker-fail! conn ex job-id message #:token [token #f])
  (define v (holder-check conn ex job-id token))
  (cond
    [(eq? v 'canceled) (settle-canceling! conn job-id token) 'canceled]
    [(not (eq? v 'ok)) v]
    [else
     (query-exec conn (string-append "UPDATE jobs SET status = 'error', error = ?, claim_token = NULL, "
                                     "finished_at = CURRENT_TIMESTAMP WHERE id = ?")
                 (format "executor ~a: ~a" (hash-ref ex 'name) message) job-id)
     'ok]))

;; ---- PULL-9: a worker reads the documents ITS OWN job names ------------------
;;
;; A pull executor runs the work but could read nothing: `infer.chat` carries
;; messages, so an OCR or CV job on a GPU box had no way to get at the bytes. The
;; fence is three conditions, and it adds NO authorization code — the same move
;; repo-put! made with its hook:
;;
;;   1. the caller is the current holder of THIS attempt (`holder-check`, so the
;;      claim_token must match — a lapsed attempt reads nothing);
;;   2. the object is REFERENCED BY THAT JOB'S PAYLOAD. A worker token is not a
;;      key to the team's repository; it opens the documents the job it is
;;      running is about, and nothing else. The payload's shape is the kind's
;;      business, so the check is over every string value in it rather than a
;;      fixed field name;
;;   3. the read happens as the JOB'S OWN USER, so `can?` decides exactly as it
;;      would for that person on the request path — visibility, grants, the org
;;      gate and token scopes included.
;;
;; `as` is "bytes" (base64, capped at TELEMACHUS_MAX_UPLOAD like every other
;; inline read) or "text" (the extractor's answer, with a scan reported as a
;; REASON beside a null text rather than as an error — the branch an OCR worker
;; exists to take).

;; every string anywhere in a jsexpr, so a kind may name its documents under any
;; key or nest them in a list without this needing to know the shape
(define (jsexpr-strings x)
  (cond [(string? x) (list x)]
        [(list? x) (append-map jsexpr-strings x)]
        [(hash? x) (append-map jsexpr-strings (hash-values x))]
        [else '()]))

(define (worker-document conn ex job-id object-id #:token [token #f]
                         #:version [version #f] #:as [as "bytes"])
  (define v (holder-check conn ex job-id token))
  (cond
    [(not (eq? v 'ok)) v]
    [(string=? object-id "") 'no-object]
    [else
     (define r (query-row conn "SELECT team_id, user_id, payload FROM jobs WHERE id = ?" job-id))
     (define payload (with-handlers ([exn:fail? (lambda (_) (hasheq))])
                       (string->jsexpr (vector-ref r 2))))
     (cond
       [(not (member object-id (jsexpr-strings payload))) 'not-in-job]
       [else
        (define p (user-principal conn (vector-ref r 1) (vector-ref r 0)))
        ;; `can?` refuses by RAISING (repo-get), while a missing row answers #f.
        ;; Both collapse to the same verdict here on purpose: "does not exist or
        ;; is not yours to read" is one answer, as it is in the knowledge graph.
        (define-values (o in)
          (with-handlers ([exn:fail? (lambda (_) (values #f #f))])
            (repo-open conn p object-id #:version version)))
        (cond
          [(not in) 'no-such-document]
          [(equal? as "text")
           (define-values (text reason)
             (dynamic-wind void
                           (lambda () (extract-text in (hash-ref o 'content_type)))
                           (lambda () (close-input-port in))))
           (hasheq 'id (hash-ref o 'id) 'key (hash-ref o 'key)
                   'content_type (hash-ref o 'content_type)
                   'text (or text 'null)
                   'reason (if reason (symbol->string reason) 'null))]
          [else
           (define bs (dynamic-wind void (lambda () (port->bytes in)) (lambda () (close-input-port in))))
           (if (> (bytes-length bs) (max-upload-bytes))
               'too-large
               (hasheq 'id (hash-ref o 'id) 'key (hash-ref o 'key)
                       'content_type (hash-ref o 'content_type)
                       'filename (hash-ref o 'filename "")
                       'version_id (hash-ref o 'version_id)
                       'size (bytes-length bs)
                       'bytes_b64 (bytes->string/utf-8 (base64-encode bs #""))))])])]))

;; an expired lease returns the job to the queue with attempt+1; past MAX-ATTEMPTS
;; it fails with the reason. Called from the scheduler's idle tick and by tests.
;;
;; FLEET-1: every expiry is AUDITED, and the entry is written BEFORE the UPDATE.
;; The requeue sets `executor_id` to NULL — it has to, the job is nobody's again —
;; so after the UPDATE the only record of which machine dropped the work is gone.
;; Without the entry a job one flaky box failed three times is indistinguishable
;; from three boxes that each tried once, which is the question an operator asks
;; first. Writing it here rather than deriving it later is the whole point: there
;; is nothing left to derive it from.
;;
;; No dedup, unlike QUOTA-3's `quota.exhausted`: that one is re-decided for every
;; queued job on every tick, while an expiry happens once per attempt and is
;; bounded by MAX-ATTEMPTS.
(define (reap-leases! conn)
  ;; every claim carries a lease now — a pull worker's and the pool's alike — so
  ;; this recovers an in-process job whose worker died as well as a remote one.
  ;; (`lease_until < ?` already skips a NULL lease; those are swept at boot by
  ;; the scheduler's reap-orphans!.)
  (define expired (query-rows conn
    (string-append "SELECT id, attempt, team_id, executor_id, kind FROM jobs "
                   "WHERE status = 'running' AND lease_until < ?") (now)))
  ;; A CANCELING job whose lease lapsed is settled, never re-queued: the holder is
  ;; gone (or ignored its cancellation past SCHED-9's ceiling), and re-running work
  ;; somebody stopped is the one outcome nobody asked for. This is also what frees
  ;; the slot of a handler that hung — see with-lease in the scheduler.
  (define stopping (query-list conn
    "SELECT id FROM jobs WHERE status = 'canceling' AND lease_until IS NOT NULL AND lease_until < ?" (now)))
  (for ([id (in-list stopping)]) (settle-canceling! conn id))
  (for ([r (in-list expired)])
    (define id (vector-ref r 0)) (define attempt (vector-ref r 1))
    ;; straight through, not through `nz`: that answers the SYMBOL 'null for a
    ;; JSON reader, and audit! wants sql-null for an absent column.
    (define team (let ([v (vector-ref r 2)]) (if (sql-null? v) sql-null v)))
    (define ex-id (let ([v (vector-ref r 3)]) (and (not (sql-null? v)) v)))
    (define ex-name (executor-name conn ex-id))
    ;; the ORIGINAL condition, inverted and named — `(< attempt MAX-ATTEMPTS)`
    ;; requeues, so the job fails on the attempt that is no longer below the cap.
    ;; `(>= (add1 attempt) …)` reads more naturally and costs the job an attempt.
    (define last? (>= attempt MAX-ATTEMPTS))
    ;; `team-id` is the JOB's team, because audit-list filters by it: an entry
    ;; without one is invisible to exactly the people whose work stopped — the
    ;; gap QUOTA-3 had to close for a deferred job, and the one `user.2fa.reset`
    ;; still has.
    (audit! conn #:action "job.lease.expired" #:actor-type "system"
            #:team-id team #:resource-type "job" #:resource-id id
            #:result (if last? "exhausted" "requeued")
            #:meta (jsexpr->string (hasheq 'kind (vector-ref r 4)
                                           'attempt attempt
                                           'max_attempts MAX-ATTEMPTS
                                           'executor_id (or ex-id 'null)
                                           'executor (or ex-name 'null)
                                           'lease_seconds LEASE-SECONDS)))
    (if (not last?)
        (query-exec conn (string-append "UPDATE jobs SET status = 'queued', executor_id = NULL, lease_until = NULL, "
                                        "claim_token = NULL, attempt = ? WHERE id = ?")
                    (add1 attempt) id)
        (begin
          (audit! conn #:action "job.attempts.exhausted" #:actor-type "system"
                  #:team-id team #:resource-type "job" #:resource-id id
                  #:result "error"
                  #:meta (jsexpr->string (hasheq 'kind (vector-ref r 4)
                                                 'attempts MAX-ATTEMPTS
                                                 'holders (map (lambda (h) (or h 'null)) (lease-holders conn id)))))
          (query-exec conn
            (string-append "UPDATE jobs SET status = 'error', error = ?, executor_id = NULL, lease_until = NULL, "
                           "claim_token = NULL, finished_at = CURRENT_TIMESTAMP WHERE id = ?")
            (exhausted-message conn id) id))))
  (+ (length expired) (length stopping)))

;; The name of an executor, or #f for an in-process job (executor_id is NULL) or
;; a row that has since been deleted. A name, not an id, because the id is what
;; the audit meta carries and the name is what an operator recognises.
(define (executor-name conn id)
  (and id (let ([v (query-maybe-value conn "SELECT name FROM executors WHERE id = ?" id)])
            (and v (not (sql-null? v)) v))))

;; Which machines held this job, oldest attempt first, read back out of the trail
;; the expiries above wrote. `#f` for an attempt the pool held in process.
(define (lease-holders conn id)
  (for/list ([m (in-list (query-list conn
                           (string-append "SELECT meta FROM audit_log WHERE action = 'job.lease.expired' "
                                          "AND resource_id = ? ORDER BY at_us ASC") id))])
    (and (not (sql-null? m))
         (with-handlers ([exn:fail? (lambda (_) #f)])
           (let ([h (string->jsexpr m)])
             (and (hash? h) (let ([n (hash-ref h 'executor 'null)]) (and (string? n) n))))))))

;; The stored error names the machines that dropped it. "no executor completed it
;; in 3 attempts" was true and told an operator nothing: the first thing they want
;; to know is whether it was one bad box three times or three boxes once each, and
;; that is the difference between retiring a host and looking at the job.
(define (exhausted-message conn id)
  (define held (lease-holders conn id))
  (define named (filter string? held))
  (cond
    [(null? named)
     (format "no worker completed it in ~a attempts (leases expired; in process)" MAX-ATTEMPTS)]
    [(= 1 (length (remove-duplicates named)))
     (format "no executor completed it in ~a attempts (leases expired on ~a~a)"
             MAX-ATTEMPTS (car named)
             (if (= (length named) (length held)) "" ", and in process"))]
    [else
     (format "no executor completed it in ~a attempts (leases expired on ~a)"
             MAX-ATTEMPTS (string-join (map (lambda (h) (or h "in process")) held) ", "))]))

;; ---- routing a synchronous model call to a pull executor (PULL-5) --------------------
;; Enqueue an infer.chat sub-job and wait for a worker to complete it. Bounded:
;; a caller inside a job is itself under a lease; a request-path caller gets the
;; same bound. The sub-job carries parent_job_id so claim exempts it from the
;; team cap (its parent holds the slot) and requirements naming the executor.
(define WAIT-SECONDS 300)
(define (pull-dispatch! conn #:team team #:user user #:executor name #:messages msgs
                        #:model [model #f] #:temperature [temp 0.7] #:parent [parent #f]
                        #:response-format [rf #f])
  (define ex (executor-by-name conn name))
  (unless ex (error 'run-chat "no executor named ~a" name))
  ;; response_format rides in the payload (issue #18): a worker must be able to
  ;; answer a schema request, or a pull executor could not run the same call the
  ;; local path can.
  (define id (enqueue-job! conn #:team team #:user user #:kind "infer.chat"
                           #:payload (let ([pl (hasheq 'messages msgs 'model (or model (hash-ref ex 'model) 'null) 'temperature temp)])
                                       (if rf (hash-set pl 'response_format rf) pl))
                           #:requirements (hasheq 'executor name 'model (or model (hash-ref ex 'model) 'null))
                           #:parent parent))
  (let loop ([waited 0])
    (define r (query-row conn "SELECT status, result, error FROM jobs WHERE id = ?" id))
    (define st (vector-ref r 0))
    (cond
      [(equal? st "done")
       (define res (string->jsexpr (vector-ref r 1)))
       ;; a worker may answer with `reply` or with content parts (issue #18); the
       ;; validator has already refused parts that carry no text
       (define reply
         (cond [(string? (hash-ref res 'reply #f)) (hash-ref res 'reply)]
               [else (let-values ([(t _p) (content->text (hash-ref res 'content ""))]) t)]))
       (values reply (let ([t (hash-ref res 'tokens_used #f)]) (if (number? t) t 0)))]
      [(member st '("error" "canceled"))
       (error 'run-chat "executor ~a: ~a" name (let ([e (vector-ref r 2)]) (if (sql-null? e) st e)))]
      [(> waited WAIT-SECONDS)
       (query-exec conn "UPDATE jobs SET status = 'canceled', finished_at = CURRENT_TIMESTAMP WHERE id = ? AND status IN ('queued','running')" id)
       (error 'run-chat "executor ~a: no worker completed the request within ~a s" name WAIT-SECONDS)]
      [else (sleep 0.25) (loop (+ waited 0.25))])))
