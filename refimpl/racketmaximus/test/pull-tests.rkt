#lang racket/base

;; test/pull-tests.rkt — slice 66: pull-model executors (PULL-1…6).
;;   raco test test/pull-tests.rkt
;;
;; What has to hold, without an HTTP server:
;;   1. a pull worker claims only REMOTE jobs its capabilities satisfy; the pool never does
;;   2. a claim is atomic — two workers, one job, one winner
;;   3. an org-bound executor never sees another company's job; an instance-wide one sees all
;;   4. a result is accepted only from the lease holder; an expired lease re-queues, then fails
;;   5. run-chat routed to a pull executor enqueues an infer.chat sub-job and waits for it
;;   6. retiring an executor revokes its token and releases its job

(require rackunit db-kit/portable
         racket/list json
         db-kit/migrate
         "../domain/db/migrations.rkt"
         "db-fixture.rkt"
         "../domain/authz/authz.rkt"
         "../domain/orgs/orgs.rkt"
         "../domain/sched/scheduler.rkt"
         "../domain/exec/pull.rkt")

(define (fresh) (define c (fresh-db #:migrate? #f)) (migrate! c all-migrations) c)

(register-job-kind! "infer.chat" #f #:remote? #t
  #:validate (lambda (r) (cond [(not (hash? r)) "result must be an object"]
                               [(not (string? (hash-ref r 'reply #f))) "result.reply must be a string"]
                               [else #f])))
(register-job-kind! "local.echo" (lambda (conn p payload) (hasheq 'echo (hash-ref payload 'x ""))))

(test-case "claims: remote kinds only, capabilities, atomicity, the org gate"
  (define c (fresh))
  (define-values (root sys) (bootstrap! c #:username "root" #:org-name "Instance" #:org-slug "system"))
  (define op (user-principal c root sys))
  (define acme (org-create! c #f #:name "Acme" #:slug "acme" #:owner-username "owner@acme"))
  (define globex (org-create! c #f #:name "Globex" #:slug "globex" #:owner-username "owner@globex"))
  (define acme-p (user-principal c (hash-ref acme 'owner_user_id) (hash-ref acme 'team_id)))
  (define globex-p (user-principal c (hash-ref globex 'owner_user_id) (hash-ref globex 'team_id)))
  ;; an instance-wide worker and an Acme-bound one
  (define-values (wide wide-tok) (executor-create! c op #:name "gpu-wide" #:model "qwen2.5:7b"))
  (define-values (acme-ex acme-tok) (executor-create! c acme-p #:name "acme-gpu" #:org (hash-ref acme 'org_id) #:model "llama-70b"))
  (check-true (string? wide-tok) "a pull executor returns its worker token once")
  (check-equal? (hash-ref wide 'status) "never-seen")
  (check-equal? (hash-ref (executor-by-token c (hash-ref wide 'token_id)) 'name) "gpu-wide" "the token resolves to its executor")
  (check-equal? (length (executor-list c globex-p)) 1 "globex sees only the instance-wide executor")
  (check-equal? (length (executor-list c op)) 2)
  ;; a local job is never offered to a worker; a remote one is never claimed by the pool
  (define local (enqueue-job! c #:team (hash-ref acme 'team_id) #:user (hash-ref acme 'owner_user_id) #:kind "local.echo" #:payload (hasheq 'x "hi")))
  (define j1 (enqueue-job! c #:team (hash-ref acme 'team_id) #:user (hash-ref acme 'owner_user_id) #:kind "infer.chat"
                           #:payload (hasheq 'messages '()) #:requirements (hasheq 'model "qwen2.5:7b")))
  (define g1 (enqueue-job! c #:team (hash-ref globex 'team_id) #:user (hash-ref globex 'owner_user_id) #:kind "infer.chat"
                           #:payload (hasheq 'messages '()) #:requirements (hasheq 'model "qwen2.5:7b")))
  (check-equal? (process-one! c) local "the pool claims the local job…")
  (check-false (process-one! c) "…and never a remote one")
  ;; capabilities: the wide worker offers only llama; j1 wants qwen — nothing
  (check-false (worker-claim! c wide #:kinds '("infer.chat") #:models '("llama-70b")) "no capable worker, no claim")
  ;; the Acme-bound worker never sees Globex's job — it offers qwen, so only the org gate blocks g1
  (define got (worker-claim! c acme-ex #:kinds '("infer.chat") #:models '("llama-70b" "qwen2.5:7b")))
  (check-equal? (hash-ref got 'id) j1 "the Acme worker gets Acme's job, not Globex's")
  (check-false (worker-claim! c acme-ex #:kinds '("infer.chat") #:models '("llama-70b" "qwen2.5:7b")) "…and nothing else")
  ;; the instance-wide worker gets Globex's
  (check-equal? (hash-ref (worker-claim! c wide #:kinds '("infer.chat") #:models '("qwen2.5:7b")) 'id) g1)
  ;; atomic: j1 is held by acme-ex; a second claim from wide cannot take it
  (check-false (worker-claim! c wide #:kinds '("infer.chat") #:models '("qwen2.5:7b")))
  ;; only the holder completes; a bad shape fails the job
  (check-equal? (worker-complete! c wide j1 (hasheq 'reply "x" 'tokens_used 1)) 'not-holder)
  (check-equal? (worker-complete! c acme-ex j1 (hasheq 'nope 1)) 'ok "accepted from the holder…")
  (check-equal? (hash-ref (get-job c j1 (hash-ref acme 'team_id)) 'status) "error" "…but a bad result fails the job")
  (check-true (regexp-match? #rx"reply must be a string" (hash-ref (get-job c j1 (hash-ref acme 'team_id)) 'error)))
  (check-equal? (worker-complete! c wide g1 (hasheq 'reply "hello" 'tokens_used 9)) 'ok)
  (check-equal? (hash-ref (hash-ref (get-job c g1 (hash-ref globex 'team_id)) 'result) 'reply) "hello")
  (check-equal? (worker-complete! c wide g1 (hasheq 'reply "again" 'tokens_used 1)) 'not-running "a finished job takes no second result")
  (check-equal? (hash-ref (car (executor-list c op)) 'status) "active" "a worker that claimed is active")
  (disconnect c))

(test-case "leases: heartbeat extends, expiry re-queues, MAX-ATTEMPTS fails, retire releases"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "root"))
  (define p (user-principal c uid tid))
  (define-values (ex tok) (executor-create! c p #:name "flaky" #:model "m"))
  (define j (enqueue-job! c #:team tid #:user uid #:kind "infer.chat" #:payload (hasheq 'messages '())))
  (define claimed (worker-claim! c ex #:kinds '("infer.chat") #:models '("m")))
  (check-equal? (hash-ref claimed 'id) j)
  (check-true (> (hash-ref claimed 'lease_until) (current-seconds)))
  (check-true (number? (worker-heartbeat! c ex j)) "the holder heartbeats")
  (check-equal? (reap-leases! c) 0 "a live lease is not reaped")
  ;; expire it by hand — the test must not sleep two minutes
  (define (expire!) (query-exec c "UPDATE jobs SET lease_until = ? WHERE id = ?" (- (current-seconds) 1) j))
  (expire!)
  (check-equal? (reap-leases! c) 1)
  (check-equal? (hash-ref (get-job c j tid) 'status) "queued" "an expired lease returns the job to the queue")
  (check-equal? (hash-ref (get-job c j tid) 'attempt) 2)
  (check-equal? (worker-heartbeat! c ex j) 'not-running "…and the old holder's heartbeat is refused")
  (check-equal? (worker-complete! c ex j (hasheq 'reply "late" 'tokens_used 1)) 'not-running "a late result is refused too")
  ;; claim, expire, claim, expire → past MAX-ATTEMPTS it fails for good
  (for ([_ (in-range (sub1 MAX-ATTEMPTS))])
    (check-true (and (worker-claim! c ex #:kinds '("infer.chat") #:models '("m")) #t))
    (expire!) (reap-leases! c))
  (check-equal? (hash-ref (get-job c j tid) 'status) "error")
  (check-true (regexp-match? #rx"leases expired" (hash-ref (get-job c j tid) 'error)))
  ;; retire: the token dies and a held job is released
  (define j2 (enqueue-job! c #:team tid #:user uid #:kind "infer.chat" #:payload (hasheq 'messages '())))
  (worker-claim! c ex #:kinds '("infer.chat") #:models '("m"))
  (check-true (and (resolve-token c tok) #t))
  (check-true (executor-retire! c p (hash-ref ex 'id)))
  (check-false (resolve-token c tok) "the worker token is revoked")
  (check-equal? (hash-ref (get-job c j2 tid) 'status) "queued" "the job it held is back in the queue")
  (check-false (executor-by-name c "flaky") "a retired executor is gone by name")
  (disconnect c))

(test-case "pull-dispatch!: a synchronous chat becomes an infer.chat sub-job a worker completes"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "root"))
  (define p (user-principal c uid tid))
  (define-values (ex tok) (executor-create! c p #:name "box" #:model "m"))
  ;; a worker thread that completes whatever it claims (a second connection over the SAME data)
  (define done (make-semaphore 0))
  (define worker
    (thread (lambda ()
              (let loop ([n 0])
                (define job (worker-claim! c ex #:kinds '("infer.chat") #:models '("m")))
                (cond [job (worker-complete! c ex (hash-ref job 'id)
                                             (hasheq 'reply (string-append "echo: " (hash-ref (car (hash-ref (hash-ref job 'payload) 'messages)) 'content))
                                                     'tokens_used 3))
                           (semaphore-post done)]
                      [(< n 400) (sleep 0.05) (loop (add1 n))])))))
  (define-values (reply tokens)
    (pull-dispatch! c #:team tid #:user uid #:executor "box" #:messages (list (hasheq 'role "user" 'content "hi")) #:temperature 0))
  (check-equal? reply "echo: hi")
  (check-equal? tokens 3)
  (semaphore-wait done)
  (define jobs (list-jobs c tid))
  (check-equal? (length jobs) 1)
  (check-equal? (hash-ref (car jobs) 'kind) "infer.chat")
  (check-equal? (hash-ref (car jobs) 'status) "done")
  (check-exn #rx"no executor named" (lambda () (pull-dispatch! c #:team tid #:user uid #:executor "nope" #:messages '())))
  (disconnect c))

;; ---- the reaper covers the pool too (issue #17) --------------------------------

(test-case "reap-leases! recovers an in-process job whose worker died"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "root"))
  ;; a pool job, claimed the way the scheduler claims one: leased, no executor
  (define j (enqueue-job! c #:team tid #:user uid #:kind "local.echo" #:payload (hasheq 'x "hi")))
  (check-true (claim-job! c j #:lease (+ (current-seconds) POOL-LEASE-SECONDS)))
  (check-true (sql-null? (query-value c "SELECT executor_id FROM jobs WHERE id = ?" j)) "no executor holds it")
  (check-equal? (reap-leases! c) 0 "a live lease is not reaped")
  ;; the worker's process is gone: nothing refreshes the lease
  (query-exec c "UPDATE jobs SET lease_until = ? WHERE id = ?" (- (current-seconds) 1) j)
  (check-equal? (reap-leases! c) 1)
  (check-equal? (hash-ref (get-job c j tid) 'status) "queued" "back in the queue, not running forever")
  (check-equal? (hash-ref (get-job c j tid) 'attempt) 2)
  ;; and the per-team cap counts it again only once it is re-claimed
  (check-equal? (query-value c "SELECT COUNT(*) FROM jobs WHERE team_id = ? AND status='running'" tid) 0)
  (check-equal? (process-one! c) j "the pool picks the recovered job back up")
  (check-equal? (hash-ref (get-job c j tid) 'status) "done")
  (disconnect c))
