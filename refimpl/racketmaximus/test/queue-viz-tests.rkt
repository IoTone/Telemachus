#lang racket/base

;; test/queue-viz-tests.rkt — QVIZ: the figures a picture of the queue is drawn
;; from (#184).
;;   raco test test/queue-viz-tests.rkt
;;   DATABASE_URL="postgres://…" raco test test/queue-viz-tests.rkt
;;
;; The slice's whole claim is that there is NO counter and NO sampling, so what
;; has to hold is about the derivation:
;;
;;   1. the three series come off the three epoch columns, and a completion is
;;      stamped by every one of the ELEVEN terminal writes, not just `finish!`
;;   2. the minute grid is FIXED — an idle minute is a zero, not a missing
;;      bucket, which is the whole difference between a deep queue and a stopped
;;      one
;;   3. a NULL clock is skipped, never bucketed as zero (nothing backfills any of
;;      the three columns)
;;   4. the four queued states PARTITION the queued set, with a precedence
;;      ordered by who can clear each one
;;   5. one job's trail is the audit rows read back, in order, naming the hosts
;;
;; Positive controls, all of which bite: dropping the zero-fill, bucketing a
;; NULL as zero, reversing the breakdown's precedence, and stamping
;; `finished_epoch` in `finish!` alone.

(require rackunit db-kit/portable
         racket/list json
         db-kit/migrate
         "../domain/db/migrations.rkt"
         "db-fixture.rkt"
         "../domain/authz/authz.rkt"
         "../domain/sched/scheduler.rkt"
         "../domain/exec/pull.rkt"
         "../domain/exec/fleet.rkt")

(define (fresh) (define c (fresh-db #:migrate? #f)) (migrate! c all-migrations) c)

(register-job-kind! "infer.chat" #f #:remote? #t
  #:validate (lambda (r) (if (and (hash? r) (string? (hash-ref r 'reply #f))) #f "result.reply must be a string")))
(register-job-kind! "viz.local" (lambda (conn p payload) (hasheq 'ok #t)))

(define (epochs c id)
  (define r (query-row c "SELECT created_epoch, started_epoch, finished_epoch FROM jobs WHERE id = ?" id))
  (for/list ([i (in-range 3)]) (let ([v (vector-ref r i)]) (and (not (sql-null? v)) v))))

(test-case "every terminal write stamps finished_epoch — not just finish!"
  ;; The design estimated two such writes. There are eleven, which is why they
  ;; share one clause; this case walks the four an ordinary instance reaches
  ;; without a reaper or a timeout, because a column stamped in one of them is
  ;; indistinguishable from a working one until the queue is quiet.
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "root"))
  (define p (user-principal c uid tid))
  (define-values (ex _t) (executor-create! c p #:name "gpu-1" #:model "m"))

  ;; (a) the pool's own finish!
  (define a (enqueue-job! c #:team tid #:user uid #:kind "viz.local" #:payload (hasheq)))
  (define cl (claim-job! c a #:lease (+ (current-seconds) 120)))
  (check-true (string? cl) "claimed")
  (check-true (finish! c a "done" #:result "{}" #:token cl))
  (check-true (number? (caddr (epochs c a))) "finish! stamps it")

  ;; (b) a worker completing
  (define b (enqueue-job! c #:team tid #:user uid #:kind "infer.chat" #:payload (hasheq 'messages '())))
  (define wc (worker-claim! c ex #:kinds '("infer.chat") #:models '("m")))
  (check-equal? (worker-complete! c ex b (hasheq 'reply "hi" 'tokens_used 1)
                                  #:token (hash-ref wc 'claim_token)) 'ok)
  (check-true (number? (caddr (epochs c b))) "worker-complete! stamps it")

  ;; (c) a worker failing
  (define d (enqueue-job! c #:team tid #:user uid #:kind "infer.chat" #:payload (hasheq 'messages '())))
  (define wf (worker-claim! c ex #:kinds '("infer.chat") #:models '("m")))
  (check-equal? (worker-fail! c ex d "no model" #:token (hash-ref wf 'claim_token)) 'ok)
  (check-true (number? (caddr (epochs c d))) "worker-fail! stamps it")

  ;; (d) a queued job cancelled
  (define e (enqueue-job! c #:team tid #:user uid #:kind "viz.local" #:payload (hasheq)))
  (check-equal? (cancel-job! c e tid) #t)
  (check-true (number? (caddr (epochs c e))) "cancel-job! stamps it")
  (disconnect c))

(test-case "the three series come off the three clocks, on one shared grid"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "root"))
  (define p (user-principal c uid tid))
  (define a (enqueue-job! c #:team tid #:user uid #:kind "viz.local" #:payload (hasheq)))
  (define cl (claim-job! c a #:lease (+ (current-seconds) 120)))
  (check-true (finish! c a "done" #:result "{}" #:token cl))

  (define f (queue-flow c #:hours 1))
  (check-equal? (hash-ref f 'bucket_seconds) 60 "an hour fits the minute grid exactly")
  (check-equal? (hash-ref f 'buckets) 60)
  (for ([k (in-list '(arrivals claims completions))])
    (check-equal? (length (hash-ref f k)) 60 (format "~a is one entry per minute" k))
    (check-equal? (apply + (hash-ref f k)) 1 (format "~a counted the one job" k)))
  ;; the three share a grid, so an element-by-element read is meaningful
  (define last-of (lambda (k) (last (hash-ref f k))))
  (check-equal? (list (last-of 'arrivals) (last-of 'claims) (last-of 'completions)) '(1 1 1)
                "all three land in the current minute")
  (disconnect c))

(test-case "an idle minute is a ZERO, not a missing bucket"
  ;; QVIZ-7, and the one property a sparkline over "the buckets that had jobs"
  ;; silently destroys: a queue that stopped an hour ago would draw exactly like
  ;; one working steadily. Control: drop the zero-fill and this fails.
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "root"))
  (define a (enqueue-job! c #:team tid #:user uid #:kind "viz.local" #:payload (hasheq)))
  ;; age it to twenty minutes ago, so eighteen clear minutes follow it
  (define t (- (current-seconds) (* 20 60)))
  (query-exec c "UPDATE jobs SET created_epoch = ? WHERE id = ?" t a)
  (define f (queue-flow c #:hours 1))
  (define xs (hash-ref f 'arrivals))
  (check-equal? (length xs) 60 "the grid is the whole window, not the populated part")
  (check-equal? (apply + xs) 1)
  (check-true (> (length (filter zero? xs)) 50) "the empty minutes are present and are zeros")
  ;; and it really is in the right minute: 20 ago, so ~40 buckets in
  (define at (for/first ([x (in-list xs)] [i (in-naturals)] #:unless (zero? x)) i))
  (check-true (and (>= at 37) (<= at 42)) (format "the arrival sits where it happened (bucket ~a)" at))
  (disconnect c))

(test-case "a NULL clock is skipped, never bucketed"
  ;; Nothing backfills any of the three columns, so a pre-migration row has no
  ;; minute and must contribute to none.
  ;;
  ;; THE OBVIOUS CONTROL DOES NOT BITE AND THAT IS WORTH KNOWING: substituting
  ;; `COALESCE(col, 0)` for the `IS NOT NULL` clause changes nothing, because
  ;; epoch 0 is outside every window this read can be asked for (`hours` is
  ;; clamped to 720). What bites is removing the clause altogether, which hands
  ;; `quotient` an SQL NULL — loudly, which is the right failure. The case is
  ;; here for the property, not for a mutation that falsifies it.
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "root"))
  (define a (enqueue-job! c #:team tid #:user uid #:kind "viz.local" #:payload (hasheq)))
  (query-exec c "UPDATE jobs SET created_epoch = NULL WHERE id = ?" a)
  (define f (queue-flow c #:hours 1))
  (check-equal? (apply + (hash-ref f 'arrivals)) 0 "a row with no clock contributes to no minute")
  (disconnect c))

(test-case "a long window WIDENS the bucket rather than shrinking the window"
  ;; 720 hours is 43,200 minutes, which is a sparkline nobody can draw. The
  ;; operator asked for thirty days and gets thirty days, and `bucket_seconds`
  ;; is what stops the unit moving silently (#178).
  (define c (fresh))
  (define f (queue-flow c #:hours 720))
  (check-true (<= (hash-ref f 'buckets) QVIZ-MAX-BUCKETS))
  (check-true (> (hash-ref f 'bucket_seconds) 60) "the bucket widened")
  (check-equal? (- (hash-ref (hash-ref f 'window) 'until) (hash-ref (hash-ref f 'window) 'since))
                (* (hash-ref f 'buckets) (hash-ref f 'bucket_seconds))
                "the grid covers exactly the window it reports")
  (disconnect c))

(test-case "the four queued states partition the queued set, in a precedence"
  ;; Priority 1 of the issue: these look identical in a depth count and have
  ;; different remedies. A job can satisfy more than one, so the precedence is
  ;; ordered by who can clear it — nothing-can-run-it first, because only an
  ;; operator clears that, and a budget last, because it clears itself.
  ;;
  ;; Control: reverse the precedence and the over-budget-AND-unrunnable job is
  ;; reported as a budget problem, which sends an operator to raise a limit that
  ;; changes nothing.
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "root"))
  (define p (user-principal c uid tid))

  ;; nothing live at all: a queued remote job is unclaimable
  (define a (enqueue-job! c #:team tid #:user uid #:kind "infer.chat" #:payload (hasheq 'messages '())))
  (define b0 (queue-breakdown c (executor-list c p)))
  (check-equal? (hash-ref b0 'unclaimable) 1)
  (check-equal? (hash-ref b0 'queued) 0)
  (check-equal? (+ (hash-ref b0 'unclaimable) (hash-ref b0 'held_by_paused)
                   (hash-ref b0 'waiting) (hash-ref b0 'queued))
                (hash-ref b0 'scanned)
                "the four add up to what was scanned — they partition it")

  ;; a live, ready host that matches: the job is simply queued
  (define-values (ex _t) (executor-create! c p #:name "gpu-1" #:model "m"))
  (worker-report-state! c ex "ready")
  (query-exec c "UPDATE executors SET capabilities = ? WHERE id = ?"
              (jsexpr->string (hasheq 'kinds '("infer.chat") 'models '("m"))) (hash-ref ex 'id))
  (define b1 (queue-breakdown c (executor-list c p)))
  (check-equal? (hash-ref b1 'unclaimable) 0)
  (check-equal? (hash-ref b1 'queued) 1 "a matching, ready host means nothing is wrong")

  ;; it pauses: the job is held by a paused host, which is neither of the others
  (worker-report-state! c ex "paused")
  (define b2 (queue-breakdown c (executor-list c p)))
  (check-equal? (hash-ref b2 'held_by_paused) 1)
  (check-equal? (hash-ref b2 'unclaimable) 0 "a host that WILL not is not a host that CANNOT")
  (check-equal? (hash-ref b2 'queued) 0)

  ;; an in-process job whose team is over its concurrency cap is `waiting`
  (worker-report-state! c ex "ready")
  (define _l (enqueue-job! c #:team tid #:user uid #:kind "viz.local" #:payload (hasheq)))
  ;; `set-cap-for!` is process-global, so the restore goes in a dynamic-wind —
  ;; a failing check raises, and a cap of 0 leaking into every later case in the
  ;; file is how `fleet-tests` once failed somewhere unrelated.
  (define b3 (dynamic-wind
               (lambda () (set-cap-for! (lambda (team) 0)))
               (lambda () (queue-breakdown c (executor-list c p)))
               (lambda () (set-cap-for! (lambda (team) 2)))))
  ;; BOTH are waiting, and that is the precedence working rather than a
  ;; surprise: the cap is the team's, so it holds the remote job too — and
  ;; `held_by_paused` and `unclaimable` did not claim it first, because a ready
  ;; host matches it.
  (check-equal? (hash-ref b3 'waiting) 2 "the cap holds the team's queue, and that clears on its own")
  (check-equal? (hash-ref b3 'queued) 0)
  (check-equal? (hash-ref b3 'unclaimable) 0)

  ;; THE PRECEDENCE ONLY MEANS ANYTHING WHERE TWO STATES ARE TRUE AT ONCE, and
  ;; nothing above reaches that: with the cap at 0 a ready host still matched.
  ;; Retire the host and the remote job is BOTH unrunnable and over budget —
  ;; the one state the ordering decides. Reported as a budget problem it sends
  ;; an operator to raise a limit that changes nothing, so `unclaimable` wins.
  ;; Control: reverse the precedence and this fails.
  (executor-retire! c p (hash-ref ex 'id))
  (define b4 (dynamic-wind
               (lambda () (set-cap-for! (lambda (team) 0)))
               (lambda () (queue-breakdown c (executor-list c p)))
               (lambda () (set-cap-for! (lambda (team) 2)))))
  (check-equal? (hash-ref b4 'unclaimable) 1
                "nothing can run it AND the team is over budget: the operator's problem wins")
  (check-equal? (hash-ref b4 'waiting) 1 "the in-process job is the one the budget holds")
  (disconnect c))

(test-case "one job's trail is the hosts that held it, oldest first"
  ;; QVIZ-3: the path exists already, because FLEET-1 writes `job.lease.expired`
  ;; naming the executor BEFORE the requeue clears `executor_id`. What did not
  ;; exist is a way to ask for one job's.
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "root"))
  (define p (user-principal c uid tid))
  (define-values (e1 _t1) (executor-create! c p #:name "flaky" #:model "m"))
  (define-values (e2 _t2) (executor-create! c p #:name "solid" #:model "m"))
  (define j (enqueue-job! c #:team tid #:user uid #:kind "infer.chat" #:payload (hasheq 'messages '())))

  (void (worker-claim! c e1 #:kinds '("infer.chat") #:models '("m")))
  (query-exec c "UPDATE jobs SET lease_until = ? WHERE id = ?" (- (current-seconds) 10) j)
  (void (reap-leases! c))
  (define c2 (worker-claim! c e2 #:kinds '("infer.chat") #:models '("m")))
  (check-equal? (hash-ref c2 'id) j "the second host picked it up")
  (define before (hash-ref (job-trail c j) 'attempt))
  (check-equal? (worker-release! c e2 j #:token (hash-ref c2 'claim_token) #:reason "busy") 'ok)

  (define t (job-trail c j))
  (check-true (hash? t))
  (check-equal? (hash-ref t 'job_id) j)
  (check-equal? (hash-ref t 'kind) "infer.chat")
  ;; issue #61's whole point, visible here: the counter cannot tell this story,
  ;; which is why the path is read from the trail instead.
  (check-equal? (hash-ref t 'attempt) before "a release spends no attempt")
  (check-equal? (hash-ref t 'releases) 1)
  (define evs (hash-ref t 'events))
  (check-equal? (length evs) 2)
  (check-equal? (map (lambda (e) (hash-ref e 'action)) evs)
                '("job.lease.expired" "job.released") "oldest first")
  (check-equal? (map (lambda (e) (hash-ref e 'executor)) evs) '("flaky" "solid")
                "the names, which is the whole point — the row no longer has them")
  (check-equal? (hash-ref (cadr evs) 'reason) "busy")
  ;; QVIZ-4: ids, names, reasons and times, and nothing a team owns
  (for ([k (in-list '(payload result error))])
    (check-false (hash-has-key? t k) (format "the trail carries no ~a" k)))
  (check-false (job-trail c "no-such-job") "a job that does not exist is #f, so the route can 404")
  (disconnect c))
