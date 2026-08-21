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
