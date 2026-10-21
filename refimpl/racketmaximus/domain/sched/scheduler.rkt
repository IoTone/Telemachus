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
;;   • Leased and FENCED. A claimed job carries lease_until, refreshed while it
;;     runs, plus a claim_token minted for that attempt; a job whose worker died
;;     is returned to the queue by the reaper, and the dead attempt's token no
;;     longer matches, so its late result cannot land (slice 69, issue #24).
;;   • Bounded pool. A fixed N worker threads (never unbounded) drain the queue;
;;     Racket DB connections are thread-safe (ops serialized), so they share one.
;;   • Testable core. `process-one!` is synchronous (claim → run → record); the
;;     worker loop just calls it, and tests call it directly — no thread races.
;;   • Cancelable, not preemptible (SCHED-7, revised by SCHED-8). A queued job is
;;     canceled outright. A RUNNING one goes to `canceling`: its result is fenced
;;     out (finish! still names `status='running'`, so the handler's answer
;;     matches no row and is discarded) while the per-team cap goes on counting
;;     it, because the handler is still holding a thread and still spending
;;     tokens. Nothing is preempted — killing a handler mid-query would leave the
;;     SHARED db connection in an undefined state and could wedge the whole pool.
;;     A handler that wants to stop early polls `job-canceled?`.
;;   • Bounded in TIME (SCHED-9). Every job has a wall-clock ceiling
;;     (TELEMACHUS_MAX_JOB_SECONDS, 30 minutes, `never` to disable). The lease
;;     refresher is the tick that enforces it: past the ceiling it flips the job
;;     to `canceling` with a reason and STOPS refreshing, so the reaper settles it
;;     and the slot comes back within one lease. That is the one case where the
;;     slot is freed before the work provably stopped — a handler that ignored
;;     both the ceiling and `job-canceled?` has already proven it will not stop,
;;     and holding its slot for ever is the worse failure.
;;
;; Job kinds are registered by the server (kind → (conn principal payload) → jsexpr).

(require db-kit/portable
         json
         racket/string
         racket/format
         "../db/id.rkt"
         "../authz/authz.rkt"      ; user-principal
         ;; issue #83 r2: a job's payload and result are the document's own words
         (only-in "../authz/sealed.rkt" define-sealed-column)
         "../db/nulls.rkt")

(provide register-job-kind! enqueue-job! get-job list-jobs cancel-job!
         seal-payload seal-result unseal-payload unseal-result seal-error unseal-error
         purge-job-content! PURGEABLE-STATUSES
         job-canceled? settle-canceling! max-job-seconds lease-tick! LIVE-IN
         process-one! start-scheduler! set-cap-for! set-hold-reason! set-on-hold! set-record!!
         remote-kind? remote-kinds remote-kind-validator
         scheduler-cap-for scheduler-hold-reason scheduler-on-hold scheduler-record!
         team-hold
         set-reaper! current-job
         claim-job! finish! reap-orphans! POOL-LEASE-SECONDS
         drain-scheduler! scheduler-inflight-count drain-seconds
         current-plugin registered-job-kinds job-kinds-of-plugin )

;; ---- sealing a job's payload and result (issue #83 r2) --------------------------
;; `payload` is the INPUT a kind was given and `result` is what it produced, and
;; for `infer.chat` and the document pipeline both are the document's own words.
;; Sealed with the same seam the extracted text uses (#19's AES-256-GCM, the same
;; `<table>.<column>:<row-id>` AAD), under the same opt-in switch.
;;
;; THE WRITES ARE THE DANGEROUS HALF, and there are only three: the enqueue, the
;; pool's `finish!`, and the worker's completion. A missed READ hands ciphertext
;; to `string->jsexpr` and raises, which is loud; a missed WRITE stores plaintext
;; and says nothing. `test/dump-leak-tests.rkt` scans every column of every table
;; for the fixture text rather than trusting an enumeration of these sites — which
;; is how the two below were identified in the first place.
;;
;; A WORKER ALWAYS RECEIVES PLAINTEXT. It holds no key and could not decrypt; the
;; wire is unchanged, and `worker-claim!` unseals before answering. The protection
;; here is of the DATABASE — a dump, a replica, a volume snapshot — exactly as
;; #19's claim is narrow about defending a dump and not a host.
(define-sealed-column "jobs.payload" (seal-payload unseal-payload) (id))
(define-sealed-column "jobs.result"  (seal-result  unseal-result)  (id))
;; `error` is sealed for the SAME reason, and it was missed in slice 2 because an
;; enumeration of "where does content live" does not naturally land on a
;; diagnostic column. It is `(exn-message e)` from an ARBITRARY handler, and the
;; messages this platform's own tools raise quote what they choked on — the strict
;; renderer names the placeholder, the schema refusal names the path, the
;; knowledge-graph extractor refuses a snippet that is not a verbatim substring of
;; the text. #59 already clears it on a purge for exactly this reason ("a
;; handler's message can quote the input it choked on"); sealing it is the same
;; observation applied to the row that has not been purged yet.
;;
;; `#:forgiving` because an error is read by a PERSON: a value that will not open
;; must not take the whole listing down with it, so a rotated key costs the
;; diagnostic and never the job's status. Payload and result RAISE, because a
;; handler running on an unreadable payload is worse than a refusal (ENC-21).
(define-sealed-column "jobs.error" (seal-error unseal-error) (id) #:forgiving)

(define (vr r i) (vector-ref r i))
(define (now) (current-seconds))

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
;; every registered remote kind, so a claim can filter in SQL rather than
;; scan a fixed window and discard what it finds (issue #54)
(define (remote-kinds) (hash-keys *remote*))
(define (remote-kind-validator kind) (hash-ref *remote* kind (lambda () (lambda (r) "unknown remote kind"))))

;; the job a handler is running in, so a nested model call can be enqueued as a
;; sub-job of it (pull routing, PULL-5)
(define current-job (make-parameter #f))

;; ---- queue ------------------------------------------------------------------
(define (enqueue-job! conn #:team team #:user user #:kind kind #:payload [payload (hasheq)] #:priority [pri 0]
                      #:requirements [req (hasheq)] #:parent [parent #f])
  (define id (new-id))
  ;; `created_epoch` beside the TEXT `created_at` (migration 0041): the age of a
  ;; queued job is what says whether the queue is moving, and an age computed
  ;; from `created_at` is invisibly wrong on one of the two dialects.
  (query-exec conn
    (string-append "INSERT INTO jobs (id, team_id, user_id, kind, payload, priority, requirements, parent_job_id, created_epoch) "
                   "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)")
    id team user kind (seal-payload id (jsexpr->string payload)) pri
    ;; `requirements` is NOT sealed: it is the kind's matching criteria (models,
    ;; capabilities), which a claim filters on in SQL and which carries no
    ;; document content.
    (jsexpr->string req) (or parent sql-null)
    (current-seconds))
  id)

;; Why is this team's next job still queued? (issue #55)
;;
;; DERIVED, never stored. A reason written onto the row would be a second copy of
;; a decision the next tick re-makes: raise the budget and the row would still
;; say "quota" for a job about to run, which is worse than saying nothing. The
;; one implementation is the admission policy itself (`*hold-reason*`), asked the
;; same question the claim asks.
;;
;; The order mirrors `claim-next!` — the concurrency cap is checked before the
;; budget — so a team that is both at its cap and over its budget is told about
;; the cap, which is the one that clears on its own.
;;
;; `#f` means nothing in the platform is holding the job: it is admissible and
;; waiting only for a free worker, or, for a remote kind, for a worker to come
;; and claim it. That is why `waiting` is then ABSENT rather than
;; `{"reason":"worker"}` — nothing here can know whether a worker for that kind
;; exists, and inventing a reason is how a reader stops trusting the field.
(define (team-hold conn team #:sub? [sub? #f])
  (define running (query-value conn (string-append "SELECT COUNT(*) FROM jobs WHERE team_id = ? AND " LIVE-IN) team))
  (define cap ((unbox *cap-for*) team))
  (cond
    ;; a sub-job is cap-exempt at claim, so the cap is not what holds it
    [(and (not sub?) (>= running cap))
     (hasheq 'reason "concurrency" 'running running 'limit cap)]
    [else ((unbox *hold-reason*) conn team)]))

;; attach that reason to the QUEUED jobs of a listing. Computed ONCE: the answer
;; is a property of the team, not of the job, and a per-row call would run the
;; whole admission check fifty times for one page.
(define (job-waiting conn team jobs)
  (define queued (filter (lambda (j) (equal? (hash-ref j 'status) "queued")) jobs))
  (cond
    [(null? queued) jobs]
    [else
     (define plain (team-hold conn team))
     (define sub (team-hold conn team #:sub? #t))
     (for/list ([j (in-list jobs)])
       (define h (and (equal? (hash-ref j 'status) "queued")
                      (if (eq? (hash-ref j 'parent_job_id) 'null) plain sub)))
       (if h (hash-set j 'waiting h) j))]))

(define (row->job r)
  (hasheq 'id (vr r 0) 'kind (vr r 1) 'status (vr r 2) 'priority (vr r 3)
          'result (let ([x (vr r 4)])
                    (if (sql-null? x)
                        'null
                        ;; unsealed first; the fallback returns the RAW value for a
                        ;; result that was never JSON, which is pre-existing
                        ;; behaviour — but it must not return ciphertext, so the
                        ;; unseal happens outside the handler's fallback
                        (let ([plain (unseal-result (vr r 0) x)])
                          (with-handlers ([exn:fail? (lambda (_) plain)]) (string->jsexpr plain)))))
          'error (let ([e (vr r 5)]) (if (sql-null? e) 'null (unseal-error (vr r 0) e)))
          'created_at (vr r 6) 'started_at (nz (vr r 7)) 'finished_at (nz (vr r 8))
          'executor_id (nz (vr r 9)) 'attempt (vr r 10) 'parent_job_id (nz (vr r 11))
          ;; `purged_at` is reported because WITHOUT it an empty payload and a
          ;; purged one are the same thing to a reader (issue #59). A caller that
          ;; honoured a deletion request needs to be able to show that it was
          ;; honoured, and `payload = '{}'` cannot show that on its own.
          'purged_at (nz (vr r 12))))

(define JSELECT
  (string-append "SELECT id, kind, status, priority, result, error, created_at, started_at, "
                 "finished_at, executor_id, attempt, parent_job_id, purged_at FROM jobs"))

(define (get-job conn id team)
  (define r (query-maybe-row conn (string-append JSELECT " WHERE id = ? AND team_id = ?") id team))
  (and r (car (job-waiting conn team (list (row->job r))))))

(define (list-jobs conn team #:limit [lim 50])
  (job-waiting conn team
    (for/list ([r (in-list (query-rows conn (string-append JSELECT " WHERE team_id = ? ORDER BY created_at DESC LIMIT ?") team lim))])
      (row->job r))))

;; The statuses in which a job's work is LIVE — it holds a thread (or a remote
;; worker) and may still be spending the team's budget. The per-team concurrency
;; cap counts these, and nothing else may: a cancel that dropped the count while
;; the handler drained would be a quota-evasion path, not an accounting wobble
;; (cancel N running jobs in a loop → N draining handlers plus N freshly claimed
;; ones, with the cap reading as satisfied throughout). `finish!` deliberately
;; does NOT use this list — its guard stays `running` alone, which is what fences
;; a canceled job's result out.
;; SCHED-8's two live statuses, and the SQL that tests for them — DERIVED from
;; the list rather than spelled a second time. They were two independent
;; literals, which is #110 r1's shape in miniature: nothing stopped one from
;; gaining a status the other did not.
(define LIVE-STATUSES '("running" "canceling"))
(define LIVE-IN
  (string-append "status IN ("
                 (string-join (for/list ([st (in-list LIVE-STATUSES)]) (format "'~a'" st)) ",")
                 ")"))

;; Cancel a job (SCHED-8). A QUEUED job is canceled outright — no work has
;; started, so there is nothing to fence and nothing to wait for. A RUNNING one
;; is marked `canceling`: the attempt's result can no longer land, the cap keeps
;; counting it, and it becomes `canceled` when the handler actually stops (or
;; when the reaper settles it, if the process holding it died).
;;
;; Returns #t (canceled or now canceling), 'canceling if it was already on its
;; way out, 'not-cancelable for a job that has finished, or #f if there is no
;; such job in this team. Cancelling a running job is a permission the CALLER
;; must hold; that gate lives on the route, not here.
(define (cancel-job! conn id team)
  (define st (query-maybe-value conn "SELECT status FROM jobs WHERE id = ? AND team_id = ?" id team))
  (cond
    [(not st) #f]                                  ; unknown
    [(equal? st "queued")
     (query-exec conn "UPDATE jobs SET status='canceled', finished_at=CURRENT_TIMESTAMP WHERE id = ?" id) #t]
    [(equal? st "canceling") 'canceling]           ; already stopping; say so rather than lying
    [(equal? st "running")
     ;; guarded on still being `running`: between the read and here the handler
     ;; may have finished, and overwriting a `done` job would discard a result
     ;; somebody is about to read.
     (define r (query conn (string-append "UPDATE jobs SET status='canceling' WHERE id = ? "
                                          "AND status='running' RETURNING id") id))
     (if (and (rows-result? r) (pair? (rows-result-rows r))) #t 'not-cancelable)]
    [else 'not-cancelable]))                        ; done/error/canceled

;; ---- purging a settled job's content (issue #59) --------------------------------
;; `payload` holds whatever a kind needs, and for `infer.chat` and the document
;; pipeline that is the document's own text; `result` holds the model's reply.
;; Nothing removed them, ever — so a downstream application that deletes a
;; document a user never confirmed could clear its own rows and the text stayed
;; here, in a table nobody reads once the run has finished.
;;
;; This is the per-job LEVER, not a retention policy. The horizon, whether it is
;; per-team or per-instance, and what evaluates it belong to #86's retention
;; rules; a scheduled sweep would call exactly this function. Building the lever
;; first means the sweep has something to call and the policy is still open.
;;
;; WHAT IS KEPT, and why the row is not deleted: status, timings, attempt counts,
;; executor and the audit references all survive. The audit log is the record of
;; what happened (QUOTA-3's rule, FLEET-1's rule); the job row need not be. A
;; DELETE would also take the FLEET-1 lease trail's anchor and make a team's
;; own history lie about how much work it ran.
;;
;; ONLY A SETTLED JOB. A queued or running one is refused rather than purged: its
;; payload is the INPUT a handler is about to read or is reading, so clearing it
;; mid-flight would fail the job in a way that looks like corruption. The caller
;; cancels first — which is why `cancel-job!` sits directly above.
(define PURGEABLE-STATUSES '("done" "error" "canceled"))

;; -> #t purged now · 'already-purged · 'not-settled · #f no such job in this team
(define (purge-job-content! conn id team)
  (define row (query-maybe-row conn
                (string-append "SELECT status, purged_at FROM jobs "
                               "WHERE id = ? AND team_id = ?") id team))
  (cond
    [(not row) #f]
    [else
     (define st (vector-ref row 0))
     (define already (vector-ref row 1))
     (cond
       [(not (member st PURGEABLE-STATUSES)) 'not-settled]
       ;; Saying so rather than reporting a second success: a caller honouring a
       ;; deletion request wants to know whether THIS call did it, and a sweep
       ;; wants to count what it actually cleared.
       [(and already (not (sql-null? already))) 'already-purged]
       [else
        ;; Guarded on `purged_at IS NULL`, which is what makes two concurrent
        ;; purges settle to ONE winner and therefore ONE audit entry. The status
        ;; is re-checked too, though a settled status is terminal and cannot
        ;; change under us — it costs nothing and the guard then states the whole
        ;; precondition in one place rather than half here and half above.
        ;;
        ;; `error` is cleared as well: a handler's message can quote the input it
        ;; choked on, so a purge that left it behind would leave the one copy of
        ;; the text most likely to be read by a human.
        (define r (query conn
                    (string-append "UPDATE jobs SET payload = '{}', result = NULL, error = NULL, "
                                   "purged_at = ? WHERE id = ? AND purged_at IS NULL "
                                   "AND status IN ('done', 'error', 'canceled') RETURNING id")
                    (current-seconds) id))
        (if (and (rows-result? r) (pair? (rows-result-rows r))) #t 'already-purged)])]))

;; Is this job on its way out? The cooperative half of cancellation: a handler
;; that runs in steps (an agent loop, a batch) polls this at a step boundary and
;; returns early. It is an optimization — it saves CPU and tokens — never a
;; correctness requirement, because the result is fenced out either way.
(define (job-canceled? conn id)
  (define st (query-maybe-value conn "SELECT status FROM jobs WHERE id = ?" id))
  (and st (member st '("canceling" "canceled")) #t))

;; Settle a job whose handler has stopped: `canceling` → `canceled`, which is the
;; moment its concurrency slot is genuinely free. Guarded on the attempt's token,
;; so a job that was reaped and re-claimed (token cleared) is left alone.
(define (settle-canceling! conn id [token #f])
  ;; the token is appended only when the SQL has a placeholder for it — passing a
  ;; #f alongside a query that does not name it is "wrong number of parameters"
  (define r (apply query conn
    (string-append "UPDATE jobs SET status='canceled', lease_until=NULL, claim_token=NULL, "
                   "finished_at=CURRENT_TIMESTAMP WHERE id = ? AND status='canceling'"
                   (if token " AND claim_token = ?" "") " RETURNING id")
    id (if token (list token) '())))
  (and (rows-result? r) (pair? (rows-result-rows r))))

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
;;   hold-reason : (conn team) -> #f | jsexpr   — checked at claim. #f admits; a
;;        hash DEFERS the job (it stays queued rather than failing) and SAYS WHY.
;;   on-hold : (conn team job-id reason) -> void — called when a claim is
;;        actually deferred, so the deferral can be recorded (issue #55).
;;   record! : (conn team result) -> void  — bills usage after a successful run.
;;
;; `hold-reason` answers with the reason rather than a boolean because the same
;; question has two askers: the claim, which must decide, and `GET /api/jobs`,
;; which must explain. A boolean admission check plus a separate "why is this
;; queued" reader would be two implementations of one policy, and they would
;; drift — so the policy is asked once, here, and both callers read its answer.
;; It must stay PURE: the job listing calls it on every read.
(define *hold-reason* (box (lambda (_conn _team) #f)))
(define *on-hold* (box (lambda (_conn _team _id _reason) (void))))
(define *record!* (box (lambda (_conn _team _result) (void))))
(define (set-hold-reason! f) (set-box! *hold-reason* f))
(define (set-on-hold! f) (set-box! *on-hold* f))
(define (set-record!! f) (set-box! *record!* f))
;; the same policies, for the pull worker's claim path (domain/exec/pull.rkt)
(define (scheduler-cap-for) (unbox *cap-for*))
(define (scheduler-hold-reason) (unbox *hold-reason*))
(define (scheduler-on-hold) (unbox *on-hold*))
(define (scheduler-record!) (unbox *record!*))
;; the lease reaper, installed by the pull module. It runs on EVERY pool tick,
;; not only an idle one (issue #54: the comment and the design both said idle,
;; so a reader planned against a delay that is not there) — an expired lease
;; is noticed within one tick of the pool doing anything at all.
(define *reaper* (box (lambda (_conn) 0)))
(define (set-reaper! f) (set-box! *reaper* f))

;; how long a claimed in-process job's lease runs, and how often the worker
;; thread refreshes it. Deliberately the same 120s the pull path uses — one
;; reaper covers both, and a pool job is no more recoverable than a remote one.
(define POOL-LEASE-SECONDS 120)

;; SCHED-9: the platform's wall-clock ceiling on ONE job, so a handler that hangs
;; cannot hold a team's concurrency slot for ever. 30 minutes: long enough for a
;; batch of model calls (the per-request deadline is 120s and an agent flow makes
;; many), short enough that a wedged job is noticed the same day. `never`
;; disables it — the same vocabulary a token's ttl uses. An unparseable or
;; non-positive value falls back to the default, never to 0, which would cancel
;; every job the instant it started.
(define MAX-JOB-SECONDS-DEFAULT 1800)
(define (max-job-seconds)
  (define v (getenv "TELEMACHUS_MAX_JOB_SECONDS"))
  (define t (and v (string-trim v)))
  (cond
    [(and t (string-ci=? t "never")) #f]
    [else
     (define n (and t (string->number t)))
     (if (and (real? n) (> n 0)) (inexact->exact (floor n)) MAX-JOB-SECONDS-DEFAULT)]))

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
  ;; `started_epoch` is the clock SCHED-9's ceiling is measured against, and it is
  ;; set HERE because this is the one claim both paths make (issue #17). A second
  ;; claim path appearing later would leave it NULL and the ceiling would quietly
  ;; stop applying to those jobs — test/sched-tests.rkt asserts the column is set
  ;; by every claim for that reason.
  ;; the fencing token for THIS attempt (issue #24): every later write about this
  ;; run carries it, so a previous attempt that is still alive cannot be mistaken
  ;; for the current one — not even by the same holder re-claiming the job.
  (define token (new-id))
  (define r (query conn
    (string-append "UPDATE jobs SET status='running', started_at=CURRENT_TIMESTAMP, started_epoch=?, "
                   "lease_until=?, executor_id=?, claim_token=? WHERE id = ? AND status='queued' RETURNING id")
    (now) lease (or executor sql-null) token id))
  (and (rows-result? r) (pair? (rows-result-rows r)) token))

;; Terminal write, guarded on still holding THIS attempt: a run whose lease expired
;; and was re-queued must not land its result on top of the new one. `status` alone
;; is not enough — the job may be running again — so the attempt's claim token is
;; part of the condition (issue #24). Returns #t if this call wrote the row.
(define (finish! conn id status #:result [result #f] #:error [err #f] #:token [token #f])
  ;; same rule as settle-canceling!: the token rides along only when the query
  ;; names it. (A #f token with no placeholder used to be a parameter-count error,
  ;; which only a caller that passed none could reach.)
  (define r (apply query conn
    (string-append "UPDATE jobs SET status=?, result=?, error=?, lease_until=NULL, claim_token=NULL, "
                   "finished_at=CURRENT_TIMESTAMP WHERE id = ? AND status='running'"
                   (if token " AND claim_token = ?" "") " RETURNING id")
    status (if result (seal-result id result) sql-null) (if err (seal-error id err) sql-null) id
    (if token (list token) '())))
  (and (rows-result? r) (pair? (rows-result-rows r))))

;; Keep the lease alive while the handler runs, and enforce SCHED-9's ceiling.
;; The refresher is a thread on the same connection (Racket serializes ops),
;; killed when the handler returns; if the process dies, so does it, and the
;; lease lapses — which is the point.
;;
;; It refreshes a job that is `canceling` as well as one that is `running`, so a
;; cancelled job's slot stays counted (and the job stays un-reaped) until its
;; handler actually stops. The ONE thing that makes it give up is the ceiling:
;; past it, the job is flipped to `canceling` with a reason and the refresher
;; EXITS, so the lease lapses and the reaper settles the row — bounding a wedged
;; handler's slot at ceiling + one lease instead of for ever.
;; ONE tick of that work, exported because the loop sleeps 40 seconds and a test
;; cannot wait it out: the interesting behaviour is what a tick decides, not when
;; it happens. Answers 'timed-out when the job is past its ceiling (and marks it),
;; 'refreshed otherwise. Both writes are guarded on the attempt's claim token,
;; like every other write about a run: a reaped-and-re-claimed job must not be
;; timed out on the old attempt's clock, nor have its lease extended by it.
(define (lease-tick! conn id token deadline)
  (cond
    [(and deadline (> (now) deadline))
     (query-exec conn
       (string-append "UPDATE jobs SET status='canceling', error=? WHERE id = ? AND "
                      LIVE-IN " AND claim_token = ?")
       (seal-error id
         (~a "exceeded the instance's maximum job run time ("
             "TELEMACHUS_MAX_JOB_SECONDS=" (or (max-job-seconds) "never") ")"))
       id token)
     'timed-out]
    [else
     (query-exec conn
       (string-append "UPDATE jobs SET lease_until = ? WHERE id = ? AND " LIVE-IN " AND claim_token = ?")
       (+ (now) POOL-LEASE-SECONDS) id token)
     'refreshed]))

(define (with-lease conn id token thunk)
  (define cap (max-job-seconds))
  (define deadline (and cap (+ (now) cap)))
  (define beat (thread (lambda ()
                         (let loop ()
                           (sleep (/ POOL-LEASE-SECONDS 3))
                           (define v (with-handlers ([exn:fail? (lambda (_) 'refreshed)])
                                       (lease-tick! conn id token deadline)))
                           (when (eq? v 'refreshed) (loop))))))
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
    (query-exec conn (string-append "UPDATE jobs SET status='queued', started_at=NULL, started_epoch=NULL, "
                                    "claim_token=NULL "
                                    "WHERE id = ? AND status='running' AND lease_until IS NULL") id))
  ;; A job that was CANCELING when the process died is settled, never re-queued:
  ;; cancellation is final, and re-running work somebody stopped is the one
  ;; outcome nobody asked for.
  (define stopping (query-list conn "SELECT id FROM jobs WHERE status='canceling' AND lease_until IS NULL"))
  (for ([id (in-list stopping)]) (settle-canceling! conn id))
  (+ (length ids) (length stopping)))

(define (claim-next! conn)
  (call-with-semaphore claim-lock
    (lambda ()
      (define cap-for (unbox *cap-for*))
      (define candidates (query-rows conn
        "SELECT id, team_id, kind, parent_job_id FROM jobs WHERE status='queued' ORDER BY priority DESC, created_at ASC LIMIT 32"))
      (for/or ([r (in-list candidates)])
        (define id (vector-ref r 0))
        (define team (vector-ref r 1))
        ;; LIVE-IN, not `status='running'`: a job being canceled is still running
        ;; code and still spending the team's budget until its handler stops.
        (define running (query-value conn (string-append "SELECT COUNT(*) FROM jobs WHERE team_id = ? AND " LIVE-IN) team))
        (and (not (remote-kind? (vector-ref r 2)))                 ; a pull worker's, not the pool's
             ;; a sub-job of an admitted parent is exempt from the cap — the parent holds the slot
             (or (not (sql-null? (vector-ref r 3))) (< running (cap-for team)))
             ;; quota gate — over-budget teams defer, and the deferral is RECORDED
             ;; rather than silent (issue #55): a queue that stops with nothing
             ;; running and nothing logged is indistinguishable from a hang.
             (let ([hold ((unbox *hold-reason*) conn team)])
               (cond
                 [hold ((unbox *on-hold*) conn team id hold) #f]
                 [else #t]))
             ;; believed only if the conditional update actually took the row; the
             ;; token it returns fences every later write about this attempt
             (let ([token (claim-job! conn id #:lease (+ (now) POOL-LEASE-SECONDS))])
               (and token (cons id token))))))))

(define (run-claimed! conn id [token #f])
  (define r (query-maybe-row conn "SELECT team_id, user_id, kind, payload FROM jobs WHERE id = ?" id))
  (when r
    (define team (vr r 0)) (define user (vr r 1)) (define kind (vr r 2))
    ;; Unsealed BEFORE parsing. The handler below swallows a parse failure into an
    ;; empty payload — which is the right call for a corrupt row, and means a
    ;; MISSED UNSEAL here would not raise: the kind would quietly run on nothing.
    ;; So this is the one read site whose mistake is silent, and
    ;; test/dump-leak-tests.rkt asserts a job's RESULT is still correct with
    ;; encryption on, which is what would catch it.
    (define payload (with-handlers ([exn:fail? (lambda (_) (hasheq))])
                      (string->jsexpr (unseal-payload id (vr r 3)))))
    (define handler (hash-ref *kinds* kind #f))
    (with-handlers ([exn:fail? (lambda (e)
                                 (unless (finish! conn id "error" #:error (exn-message e) #:token token)
                                   (settle-canceling! conn id token)))])
      (cond
        [(not handler)
         (finish! conn id "error" #:error "unknown job kind" #:token token)]
        [else
         (define result (with-lease conn id token
                          (lambda ()
                            (parameterize ([current-job (hasheq 'id id 'team team 'user user)])
                              (handler conn (user-principal conn user team) payload)))))
         ;; bill only what we actually recorded: a run whose lease lapsed mid-flight
         ;; has been re-queued, and the new attempt will bill its own usage.
         (cond
           [(finish! conn id "done" #:result (jsexpr->string result) #:token token)
            ((unbox *record!*) conn team result)]       ; meter usage for a successful run
           ;; finish! matched nothing: either this attempt was reaped (token
           ;; cleared, nothing to do — the new attempt owns the row) or the job
           ;; was cancelled while it ran. In the second case the handler has now
           ;; stopped, which is the moment the slot is genuinely free, so settle
           ;; the row. The result is deliberately discarded: it is the answer to a
           ;; question the caller withdrew.
           [else (settle-canceling! conn id token)])]))))

;; synchronous: claim + run the next queued job. Returns its id, or #f if none.
;; Used by the worker loop and directly by tests.

;; ---- what THIS process is holding right now (issue #89) ---------------------
;;
;; A graceful shutdown has to know which attempts are its own, and the jobs table
;; cannot say: an in-process claim leaves `executor_id` NULL, so "running with no
;; executor" is every replica's pool work, not this one's. Requeueing by that
;; query would steal a sibling's in-flight jobs the moment one replica restarted
;; — which is exactly the deployment the container story invites.
;;
;; So the pool keeps its own register, the shape the reference worker's `held` box
;; already uses for one job. Maintained in a dynamic-wind so it is right however
;; run-claimed! exits.
(define inflight-lock (make-semaphore 1))
(define *inflight* (make-hash))            ; job id -> claim token

(define (inflight-add! id token)
  (call-with-semaphore inflight-lock (lambda () (hash-set! *inflight* id token))))
(define (inflight-remove! id)
  (call-with-semaphore inflight-lock (lambda () (hash-remove! *inflight* id))))
(define (scheduler-inflight-count)
  (call-with-semaphore inflight-lock (lambda () (hash-count *inflight*))))
(define (inflight-snapshot)
  (call-with-semaphore inflight-lock (lambda () (hash->list *inflight*))))

(define (process-one! conn)
  (define claimed (claim-next! conn))
  (and claimed
       (let ([id (car claimed)] [token (cdr claimed)])
         (inflight-add! id token)
         (dynamic-wind
          void
          (lambda () (run-claimed! conn id token) id)
          (lambda () (inflight-remove! id))))))

;; ---- the bounded worker pool ------------------------------------------------
(define *run* (box #f))
(define (start-scheduler! conn #:workers [n 2] #:idle [idle 0.2] #:cap-for [cf #f]
                          #:hold-reason [hold #f] #:on-hold [onhold #f] #:record! [rec #f])
  (when cf (set-cap-for! cf))
  (when hold (set-hold-reason! hold))
  (when onhold (set-on-hold! onhold))
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

;; ---- graceful shutdown (issue #89) ------------------------------------------

;; How long to let in-flight jobs finish. The default has to fit INSIDE the
;; orchestrator's own patience or the drain is pointless — it would be SIGKILLed
;; halfway, which is strictly worse than a short clean one. Kubernetes allows 30s
;; by default (`terminationGracePeriodSeconds`) and systemd 90s
;; (`TimeoutStopSec`), so 25 fits under both; `docker stop` allows only 10, which
;; is why the compose file and the docs pass `-t`/`stop_grace_period`.
;; An unparseable or non-positive value falls back to the default, never to 0 —
;; the platform's rule for every interval knob, and a 0 here would make the
;; "graceful" path identical to a kill.
(define DEFAULT-DRAIN-SECONDS 25)
(define (drain-seconds)
  (define raw (getenv "TELEMACHUS_DRAIN_SECONDS"))
  (define n (and raw (string->number (string-trim raw))))
  (cond [(and (real? n) (> n 0)) (inexact->exact (floor n))]
        [(and raw (member (string-downcase (string-trim raw)) '("never" "0"))) 0]
        [else DEFAULT-DRAIN-SECONDS]))

;; Hand a job back WITHOUT blaming it: queued again, same attempt, same
;; `releases`. An operator restarting a box is not the job's fault, and neither
;; counter should move —
;;
;;   • `attempt` is what PULL-12 established: spending one for the host's
;;     business is how healthy jobs reached `error`. A rolling deploy would
;;     otherwise burn an attempt per replica per restart.
;;   • `releases` is deliberately NOT used either, even though it is the bound on
;;     a worker's release loop. Its ceiling (MAX-RELEASES) FAILS the job, so a
;;     crashlooping deployment would fail every job it touched after ten
;;     restarts. Nothing bounds a restart loop here, on purpose: the honest
;;     outcome of a box that cannot stay up is a queue that does not move, not a
;;     queue full of jobs marked broken.
;;
;; Fenced on the attempt's claim_token like every other post-claim write (issue
;; #24), so a job whose lease already lapsed and was re-claimed elsewhere is left
;; alone. A job being CANCELED is settled rather than requeued — SCHED-8's rule,
;; and re-running work somebody stopped is the one outcome nobody asked for.
(define (drain-release! conn id token)
  (define st (query-maybe-value conn "SELECT status FROM jobs WHERE id = ?" id))
  (cond
    [(equal? st "canceling") (settle-canceling! conn id token) 'canceled]
    [else
     ;; Audited BEFORE the write, for FLEET-1's reason: the requeue clears
     ;; `executor_id` and resets the clock, so afterwards nothing says this job
     ;; was interrupted by a shutdown rather than simply queued.
     (define team (let ([t (query-maybe-value conn "SELECT team_id FROM jobs WHERE id = ?" id)])
                    (if (or (not t) (sql-null? t)) sql-null t)))
     (with-handlers ([exn:fail? void])
       (audit! conn #:action "job.drained" #:actor-type "system"
               #:team-id team #:resource-type "job" #:resource-id id
               #:result "requeued"
               #:meta (jsexpr->string (hasheq 'reason "shutdown"))))
     (define r (query conn
       (string-append "UPDATE jobs SET status='queued', executor_id=NULL, lease_until=NULL, "
                      "claim_token=NULL, started_at=NULL, started_epoch=NULL "
                      "WHERE id = ? AND claim_token = ? AND status='running' RETURNING id")
       id token))
     (if (and (rows-result? r) (pair? (rows-result-rows r))) 'requeued 'not-ours)]))

;; Stop claiming, wait for in-flight work, then hand back whatever did not
;; finish. Returns (values finished requeued) — how many completed on their own
;; and how many went back to the queue.
;;
;; `stop` is start-scheduler!'s own thunk; passing it keeps this function from
;; needing to know that the flag is a box.
(define (drain-scheduler! conn #:stop [stop #f] #:seconds [secs (drain-seconds)]
                          #:log [log void])
  (if stop (stop) (set-box! *run* #f))        ; claim nothing further
  (define before (scheduler-inflight-count))
  (define deadline (+ (current-inexact-milliseconds) (* 1000.0 secs)))
  (let wait ([announced #f])
    (define n (scheduler-inflight-count))
    (cond
      [(zero? n) (void)]
      [(>= (current-inexact-milliseconds) deadline)
       (log (format "drain: ~a job(s) did not finish within ~as — handing them back" n secs))]
      [else
       (unless announced
         (log (format "drain: waiting up to ~as for ~a running job(s)" secs n)))
       (sleep 0.25)
       (wait #t)]))
  ;; whatever is still held is handed back, blamelessly
  (define left (inflight-snapshot))
  (define requeued
    (for/sum ([p (in-list left)])
      (define outcome
        (with-handlers ([exn:fail? (lambda (e)
                                     (log (format "drain: could not hand back ~a: ~a"
                                                  (car p) (exn-message e)))
                                     'error)])
          (drain-release! conn (car p) (cdr p))))
      (if (eq? outcome 'requeued) 1 0)))
  (values (- before (length left)) requeued))
