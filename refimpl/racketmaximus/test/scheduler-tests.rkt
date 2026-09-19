#lang racket/base

;; test/scheduler-tests.rkt — the async job scheduler, driven synchronously via
;; process-one! (no thread races).  raco test test/scheduler-tests.rkt

(require rackunit db-kit/portable
         db-kit/migrate
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

(test-case "quota hooks: admit? defers an over-budget team, record! bills the run"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice"))
  (register-job-kind! "meter" (lambda (conn p pl) (hasheq 'tokens_used 7)))
  (define j (enqueue-job! c #:team tid #:user uid #:kind "meter"))
  ;; admit? #f → the job stays queued (deferred), not run
  (set-admit?! (lambda (conn team) #f))
  (check-false (process-one! c))
  (check-equal? (hash-ref (get-job c j tid) 'status) "queued")
  ;; admit? #t + record! captures the billed tokens
  (define billed (box 0))
  (set-admit?! (lambda (conn team) #t))
  (set-record!! (lambda (conn team result) (set-box! billed (+ (unbox billed) (hash-ref result 'tokens_used 0)))))
  (check-equal? (process-one! c) j)
  (check-equal? (hash-ref (get-job c j tid) 'status) "done")
  (check-equal? (unbox billed) 7)
  (set-admit?! (lambda (conn team) #t)) (set-record!! (lambda (conn team result) (void))))   ; restore defaults

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
