#lang racket/base

;; domain/sched/scheduler.rkt — the async AI workload scheduler (slice 27).
;;
;; Submit a unit of work (a "job") and let a bounded worker pool run it later,
;; off the request path — for deferred/bulk AI work (batch translation, long
;; agent flows). Design goals, in order: SAFE, then fair, then fast.
;;
;;   • Atomic claim. The next queued job is claimed by a CONDITIONAL update that
;;     names the row it expects (UPDATE … WHERE id = ? AND status='queued'
;;     RETURNING id) and is believed only when a row comes back, so two workers
;;     never run one job even when they are not in the same process.
;;   • Leased. A claimed job carries lease_until, refreshed while it runs; a job
;;     whose worker died is returned to the queue by the reaper (slice 69).
;;   • Bounded pool. A fixed N worker threads (never unbounded) drain the queue;
;;     Racket DB connections are thread-safe (ops serialized), so they share one.
;;   • Testable core. `process-one!` is synchronous (claim → run → record); the
;;     worker loop just calls it, and tests call it directly — no thread races.
;;   • Cancelable, not preemptible. cancel affects queued jobs; running ones run
;;     to completion (decision SCHED-7).
;;
;; Job kinds are registered by the server (kind → (conn principal payload) → jsexpr).

(require db-kit/portable
         json
         racket/string
         "../db/id.rkt"
         "../authz/authz.rkt")     ; user-principal

(provide register-job-kind! enqueue-job! get-job list-jobs cancel-job!
         process-one! start-scheduler! set-cap-for! set-admit?! set-record!!
         remote-kind? remote-kind-validator scheduler-cap-for scheduler-admit? scheduler-record!
         set-reaper! current-job
         claim-job! reap-orphans! POOL-LEASE-SECONDS
         current-plugin registered-job-kinds job-kinds-of-plugin plugin-kind-prefix)

(define (vr r i) (vector-ref r i))
(define (now) (current-seconds))
(define (nz x) (if (sql-null? x) 'null x))

;; ---- kind registry ----------------------------------------------------------
;; A kind is in-process (a handler) or REMOTE (slice 66): no handler here, never
;; claimed by the pool, claimed by a pull worker over HTTP and completed with a
;; result the kind's #:validate accepts (a string naming the problem, or #f).
(define *kinds* (make-hash))
(define *remote* (make-hash))       ; kind -> validator
(define (registered-job-kinds)
  (sort (append (hash-keys *kinds*) (hash-keys *remote*)) string<?))

;; A PLUGIN may register a job kind too (issue #21) — `init!` runs with full SDK
;; access, and this is the documented route. The loader parameterizes this to the
;; plugin's id while its init! runs; everything registered under it must be named
;; `x.<plugin-id>.<kind>`, the same platform-fixed prefix plugin ROUTES get, so a
;; plugin can never take a core kind's name (`flow.step`, `infer.chat`) or another
;; plugin's. A violation raises, and the loader turns that into "this plugin
;; failed to load" rather than a mystery at claim time.
(define current-plugin (make-parameter #f))
(define (plugin-kind-prefix id) (string-append "x." id "."))

;; kind -> the plugin that registered it, so `GET /api/plugins` and the generated
;; reference can say whose a kind is. Owned by the registry rather than derived by
;; the loader from a before/after diff: re-loading the plugins must not make a
;; kind look like nobody's.
(define *kind-source* (make-hash))
(define (job-kinds-of-plugin id)
  (sort (for/list ([(k v) (in-hash *kind-source*)] #:when (equal? v id)) k) string<?))

(define (register-job-kind! kind handler #:remote? [remote? #f] #:validate [validate #f])
  (define pid (current-plugin))
  (when pid
    (define want (plugin-kind-prefix pid))
    (unless (and (string? kind) (string-prefix? kind want) (> (string-length kind) (string-length want)))
      (error 'register-job-kind! "plugin ~a: a job kind must be named ~a<name> (got ~s)" pid want kind))
    ;; someone ELSE already owns this name. Re-registering your own is fine: the
    ;; loader may run again in one process, and a reload must not fail the plugin.
    (when (and (or (hash-has-key? *kinds* kind) (hash-has-key? *remote* kind))
               (not (equal? (hash-ref *kind-source* kind #f) pid)))
      (error 'register-job-kind! "plugin ~a: job kind ~s is already registered" pid kind)))
  ;; a remote kind's validator is the only thing between a worker's reply and the
  ;; rest of the system — there is no in-process handler to be strict for it.
  (when (and remote? (not (procedure? validate)))
    (error 'register-job-kind! "job kind ~s is remote and needs #:validate" kind))
  (when pid (hash-set! *kind-source* kind pid))
  (if remote?
      (hash-set! *remote* kind validate)
      (hash-set! *kinds* kind handler)))
(define (remote-kind? kind) (hash-has-key? *remote* kind))
(define (remote-kind-validator kind) (hash-ref *remote* kind (lambda () (lambda (r) "unknown remote kind"))))

;; the job a handler is running in, so a nested model call can be enqueued as a
;; sub-job of it (pull routing, PULL-5)
(define current-job (make-parameter #f))

;; ---- queue ------------------------------------------------------------------
(define (enqueue-job! conn #:team team #:user user #:kind kind #:payload [payload (hasheq)] #:priority [pri 0]
                      #:requirements [req (hasheq)] #:parent [parent #f])
  (define id (new-id))
  (query-exec conn
    "INSERT INTO jobs (id, team_id, user_id, kind, payload, priority, requirements, parent_job_id) VALUES (?, ?, ?, ?, ?, ?, ?, ?)"
    id team user kind (jsexpr->string payload) pri (jsexpr->string req) (or parent sql-null))
  id)

(define (row->job r)
  (hasheq 'id (vr r 0) 'kind (vr r 1) 'status (vr r 2) 'priority (vr r 3)
          'result (let ([x (vr r 4)]) (if (sql-null? x) 'null (with-handlers ([exn:fail? (lambda (_) x)]) (string->jsexpr x))))
          'error (nz (vr r 5)) 'created_at (vr r 6) 'started_at (nz (vr r 7)) 'finished_at (nz (vr r 8))
          'executor_id (nz (vr r 9)) 'attempt (vr r 10) 'parent_job_id (nz (vr r 11))))

(define JSELECT
  "SELECT id, kind, status, priority, result, error, created_at, started_at, finished_at, executor_id, attempt, parent_job_id FROM jobs")

(define (get-job conn id team)
  (define r (query-maybe-row conn (string-append JSELECT " WHERE id = ? AND team_id = ?") id team))
  (and r (row->job r)))

(define (list-jobs conn team #:limit [lim 50])
  (for/list ([r (in-list (query-rows conn (string-append JSELECT " WHERE team_id = ? ORDER BY created_at DESC LIMIT ?") team lim))])
    (row->job r)))

(define (cancel-job! conn id team)
  (define st (query-maybe-value conn "SELECT status FROM jobs WHERE id = ? AND team_id = ?" id team))
  (cond
    [(not st) #f]                                  ; unknown
    [(equal? st "queued")
     (query-exec conn "UPDATE jobs SET status='canceled', finished_at=CURRENT_TIMESTAMP WHERE id = ?" id) #t]
    [else 'not-cancelable]))                        ; running/done/error/canceled

;; ---- claim + run ------------------------------------------------------------
(define claim-lock (make-semaphore 1))

;; per-team concurrency cap: how many of a team's jobs may run at once. Set by the
;; server from the team's ai.concurrency limit; defaults to 2. This is enforced at
;; CLAIM time (a team already at its cap is skipped for the next under-cap team),
;; so one team's batch can't monopolize the worker pool — and, unlike wrapping a
;; shared blocking governor, a busy team never head-of-line-blocks a worker.
(define *cap-for* (box (lambda (_team) 2)))
(define (set-cap-for! f) (set-box! *cap-for* f))

;; quota metering hooks (injected by the server; decoupled from the quota service).
;;   admit?  : (conn team) -> bool   — checked at claim; an over-budget team's jobs
;;                                     stay queued (deferred) rather than failing.
;;   record! : (conn team result) -> void  — bills usage after a successful run.
(define *admit?* (box (lambda (_conn _team) #t)))
(define *record!* (box (lambda (_conn _team _result) (void))))
(define (set-admit?! f) (set-box! *admit?* f))
(define (set-record!! f) (set-box! *record!* f))
;; the same policies, for the pull worker's claim path (domain/exec/pull.rkt)
(define (scheduler-cap-for) (unbox *cap-for*))
(define (scheduler-admit?) (unbox *admit?*))
(define (scheduler-record!) (unbox *record!*))
;; the lease reaper, installed by the pull module; runs on the pool's idle tick
(define *reaper* (box (lambda (_conn) 0)))
(define (set-reaper! f) (set-box! *reaper* f))

;; how long a claimed in-process job's lease runs, and how often the worker
;; thread refreshes it. Deliberately the same 120s the pull path uses — one
;; reaper covers both, and a pool job is no more recoverable than a remote one.
(define POOL-LEASE-SECONDS 120)

;; Flip ONE job queued→running, and say whether THIS call made the transition.
;;
;; The condition (`AND status='queued'`) is what keeps two claimants off one job,
;; but the condition alone is not enough: query-exec discards the row count, so a
;; caller whose update matched nothing would go on to run a job another worker
;; holds. RETURNING is how the answer comes back portably — Racket's db reports
;; affected rows on PostgreSQL and not on SQLite, while RETURNING works on both
;; (SQLite ≥ 3.35). Shared with the pull path so both claims are believed the
;; same way.
(define (claim-job! conn id #:lease lease #:executor [executor #f])
  (define r (query conn
    (string-append "UPDATE jobs SET status='running', started_at=CURRENT_TIMESTAMP, "
                   "lease_until=?, executor_id=? WHERE id = ? AND status='queued' RETURNING id")
    lease (or executor sql-null) id))
  (and (rows-result? r) (pair? (rows-result-rows r))))

;; Terminal write, guarded on still holding the job: a run whose lease expired
;; and was re-queued by the reaper must not land its result on top of the new
;; attempt. Returns #t if this call wrote the terminal row.
(define (finish! conn id status #:result [result #f] #:error [err #f])
  (define r (query conn
    (string-append "UPDATE jobs SET status=?, result=?, error=?, lease_until=NULL, "
                   "finished_at=CURRENT_TIMESTAMP WHERE id = ? AND status='running' RETURNING id")
    status (or result sql-null) (or err sql-null) id))
  (and (rows-result? r) (pair? (rows-result-rows r))))

;; Keep the lease alive while the handler runs. The refresher is a thread on the
;; same connection (Racket serializes ops), killed when the handler returns; if
;; the process dies, so does it, and the lease lapses — which is the point.
(define (with-lease conn id thunk)
  (define beat (thread (lambda ()
                         (let loop ()
                           (sleep (/ POOL-LEASE-SECONDS 3))
                           (with-handlers ([exn:fail? void])
                             (query-exec conn "UPDATE jobs SET lease_until = ? WHERE id = ? AND status='running'"
                                         (+ (now) POOL-LEASE-SECONDS) id))
                           (loop)))))
  (dynamic-wind void thunk (lambda () (kill-thread beat))))

;; Upgrade/restart path: an in-process job claimed by a build with no lease (or by
;; this instance before it restarted) is `running` with lease_until NULL, and the
;; lease reaper cannot see it — nothing would ever recover it. The pool sweeps
;; those back to the queue when it starts. Safe because a NULL lease now means
;; "claimed by a process that is gone": every live claim sets one. (A rolling
;; deploy alongside a pre-slice-69 instance is the one case where it could requeue
;; a job that is still running; this platform deploys one instance at a time.)
(define (reap-orphans! conn)
  (define ids (query-list conn "SELECT id FROM jobs WHERE status='running' AND lease_until IS NULL"))
  (for ([id (in-list ids)])
    (query-exec conn "UPDATE jobs SET status='queued', started_at=NULL WHERE id = ? AND status='running' AND lease_until IS NULL" id))
  (length ids))

(define (claim-next! conn)
  (call-with-semaphore claim-lock
    (lambda ()
      (define cap-for (unbox *cap-for*))
      (define candidates (query-rows conn
        "SELECT id, team_id, kind, parent_job_id FROM jobs WHERE status='queued' ORDER BY priority DESC, created_at ASC LIMIT 32"))
      (for/or ([r (in-list candidates)])
        (define id (vector-ref r 0))
        (define team (vector-ref r 1))
        (define running (query-value conn "SELECT COUNT(*) FROM jobs WHERE team_id = ? AND status='running'" team))
        (and (not (remote-kind? (vector-ref r 2)))                 ; a pull worker's, not the pool's
             ;; a sub-job of an admitted parent is exempt from the cap — the parent holds the slot
             (or (not (sql-null? (vector-ref r 3))) (< running (cap-for team)))
             ((unbox *admit?*) conn team)             ; quota gate — over-budget teams defer
             ;; believed only if the conditional update actually took the row
             (claim-job! conn id #:lease (+ (now) POOL-LEASE-SECONDS))
             id)))))

(define (run-claimed! conn id)
  (define r (query-maybe-row conn "SELECT team_id, user_id, kind, payload FROM jobs WHERE id = ?" id))
  (when r
    (define team (vr r 0)) (define user (vr r 1)) (define kind (vr r 2))
    (define payload (with-handlers ([exn:fail? (lambda (_) (hasheq))]) (string->jsexpr (vr r 3))))
    (define handler (hash-ref *kinds* kind #f))
    (with-handlers ([exn:fail? (lambda (e) (finish! conn id "error" #:error (exn-message e)))])
      (cond
        [(not handler)
         (finish! conn id "error" #:error "unknown job kind")]
        [else
         (define result (with-lease conn id
                          (lambda ()
                            (parameterize ([current-job (hasheq 'id id 'team team 'user user)])
                              (handler conn (user-principal conn user team) payload)))))
         ;; bill only what we actually recorded: a run whose lease lapsed mid-flight
         ;; has been re-queued, and the new attempt will bill its own usage.
         (when (finish! conn id "done" #:result (jsexpr->string result))
           ((unbox *record!*) conn team result))]))))    ; meter usage for a successful run

;; synchronous: claim + run the next queued job. Returns its id, or #f if none.
;; Used by the worker loop and directly by tests.
(define (process-one! conn)
  (define id (claim-next! conn))
  (and id (begin (run-claimed! conn id) id)))

;; ---- the bounded worker pool ------------------------------------------------
(define *run* (box #f))
(define (start-scheduler! conn #:workers [n 2] #:idle [idle 0.2] #:cap-for [cf #f] #:admit? [adm #f] #:record! [rec #f])
  (when cf (set-cap-for! cf))
  (when adm (set-admit?! adm))
  (when rec (set-record!! rec))
  (reap-orphans! conn)          ; jobs left `running` by a process that is gone
  (set-box! *run* #t)
  (for ([_ (in-range (max 1 n))])
    (thread (lambda ()
              (let loop ()
                (when (unbox *run*)
                  (with-handlers ([exn:fail? (lambda (_) (sleep idle))])
                    (define idle? (not (process-one! conn)))
                    ((unbox *reaper*) conn)            ; expired pull leases go back to the queue
                    (when idle? (sleep idle)))
                  (loop))))))
  (lambda () (set-box! *run* #f)))    ; stop thunk
