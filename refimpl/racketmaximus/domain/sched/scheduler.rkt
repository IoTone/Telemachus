#lang racket/base

;; domain/sched/scheduler.rkt — the async AI workload scheduler (slice 27).
;;
;; Submit a unit of work (a "job") and let a bounded worker pool run it later,
;; off the request path — for deferred/bulk AI work (batch translation, long
;; agent flows). Design goals, in order: SAFE, then fair, then fast.
;;
;;   • Atomic claim. next queued job is claimed under a lock (SELECT … LIMIT 1,
;;     then UPDATE … WHERE status='queued'), so two workers never run one job.
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
         "../db/id.rkt"
         "../authz/authz.rkt")     ; user-principal

(provide register-job-kind! enqueue-job! get-job list-jobs cancel-job!
         process-one! start-scheduler! set-cap-for! set-admit?! set-record!!
         remote-kind? remote-kind-validator scheduler-cap-for scheduler-admit? scheduler-record!
         set-reaper! current-job)

(define (vr r i) (vector-ref r i))
(define (nz x) (if (sql-null? x) 'null x))

;; ---- kind registry ----------------------------------------------------------
;; A kind is in-process (a handler) or REMOTE (slice 66): no handler here, never
;; claimed by the pool, claimed by a pull worker over HTTP and completed with a
;; result the kind's #:validate accepts (a string naming the problem, or #f).
(define *kinds* (make-hash))
(define *remote* (make-hash))       ; kind -> validator
(define (register-job-kind! kind handler #:remote? [remote? #f] #:validate [validate (lambda (r) #f)])
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
             (begin
               (query-exec conn "UPDATE jobs SET status='running', started_at=CURRENT_TIMESTAMP WHERE id = ?" id)
               id))))))

(define (run-claimed! conn id)
  (define r (query-maybe-row conn "SELECT team_id, user_id, kind, payload FROM jobs WHERE id = ?" id))
  (when r
    (define team (vr r 0)) (define user (vr r 1)) (define kind (vr r 2))
    (define payload (with-handlers ([exn:fail? (lambda (_) (hasheq))]) (string->jsexpr (vr r 3))))
    (define handler (hash-ref *kinds* kind #f))
    (with-handlers ([exn:fail? (lambda (e)
                                 (query-exec conn "UPDATE jobs SET status='error', error=?, finished_at=CURRENT_TIMESTAMP WHERE id = ?"
                                             (exn-message e) id))])
      (cond
        [(not handler)
         (query-exec conn "UPDATE jobs SET status='error', error='unknown job kind', finished_at=CURRENT_TIMESTAMP WHERE id = ?" id)]
        [else
         (define result (parameterize ([current-job (hasheq 'id id 'team team 'user user)])
                          (handler conn (user-principal conn user team) payload)))
         (query-exec conn "UPDATE jobs SET status='done', result=?, finished_at=CURRENT_TIMESTAMP WHERE id = ?"
                     (jsexpr->string result) id)
         ((unbox *record!*) conn team result)]))))    ; meter usage for a successful run

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
  (set-box! *run* #t)
  (for ([_ (in-range (max 1 n))])
    (thread (lambda ()
              (let loop ()
                (when (unbox *run*)
                  (with-handlers ([exn:fail? (lambda (_) (sleep idle))])
                    (unless (process-one! conn)
                      ((unbox *reaper*) conn)          ; expired pull leases go back to the queue
                      (sleep idle)))
                  (loop))))))
  (lambda () (set-box! *run* #f)))    ; stop thunk
