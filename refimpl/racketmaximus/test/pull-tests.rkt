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
         "../domain/exec/pull.rkt"
         "../domain/repo/repo.rkt"
         (only-in "../domain/repo/blobs.rkt" current-blob-root)
         racket/file racket/port net/base64)

;; blobs go to a temp dir, never the checkout's data/
(current-blob-root (make-temporary-file "tmx-pull-blobs-~a" 'directory))
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
  (define wide-got (worker-claim! c wide #:kinds '("infer.chat") #:models '("qwen2.5:7b")))
  (check-equal? (hash-ref wide-got 'id) g1)
  ;; atomic: j1 is held by acme-ex; a second claim from wide cannot take it
  (check-false (worker-claim! c wide #:kinds '("infer.chat") #:models '("qwen2.5:7b")))
  ;; only the holder completes; a bad shape fails the job
  (check-equal? (worker-complete! c wide j1 (hasheq 'reply "x" 'tokens_used 1)
                                  #:token (hash-ref wide-got 'claim_token)) 'not-holder)
  (check-equal? (worker-complete! c acme-ex j1 (hasheq 'nope 1)
                                  #:token (hash-ref got 'claim_token)) 'ok "accepted from the holder…")
  (check-equal? (hash-ref (get-job c j1 (hash-ref acme 'team_id)) 'status) "error" "…but a bad result fails the job")
  (check-true (regexp-match? #rx"reply must be a string" (hash-ref (get-job c j1 (hash-ref acme 'team_id)) 'error)))
  (check-equal? (worker-complete! c wide g1 (hasheq 'reply "hello" 'tokens_used 9)
                                  #:token (hash-ref wide-got 'claim_token)) 'ok)
  (check-equal? (hash-ref (hash-ref (get-job c g1 (hash-ref globex 'team_id)) 'result) 'reply) "hello")
  (check-equal? (worker-complete! c wide g1 (hasheq 'reply "again" 'tokens_used 1)
                                  #:token (hash-ref wide-got 'claim_token)) 'not-running
                "a finished job takes no second result")
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
  (define fence (hash-ref claimed 'claim_token))
  (check-true (string? fence) "the claim hands back a fencing token")
  (check-true (number? (worker-heartbeat! c ex j #:token fence)) "the holder heartbeats")
  (check-equal? (worker-heartbeat! c ex j #:token "not-the-token") 'not-holder
                "…and a stale token is refused (issue #24)")
  (check-equal? (worker-heartbeat! c ex j) 'not-holder "…as is no token at all")
  (check-equal? (reap-leases! c) 0 "a live lease is not reaped")
  ;; expire it by hand — the test must not sleep two minutes
  (define (expire!) (query-exec c "UPDATE jobs SET lease_until = ? WHERE id = ?" (- (current-seconds) 1) j))
  (expire!)
  (check-equal? (reap-leases! c) 1)
  (check-equal? (hash-ref (get-job c j tid) 'status) "queued" "an expired lease returns the job to the queue")
  (check-equal? (hash-ref (get-job c j tid) 'attempt) 2)
  (check-equal? (worker-heartbeat! c ex j #:token fence) 'not-running "…and the old holder's heartbeat is refused")
  (check-equal? (worker-complete! c ex j (hasheq 'reply "late" 'tokens_used 1) #:token fence) 'not-running
                "a late result is refused too")
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
                                                     'tokens_used 3)
                                             ;; the claim's fence goes back with the result (issue #24)
                                             #:token (hash-ref job 'claim_token))
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
  (check-true (string? (claim-job! c j #:lease (+ (current-seconds) POOL-LEASE-SECONDS))))
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

;; ---- the fence (issue #24) ------------------------------------------------------

(test-case "a re-claimed job refuses the previous attempt's result, same holder and all"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "root"))
  (define p (user-principal c uid tid))
  (define-values (ex tok0) (executor-create! c p #:name "one-box" #:model "m"))
  (define j (enqueue-job! c #:team tid #:user uid #:kind "infer.chat" #:payload (hasheq 'messages '())))
  ;; attempt 1 claims, and is still alive when its lease lapses
  (define a1 (worker-claim! c ex #:kinds '("infer.chat") #:models '("m")))
  (define t1 (hash-ref a1 'claim_token))
  (query-exec c "UPDATE jobs SET lease_until = ? WHERE id = ?" (- (current-seconds) 1) j)
  (check-equal? (reap-leases! c) 1)
  ;; the SAME executor claims it again — which is exactly the case executor_id and
  ;; status cannot tell apart
  (define a2 (worker-claim! c ex #:kinds '("infer.chat") #:models '("m")))
  (define t2 (hash-ref a2 'claim_token))
  (check-equal? (hash-ref a2 'id) j)
  (check-false (equal? t1 t2) "a new attempt mints a new token")
  ;; attempt 1 finally finishes: refused, and the job is still running for attempt 2
  (check-equal? (worker-complete! c ex j (hasheq 'reply "from attempt 1" 'tokens_used 1) #:token t1) 'not-holder)
  (check-equal? (hash-ref (get-job c j tid) 'status) "running")
  (check-equal? (worker-fail! c ex j "attempt 1 gave up" #:token t1) 'not-holder
                "…and it cannot fail the live attempt either")
  ;; attempt 2 completes normally
  (check-equal? (worker-complete! c ex j (hasheq 'reply "from attempt 2" 'tokens_used 2) #:token t2) 'ok)
  (define done (get-job c j tid))
  (check-equal? (hash-ref done 'status) "done")
  (check-equal? (hash-ref (hash-ref done 'result) 'reply) "from attempt 2")
  ;; and the token is cleared, so even attempt 2 cannot write twice
  (check-equal? (worker-complete! c ex j (hasheq 'reply "again" 'tokens_used 1) #:token t2) 'not-running)
  (disconnect c))

(test-case "the pool is fenced the same way"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "root"))
  (define j (enqueue-job! c #:team tid #:user uid #:kind "local.echo" #:payload (hasheq 'x "hi")))
  (define t1 (claim-job! c j #:lease (+ (current-seconds) POOL-LEASE-SECONDS)))
  (check-true (string? t1) "a pool claim mints a token too")
  ;; reaped and re-claimed
  (query-exec c "UPDATE jobs SET lease_until = ? WHERE id = ?" (- (current-seconds) 1) j)
  (check-equal? (reap-leases! c) 1)
  (check-true (sql-null? (query-value c "SELECT claim_token FROM jobs WHERE id = ?" j))
              "requeueing clears the token")
  (define t2 (claim-job! c j #:lease (+ (current-seconds) POOL-LEASE-SECONDS)))
  (check-false (equal? t1 t2))
  (disconnect c))

;; issue #54: the claim took the oldest 64 queued jobs of ANY kind and filtered in
;; Racket, so a worker whose job sat behind a wall of in-process ones saw an empty
;; queue and polled forever against work it could have run.
(test-case "a remote job behind a wall of local ones is still claimable"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "root"))
  (define p (user-principal c uid tid))
  (define-values (ex tok) (executor-create! c p #:name "gpu" #:model "m"))
  ;; more local jobs than the scan window, queued FIRST so they sort ahead
  (for ([i (in-range 80)])
    (enqueue-job! c #:team tid #:user uid #:kind "local.echo" #:payload (hasheq 'x i)))
  (define remote (enqueue-job! c #:team tid #:user uid #:kind "infer.chat"
                               #:payload (hasheq 'messages '())))
  (define got (worker-claim! c (executor-by-token c (hash-ref ex 'token_id))))
  (check-true (hash? got) "the window bounds the scan, not the answer")
  (check-equal? (hash-ref got 'id) remote)
  (disconnect c))

;; ---- SCHED-8 on the remote path: a worker learns it was canceled ------------

(test-case "a canceled remote job tells its worker to stop, and settles when it does"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice"))
  (define p (user-principal c uid tid))
  (define-values (ex tok) (executor-create! c p #:name "gpu" #:model "m"))
  (define j (enqueue-job! c #:team tid #:user uid #:kind "infer.chat" #:payload (hasheq 'messages '())))
  (define claimed (worker-claim! c ex #:kinds '("infer.chat") #:models '("m")))
  (define fence (hash-ref claimed 'claim_token))
  (check-true (number? (worker-heartbeat! c ex j #:token fence)))
  ;; somebody cancels it while the worker is working
  (check-equal? (cancel-job! c j tid) #t)
  ;; the heartbeat is the only channel back to a remote worker — this is the signal
  (check-equal? (worker-heartbeat! c ex j #:token fence) 'canceled)
  ;; …and the cap still counts the job, because the worker has not stopped yet
  (check-equal? (query-value c (string-append "SELECT COUNT(*) FROM jobs WHERE team_id = ? AND " LIVE-IN) tid) 1)
  ;; a worker that honours it posts /fail (or /complete); either settles the row,
  ;; which is what frees the slot without waiting the lease out
  (check-equal? (worker-fail! c ex j "canceled" #:token fence) 'canceled)
  (check-equal? (query-value c "SELECT status FROM jobs WHERE id = ?" j) "canceled")
  (check-equal? (query-value c (string-append "SELECT COUNT(*) FROM jobs WHERE team_id = ? AND " LIVE-IN) tid) 0))

(test-case "a canceled job's lease lapsing settles it; it is never re-queued"
  ;; This is also what frees the slot of a handler that hung past SCHED-9's ceiling.
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice"))
  (define p (user-principal c uid tid))
  (define-values (ex tok) (executor-create! c p #:name "gpu" #:model "m"))
  (define j (enqueue-job! c #:team tid #:user uid #:kind "infer.chat" #:payload (hasheq 'messages '())))
  (void (worker-claim! c ex #:kinds '("infer.chat") #:models '("m")))
  (check-equal? (cancel-job! c j tid) #t)
  (query-exec c "UPDATE jobs SET lease_until = ? WHERE id = ?" (- (current-seconds) 1) j)
  (check-equal? (reap-leases! c) 1)
  (check-equal? (query-value c "SELECT status FROM jobs WHERE id = ?" j) "canceled"
                "cancellation is final — re-running stopped work is what nobody asked for")
  (check-equal? (query-value c "SELECT attempt FROM jobs WHERE id = ?" j) 1
                "…and its attempt was not bumped, which a re-queue would have done"))

;; ---- PULL-9: a worker reads the documents ITS OWN job names -----------------

(test-case "worker-document: holder, job-bound, and read as the job's own user"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice"))
  (define alice (user-principal c uid tid))
  (define-values (ex tok) (executor-create! c alice #:name "ocr-box" #:model "m"))
  (define-values (other other-tok) (executor-create! c alice #:name "elsewhere" #:model "m"))
  (define doc (repo-put! c alice #:key "scans/levee.txt" #:port (open-input-string "levee 7 looks sound")
                         #:content-type "text/plain" #:filename "levee.txt"))
  (define unrelated (repo-put! c alice #:key "scans/other.txt" #:port (open-input-string "not this one")
                               #:content-type "text/plain" #:filename "other.txt"))
  ;; a job that NAMES the document
  (define j (enqueue-job! c #:team tid #:user uid #:kind "infer.chat"
                          #:payload (hasheq 'messages '() 'object_id (hash-ref doc 'id))))
  (define claimed (worker-claim! c ex #:kinds '("infer.chat") #:models '("m")))
  (define fence (hash-ref claimed 'claim_token))

  ;; the bytes come back, byte-identical
  (define got (worker-document c ex j (hash-ref doc 'id) #:token fence))
  (check-true (hash? got) (format "~a" got))
  (check-equal? (bytes->string/utf-8 (base64-decode (string->bytes/utf-8 (hash-ref got 'bytes_b64))))
                "levee 7 looks sound")
  (check-equal? (hash-ref got 'key) "scans/levee.txt")
  ;; and the extracted text, for a worker that wants words rather than bytes
  (define txt (worker-document c ex j (hash-ref doc 'id) #:token fence #:as "text"))
  (check-equal? (hash-ref txt 'text) "levee 7 looks sound")
  (check-equal? (hash-ref txt 'reason) 'null)

  ;; the three halves of the fence
  (check-equal? (worker-document c ex j (hash-ref unrelated 'id) #:token fence) 'not-in-job
                "a worker token is not a key to the team's repository")
  (check-equal? (worker-document c ex j (hash-ref doc 'id) #:token "stale") 'not-holder)
  (check-equal? (worker-document c other j (hash-ref doc 'id) #:token fence) 'not-holder)
  (check-equal? (worker-document c ex j "" #:token fence) 'no-object)
  (check-equal? (worker-document c ex j (hash-ref doc 'id) #:token fence #:version "nope") 'no-such-document)

  ;; a job that names nothing reads nothing
  (define j2 (enqueue-job! c #:team tid #:user uid #:kind "infer.chat" #:payload (hasheq 'messages '())))
  (define claimed2 (worker-claim! c ex #:kinds '("infer.chat") #:models '("m")))
  (check-equal? (worker-document c ex j2 (hash-ref doc 'id) #:token (hash-ref claimed2 'claim_token))
                'not-in-job)
  ;; and a finished job reads nothing either — the fence is the ATTEMPT, not the team
  (void (worker-complete! c ex j2 (hasheq 'reply "x" 'tokens_used 1) #:token (hash-ref claimed2 'claim_token)))
  (check-equal? (worker-document c ex j2 (hash-ref doc 'id) #:token (hash-ref claimed2 'claim_token))
                'not-running))

(test-case "worker-document reads as the JOB'S user, so can? decides"
  ;; The read adds no authorization code: a document the job's user cannot see is
  ;; invisible to the worker running that user's job.
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice"))
  (define alice (user-principal c uid tid))
  (define bob (create-user! c #:username "bob"))
  (void (add-member! c #:team tid #:user bob #:role "member"))
  (define bobp (user-principal c bob tid))
  (define-values (ex tok) (executor-create! c alice #:name "gpu" #:model "m"))
  ;; alice's PRIVATE document — private from colleagues, not just from strangers
  (define secret (repo-put! c alice #:key "private/plan.txt" #:port (open-input-string "the plan")
                            #:content-type "text/plain" #:visibility "private"))
  ;; a job of BOB'S that names it
  (define j (enqueue-job! c #:team tid #:user bob #:kind "infer.chat"
                          #:payload (hasheq 'messages '() 'object_id (hash-ref secret 'id))))
  (void (worker-claim! c ex #:kinds '("infer.chat") #:models '("m")))
  (define fence (query-value c "SELECT claim_token FROM jobs WHERE id = ?" j))
  (check-equal? (worker-document c ex j (hash-ref secret 'id) #:token fence) 'no-such-document
                "naming a document in a payload does not grant access to it")
  ;; the same document, in a job of alice's own, does come back
  (define j2 (enqueue-job! c #:team tid #:user uid #:kind "infer.chat"
                           #:payload (hasheq 'messages '() 'object_id (hash-ref secret 'id))))
  (void (worker-claim! c ex #:kinds '("infer.chat") #:models '("m")))
  (define fence2 (query-value c "SELECT claim_token FROM jobs WHERE id = ?" j2))
  (check-true (hash? (worker-document c ex j2 (hash-ref secret 'id) #:token fence2))))

;; ---- issue #62: a worker WRITES a document derived from one its job names ----

(test-case "worker-derive!: the fence, the anchor, and the inheritance"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice"))
  (define alice (user-principal c uid tid))
  (define bob (create-user! c #:username "bob"))
  (void (add-member! c #:team tid #:user bob #:role "member"))
  (define-values (ex tok) (executor-create! c alice #:name "ocr-box" #:model "m"))
  (define-values (other other-tok) (executor-create! c alice #:name "elsewhere" #:model "m"))
  (define src (repo-put! c alice #:key "scans/levee.pdf" #:port (open-input-string "scanned bytes")
                         #:content-type "application/pdf" #:filename "levee.pdf"
                         #:visibility "private"))
  ;; a live grant on the SOURCE, so the inheritance below has something to copy
  (void (repo-share! c alice (hash-ref src 'id) #:principal-type "user" #:principal-id bob
                     #:capability "view"))
  (define unrelated (repo-put! c alice #:key "scans/other.pdf" #:port (open-input-string "not this one")
                               #:content-type "application/pdf"))
  (define j (enqueue-job! c #:team tid #:user uid #:kind "infer.chat"
                          #:payload (hasheq 'messages '() 'object_id (hash-ref src 'id))))
  (void (worker-claim! c ex #:kinds '("infer.chat") #:models '("m")))
  (define fence (query-value c "SELECT claim_token FROM jobs WHERE id = ?" j))
  (define b64 (lambda (str) (bytes->string/utf-8 (base64-encode (string->bytes/utf-8 str) #""))))

  ;; the happy path: the text layer lands beside the scan
  (define got (worker-derive! c ex j #:token fence
                              #:source (hash-ref src 'id) #:key "scans/levee.pdf.ocr.txt"
                              #:bytes-b64 (b64 "levee 7 looks sound") #:content-type "text/plain"))
  (check-true (hash? got) (format "~a" got))
  (check-equal? (hash-ref got 'derived_from) (hash-ref src 'id))
  (define out (repo-get c alice (hash-ref got 'object_id)))
  ;; byte-identical, and PRIVATE like its source — visibility first, then grants
  (define-values (o in) (repo-open c alice (hash-ref got 'object_id)))
  (check-equal? (port->string in) "levee 7 looks sound") (close-input-port in)
  (check-equal? (hash-ref out 'visibility) "private")
  ;; the source's live grant was copied, so bob can read the derived text too
  (define-values (ob bin) (repo-open c (user-principal c bob tid) (hash-ref got 'object_id)))
  (check-true (and bin (begin (close-input-port bin) #t)) "the grant was inherited")
  ;; and the derivation row says where it came from
  (check-equal? (query-value c "SELECT source_object_id FROM repo_derivations WHERE object_id = ?"
                             (hash-ref got 'object_id))
                (hash-ref src 'id))
  ;; the write is audited, naming the executor
  (check-equal? (query-value c (string-append "SELECT COUNT(*) FROM audit_log WHERE "
                                              "action = 'job.document.derived' AND resource_id = ?")
                             (hash-ref got 'object_id))
                1)

  ;; the fence, all three halves, plus the anchor
  (check-equal? (worker-derive! c ex j #:token "stale" #:source (hash-ref src 'id)
                                #:key "x.txt" #:bytes-b64 (b64 "x")) 'not-holder)
  (check-equal? (worker-derive! c other j #:token fence #:source (hash-ref src 'id)
                                #:key "x.txt" #:bytes-b64 (b64 "x")) 'not-holder)
  (check-equal? (worker-derive! c ex j #:token fence #:source (hash-ref unrelated 'id)
                                #:key "x.txt" #:bytes-b64 (b64 "x")) 'not-in-job
                "there is no standalone put — the output must derive from a document the job names")
  (check-equal? (worker-derive! c ex j #:token fence #:source ""
                                #:key "x.txt" #:bytes-b64 (b64 "x")) 'no-source)
  (check-equal? (worker-derive! c ex j #:token fence #:source (hash-ref src 'id)
                                #:key "" #:bytes-b64 (b64 "x")) 'no-key)
  (check-equal? (worker-derive! c ex j #:token fence #:source (hash-ref src 'id)
                                #:key "x.txt" #:bytes-b64 "") 'no-bytes)
  (check-equal? (worker-derive! c ex j #:token fence #:source (hash-ref src 'id)
                                #:key "x.txt" #:bytes-b64 "???") 'bad-bytes)
  ;; a refusal from the write itself comes back VERBATIM — the invalid key here
  (define refused (worker-derive! c ex j #:token fence #:source (hash-ref src 'id)
                                  #:key "../escape.txt" #:bytes-b64 (b64 "x")))
  (check-true (and (pair? refused) (eq? (car refused) 'refused)) (format "~a" refused))
  ;; the ceiling: a worker is not a way past TELEMACHUS_MAX_UPLOAD
  (putenv "TELEMACHUS_MAX_UPLOAD" "8")
  (check-equal? (worker-derive! c ex j #:token fence #:source (hash-ref src 'id)
                                #:key "x.txt" #:bytes-b64 (b64 "well over eight bytes"))
                'too-large)
  (putenv "TELEMACHUS_MAX_UPLOAD" "")
  ;; a settled job writes nothing — the fence is the ATTEMPT
  (void (worker-complete! c ex j (hasheq 'reply "x" 'tokens_used 1) #:token fence))
  (check-equal? (worker-derive! c ex j #:token fence #:source (hash-ref src 'id)
                                #:key "x.txt" #:bytes-b64 (b64 "x")) 'not-running))

(test-case "worker-derive! writes as the JOB'S user, so can? and the quotas decide"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice"))
  (define alice (user-principal c uid tid))
  (define bob (create-user! c #:username "bob"))
  (void (add-member! c #:team tid #:user bob #:role "member"))
  (define-values (ex tok) (executor-create! c alice #:name "gpu" #:model "m"))
  ;; alice's PRIVATE document in a job of BOB'S: the source is invisible to the
  ;; job's user, and a forbidden source and a missing one are ONE answer
  (define secret (repo-put! c alice #:key "private/plan.pdf" #:port (open-input-string "the plan")
                            #:content-type "application/pdf" #:visibility "private"))
  (define j (enqueue-job! c #:team tid #:user bob #:kind "infer.chat"
                          #:payload (hasheq 'messages '() 'object_id (hash-ref secret 'id))))
  (void (worker-claim! c ex #:kinds '("infer.chat") #:models '("m")))
  (define fence (query-value c "SELECT claim_token FROM jobs WHERE id = ?" j))
  (define b64 (lambda (str) (bytes->string/utf-8 (base64-encode (string->bytes/utf-8 str) #""))))
  (check-equal? (worker-derive! c ex j #:token fence #:source (hash-ref secret 'id)
                                #:key "x.txt" #:bytes-b64 (b64 "x"))
                'no-such-document
                "naming a document in a payload does not grant access to it"))

;; ---- issue #58: a worker says whether it is taking work ----------------------
(define (ex-named c p name)
  (findf (lambda (e) (equal? (hash-ref e 'name) name)) (executor-list c p)))

(test-case "worker state: reported, closed, and never asserted for a stale box"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice"))
  (define alice (user-principal c uid tid))
  (define-values (ex tok) (executor-create! c alice #:name "gpu" #:model "m"))

  ;; Nothing reported yet. The key is 'null rather than a guessed "ready": an
  ;; executor that has never spoken reads exactly as it did before migration
  ;; 0040, so a worker written against the old wire is not called paused for its
  ;; silence.
  (check-equal? (hash-ref (ex-named c alice "gpu") 'worker_state) 'null)
  (check-equal? (hash-ref (ex-named c alice "gpu") 'state_at) 'null)
  (check-equal? (hash-ref (ex-named c alice "gpu") 'status) "never-seen")

  ;; the standalone report — the one channel a worker with NO job can use
  (check-equal? (worker-report-state! c ex "paused") "paused")
  (define e1 (ex-named c alice "gpu"))
  (check-equal? (hash-ref e1 'worker_state) "paused")
  (check-true (number? (hash-ref e1 'state_at)))
  ;; liveness and willingness are SEPARATE questions: a paused worker is alive
  ;; and refusing, and `status` must keep saying so
  (check-equal? (hash-ref e1 'status) "active")

  ;; the vocabulary is closed
  (check-exn exn:fail:user? (lambda () (worker-report-state! c ex "draining")))
  (check-equal? (hash-ref (ex-named c alice "gpu") 'worker_state) "paused"
                "a refused report leaves the stored state alone")

  ;; a claim may carry one, so the normal loop needs no second request
  (void (worker-claim! c ex #:kinds '("infer.chat") #:models '("m") #:state "ready"))
  (check-equal? (hash-ref (ex-named c alice "gpu") 'worker_state) "ready")

  ;; a call that names NO state leaves the stored one alone rather than
  ;; overwriting it with a guess
  (void (worker-claim! c ex #:kinds '("infer.chat") #:models '("m")))
  (check-equal? (hash-ref (ex-named c alice "gpu") 'worker_state) "ready")

  ;; …and the heartbeat carries one too
  (define j (enqueue-job! c #:team tid #:user uid #:kind "infer.chat" #:payload (hasheq 'messages '())))
  (define claimed (worker-claim! c ex #:kinds '("infer.chat") #:models '("m") #:state "ready"))
  (check-true (hash? claimed))
  (check-true (number? (worker-heartbeat! c ex (hash-ref claimed 'id)
                                          #:token (hash-ref claimed 'claim_token) #:state "busy")))
  (check-equal? (hash-ref (ex-named c alice "gpu") 'worker_state) "busy")

  ;; A state is a claim about NOW. Once the row goes stale the last word is
  ;; withdrawn rather than repeated — the rule QUOTA-3 settled for a held job's
  ;; reason, where the key is absent rather than guessed.
  (query-exec c "UPDATE executors SET last_seen_at = ? WHERE id = ?"
              (- (current-seconds) (* 4 LEASE-SECONDS)) (hash-ref ex 'id))
  (define e2 (ex-named c alice "gpu"))
  (check-equal? (hash-ref e2 'status) "stale")
  (check-equal? (hash-ref e2 'worker_state) 'null
                "a worker that said busy an hour ago and vanished is stale, not busy")
  (check-equal? (hash-ref e2 'state_at) 'null))

;; ---- FLEET-1: the reaper leaves a record (issue #70) ---------------------------
;; The requeue sets executor_id to NULL, so after the UPDATE nothing in the jobs
;; table says which machine dropped the work. These are the assertions that the
;; trail is written BEFORE that happens, and that the final error names the boxes.

(define (lease-audit c job)
  (for/list ([r (in-list (query-rows c (string-append
                           "SELECT action, result, team_id, meta FROM audit_log "
                           "WHERE resource_id = ? ORDER BY at_us ASC") job))])
    (list (vector-ref r 0) (vector-ref r 1)
          (and (not (sql-null? (vector-ref r 2))) (vector-ref r 2))
          (string->jsexpr (vector-ref r 3)))))

(test-case "FLEET-1: every lease expiry is audited, and the error names the holders"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "root"))
  (define p (user-principal c uid tid))
  (define-values (ex1 _t1) (executor-create! c p #:name "gpu-1" #:model "m"))
  (define-values (ex2 _t2) (executor-create! c p #:name "gpu-2" #:model "m"))
  (define j (enqueue-job! c #:team tid #:user uid #:kind "infer.chat" #:payload (hasheq 'messages '())))
  (define (expire!) (query-exec c "UPDATE jobs SET lease_until = ? WHERE id = ?" (- (current-seconds) 1) j))

  ;; gpu-1 takes it and dies
  (check-equal? (hash-ref (worker-claim! c ex1 #:kinds '("infer.chat") #:models '("m")) 'id) j)
  (expire!) (check-equal? (reap-leases! c) 1)
  (define a1 (lease-audit c j))
  (check-equal? (length a1) 1 "one expiry, one entry")
  (check-equal? (car (car a1)) "job.lease.expired")
  (check-equal? (cadr (car a1)) "requeued" "the result says what became of the job")
  (check-equal? (caddr (car a1)) tid
                "the entry carries the JOB's team, or audit-list cannot show it to them")
  (define m1 (cadddr (car a1)))
  (check-equal? (hash-ref m1 'executor) "gpu-1"
                "the machine that dropped it is named, though executor_id is now NULL")
  (check-equal? (hash-ref m1 'kind) "infer.chat")
  (check-equal? (hash-ref m1 'max_attempts) MAX-ATTEMPTS)
  (check-true (sql-null? (query-value c "SELECT executor_id FROM jobs WHERE id = ?" j))
              "…and the row itself no longer remembers")

  ;; gpu-2 takes it and dies; then gpu-1 again, which exhausts it
  (check-equal? (hash-ref (worker-claim! c ex2 #:kinds '("infer.chat") #:models '("m")) 'id) j)
  (expire!) (reap-leases! c)
  (check-equal? (hash-ref (get-job c j tid) 'status) "queued" "still inside MAX-ATTEMPTS")
  (check-equal? (hash-ref (worker-claim! c ex1 #:kinds '("infer.chat") #:models '("m")) 'id) j)
  (expire!) (reap-leases! c)
  (check-equal? (hash-ref (get-job c j tid) 'status) "error")

  (define all (lease-audit c j))
  (check-equal? (map car all)
                '("job.lease.expired" "job.lease.expired" "job.lease.expired" "job.attempts.exhausted")
                "three expiries and the verdict, in order")
  (check-equal? (map cadr all) '("requeued" "requeued" "exhausted" "error"))
  (check-equal? (for/list ([e (in-list (take all 3))]) (hash-ref (cadddr e) 'executor))
                '("gpu-1" "gpu-2" "gpu-1")
                "oldest attempt first — one flaky box twice is not three boxes once")
  (check-equal? (hash-ref (cadddr (list-ref all 3)) 'holders) '("gpu-1" "gpu-2" "gpu-1"))
  ;; the stored error is the thing an operator reads first
  (define err (hash-ref (get-job c j tid) 'error))
  (check-true (regexp-match? #rx"leases expired" err) "the old wording still holds")
  (check-true (regexp-match? #rx"gpu-1, gpu-2, gpu-1" err) "…and it now names the holders")
  (disconnect c))

(test-case "FLEET-1: an in-process job names no executor, and says so"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "root"))
  (define j (enqueue-job! c #:team tid #:user uid #:kind "local.echo" #:payload (hasheq 'x "hi")))
  (define (expire!) (query-exec c "UPDATE jobs SET lease_until = ? WHERE id = ?" (- (current-seconds) 1) j))
  ;; the pool claims with a lease and no executor; three deaths in a row
  (let loop ([n 0])
    (when (< n MAX-ATTEMPTS)
      (check-true (string? (claim-job! c j #:lease (+ (current-seconds) POOL-LEASE-SECONDS))))
      (expire!) (reap-leases! c)
      (loop (add1 n))))
  (check-equal? (hash-ref (get-job c j tid) 'status) "error")
  (define all (lease-audit c j))
  (check-equal? (length all) (add1 MAX-ATTEMPTS))
  (check-equal? (hash-ref (cadddr (car all)) 'executor) 'null
                "no executor held it — null, never a guessed name")
  (check-true (regexp-match? #rx"in process" (hash-ref (get-job c j tid) 'error))
              "the error says the pool lost it, not that an executor did")
  (disconnect c))

;; ---- issue #61: a releasable claim that does not spend an attempt -------------
;; A worker that claims a job and then finds it cannot run it used to have two
;; ways out, and both blamed the job: fail it, or go quiet and let the lease
;; reap it. Each spent one of three attempts for something that was the HOST's
;; problem. These are the assertions that a release costs the job nothing, that
;; it cannot become a spin, and that it is still fenced.

(test-case "#61: a release re-queues, spends no attempt, and is fenced"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "root"))
  (define p (user-principal c uid tid))
  (define-values (ex tok) (executor-create! c p #:name "gpu-1" #:model "m"))
  (define j (enqueue-job! c #:team tid #:user uid #:kind "infer.chat" #:payload (hasheq 'messages '())))
  (define cl (worker-claim! c ex #:kinds '("infer.chat") #:models '("m")))
  (define fence (hash-ref cl 'claim_token))
  (define attempt-before (hash-ref (get-job c j tid) 'attempt))

  ;; fenced exactly like complete and fail: a stranger's token is refused, and a
  ;; refusal tells them nothing about somebody else's job
  (check-equal? (worker-release! c ex j #:token "not-the-token") 'not-holder)
  (check-equal? (worker-release! c ex j) 'not-holder "…as is no token at all")
  (check-equal? (hash-ref (get-job c j tid) 'status) "running" "a refused release changes nothing")

  (check-equal? (worker-release! c ex j #:token fence #:reason "unsupported") 'ok)
  (define after (get-job c j tid))
  (check-equal? (hash-ref after 'status) "queued" "straight back to the queue")
  (check-equal? (hash-ref after 'attempt) attempt-before
                "and the attempt counter is UNTOUCHED — that is the whole issue")
  (check-equal? (hash-ref after 'started_at) 'null "it never ran, so it has no start time")
  (check-true (sql-null? (query-value c "SELECT executor_id FROM jobs WHERE id = ?" j)))
  (check-equal? (worker-complete! c ex j (hasheq 'reply "late" 'tokens_used 1) #:token fence) 'not-running
                "the released attempt cannot land a result afterwards")
  (disconnect c))

(test-case "#61: the releaser waits out a cool-off; every other worker may take it at once"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "root"))
  (define p (user-principal c uid tid))
  (define-values (a _ta) (executor-create! c p #:name "box-a" #:model "m"))
  (define-values (b _tb) (executor-create! c p #:name "box-b" #:model "m"))
  (define j (enqueue-job! c #:team tid #:user uid #:kind "infer.chat" #:payload (hasheq 'messages '())))
  (define cl (worker-claim! c a #:kinds '("infer.chat") #:models '("m")))
  (check-equal? (worker-release! c a j #:token (hash-ref cl 'claim_token) #:reason "busy") 'ok)

  ;; the box that just let go is not handed it straight back — that is the bound
  ;; on a release loop, which the untouched attempt counter cannot provide
  (check-false (worker-claim! c a #:kinds '("infer.chat") #:models '("m"))
               "the releasing executor is in its cool-off")
  ;; …but a healthy fleet is not held up for it
  (check-equal? (hash-ref (worker-claim! c b #:kinds '("infer.chat") #:models '("m")) 'id) j
                "another worker takes it immediately — one bad box must not stall the queue")

  ;; and the cool-off really does expire rather than excluding for ever
  (worker-release! c b j #:token (query-value c "SELECT claim_token FROM jobs WHERE id = ?" j) #:reason "busy")
  (query-exec c "UPDATE jobs SET release_after = ? WHERE id = ?" (- (current-seconds) 1) j)
  (check-equal? (hash-ref (worker-claim! c b #:kinds '("infer.chat") #:models '("m")) 'id) j
                "past the horizon it is offered back")
  (disconnect c))

(test-case "#61: past MAX-RELEASES the job fails, naming the hosts that let it go"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "root"))
  (define p (user-principal c uid tid))
  (define-values (ex _t) (executor-create! c p #:name "fussy" #:model "m"))
  (define j (enqueue-job! c #:team tid #:user uid #:kind "infer.chat" #:payload (hasheq 'messages '())))
  (define (claim-release! r)
    (define cl (worker-claim! c ex #:kinds '("infer.chat") #:models '("m")))
    (check-true (and cl #t) "the cool-off was cleared, so it can claim again")
    (define v (worker-release! c ex j #:token (hash-ref cl 'claim_token) #:reason r))
    ;; the cool-off is per claim; clear it so the loop can run without sleeping
    (query-exec c "UPDATE jobs SET release_after = NULL WHERE id = ?" j)
    v)
  (for ([_ (in-range MAX-RELEASES)]) (check-equal? (claim-release! "busy") 'ok))
  (check-equal? (hash-ref (get-job c j tid) 'attempt) 1
                "ten releases later it has still never spent an attempt")
  (check-equal? (claim-release! "unsupported") 'failed "the next one gives up on it")
  (define done (get-job c j tid))
  (check-equal? (hash-ref done 'status) "error")
  (check-true (regexp-match? #rx"released 10 times" (hash-ref done 'error)))
  (check-true (regexp-match? #rx"fussy" (hash-ref done 'error))
              "…and names the host, so an operator knows where to look")
  ;; every release is in the trail, for FLEET-1's reason: the re-queue clears
  ;; executor_id, so afterwards nothing in the row says who let go
  (check-equal? (query-value c "SELECT COUNT(*) FROM audit_log WHERE action = 'job.released' AND resource_id = ?" j)
                (add1 MAX-RELEASES))
  (disconnect c))

(test-case "#61: an unknown reason is recorded, not refused; a canceled job is settled"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "root"))
  (define p (user-principal c uid tid))
  (define-values (ex _t) (executor-create! c p #:name "gpu-1" #:model "m"))
  (define j (enqueue-job! c #:team tid #:user uid #:kind "infer.chat" #:payload (hasheq 'messages '())))
  (define cl (worker-claim! c ex #:kinds '("infer.chat") #:models '("m")))
  ;; the RELEASE is the request and the reason rides along, so refusing the call
  ;; would leave the worker holding a job it has already said it cannot run
  (check-equal? (worker-release! c ex j #:token (hash-ref cl 'claim_token) #:reason "my-gpu-melted") 'ok)
  (check-equal? (hash-ref (string->jsexpr
                            (query-value c (string-append "SELECT meta FROM audit_log WHERE action = 'job.released' "
                                                          "AND resource_id = ?") j))
                          'reason)
                "other" "an unknown reason collapses, exactly as an extractor's does")

  ;; a release while the job is being CANCELED settles it — cancellation wins,
  ;; and re-queueing work somebody stopped is the one outcome nobody asked for
  (query-exec c "UPDATE jobs SET release_after = NULL WHERE id = ?" j)
  (define cl2 (worker-claim! c ex #:kinds '("infer.chat") #:models '("m")))
  (check-equal? (cancel-job! c j tid) #t)
  (check-equal? (hash-ref (get-job c j tid) 'status) "canceling")
  (check-equal? (worker-release! c ex j #:token (hash-ref cl2 'claim_token)) 'canceled)
  (check-equal? (hash-ref (get-job c j tid) 'status) "canceled" "settled, never re-queued")
  (disconnect c))

;; ---- issue #60: the worker token expires, and a rotation overlaps -----------------
;;
;; The knob is process-global, so every case that sets it restores it in a
;; dynamic-wind: a failing check raises, and a leaked TELEMACHUS_WORKER_TOKEN_DAYS
;; would silently change what every later test in this file mints (the trap
;; set-cap-for! set in test/fleet-tests.rkt).
(define (with-token-days days thunk)
  (define had (getenv "TELEMACHUS_WORKER_TOKEN_DAYS"))
  (dynamic-wind
    (lambda () (putenv "TELEMACHUS_WORKER_TOKEN_DAYS" days))
    thunk
    (lambda () (putenv "TELEMACHUS_WORKER_TOKEN_DAYS" (or had "")))))

(define (token-expiry c tok-id)
  (define v (query-maybe-value c "SELECT expires_at FROM api_tokens WHERE id = ?" tok-id))
  (and v (not (sql-null? v)) (string->number (format "~a" v))))
(define (token-status-of c tok-id)
  (query-value c "SELECT status FROM api_tokens WHERE id = ?" tok-id))

(test-case "#60: with the knob unset a worker token still never expires"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "root"))
  (define p (user-principal c uid tid))
  (define-values (ex tok) (executor-create! c p #:name "gpu-1" #:model "m"))
  ;; The whole upgrade-safety argument: nothing anybody has deployed stops
  ;; working, because expiry is opt-in per instance (the retention rule, DEL-9).
  ;; `#:ttl #f` would be issue-token!'s "default for this kind" — 30 days — so
  ;; this case fails against the obvious spelling of the change.
  (check-false (token-expiry c (hash-ref ex 'token_id)) "no expiry unless the instance asked for one")
  (define st (worker-token-status c ex))
  (check-equal? (hash-ref st 'expires_at) 'null)
  (check-false (hash-ref st 'rotate) "nothing to rotate for")
  (check-equal? (hash-ref st 'ttl_seconds) 'null)
  ;; and the token works, which is the point
  (check-equal? (hash-ref (executor-by-token c (hash-ref ex 'token_id)) 'name) "gpu-1")
  (check-true (string? tok))
  (disconnect c))

(test-case "#60: the knob sets a horizon, and the platform says when to rotate"
  (with-token-days "30" (lambda ()
    (define c (fresh))
    (define-values (uid tid) (bootstrap! c #:username "root"))
    (define p (user-principal c uid tid))
    (define-values (ex _t) (executor-create! c p #:name "gpu-1" #:model "m"))
    (define exp (token-expiry c (hash-ref ex 'token_id)))
    (check-true (and exp (> exp (+ (current-seconds) (* 29 86400)))) "~30 days out")
    (check-false (hash-ref (worker-token-status c ex) 'rotate) "not yet — a month of life left")
    ;; the window is a third of the token's life, so a token 20 days from its
    ;; horizon is still fine and one 60 seconds away is not
    (query-exec c "UPDATE api_tokens SET expires_at = ? WHERE id = ?"
                (number->string (+ (current-seconds) (* 20 86400))) (hash-ref ex 'token_id))
    (check-false (hash-ref (worker-token-status c (executor-by-id c (hash-ref ex 'id))) 'rotate))
    (query-exec c "UPDATE api_tokens SET expires_at = ? WHERE id = ?"
                (number->string (+ (current-seconds) 60)) (hash-ref ex 'token_id))
    (check-true (hash-ref (worker-token-status c (executor-by-id c (hash-ref ex 'id))) 'rotate)
                "inside the window the platform asks for a rotation")
    (disconnect c))))

(test-case "#60: a rotation OVERLAPS — both tokens work, and the old one is shortened"
  (with-token-days "30" (lambda ()
    (define c (fresh))
    (define-values (uid tid) (bootstrap! c #:username "root"))
    (define p (user-principal c uid tid))
    (define-values (ex old-raw) (executor-create! c p #:name "gpu-1" #:model "m"))
    (define old-id (hash-ref ex 'token_id))
    (define new-raw (rotate-worker-token! c ex #:actor-id uid))
    (check-true (string? new-raw) "a raw token, shown once")
    (check-false (equal? new-raw old-raw))
    (define after (executor-by-id c (hash-ref ex 'id)))
    (check-false (equal? (hash-ref after 'token_id) old-id) "the new token is the current one")
    (check-equal? (hash-ref after 'prev_token_id) old-id "…and the old one is in the second slot")
    ;; THE OVERLAP: the host may still be presenting the token it is replacing,
    ;; and refusing it here would make the rotation the outage it exists to avoid
    (check-equal? (hash-ref (executor-by-token c old-id) 'id) (hash-ref ex 'id)
                  "the outgoing token still resolves to its executor")
    (check-equal? (hash-ref (executor-by-token c (hash-ref after 'token_id)) 'id) (hash-ref ex 'id))
    ;; both are live credentials with the worker's scope, not merely rows
    (for ([raw (in-list (list old-raw new-raw))])
      (define rp (resolve-token c raw))
      (check-true (and rp #t) "both tokens resolve to a principal")
      (check-true (and (member "jobs:execute" (principal-token-scopes rp)) #t) "…with the worker scope"))
    ;; SHORTENED to the overlap, never extended: a token with 30 days left does
    ;; not get a year more life because something replaced it
    (define oexp (token-expiry c old-id))
    (check-true (and oexp (<= oexp (+ (current-seconds) WORKER-TOKEN-OVERLAP)))
                "the outgoing token now expires within the overlap")
    (check-true (> oexp (current-seconds)) "…but not yet")
    ;; the audit entry names both ids and never a token
    (define meta (string->jsexpr
                  (query-value c (string-append "SELECT meta FROM audit_log WHERE action = 'executor.token.rotate' "
                                                "AND resource_id = ?") (hash-ref ex 'id))))
    (check-equal? (hash-ref meta 'previous_token_id) old-id)
    (check-false (regexp-match? (regexp-quote new-raw) (format "~a" meta)) "the raw token is never written down")
    (disconnect c))))

(test-case "#60: two slots and no more; the identity is the row's, not the caller's"
  (with-token-days "30" (lambda ()
    (define c (fresh))
    (define-values (uid tid) (bootstrap! c #:username "root"))
    (define p (user-principal c uid tid))
    ;; a SECOND operator, to prove a rotation does not re-attribute the credential
    (define other (create-user! c #:username "ops2" #:password "pw-ops2-x"))
    (define-values (ex a-raw) (executor-create! c p #:name "gpu-1" #:model "m"))
    (define a (hash-ref ex 'token_id))
    (void (rotate-worker-token! c (executor-by-id c (hash-ref ex 'id)) #:actor-id other))
    (define e2 (executor-by-id c (hash-ref ex 'id)))
    (define b (hash-ref e2 'token_id))
    (check-equal? (query-value c "SELECT user_id FROM api_tokens WHERE id = ?" b) uid
                  "the new token belongs to whoever the old one did, never to the operator who pressed the button")
    (check-equal? (query-value c "SELECT team_id FROM api_tokens WHERE id = ?" b) tid)
    (check-equal? (string->jsexpr (query-value c "SELECT scopes FROM api_tokens WHERE id = ?" b)) '("jobs:execute"))
    ;; a third token retires the oldest at once: "how many live credentials does
    ;; this executor have" must have an answer, and it is two
    (void (rotate-worker-token! c e2 #:actor-id uid))
    (check-equal? (token-status-of c a) "revoked" "the oldest is revoked, not left to run out")
    (check-false (resolve-token c a-raw) "…and no longer resolves at all")
    (define e3 (executor-by-id c (hash-ref ex 'id)))
    (check-equal? (hash-ref e3 'prev_token_id) b)
    (check-equal? (token-status-of c b) "active")
    (disconnect c))))

(test-case "#60: the worker plane may not rotate in a loop; the operator always may"
  (with-token-days "30" (lambda ()
    (define c (fresh))
    (define-values (uid tid) (bootstrap! c #:username "root"))
    (define p (user-principal c uid tid))
    (define-values (ex _t) (executor-create! c p #:name "gpu-1" #:model "m"))
    ;; a buggy worker polling once a second would otherwise mint a token a second
    (check-equal? (rotate-worker-token! c ex #:actor-id uid #:min-age WORKER-ROTATE-MIN-AGE) 'too-soon)
    ;; …while a rotation somebody asked for on purpose — a token believed leaked —
    ;; is never refused because something rotated recently
    (check-true (string? (rotate-worker-token! c ex #:actor-id uid #:min-age 0)))
    ;; …and the floor NEVER refuses a rotation the platform asked for. This is
    ;; the exception that is the rule: a floor that can refuse the renewal the
    ;; platform is requesting is a scheduled outage with a rate limiter in front
    ;; of it. The smoke found it — a short lifetime puts a token inside its
    ;; renewal window while it is still younger than the floor.
    (with-token-days "0.0005" (lambda ()   ; 43 seconds: always inside its window
      (define-values (short _s) (executor-create! c p #:name "gpu-2" #:model "m"))
      (check-true (hash-ref (worker-token-status c short) 'rotate) "the platform is asking")
      (check-true (string? (rotate-worker-token! c short #:actor-id uid #:min-age WORKER-ROTATE-MIN-AGE))
                  "…so a seconds-old token rotates anyway")))
    ;; a push executor has no worker token at all
    (define-values (push _k) (executor-create! c p #:name "push-1" #:mode "push" #:url "http://127.0.0.1:1/v1/chat/completions"))
    (check-equal? (rotate-worker-token! c push #:actor-id uid) 'not-pull)
    (disconnect c))))

(test-case "#60: retiring an executor revokes BOTH slots"
  (with-token-days "30" (lambda ()
    (define c (fresh))
    (define-values (uid tid) (bootstrap! c #:username "root"))
    (define p (user-principal c uid tid))
    (define-values (ex a-raw) (executor-create! c p #:name "gpu-1" #:model "m"))
    (define a (hash-ref ex 'token_id))
    (define b-raw (rotate-worker-token! c (executor-by-id c (hash-ref ex 'id)) #:actor-id uid))
    (check-true (executor-retire! c p (hash-ref ex 'id)))
    ;; a retire that left the OLD token alive would leave a live jobs:execute
    ;; credential for a host the operator has just taken away
    (check-equal? (token-status-of c a) "revoked")
    (check-false (resolve-token c a-raw))
    (check-false (resolve-token c b-raw) "…and the current one too")
    (disconnect c))))
