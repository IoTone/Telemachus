#lang racket/base

;; test/bench-platform.rkt — the measurements issue #185 asks for.
;;
;; NOT a suite and deliberately not named `*-tests.rkt`: it seeds tens of
;; thousands of rows and takes minutes, which is `calibrate-retrieval.rkt`'s
;; precedent for a harness that measures rather than asserts.
;;
;;   racket test/bench-platform.rkt                       # SQLite, everything
;;   DATABASE_URL="postgres://…" racket test/bench-platform.rkt
;;   racket test/bench-platform.rkt --only claim           # one section
;;   racket test/bench-platform.rkt --scale 2000           # smaller, for a laptop
;;
;; #185's method is "measure first and write the numbers in the issue, change one
;; thing, measure again. No optimization lands without a before and after." So
;; this file's job is the BEFORE, and it must be re-runnable to produce the
;; after — which is why the scale is an argument and the output is a table rather
;; than prose.
;;
;; WHAT IT DELIBERATELY DOES NOT DO: assert. A threshold here would be a
;; performance test that fails on a loaded CI runner and teaches everybody to
;; re-run it, which is worse than no check. The numbers go in the issue, and a
;; regression is caught by somebody re-running this against the recorded ones.

(require db-kit/portable db-kit/migrate
         racket/list racket/string racket/format json
         "../domain/db/migrations.rkt"
         "db-fixture.rkt"
         "../domain/authz/authz.rkt"
         "../domain/db/id.rkt"
         "../domain/sched/scheduler.rkt"
         "../domain/exec/pull.rkt"
         "../domain/exec/fleet.rkt"
         "../domain/apps/search.rkt"
         "../domain/repo/repo.rkt"
         "../config.rkt")

;; ---- the harness ------------------------------------------------------------

(define scale (make-parameter 10000))
(define only (make-parameter #f))

(define (want? name) (or (not (only)) (equal? (only) name)))

;; Milliseconds for one call, and the MEDIAN of n runs rather than the mean: one
;; cold first call (page cache, a plan being built) otherwise dominates a mean
;; over five, and the median is what an operator's next request will look like.
(define (ms-of n thunk)
  (define xs (for/list ([_ (in-range n)])
               (define t0 (current-inexact-milliseconds))
               (void (thunk))
               (- (current-inexact-milliseconds) t0)))
  (define sorted (sort xs <))
  (values (list-ref sorted (quotient n 2))      ; median
          (apply min sorted)
          (apply max sorted)))

(define results '())
(define (record! section what n med lo hi [note ""])
  (set! results (cons (list section what n med lo hi note) results))
  (printf "  ~a~a  n=~a  median ~ams  (min ~a, max ~a)~a\n"
          what (make-string (max 1 (- 44 (string-length what))) #\space)
          n (~r med #:precision 1) (~r lo #:precision 1) (~r hi #:precision 1)
          (if (string=? note "") "" (string-append "  — " note))))

(define (section name) (printf "\n== ~a ==\n" name))

;; Ascending and de-duplicated: a `--scale` smaller than one of the fixed steps
;; would otherwise run them out of order, which makes a curve unreadable and a
;; table look wrong.
(define (steps . xs) (sort (remove-duplicates xs) <))

;; ---- fixtures ---------------------------------------------------------------

(define (fresh)
  (define c (fresh-db #:migrate? #f))
  (migrate! c all-migrations)
  c)

(register-job-kind! "infer.chat" #f #:remote? #t
  #:validate (lambda (r) (if (hash? r) #f "a hash")))
(register-job-kind! "bench.local" (lambda (conn p payload) (hasheq 'ok #t)))

;; Rows are inserted DIRECTLY rather than through `enqueue-job!`, and that is a
;; measurement decision rather than a shortcut: the point is to measure the READ
;; paths at scale, and going through the enqueue seam would spend most of the
;; run on quota records and audit entries the read never touches. Every column
;; the reads actually use is filled.
(define (seed-jobs! c team user n #:kinds [kinds '("infer.chat" "bench.local")]
                    #:status [status "queued"] #:spread [spread 86400])
  (define now (current-seconds))
  (call-with-transaction c
    (lambda ()
      (for ([i (in-range n)])
        (define kind (list-ref kinds (modulo i (length kinds))))
        (define created (- now (modulo (* i 7) spread)))
        (query-exec c
          (string-append "INSERT INTO jobs (id, team_id, user_id, kind, payload, status, priority, "
                         "attempt, created_epoch, started_epoch, finished_epoch, requirements) "
                         "VALUES (?,?,?,?,?,?,?,?,?,?,?,?)")
          (new-id) team user kind "{}" status (modulo i 3) 0
          created
          (if (equal? status "queued") sql-null (+ created 1))
          (if (member status '("done" "error" "canceled")) (+ created 5) sql-null)
          (if (equal? kind "infer.chat") "{\"model\":\"m\"}" "{}"))))))

(define (seed-executors! c p n #:paused [paused 0] #:models [models '("m")])
  (for/list ([i (in-range n)])
    (define-values (ex _t) (executor-create! c p #:name (format "gpu-~a" i) #:model "m"))
    ;; `last_seen_at` IS EPOCH SECONDS, not a timestamp — the column is named
    ;; `_at` and holds a number, which is the opposite of the `created_at`/
    ;; `created_epoch` split everywhere else in this schema. Writing
    ;; CURRENT_TIMESTAMP here makes `row->executor` compute an age by
    ;; subtracting a string.
    (query-exec c "UPDATE executors SET capabilities = ?, last_seen_at = ?, worker_state = ?, state_epoch = ? WHERE id = ?"
                (jsexpr->string (hasheq 'kinds '("infer.chat") 'models models))
                (current-seconds)
                (if (< i paused) "paused" "ready")
                (current-seconds)
                (hash-ref ex 'id))
    (executor-by-id c (hash-ref ex 'id))))

;; ---- 1. the claim path under a fleet (#185's second bullet) ------------------
;;
;; `worker-claim!` holds ONE process-wide semaphore and runs a windowed query per
;; poll, so N workers long-polling is N serialized queries. The #169 runs used
;; three workers and said nothing about thirty.
(define (bench-claim!)
  (section "the claim path under a fleet")
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "root"))
  (define p (user-principal c uid tid))
  (define exs (seed-executors! c p 30))
  (for ([depth (in-list (steps 100 1000 (scale)))])
    (query-exec c "DELETE FROM jobs")
    (seed-jobs! c tid uid depth)
    ;; A claim that TAKES a job is the cheap case; the expensive one is the poll
    ;; that finds nothing, because that is what N idle workers do all day — the
    ;; scan runs and the UPDATE matches nothing.
    (define-values (m lo hi)
      (ms-of 9 (lambda () (worker-claim! c (car exs) #:kinds '("no.such.kind") #:models '("m")))))
    (record! "claim" (format "an EMPTY poll, queue depth ~a" depth) depth m lo hi
             "what 30 idle workers do all day")
    (define-values (m2 lo2 hi2)
      (ms-of 9 (lambda () (worker-claim! c (car exs) #:kinds '("infer.chat") #:models '("m")))))
    (record! "claim" (format "a poll that CLAIMS, queue depth ~a" depth) depth m2 lo2 hi2)
    ;; The serialized cost: thirty workers polling once each, through the one
    ;; semaphore, which is the figure a fleet operator actually experiences.
    (define-values (m3 lo3 hi3)
      (ms-of 3 (lambda ()
                 (for ([e (in-list exs)])
                   (worker-claim! c e #:kinds '("no.such.kind") #:models '("m"))))))
    (record! "claim" (format "30 idle workers, one round, depth ~a" depth) depth m3 lo3 hi3
             "the semaphore serializes these"))

  ;; THE CASE THE DEPTH CURVE WAS HIDING, and it is not about depth at all.
  ;;
  ;; The window is `LIMIT 64`, so the SQL is bounded — but the `for/or` after it
  ;; asks `team-hold` (a COUNT(*) over the team's jobs, plus the quota check) and
  ;; `executor-can-run?` ONCE PER CANDIDATE. While the team is under its cap the
  ;; first candidate wins and the loop stops; once the team is AT its cap every
  ;; candidate is rejected, so a poll walks all 64 and runs 64 counts to return
  ;; nothing. The default cap is 2, so that is the ORDINARY case for a busy team,
  ;; and with 30 workers it is 1,920 counts a round.
  ;;
  ;; Measured both ways at one depth, because the difference between them IS the
  ;; finding and a single number hides it.
  (query-exec c "DELETE FROM jobs")
  (seed-jobs! c tid uid (scale))
  (define (poll-round!) (for ([e (in-list exs)]) (worker-claim! c e #:kinds '("infer.chat") #:models '("m"))))
  ;; (a) nothing is held: the cap is high, so candidate 1 is claimable
  (dynamic-wind
    (lambda () (set-cap-for! (lambda (team) 1000000)))
    (lambda ()
      (define-values (m lo hi) (ms-of 5 (lambda () (worker-claim! c (car exs) #:kinds '("infer.chat") #:models '("m")))))
      (record! "claim" "one poll, team UNDER its cap" (scale) m lo hi
               "candidate 1 is claimable, the loop stops")
      (define-values (m2 lo2 hi2) (ms-of 3 poll-round!))
      (record! "claim" "30 workers, team UNDER its cap" (scale) m2 lo2 hi2))
    (lambda () (set-cap-for! (lambda (team) 2))))
  ;; (b) the team is AT its cap, which is the default of 2 and the normal state
  ;; of a busy team. Nothing is claimable, so every candidate is rejected.
  (dynamic-wind
    (lambda () (set-cap-for! (lambda (team) 0)))
    (lambda ()
      (define-values (m lo hi) (ms-of 5 (lambda () (worker-claim! c (car exs) #:kinds '("infer.chat") #:models '("m")))))
      (record! "claim" "one poll, team AT its cap" (scale) m lo hi
               "all 64 candidates rejected, one COUNT(*) each")
      (define-values (m2 lo2 hi2) (ms-of 3 poll-round!))
      (record! "claim" "30 workers, team AT its cap" (scale) m2 lo2 hi2
               "this is what a busy fleet does"))
    (lambda () (set-cap-for! (lambda (team) 2))))
  (disconnect c))

;; ---- 2. the queue and fleet reads (#185's third bullet) ----------------------
;;
;; Both scan with a bound and both apply `can?` per row AFTER the SQL window,
;; which is the pattern CLS-27 found can page through a lot to return little.
(define (bench-reads!)
  (section "the queue and fleet reads")
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "root"))
  (define p (user-principal c uid tid))
  (define exs (seed-executors! c p 10 #:paused 3))
  (for ([depth (in-list (steps 100 1000 (scale)))])
    (query-exec c "DELETE FROM jobs")
    (seed-jobs! c tid uid depth)
    (define-values (m lo hi) (ms-of 5 (lambda () (fleet-report c p))))
    (record! "reads" (format "fleet-report, queue depth ~a" depth) depth m lo hi
             "scans at most 200 queued remote rows")
    (define-values (m2 lo2 hi2) (ms-of 5 (lambda () (queue-listing c p #:limit 25))))
    (record! "reads" (format "queue-listing 25 of ~a" depth) depth m2 lo2 hi2)
    (define-values (m2b lo2b hi2b) (ms-of 5 (lambda () (queue-listing c p #:limit 200))))
    (record! "reads" (format "queue-listing 200 of ~a" depth) depth m2b lo2b hi2b)
    ;; The page nobody looks at: paging deep is where an OFFSET scan shows up,
    ;; and the queue read offers `offset` without bounding it.
    (define-values (m3 lo3 hi3)
      (ms-of 5 (lambda () (queue-listing c p #:limit 25 #:offset (max 0 (- depth 25))))))
    (record! "reads" (format "queue-listing LAST page of ~a" depth) depth m3 lo3 hi3
             "the OFFSET scan")
    (define-values (m4 lo4 hi4) (ms-of 5 (lambda () (queue-flow c #:hours 24))))
    (record! "reads" (format "queue-flow 24h over ~a jobs" depth) depth m4 lo4 hi4
             "three GROUP-BY-less scans, bucketed in Racket")
    (define-values (m5 lo5 hi5) (ms-of 5 (lambda () (queue-breakdown c (executor-list c p)))))
    (record! "reads" (format "queue-breakdown over ~a" depth) depth m5 lo5 hi5
             "one scan, capped at 500"))
  (disconnect c))

;; ---- 3. search (#185's fourth bullet) ---------------------------------------
;;
;; A `LIKE` over `repo_text.content` with a per-row authorization filter, and no
;; content search at all when `TMACH_ENCRYPT_CONTENT` is on. "Worth knowing where
;; it stops being usable" is the issue's own phrasing, so the shape to find is
;; where the curve bends rather than one number.
(define WORDS '("invoice" "contract" "tender" "survey" "bridge" "concrete" "inspection"
                "cephalopod" "octopus" "harbour" "cable" "foundation" "deflection" "weld"))

(define (bench-search!)
  (section "search")
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "root"))
  (define p (user-principal c uid tid))
  ;; `repo_text` rows are inserted directly for the same reason the jobs are:
  ;; `repo-put!` would spend the run on blobs and quota records, and search
  ;; reads `repo_objects` joined to `repo_text` and nothing else.
  ;; `org_id` is NOT NULL on `repo_objects` and is the DEDUP AND ISOLATION
  ;; namespace (DOC-6), so it is read off the team rather than invented — a
  ;; fixture that made one up would scan rows the org gate would never return.
  (define org (let ([v (query-maybe-value c "SELECT org_id FROM teams WHERE id = ?" tid)])
                (if (or (not v) (sql-null? v)) "system" v)))
  (define (seed-docs! n)
    (call-with-transaction c
      (lambda ()
        (for ([i (in-range n)])
          (define oid (new-id))
          (define vid (new-id))
          (query-exec c
            (string-append "INSERT INTO repo_objects (id, org_id, team_id, owner_user_id, key, visibility, "
                           "current_version_id) VALUES (?,?,?,?,?,?,?)")
            oid org tid uid (format "bench/doc-~a.txt" i)
            ;; a tenth are PRIVATE, which is what makes the per-row `can?`
            ;; filter do work rather than wave everything through
            (if (zero? (modulo i 10)) "private" "team") vid)
          (query-exec c
            (string-append "INSERT INTO repo_versions (id, object_id, seq, digest, size, "
                           "content_type, filename, created_by) VALUES (?,?,?,?,?,?,?,?)")
            vid oid 1 (make-string 64 #\a) 1000 "text/plain" (format "doc-~a.txt" i) uid)
          (query-exec c
            "INSERT INTO repo_text (object_id, version_id, content) VALUES (?,?,?)"
            oid vid
            ;; ~1 KB of plausible prose. Every document contains every common
            ;; word, so "a common word" really does match all of them — which
            ;; is the shape that makes the per-row `can?` filter the cost.
            (string-join (for/list ([k (in-range 140)])
                           (list-ref WORDS (modulo (+ i k) (length WORDS)))) " ")))))) 
  (for ([n (in-list (steps 100 1000 (min 20000 (scale))))])
    (query-exec c "DELETE FROM repo_text") (query-exec c "DELETE FROM repo_versions")
    (query-exec c "DELETE FROM repo_objects")
    (seed-docs! n)
    (define-values (m lo hi) (ms-of 5 (lambda () (search-all c p "invoice" #:limit 20))))
    (record! "search" (format "a COMMON word over ~a docs" n) n m lo hi
             "LIKE '%…%' — no index can serve it")
    (define-values (m2 lo2 hi2) (ms-of 5 (lambda () (search-all c p "zzzznotpresent" #:limit 20))))
    (record! "search" (format "a word in NO document, ~a docs" n) n m2 lo2 hi2
             "the full scan with nothing to return")
    (define-values (m3 lo3 hi3) (ms-of 5 (lambda () (search-all c p "doc-7" #:limit 20))))
    (record! "search" (format "by KEY over ~a docs" n) n m3 lo3 hi3))
  (disconnect c))

;; ---- 4. graph reads, because #191 is about to lean on them ------------------
(define (bench-kg!)
  (section "the knowledge graph read")
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "root"))
  (define p (user-principal c uid tid))
  (printf "  (skipped: seeding a graph wants the extractor; see the issue)\n")
  (disconnect c))

;; ---- the report -------------------------------------------------------------

(define (report!)
  (printf "\n\n== the table, for the issue ==\n\n")
  (printf "| section | what | scale | median ms | min | max | note |\n")
  (printf "|---|---|---|---|---|---|---|\n")
  (for ([r (in-list (reverse results))])
    (printf "| ~a | ~a | ~a | **~a** | ~a | ~a | ~a |\n"
            (list-ref r 0) (list-ref r 1) (list-ref r 2)
            (~r (list-ref r 3) #:precision 1) (~r (list-ref r 4) #:precision 1)
            (~r (list-ref r 5) #:precision 1) (list-ref r 6))))

(module+ main
  (define args (vector->list (current-command-line-arguments)))
  (let loop ([a args])
    (cond [(null? a) (void)]
          [(and (equal? (car a) "--scale") (pair? (cdr a)))
           (scale (or (string->number (cadr a)) 10000)) (loop (cddr a))]
          [(and (equal? (car a) "--only") (pair? (cdr a)))
           (only (cadr a)) (loop (cddr a))]
          [else (loop (cdr a))]))
  (printf "bench-platform — dialect ~a, scale ~a\n"
          (let ([u (getenv "DATABASE_URL")]) (if (and u (regexp-match? #rx"postgres" u)) "postgresql" "sqlite"))
          (scale))
  (when (want? "claim")  (bench-claim!))
  (when (want? "reads")  (bench-reads!))
  (when (want? "search") (bench-search!))
  (report!))
