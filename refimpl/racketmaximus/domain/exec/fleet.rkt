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

(provide fleet-report queue-listing FLEET-WINDOW-HOURS QUEUE-PAGE-MAX)

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
                            #:kinds (caps-list e 'kinds) #:models (caps-list e 'models)
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

;; ---- the queue, job by job (FLEET-4) -----------------------------------------
;;
;; `fleet-report` carries the queue's three summary numbers, which answer "is
;; this moving". This answers "what is in it, and what is each row waiting for" —
;; a paged, filterable listing across every team, for the operator who owns the
;; box.
;;
;; A SEPARATE route rather than more of `/api/admin/workers`: that one is a
;; bounded dashboard that must stay cheap enough to poll, and this needs paging,
;; filters and a total. Keeping them together would have made every dashboard
;; read pay for a page of jobs nobody asked for.
;;
;; Three things it deliberately does NOT do:
;;
;;   It carries no `payload` and no `result`. This read crosses every team and
;;   every org on the instance, and a queue is managed by kind, age, team and
;;   holder — not by reading a team's prompts. The team-scoped `GET /api/jobs/:id`
;;   still has them, under that team's own gate. Narrower is the whole discipline
;;   LAY-11 and the public funnel slice already follow.
;;
;;   It cannot cancel. `cancel-job!` is team-scoped and the permission rule is
;;   team-tier (owner-ok OR `jobs:cancel`, SCHED-8); an operator stopping another
;;   company's job is a decision of its own and not one to make inside a listing.
;;
;;   It invents no hold reason. `waiting` comes from `team-hold`, the same
;;   admission seam `GET /api/jobs` asks (QUOTA-3), and is ABSENT when nothing
;;   holds the job — never `{"reason":"worker"}`.

(define QUEUE-PAGE-MAX 200)

;; `team-hold` is a property of the TEAM, so a cross-team listing asks it once
;; per team rather than once per row — the reason QUOTA-3 computes it once per
;; listing, scaled up to a listing that spans teams.
(define (hold-cache conn)
  (define seen (make-hash))
  (lambda (team sub?)
    (hash-ref! seen (cons team sub?) (lambda () (team-hold conn team #:sub? sub?)))))

(define QSELECT
  (string-append
   "SELECT j.id, j.kind, j.status, j.priority, j.team_id, j.attempt, j.parent_job_id, "
   "       j.created_epoch, j.lease_until, j.error, j.created_at, j.requirements, "
   "       t.name, o.name, x.name, j.releases "
   "FROM jobs j "
   "LEFT JOIN teams t ON t.id = j.team_id "
   "LEFT JOIN orgs o ON o.id = t.org_id "
   "LEFT JOIN executors x ON x.id = j.executor_id "))

;; Filters are AND-ed, and every one of them is a column: an operator looking at
;; a deep queue is asking "which kind", "whose", "which box" — and a filter that
;; was ignored rather than refused is the bug `query-param`'s assq mismatch
;; produced in the Localization Manager, where a request for Dutch was answered
;; with Japanese.
(define (queue-where kind status executor team)
  (for/fold ([cls '()] [args '()] #:result (values (reverse cls) (reverse args)))
            ([f (in-list (list (cons "j.kind = ?" kind)
                               (cons "j.status = ?" status)
                               (cons "x.name = ?" executor)
                               (cons "j.team_id = ?" team)))])
    (if (cdr f) (values (cons (car f) cls) (cons (cdr f) args)) (values cls args))))

;; -> a hash with `jobs`, `total`, `order`, and the filters that were applied.
;;
;; `order` says which way the list runs, because a list that LOOKED ordered and
;; was not would mislead about what runs next. Asked for the queued rows alone,
;; it is the claim's own order (`priority DESC, created ASC`), so position 1
;; really is the next job a free worker takes. Otherwise it is newest first.
;;
;; `COALESCE(created_epoch, 0)` rather than a bare column: a row from before
;; migration 0041 has none, and the two dialects sort NULLs opposite ways under
;; ASC. Zero is also the right answer for drain order — a pre-0041 job is the
;; oldest thing here.
(define (queue-listing conn p #:kind [kind #f] #:status [status #f] #:executor [executor #f]
                       #:team [team #f] #:limit [lim 50] #:offset [off 0])
  (define n (max 1 (min QUEUE-PAGE-MAX lim)))
  (define skip (max 0 off))
  (define-values (cls args) (queue-where kind status executor team))
  (define where (if (null? cls) "" (string-append "WHERE " (string-join cls " AND ") " ")))
  (define drain? (equal? status "queued"))
  (define order (if drain?
                    "ORDER BY j.priority DESC, COALESCE(j.created_epoch, 0) ASC "
                    "ORDER BY COALESCE(j.created_epoch, 0) DESC "))
  (define total (apply query-value conn
                       (string-append "SELECT COUNT(*) FROM jobs j "
                                      "LEFT JOIN teams t ON t.id = j.team_id "
                                      "LEFT JOIN executors x ON x.id = j.executor_id " where)
                       args))
  (define rows (apply query-rows conn
                      (string-append QSELECT where order "LIMIT " (number->string n)
                                     " OFFSET " (number->string skip))
                      args))
  (define held (hold-cache conn))
  (define rk (remote-kinds))
  ;; the live fleet, read once: `runnable` asks the claim's own predicate, so a
  ;; row that says nothing can run it agrees with what a worker would refuse.
  (define live (filter (lambda (e) (and (equal? (hash-ref e 'status) "active")
                                        (equal? (hash-ref e 'mode) "pull")))
                       (executor-list conn p)))
  (hasheq
   'total total 'limit n 'offset skip
   'order (if drain? "drain" "recent")
   'filters (hasheq 'kind (or kind 'null) 'status (or status 'null)
                    'executor (or executor 'null) 'team (or team 'null))
   'jobs
   (for/list ([r (in-list rows)])
     (define st (vector-ref r 2))
     (define tid (vector-ref r 4))
     (define sub? (not (sql-null? (vector-ref r 6))))
     (define kd (vector-ref r 1))
     (define remote? (and (member kd rk) #t))
     (define req (with-handlers ([exn:fail? (lambda (_) (hasheq))])
                   (let ([j (string->jsexpr (let ([v (vector-ref r 11)]) (if (sql-null? v) "{}" v)))])
                     (if (hash? j) j (hasheq)))))
     (define base
       (hasheq 'id (vector-ref r 0) 'kind kd 'status st
               'priority (vector-ref r 3)
               'team_id (nz* (vector-ref r 4)) 'team (nz* (vector-ref r 12)) 'org (nz* (vector-ref r 13))
               'attempt (vector-ref r 5) 'max_attempts MAX-ATTEMPTS
               'sub_job sub?
               'remote remote?
               'executor (nz* (vector-ref r 14))
               'age_seconds (let ([v (vector-ref r 7)]) (if (sql-null? v) 'null (- (now) v)))
               'created_at (format "~a" (vector-ref r 10))
               'lease_seconds_left (let ([v (vector-ref r 8)])
                                     (if (sql-null? v) 'null (- v (now))))
               ;; issue #61: a release spends no attempt, so `attempt` cannot show
               ;; a job workers keep handing back. This is the column that can.
               'releases (let ([v (vector-ref r 15)]) (if (sql-null? v) 0 v))
               'error (nz* (vector-ref r 9))))
     ;; `waiting` only where it can mean anything, and ABSENT when nothing holds
     ;; the job (QUOTA-3): nothing here can know whether a worker for a remote
     ;; kind exists, and a reason nothing stands behind is how a reader stops
     ;; trusting the field. `runnable` is the separate, answerable half.
     (define with-hold
       (cond
         [(not (equal? st "queued")) base]
         [(held tid sub?) => (lambda (h) (hash-set base 'waiting h))]
         [else base]))
     (if (and (equal? st "queued") remote?)
         (hash-set with-hold 'runnable
                   (for/or ([e (in-list live)])
                     (executor-can-run? conn e
                       #:kinds (caps-list e 'kinds) #:models (caps-list e 'models)
                       #:kind kd #:team tid #:requirements req)))
         with-hold))))

(define (nz* v) (if (sql-null? v) 'null v))
(define (caps-list e k)
  (let ([v (hash-ref (let ([c (hash-ref e 'capabilities (hasheq))]) (if (hash? c) c (hasheq))) k '())])
    (if (list? v) (filter string? v) '())))
