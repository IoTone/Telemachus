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
         racket/list
         "../db/id.rkt"
         (only-in "../authz/sealed.rkt" define-sealed-column)
         (only-in "../authz/authz.rkt" audit!)
         (only-in "scheduler.rkt" enqueue-job! registered-job-kinds)
         ;; #140: a wall-clock cadence needs the clock on somebody's wall. zones.rkt
         ;; holds no database, so this module stays free of the settings layer —
         ;; WHOSE zone it is was decided at create time and is on the row.
         (only-in "../time/zones.rkt" civil-from-days days-from-civil local-fields local->epoch zone-exists?)
         "../db/nulls.rkt")

(provide SCHEDULE-MIN-INTERVAL
         schedule-create! schedule-list schedule-get schedule-update! schedule-delete!
         schedule-problem fire-due-schedules! schedule-due-count claim-schedule-tick!
         CADENCES next-firing parse-days)

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

;; A CLOSED vocabulary, like `WORKER-STATES` and `EXTRACT-REASONS`: three ways to
;; say when, and a fourth would arrive as a cadence nothing computes. `interval`
;; is what #135 shipped and stays the default, so every existing row is untouched.
;;
;; CRON WAS DECLINED. Five fields with ranges, steps and lists is a parser and a
;; timezone question, and the two dialects already disagree about what "day"
;; means (QUOTA-3). A time of day plus a set of weekdays covers both callers that
;; were waiting — #114's morning briefing and #121's periodic plugin work — with
;; no grammar at all. If an operator ever needs to paste a real crontab line,
;; that is a translation layer above this, not a second scheduler.
(define CADENCES '("interval" "daily" "weekly"))
(define MINUTES-PER-DAY 1440)
;; How far forward `next-firing` will look for a local time that exists. A year
;; and a bit: enough that no DST rule or weekday set can exhaust it, bounded so a
;; nonsense row cannot spin the tick.
(define FIRING-SEARCH-DAYS 400)

;; "1,2,3,4,5" -> '(1 2 3 4 5), sorted and de-duplicated; #f if it is not a
;; usable set. Sunday = 0, as `local-fields` and POSIX both number it.
(define (parse-days str)
  (and (string? str)
       (let ([parts (filter (lambda (x) (not (string=? x ""))) (string-split (string-trim str) ","))])
         (and (pair? parts)
              (let ([ns (map (lambda (x) (string->number (string-trim x))) parts)])
                (and (andmap (lambda (n) (and (exact-integer? n) (>= n 0) (<= n 6))) ns)
                     (sort (remove-duplicates ns) <)))))))

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
(define (schedule-problem #:kind kind #:interval interval #:payload payload
                          #:cadence [cadence "interval"] #:at-minute [at-minute #f]
                          #:days [days #f] #:timezone [timezone #f])
  (cond
    [(not (and (string? kind) (not (string=? kind "")))) "kind is required"]
    ;; An unknown kind would fire for ever and enqueue work nothing can run —
    ;; the shape #113 is about, on a timer. Refused at CREATE, where somebody is
    ;; reading the answer.
    [(not (member kind (registered-job-kinds)))
     (format "~a is not a registered job kind" kind)]
    [(not (member cadence CADENCES))
     (format "cadence must be one of ~a" (string-join CADENCES ", "))]
    ;; Each cadence is checked for what IT needs, and `interval` keeps #135's
    ;; floor exactly — a wall-clock cadence has no need of one, since a time of
    ;; day cannot recur faster than daily.
    [(and (string=? cadence "interval")
          (not (and (exact-integer? interval) (>= interval SCHEDULE-MIN-INTERVAL))))
     (format "interval_seconds must be a whole number of seconds, at least ~a" SCHEDULE-MIN-INTERVAL)]
    [(and (not (string=? cadence "interval"))
          (not (and (exact-integer? at-minute) (>= at-minute 0) (< at-minute MINUTES-PER-DAY))))
     "at_minute must be the whole minute of the local day, 0 to 1439"]
    [(and (string=? cadence "weekly") (not (parse-days (or days ""))))
     "days_of_week must be a comma-separated set of 0-6, Sunday = 0"]
    ;; The zone is required for a wall-clock cadence and must be one this
    ;; instance has data for: "07:00" means nothing without saying whose 07:00,
    ;; and a schedule quietly given UTC would fire at the wrong hour for ever.
    [(and (not (string=? cadence "interval")) (not (zone-usable? timezone)))
     (format "~a is not a timezone this instance has data for"
             (if (and (string? timezone) (not (string=? timezone ""))) timezone "(none)"))]
    [(not (hash? payload)) "payload must be an object"]
    [else #f]))

;; `zone-offset` answers 0/"UTC" for a zone it cannot read rather than raising —
;; it is on the request path and the scheduler's tick — so a schedule must be
;; held to `zone-exists?` HERE, at the create, where somebody is reading the
;; answer. Validating nowhere would give a typo'd zone a silent UTC firing time.
(define (zone-usable? z)
  (and (string? z) (not (string=? z "")) (zone-exists? z)))

;; ---- the row ------------------------------------------------------------------
(define COLS
  (string-append "id, team_id, user_id, name, kind, payload, requirements, priority, "
                 "interval_seconds, paused, next_run_epoch, last_run_epoch, last_job_id, "
                 "fired, skipped, last_skip_reason, last_skip_epoch, created_by, created_epoch, "
                 "cadence, at_minute, days_of_week, timezone"))

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
          'paused (= 1 (vector-ref r 9))
          'next_run_epoch (vector-ref r 10)
          'last_run_epoch (nz (vector-ref r 11))
          'last_job_id (nz (vector-ref r 12))
          'fired (vector-ref r 13)
          'skipped (vector-ref r 14)
          'last_skip_reason (nz (vector-ref r 15))
          'last_skip_epoch (nz (vector-ref r 16))
          'created_by (nz (vector-ref r 17))
          'created_epoch (vector-ref r 18)
          'cadence (vector-ref r 19)
          'at_minute (nz (vector-ref r 20))
          'days_of_week (nz (vector-ref r 21))
          'timezone (nz (vector-ref r 22))
          ;; `interval_seconds` is reported ONLY for the cadence it drives. The
          ;; column is NOT NULL (0051) so a daily row carries a nominal 86400,
          ;; and a number nothing computes with is how a reader comes to believe
          ;; the wrong thing — LIVE-IN's lesson, pointed the other way.
          'interval_seconds (if (string=? (vector-ref r 19) "interval")
                                (vector-ref r 8)
                                'null)))

;; ---- create / read / update / delete -------------------------------------------
(define (schedule-create! conn #:team team #:user user #:kind kind #:interval [interval 86400]
                          #:cadence [cadence "interval"] #:at-minute [at-minute #f]
                          #:days [days #f] #:timezone [timezone #f]
                          #:payload [payload (hasheq)] #:requirements [req (hasheq)]
                          #:priority [pri 0] #:name [name #f] #:created-by [by #f]
                          #:paused? [paused? #f]
                          ;; The first firing is one interval away, not immediate. A
                          ;; create that fired at once would make every mistaken
                          ;; create cost a run, and the cadence is what was asked for.
                          #:start [start #f])
  (define id (new-id))
  ;; The nominal period for a wall-clock cadence: the column is NOT NULL and
  ;; nothing computes with it there (see `row->schedule`, which hides it).
  (define nominal (cond [(string=? cadence "daily") 86400]
                        [(string=? cadence "weekly") 604800]
                        [else interval]))
  ;; The FIRST firing comes from the same function every later one does, so
  ;; "07:00 tomorrow" and "07:00 next Monday" are not two pieces of arithmetic
  ;; that can disagree.
  (define-values (first-due _gap)
    (if start
        (values start #f)
        (next-firing (hasheq 'cadence cadence 'interval_seconds nominal 'at_minute at-minute
                             'days_of_week days 'timezone timezone))))
  (query-exec conn
    (string-append "INSERT INTO job_schedules (id, team_id, user_id, name, kind, payload, requirements, "
                   "priority, interval_seconds, paused, next_run_epoch, created_by, created_epoch, "
                   "cadence, at_minute, days_of_week, timezone) "
                   "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)")
    id team user (or name sql-null) kind
    (seal-schedule-payload id (jsexpr->string payload))
    ;; `requirements` is NOT sealed, for `jobs.requirements`' own reason: it is
    ;; the kind's matching criteria, filtered on in SQL by a claim, and it holds
    ;; no document content.
    (jsexpr->string req)
    pri nominal (if paused? 1 0) first-due
    (or by sql-null) (now)
    cadence (or at-minute sql-null) (or days sql-null) (or timezone sql-null))
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
                          #:payload [payload 'same] #:priority [pri 'same] #:name [name 'same]
                          #:cadence [cadence 'same] #:at-minute [at-minute 'same]
                          #:days [days 'same] #:timezone [timezone 'same])
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
             ;; Resuming does not catch up on the ticks missed while it was off —
             ;; the same rule the tick itself follows, and here the catch-up would
             ;; be a burst proportional to how long somebody left it paused. The
             ;; next firing comes from `next-firing`, so a wall-clock schedule
             ;; resumes at its own hour rather than an interval from now.
             (define-values (due _gap) (next-firing cur))
             (query-exec conn (string-append "UPDATE job_schedules SET next_run_epoch = ? "
                                             "WHERE id = ? AND team_id = ? AND next_run_epoch < ?")
                         due id team (now))))
         (when (hash? payload)
           (query-exec conn "UPDATE job_schedules SET payload = ? WHERE id = ? AND team_id = ?"
                       (seal-schedule-payload id (jsexpr->string payload)) id team))
         (when (exact-integer? pri)
           (query-exec conn "UPDATE job_schedules SET priority = ? WHERE id = ? AND team_id = ?" pri id team))
         (when (string? name)
           (query-exec conn "UPDATE job_schedules SET name = ? WHERE id = ? AND team_id = ?" name id team))
         (when (string? cadence)
           (query-exec conn "UPDATE job_schedules SET cadence = ? WHERE id = ? AND team_id = ?" cadence id team)
           ;; keep the nominal period honest alongside the cadence
           (query-exec conn "UPDATE job_schedules SET interval_seconds = ? WHERE id = ? AND team_id = ? AND cadence <> 'interval'"
                       (if (string=? cadence "weekly") 604800 86400) id team))
         (when (exact-integer? at-minute)
           (query-exec conn "UPDATE job_schedules SET at_minute = ? WHERE id = ? AND team_id = ?" at-minute id team))
         (when (string? days)
           (query-exec conn "UPDATE job_schedules SET days_of_week = ? WHERE id = ? AND team_id = ?" days id team))
         (when (string? timezone)
           (query-exec conn "UPDATE job_schedules SET timezone = ? WHERE id = ? AND team_id = ?" timezone id team))
         ;; ANY change to WHEN means the stored due time was computed from
         ;; something that is no longer true, so it is recomputed from the new
         ;; row. Leaving it would fire once at the old time and only then obey
         ;; the edit, which reads as the edit not having taken.
         (define touched-when?
           (or (exact-integer? interval) (string? cadence) (exact-integer? at-minute)
               (string? days) (string? timezone)))
         (when touched-when?
           (define fresh (schedule-get conn id team))
           (define-values (due _gap) (next-firing fresh))
           (query-exec conn "UPDATE job_schedules SET next_run_epoch = ? WHERE id = ? AND team_id = ?"
                       due id team))
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
    ;; The next due time is computed BEFORE the claim, from the row as read, so
    ;; the guarded UPDATE carries it — and a wall-clock cadence advances to its
    ;; own next hour rather than to "now plus a period".
    (define-values (next-due gap) (next-firing s))
    (define claimed (claim-schedule-tick! conn id due next-due))
    (cond
      [(not claimed) (values fired skipped)]       ; another replica took this tick
      [else
       ;; A local time the clocks jumped over: the day was passed over, and that
       ;; is recorded rather than silently absorbed (TZ-5 leaves the choice to
       ;; the caller; this is the caller choosing).
       (when gap (note-skip! conn id gap))
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
(define (claim-schedule-tick! conn id due next-due)
  (and (query-maybe-row conn (string-append "UPDATE job_schedules SET next_run_epoch = ? "
                                            "WHERE id = ? AND paused = 0 AND next_run_epoch = ? RETURNING id")
                        next-due id due)
       #t))

(define (note-skip! conn id reason)
  (query-exec conn (string-append "UPDATE job_schedules SET skipped = skipped + 1, "
                                  "last_skip_reason = ?, last_skip_epoch = ? WHERE id = ?")
              reason (now) id))

;; ---- when does this fire next? (#140) -----------------------------------------
;; -> (values epoch skip-reason-or-#f)
;;
;; THE ANSWER IS ALWAYS STRICTLY AFTER `after`, which is what makes SCHED-11's
;; "skip, do not catch up" fall out of the arithmetic rather than being enforced
;; on top of it: a box that was down for a week asks this once and gets the next
;; matching local time, not the 1,440 it slept through.
;;
;; The second value is the honest half. Twice a year a local time does not exist
;; (the clocks jump over it), and a `daily 01:30 Europe/London` has no 01:30 on
;; the spring-forward morning. That day is PASSED OVER and the reason is
;; reported, so the row can record it — TZ-5 says the caller decides, and this is
;; the caller deciding. Inventing an hour that did not happen, or firing at a
;; different time that day, are both worse: the first is a lie and the second is
;; a schedule that silently moves.
(define (next-firing s #:after [after (now)])
  (define cadence (hash-ref s 'cadence "interval"))
  (cond
    [(string=? cadence "interval")
     (values (+ after (hash-ref s 'interval_seconds)) #f)]
    [else
     (define tz (or (hash-ref s 'timezone #f) "UTC"))
     (define at (or (hash-ref s 'at_minute #f) 0))
     (define hh (quotient at 60))
     (define mm (remainder at 60))
     (define want (and (string=? cadence "weekly")
                       (parse-days (or (hash-ref s 'days_of_week #f) ""))))
     ;; start from the LOCAL day containing `after`, so "today at 07:00" is
     ;; offered when 07:00 has not happened yet
     (define-values (y0 m0 d0 _h _m _s _dow) (local-fields tz after))
     (define day0 (days-from-civil y0 m0 d0))
     (let loop ([i 0] [gap #f])
       (cond
         [(>= i FIRING-SEARCH-DAYS) (values (+ after 86400) (or gap "no-firing-found"))]
         [else
          (define days (+ day0 i))
          (define-values (y m d) (civil-from-days days))
          (define dow (modulo (+ days 4) 7))        ; 1970-01-01 was a Thursday
          (cond
            [(and want (not (member dow want))) (loop (add1 i) gap)]
            [else
             (define-values (t st) (local->epoch tz y m d hh mm 0))
             (cond
               ;; the clocks jumped over this local time: pass the day over and
               ;; say so. `ambiguous` needs no branch — TZ-5 already answers with
               ;; the FIRST of the two occurrences, which is the one to fire.
               [(eq? st 'nonexistent) (loop (add1 i) "dst-gap")]
               [(> t after) (values t gap)]
               [else (loop (add1 i) gap)])])]))]))
