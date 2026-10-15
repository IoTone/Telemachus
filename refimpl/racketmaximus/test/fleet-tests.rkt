#lang racket/base

;; test/fleet-tests.rkt — FLEET-2: the operator's view of the worker fleet (#70).
;;   raco test test/fleet-tests.rkt
;;
;; What has to hold, without an HTTP server:
;;   1. an executor's entry says what it holds now and what it did in the window
;;   2. the window counts come from two sources that must not double-count:
;;      outcomes from the jobs row (the last attempt), expiries from FLEET-1's trail
;;   3. the queue's depth and its OLDEST age, with null for a pre-0041 row
;;   4. `unclaimable` counts jobs no live executor can run — and NOT a job that
;;      is merely held by a quota, which is a different answer
;;   5. the claim records what a worker declares, so the report has something true
;;      to read

(require rackunit db-kit/portable
         racket/list json
         db-kit/migrate
         "../domain/db/migrations.rkt"
         "db-fixture.rkt"
         "../domain/authz/authz.rkt"
         "../domain/orgs/orgs.rkt"
         "../domain/sched/scheduler.rkt"
         "../domain/exec/pull.rkt"
         "../domain/exec/fleet.rkt")

(define (fresh) (define c (fresh-db #:migrate? #f)) (migrate! c all-migrations) c)

(register-job-kind! "infer.chat" #f #:remote? #t
  #:validate (lambda (r) (if (and (hash? r) (string? (hash-ref r 'reply #f))) #f "result.reply must be a string")))
(register-job-kind! "fleet.local" (lambda (conn p payload) (hasheq 'ok #t)))

(define (ex-of rep name)
  (findf (lambda (e) (equal? (hash-ref e 'name) name)) (hash-ref rep 'executors)))
(define (depth-of rep kind)
  (let ([row (findf (lambda (d) (equal? (hash-ref d 'kind) kind)) (hash-ref (hash-ref rep 'queue) 'depth))])
    (and row (hash-ref row 'queued))))

(test-case "an executor's entry: what it holds, what it did, what it dropped"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "root"))
  (define p (user-principal c uid tid))
  (define-values (ex _t) (executor-create! c p #:name "gpu-1" #:model "m"))

  ;; nothing claimed yet
  (define r0 (fleet-report c p))
  (check-equal? (hash-ref (hash-ref r0 'fleet) 'pull) 1)
  (check-equal? (hash-ref (hash-ref r0 'fleet) 'never_seen) 1 "created and never heard from")
  (check-equal? (hash-ref (ex-of r0 "gpu-1") 'current) 'null)

  ;; one job claimed and held
  (define j (enqueue-job! c #:team tid #:user uid #:kind "infer.chat" #:payload (hasheq 'messages '())))
  (define cl (worker-claim! c ex #:kinds '("infer.chat") #:models '("m")))
  (check-equal? (hash-ref cl 'id) j)
  (define r1 (fleet-report c p))
  (define e1 (ex-of r1 "gpu-1"))
  (check-equal? (hash-ref (hash-ref r1 'fleet) 'active) 1 "a claim is a sighting")
  (define cur (hash-ref e1 'current))
  (check-equal? (hash-ref cur 'job_id) j)
  (check-equal? (hash-ref cur 'kind) "infer.chat")
  (check-equal? (hash-ref cur 'team_id) tid)
  (check-true (> (hash-ref cur 'seconds_left) 0) "the lease has time left on it")
  (check-equal? (hash-ref (hash-ref e1 'window) 'running) 1)

  ;; it completes: the outcome moves, and nothing is held
  (check-equal? (worker-complete! c ex j (hasheq 'reply "hi" 'tokens_used 1) #:token (hash-ref cl 'claim_token)) 'ok)
  (define r2 (fleet-report c p))
  (check-equal? (hash-ref (ex-of r2 "gpu-1") 'current) 'null)
  (check-equal? (hash-ref (hash-ref (ex-of r2 "gpu-1") 'window) 'done) 1)
  (check-equal? (hash-ref (hash-ref (ex-of r2 "gpu-1") 'window) 'leases_expired) 0)
  (disconnect c))

(test-case "the two counts do not double-count: outcomes from the row, expiries from the trail"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "root"))
  (define p (user-principal c uid tid))
  (define-values (e1 _t1) (executor-create! c p #:name "flaky" #:model "m"))
  (define-values (e2 _t2) (executor-create! c p #:name "solid" #:model "m"))
  (define j (enqueue-job! c #:team tid #:user uid #:kind "infer.chat" #:payload (hasheq 'messages '())))
  ;; flaky takes it and drops it
  (worker-claim! c e1 #:kinds '("infer.chat") #:models '("m"))
  (query-exec c "UPDATE jobs SET lease_until = ? WHERE id = ?" (- (current-seconds) 1) j)
  (check-equal? (reap-leases! c) 1)
  ;; solid takes it and finishes it
  (define cl (worker-claim! c e2 #:kinds '("infer.chat") #:models '("m")))
  (check-equal? (worker-complete! c e2 j (hasheq 'reply "ok" 'tokens_used 1) #:token (hash-ref cl 'claim_token)) 'ok)

  (define rep (fleet-report c p))
  (define wf (hash-ref (ex-of rep "flaky") 'window))
  (define ws (hash-ref (ex-of rep "solid") 'window))
  (check-equal? (hash-ref wf 'leases_expired) 1 "the trail remembers flaky, though the row does not")
  (check-equal? (hash-ref wf 'done) 0 "…and flaky is credited with nothing it did not finish")
  (check-equal? (hash-ref ws 'done) 1 "the final holder owns the outcome")
  (check-equal? (hash-ref ws 'leases_expired) 0 "…and is blamed for no expiry")
  (disconnect c))

(test-case "the queue: depth by kind, remote marked, and the oldest age"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "root"))
  (define p (user-principal c uid tid))
  (define old (enqueue-job! c #:team tid #:user uid #:kind "infer.chat" #:payload (hasheq 'messages '())))
  (enqueue-job! c #:team tid #:user uid #:kind "infer.chat" #:payload (hasheq 'messages '()))
  (enqueue-job! c #:team tid #:user uid #:kind "fleet.local" #:payload (hasheq))
  ;; age the first one by hand rather than sleeping
  (query-exec c "UPDATE jobs SET created_epoch = ? WHERE id = ?" (- (current-seconds) 600) old)

  (define q (hash-ref (fleet-report c p) 'queue))
  (check-equal? (depth-of (fleet-report c p) "infer.chat") 2)
  (check-equal? (depth-of (fleet-report c p) "fleet.local") 1)
  (check-true (hash-ref (findf (lambda (d) (equal? (hash-ref d 'kind) "infer.chat")) (hash-ref q 'depth)) 'remote)
              "a remote kind is marked — adding a machine can drain it")
  (check-false (hash-ref (findf (lambda (d) (equal? (hash-ref d 'kind) "fleet.local")) (hash-ref q 'depth)) 'remote)
               "an in-process kind is not")
  (check-true (>= (hash-ref q 'oldest_queued_seconds) 600) "the OLDEST wait, not the newest")

  ;; a row from before migration 0041 has no epoch, and is not guessed at
  (query-exec c "UPDATE jobs SET created_epoch = NULL")
  (check-equal? (hash-ref (hash-ref (fleet-report c p) 'queue) 'oldest_queued_seconds) 'null
                "null, never an age derived from nothing")
  (disconnect c))

(test-case "unclaimable: no live worker can run it — and a quota hold is NOT that"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "root"))
  (define p (user-principal c uid tid))
  ;; a job naming a model nobody has
  (define j (enqueue-job! c #:team tid #:user uid #:kind "infer.chat"
                          #:payload (hasheq 'messages '()) #:requirements (hasheq 'model "llama-70b")))
  (define u0 (hash-ref (hash-ref (fleet-report c p) 'queue) 'unclaimable))
  (check-equal? (hash-ref u0 'count) 1 "no executors at all: nothing can run it")

  ;; a worker that declares the wrong model does not help
  (define-values (ex _t) (executor-create! c p #:name "gpu-1" #:model "m"))
  (worker-claim! c ex #:kinds '("infer.chat") #:models '("qwen2.5:7b"))
  (check-equal? (hash-ref (hash-ref (hash-ref (fleet-report c p) 'queue) 'unclaimable) 'count) 1
                "a live box with the wrong model is still no answer")
  ;; …and the claim RECORDED what it declared, which is what the report reads
  (check-equal? (hash-ref (hash-ref (ex-of (fleet-report c p) "gpu-1") 'capabilities) 'models)
                '("qwen2.5:7b")
                "the capability record is what the worker said, not what was typed at create")

  ;; declare the right model and the job becomes claimable
  (worker-claim! c ex #:kinds '("infer.chat") #:models '("llama-70b"))
  (check-equal? (hash-ref (hash-ref (hash-ref (fleet-report c p) 'queue) 'unclaimable) 'count) 0
                "now a machine exists that can run it")

  ;; a job a QUOTA holds is admissible to some worker, so it is not unclaimable:
  ;; GET /api/jobs already explains that one (QUOTA-3), and counting it here
  ;; would send an operator to buy hardware for a budget problem.
  (define j2 (enqueue-job! c #:team tid #:user uid #:kind "infer.chat" #:payload (hasheq 'messages '())))
  (check-equal? (hash-ref (hash-ref (hash-ref (fleet-report c p) 'queue) 'unclaimable) 'count) 0)
  (disconnect c))

(test-case "a stale worker counts for nothing, and the org gate holds"
  (define c (fresh))
  (define-values (root sys) (bootstrap! c #:username "root" #:org-name "Instance" #:org-slug "system"))
  (define op (user-principal c root sys))
  (define acme (org-create! c #f #:name "Acme" #:slug "acme" #:owner-username "owner@acme"))
  (define globex (org-create! c #f #:name "Globex" #:slug "globex" #:owner-username "owner@globex"))
  ;; an Acme-bound worker, live; a Globex job it must never be offered
  (define-values (ax _t) (executor-create! c op #:name "acme-box" #:model "m"
                                           #:org (hash-ref acme 'org_id)))
  (worker-claim! c ax #:kinds '("infer.chat") #:models '("m"))
  (enqueue-job! c #:team (hash-ref globex 'team_id) #:user (hash-ref globex 'owner_user_id)
                #:kind "infer.chat" #:payload (hasheq 'messages '()))
  (check-equal? (hash-ref (hash-ref (hash-ref (fleet-report c op) 'queue) 'unclaimable) 'count) 1
                "another company's worker is not an answer for this queue")

  ;; the same worker gone stale stops counting as a reason the queue can drain
  (query-exec c "UPDATE executors SET last_seen_at = ? WHERE id = ?"
              (- (current-seconds) (* 10 STALE-AFTER)) (hash-ref ax 'id))
  (define rep (fleet-report c op))
  (check-equal? (hash-ref (hash-ref rep 'fleet) 'stale) 1)
  (check-equal? (hash-ref (hash-ref rep 'fleet) 'active) 0)
  (check-equal? (hash-ref (ex-of rep "acme-box") 'worker_state) 'null
                "a stale box's reported state is withdrawn (PULL-11e), here too")
  (disconnect c))

;; ---- FLEET-3: the operator's own lever ---------------------------------------
;; Before this the only way to take a box out of rotation was to RETIRE it, which
;; revokes the worker token — so a ten-minute drain meant re-provisioning the
;; host. These are the assertions that draining is reversible, that it leaves the
;; worker visibly alive, and that it does not touch work already in flight.

(test-case "FLEET-3: a drained worker is offered nothing, stays alive, and comes back"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "root"))
  (define p (user-principal c uid tid))
  (define-values (ex tok) (executor-create! c p #:name "gpu-1" #:model "m"))
  (define (claim) (worker-claim! c (executor-by-name c "gpu-1") #:kinds '("infer.chat") #:models '("m")))
  (define (j!) (enqueue-job! c #:team tid #:user uid #:kind "infer.chat" #:payload (hasheq 'messages '())))

  ;; a fresh executor is in rotation, and nothing was backfilled to say so
  (check-equal? (hash-ref (executor-by-name c "gpu-1") 'admin_state) "active")
  (check-true (sql-null? (query-value c "SELECT admin_state FROM executors WHERE id = ?" (hash-ref ex 'id)))
              "NULL in the column reads as active — no backfill")
  (define j1 (j!))
  (check-equal? (hash-ref (claim) 'id) j1 "it takes work")

  ;; drain it: the job it HOLDS is left alone
  (define drained (executor-set-admin-state! c p (hash-ref ex 'id) "drained"))
  (check-equal? (hash-ref drained 'admin_state) "drained")
  (check-equal? (hash-ref (get-job c j1 tid) 'status) "running"
                "draining says `start nothing new`, not `stop what you are doing`")

  ;; …and it is offered nothing more
  (define j2 (j!))
  (check-false (claim) "a drained worker gets no work")
  (check-equal? (hash-ref (get-job c j2 tid) 'status) "queued")

  ;; …while remaining visibly ALIVE, which is the whole difference from a retire
  (define e2 (executor-by-name c "gpu-1"))
  (check-equal? (hash-ref e2 'status) "active" "the claim was still a sighting")
  (check-true (and (resolve-token c tok) #t) "and its token still works")

  ;; the fleet report counts the intent separately from the liveness
  (define rep (fleet-report c p))
  (check-equal? (hash-ref (hash-ref rep 'fleet) 'drained) 1)
  (check-equal? (hash-ref (hash-ref rep 'fleet) 'active) 1
                "three questions, three answers — a drained box is still alive")
  ;; and it is not an answer to the queue: the job waiting on it is unclaimable
  (check-equal? (hash-ref (hash-ref (hash-ref rep 'queue) 'unclaimable) 'count) 1
                "a drained host must not read as a reason the queue can drain")

  ;; resume: back in rotation on the next claim
  (check-equal? (hash-ref (executor-set-admin-state! c p (hash-ref ex 'id) "active") 'admin_state) "active")
  (check-equal? (hash-ref (claim) 'id) j2)
  (check-equal? (hash-ref (hash-ref (hash-ref (fleet-report c p) 'queue) 'unclaimable) 'count) 0)
  (disconnect c))

(test-case "FLEET-3: the vocabulary is closed, a retired executor is not drainable, and both audit"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "root"))
  (define p (user-principal c uid tid))
  (define-values (ex _t) (executor-create! c p #:name "gpu-1" #:model "m"))
  (check-exn #rx"state must be one of"
             (lambda () (executor-set-admin-state! c p (hash-ref ex 'id) "retired"))
             "`retired` is not an admin state — retiring is irreversible and is its own call")
  (check-false (executor-set-admin-state! c p "no-such-id" "drained") "an unknown executor is #f")

  (executor-set-admin-state! c p (hash-ref ex 'id) "drained")
  (executor-set-admin-state! c p (hash-ref ex 'id) "active")
  (check-equal? (for/list ([a (in-list (query-list c (string-append
                                 "SELECT action FROM audit_log WHERE resource_id = ? "
                                 "AND action LIKE 'executor.%' ORDER BY at_us ASC") (hash-ref ex 'id)))]) a)
                '("executor.create" "executor.drain" "executor.resume")
                "an operator taking compute out of rotation is an audited act, both ways")

  ;; a retired row has no token to drain, and saying so beats pretending it worked
  (check-true (executor-retire! c p (hash-ref ex 'id)))
  (check-equal? (executor-set-admin-state! c p (hash-ref ex 'id) "drained") 'retired)
  (disconnect c))
