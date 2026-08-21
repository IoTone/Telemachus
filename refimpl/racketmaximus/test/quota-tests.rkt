#lang racket/base

;; test/quota-tests.rkt — slice 6: quotas + concurrency governor.
;;   raco test test/quota-tests.rkt   (with pkgs on PLTCOLLECTS)

(require rackunit db-kit/portable
         db-kit/migrate
         "../domain/db/migrations.rkt"
         "db-fixture.rkt"
         "../domain/quota/quota.rkt"
         "../domain/sched/governor.rkt")

(define (fresh) (define c (fresh-db #:migrate? #f)) (migrate! c all-migrations) c)

(test-case "quota: set/check/record + unset = unlimited"
  (define c (fresh))
  (set-limit! c "team" "t1" "ai.tokens.total" 100 #:window "day")
  (define d0 (quota-check c "team" "t1" "ai.tokens.total" 30))
  (check-true (hash-ref d0 'allowed))
  (check-equal? (hash-ref d0 'remaining) 100)
  (quota-record! c "team" "t1" "ai.tokens.total" 80)
  (define d1 (quota-check c "team" "t1" "ai.tokens.total" 30))
  (check-false (hash-ref d1 'allowed))                 ; 80 + 30 > 100
  (check-equal? (hash-ref d1 'used) 80)
  (check-equal? (hash-ref d1 'remaining) 20)
  (check-true (hash-ref (quota-check c "team" "t1" "ai.requests" 999) 'allowed))  ; no limit → allowed
  ;; upsert: change the limit
  (set-limit! c "team" "t1" "ai.tokens.total" 200 #:window "day")
  (check-true (hash-ref (quota-check c "team" "t1" "ai.tokens.total" 30) 'allowed)))

(test-case "quota: default-policy! seeds the three AI dimensions"
  (define c (fresh))
  (default-policy! c "teamX" #:tokens-per-day 500 #:concurrency 3)
  (define-values (tok _w1) (get-limit c "team" "teamX" "ai.tokens.total"))
  (define-values (conc _w2) (get-limit c "team" "teamX" "ai.concurrency"))
  (check-equal? tok 500)
  (check-equal? conc 3))

(test-case "governor: concurrency cap is never exceeded under load"
  (define g (make-governor))
  (define max-seen (box 0))
  (define lock (make-semaphore 1))
  (define (job)
    (with-slot g "team:x" 2
      (lambda (inflight)
        (call-with-semaphore lock (lambda () (when (> inflight (unbox max-seen)) (set-box! max-seen inflight))))
        (sleep 0.05))))
  (for-each thread-wait (for/list ([i (in-range 8)]) (thread job)))
  (check-true (<= (unbox max-seen) 2))                 ; never more than the cap ran together
  (check-equal? (governor-inflight g "team:x") 0))     ; all released
