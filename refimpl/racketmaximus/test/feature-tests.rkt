#lang racket/base

;; test/feature-tests.rkt — per-team feature activation.  raco test test/feature-tests.rkt

(require rackunit
         db
         db-kit/migrate
         "../domain/db/migrations.rkt"
         "../domain/features/features.rkt")

(define (fresh) (define c (sqlite3-connect #:database 'memory)) (migrate! c all-migrations) c)

(test-case "features default on; toggle off/on; per-team; features-for lists all"
  (define c (fresh))
  (check-true (feature-enabled? c "t1" "chat"))            ; no row → enabled
  (set-feature-enabled! c "t1" "chat" #f)
  (check-false (feature-enabled? c "t1" "chat"))
  (check-true (feature-enabled? c "t2" "chat"))            ; other team unaffected
  (set-feature-enabled! c "t1" "chat" #t)                  ; upsert back on
  (check-true (feature-enabled? c "t1" "chat"))
  (define fs (features-for c "t1"))
  (check-equal? (length fs) (length known-features))
  (check-true (for/or ([f (in-list fs)]) (equal? (hash-ref f 'feature) "search"))))
