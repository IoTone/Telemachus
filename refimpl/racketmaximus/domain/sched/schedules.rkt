#lang racket/base

;; domain/sched/schedules.rkt — the platform's clock (issue #135).
;;
;; A SCHEDULE IS A ROW THAT ENQUEUES AN ORDINARY JOB, and that is the whole
;; design. There is no second execution path: the job this fires inherits the
;; team, the user, quota admission, the org gate, cancel, the lease, the fence
;; and the entire FLEET surface from `jobs`, exactly as a hand-enqueued job
;; does. Everything here is therefore about WHEN, and nothing about running.
;;
;; The principal is the non-negotiable part. `user_id` is NOT NULL because a
;; schedule with no user is a system principal, and this platform deliberately
;; has none — a job runs as `(user-principal conn user team)`, so there is
;; always somebody `can?` can answer about and always a tenant the org gate can
;; scope to. That is also the complete answer to "who may see what this pulled".

(require db-kit/portable
         json
         racket/string
         "../db/id.rkt"
         (only-in "../authz/sealed.rkt" define-sealed-column)
         (only-in "../authz/authz.rkt" audit!)
         (only-in "scheduler.rkt" enqueue-job! registered-job-kinds)
         "../db/nulls.rkt")

(provide SCHEDULE-MIN-INTERVAL
         schedule-create! schedule-list schedule-get schedule-update! schedule-delete!
         schedule-problem fire-due-schedules! schedule-due-count claim-schedule-tick!)

;; The payload is sealed for the SAME reason `jobs.payload` is (#83 r2): it IS
;; the job's input, copied onto every job this schedule fires, and sealing the
;; destination while leaving the source in the clear beside it protects nothing.
;;
;; It is listed in `CONTENT-SECRETS` in cli/telemachus-secrets.rkt, which
;; `jobs.payload` is not, and the difference is LIFETIME. A job row settles in
;; minutes and #59 purges it; a schedule is configuration that outlives key
;; rotations, so a sealed column `rewrap` does not walk is a schedule that stops
;; firing for ever the first time an operator rotates the key.
(define-sealed-column "job_schedules.payload" (seal-schedule-payload unseal-schedule-payload) (id))

;; A FLOOR, not an operator knob. The tick rides the pool's reaper seam, so an
;; interval shorter than the tick cadence cannot be honoured anyway, and both
;; callers waiting on this (#114's feed poller, #121's periodic plugin work) are
;; minutes-to-hours work. A cron vocabulary was declined: it is a parser plus a
;; timezone question, and the two dialects already disagree about what "day"
;; means (QUOTA-3). An interval is the smaller surface and covers both.
(define SCHEDULE-MIN-INTERVAL 60)
(define FIRE-BATCH 200)

;; A job the schedule fired that has not settled yet. `queued` is in this list
;; as well as the two LIVE statuses, and it has to be: the one-at-a-time rule is
;; what BOUNDS the queue. Without it an over-budget team's schedule enqueues a
;; job every tick for ever — admission defers at CLAIM, not at enqueue, so
;; nothing upstream of here would ever push back.
(define OUTSTANDING '("queued" "running" "canceling"))
(define OUTSTANDING-IN
  (string-append "status IN (" (string-join (for/list ([s (in-list OUTSTANDING)]) (format "'~a'" s)) ",") ")"))

(define (now) (current-seconds))

;; ---- validation ---------------------------------------------------------------
;; -> #f, or one sentence naming the problem. A caller turns it into a 400.
(define (schedule-problem #:kind kind #:interval interval #:payload payload)
  (cond
    [(not (and (string? kind) (not (string=? kind "")))) "kind is required"]
    ;; An unknown kind would fire for ever and enqueue work nothing can run —
    ;; the shape #113 is about, on a timer. Refused at CREATE, where somebody is
    ;; reading the answer.
    [(not (member kind (registered-job-kinds)))
     (format "~a is not a registered job kind" kind)]
    [(not (and (exact-integer? interval) (>= interval SCHEDULE-MIN-INTERVAL)))
     (format "interval_seconds must be a whole number of seconds, at least ~a" SCHEDULE-MIN-INTERVAL)]
    [(not (hash? payload)) "payload must be an object"]
    [else #f]))

;; ---- the row ------------------------------------------------------------------
(define COLS
  (string-append "id, team_id, user_id, name, kind, payload, requirements, priority, "
                 "interval_seconds, paused, next_run_epoch, last_run_epoch, last_job_id, "
                 "fired, skipped, last_skip_reason, last_skip_epoch, created_by, created_epoch"))

(define (row->schedule r)
  (define id (vector-ref r 0))
  (hasheq 'id id
          'team_id (vector-ref r 1)
          'user_id (vector-ref r 2)
          'name (nz (vector-ref r 3))
          'kind (vector-ref r 4)
          'payload (string->jsexpr (unseal-schedule-payload id (vector-ref r 5)))
          'requirements (string->jsexpr (vector-ref r 6))
          'priority (vector-ref r 7)
          'interval_seconds (vector-ref r 8)
          'paused (= 1 (vector-ref r 9))
          'next_run_epoch (vector-ref r 10)
          'last_run_epoch (nz (vector-ref r 11))
          'last_job_id (nz (vector-ref r 12))
          'fired (vector-ref r 13)
          'skipped (vector-ref r 14)
          'last_skip_reason (nz (vector-ref r 15))
          'last_skip_epoch (nz (vector-ref r 16))
          'created_by (nz (vector-ref r 17))
          'created_epoch (vector-ref r 18)))

;; ---- create / read / update / delete -------------------------------------------
(define (schedule-create! conn #:team team #:user user #:kind kind #:interval interval
                          #:payload [payload (hasheq)] #:requirements [req (hasheq)]
                          #:priority [pri 0] #:name [name #f] #:created-by [by #f]
                          #:paused? [paused? #f]
                          ;; The first firing is one interval away, not immediate. A
                          ;; create that fired at once would make every mistaken
                          ;; create cost a run, and the cadence is what was asked for.
                          #:start [start #f])
  (define id (new-id))
  (query-exec conn
    (string-append "INSERT INTO job_schedules (id, team_id, user_id, name, kind, payload, requirements, "
                   "priority, interval_seconds, paused, next_run_epoch, created_by, created_epoch) "
                   "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)")
    id team user (or name sql-null) kind
    (seal-schedule-payload id (jsexpr->string payload))
    ;; `requirements` is NOT sealed, for `jobs.requirements`' own reason: it is
    ;; the kind's matching criteria, filtered on in SQL by a claim, and it holds
    ;; no document content.
    (jsexpr->string req)
    pri interval (if paused? 1 0) (or start (+ (now) interval))
    (or by sql-null) (now))
  id)

(define (schedule-list conn team)
  (for/list ([r (in-list (query-rows conn (string-append "SELECT " COLS " FROM job_schedules WHERE team_id = ? "
                                                         "ORDER BY next_run_epoch ASC, id ASC") team))])
    (row->schedule r)))

;; Team-scoped IN THE STATEMENT, so another team's id is a miss rather than a
;; refusal — the rule the session routes follow (#118).
(define (schedule-get conn id team)
  (define r (query-maybe-row conn (string-append "SELECT " COLS " FROM job_schedules WHERE id = ? AND team_id = ?") id team))
  (and r (row->schedule r)))

;; Only the fields a steward retunes. The PRINCIPAL is never patchable: changing
;; whose authority a timer spends is a new schedule, not an edit, and an edit
;; would leave every audit entry already written naming the wrong person.
(define (schedule-update! conn id team #:interval [interval 'same] #:paused? [paused? 'same]
                          #:payload [payload 'same] #:priority [pri 'same] #:name [name 'same])
  (define cur (schedule-get conn id team))
  (and cur
       (let ()
         (when (exact-integer? interval)
           (query-exec conn "UPDATE job_schedules SET interval_seconds = ? WHERE id = ? AND team_id = ?" interval id team))
         (when (boolean? paused?)
           (query-exec conn "UPDATE job_schedules SET paused = ? WHERE id = ? AND team_id = ?" (if paused? 1 0) id team)
           ;; Resuming moves the due time forward rather than firing for every
           ;; tick missed while paused — the same skip-rather-than-catch-up rule
           ;; the tick itself follows, and here the catch-up would be a burst
           ;; proportional to how long somebody left it off.
           (unless paused?
             (query-exec conn (string-append "UPDATE job_schedules SET next_run_epoch = ? "
                                             "WHERE id = ? AND team_id = ? AND next_run_epoch < ?")
                         (+ (now) (hash-ref cur 'interval_seconds)) id team (now))))
         (when (hash? payload)
           (query-exec conn "UPDATE job_schedules SET payload = ? WHERE id = ? AND team_id = ?"
                       (seal-schedule-payload id (jsexpr->string payload)) id team))
         (when (exact-integer? pri)
           (query-exec conn "UPDATE job_schedules SET priority = ? WHERE id = ? AND team_id = ?" pri id team))
         (when (string? name)
           (query-exec conn "UPDATE job_schedules SET name = ? WHERE id = ? AND team_id = ?" name id team))
         (schedule-get conn id team))))

;; The row goes; jobs it already fired are ordinary jobs and are left alone.
(define (schedule-delete! conn id team)
  (define r (query-maybe-row conn "DELETE FROM job_schedules WHERE id = ? AND team_id = ? RETURNING id" id team))
  (and r #t))

(define (schedule-due-count conn)
  (query-value conn "SELECT COUNT(*) FROM job_schedules WHERE paused = 0 AND next_run_epoch <= ?" (now)))

;; ---- the tick -----------------------------------------------------------------
;; -> (values fired skipped). Rides the pool's reaper seam; see server/main.rkt.
;;
;; THE CLAIM IS ONE GUARDED UPDATE, BELIEVED ONLY IF A ROW COMES BACK —
;; `claim-job!`'s rule (#17), and the only thing in this tree that is already
;; correct about two replicas ticking at once. The guard names the due time this
;; process READ, so of two replicas holding the same row exactly one UPDATE
;; matches and the loser does nothing.
;;
;; Advancing the due time BEFORE deciding whether to fire is deliberate: it
;; makes a crash between the claim and the enqueue cost one SKIPPED tick rather
;; than a duplicate run. Of the two directions a failure can take here, firing
;; twice is the one nobody can undo.
(define (fire-due-schedules! conn)
  (define rows (query-rows conn (string-append "SELECT " COLS " FROM job_schedules "
                                               "WHERE paused = 0 AND next_run_epoch <= ? "
                                               "ORDER BY next_run_epoch ASC LIMIT " (number->string FIRE-BATCH))
                            (now)))
  (for/fold ([fired 0] [skipped 0]) ([r (in-list rows)])
    (define s (row->schedule r))
    (define id (hash-ref s 'id))
    (define due (hash-ref s 'next_run_epoch))
    ;; A MISSED TICK IS SKIPPED, NOT CAUGHT UP: the next due time is computed
    ;; from NOW, so a box that was down for a day fires once and not 1,440
    ;; times against a budget sized for one.
    (define claimed (claim-schedule-tick! conn id due (hash-ref s 'interval_seconds)))
    (cond
      [(not claimed) (values fired skipped)]       ; another replica took this tick
      [else
       ;; ONE AT A TIME per schedule. The previous job still being outstanding
       ;; means the work is not keeping up with its own cadence, and stacking a
       ;; second run on top of it would make that worse rather than visible.
       ;; `nz` renders a SQL NULL as the jsexpr null, which is TRUTHY in Racket —
       ;; so the test has to be `string?`, not the value itself. A schedule that
       ;; had never fired otherwise asks `jobs WHERE id = 'null` and the driver
       ;; refuses the parameter.
       (define outstanding?
         (and (string? (hash-ref s 'last_job_id))
              (query-maybe-value conn (string-append "SELECT id FROM jobs WHERE id = ? AND " OUTSTANDING-IN)
                                 (hash-ref s 'last_job_id))
              #t))
       (cond
         [outstanding?
          (note-skip! conn id "overrun")
          (values fired (add1 skipped))]
         [else
          (with-handlers ([exn:fail? (lambda (e)
                                       ;; One schedule's bad row must not stop the
                                       ;; others, and must not take the lease
                                       ;; reaper down with it.
                                       (note-skip! conn id "error")
                                       (eprintf "schedule ~a: ~a\n" id (exn-message e))
                                       (values fired (add1 skipped)))])
            (define job (enqueue-job! conn #:team (hash-ref s 'team_id) #:user (hash-ref s 'user_id)
                                      #:kind (hash-ref s 'kind) #:payload (hash-ref s 'payload)
                                      #:priority (hash-ref s 'priority)
                                      #:requirements (hash-ref s 'requirements)))
            (query-exec conn (string-append "UPDATE job_schedules SET last_run_epoch = ?, last_job_id = ?, "
                                            "fired = fired + 1 WHERE id = ?")
                        (now) job id)
            ;; The trail has to name the schedule, or a job that appeared with
            ;; nobody present to start it is a job with no explanation. The team
            ;; is the SCHEDULE's team: `audit-list` filters on it, so an entry
            ;; without one is invisible to the people whose budget it spends
            ;; (QUOTA-3's rule, third time).
            (audit! conn #:action "job.schedule.fired" #:actor-type "system"
                    #:team-id (hash-ref s 'team_id)
                    #:resource-type "job_schedule" #:resource-id id
                    #:meta (jsexpr->string (hasheq 'job_id job 'kind (hash-ref s 'kind)
                                                   'interval_seconds (hash-ref s 'interval_seconds))))
            (values (add1 fired) skipped))])])))

;; A SKIP IS NOT AUDITED, and that is a decision rather than an omission: a
;; schedule whose work overruns would write an entry on every tick, which is
;; PULL-14's "report once per outage, not once per check" — the row carries the
;; count, the reason and the time, which is what a reader actually asks for.
;; The claim, on its own, because a test of "two replicas cannot both fire one
;; tick" has to drive the REAL statement: an assertion written over a
;; hand-copied UPDATE agrees with any change made to this one, and a pair of
;; serial `fire-due-schedules!` calls cannot see the difference either — the
;; first advances the due time, so the second finds nothing due and the guard is
;; never exercised. Exported FOR that test (#110 r4's rule: an export with a
;; test behind it is not an over-wide export).
;;
;; -> #t when this process took the tick, #f when another already had it.
(define (claim-schedule-tick! conn id due interval)
  (and (query-maybe-row conn (string-append "UPDATE job_schedules SET next_run_epoch = ? "
                                            "WHERE id = ? AND paused = 0 AND next_run_epoch = ? RETURNING id")
                        (+ (now) interval) id due)
       #t))

(define (note-skip! conn id reason)
  (query-exec conn (string-append "UPDATE job_schedules SET skipped = skipped + 1, "
                                  "last_skip_reason = ?, last_skip_epoch = ? WHERE id = ?")
              reason (now) id))
