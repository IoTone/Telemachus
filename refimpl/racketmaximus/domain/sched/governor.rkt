#lang racket/base

;; domain/sched/governor.rkt — the concurrency governor (workload-queue control
;; plane, single-node). One semaphore per scope key (e.g. "team:<id>") caps how
;; many jobs run at once; excess `with-slot` calls block (queue) until a slot
;; frees — the "no accidental self-DDOS" guarantee. `inflight` is exposed for
;; observability. Semaphores serialize via Racket's evented scheduler; no FFI.

(provide make-governor with-slot governor-inflight)

(struct governor (sems counts lock))

(define (make-governor) (governor (make-hash) (make-hash) (make-semaphore 1)))

(define (sem-for g key limit)
  (call-with-semaphore (governor-lock g)
    (lambda () (hash-ref! (governor-sems g) key (lambda () (make-semaphore limit))))))

(define (count-box g key)
  (call-with-semaphore (governor-lock g)
    (lambda () (hash-ref! (governor-counts g) key (lambda () (box 0))))))

(define (bump! g b delta)
  (call-with-semaphore (governor-lock g)
    (lambda () (set-box! b (+ (unbox b) delta)) (unbox b))))

;; acquire the slot for `key` (blocks/queues up to `limit` concurrent), then run
;; (proc inflight) with the current in-flight count, releasing on the way out.
(define (with-slot g key limit proc)
  (define sem (sem-for g key limit))
  (define cb (count-box g key))
  (semaphore-wait sem)
  (define inflight (bump! g cb 1))
  (dynamic-wind void
                (lambda () (proc inflight))
                (lambda () (bump! g cb -1) (semaphore-post sem))))

(define (governor-inflight g key)
  (define cb (call-with-semaphore (governor-lock g)
               (lambda () (hash-ref (governor-counts g) key (lambda () (box 0))))))
  (unbox cb))
