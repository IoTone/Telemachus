#lang racket/base

;; test/schedule-tests.rkt — the platform's clock (#135).
;;
;; The two properties worth testing here are the ones a wrong implementation
;; gets wrong QUIETLY: a missed tick caught up as a burst, and two replicas both
;; firing the same tick. Both are positive-controlled below — each case is also
;; run against the mistake it guards, and fails there.
;;
;;   raco test test/schedule-tests.rkt

(require rackunit db-kit/portable
         db-kit/migrate
         "../domain/db/migrations.rkt"
         "db-fixture.rkt"
         "../domain/authz/authz.rkt"
         "../domain/sched/scheduler.rkt"
         "../domain/sched/schedules.rkt"
         (only-in "../domain/time/zones.rkt" local-fields zoneinfo-dir))

(define (fresh) (define c (fresh-db #:migrate? #f)) (migrate! c all-migrations) c)

(register-job-kind! "sched-echo" (lambda (conn p payload) (hasheq 'echo (hash-ref payload 'text ""))))

;; Pull a schedule's due time back so the next tick finds it, without sleeping.
(define (make-due! c id [when (- (current-seconds) 1)])
  (query-exec c "UPDATE job_schedules SET next_run_epoch = ? WHERE id = ?" when id))

(define (jobs-of c team) (length (list-jobs c team)))

(test-case "create: the kind must exist, the interval has a floor, the payload is an object"
  (check-false (schedule-problem #:kind "sched-echo" #:interval 60 #:payload (hasheq)))
  ;; An unknown kind on a timer is #113's shape: it would enqueue work nothing
  ;; can run, for ever, and nobody would be present to read the failure.
  (check-true (string? (schedule-problem #:kind "no-such-kind" #:interval 60 #:payload (hasheq))))
  (check-true (string? (schedule-problem #:kind "sched-echo" #:interval 59 #:payload (hasheq))))
  (check-true (string? (schedule-problem #:kind "sched-echo" #:interval 60 #:payload '(1 2))))
  (check-true (string? (schedule-problem #:kind "" #:interval 60 #:payload (hasheq)))))

(test-case "a schedule fires one ordinary job, as its own principal"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice"))
  (define sid (schedule-create! c #:team tid #:user uid #:kind "sched-echo" #:interval 60
                                #:payload (hasheq 'text "tick") #:name "every minute"))
  ;; The first firing is one interval away, not immediate.
  (define-values (f0 s0) (fire-due-schedules! c))
  (check-equal? (list f0 s0) (list 0 0))
  (check-equal? (jobs-of c tid) 0)

  (make-due! c sid)
  (define-values (f1 s1) (fire-due-schedules! c))
  (check-equal? (list f1 s1) (list 1 0))
  (check-equal? (jobs-of c tid) 1)
  (define row (schedule-get c sid tid))
  (check-equal? (hash-ref row 'fired) 1)
  (check-true (string? (hash-ref row 'last_job_id)))
  ;; the job is the schedule's team AND user — there is no system principal
  (define j (car (list-jobs c tid)))
  (check-equal? (hash-ref j 'kind) "sched-echo")
  (check-equal? (process-one! c) (hash-ref row 'last_job_id))
  (check-equal? (hash-ref (get-job c (hash-ref row 'last_job_id) tid) 'status) "done")
  ;; the payload survived the sealing round trip
  (check-equal? (hash-ref (hash-ref row 'payload) 'text) "tick")
  ;; and the firing is in the trail, under the schedule's own team
  (check-true (for/or ([e (in-list (audit-list c tid))])
                (equal? (hash-ref e 'action) "job.schedule.fired"))))

(test-case "A MISSED TICK IS SKIPPED, NOT CAUGHT UP"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice"))
  (define sid (schedule-create! c #:team tid #:user uid #:kind "sched-echo" #:interval 60))
  ;; a day of downtime, 1,440 missed minutes
  (make-due! c sid (- (current-seconds) 86400))
  (define-values (fired _s) (fire-due-schedules! c))
  (check-equal? fired 1)
  (check-equal? (jobs-of c tid) 1)
  ;; CONTROL for the catch-up mistake: the next due time is computed from NOW,
  ;; so the backlog is gone. An implementation that advanced by `due + interval`
  ;; would leave the row due in the past and the next tick would fire again.
  (check-true (> (hash-ref (schedule-get c sid tid) 'next_run_epoch) (current-seconds)))
  (define-values (f2 s2) (fire-due-schedules! c))
  (check-equal? (list f2 s2) (list 0 0))
  (check-equal? (jobs-of c tid) 1))

(test-case "ONE AT A TIME: an outstanding job skips the tick and the row says so"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice"))
  (define sid (schedule-create! c #:team tid #:user uid #:kind "sched-echo" #:interval 60))
  (make-due! c sid)
  (check-equal? (let-values ([(f _s) (fire-due-schedules! c)]) f) 1)
  ;; the job is still queued, so the next tick must not stack a second one —
  ;; this is also what BOUNDS the queue for a team that is over its budget,
  ;; since admission defers at claim and never at enqueue
  (make-due! c sid)
  (define-values (f2 s2) (fire-due-schedules! c))
  (check-equal? (list f2 s2) (list 0 1))
  (check-equal? (jobs-of c tid) 1)
  (define row (schedule-get c sid tid))
  (check-equal? (hash-ref row 'skipped) 1)
  (check-equal? (hash-ref row 'last_skip_reason) "overrun")
  (check-true (number? (hash-ref row 'last_skip_epoch)))
  ;; once it settles, the schedule fires again
  (void (process-one! c))
  (make-due! c sid)
  (check-equal? (let-values ([(f _s) (fire-due-schedules! c)]) f) 1)
  (check-equal? (jobs-of c tid) 2))

(test-case "TWO REPLICAS: the claim is one guarded UPDATE, so one tick fires once"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice"))
  (define sid (schedule-create! c #:team tid #:user uid #:kind "sched-echo" #:interval 60))
  (make-due! c sid)
  ;; Both replicas read the same due row and then claim it. The claim names the
  ;; due time this process READ, so exactly one UPDATE matches a row and the
  ;; loser does nothing rather than firing a duplicate. Driving
  ;; `claim-schedule-tick!` rather than a hand-copied UPDATE is the point: a
  ;; copy would agree with any change to the real one, and two serial
  ;; `fire-due-schedules!` calls cannot see the guard at all, because the first
  ;; advances the due time and the second finds nothing due.
  (define due (hash-ref (schedule-get c sid tid) 'next_run_epoch))
  (check-true (claim-schedule-tick! c sid due 60))
  (check-false (claim-schedule-tick! c sid due 60))

  ;; and the tick itself, run twice over one due row, enqueues one job
  (make-due! c sid)
  (check-equal? (let-values ([(f _s) (fire-due-schedules! c)]) f) 1)
  (check-equal? (let-values ([(f _s) (fire-due-schedules! c)]) f) 0)
  (check-equal? (jobs-of c tid) 1))

(test-case "paused, resumed, patched, deleted; another team's id is a miss"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice"))
  (define sid (schedule-create! c #:team tid #:user uid #:kind "sched-echo" #:interval 60))
  (make-due! c sid)
  (void (schedule-update! c sid tid #:paused? #t))
  (check-true (hash-ref (schedule-get c sid tid) 'paused))
  (check-equal? (let-values ([(f s) (fire-due-schedules! c)]) (list f s)) (list 0 0))
  (check-equal? (jobs-of c tid) 0)
  ;; resuming does not catch up on the ticks missed while it was off
  (void (schedule-update! c sid tid #:paused? #f))
  (check-true (> (hash-ref (schedule-get c sid tid) 'next_run_epoch) (current-seconds)))
  (check-equal? (let-values ([(f s) (fire-due-schedules! c)]) (list f s)) (list 0 0))

  (define patched (schedule-update! c sid tid #:interval 3600 #:name "hourly"
                                    #:payload (hasheq 'text "new") #:priority 3))
  (check-equal? (hash-ref patched 'interval_seconds) 3600)
  (check-equal? (hash-ref patched 'name) "hourly")
  (check-equal? (hash-ref (hash-ref patched 'payload) 'text) "new")
  (check-equal? (hash-ref patched 'priority) 3)
  ;; the principal is not patchable, and the row still names who it runs as
  (check-equal? (hash-ref patched 'user_id) uid)

  ;; another team's id is a MISS, never a refusal (#118's rule)
  (define tid2 (create-team! c #:slug "ops" #:name "Ops"))
  (check-false (schedule-get c sid tid2))
  (check-false (schedule-update! c sid tid2 #:paused? #t))
  (check-false (schedule-delete! c sid tid2))
  (check-equal? (length (schedule-list c tid2)) 0)

  (check-true (schedule-delete! c sid tid))
  (check-false (schedule-get c sid tid))
  (check-false (schedule-delete! c sid tid)))

;; ---- a wall-clock cadence (#140) ----------------------------------------------
;; An interval cannot say "07:00 on weekdays": 24h from an arbitrary create time
;; drifts to whatever minute the row happened to be written. These cases carry
;; the ANSWERS from Python's zoneinfo over the same tzdata, as literals — the
;; rule test/timezone-tests.rkt states and for the same reason.

(define BASE 1792659600)        ; 2026-10-22T09:00:00Z, a Thursday

(define (sched cadence #:at [at 420] #:days [days #f] #:tz [tz "Europe/London"])
  (hasheq 'cadence cadence 'interval_seconds 86400 'at_minute at
          'days_of_week days 'timezone tz))

(test-case "next-firing lands on the local hour asked for"
  (cond
    [(not (zoneinfo-dir))
     (eprintf "schedule-tests: NO TZ DATABASE — the wall-clock cases did not run\n")
     (check-true #t)]
    [else
     ;; 07:00 London, 07:00 Tokyo: the SAME wall-clock cadence is two different
     ;; instants, which is the whole point of the slice
     (check-equal? (let-values ([(t _g) (next-firing (sched "daily") #:after BASE)]) t) 1792735200)
     (check-equal? (let-values ([(t _g) (next-firing (sched "daily" #:tz "Asia/Tokyo") #:after BASE)]) t)
                   1792706400)
     ;; weekdays only — the base is a Thursday, so the next weekday 07:00 is
     ;; Friday's and the weekly answer coincides with the daily one
     (check-equal? (let-values ([(t _g) (next-firing (sched "weekly" #:days "1,2,3,4,5") #:after BASE)]) t)
                   1792735200)
     ;; …and a Sunday-only schedule skips three days rather than firing tomorrow
     (check-equal? (let-values ([(t _g) (next-firing (sched "weekly" #:at 1425 #:days "0") #:after BASE)]) t)
                   1792971900)
     ;; the answer is always STRICTLY after: asked at its own firing time, a
     ;; daily schedule answers tomorrow, which is what stops a double fire
     (define-values (t1 _g1) (next-firing (sched "daily") #:after BASE))
     (define-values (t2 _g2) (next-firing (sched "daily") #:after t1))
     (check-equal? (- t2 t1) 86400)]))

(test-case "A LOCAL TIME THE CLOCKS JUMPED OVER IS PASSED OVER, AND SAID SO"
  (cond
    [(not (zoneinfo-dir)) (check-true #t)]
    [else
     ;; `daily 01:30 Europe/London`, asked on 27 March 2027. There is no 01:30 on
     ;; the 28th — the clocks go straight from 01:00 to 02:00 — so the next
     ;; firing is the 29th, and the gap is REPORTED so the row can record it.
     ;; Inventing an hour that did not happen, or firing at a different time that
     ;; morning, are both worse: the first is a lie and the second is a schedule
     ;; that silently moved.
     (define-values (t gap) (next-firing (sched "daily" #:at 90) #:after 1806148800))
     (check-equal? t 1806280200)                      ; 2027-03-29T01:30 local
     (check-equal? gap "dst-gap")
     ;; an ordinary day reports no gap at all
     (define-values (_t2 gap2) (next-firing (sched "daily" #:at 90) #:after BASE))
     (check-false gap2)]))

(test-case "a daily schedule is created, fires at its hour, and advances by a day"
  (cond
    [(not (zoneinfo-dir)) (check-true #t)]
    [else
     (define c (fresh))
     (define-values (uid tid) (bootstrap! c #:username "alice"))
     (define sid (schedule-create! c #:team tid #:user uid #:kind "sched-echo"
                                   #:cadence "daily" #:at-minute 420 #:timezone "Europe/London"
                                   #:name "morning briefing"))
     (define row (schedule-get c sid tid))
     (check-equal? (hash-ref row 'cadence) "daily")
     (check-equal? (hash-ref row 'at_minute) 420)
     (check-equal? (hash-ref row 'timezone) "Europe/London")
     ;; `interval_seconds` is hidden for a cadence it does not drive: the column
     ;; is NOT NULL and carries a nominal 86400, and a number nothing computes
     ;; with is how a reader comes to believe the wrong thing.
     (check-equal? (hash-ref row 'interval_seconds) 'null)
     ;; the first firing is in the future and at the right local minute
     (check-true (> (hash-ref row 'next_run_epoch) (current-seconds)))
     (define-values (_y _m _d hh mm _s _dow)
       (local-fields "Europe/London" (hash-ref row 'next_run_epoch)))
     (check-equal? (list hh mm) '(7 0))
     ;; firing advances to the NEXT local 07:00, not to "now plus a day"
     (make-due! c sid)
     (check-equal? (let-values ([(f _s) (fire-due-schedules! c)]) f) 1)
     (define after (schedule-get c sid tid))
     (define-values (_y2 _m2 _d2 hh2 mm2 _s2 _dow2)
       (local-fields "Europe/London" (hash-ref after 'next_run_epoch)))
     (check-equal? (list hh2 mm2) '(7 0))
     (check-true (> (hash-ref after 'next_run_epoch) (current-seconds)))]))

(test-case "the cadence vocabulary is closed, and each one is checked for what IT needs"
  (check-equal? CADENCES '("interval" "daily" "weekly"))
  ;; an unknown cadence is refused rather than treated as an interval
  (check-true (string? (schedule-problem #:kind "sched-echo" #:interval 60 #:payload (hasheq)
                                         #:cadence "hourly")))
  ;; daily needs a minute of the day, and a zone
  (check-true (string? (schedule-problem #:kind "sched-echo" #:interval 60 #:payload (hasheq)
                                         #:cadence "daily" #:timezone "UTC")))
  (check-true (string? (schedule-problem #:kind "sched-echo" #:interval 60 #:payload (hasheq)
                                         #:cadence "daily" #:at-minute 1440 #:timezone "UTC")))
  ;; "07:00" means nothing without saying whose 07:00
  (check-true (string? (schedule-problem #:kind "sched-echo" #:interval 60 #:payload (hasheq)
                                         #:cadence "daily" #:at-minute 420)))
  (check-true (string? (schedule-problem #:kind "sched-echo" #:interval 60 #:payload (hasheq)
                                         #:cadence "daily" #:at-minute 420 #:timezone "Mars/Olympus")))
  (check-false (schedule-problem #:kind "sched-echo" #:interval 60 #:payload (hasheq)
                                 #:cadence "daily" #:at-minute 420 #:timezone "UTC"))
  ;; weekly needs the days as well
  (check-true (string? (schedule-problem #:kind "sched-echo" #:interval 60 #:payload (hasheq)
                                         #:cadence "weekly" #:at-minute 420 #:timezone "UTC")))
  (check-false (schedule-problem #:kind "sched-echo" #:interval 60 #:payload (hasheq)
                                 #:cadence "weekly" #:at-minute 420 #:days "1,5" #:timezone "UTC"))
  ;; an interval schedule keeps #135's floor exactly, and needs none of the above
  (check-false (schedule-problem #:kind "sched-echo" #:interval 60 #:payload (hasheq)))
  (check-true (string? (schedule-problem #:kind "sched-echo" #:interval 30 #:payload (hasheq)))))

(test-case "the weekday set is parsed, and nonsense is refused rather than ignored"
  (check-equal? (parse-days "1,2,3,4,5") '(1 2 3 4 5))
  (check-equal? (parse-days " 0 , 6 ") '(0 6))
  (check-equal? (parse-days "3,3,1") '(1 3))           ; sorted and de-duplicated
  (check-false (parse-days ""))
  (check-false (parse-days "7"))                        ; Sunday is 0, not 7
  (check-false (parse-days "-1"))
  (check-false (parse-days "mon,tue"))
  (check-false (parse-days #f)))

(test-case "changing WHEN recomputes the due time rather than firing once at the old one"
  (cond
    [(not (zoneinfo-dir)) (check-true #t)]
    [else
     (define c (fresh))
     (define-values (uid tid) (bootstrap! c #:username "alice"))
     ;; an interval schedule, switched to a wall-clock cadence
     (define sid (schedule-create! c #:team tid #:user uid #:kind "sched-echo" #:interval 3600))
     (define before (hash-ref (schedule-get c sid tid) 'next_run_epoch))
     (define s2 (schedule-update! c sid tid #:cadence "daily" #:at-minute 420 #:timezone "Asia/Tokyo"))
     (check-equal? (hash-ref s2 'cadence) "daily")
     (check-equal? (hash-ref s2 'interval_seconds) 'null)
     (define-values (_y _m _d hh mm _s _dow)
       (local-fields "Asia/Tokyo" (hash-ref s2 'next_run_epoch)))
     (check-equal? (list hh mm) '(7 0))
     ;; the stored due time was computed from something no longer true, so it
     ;; must have moved: leaving it would fire once at the old time and only then
     ;; obey the edit, which reads as the edit not having taken
     (check-not-equal? (hash-ref s2 'next_run_epoch) before)]))
