#lang racket/base

;; domain/review/review.rkt — human review as a first-class record (LAY-1…3).
;;
;; A workflow step can park a run until a person decides. This module owns the
;; record of that decision: the verdict, the rationale, who made it and when. It
;; knows nothing about workflows — `domain/flow/run.rkt` opens a review when it
;; parks a run and installs `set-resume-hook!` to advance it again, the same seam
;; shape `repo-put!` uses for triggers.
;;
;; Why a table rather than the audit log: the audit log is an append-only ordering
;; of events, and a queue is a work surface. "What is waiting for me?" and "why was
;; this rejected in March?" are ordinary questions that an event log answers badly.
;; The audit log still records THAT a decision happened, as it does for every
;; other action.
;;
;; Four eyes (LAY-3): the Localization Manager already refuses to let a translator
;; approve their own string, and treats a machine draft — which has no human
;; author — as approvable by anyone holding the permission. That is exactly the
;; rule the RFE asks for under "mandatory dual-review", and it was locked inside
;; one subsystem. Here `author_user_id` carries it: NULL means the subject was
;; produced by a model and anyone with `reviews:decide` may decide it; a non-NULL
;; author may never decide their own.

(require db-kit/portable
         racket/string
         racket/list
         json
         "../db/id.rkt"
         (only-in sha2-kit sha256-hex)
         "../authz/authz.rkt"                        ; principal-*, audit!
         (only-in "../flow/spec.rkt" REVIEW-VERDICTS))  ; one frozen vocabulary

(provide review-open! review-list review-get review-decide! review-cancel-run!
         set-resume-hook! review-count-pending answers-problem
         review-verify review-stats)

(define (now-ms) (inexact->exact (floor (current-inexact-milliseconds))))
(define (nz v) (if (sql-null? v) #f v))
(define (js s) (with-handlers ([exn:fail? (lambda (_) (hasheq))])
                 (let ([j (string->jsexpr (if (sql-null? s) "{}" s))]) (if (or (hash? j) (list? j)) j (hasheq)))))

;; A run is resumed by whoever installed the hook; this module never requires the
;; flow engine, so the dependency runs one way only.
(define resume-hook (box (lambda (conn review) (void))))
(define (set-resume-hook! f) (set-box! resume-hook f))

(define RSELECT
  (string-append
   "SELECT id, team_id, run_id, step_row_id, step_id, title, instructions, subject, checklist, "
   "       four_eyes, author_user_id, status, verdict, rationale, answers, requested_by, decided_by, "
   "       requested_ms, decided_ms, hash, prev_hash "
   "FROM reviews"))

(define (row->review r)
  (hasheq 'id (vector-ref r 0) 'team_id (vector-ref r 1)
          'run_id (or (nz (vector-ref r 2)) 'null)
          'step_row_id (or (nz (vector-ref r 3)) 'null)
          'step_id (or (nz (vector-ref r 4)) 'null)
          'title (vector-ref r 5)
          'instructions (or (nz (vector-ref r 6)) "")
          'subject (js (vector-ref r 7))
          'checklist (js (vector-ref r 8))
          'four_eyes (not (zero? (vector-ref r 9)))
          'author_user_id (or (nz (vector-ref r 10)) 'null)
          'status (vector-ref r 11)
          'verdict (or (nz (vector-ref r 12)) 'null)
          'rationale (or (nz (vector-ref r 13)) "")
          'answers (js (vector-ref r 14))
          'requested_by (or (nz (vector-ref r 15)) 'null)
          'decided_by (or (nz (vector-ref r 16)) 'null)
          'requested_ms (vector-ref r 17)
          'decided_ms (or (nz (vector-ref r 18)) 'null)
          'hash (or (nz (vector-ref r 19)) 'null)
          'prev_hash (or (nz (vector-ref r 20)) 'null)))

;; ---- validation --------------------------------------------------------------
;; Unknown keys are refused rather than dropped, the same call the workflow spec
;; makes: an answer that goes nowhere is how a reviewer concludes the form is broken.
(define (answers-problem checklist answers)
  (define keys (for/list ([i (in-list checklist)] #:when (hash? i)) (hash-ref i 'key "")))
  (cond
    [(not (hash? answers)) "answers must be an object"]
    [else
     (or
      (for/or ([(k v) (in-hash answers)])
        (cond [(not (member (symbol->string k) keys)) (format "answers: '~a' is not in this checklist" k)]
              [(not (string? v)) (format "answers.~a must be a string" k)]
              [else #f]))
      (for/or ([i (in-list checklist)])
        (and (hash? i)
             (hash-ref i 'required #f)
             (let ([a (hash-ref answers (string->symbol (hash-ref i 'key "")) "")])
               (and (or (not (string? a)) (string=? (string-trim a) ""))
                    (format "answers: '~a' is required" (hash-ref i 'label (hash-ref i 'key ""))))))))]))

;; ---- opening -----------------------------------------------------------------
;; Called by the flow engine when it parks a run. `author` is the human whose work
;; is under review, or #f when a model produced it.
(define (review-open! conn #:team team #:title title #:subject subject
                      #:run [run-id #f] #:step-row [step-row #f] #:step [step-id #f]
                      #:instructions [instructions ""] #:checklist [checklist '()]
                      #:four-eyes [four-eyes #f] #:author [author #f] #:requested-by [requested-by #f])
  (define id (new-id))
  (query-exec conn
    (string-append "INSERT INTO reviews (id, team_id, run_id, step_row_id, step_id, title, instructions, "
                   "subject, checklist, four_eyes, author_user_id, status, requested_by, requested_ms) "
                   "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'pending', ?, ?)")
    id team (or run-id sql-null) (or step-row sql-null) (or step-id sql-null)
    title (or instructions "") (jsexpr->string subject) (jsexpr->string checklist)
    (if four-eyes 1 0) (or author sql-null) (or requested-by sql-null) (now-ms))
  (row->review (query-row conn (string-append RSELECT " WHERE id = ?") id)))

;; ---- reading -----------------------------------------------------------------
(define (review-list conn p #:status [status "pending"] #:limit [limit 50] #:offset [offset 0])
  (define team (principal-team-id p))
  (define rows
    (if (and status (not (string=? status "")) (not (string=? status "all")))
        (query-rows conn (string-append RSELECT " WHERE team_id = ? AND status = ? "
                                        "ORDER BY requested_ms DESC, id DESC LIMIT ? OFFSET ?")
                    team status limit offset)
        (query-rows conn (string-append RSELECT " WHERE team_id = ? "
                                        "ORDER BY requested_ms DESC, id DESC LIMIT ? OFFSET ?")
                    team limit offset)))
  (map row->review rows))

(define (review-get conn p id)
  (define r (query-maybe-row conn (string-append RSELECT " WHERE id = ?") id))
  (and r
       (let ([rev (row->review r)])
         (and (equal? (hash-ref rev 'team_id) (principal-team-id p)) rev))))

(define (review-count-pending conn p)
  (query-value conn "SELECT COUNT(*) FROM reviews WHERE team_id = ? AND status = 'pending'"
               (principal-team-id p)))

;; ---- the decision chain (LAY-11) ----------------------------------------------
;; WHAT THIS DETECTS, AND WHAT IT DOES NOT. Each decision hashes its own fields
;; together with the previous decision's hash, so a row altered in place, or
;; removed from the middle, breaks every link after it and `review-verify` names
;; the first break.
;;
;; It does NOT detect a rewrite by anyone who can write this table: they can
;; recompute every link after the row they changed, and the chain will verify.
;; That is the party an administrative audit is most meant to defend against, so
;; the claim is deliberately narrow — the same shape as secrets at rest, which
;; defends a DUMP and not a HOST, and which is written down that way because the
;; old note in creds.rkt had overclaimed in exactly this direction.
;;
;; What would close that gap is an EXTERNAL anchor: periodically publishing the
;; head hash somewhere the database's owner does not control. That is a
;; deployment decision rather than a schema one, and it is not built.
;; The canonical form is an ordered LIST, never a hash: `hasheq` iteration order
;; is not stable across processes, so hashing a hash would make the chain disagree
;; with itself on a different machine. The docs generator learned this the same
;; way, which is why `json-out` sorts.
;;
;; The chain is per TEAM because a team is the isolation boundary — one team's
;; history should not be able to invalidate another's, and a verification answer
;; is about a team's own records.
(define (chain-hash rev prev)
  (sha256-hex
   (string->bytes/utf-8
    (jsexpr->string
     (list "telemachus.review.v1"
           (hash-ref rev 'id)
           (hash-ref rev 'team_id)
           (let ([v (hash-ref rev 'run_id)]) (if (string? v) v ""))
           (let ([v (hash-ref rev 'step_id)]) (if (string? v) v ""))
           (hash-ref rev 'title "")
           (jsexpr->string (hash-ref rev 'subject (hasheq)))
           (let ([v (hash-ref rev 'verdict)]) (if (string? v) v ""))
           (hash-ref rev 'rationale "")
           (jsexpr->string (hash-ref rev 'answers (hasheq)))
           (let ([v (hash-ref rev 'decided_by)]) (if (string? v) v ""))
           (let ([v (hash-ref rev 'decided_ms)]) (if (number? v) v 0))
           (or prev ""))))))

(define (last-chain-hash conn team)
  (define v (query-maybe-value conn
    (string-append "SELECT hash FROM reviews WHERE team_id = ? AND status = 'decided' AND hash IS NOT NULL "
                   "ORDER BY decided_ms DESC, id DESC LIMIT 1")
    team))
  (and v (not (sql-null? v)) v))

;; Walk a team's chain in decision order and recompute it. -> (hasheq ok, checked,
;; broken_at) where broken_at names the FIRST decision whose stored hash does not
;; match what its contents and its predecessor imply.
(define (review-verify conn p)
  (define team (principal-team-id p))
  (define rows (query-rows conn
    (string-append RSELECT " WHERE team_id = ? AND status = 'decided' AND hash IS NOT NULL "
                   "ORDER BY decided_ms ASC, id ASC") team))
  (let loop ([rs rows] [prev #f] [n 0])
    (cond
      [(null? rs) (hasheq 'ok #t 'checked n 'broken_at 'null)]
      [else
       (define rev (row->review (car rs)))
       (define stored (let ([v (vector-ref (car rs) 19)]) (and (not (sql-null? v)) v)))
       (define want (chain-hash rev prev))
       (if (equal? stored want)
           (loop (cdr rs) stored (add1 n))
           (hasheq 'ok #f 'checked n 'broken_at (hash-ref rev 'id)))])))

;; ---- the accuracy signal (LAY-10) ---------------------------------------------
;; Their "framework to determine the reliability of AI-generated outputs" sounds
;; like an evaluation platform and is a QUERY: every reviewed output already
;; carries a verdict, so accuracy per workflow and per step is a group-by over
;; decisions the team made anyway.
;;
;; NOT per model, and the reason matters for the follow-up. `jobs.executor_id`
;; IS recorded — `claim-job!` writes it — but only when a WORKER claims the job;
;; the pool's in-process jobs on the local model leave it NULL. So a per-model
;; breakdown would cover the pull-executed subset while looking complete, which is
;; worse than not offering one. The fix is not "start recording executors": it is
;; to keep the model `model-exchange` already RESOLVES and returns as its third
;; value, which both call sites currently discard. That is a small hole in a known
;; place, and it is the follow-up that would earn this column.
(define (review-stats conn p #:since [since #f])
  (define team (principal-team-id p))
  ;; `decided_ms` is BIGINT, and PostgreSQL refuses an inexact real for one while
  ;; SQLite takes it — so a caller passing ?since=1.5, or any arithmetic on
  ;; current-inexact-milliseconds, worked in development and threw a raw SQL error
  ;; in production. The same dialect divergence the quota ceiling had. Coerce here,
  ;; where the value meets the query, rather than trusting every caller.
  (define from
    (let ([n (and (real? since) since)])
      (if n (inexact->exact (floor n)) 0)))
  (define rows
    (query-rows conn
      (string-append
       "SELECT COALESCE(d.slug, ''), COALESCE(r.step_id, ''), r.verdict, COUNT(*), "
       "       AVG(CASE WHEN r.decided_ms IS NULL THEN NULL ELSE r.decided_ms - r.requested_ms END) "
       "FROM reviews r "
       "LEFT JOIN workflow_runs run ON run.id = r.run_id "
       "LEFT JOIN workflow_defs d ON d.id = run.def_id "
       "WHERE r.team_id = ? AND r.status = 'decided' AND r.decided_ms >= ? "
       "GROUP BY COALESCE(d.slug, ''), COALESCE(r.step_id, ''), r.verdict")
      team from))
  ;; fold the per-verdict rows into one row per (workflow, step)
  (define acc (make-hash))
  (for ([r (in-list rows)])
    (define k (cons (vector-ref r 0) (vector-ref r 1)))
    (define cur (hash-ref acc k (lambda () (hasheq 'approve 0 'revise 0 'reject 0 'ms 0 'n 0))))
    (define verdict (string->symbol (vector-ref r 2)))
    (define n (vector-ref r 3))
    (define ms (let ([v (vector-ref r 4)]) (if (or (sql-null? v) (not v)) 0 (inexact->exact (round (* 1.0 v))))))
    (hash-set! acc k (hash-set* cur verdict (+ (hash-ref cur verdict 0) n)
                                'n (+ (hash-ref cur 'n) n)
                                'ms (+ (hash-ref cur 'ms) (* ms n)))))
  (for/list ([k (in-list (sort (hash-keys acc) (lambda (a b) (string<? (string-append (car a) (cdr a))
                                                                      (string-append (car b) (cdr b))))))])
    (define v (hash-ref acc k))
    (define n (hash-ref v 'n))
    (hasheq 'workflow (car k) 'step (cdr k)
            'approved (hash-ref v 'approve) 'revised (hash-ref v 'revise) 'rejected (hash-ref v 'reject)
            'decided n
            ;; the number the RFE actually wants: how often the specialist let the
            ;; AI's output stand
            'approval_rate (if (zero? n) 0 (/ (round (* 1000.0 (/ (hash-ref v 'approve) n))) 1000))
            'mean_decision_ms (if (zero? n) 0 (quotient (hash-ref v 'ms) n)))))

;; ---- deciding ----------------------------------------------------------------
;; A decided review is terminal: deciding again is refused rather than overwriting.
;; A decision that turns out to be wrong wants a superseding record, not a rewrite
;; — the same call the grants table makes by keeping expired rows for the trail.
(define (review-decide! conn p id verdict #:rationale [rationale ""] #:answers [answers (hasheq)])
  (define rev (review-get conn p id))
  (define who (principal-user-id p))
  (cond
    [(not rev) 'no-such-review]
    [(not (equal? (hash-ref rev 'status) "pending")) 'already-decided]
    [(not (member verdict REVIEW-VERDICTS)) 'bad-verdict]
    ;; LAY-3: a human author may never decide their own work. A model-produced
    ;; subject has no author, so anyone holding the permission may decide it.
    [(and (hash-ref rev 'four_eyes)
          (string? (hash-ref rev 'author_user_id))
          (equal? (hash-ref rev 'author_user_id) who))
     'needs-another-reviewer]
    ;; A rationale is required where it carries information. Demanding one for a
    ;; plain approval buys a field full of "ok"; sending work back or rejecting it
    ;; is precisely the case Layer 3 has to explain later.
    [(and (not (equal? verdict "approve")) (string=? (string-trim (or rationale "")) ""))
     'needs-rationale]
    [(answers-problem (hash-ref rev 'checklist) answers) => values]
    [else
     (define ms (now-ms))
     (query-exec conn
       (string-append "UPDATE reviews SET status = 'decided', verdict = ?, rationale = ?, answers = ?, "
                      "decided_by = ?, decided_ms = ? WHERE id = ? AND status = 'pending'")
       verdict (or rationale "") (jsexpr->string answers) who ms id)
     ;; LAY-11: link it into the team's chain, AFTER the decision is stored — the
     ;; hash describes a decision that has already been recorded, never one that
     ;; might still fail to write.
     (define prev (last-chain-hash conn (hash-ref rev 'team_id)))
     (define decided (review-get conn p id))
     (query-exec conn "UPDATE reviews SET prev_hash = ?, hash = ? WHERE id = ?"
                 (or prev sql-null) (chain-hash decided prev) id)
     (define out (review-get conn p id))
     (audit! conn #:action (format "review.~a" verdict) #:actor-type "user" #:actor-id who
             #:team-id (hash-ref rev 'team_id)
             #:resource-type "review" #:resource-id id
             #:meta (jsexpr->string (hasheq 'run_id (hash-ref rev 'run_id)
                                            'step_id (hash-ref rev 'step_id))))
     ;; resume whatever parked on this, AFTER the row is terminal — a hook that
     ;; raises must not be able to leave the decision unrecorded
     (with-handlers ([exn:fail? (lambda (e)
                                  (audit! conn #:action "review.resume.error" #:actor-type "user" #:actor-id who
                                          #:team-id (hash-ref rev 'team_id)
                                          #:resource-type "review" #:resource-id id
                                          #:meta (jsexpr->string (hasheq 'error (exn-message e)))))])
       ((unbox resume-hook) conn out))
     out]))

;; A cancelled run leaves no pending review behind to answer.
(define (review-cancel-run! conn run-id)
  (query-exec conn "UPDATE reviews SET status = 'canceled' WHERE run_id = ? AND status = 'pending'" run-id))
