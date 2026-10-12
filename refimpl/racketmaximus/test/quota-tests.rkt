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

;; issue #54: `limit_value INTEGER` is 64-bit on SQLite and 32-bit on PostgreSQL,
;; so this worked in development and threw a raw SQL error in production. Not a
;; hypothetical ceiling — `storage.bytes` is a byte count, so any storage quota
;; above 2 GiB crosses it. Migration 0035 widens the column on PostgreSQL.
(test-case "a quota above the 32-bit ceiling round-trips on either dialect"
  (define c (fresh))
  (define big (+ (expt 2 31) 1000))          ; 2,147,484,648 — a 2 GiB storage cap and change
  (set-limit! c "team" "t-big" "storage.bytes" big #:window "total")
  (define-values (lim win) (get-limit c "team" "t-big" "storage.bytes"))
  (check-equal? lim big "the limit survives the round trip, not just the insert")
  (check-true (hash-ref (quota-check c "team" "t-big" "storage.bytes" 1000) 'allowed))
  (disconnect c))
