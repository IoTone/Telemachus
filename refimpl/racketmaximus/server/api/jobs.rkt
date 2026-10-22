#lang racket/base

;; server/api/jobs.rkt — the async job queue
;;
;; Split out of main.rkt by #110 r3. The shared surface every handler here
;; needs — the pool, the request accessors, with-auth/with-mt, the response
;; constructors — is server/kit.rkt.

(provide ep-jobs-create ep-jobs-list ep-job-get ep-job-cancel ep-job-purge
         ep-schedules-list ep-schedules-create ep-schedule-get ep-schedule-patch ep-schedule-delete)

(require db-kit/portable
         web-kit
         (only-in "../../domain/authz/authz.rkt" audit! can? principal-team-id principal-user-id require-perm)
         (only-in "../../domain/sched/scheduler.rkt" cancel-job! enqueue-job! get-job list-jobs purge-job-content!)
         (only-in "../../domain/sched/schedules.rkt" SCHEDULE-MIN-INTERVAL schedule-create! schedule-delete!
                  schedule-get schedule-list schedule-problem schedule-update!)
         json
         "../kit.rkt"
         "../admission.rkt")

;; ---- async jobs -------------------------------------------------------------
(define (ep-jobs-create req)
  (with-auth req (lambda (p)
    (require-perm db-conn p "chat:use")
    (define b (read-json-body req))
    (define kind (hash-ref b 'kind #f))
    (cond
      [(not kind) (err "kind required" 400)]
      [else
       (define pr (hash-ref b 'priority 0))
       (define pl (let ([x (hash-ref b 'payload (hasheq))]) (if (hash? x) x (hasheq))))
       ;; #90: enqueueing is the other create a queued integrator retries. The
       ;; fingerprint covers the kind, the payload and the priority — a retry
       ;; that changed the priority is a different request, and silently
       ;; replaying the first would leave the job at a priority the client no
       ;; longer asked for.
       (with-idem req p b #:endpoint "POST /api/jobs"
                  #:payload (hasheq 'kind (format "~a" kind) 'payload pl
                                    'priority (if (number? pr) pr 0))
                  (lambda ()
                    (define id (enqueue-job! db-conn #:team (principal-team-id p)
                                             #:user (principal-user-id p)
                                             #:kind (format "~a" kind) #:payload pl
                                             #:priority (if (number? pr) pr 0)))
                    (values (hasheq 'id id 'status "queued") 202)))]))))

(define (ep-jobs-list req)
  (with-auth req (lambda (p) (json-response (hasheq 'jobs (list-jobs db-conn (principal-team-id p)))))))

(define (ep-job-get req id)
  (with-auth req (lambda (p)
    (define j (get-job db-conn id (principal-team-id p)))
    (if j (json-response j) (err "not found" 404)))))

;; SCHED-8. A job's OWNER may stop their own work, queued or running — the same
;; owner-ok rule notes and documents live by, and the person whose team budget a
;; runaway run is burning is exactly the person who should be able to stop it.
;; Stopping SOMEBODY ELSE's job is the stewardship act, and that needs
;; `jobs:cancel` (admin and owner by role). A running job goes to `canceling`:
;; its result is fenced out at once, and it stops holding its team's concurrency
;; slot when the handler actually returns.
(define (ep-job-cancel req id)
  (with-auth req (lambda (p)
    (define team (principal-team-id p))
    (define owner (query-maybe-value db-conn "SELECT user_id FROM jobs WHERE id = ? AND team_id = ?" id team))
    (cond
      [(not owner) (err "not found" 404)]
      [(and (not (equal? owner (principal-user-id p)))
            (not (can? db-conn p "jobs:cancel")))
       (err "forbidden: jobs:cancel (you may always cancel your own job)" 403)]
      [else
       (define r (cancel-job! db-conn id team))
       (cond
         [(eq? r #t)
          (define st (query-maybe-value db-conn "SELECT status FROM jobs WHERE id = ?" id))
          (audit! db-conn #:action "job.cancel" #:actor-type "user" #:actor-id (principal-user-id p)
                  #:team-id team #:resource-type "job" #:resource-id id)
          (json-response (hasheq 'ok #t 'id id 'status (or st "canceled")))]
         [(eq? r 'canceling) (json-response (hasheq 'ok #t 'id id 'status "canceling"))]
         [(eq? r 'not-cancelable) (err "the job has already finished — nothing to cancel" 409)]
         [else (err "not found" 404)])]))))

;; Purge a settled job's content (issue #59). Mirrors ep-job-cancel's shape: the
;; route carries no #:perm and the finer rule lives here, because "your own" and
;; "somebody else's" need different authorities and the table cannot express that.
(define (ep-job-purge req id)
  (with-auth req (lambda (p)
    (define team (principal-team-id p))
    (define owner (query-maybe-value db-conn "SELECT user_id FROM jobs WHERE id = ? AND team_id = ?" id team))
    (cond
      [(not owner) (err "not found" 404)]
      [(and (not (equal? owner (principal-user-id p)))
            (not (can? db-conn p "jobs:purge")))
       (err "forbidden: jobs:purge (you may always purge your own job)" 403)]
      [else
       (define r (purge-job-content! db-conn id team))
       (cond
         [(eq? r #t)
          ;; Audited with NO CONTENT in the entry — the point of the call is that
          ;; the content stops existing, and an audit row quoting it would be the
          ;; one copy left behind. The action, the actor and the job id are the
          ;; record that a deletion request was honoured.
          (audit! db-conn #:action "job.purge" #:actor-type "user" #:actor-id (principal-user-id p)
                  #:team-id team #:resource-type "job" #:resource-id id)
          (json-response (hasheq 'ok #t 'id id 'purged #t))]
         ;; Not an error: the caller asked for the content to be gone and it is.
         ;; `purged: #f` says THIS call did not do it, which a caller reconciling
         ;; a deletion request wants to know.
         [(eq? r 'already-purged) (json-response (hasheq 'ok #t 'id id 'purged #f))]
         [(eq? r 'not-settled)
          (err (string-append "the job is still queued, running or canceling — its payload is the input "
                              "a handler is about to read. Cancel it first, then purge.") 409)]
         [else (err "not found" 404)])]))))

;; ---- recurring work (#135) ---------------------------------------------------
;; The clock, and nothing else: each handler reads or writes a `job_schedules`
;; row, and the firing itself rides the pool's reaper seam in main.rkt. Every
;; read and write is team-scoped IN THE STATEMENT, so another team's id is a
;; miss rather than a refusal.
(define (ep-schedules-list req)
  (with-auth req (lambda (p)
    (require-perm db-conn p "jobs:schedule")
    (json-response (hasheq 'schedules (schedule-list db-conn (principal-team-id p))
                           'min_interval_seconds SCHEDULE-MIN-INTERVAL)))))

(define (ep-schedules-create req)
  (with-auth req (lambda (p)
    (require-perm db-conn p "jobs:schedule")
    (define b (read-json-body req))
    (define kind (let ([k (hash-ref b 'kind #f)]) (and k (format "~a" k))))
    (define interval (hash-ref b 'interval_seconds #f))
    (define payload (hash-ref b 'payload (hasheq)))
    (define problem (schedule-problem #:kind (or kind "") #:interval interval #:payload payload))
    (cond
      [problem (err problem 400)]
      [else
       (define id (schedule-create! db-conn
                                    #:team (principal-team-id p) #:user (principal-user-id p)
                                    #:kind kind #:interval interval #:payload payload
                                    #:requirements (let ([r (hash-ref b 'requirements (hasheq))])
                                                     (if (hash? r) r (hasheq)))
                                    #:priority (let ([x (hash-ref b 'priority 0)]) (if (exact-integer? x) x 0))
                                    #:name (let ([n (hash-ref b 'name #f)]) (and n (format "~a" n)))
                                    #:paused? (eq? #t (hash-ref b 'paused #f))
                                    #:created-by (principal-user-id p)))
       (audit! db-conn #:action "job.schedule.created" #:actor-type "user"
               #:actor-id (principal-user-id p) #:team-id (principal-team-id p)
               #:resource-type "job_schedule" #:resource-id id
               #:meta (jsexpr->string (hasheq 'kind kind 'interval_seconds interval)))
       (json-response (schedule-get db-conn id (principal-team-id p)) #:code 201)]))))

(define (ep-schedule-get req id)
  (with-auth req (lambda (p)
    (require-perm db-conn p "jobs:schedule")
    (define s (schedule-get db-conn id (principal-team-id p)))
    (if s (json-response s) (err "no such schedule" 404)))))

(define (ep-schedule-patch req id)
  (with-auth req (lambda (p)
    (require-perm db-conn p "jobs:schedule")
    (define b (read-json-body req))
    (define interval (hash-ref b 'interval_seconds 'same))
    (cond
      ;; The floor is the same floor create enforces — a patch is not a way
      ;; round it.
      [(and (not (eq? interval 'same))
            (not (and (exact-integer? interval) (>= interval SCHEDULE-MIN-INTERVAL))))
       (err (format "interval_seconds must be a whole number of seconds, at least ~a" SCHEDULE-MIN-INTERVAL) 400)]
      [else
       (define s (schedule-update! db-conn id (principal-team-id p)
                                   #:interval interval
                                   #:paused? (let ([v (hash-ref b 'paused 'same)])
                                               (if (boolean? v) v 'same))
                                   #:payload (let ([v (hash-ref b 'payload 'same)])
                                               (if (hash? v) v 'same))
                                   #:priority (hash-ref b 'priority 'same)
                                   #:name (let ([v (hash-ref b 'name 'same)])
                                            (if (eq? v 'same) 'same (format "~a" v)))))
       (cond
         [(not s) (err "no such schedule" 404)]
         [else
          (audit! db-conn #:action "job.schedule.updated" #:actor-type "user"
                  #:actor-id (principal-user-id p) #:team-id (principal-team-id p)
                  #:resource-type "job_schedule" #:resource-id id
                  #:meta (jsexpr->string (hasheq 'paused (hash-ref s 'paused)
                                                 'interval_seconds (hash-ref s 'interval_seconds))))
          (json-response s)])]))))

(define (ep-schedule-delete req id)
  (with-auth req (lambda (p)
    (require-perm db-conn p "jobs:schedule")
    (cond
      [(schedule-delete! db-conn id (principal-team-id p))
       (audit! db-conn #:action "job.schedule.deleted" #:actor-type "user"
               #:actor-id (principal-user-id p) #:team-id (principal-team-id p)
               #:resource-type "job_schedule" #:resource-id id)
       (json-response (hasheq 'ok #t))]
      [else (err "no such schedule" 404)]))))
