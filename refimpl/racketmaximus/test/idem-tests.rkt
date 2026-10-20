#lang racket/base

;; test/idem-tests.rkt — idempotency keys (issue #90), the model half.
;;
;;   raco test test/idem-tests.rkt
;;   DATABASE_URL="postgres://…" raco test test/idem-tests.rkt
;;
;; The HTTP contract (replay returns the original status, a changed payload is a
;; 409) is pinned in test/server-smoke.sh, because the thing being promised is a
;; RESPONSE and the response only exists over HTTP. What is here is the part a
;; wire test cannot see: the fingerprint's canonicalization, the window's edge,
;; the concurrent-retry race, and the reaper.

(require rackunit db-kit/portable json racket/list
         db-kit/migrate
         "../domain/db/migrations.rkt"
         "db-fixture.rkt"
         "../domain/idem/idem.rkt")

(define (fresh)
  (define c (fresh-db #:migrate? #f))
  (migrate! c all-migrations)
  c)

(define EP "POST /api/jobs")

;; ---- 1. the three answers --------------------------------------------------------
(test-case "miss, then hit, then conflict — three answers, not a boolean"
  (define c (fresh))
  (define fp (idem-fingerprint EP (hasheq 'kind "echo")))
  (check-false (idem-lookup c "t1" "k1" EP fp) "an unused key is a MISS")

  (idem-store! c "t1" "k1" EP fp (hasheq 'id "job-1" 'status "queued") 202)
  (define hit (idem-lookup c "t1" "k1" EP fp))
  (check-true (hash? hit))
  ;; the ORIGINAL answer AND its ORIGINAL code: the client never saw the first
  (check-equal? (hash-ref (hash-ref hit 'hit) 'id) "job-1")
  (check-equal? (hash-ref hit 'code) 202 "202, not 200 — the code is part of the answer")

  ;; the same key for a DIFFERENT request
  (define fp2 (idem-fingerprint EP (hasheq 'kind "something-else")))
  (check-eq? (idem-lookup c "t1" "k1" EP fp2) 'conflict)
  (close-db! c))

(test-case "a key belongs to its TEAM"
  (define c (fresh))
  (define fp (idem-fingerprint EP (hasheq 'kind "echo")))
  (idem-store! c "t1" "shared-key" EP fp (hasheq 'id "a") 202)
  ;; another team using the same string is not retrying anything
  (check-false (idem-lookup c "t2" "shared-key" EP fp))
  (close-db! c))

;; ---- 2. the fingerprint canonicalizes -------------------------------------------
;; The trap this avoids is the one that makes `json-out` sort and AUD-13 hash a
;; list: `hasheq` iteration order is not stable, so a fingerprint taken over
;; `jsexpr->string` of a hash would differ between two processes — and a
;; load-balanced instance would then 409 a client's honest retry.
(test-case "two requests that differ only in JSON key ORDER are the same request"
  (define a (hasheq 'kind "echo" 'payload (hasheq 'x 1 'y 2) 'priority 0))
  (define b (hasheq 'priority 0 'payload (hasheq 'y 2 'x 1) 'kind "echo"))
  (check-equal? (idem-fingerprint EP a) (idem-fingerprint EP b)))

(test-case "…but a different VALUE, a different list order, or a different endpoint is not"
  (define a (hasheq 'kind "echo" 'payload (hasheq 'x 1)))
  (check-not-equal? (idem-fingerprint EP a) (idem-fingerprint EP (hasheq 'kind "echo" 'payload (hasheq 'x 2))))
  ;; a LIST's order is meaningful — it is the caller's sequence, not a hash's
  (check-not-equal? (idem-fingerprint EP (hasheq 'xs '(1 2)))
                    (idem-fingerprint EP (hasheq 'xs '(2 1))))
  (check-not-equal? (idem-fingerprint EP a) (idem-fingerprint "POST /api/other" a))
  ;; and the endpoint is IN the fingerprint, so one key on two endpoints conflicts
  ;; rather than silently replaying the wrong answer
  (check-not-equal? (idem-fingerprint EP (hasheq)) (idem-fingerprint "POST /api/x" (hasheq))))

(test-case "null, booleans and nested structures survive the canonicalization"
  (define x (hasheq 'a 'null 'b #t 'c (list (hasheq 'd "s") 3)))
  (check-equal? (idem-fingerprint EP x) (idem-fingerprint EP x))
  (check-not-equal? (idem-fingerprint EP x) (idem-fingerprint EP (hasheq 'a 'null 'b #f 'c (list (hasheq 'd "s") 3)))))

;; ---- 3. the window ---------------------------------------------------------------
(test-case "a key past the window is a MISS, not a conflict"
  (define c (fresh))
  (define fp (idem-fingerprint EP (hasheq 'kind "echo")))
  (idem-store! c "t1" "old" EP fp (hasheq 'id "a") 202)
  ;; age it past 24h by UPDATE, never by sleeping (the platform's rule for leases)
  (query-exec c "UPDATE idempotency_keys SET created_epoch = ? WHERE key = 'old'"
              (- (current-seconds) (+ IDEM-WINDOW-SECONDS 60)))
  ;; After a day the client is not retrying, it is making a NEW request — and
  ;; refusing it would be worse than performing it. A conflict here would make a
  ;; key permanently poisonous.
  (check-false (idem-lookup c "t1" "old" EP fp))
  ;; …and even a DIFFERENT payload on that key is a miss, for the same reason
  (check-false (idem-lookup c "t1" "old" EP (idem-fingerprint EP (hasheq 'kind "other"))))
  (close-db! c))

;; ---- 4. the concurrent retry -----------------------------------------------------
(test-case "two concurrent retries both store, and the loser does not fail"
  (define c (fresh))
  (define fp (idem-fingerprint EP (hasheq 'kind "echo")))
  ;; both got past the lookup before either stored — the race that is REAL, since
  ;; a retrying client often sends twice in the same second
  (idem-store! c "t1" "k" EP fp (hasheq 'id "first") 202)
  (idem-store! c "t1" "k" EP fp (hasheq 'id "second") 202)
  ;; ON CONFLICT DO NOTHING: the FIRST answer stands, and the second call does
  ;; not raise — it has already performed work it must be able to answer for.
  (check-equal? (hash-ref (hash-ref (idem-lookup c "t1" "k" EP fp) 'hit) 'id) "first")
  (check-equal? (query-value c "SELECT COUNT(*) FROM idempotency_keys WHERE key = 'k'") 1)
  (close-db! c))

;; ---- 5. the reaper (r4) ----------------------------------------------------------
(test-case "keys past the window are reaped, and live ones are left alone"
  (define c (fresh))
  (define fp (idem-fingerprint EP (hasheq 'kind "echo")))
  (idem-store! c "t1" "live" EP fp (hasheq 'id "a") 202)
  (idem-store! c "t1" "dead" EP fp (hasheq 'id "b") 202)
  (query-exec c "UPDATE idempotency_keys SET created_epoch = ? WHERE key = 'dead'"
              (- (current-seconds) (+ IDEM-WINDOW-SECONDS 60)))
  (check-equal? (idem-reap! c) 1)
  (check-equal? (query-list c "SELECT key FROM idempotency_keys") '("live"))
  ;; the stored response may name a document, so a key that can never be
  ;; replayed again is a copy with no purpose rather than retained data
  (check-equal? (idem-reap! c) 0 "idempotent, so it is safe on a timer")
  (close-db! c))
