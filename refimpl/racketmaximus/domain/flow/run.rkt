#lang racket/base

;; domain/flow/run.rkt — publishing definitions, and running them.
;;
;; The interpreter is a REDUCER, not a thread. `flow-advance!` reads the run's
;; cursor and its completed steps *from the database*, decides the next step, and
;; enqueues it as a scheduler job of kind "flow.step". When that job finishes it
;; records the output and calls `flow-advance!` again. Nothing about a run lives in
;; memory, which is what makes a restart mid-run a non-event: the rows are the
;; state. It is the discipline `domain/agent/loop.rkt` established — a decision
;; spine with the effects injected — applied one level up.
;;
;; Everything else is inherited rather than built: each step is a job, so the
;; scheduler's durability, cancellation, per-team concurrency cap and quota
;; admission already apply, and `can?` (with the org gate at step 0) is re-checked
;; on every step against the principal the run pinned at start.

(require db-kit/portable
         racket/list
         racket/string
         json
         "../db/id.rkt"
         "../authz/authz.rkt"
         "../features/features.rkt"
         "../sched/scheduler.rkt"
         "../agent/registry.rkt"
         "spec.rkt"
         "bind.rkt")

(provide flow-publish! flow-defs flow-def-get flow-def-by-slug
         flow-run-start! flow-run-get flow-runs flow-run-cancel!
         flow-advance! flow-step-execute!
         register-plugin-workflow! plugin-workflows
         FLOW-JOB-KIND)

(define FLOW-JOB-KIND "flow.step")
(define FEATURE "workflows")

(define (vr r i) (vector-ref r i))
(define (nz x) (if (sql-null? x) 'null x))
(define (js s) (if (or (not s) (sql-null? s)) (hasheq)
                   (with-handlers ([exn:fail? (lambda (_) (hasheq))]) (string->jsexpr s))))

;; ---- definitions -------------------------------------------------------------
(define DSELECT
  "SELECT id, team_id, slug, version, source, spec, status, created_by, created_at FROM workflow_defs")

(define (row->def r #:spec [with-spec #t])
  (define spec (js (vr r 5)))
  ;; name/description ride along even when the spec body is dropped: a listing has to
  ;; be able to say what a workflow IS, and they are the only human-readable fields.
  (define base (hasheq 'id (vr r 0) 'team_id (vr r 1) 'slug (vr r 2) 'version (vr r 3)
                       'source (vr r 4) 'status (vr r 6)
                       'name (hash-ref spec 'name (vr r 2))
                       'description (hash-ref spec 'description 'null)
                       'step_count (length (hash-ref spec 'steps '()))
                       'created_by (nz (vr r 7)) 'created_at (vr r 8)))
  (if with-spec (hash-set base 'spec spec) base))

;; A definition is an ownable resource, so cross-org reads die at step 0 of `can?`
;; rather than at a WHERE clause. Visibility is "team": per TEN-2a an org admin may
;; see what automation runs inside their company even though they may not read the
;; data it touches.
(define (def->resource d)
  (hasheq 'resource_type "workflows" 'resource_id (hash-ref d 'id)
          'team_id (hash-ref d 'team_id)
          'owner_user_id (let ([u (hash-ref d 'created_by)]) (if (eq? u 'null) sql-null u))
          'visibility "team"))

;; Publish a definition. The document goes through `validate-spec` here and
;; nowhere else — the same call the macro makes — so there is one definition of
;; "valid" for JSON and Racket alike. Re-publishing a slug bumps its version;
;; history is kept, since a running flow references the version it started on.
(define (flow-publish! conn p doc #:source [source "db"])
  (require-perm conn p "workflows:write")
  (define spec (validate-spec doc))
  (define team (principal-team-id p))
  (define slug (spec-slug spec))
  (define prev (query-maybe-value conn
    "SELECT MAX(version) FROM workflow_defs WHERE team_id = ? AND slug = ?" team slug))
  (define version (if (or (not prev) (sql-null? prev)) 1 (add1 prev)))
  (define id (new-id))
  (query-exec conn
    "INSERT INTO workflow_defs (id, team_id, slug, version, source, spec, created_by) VALUES (?, ?, ?, ?, ?, ?, ?)"
    id team slug version source (jsexpr->string spec) (principal-user-id p))
  (audit! conn #:action "workflow.publish" #:actor-type "user" #:actor-id (principal-user-id p)
          #:team-id team #:resource-type "workflows" #:resource-id id
          #:meta (jsexpr->string (hasheq 'slug slug 'version version 'source source)))
  (row->def (query-maybe-row conn (string-append DSELECT " WHERE id = ?") id)))

;; ---- plugin-contributed definitions ------------------------------------------
;; A plugin ships specs, not rows: it has no team to publish into at load time.
;; They are held here and MATERIALIZED into a team's `workflow_defs` the first time
;; that team looks one up, so a run still references a real, versioned row and the
;; foreign key stays honest. Idempotent — a second lookup finds the row.
(define *plugin-workflows* (box '()))

(define (register-plugin-workflow! plugin-id spec)
  (define valid (validate-spec spec))
  (set-box! *plugin-workflows*
            (append (filter (lambda (e) (not (equal? (spec-slug (cdr e)) (spec-slug valid))))
                            (unbox *plugin-workflows*))
                    (list (cons plugin-id valid))))
  valid)

(define (plugin-workflows)
  (for/list ([e (in-list (unbox *plugin-workflows*))])
    (hasheq 'plugin (car e) 'slug (spec-slug (cdr e)) 'spec (cdr e))))

(define (materialize-plugin-defs! conn team)
  (for ([e (in-list (unbox *plugin-workflows*))])
    (define spec (cdr e))
    (unless (query-maybe-value conn "SELECT id FROM workflow_defs WHERE team_id = ? AND slug = ?"
                               team (spec-slug spec))
      ;; Two requests can reach this line together — the console fires the
      ;; Workflows tab's list and a "Run workflow…" lookup in parallel on a team
      ;; that has never looked — and both see no row. The UNIQUE(team_id, slug,
      ;; version) makes the second insert a no-op rather than a 500.
      (query-exec conn
        (string-append "INSERT INTO workflow_defs (id, team_id, slug, version, source, spec) VALUES (?, ?, ?, 1, ?, ?) "
                       "ON CONFLICT (team_id, slug, version) DO NOTHING")
        (new-id) team (spec-slug spec) (string-append "plugin:" (car e)) (jsexpr->string spec)))))

(define (flow-defs conn p)
  (require-perm conn p "workflows:read")
  (materialize-plugin-defs! conn (principal-team-id p))
  (for/list ([r (in-list (query-rows conn
       (string-append DSELECT " WHERE team_id = ? AND status = 'active' ORDER BY slug ASC, version DESC")
       (principal-team-id p)))])
    (row->def r #:spec #f)))

(define (flow-def-get conn p id)
  (define r (query-maybe-row conn (string-append DSELECT " WHERE id = ?") id))
  (and r (let ([d (row->def r)])
           (require-perm conn p "workflows:read" #:resource (def->resource d))
           d)))

;; the newest active version of a slug in the caller's team
(define (flow-def-by-slug conn p slug)
  (require-perm conn p "workflows:read")
  (materialize-plugin-defs! conn (principal-team-id p))
  (define r (query-maybe-row conn
    (string-append DSELECT " WHERE team_id = ? AND slug = ? AND status = 'active' ORDER BY version DESC LIMIT 1")
    (principal-team-id p) slug))
  (and r (let ([d (row->def r)])
           (require-perm conn p "workflows:read" #:resource (def->resource d))
           d)))

;; ---- runs --------------------------------------------------------------------
(define RSELECT
  ;; the def's slug rides along so a run can name itself without a second lookup —
  ;; the console lists runs before it has fetched any definition.
  (string-append "SELECT id, def_id, team_id, user_id, status, input, output, error, cursor_json, "
                 "steps_used, created_at, started_at, finished_at, "
                 "(SELECT slug FROM workflow_defs d WHERE d.id = workflow_runs.def_id) "
                 "FROM workflow_runs"))

(define (row->run r)
  (hasheq 'id (vr r 0) 'def_id (vr r 1) 'team_id (vr r 2) 'user_id (vr r 3)
          'status (vr r 4) 'input (js (vr r 5))
          'output (if (sql-null? (vr r 6)) 'null (js (vr r 6)))
          'error (nz (vr r 7)) 'cursor (js (vr r 8)) 'steps_used (vr r 9)
          'created_at (vr r 10) 'started_at (nz (vr r 11)) 'finished_at (nz (vr r 12))
          'slug (nz (vr r 13))))

(define (run-row conn id) (query-maybe-row conn (string-append RSELECT " WHERE id = ?") id))

(define SSELECT
  (string-append "SELECT id, run_id, step_id, seq, status, attempt, job_id, input, output, error, "
                 "started_at, finished_at, parent_id FROM workflow_steps"))

(define (row->step r)
  (hasheq 'id (vr r 0) 'run_id (vr r 1) 'step_id (vr r 2) 'seq (vr r 3) 'status (vr r 4)
          'attempt (vr r 5) 'job_id (nz (vr r 6))
          'input (if (sql-null? (vr r 7)) 'null (js (vr r 7)))
          'output (if (sql-null? (vr r 8)) 'null (js (vr r 8)))
          'error (nz (vr r 9)) 'started_at (nz (vr r 10)) 'finished_at (nz (vr r 11))
          'parent_id (nz (vr r 12))))

(define (run-steps conn run-id)
  (for/list ([r (in-list (query-rows conn (string-append SSELECT " WHERE run_id = ? ORDER BY seq ASC") run-id))])
    (row->step r)))

;; the binding context: the latest completed output per step id, so a loop's second
;; pass sees its own results rather than the first pass's
(define (outputs-of conn run-id)
  (for/fold ([h (hasheq)]) ([s (in-list (run-steps conn run-id))]
                            #:when (equal? (hash-ref s 'status) "done"))
    (hash-set h (string->symbol (hash-ref s 'step_id)) (hash-ref s 'output))))

(define (base-step-id sid) (car (string-split sid "#")))

;; the fan-out this step belongs to, or #f. NOT (hash-ref st 'parent_id) — that is
;; 'null for an ordinary step, and 'null is truthy.
(define (parent-of st) (let ([v (hash-ref st 'parent_id)]) (and (string? v) v)))

(define (spec-of conn run)
  (js (query-value conn "SELECT spec FROM workflow_defs WHERE id = ?" (hash-ref run 'def_id))))

;; declared inputs must be present and of the declared type — a cheap check that
;; turns a whole class of "the binding resolved to null" mysteries into one error
(define (check-input! spec input)
  (for ([(k t) (in-hash (hash-ref spec 'input (hasheq)))])
    (define v (hash-ref input k 'missing))
    (when (eq? v 'missing) (error 'flow "input '~a' is required" k))
    (define ok?
      (case t
        [("string") (string? v)] [("number") (real? v)] [("boolean") (boolean? v)]
        [("object") (hash? v)]   [("array") (list? v)]  [else #t]))
    (unless ok? (error 'flow "input '~a' must be a ~a" k t))))

;; the binding context for a run, optionally inside a map iteration
(define (context-for conn run #:item [item 'none] #:index [index 'none])
  (make-context #:input (hash-ref run 'input)
                #:outputs (outputs-of conn (hash-ref run 'id))
                #:run-id (hash-ref run 'id)
                #:team-id (hash-ref run 'team_id)
                #:user-id (hash-ref run 'user_id)
                #:locale (user-locale conn (hash-ref run 'user_id))
                #:item item #:index index))

(define (flow-run-start! conn p def #:input [input (hasheq)])
  (require-perm conn p "workflows:run")
  (unless (feature-enabled? conn (principal-team-id p) FEATURE)
    (error 'flow "workflows are disabled for this team"))
  (define spec (hash-ref def 'spec))
  (check-input! spec input)
  (define id (new-id))
  (query-exec conn
    (string-append "INSERT INTO workflow_runs (id, def_id, team_id, user_id, status, input, cursor_json, started_at) "
                   "VALUES (?, ?, ?, ?, 'running', ?, ?, CURRENT_TIMESTAMP)")
    id (hash-ref def 'id) (principal-team-id p) (principal-user-id p)
    (jsexpr->string input) (jsexpr->string (hasheq 'next (spec-start spec))))
  (audit! conn #:action "workflow.run" #:actor-type "user" #:actor-id (principal-user-id p)
          #:team-id (principal-team-id p) #:resource-type "workflows" #:resource-id (hash-ref def 'id)
          #:meta (jsexpr->string (hasheq 'run_id id 'slug (hash-ref def 'slug))))
  (flow-advance! conn id)
  (flow-run-get* conn id))

(define (flow-run-get* conn id)
  (define r (run-row conn id))
  (and r (let ([run (row->run r)]) (hash-set run 'steps (run-steps conn id)))))

(define (flow-run-get conn p id)
  (define r (run-row conn id))
  (and r (let ([run (row->run r)])
           (require-perm conn p "workflows:read"
                         #:resource (hasheq 'resource_type "workflows" 'resource_id (hash-ref run 'def_id)
                                            'team_id (hash-ref run 'team_id)
                                            'owner_user_id (hash-ref run 'user_id) 'visibility "team"))
           (hash-set run 'steps (run-steps conn id)))))

(define (flow-runs conn p #:limit [lim 50])
  (require-perm conn p "workflows:read")
  (for/list ([r (in-list (query-rows conn
       (string-append RSELECT " WHERE team_id = ? ORDER BY created_at DESC LIMIT ?")
       (principal-team-id p) lim))])
    (row->run r)))

;; Cancel affects work not yet done: the run is marked, and the pending step job
;; no-ops when it is claimed (SCHED-7 — cancelable, not preemptible, so a step
;; already running finishes).
(define (flow-run-cancel! conn p id)
  (define run (flow-run-get conn p id))
  (and run
       (cond
         [(member (hash-ref run 'status) '("done" "error" "canceled")) 'not-cancelable]
         [else
          (require-perm conn p "workflows:run")
          (finish! conn id "canceled" #:error "canceled by request")
          #t])))

(define (finish! conn id status #:error [err #f] #:output [out #f])
  (query-exec conn
    "UPDATE workflow_runs SET status = ?, error = ?, output = ?, cursor_json = '{}', finished_at = CURRENT_TIMESTAMP WHERE id = ?"
    status (or err sql-null) (if out (jsexpr->string out) sql-null) id))

;; ---- the reducer -------------------------------------------------------------
;; advance : (conn run-id) -> void. Reads state from the DB, decides, enqueues.
(define (flow-advance! conn run-id)
  (define r (run-row conn run-id))
  (when r
    (define run (row->run r))
    (when (equal? (hash-ref run 'status) "running")
      (define spec (spec-of conn run))
      (define next (hash-ref (hash-ref run 'cursor) 'next 'null))
      (define used (hash-ref run 'steps_used))
      (cond
        [(eq? next 'null)
         ;; nothing left: the run's output is the last completed step's
         (define done (filter (lambda (s) (equal? (hash-ref s 'status) "done")) (run-steps conn run-id)))
         (finish! conn run-id "done" #:output (if (null? done) (hasheq) (hash-ref (last done) 'output)))]
        [(>= used (spec-max-steps spec))
         (finish! conn run-id "error"
                  #:error (format "max_steps exceeded (~a) — the workflow did not terminate" (spec-max-steps spec)))]
        [(not (step-ref spec next))
         (finish! conn run-id "error" #:error (format "step '~a' is not in this workflow" next))]
        [(eq? (step-kind (step-ref spec next)) 'map) (start-map! conn run spec next used)]
        [else
         (define sid (new-id))
         (query-exec conn
           "INSERT INTO workflow_steps (id, run_id, step_id, seq, status, attempt) VALUES (?, ?, ?, ?, 'queued', 1)"
           sid run-id next used)
         (query-exec conn "UPDATE workflow_runs SET steps_used = ? WHERE id = ?" (add1 used) run-id)
         (enqueue-step! conn run sid)]))))

;; Fan out: one parent row that stays `running` while N child jobs drain. The
;; children are ordinary scheduler jobs, so the team's concurrency cap is the only
;; thing bounding the parallelism — that is the whole reason a step is a job.
(define (start-map! conn run spec map-id used)
  (define run-id (hash-ref run 'id))
  (define st (step-ref spec map-id))
  (define items (resolve-value (hash-ref st 'over) (context-for conn run)))
  (cond
    [(not (list? items))
     (finish! conn run-id "error" #:error (format "step '~a': 'over' did not resolve to an array" map-id))]
    [(> (+ used 1 (length items)) (spec-max-steps spec))
     (finish! conn run-id "error"
              #:error (format "step '~a': fanning out ~a items would exceed max_steps (~a)"
                              map-id (length items) (spec-max-steps spec)))]
    [else
     (define pid (new-id))
     (query-exec conn
       (string-append "INSERT INTO workflow_steps (id, run_id, step_id, seq, status, attempt, input, started_at) "
                      "VALUES (?, ?, ?, ?, 'running', 1, ?, CURRENT_TIMESTAMP)")
       pid run-id map-id used (jsexpr->string (hasheq 'count (length items) 'over items)))
     (query-exec conn "UPDATE workflow_runs SET steps_used = ? WHERE id = ?"
                 (+ used 1 (length items)) run-id)
     (cond
       [(null? items) (complete-map! conn run-id pid)]     ; nothing to fan out over
       [else
        (for ([v (in-list items)] [i (in-naturals)])
          (define cid (new-id))
          (query-exec conn
            (string-append "INSERT INTO workflow_steps (id, run_id, parent_id, step_id, seq, status, attempt, input) "
                           "VALUES (?, ?, ?, ?, ?, 'queued', 1, ?)")
            cid run-id pid (format "~a#~a" map-id i) (+ used 1 i)
            (jsexpr->string (hasheq 'item v 'index i)))
          (enqueue-step! conn run cid))])]))

;; Children finish on different worker threads, so the "was I the last one?" read
;; and the parent's write have to be one critical section — otherwise two children
;; both see a full house and the next step is enqueued twice.
(define map-lock (make-semaphore 1))

(define (complete-map! conn run-id parent-id)
  (call-with-semaphore map-lock
    (lambda ()
      (define prow (query-maybe-row conn (string-append SSELECT " WHERE id = ?") parent-id))
      (when prow
        (define parent (row->step prow))
        (when (equal? (hash-ref parent 'status) "running")
          (define expected (hash-ref (hash-ref parent 'input) 'count 0))
          (define kids (for/list ([r (in-list (query-rows conn
                          (string-append SSELECT " WHERE parent_id = ? ORDER BY seq ASC") parent-id))])
                         (row->step r)))
          (when (>= (length (filter (lambda (k) (equal? (hash-ref k 'status) "done")) kids)) expected)
            (define out (hasheq 'results (for/list ([k (in-list kids)]) (hash-ref k 'output))))
            (query-exec conn
              "UPDATE workflow_steps SET status = 'done', output = ?, finished_at = CURRENT_TIMESTAMP WHERE id = ?"
              (jsexpr->string out) parent-id)
            (define rrow (run-row conn run-id))
            (when rrow
              (define run (row->run rrow))
              (define nxt (step-next (spec-of conn run) (step-ref (spec-of conn run) (hash-ref parent 'step_id))))
              (query-exec conn "UPDATE workflow_runs SET cursor_json = ? WHERE id = ?"
                          (jsexpr->string (if nxt (hasheq 'next nxt) (hasheq))) run-id)
              (flow-advance! conn run-id))))))))

(define (enqueue-step! conn run step-row-id)
  (define job (enqueue-job! conn #:team (hash-ref run 'team_id) #:user (hash-ref run 'user_id)
                            #:kind FLOW-JOB-KIND
                            #:payload (hasheq 'run_id (hash-ref run 'id) 'step step-row-id)))
  (query-exec conn "UPDATE workflow_steps SET job_id = ? WHERE id = ?" job step-row-id))

;; ---- executing one step ------------------------------------------------------
;; Registered as the "flow.step" job kind at module level, the way the built-in
;; tools register themselves — so requiring this module is all it takes for the
;; scheduler (and a test calling `process-one!`) to be able to run a workflow.
(define (tool-run! conn p name args)
  (define t (tool-by-name name))
  (unless t (error 'flow "unknown tool '~a' — no plugin registered it" name))
  (unless (tool-enabled? conn (principal-team-id p) name)
    (error 'flow "tool '~a' is disabled for this team" name))
  (require-perm conn p "tools:invoke")                      ; raises → the step fails
  (when (tool-perm t) (require-perm conn p (tool-perm t)))
  ((tool-handler t) conn p args))

(define (flow-step-execute! conn p payload)
  (define run-id (format "~a" (hash-ref payload 'run_id "")))
  (define srow-id (format "~a" (hash-ref payload 'step "")))
  (define srow (query-maybe-row conn (string-append SSELECT " WHERE id = ?") srow-id))
  (define rrow (run-row conn run-id))
  (cond
    [(or (not srow) (not rrow)) (hasheq 'skipped "run or step vanished")]
    [else
     (define run (row->run rrow))
     (define st (row->step srow))
     (cond
       ;; the run was cancelled (or already finished) while this sat in the queue
       [(not (equal? (hash-ref run 'status) "running")) (hasheq 'skipped (hash-ref run 'status))]
       [else
        (define spec (spec-of conn run))
        (define step (step-ref spec (base-step-id (hash-ref st 'step_id))))
        (define child? (and (parent-of st) #t))
        (define ctx
          (if child?
              (context-for conn run
                           #:item (hash-ref (hash-ref st 'input) 'item 'null)
                           #:index (hash-ref (hash-ref st 'input) 'index 0))
              (context-for conn run)))
        (query-exec conn "UPDATE workflow_steps SET status = 'running', started_at = CURRENT_TIMESTAMP WHERE id = ?" srow-id)
        (with-handlers ([exn:fail? (lambda (e) (step-failed! conn run st srow-id (exn-message e)))])
          (define-values (output next)
            (cond
              ;; one item of a fan-out: the map's template, with ${item} bound
              [child?
               (define tmpl (map-template step))
               (define args (resolve-hash (hash-ref tmpl 'with (hasheq)) ctx))
               (query-exec conn "UPDATE workflow_steps SET input = ? WHERE id = ?"
                           (jsexpr->string (hash-set (hash-ref st 'input) 'args args)) srow-id)
               (values (hasheq 'result (tool-run! conn p (substring (hash-ref tmpl 'uses "") 5) args)) 'child)]
              [else
               (case (step-kind step)
              [(tool)
               (define args (resolve-hash (hash-ref step 'with (hasheq)) ctx))
               (query-exec conn "UPDATE workflow_steps SET input = ? WHERE id = ?" (jsexpr->string args) srow-id)
               (define result (tool-run! conn p (step-tool-name step) args))
               (values (hasheq 'result result) (step-next spec step))]
              [(choice)
               (define hit (eval-predicate (hash-ref step 'when) ctx))
               (values (hasheq 'result hit)
                       (if hit (hash-ref step 'then) (hash-ref step 'else (lambda () (step-next spec step)))))]
                 [else (error 'flow "unsupported step kind in '~a'" (hash-ref st 'step_id))])]))
          (query-exec conn
            "UPDATE workflow_steps SET status = 'done', output = ?, finished_at = CURRENT_TIMESTAMP WHERE id = ?"
            (jsexpr->string output) srow-id)
          (cond
            ;; a child never moves the cursor — the parent does, once they are all in
            [(eq? next 'child) (complete-map! conn run-id (parent-of st))]
            [else
             (query-exec conn "UPDATE workflow_runs SET cursor_json = ? WHERE id = ?"
                         (jsexpr->string (if next (hasheq 'next next) (hasheq))) run-id)
             (flow-advance! conn run-id)])
          output)])]))

;; A step that raised is retried in place (a new job for the same step row) while
;; attempts remain; the job that failed still reports ok, because the *step* row is
;; where a run's truth lives and it says 'queued, attempt N+1'.
(define (step-failed! conn run st srow-id message)
  (define spec (spec-of conn run))
  (define step (step-ref spec (base-step-id (hash-ref st 'step_id))))
  (define retry (if (parent-of st)
                    (hash-ref (map-template step) 'retry (hasheq))
                    (hash-ref step 'retry (hasheq))))
  (define allowed (add1 (hash-ref retry 'max 0)))
  (define attempt (hash-ref st 'attempt))
  (cond
    [(< attempt allowed)
     (query-exec conn "UPDATE workflow_steps SET status = 'queued', attempt = ?, error = ? WHERE id = ?"
                 (add1 attempt) message srow-id)
     (enqueue-step! conn run srow-id)
     (hasheq 'retrying (add1 attempt) 'error message)]
    [else
     (query-exec conn
       "UPDATE workflow_steps SET status = 'error', error = ?, finished_at = CURRENT_TIMESTAMP WHERE id = ?"
       message srow-id)
     ;; one bad item fails the whole fan-out, and the fan-out fails the run: the
     ;; siblings still in flight find the run no longer `running` and no-op
     (when (parent-of st)
       (query-exec conn
         "UPDATE workflow_steps SET status = 'error', error = ?, finished_at = CURRENT_TIMESTAMP WHERE id = ?"
         message (parent-of st)))
     (finish! conn (hash-ref run 'id) "error"
              #:error (format "step '~a' failed: ~a" (hash-ref st 'step_id) message))
     (hasheq 'failed (hash-ref st 'step_id) 'error message)]))

(register-job-kind! FLOW-JOB-KIND flow-step-execute!)
