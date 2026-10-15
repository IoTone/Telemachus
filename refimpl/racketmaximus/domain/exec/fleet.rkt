#lang racket/base

;; domain/exec/fleet.rkt — the operator's view of the worker fleet (FLEET-2,
;; issue #70).
;;
;; `GET /api/executors` answers what each executor IS. This answers what the
;; fleet is DOING: which box holds which job, how often each one drops work, how
;; deep the queue is, how long its oldest job has waited, and — the figure the
;; platform could not express at all — how many queued remote jobs no live
;; worker is able to run.
;;
;; Three rules it lives by, each one of them learned somewhere else first:
;;
;;   Every number is DERIVED. Nothing here is a counter on a row. A stored count
;;   would be a second copy of something the rows already answer, and the day it
;;   disagreed with them it would be the one an operator believed. The same rule
;;   as `missing`/`stale` in the Localization Manager, `waiting` on a job
;;   (QUOTA-3) and executor health itself.
;;
;;   It is INSTANCE-scoped and `instance:manage`, not a wider `GET /api/jobs`.
;;   That route is team-scoped by contract; widening it to cross teams would make
;;   a team-tier route answer past the org gate, which is step 0 of `can?` and the
;;   one thing nothing may tunnel through. An instance-wide question gets its own
;;   instance-wide route.
;;
;;   "Nothing can run it" and "nothing may run it yet" are DIFFERENT answers.
;;   `unclaimable` counts only jobs no live executor's capabilities satisfy. A job
;;   held by its team's concurrency cap or its AI budget is not unclaimable — it
;;   is deferred, QUOTA-3 already explains it on the job itself, and reporting it
;;   here would send an operator to buy a machine when the answer was a quota.

(require db-kit/portable
         racket/list racket/string
         json
         "../authz/authz.rkt"
         "../sched/scheduler.rkt"
         "pull.rkt")

(provide fleet-report FLEET-WINDOW-HOURS)

;; How far back the per-executor counts look. Not "lifetime": the audit log grows
;; without bound, and the operationally interesting number is what this box has
;; done lately — a machine that failed forty jobs last month and none today is
;; healthy, and a lifetime total says the opposite for ever.
(define FLEET-WINDOW-HOURS 24)
(define (now) (current-seconds))

;; The audit meta is written without spaces (`jsexpr->string`), so a key/value
;; pair is one substring. The same LIKE trick `object-processing` uses to find the
;; runs that touched a document — not elegant, and the alternative is a JSON
;; operator, which SQLite and PostgreSQL do not spell the same way.
(define (meta-has conn action id-key id horizon)
  (query-value conn
    (string-append "SELECT COUNT(*) FROM audit_log WHERE action = ? AND at_us >= ? "
                   "AND meta LIKE ?")
    action (* 1000000 horizon) (format "%\"~a\":\"~a\"%" id-key id)))

;; What this executor is holding right now. `seconds_left` can go negative: that
;; is a lease the reaper has not swept yet, and rounding it up to zero would hide
;; exactly the moment an operator is looking for.
(define (current-work conn ex-id)
  (define r (query-maybe-row conn
    (string-append "SELECT id, kind, team_id, attempt, lease_until, status FROM jobs "
                   "WHERE executor_id = ? AND status IN ('running','canceling') "
                   "ORDER BY lease_until DESC LIMIT 1")
    ex-id))
  (and r
       (hasheq 'job_id (vector-ref r 0) 'kind (vector-ref r 1)
               'team_id (vector-ref r 2) 'attempt (vector-ref r 3)
               'status (vector-ref r 5)
               'lease_until (let ([v (vector-ref r 4)]) (if (sql-null? v) 'null v))
               'seconds_left (let ([v (vector-ref r 4)]) (if (sql-null? v) 'null (- v (now)))))))

;; The last few jobs this executor was holding when they failed, newest first.
;; `error` is the stored message, which since FLEET-1 names the holders.
(define (recent-failures conn ex-id lim)
  (for/list ([r (in-list (query-rows conn
                           (string-append "SELECT id, kind, error, attempt FROM jobs "
                                          "WHERE executor_id = ? AND status = 'error' "
                                          "ORDER BY finished_at DESC LIMIT ?")
                           ex-id lim))])
    (hasheq 'job_id (vector-ref r 0) 'kind (vector-ref r 1) 'attempt (vector-ref r 3)
            'error (let ([v (vector-ref r 2)]) (if (sql-null? v) 'null v)))))

;; Jobs this executor STARTED inside the window, by outcome.
;;
;; `started_epoch` is the clock (migration 0038) because `finished_at` is TEXT
;; CURRENT_TIMESTAMP and differs by dialect. It is stamped on every claim, so for
;; a job that was re-claimed these counts describe the LAST attempt — which is
;; also the only attempt `jobs.executor_id` still names. The expiries of the
;; earlier attempts are the trail FLEET-1 writes, counted separately below;
;; between the two, no attempt goes unrecorded and neither number double-counts.
(define (outcomes conn ex-id horizon)
  (define rows (query-rows conn
    (string-append "SELECT status, COUNT(*) FROM jobs WHERE executor_id = ? AND started_epoch >= ? "
                   "GROUP BY status")
    ex-id horizon))
  (define (n st) (or (for/or ([r (in-list rows)]) (and (equal? (vector-ref r 0) st) (vector-ref r 1))) 0))
  (hasheq 'done (n "done") 'error (n "error")
          'canceled (+ (n "canceled") (n "canceling"))
          'running (n "running")))

(define (executor-entry conn ex horizon)
  (define id (hash-ref ex 'id))
  (hash-set* ex
             'current (or (current-work conn id) 'null)
             'window (hash-set (outcomes conn id horizon)
                               'leases_expired (meta-has conn "job.lease.expired" "executor_id" id horizon))
             'recent_failures (recent-failures conn id 5)))

;; ---- the queue ---------------------------------------------------------------

;; Depth by kind, with the remote kinds marked: a queue of in-process work says
;; nothing about the fleet, and an operator reading a worker page needs to see
;; which rows are even addressable by adding a machine.
(define (queue-depth conn)
  (define rk (remote-kinds))
  (for/list ([r (in-list (query-rows conn
                  (string-append "SELECT kind, COUNT(*) FROM jobs WHERE status = 'queued' "
                                 "GROUP BY kind ORDER BY COUNT(*) DESC, kind")))])
    (hasheq 'kind (vector-ref r 0) 'queued (vector-ref r 1)
            'remote (and (member (vector-ref r 0) rk) #t))))

;; The oldest queued job's age, in seconds. `null` when the queue is empty, and
;; `null` for a job enqueued before migration 0041 — which is honest, where a
;; number derived from nothing would not be (PULL-11e's rule).
(define (oldest-queued conn)
  (define v (query-maybe-value conn
    "SELECT MIN(created_epoch) FROM jobs WHERE status = 'queued' AND created_epoch IS NOT NULL"))
  (if (or (not v) (sql-null? v)) 'null (- (now) v)))

;; How many queued REMOTE jobs no live executor can run, and why.
;;
;; This is the number the platform could not express. "I forgot to start the GPU
;; box" and "the queue is moving fine" looked identical, so a stalled queue was
;; indistinguishable from a busy one. It asks `executor-can-run?` — the predicate
;; the claim itself decides with — of every live executor, so the report cannot
;; disagree with what a worker would actually take.
;;
;; Only `active` executors count. A stale one may be coming back, but it is not
;; running anything now, and an operator asking "can this queue drain" wants the
;; answer about the fleet that exists.
(define (unclaimable conn executors #:limit [lim 200])
  (define rk (remote-kinds))
  ;; `executor-can-run?` refuses a DRAINED executor itself, so this filter stays
  ;; about liveness alone and the two cannot disagree about intent.
  (define live (filter (lambda (e) (and (equal? (hash-ref e 'status) "active")
                                        (equal? (hash-ref e 'mode) "pull")))
                       executors))
  (define rows
    (if (null? rk)
        '()
        (apply query-rows conn
               (string-append "SELECT id, kind, team_id, requirements FROM jobs "
                              "WHERE status = 'queued' AND kind IN ("
                              (string-join (make-list (length rk) "?") ",")
                              ") ORDER BY created_epoch ASC LIMIT " (number->string lim))
               rk)))
  (define stuck
    (for/list ([r (in-list rows)]
               #:unless (for/or ([e (in-list live)])
                          (executor-can-run? conn e
                            #:kinds (let ([k (hash-ref (hash-ref e 'capabilities (hasheq)) 'kinds '())])
                                      (if (list? k) (filter string? k) '()))
                            #:models (let ([m (hash-ref (hash-ref e 'capabilities (hasheq)) 'models '())])
                                       (if (list? m) (filter string? m) '()))
                            #:kind (vector-ref r 1) #:team (vector-ref r 2)
                            #:requirements (with-handlers ([exn:fail? (lambda (_) (hasheq))])
                                             (let ([j (string->jsexpr (vector-ref r 3))])
                                               (if (hash? j) j (hasheq)))))))
      (hasheq 'job_id (vector-ref r 0) 'kind (vector-ref r 1) 'team_id (vector-ref r 2))))
  (hasheq 'count (length stuck)
          'scanned (length rows)
          'truncated (= (length rows) lim)
          'jobs (take stuck (min 20 (length stuck)))))

;; ---- the report --------------------------------------------------------------

;; `p` must be an operator; the route's `instance:manage` is what says so, and
;; `executor-list` is asked with the same principal so a non-operator caller that
;; reached here would still see only its own org's rows rather than everything.
(define (fleet-report conn p #:hours [hours FLEET-WINDOW-HOURS])
  (define horizon (- (now) (* 3600 hours)))
  (define executors (executor-list conn p))
  (define entries (for/list ([e (in-list executors)]) (executor-entry conn e horizon)))
  (define pulls (filter (lambda (e) (equal? (hash-ref e 'mode) "pull")) executors))
  (hasheq
   'window (hasheq 'hours hours 'since horizon)
   'executors entries
   'fleet (hasheq 'pull (length pulls)
                  'active (for/sum ([e (in-list pulls)]) (if (equal? (hash-ref e 'status) "active") 1 0))
                  'stale (for/sum ([e (in-list pulls)]) (if (equal? (hash-ref e 'status) "stale") 1 0))
                  'never_seen (for/sum ([e (in-list pulls)]) (if (equal? (hash-ref e 'status) "never-seen") 1 0))
                  ;; what the workers SAY, which is a different question from
                  ;; whether they are alive (PULL-11a) — and withdrawn for a
                  ;; stale row, so these never add up to `pull` by accident
                  'paused (for/sum ([e (in-list pulls)]) (if (equal? (hash-ref e 'worker_state) "paused") 1 0))
                  ;; what the OPERATOR intends (FLEET-3), a third count beside
                  ;; the derived health and the reported state. A drained box is
                  ;; counted `active` as well when it is alive, because it is —
                  ;; these are three answers to three questions, not a partition.
                  'drained (for/sum ([e (in-list pulls)]) (if (equal? (hash-ref e 'admin_state) "drained") 1 0)))
   'queue (hasheq 'depth (queue-depth conn)
                  'oldest_queued_seconds (oldest-queued conn)
                  'remote_kinds (remote-kinds)
                  'unclaimable (unclaimable conn executors))))
