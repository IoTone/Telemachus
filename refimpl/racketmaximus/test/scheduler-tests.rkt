#lang racket/base

;; #128 job 2: operator-facing variables are read through ONE accessor,
;; which tries TMACH_<name> and falls back to TELEMACHUS_<name>.
(require (only-in "../config.rkt" tmach-env))

;; test/scheduler-tests.rkt — the async job scheduler, driven synchronously via
;; process-one! (no thread races).  raco test test/scheduler-tests.rkt

(require rackunit db-kit/portable
         db-kit/migrate
         racket/list          ; findf
         "../domain/db/migrations.rkt"
         "db-fixture.rkt"
         "../domain/authz/authz.rkt"
         "../domain/db/id.rkt"
         "../domain/sched/scheduler.rkt")

(define (fresh) (define c (fresh-db #:migrate? #f)) (migrate! c all-migrations) c)

(test-case "enqueue → run (priority order), result recorded, cancel, error paths"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice"))
  (register-job-kind! "echo" (lambda (conn p payload) (hasheq 'echo (string-upcase (hash-ref payload 'text "")))))

  (define j1 (enqueue-job! c #:team tid #:user uid #:kind "echo" #:payload (hasheq 'text "low")  #:priority 0))
  (define j2 (enqueue-job! c #:team tid #:user uid #:kind "echo" #:payload (hasheq 'text "high") #:priority 5))
  (check-equal? (process-one! c) j2)                       ; higher priority runs first
  (define g2 (get-job c j2 tid))
  (check-equal? (hash-ref g2 'status) "done")
  (check-equal? (hash-ref (hash-ref g2 'result) 'echo) "HIGH")
  (check-equal? (process-one! c) j1)
  (check-equal? (hash-ref (get-job c j1 tid) 'status) "done")
  (check-false (process-one! c))                           ; queue drained

  ;; cancel a queued job → not picked up
  (define j3 (enqueue-job! c #:team tid #:user uid #:kind "echo" #:payload (hasheq 'text "x")))
  (check-true (cancel-job! c j3 tid))
  (check-equal? (hash-ref (get-job c j3 tid) 'status) "canceled")
  (check-false (process-one! c))
  (check-equal? (cancel-job! c j3 tid) 'not-cancelable)    ; already terminal

  ;; unknown kind and throwing handler → error status
  (define j4 (enqueue-job! c #:team tid #:user uid #:kind "nope"))
  (process-one! c)
  (check-equal? (hash-ref (get-job c j4 tid) 'status) "error")
  (register-job-kind! "boom" (lambda (conn p payload) (error "kaboom")))
  (define j5 (enqueue-job! c #:team tid #:user uid #:kind "boom"))
  (process-one! c)
  (check-equal? (hash-ref (get-job c j5 tid) 'status) "error")
  (check-regexp-match #rx"kaboom" (hash-ref (get-job c j5 tid) 'error))

  ;; team isolation
  (check-false (get-job c j2 "other-team")))

(test-case "per-team concurrency cap gates the claim"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice"))
  (register-job-kind! "ok" (lambda (conn p pl) (hasheq 'ok #t)))
  ;; simulate one already-running job for this team
  (query-exec c "INSERT INTO jobs (id,team_id,user_id,kind,status) VALUES (?,?,?,?,'running')" (new-id) tid uid "ok")
  (define jq (enqueue-job! c #:team tid #:user uid #:kind "ok"))
  (set-cap-for! (lambda (_) 1))
  (check-false (process-one! c))               ; team already at cap (1 running) → nothing claimed
  (set-cap-for! (lambda (_) 2))
  (check-equal? (process-one! c) jq)           ; cap raised → the queued job is claimed
  (set-cap-for! (lambda (_) 2)))               ; restore default

(test-case "quota hooks: a hold reason defers an over-budget team, record! bills the run"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice"))
  (register-job-kind! "meter" (lambda (conn p pl) (hasheq 'tokens_used 7)))
  (define j (enqueue-job! c #:team tid #:user uid #:kind "meter"))
  ;; a reason → the job stays queued (deferred), not run
  (define held (hasheq 'reason "quota" 'scope "team" 'dimension "ai.tokens.total" 'window "day"))
  (set-hold-reason! (lambda (conn team) held))
  (check-false (process-one! c))
  (check-equal? (hash-ref (get-job c j tid) 'status) "queued")
  ;; #f + record! captures the billed tokens
  (define billed (box 0))
  (set-hold-reason! (lambda (conn team) #f))
  (set-record!! (lambda (conn team result) (set-box! billed (+ (unbox billed) (hash-ref result 'tokens_used 0)))))
  (check-equal? (process-one! c) j)
  (check-equal? (hash-ref (get-job c j tid) 'status) "done")
  (check-equal? (unbox billed) 7)
  (set-record!! (lambda (conn team result) (void))))   ; restore defaults

;; ---- issue #55: a deferred job says WHY, and the deferral is reported --------

(test-case "a queued job carries the reason it is held, and only while it is held"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice"))
  (register-job-kind! "ok55" (lambda (conn p pl) (hasheq)))
  (define j (enqueue-job! c #:team tid #:user uid #:kind "ok55"))
  ;; nothing holding it: the key is ABSENT, not a reason nothing can stand behind
  (set-hold-reason! (lambda (conn team) #f))
  (set-cap-for! (lambda (_) 2))
  (check-false (hash-has-key? (get-job c j tid) 'waiting))
  ;; the budget holds it
  (set-hold-reason! (lambda (conn team)
                      (hasheq 'reason "quota" 'scope "team" 'dimension "ai.tokens.total" 'window "day")))
  (define w (hash-ref (get-job c j tid) 'waiting))
  (check-equal? (hash-ref w 'reason) "quota")
  (check-equal? (hash-ref w 'dimension) "ai.tokens.total")
  ;; the listing answers the same way
  (define lj (findf (lambda (x) (equal? (hash-ref x 'id) j)) (list-jobs c tid)))
  (check-equal? (hash-ref (hash-ref lj 'waiting) 'reason) "quota")
  ;; the CAP is checked before the budget, as claim-next! checks it, so a team
  ;; that is both at its cap and over budget is told about the cap — the one that
  ;; clears on its own
  (query-exec c "INSERT INTO jobs (id,team_id,user_id,kind,status) VALUES (?,?,?,?,'running')" (new-id) tid uid "ok55")
  (set-cap-for! (lambda (_) 1))
  (check-equal? (hash-ref (hash-ref (get-job c j tid) 'waiting) 'reason) "concurrency")
  ;; a RUNNING job never carries one
  (check-false (hash-has-key?
                (findf (lambda (x) (equal? (hash-ref x 'status) "running")) (list-jobs c tid))
                'waiting))
  (set-cap-for! (lambda (_) 2))
  (set-hold-reason! (lambda (conn team) #f)))

(test-case "the deferral is reported once per held claim, with the job it held"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice"))
  (register-job-kind! "ok55b" (lambda (conn p pl) (hasheq)))
  (define j (enqueue-job! c #:team tid #:user uid #:kind "ok55b"))
  (define seen (box '()))
  (set-hold-reason! (lambda (conn team) (hasheq 'reason "quota" 'dimension "ai.requests")))
  (set-on-hold! (lambda (conn team id reason) (set-box! seen (cons (cons id (hash-ref reason 'dimension)) (unbox seen)))))
  (check-false (process-one! c))
  (check-equal? (unbox seen) (list (cons j "ai.requests")))
  ;; admitted again → nothing reported
  (set-hold-reason! (lambda (conn team) #f))
  (check-equal? (process-one! c) j)
  (check-equal? (length (unbox seen)) 1)
  (set-on-hold! (lambda (conn team id reason) (void))))

;; ---- the claim is conditional, and a claimed job is leased (issue #17) --------

(test-case "claim-job! is conditional: only the caller that took the row believes it"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice"))
  (register-job-kind! "ok" (lambda (conn p pl) (hasheq 'ok #t)))
  (define j (enqueue-job! c #:team tid #:user uid #:kind "ok"))
  (define lease (+ (current-seconds) POOL-LEASE-SECONDS))
  ;; the claim returns this attempt's fencing token (issue #24), #f if it lost
  (define token (claim-job! c j #:lease lease))
  (check-true (string? token))                           ; first claimant takes it
  (check-equal? (query-value c "SELECT claim_token FROM jobs WHERE id = ?" j) token)
  (check-false (claim-job! c j #:lease (+ lease 99)))    ; second finds it no longer queued
  ;; the loser's update changed nothing: the first lease still stands
  (check-equal? (query-value c "SELECT status FROM jobs WHERE id = ?" j) "running")
  (check-equal? (query-value c "SELECT lease_until FROM jobs WHERE id = ?" j) lease))

(test-case "a pool claim carries a lease, and clears it when the job finishes"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice"))
  (define seen (box #f))
  (register-job-kind! "peek"
    (lambda (conn p pl)
      ;; mid-run: the row we are running carries a live lease, so the reaper
      ;; leaves it alone while this worker is alive
      (set-box! seen (query-value conn "SELECT lease_until FROM jobs WHERE id = ?" (hash-ref (current-job) 'id)))
      (hasheq 'ok #t)))
  (define j (enqueue-job! c #:team tid #:user uid #:kind "peek"))
  (check-equal? (process-one! c) j)
  (check-true (number? (unbox seen)))
  (check-true (> (unbox seen) (current-seconds)))
  (check-equal? (hash-ref (get-job c j tid) 'status) "done")
  (check-true (sql-null? (query-value c "SELECT lease_until FROM jobs WHERE id = ?" j))))   ; released

(test-case "a run whose lease was reaped mid-flight does not clobber the new attempt"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice"))
  (define billed (box 0))
  (set-record!! (lambda (conn team result) (set-box! billed (add1 (unbox billed)))))
  (register-job-kind! "slow"
    (lambda (conn p pl)
      ;; stand in for the reaper: the lease expired and the job went back to the queue
      (query-exec conn "UPDATE jobs SET status='queued', lease_until=NULL, attempt=2 WHERE id = ?"
                  (hash-ref (current-job) 'id))
      (hasheq 'tokens_used 5)))
  (define j (enqueue-job! c #:team tid #:user uid #:kind "slow"))
  (process-one! c)
  (check-equal? (hash-ref (get-job c j tid) 'status) "queued")   ; still the queued retry, not "done"
  (check-equal? (unbox billed) 0)                                ; and nothing was billed for it
  (set-record!! (lambda (conn team result) (void))))

(test-case "reap-orphans! requeues a job left running with no lease"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice"))
  (register-job-kind! "ok" (lambda (conn p pl) (hasheq 'ok #t)))
  ;; what a pre-lease build (or a process that died) leaves behind
  (define orphan (new-id))
  (query-exec c "INSERT INTO jobs (id,team_id,user_id,kind,status) VALUES (?,?,?,?,'running')" orphan tid uid "ok")
  (define live (new-id))
  (query-exec c "INSERT INTO jobs (id,team_id,user_id,kind,status,lease_until) VALUES (?,?,?,?,'running',?)"
              live tid uid "ok" (+ (current-seconds) 300))
  (check-equal? (reap-orphans! c) 1)
  (check-equal? (query-value c "SELECT status FROM jobs WHERE id = ?" orphan) "queued")
  (check-equal? (query-value c "SELECT status FROM jobs WHERE id = ?" live) "running"))   ; a live lease is untouched

;; ---- SCHED-8: cancelling a job that is already RUNNING ----------------------

(test-case "a cancelled RUNNING job keeps its concurrency slot until the handler stops"
  ;; The property the whole `canceling` status exists for. Flipping a running job
  ;; straight to `canceled` would drop it out of the per-team cap count while its
  ;; handler was still holding a thread and still spending tokens — cancel N jobs
  ;; in a loop and the team gets N draining handlers plus N freshly claimed ones,
  ;; with the cap reading as satisfied throughout.
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice"))
  (define live-count (box -1))
  (define saw (box 'nothing))
  (register-job-kind! "cancels-itself"
    (lambda (conn p payload)
      (define id (hash-ref (current-job) 'id))
      (set-box! saw (cancel-job! conn id tid))
      ;; still inside the handler: the work is live, so the cap must still see it
      (set-box! live-count
                (query-value conn (string-append "SELECT COUNT(*) FROM jobs WHERE team_id = ? AND " LIVE-IN) tid))
      (hasheq 'finished "anyway")))
  (define j (enqueue-job! c #:team tid #:user uid #:kind "cancels-itself"))
  (process-one! c)
  (check-equal? (unbox saw) #t)                       ; a running job IS cancelable
  (check-equal? (unbox live-count) 1)                 ; and still counted while it drains
  (define g (get-job c j tid))
  (check-equal? (hash-ref g 'status) "canceled")      ; settled once the handler returned
  (check-equal? (hash-ref g 'result) 'null)           ; its answer was discarded, not stored
  ;; and NOW the slot is free
  (check-equal? (query-value c (string-append "SELECT COUNT(*) FROM jobs WHERE team_id = ? AND " LIVE-IN) tid) 0))

(test-case "cancel is reported honestly at every stage"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice"))
  (register-job-kind! "ok2" (lambda (conn p pl) (hasheq 'ok #t)))
  (check-false (cancel-job! c (new-id) tid))                     ; no such job
  (define j (enqueue-job! c #:team tid #:user uid #:kind "ok2"))
  (define tok (claim-job! c j #:lease (+ (current-seconds) 300))) ; now running
  (check-equal? (cancel-job! c j tid) #t)
  (check-equal? (query-value c "SELECT status FROM jobs WHERE id = ?" j) "canceling")
  (check-equal? (cancel-job! c j tid) 'canceling)                ; already on its way out
  (check-true (job-canceled? c j))
  ;; the attempt's result can no longer land
  (check-false (finish! c j "done" #:result "{}" #:token tok))
  (check-true (settle-canceling! c j tok))
  (check-equal? (query-value c "SELECT status FROM jobs WHERE id = ?" j) "canceled")
  (check-equal? (cancel-job! c j tid) 'not-cancelable)           ; terminal
  (check-false (settle-canceling! c j tok)))                     ; and settling again is a no-op

(test-case "settle-canceling! is fenced by the attempt's claim token"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice"))
  (register-job-kind! "ok3" (lambda (conn p pl) (hasheq 'ok #t)))
  (define j (enqueue-job! c #:team tid #:user uid #:kind "ok3"))
  (define tok (claim-job! c j #:lease (+ (current-seconds) 300)))
  (check-equal? (cancel-job! c j tid) #t)
  (check-false (settle-canceling! c j "some-other-attempt"))     ; not this attempt's to settle
  (check-equal? (query-value c "SELECT status FROM jobs WHERE id = ?" j) "canceling")
  (check-true (settle-canceling! c j tok)))

;; ---- SCHED-9: the wall-clock ceiling ----------------------------------------

(test-case "every claim stamps started_epoch, which the ceiling is measured against"
  ;; There is ONE claim path (issue #17) and both the pool and a pull worker go
  ;; through it. A second one appearing later would leave this column NULL and
  ;; the ceiling would quietly stop applying to those jobs — hence the assertion.
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice"))
  (register-job-kind! "ok4" (lambda (conn p pl) (hasheq 'ok #t)))
  (define j (enqueue-job! c #:team tid #:user uid #:kind "ok4"))
  (check-true (sql-null? (query-value c "SELECT started_epoch FROM jobs WHERE id = ?" j)))
  (define before (current-seconds))
  (void (claim-job! c j #:lease (+ (current-seconds) 300)))
  (define se (query-value c "SELECT started_epoch FROM jobs WHERE id = ?" j))
  (check-false (sql-null? se))
  (check-true (>= se before))
  ;; and the pool's own claim stamps it too
  (define j2 (enqueue-job! c #:team tid #:user uid #:kind "ok4"))
  (process-one! c)
  (check-false (sql-null? (query-value c "SELECT started_epoch FROM jobs WHERE id = ?" j2))))

(test-case "the ceiling is configurable, and never silently zero"
  (define old (tmach-env "MAX_JOB_SECONDS"))
  (define (cap v) (void (putenv "TMACH_MAX_JOB_SECONDS" v)))
  (cap "") (check-equal? (max-job-seconds) 1800)        ; unset → the shipped default
  (cap "60") (check-equal? (max-job-seconds) 60)
  (cap " 90 ") (check-equal? (max-job-seconds) 90)
  (cap "never") (check-false (max-job-seconds))          ; explicitly off
  (cap "NEVER") (check-false (max-job-seconds))
  (cap "nonsense") (check-equal? (max-job-seconds) 1800) ; never a surprise 0, which would
  (cap "0") (check-equal? (max-job-seconds) 1800)        ; cancel every job as it started
  (cap "-5") (check-equal? (max-job-seconds) 1800)
  (void (if old (putenv "TMACH_MAX_JOB_SECONDS" old) (putenv "TMACH_MAX_JOB_SECONDS" ""))))

(test-case "a tick past the ceiling cancels the job; before it, it extends the lease"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice"))
  (register-job-kind! "ok5" (lambda (conn p pl) (hasheq 'ok #t)))
  (define j (enqueue-job! c #:team tid #:user uid #:kind "ok5"))
  (define tok (claim-job! c j #:lease (+ (current-seconds) 5)))
  ;; within the ceiling: the lease moves forward and the job stays running
  (check-equal? (lease-tick! c j tok (+ (current-seconds) 300)) 'refreshed)
  (check-equal? (query-value c "SELECT status FROM jobs WHERE id = ?" j) "running")
  (check-true (> (query-value c "SELECT lease_until FROM jobs WHERE id = ?" j) (+ (current-seconds) 60)))
  ;; a stale attempt's tick neither times the job out nor extends its lease
  (check-equal? (lease-tick! c j "stale-attempt" (- (current-seconds) 1)) 'timed-out)
  (check-equal? (query-value c "SELECT status FROM jobs WHERE id = ?" j) "running")
  ;; past the ceiling: canceling, with a reason that names the knob
  (check-equal? (lease-tick! c j tok (- (current-seconds) 1)) 'timed-out)
  (check-equal? (query-value c "SELECT status FROM jobs WHERE id = ?" j) "canceling")
  (check-regexp-match #rx"TMACH_MAX_JOB_SECONDS"
                      (query-value c "SELECT error FROM jobs WHERE id = ?" j))
  ;; "no limit" never times anything out
  (check-equal? (lease-tick! c j tok #f) 'refreshed))

(test-case "reap-orphans! settles a canceling job rather than re-queuing it"
  ;; Re-running work somebody stopped is the one outcome nobody asked for.
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice"))
  (define stopping (new-id))
  (query-exec c "INSERT INTO jobs (id,team_id,user_id,kind,status) VALUES (?,?,?,?,'canceling')"
              stopping tid uid "ok")
  (check-equal? (reap-orphans! c) 1)
  (check-equal? (query-value c "SELECT status FROM jobs WHERE id = ?" stopping) "canceled"))

;; ---- graceful shutdown (issue #89) -----------------------------------------

(test-case "drain-seconds: a default, an off switch, and never 0 by accident"
  (define (with-env v thunk)
    (define old (tmach-env "DRAIN_SECONDS"))
    (dynamic-wind
     (lambda () (if v (putenv "TMACH_DRAIN_SECONDS" v) (putenv "TMACH_DRAIN_SECONDS" "")))
     thunk
     ;; restore in a dynamic-wind: a failing check raises, and a leaked value
     ;; would change what every later test in this file measures
     (lambda () (putenv "TMACH_DRAIN_SECONDS" (or old "")))))
  (with-env #f    (lambda () (check-equal? (drain-seconds) 25)))
  (with-env "60"  (lambda () (check-equal? (drain-seconds) 60)))
  ;; An off switch has to be spelled, and it is the one case 0 is meant.
  (with-env "0"      (lambda () (check-equal? (drain-seconds) 0)))
  (with-env "never"  (lambda () (check-equal? (drain-seconds) 0)))
  ;; …and a typo must never read as "hand everything back immediately", which is
  ;; the platform's rule for every interval knob.
  (with-env "banana" (lambda () (check-equal? (drain-seconds) 25)))
  (with-env "-5"     (lambda () (check-equal? (drain-seconds) 25))))

(test-case "a drain hands back what did not finish, un-charged, and fences its result"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "drainer"))
  (define started (make-semaphore 0))
  (define release (make-semaphore 0))
  (register-job-kind! "slow"
    (lambda (conn p payload)
      (semaphore-post started)
      (semaphore-wait release)        ; held in flight until this test lets go
      (hasheq 'finished #t)))
  (define j (enqueue-job! c #:team tid #:user uid #:kind "slow"))
  (define att0 (hash-ref (get-job c j tid) 'attempt))
  (check-equal? (scheduler-inflight-count) 0 "nothing is held before the claim")

  (define runner (thread (lambda () (process-one! c))))
  (semaphore-wait started)
  ;; The register is what makes a drain possible at all: `executor_id IS NULL`
  ;; is every replica's pool work, not this process's.
  (check-equal? (scheduler-inflight-count) 1 "the pool knows what it is holding")

  ;; No patience at all: hand it straight back.
  (define-values (finished requeued) (drain-scheduler! c #:seconds 0))
  (check-equal? requeued 1)
  (check-equal? finished 0)
  (define g (get-job c j tid))
  (check-equal? (hash-ref g 'status) "queued" "the job is runnable again")
  (check-equal? (hash-ref g 'attempt) att0
                "a shutdown is not the job's fault — no attempt is spent")

  ;; Now let the handler run to completion. Its result must NOT land: the drain
  ;; cleared the attempt's claim_token, and `finish!` names it (issue #24). This
  ;; is the same fence a cancelled job relies on, and without it a drained job
  ;; would be marked done by a process that no longer owns it.
  (semaphore-post release)
  (thread-wait runner)
  (define g2 (get-job c j tid))
  (check-equal? (hash-ref g2 'status) "queued"
                "the drained attempt cannot complete the job it let go of")
  ;; `'null`, not #f: get-job maps a NULL column to the jsexpr null.
  (check-equal? (hash-ref g2 'result) 'null "…and wrote no result at all")
  (check-equal? (scheduler-inflight-count) 0 "the register is empty again")
  (close-db! c))

(test-case "a drain waits for a job that finishes in time, and spends nothing"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "waiter"))
  (define started (make-semaphore 0))
  (register-job-kind! "quick"
    (lambda (conn p payload) (semaphore-post started) (hasheq 'ok #t)))
  (define j (enqueue-job! c #:team tid #:user uid #:kind "quick"))
  (define runner (thread (lambda () (process-one! c))))
  (semaphore-wait started)
  (thread-wait runner)                       ; it really did finish on its own
  ;; A drain with work already done reports no requeue — the ordinary restart.
  (define-values (finished requeued) (drain-scheduler! c #:seconds 5))
  (check-equal? requeued 0)
  (check-equal? (hash-ref (get-job c j tid) 'status) "done")
  (close-db! c))

;; ---- purging a settled job's content (issue #59) --------------------------------
;; `payload` holds the document's own text for `infer.chat` and the pipeline, and
;; `result` the model's reply; nothing ever removed them. The case that forced
;; this is a downstream application honouring a deletion request: it can clear
;; its own rows, and the text stayed here.
;;
;; The assertions are deliberately split between "the content is gone" and "the
;; row is still accountable", because a DELETE would satisfy the first and
;; destroy the second — and the audit log, not the job row, is the record of
;; what happened.
(test-case "a settled job's content is purgeable, once, and the row survives"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice"))
  (register-job-kind! "echo" (lambda (conn p payload) (hasheq 'echo (hash-ref payload 'secret ""))))

  (define j (enqueue-job! c #:team tid #:user uid #:kind "echo"
                          #:payload (hasheq 'secret "PATIENT-RECORD-8831")))
  ;; before: the sensitive text really is in the row, or the test proves nothing
  (check-equal? (query-value c "SELECT payload FROM jobs WHERE id = ?" j)
                "{\"secret\":\"PATIENT-RECORD-8831\"}")
  (check-equal? (purge-job-content! c j tid) 'not-settled
                "a QUEUED job is refused: its payload is the input a handler will read")

  (check-equal? (process-one! c) j)
  (define before (get-job c j tid))
  (check-equal? (hash-ref before 'status) "done")
  (check-equal? (hash-ref (hash-ref before 'result) 'echo) "PATIENT-RECORD-8831")
  (check-equal? (hash-ref before 'purged_at) 'null "not purged yet")

  ;; the purge itself
  (check-equal? (purge-job-content! c j tid) #t)
  (check-equal? (query-value c "SELECT payload FROM jobs WHERE id = ?" j) "{}")
  (check-true (sql-null? (query-value c "SELECT result FROM jobs WHERE id = ?" j)))
  (check-true (sql-null? (query-value c "SELECT error FROM jobs WHERE id = ?" j)))
  ;; and NOTHING anywhere in the row still quotes it
  (check-false (regexp-match? #px"PATIENT-RECORD"
                              (format "~a" (query-row c "SELECT * FROM jobs WHERE id = ?" j)))
               "no column may still hold the purged text")

  ;; the row is still accountable
  (define after (get-job c j tid))
  (check-equal? (hash-ref after 'status) "done" "status survives")
  (check-equal? (hash-ref after 'kind) "echo")
  (check-equal? (hash-ref after 'created_at) (hash-ref before 'created_at) "timings survive")
  (check-equal? (hash-ref after 'finished_at) (hash-ref before 'finished_at))
  (check-equal? (hash-ref after 'attempt) (hash-ref before 'attempt) "attempt count survives")
  ;; …and says so, which is the whole reason for the column: '{}' alone cannot
  ;; distinguish "purged" from "never had a payload"
  (check-true (exact-integer? (hash-ref after 'purged_at)) "purged_at is reported")

  ;; idempotent, and HONEST about it: the second call did not do it
  (check-equal? (purge-job-content! c j tid) 'already-purged)
  (close-db! c))

(test-case "purge is refused mid-flight, and scoped to the team"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice"))
  (register-job-kind! "echo" (lambda (conn p payload) (hasheq 'ok #t)))
  (define j (enqueue-job! c #:team tid #:user uid #:kind "echo" #:payload (hasheq 'text "x")))

  ;; running and canceling are both refused — a payload being READ must not be
  ;; cleared under the handler, which would fail the job as if it were corrupt
  (query-exec c "UPDATE jobs SET status='running' WHERE id = ?" j)
  (check-equal? (purge-job-content! c j tid) 'not-settled)
  (query-exec c "UPDATE jobs SET status='canceling' WHERE id = ?" j)
  (check-equal? (purge-job-content! c j tid) 'not-settled)
  ;; canceled IS settled — the work stopped, so the input it was given can go
  (query-exec c "UPDATE jobs SET status='canceled' WHERE id = ?" j)
  (check-equal? (purge-job-content! c j tid) #t)

  ;; another team cannot reach it, and the answer is the same as "no such job" —
  ;; a 404, never a 403, so the call cannot be used to probe for job ids
  (check-false (purge-job-content! c j "some-other-team"))
  (check-false (purge-job-content! c "no-such-job" tid))
  (close-db! c))
