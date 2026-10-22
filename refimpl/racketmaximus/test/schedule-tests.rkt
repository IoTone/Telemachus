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
         "../domain/sched/schedules.rkt")

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
