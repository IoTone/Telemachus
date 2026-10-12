#lang racket/base

;; test/review-tests.rkt — LAY-1…3: a workflow that waits for a person.
;;
;; What has to hold:
;;   1. the spec validates a review step and refuses a malformed one
;;   2. a run PARKS on it — status `waiting`, nothing queued, a pending review
;;   3. a verdict advances the run down the branch that verdict names
;;   4. `revise` loops back; `reject` with no branch ends the run
;;   5. four eyes: the run's initiator may not decide their own; another may
;;   6. a decided review is terminal, and a cancelled run leaves no question open
;;
;;   raco test test/review-tests.rkt

(require rackunit db-kit/portable
         racket/list json
         db-kit/migrate
         "../domain/db/migrations.rkt"
         "db-fixture.rkt"
         "../domain/authz/authz.rkt"
         "../domain/sched/scheduler.rkt"
         "../domain/agent/registry.rkt"
         "../domain/agent/tools.rkt"
         "../domain/flow/spec.rkt"
         "../domain/flow/run.rkt"
         "../domain/review/review.rkt")

(define (fresh) (define c (fresh-db #:migrate? #f)) (migrate! c all-migrations) c)
(define (owner-of conn)
  (define-values (u team) (bootstrap! conn #:username "root" #:team-slug "engineering"))
  (user-principal conn u team))
(define (drain! conn [limit 50])
  (let loop ([n 0]) (when (and (< n limit) (process-one! conn)) (loop (add1 n)))))
(define (status conn id) (query-value conn "SELECT status FROM workflow_runs WHERE id = ?" id))

;; extract → review → file. The review is the only thing between them.
(define (spec-with #:four-eyes [four-eyes #f] #:checklist [checklist '()])
  (hasheq 'spec 1 'slug "inspect" 'description "draft, review, file"
          'max_steps 10
          'input (hasheq 'subject "string")
          'start "draft"
          'steps (list
                  (hasheq 'id "draft" 'uses "tool:create_note"
                          'with (hasheq 'title "${input.subject}" 'body "a drafted finding")
                          'next "check")
                  (hasheq 'id "check" 'uses "review"
                          'title "Check the drafted finding"
                          'instructions "Confirm the finding is supported."
                          'of "${steps.draft.output.result}"
                          'checklist checklist
                          'four_eyes four-eyes
                          'on (hasheq 'approve "file" 'revise "draft" 'reject 'null))
                  (hasheq 'id "file" 'uses "tool:create_note"
                          'with (hasheq 'title "filed" 'body "approved") 'end #t))))

(define (start! conn p spec)
  (define d (flow-publish! conn p spec))
  (define run (flow-run-start! conn p d #:input (hasheq 'subject "levee 7")))
  (drain! conn)
  (hash-ref run 'id))

(define (pending-of conn p) (review-list conn p #:status "pending"))

;; ---- 1. the spec --------------------------------------------------------------
(test-case "a review step validates, and a malformed one is refused by name"
  (check-not-exn (lambda () (validate-spec (spec-with))))
  (define (broken f) (let* ([s (spec-with)]
                            [steps (hash-ref s 'steps)]
                            [rev (f (second steps))])
                       (hash-set s 'steps (list (first steps) rev (third steps)))))
  (check-exn #rx"'of' is required"
             (lambda () (validate-spec (broken (lambda (r) (hash-remove r 'of))))))
  (check-exn #rx"'on' is required"
             (lambda () (validate-spec (broken (lambda (r) (hash-remove r 'on))))))
  (check-exn #rx"'approve' is required"
             (lambda () (validate-spec (broken (lambda (r) (hash-set r 'on (hasheq 'reject 'null)))))))
  (check-exn #rx"is not a verdict"
             (lambda () (validate-spec (broken (lambda (r) (hash-set r 'on (hasheq 'approve "file" 'escalate "file")))))))
  (check-exn #rx"must be a step id in this workflow"
             (lambda () (validate-spec (broken (lambda (r) (hash-set r 'on (hasheq 'approve "nowhere")))))))
  (check-exn #rx"checklist"
             (lambda () (validate-spec (broken (lambda (r) (hash-set r 'checklist (list (hasheq 'key "A B")))))))))

;; ---- 2 & 3. parking and approving ---------------------------------------------
(test-case "a run parks on the review, and an approval sends it down the approve branch"
  (define c (fresh)) (define p (owner-of c))
  (define id (start! c p (spec-with)))
  (check-equal? (status c id) "waiting" "the run is parked, not running and not done")
  (define rs (pending-of c p))
  (check-equal? (length rs) 1)
  (define rev (first rs))
  (check-equal? (hash-ref rev 'title) "Check the drafted finding")
  (check-equal? (hash-ref rev 'run_id) id)
  ;; `of` was resolved: the review carries what the draft step produced
  (check-true (regexp-match? #rx"Created note" (format "~a" (hash-ref rev 'subject))))
  ;; nothing is queued while it waits — a parked run holds no concurrency slot
  (check-equal? (query-value c "SELECT COUNT(*) FROM jobs WHERE status = 'queued'") 0)

  (define out (review-decide! c p (hash-ref rev 'id) "approve"))
  (check-equal? (hash-ref out 'verdict) "approve")
  (drain! c)
  (check-equal? (status c id) "done" "approving advanced the run to the end")
  (check-equal? (length (pending-of c p)) 0)
  (disconnect c))

;; ---- 4. the other two verdicts -------------------------------------------------
(test-case "revise loops back to the step it names"
  (define c (fresh)) (define p (owner-of c))
  (define id (start! c p (spec-with)))
  (define rev (first (pending-of c p)))
  (review-decide! c p (hash-ref rev 'id) "revise" #:rationale "the finding needs a measurement")
  (drain! c)
  ;; back through draft, and parked on the review again — a NEW question
  (check-equal? (status c id) "waiting")
  (define again (pending-of c p))
  (check-equal? (length again) 1)
  (check-not-equal? (hash-ref (first again) 'id) (hash-ref rev 'id))
  (disconnect c))

(test-case "reject ends the run, and demands a reason"
  (define c (fresh)) (define p (owner-of c))
  (define id (start! c p (spec-with)))
  (define rev (first (pending-of c p)))
  (check-equal? (review-decide! c p (hash-ref rev 'id) "reject") 'needs-rationale
                "sending work back is exactly the case Layer 3 has to explain later")
  (check-equal? (status c id) "waiting" "a refused decision leaves the run parked")
  (review-decide! c p (hash-ref rev 'id) "reject" #:rationale "not supported by the survey")
  (drain! c)
  (check-equal? (status c id) "done" "the reject branch is null, so the run ends")
  (disconnect c))

;; ---- 5. four eyes ---------------------------------------------------------------
(test-case "with four_eyes the initiator may not decide, but a colleague may"
  (define c (fresh)) (define p (owner-of c))
  (define id (start! c p (spec-with #:four-eyes #t)))
  (define rev (first (pending-of c p)))
  (check-equal? (hash-ref rev 'four_eyes) #t)
  (check-equal? (review-decide! c p (hash-ref rev 'id) "approve") 'needs-another-reviewer
                "the person who set the work in motion cannot wave it through")
  (define bob (create-user! c #:username "bob"))
  (add-member! c #:user bob #:team (principal-team-id p) #:role "member")
  (define pb (user-principal c bob (principal-team-id p)))
  (define out (review-decide! c pb (hash-ref rev 'id) "approve"))
  (check-equal? (hash-ref out 'verdict) "approve")
  (check-equal? (hash-ref out 'decided_by) bob)
  (drain! c)
  (check-equal? (status c id) "done")
  (disconnect c))

(test-case "without four_eyes the subject has no human author, so anyone may decide"
  ;; the Localization Manager's machine-draft rule: a model-produced output is
  ;; nobody's work, and a one-person team must still be able to run a pipeline
  (define c (fresh)) (define p (owner-of c))
  (define id (start! c p (spec-with)))
  (define rev (first (pending-of c p)))
  (check-equal? (hash-ref rev 'author_user_id) 'null)
  (check-equal? (hash-ref (review-decide! c p (hash-ref rev 'id) "approve") 'verdict) "approve")
  (disconnect c))

;; ---- 6. terminal, and cancellation ---------------------------------------------
(test-case "a decided review is terminal"
  (define c (fresh)) (define p (owner-of c))
  (start! c p (spec-with))
  (define rev (first (pending-of c p)))
  (review-decide! c p (hash-ref rev 'id) "approve")
  (check-equal? (review-decide! c p (hash-ref rev 'id) "approve") 'already-decided
                "a wrong decision wants a superseding record, not a rewrite")
  (check-equal? (review-decide! c p (hash-ref rev 'id) "sideways") 'already-decided)
  (disconnect c))

(test-case "cancelling a parked run leaves no question in anybody's queue"
  (define c (fresh)) (define p (owner-of c))
  (define id (start! c p (spec-with)))
  (check-equal? (length (pending-of c p)) 1)
  (flow-run-cancel! c p id)
  (check-equal? (status c id) "canceled")
  (check-equal? (length (pending-of c p)) 0)
  (check-equal? (hash-ref (first (review-list c p #:status "canceled")) 'status) "canceled")
  (disconnect c))

;; ---- the checklist --------------------------------------------------------------
(test-case "a required checklist answer is demanded, and an unknown one refused"
  (define cl (list (hasheq 'key "method" 'label "Technical validity" 'required #t)
                   (hasheq 'key "risk"   'label "Unforeseen risk")))
  (define c (fresh)) (define p (owner-of c))
  (start! c p (spec-with #:checklist cl))
  (define rev (first (pending-of c p)))
  (check-equal? (hash-ref rev 'checklist) cl)
  (check-true (string? (review-decide! c p (hash-ref rev 'id) "approve" #:answers (hasheq 'risk "none"))))
  (check-true (string? (review-decide! c p (hash-ref rev 'id) "approve"
                                       #:answers (hasheq 'method "ok" 'nope "x"))))
  (define out (review-decide! c p (hash-ref rev 'id) "approve" #:answers (hasheq 'method "sound")))
  (check-equal? (hash-ref (hash-ref out 'answers) 'method) "sound")
  (disconnect c))
