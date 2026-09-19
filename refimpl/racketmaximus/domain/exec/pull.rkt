#lang racket/base

;; domain/exec/pull.rkt — pull-model executors (slice 66, PULL-1…8): inference
;; hosts that come to the work.
;;
;; A pull executor is a row in `executors` plus a WORKER TOKEN — an API token
;; whose only scope is jobs:execute, bound to the row. The host runs a loop:
;;
;;   claim  → the next queued REMOTE job its capabilities satisfy, offered only if
;;            its executor is instance-wide or belongs to the job's team's org
;;   heartbeat, or the lease expires and the job goes back to the queue
;;   complete / fail  → accepted only from the current lease holder
;;
;; Nothing new lives above the scheduler: the job is the same row an in-process
;; worker would claim, with the same per-team cap, quota admission and cancel.
;; A job kind registered `#:remote? #t` has no in-process handler and is never
;; claimed by the pool; the first one is `infer.chat` — the exact wire run-chat
;; speaks — so every model-using tool works unchanged when its chat is routed to
;; a pull executor (run-chat enqueues an infer.chat sub-job and waits, PULL-5).

(require db-kit/portable
         racket/string racket/list
         json
         "../db/id.rkt"
         "../authz/authz.rkt"
         "../sched/scheduler.rkt"
         "federation.rkt")

(provide executor-create! executor-list executor-retire! executor-by-token executor-by-name
         worker-claim! worker-heartbeat! worker-complete! worker-fail! reap-leases!
         LEASE-SECONDS MAX-ATTEMPTS STALE-AFTER
         pull-dispatch!)

(define LEASE-SECONDS 120)      ; a worker heartbeats every LEASE/3
(define MAX-ATTEMPTS 3)         ; lease expiries before the job fails for good
(define STALE-AFTER (* 3 LEASE-SECONDS))
(define (now) (current-seconds))
(define (nz x) (if (sql-null? x) 'null x))

;; ---- executors --------------------------------------------------------------------
(define ESELECT
  (string-append "SELECT id, org_id, name, mode, url, model, capabilities, token_id, status, last_seen_at, created_at, created_by "
                 "FROM executors"))

(define (row->executor r)
  (define seen (let ([v (vector-ref r 9)]) (and (not (sql-null? v)) v)))
  (hasheq 'id (vector-ref r 0) 'org_id (nz (vector-ref r 1)) 'name (vector-ref r 2) 'mode (vector-ref r 3)
          'url (nz (vector-ref r 4)) 'model (nz (vector-ref r 5))
          'capabilities (with-handlers ([exn:fail? (lambda (_) (hasheq))])
                          (let ([j (string->jsexpr (vector-ref r 6))]) (if (hash? j) j (hasheq))))
          'token_id (nz (vector-ref r 7))
          ;; health is DERIVED: a pull worker that has not been heard from is stale
          'status (cond [(equal? (vector-ref r 8) "retired") "retired"]
                        [(not (equal? (vector-ref r 3) "pull")) "active"]
                        [(not seen) "never-seen"]
                        [(> (- (now) seen) STALE-AFTER) "stale"]
                        [else "active"])
          'last_seen_at (or seen 'null) 'created_at (format "~a" (vector-ref r 10))
          'created_by (nz (vector-ref r 11))))

;; -> (values executor worker-token-or-#f). A pull executor's token is returned
;; ONCE, here; it is an API token scoped jobs:execute that never expires (a host
;; is not a person; retire the executor to end it).
(define (executor-create! conn p #:name name #:mode [mode "pull"] #:org [org-id #f]
                          #:url [url #f] #:model [model #f] #:key [key #f]
                          #:capabilities [caps (hasheq)])
  (unless (and (string? name) (regexp-match? #px"^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$" name))
    (raise-user-error 'executors "name must be 1-64 letters, digits, dots, dashes or underscores"))
  (unless (member mode '("pull" "push")) (raise-user-error 'executors "mode must be pull or push"))
  (when (and (equal? mode "push") (not (string? url))) (raise-user-error 'executors "a push executor needs a url"))
  (when (query-maybe-value conn "SELECT id FROM executors WHERE name = ? AND status <> 'retired'" name)
    (raise-user-error 'executors "an executor named ~a already exists" name))
  (define id (new-id))
  (define-values (raw tid)
    (if (equal? mode "pull")
        (issue-token! conn #:user (principal-user-id p) #:team (principal-team-id p)
                      #:name (string-append "worker:" name) #:scopes '("jobs:execute") #:ttl 'never)
        (values #f #f)))
  (query-exec conn
    (string-append "INSERT INTO executors (id, org_id, name, mode, url, model, secret_key, capabilities, token_id, created_by) "
                   "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)")
    id (or org-id sql-null) name mode (or url sql-null) (or model sql-null) (or key sql-null)
    (jsexpr->string caps) (or tid sql-null) (principal-user-id p))
  (when (equal? mode "push")
    (register-executor! name #:url url #:model (or model "local") #:key key))
  (audit! conn #:action "executor.create" #:actor-type "user" #:actor-id (principal-user-id p)
          #:resource-type "executor" #:resource-id id
          #:meta (jsexpr->string (hasheq 'name name 'mode mode 'org_id (or org-id 'null))))
  (values (row->executor (query-row conn (string-append ESELECT " WHERE id = ?") id)) raw))

;; every executor the caller may see: the operator sees all; an org principal
;; its own org's and the instance-wide ones
(define (executor-list conn p)
  (define rows (query-rows conn (string-append ESELECT " ORDER BY created_at, name")))
  (define org (principal-org-id p))
  (for/list ([r (in-list rows)]
             #:when (or (principal-is-operator p)
                        (sql-null? (vector-ref r 1))
                        (equal? (vector-ref r 1) org)))
    (row->executor r)))

(define (executor-retire! conn p id)
  (define r (query-maybe-row conn (string-append ESELECT " WHERE id = ?") id))
  (and r
       (let ([e (row->executor r)])
         (unless (or (principal-is-operator p) (equal? (hash-ref e 'org_id) (principal-org-id p)))
           (raise (exn:fail:forbidden "forbidden: instance:manage" (current-continuation-marks) "instance:manage")))
         (query-exec conn "UPDATE executors SET status = 'retired' WHERE id = ?" id)
         (when (string? (hash-ref e 'token_id))
           (query-exec conn "UPDATE api_tokens SET status = 'revoked' WHERE id = ?" (hash-ref e 'token_id)))
         ;; a job this host holds goes back to the queue right away
         (query-exec conn "UPDATE jobs SET status = 'queued', executor_id = NULL, lease_until = NULL WHERE executor_id = ? AND status = 'running'" id)
         (audit! conn #:action "executor.retire" #:actor-type "user" #:actor-id (principal-user-id p)
                 #:resource-type "executor" #:resource-id id)
         #t)))

(define (executor-by-token conn token-id)
  (define r (query-maybe-row conn (string-append ESELECT " WHERE token_id = ? AND status <> 'retired'") token-id))
  (and r (row->executor r)))

(define (executor-by-name conn name)
  (define r (query-maybe-row conn (string-append ESELECT " WHERE name = ? AND status <> 'retired'") name))
  (and r (row->executor r)))

;; ---- the worker protocol ------------------------------------------------------------
(define claim-lock (make-semaphore 1))

;; the next queued REMOTE job this worker can run, or #f. Atomic under the lock,
;; like the pool's claim; the same per-team cap and quota admission apply (a
;; sub-job spawned inside an admitted parent is exempt from the cap — its parent
;; holds the slot). Offered only inside the executor's org, or anywhere for an
;; instance-wide executor.
(define (worker-claim! conn ex #:kinds [kinds '()] #:models [models '()])
  (call-with-semaphore claim-lock
    (lambda ()
      (query-exec conn "UPDATE executors SET last_seen_at = ? WHERE id = ?" (now) (hash-ref ex 'id))
      (define candidates
        (query-rows conn
          (string-append "SELECT id, team_id, kind, requirements, parent_job_id FROM jobs "
                         "WHERE status = 'queued' ORDER BY priority DESC, created_at ASC LIMIT 64")))
      (for/or ([r (in-list candidates)])
        (define id (vector-ref r 0)) (define team (vector-ref r 1)) (define kind (vector-ref r 2))
        (define req (with-handlers ([exn:fail? (lambda (_) (hasheq))])
                      (let ([j (string->jsexpr (vector-ref r 3))]) (if (hash? j) j (hasheq)))))
        (define sub? (not (sql-null? (vector-ref r 4))))
        (define want-model (let ([m (hash-ref req 'model #f)]) (and (string? m) m)))
        (define want-exec (let ([e (hash-ref req 'executor #f)]) (and (string? e) e)))
        (and (remote-kind? kind)
             (or (null? kinds) (member kind kinds))
             (or (not want-model) (member want-model models))
             (or (not want-exec) (equal? want-exec (hash-ref ex 'name)))
             ;; the org gate: an org-bound executor never sees another company's job
             (let ([eorg (hash-ref ex 'org_id)])
               (or (eq? eorg 'null) (equal? eorg (team-org conn team))))
             (or sub? (< (query-value conn "SELECT COUNT(*) FROM jobs WHERE team_id = ? AND status = 'running'" team)
                         ((scheduler-cap-for) team)))
             ((scheduler-admit?) conn team)
             ;; the same conditional claim the pool makes: the update names the
             ;; row it expects and is believed only when RETURNING hands one back,
             ;; so two workers scanning the same queue never both get this job.
             (let* ([lease (+ (now) LEASE-SECONDS)]
                    [took? (claim-job! conn id #:lease lease #:executor (hash-ref ex 'id))])
               (and took?
                    (let ([row (query-row conn "SELECT id, kind, payload, team_id FROM jobs WHERE id = ?" id)])
                      (hasheq 'id (vector-ref row 0) 'kind (vector-ref row 1)
                              'payload (with-handlers ([exn:fail? (lambda (_) (hasheq))]) (string->jsexpr (vector-ref row 2)))
                              'lease_until lease 'lease_seconds LEASE-SECONDS)))))))))

;; is this job held by this executor, and still running? -> 'ok | 'not-holder | 'not-running
(define (holder-check conn ex job-id)
  (define r (query-maybe-row conn "SELECT executor_id, status FROM jobs WHERE id = ?" job-id))
  (cond [(not r) 'not-found]
        [(not (equal? (vector-ref r 1) "running")) 'not-running]
        [(not (equal? (vector-ref r 0) (hash-ref ex 'id))) 'not-holder]
        [else 'ok]))

(define (worker-heartbeat! conn ex job-id)
  (define v (holder-check conn ex job-id))
  (cond
    [(eq? v 'ok)
     (define lease (+ (now) LEASE-SECONDS))
     (query-exec conn "UPDATE jobs SET lease_until = ? WHERE id = ?" lease job-id)
     (query-exec conn "UPDATE executors SET last_seen_at = ? WHERE id = ?" (now) (hash-ref ex 'id))
     lease]
    [else v]))

;; a result is accepted only from the current holder; it is validated by the
;; kind's #:validate (a bad shape is the WORKER's mistake and fails the job)
(define (worker-complete! conn ex job-id result)
  (define v (holder-check conn ex job-id))
  (cond
    [(not (eq? v 'ok)) v]
    [else
     (define kind (query-value conn "SELECT kind FROM jobs WHERE id = ?" job-id))
     (define problem ((remote-kind-validator kind) result))
     (cond
       [problem
        (query-exec conn "UPDATE jobs SET status = 'error', error = ?, finished_at = CURRENT_TIMESTAMP WHERE id = ?"
                    (string-append "worker returned a bad result: " problem) job-id)
        'ok]
       [else
        (query-exec conn "UPDATE jobs SET status = 'done', result = ?, finished_at = CURRENT_TIMESTAMP WHERE id = ?"
                    (jsexpr->string result) job-id)
        (define team (query-value conn "SELECT team_id FROM jobs WHERE id = ?" job-id))
        ((scheduler-record!) conn team result)
        'ok])]))

(define (worker-fail! conn ex job-id message)
  (define v (holder-check conn ex job-id))
  (cond
    [(not (eq? v 'ok)) v]
    [else
     (query-exec conn "UPDATE jobs SET status = 'error', error = ?, finished_at = CURRENT_TIMESTAMP WHERE id = ?"
                 (format "executor ~a: ~a" (hash-ref ex 'name) message) job-id)
     'ok]))

;; an expired lease returns the job to the queue with attempt+1; past MAX-ATTEMPTS
;; it fails with the reason. Called from the scheduler's idle tick and by tests.
(define (reap-leases! conn)
  ;; every claim carries a lease now — a pull worker's and the pool's alike — so
  ;; this recovers an in-process job whose worker died as well as a remote one.
  ;; (`lease_until < ?` already skips a NULL lease; those are swept at boot by
  ;; the scheduler's reap-orphans!.)
  (define expired (query-rows conn
    "SELECT id, attempt FROM jobs WHERE status = 'running' AND lease_until < ?" (now)))
  (for ([r (in-list expired)])
    (define id (vector-ref r 0)) (define attempt (vector-ref r 1))
    (if (< attempt MAX-ATTEMPTS)
        (query-exec conn "UPDATE jobs SET status = 'queued', executor_id = NULL, lease_until = NULL, attempt = ? WHERE id = ?"
                    (add1 attempt) id)
        (query-exec conn
          "UPDATE jobs SET status = 'error', error = ?, executor_id = NULL, lease_until = NULL, finished_at = CURRENT_TIMESTAMP WHERE id = ?"
          (format "no executor completed it in ~a attempts (leases expired)" MAX-ATTEMPTS) id)))
  (length expired))

;; ---- routing a synchronous model call to a pull executor (PULL-5) --------------------
;; Enqueue an infer.chat sub-job and wait for a worker to complete it. Bounded:
;; a caller inside a job is itself under a lease; a request-path caller gets the
;; same bound. The sub-job carries parent_job_id so claim exempts it from the
;; team cap (its parent holds the slot) and requirements naming the executor.
(define WAIT-SECONDS 300)
(define (pull-dispatch! conn #:team team #:user user #:executor name #:messages msgs
                        #:model [model #f] #:temperature [temp 0.7] #:parent [parent #f])
  (define ex (executor-by-name conn name))
  (unless ex (error 'run-chat "no executor named ~a" name))
  (define id (enqueue-job! conn #:team team #:user user #:kind "infer.chat"
                           #:payload (hasheq 'messages msgs 'model (or model (hash-ref ex 'model) 'null) 'temperature temp)
                           #:requirements (hasheq 'executor name 'model (or model (hash-ref ex 'model) 'null))
                           #:parent parent))
  (let loop ([waited 0])
    (define r (query-row conn "SELECT status, result, error FROM jobs WHERE id = ?" id))
    (define st (vector-ref r 0))
    (cond
      [(equal? st "done")
       (define res (string->jsexpr (vector-ref r 1)))
       (values (hash-ref res 'reply "") (let ([t (hash-ref res 'tokens_used #f)]) (if (number? t) t 0)))]
      [(member st '("error" "canceled"))
       (error 'run-chat "executor ~a: ~a" name (let ([e (vector-ref r 2)]) (if (sql-null? e) st e)))]
      [(> waited WAIT-SECONDS)
       (query-exec conn "UPDATE jobs SET status = 'canceled', finished_at = CURRENT_TIMESTAMP WHERE id = ? AND status IN ('queued','running')" id)
       (error 'run-chat "executor ~a: no worker completed the request within ~a s" name WAIT-SECONDS)]
      [else (sleep 0.25) (loop (+ waited 0.25))])))
