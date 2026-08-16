#lang racket/base

;; test/scheduler-tests.rkt — the async job scheduler, driven synchronously via
;; process-one! (no thread races).  raco test test/scheduler-tests.rkt

(require rackunit
         db
         db-kit/migrate
         "../domain/db/migrations.rkt"
         "../domain/authz/authz.rkt"
         "../domain/sched/scheduler.rkt")

(define (fresh) (define c (sqlite3-connect #:database 'memory)) (migrate! c all-migrations) c)

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
