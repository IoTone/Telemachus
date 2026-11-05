#lang racket/base

;; test/flow-tests.rkt — slice 46: the workflow engine.
;;   raco test test/flow-tests.rkt    (from refimpl/racketmaximus/, pkgs on PLTCOLLECTS)
;;
;; Covers the four things slice 46 claims: a workflow written in Racket runs end to
;; end, it survives a restart mid-run, it is refused across an org boundary, and the
;; spec round-trips publish → store → load → execute unchanged.

(require rackunit db-kit/portable
         syntax/macro-testing
         racket/list
         racket/file
         json
         db-kit/migrate
         "../domain/db/migrations.rkt"
         "db-fixture.rkt"
         "../domain/authz/authz.rkt"
         "../domain/orgs/orgs.rkt"
         "../domain/notes/notes.rkt"
         "../domain/sched/scheduler.rkt"
         "../domain/agent/registry.rkt"
         "../domain/agent/tools.rkt"          ; side effect: the built-in tool catalog
         ;; WF-14: the fault a fan-out must treat as fatal whatever its policy
         "../domain/tools/faults.rkt"
         "../domain/flow/spec.rkt"
         "../domain/flow/bind.rkt"
         "../domain/flow/dsl.rkt"
         "../domain/flow/run.rkt")

;; ---- fixtures ----------------------------------------------------------------
;; `key` names a SHARED database: two fixtures opened with the same key see each
;; other's writes, which is what the durability test needs and what the fixture
;; supplies on either dialect (a file on SQLite, one schema on Postgres).
(define (fresh [key #f])
  (define conn (fresh-db #:shared key #:migrate? #f))
  (migrate! conn all-migrations)
  conn)

(define (owner-of conn)
  (define-values (u team)
    (bootstrap! conn #:username "root" #:org-name "Acme" #:org-slug "acme"
                #:team-name "Engineering" #:team-slug "engineering"))
  (user-principal conn u team))

;; run the queue to quiescence — `process-one!` is the scheduler's synchronous core,
;; so this is the real claim/run path, not a test-only shortcut
(define (drain! conn [limit 50])
  (let loop ([n 0]) (when (and (< n limit) (process-one! conn)) (loop (add1 n)))))

(define (status conn run-id)
  (query-value conn "SELECT status FROM workflow_runs WHERE id = ?" run-id))

;; ---- a workflow written in Racket, the way a plugin author would -------------
(define-workflow note-triage
  #:description "Write a note, then branch on what the tool said"
  #:input ([subject string])
  (step write  (tool create_note #:title (in subject) #:body "filed by a workflow"))
  (step gate   (choice (contains (out write result) "Created note") #:then confirm #:else bail))
  (step confirm (tool create_note #:title "confirmed" #:body (out write result)) #:end)
  (step bail    (tool create_note #:title "unexpected" #:body "the write step did not report success") #:end))

;; ---- the spec ----------------------------------------------------------------
(test-case "the macro emits a document the normative validator accepts"
  (check-equal? (hash-ref note-triage 'spec) SPEC-FORMAT-VERSION)
  (check-equal? (spec-slug note-triage) "note-triage")
  (check-equal? (spec-start note-triage) "write")
  (check-equal? (length (spec-steps note-triage)) 4)
  ;; validate-spec is idempotent — the same call the publish path makes
  (check-equal? (validate-spec note-triage) note-triage))

(test-case "the spec survives a JSON round trip byte for byte"
  (define wire (jsexpr->string note-triage))
  (check-equal? (validate-spec (string->jsexpr wire)) note-triage)
  (check-equal? (jsexpr->string (validate-spec (string->jsexpr wire))) wire))

(test-case "unknown fields are rejected, not ignored (WF-10)"
  (define base (hasheq 'spec 1 'slug "s" 'steps (list (hasheq 'id "a" 'uses "tool:x"))))
  (check-not-exn (lambda () (validate-spec base)))
  (check-exn exn:fail:spec? (lambda () (validate-spec (hash-set base 'sped 1))))
  (check-exn exn:fail:spec?
             (lambda () (validate-spec (hash-set base 'steps (list (hasheq 'id "a" 'uses "tool:x" 'onError "ignore"))))))
  ;; a newer format version is refused rather than best-effort executed
  (check-exn exn:fail:spec? (lambda () (validate-spec (hash-set base 'spec 2))))
  ;; a step kind this build does not have yet is a refusal, not a silent no-op
  (check-exn exn:fail:spec?
             (lambda () (validate-spec (hash-set base 'steps (list (hasheq 'id "a" 'uses "agent")))))))

(test-case "dangling references and ids are caught at publish time"
  (define (with-steps ss) (hasheq 'spec 1 'slug "s" 'steps ss))
  (check-exn exn:fail:spec?
             (lambda () (validate-spec (with-steps (list (hasheq 'id "a" 'uses "tool:x"
                                                                 'with (hasheq 'v "${steps.ghost.output.y}")))))))
  (check-exn exn:fail:spec?
             (lambda () (validate-spec (with-steps (list (hasheq 'id "a" 'uses "tool:x" 'next "ghost"))))))
  (check-exn exn:fail:spec?
             (lambda () (validate-spec (with-steps (list (hasheq 'id "a" 'uses "tool:x")
                                                         (hasheq 'id "a" 'uses "tool:y"))))))
  ;; a malformed reference root
  (check-exn exn:fail:spec?
             (lambda () (validate-spec (with-steps (list (hasheq 'id "a" 'uses "tool:x"
                                                                 'with (hasheq 'v "${env.SECRET}")))))))
  ;; …but a forward reference to a later step is legal: loops are bounded, not banned
  (check-not-exn
   (lambda () (validate-spec (with-steps (list (hasheq 'id "a" 'uses "tool:x" 'next "b")
                                               (hasheq 'id "b" 'uses "tool:y" 'next "a")))))))

;; ---- the binding sublanguage -------------------------------------------------
(test-case "bindings resolve by type, interpolate by text, and evaluate predicates"
  (define ctx (make-context #:input (hasheq 'n 3 'who "ada")
                            #:outputs (hasheq 'first (hasheq 'rating 5 'tags '("a" "b")))
                            #:run-id "r1" #:team-id "t1" #:user-id "u1"))
  ;; a whole-string reference keeps the value's type
  (check-equal? (resolve-value "${input.n}" ctx) 3)
  (check-equal? (resolve-value "${steps.first.output.tags}" ctx) '("a" "b"))
  (check-equal? (resolve-value "${run.id}" ctx) "r1")
  (check-equal? (resolve-value "${principal.team_id}" ctx) "t1")
  ;; embedded in text it interpolates
  (check-equal? (resolve-value "hi ${input.who}, rated ${steps.first.output.rating}" ctx) "hi ada, rated 5")
  ;; a miss is null, not an error — the predicate set is how you test for it
  (check-equal? (resolve-value "${input.nope}" ctx) 'null)
  (check-true  (eval-predicate (hasheq 'gt (list "${steps.first.output.rating}" 3)) ctx))
  (check-false (eval-predicate (hasheq 'gt (list "${steps.first.output.rating}" 9)) ctx))
  (check-true  (eval-predicate (hasheq 'eq (list "${input.who}" "ada")) ctx))
  (check-true  (eval-predicate (hasheq 'contains (list "${steps.first.output.tags}" "b")) ctx))
  (check-true  (eval-predicate (hasheq 'exists (list "${input.n}")) ctx))
  (check-false (eval-predicate (hasheq 'exists (list "${input.nope}")) ctx))
  (check-true  (eval-predicate (hasheq 'empty (list "${input.nope}")) ctx)))

;; ---- end to end --------------------------------------------------------------
(test-case "a workflow runs end to end through the real scheduler"
  (define conn (fresh))
  (define p (owner-of conn))
  (define d (flow-publish! conn p note-triage))
  (check-equal? (hash-ref d 'version) 1)
  (check-equal? (hash-ref d 'source) "db")

  (define run (flow-run-start! conn p d #:input (hasheq 'subject "Q3 plan")))
  (drain! conn)
  (define final (flow-run-get conn p (hash-ref run 'id)))
  (check-equal? (hash-ref final 'status) "done" "the run completed")

  ;; write → gate → confirm, and the `else` branch was never taken
  (define ran (for/list ([s (in-list (hash-ref final 'steps))]) (hash-ref s 'step_id)))
  (check-equal? ran '("write" "gate" "confirm"))
  (check-true (for/and ([s (in-list (hash-ref final 'steps))]) (equal? (hash-ref s 'status) "done")))

  ;; the steps really did the work: two notes exist, and the second quotes the first
  (define titles (for/list ([n (in-list (notes-list conn p))]) (hash-ref n 'title)))
  (check-true (and (member "Q3 plan" titles) (member "confirmed" titles) #t))
  (define confirmed (findf (lambda (n) (equal? (hash-ref n 'title) "confirmed")) (notes-list conn p)))
  (check-regexp-match #rx"Created note" (hash-ref confirmed 'body)
                      "the confirm step consumed the write step's output"))

(test-case "publishing the same slug versions it, and the newest wins"
  (define conn (fresh))
  (define p (owner-of conn))
  (flow-publish! conn p note-triage)
  (define v2 (flow-publish! conn p (hash-set note-triage 'description "second cut")))
  (check-equal? (hash-ref v2 'version) 2)
  (check-equal? (hash-ref (flow-def-by-slug conn p "note-triage") 'version) 2))

(test-case "a failing step ends the run with the reason, after its retries"
  (define conn (fresh))
  (define p (owner-of conn))
  (define spec (hasheq 'spec 1 'slug "broken"
                       'steps (list (hasheq 'id "boom" 'uses "tool:no_such_tool"
                                            'retry (hasheq 'max 2)))))
  (define d (flow-publish! conn p spec))
  (define run (flow-run-start! conn p d))
  (drain! conn)
  (define final (flow-run-get conn p (hash-ref run 'id)))
  (check-equal? (hash-ref final 'status) "error")
  (check-regexp-match #rx"no_such_tool" (hash-ref final 'error))
  ;; retried the declared number of times before giving up
  (check-equal? (hash-ref (car (hash-ref final 'steps)) 'attempt) 3))

(test-case "a workflow that never terminates is stopped by max_steps"
  (define conn (fresh))
  (define p (owner-of conn))
  (define spec (hasheq 'spec 1 'slug "spin" 'max_steps 5
                       'steps (list (hasheq 'id "a" 'uses "tool:list_notes" 'next "a"))))
  (define d (flow-publish! conn p spec))
  (define run (flow-run-start! conn p d))
  (drain! conn 200)
  (define final (flow-run-get conn p (hash-ref run 'id)))
  (check-equal? (hash-ref final 'status) "error")
  (check-regexp-match #rx"max_steps" (hash-ref final 'error)))

(test-case "cancelling a run stops the work that has not started"
  (define conn (fresh))
  (define p (owner-of conn))
  (define d (flow-publish! conn p note-triage))
  (define run (flow-run-start! conn p d #:input (hasheq 'subject "abandon me")))
  (check-equal? (flow-run-cancel! conn p (hash-ref run 'id)) #t)
  (drain! conn)
  (check-equal? (status conn (hash-ref run 'id)) "canceled")
  ;; the queued step was claimed and no-opped rather than writing a note
  (check-equal? (notes-list conn p) '())
  (check-equal? (flow-run-cancel! conn p (hash-ref run 'id)) 'not-cancelable))

;; ---- durability --------------------------------------------------------------
(test-case "a run survives the process that started it"
  ;; the point is that NOTHING is carried over in memory — only the database
  (define shared 'flow-durability)
  ;; --- "process" one: publish, start, run exactly one step, then close everything
  (define run-id
    (let* ([conn (fresh shared)]
           [p (owner-of conn)]
           [d (flow-publish! conn p note-triage)]
           [run (flow-run-start! conn p d #:input (hasheq 'subject "survivor"))])
      (check-true (and (process-one! conn) #t) "the first step ran")
      (check-equal? (status conn (hash-ref run 'id)) "running")
      (disconnect conn)
      (hash-ref run 'id)))
  ;; --- "process" two: a brand-new connection picks the run up mid-flight
  (define conn2 (fresh-db #:shared shared #:migrate? #f))
  (drain! conn2)
  (check-equal? (status conn2 run-id) "done" "resumed from the database alone")
  (define steps (query-list conn2 "SELECT step_id FROM workflow_steps WHERE run_id = ? ORDER BY seq" run-id))
  (check-equal? steps '("write" "gate" "confirm"))
  (close-db! conn2))

;; ---- tenancy -----------------------------------------------------------------
(test-case "a workflow definition does not cross an org boundary"
  (define conn (fresh))
  (define-values (root sys) (bootstrap! conn #:username "root" #:org-name "Instance" #:org-slug "system"
                                        #:team-name "Instance" #:team-slug "instance"))
  (define (company name slug)
    (define o (org-create! conn #f #:name name #:slug slug
                           #:owner-username (string-append "owner@" slug)
                           #:team-name "Engineering" #:team-slug "engineering"))
    (user-principal conn (hash-ref o 'owner_user_id) (hash-ref o 'team_id)))
  (define acme (company "Acme" "acme"))
  (define globex (company "Globex" "globex"))

  (define d (flow-publish! conn acme note-triage))
  ;; its owner reads it…
  (check-equal? (hash-ref (flow-def-get conn acme (hash-ref d 'id)) 'slug) "note-triage")
  ;; …the other company cannot, by id, even though it knows the id
  (check-exn exn:fail:forbidden? (lambda () (flow-def-get conn globex (hash-ref d 'id))))
  ;; …and the slug is free for it to use, because defs are per team
  (check-not-exn (lambda () (flow-publish! conn globex note-triage)))
  (check-equal? (length (flow-defs conn globex)) 1)

  ;; a run is likewise unreachable from the other company
  (define run (flow-run-start! conn acme d #:input (hasheq 'subject "acme only")))
  (check-exn exn:fail:forbidden? (lambda () (flow-run-get conn globex (hash-ref run 'id)))))

(test-case "every step re-checks the principal — no authority accumulates"
  (define conn (fresh))
  (define p (owner-of conn))
  ;; a viewer may read and run, but create_note needs notes:write
  (define viewer (create-user! conn #:username "vic"))
  (add-member! conn #:user viewer #:team (principal-team-id p) #:role "viewer")
  (define vp (user-principal conn viewer (principal-team-id p)))
  (define d (flow-publish! conn p note-triage))
  (check-exn exn:fail:forbidden? (lambda () (flow-publish! conn vp note-triage)))
  ;; the viewer starts it (workflows:run is covered by *:read? no — it is refused)
  (check-exn exn:fail:forbidden? (lambda () (flow-run-start! conn vp d #:input (hasheq 'subject "x")))))

(test-case "the feature flag turns the whole engine off for a team"
  (define conn (fresh))
  (define p (owner-of conn))
  (define d (flow-publish! conn p note-triage))
  (query-exec conn "INSERT INTO feature_settings (id, team_id, feature, enabled) VALUES ('f1', ?, 'workflows', 0)"
              (principal-team-id p))
  (check-exn exn:fail? (lambda () (flow-run-start! conn p d #:input (hasheq 'subject "nope")))))

;; ---- map: fan-out (slice 47) -------------------------------------------------
;; `list_notes` is a handy per-item tool: it takes no arguments, so a map over three
;; items is three identical jobs whose ORDER in the aggregate is what we care about.
(define-workflow fan-demo
  #:input ([subjects array])
  (step make (map #:over (in subjects) (tool create_note #:title (item) #:body "fanned")))
  (step tally (tool list_notes) #:end))

(test-case "a map fans out, and the parent aggregates in order"
  (define conn (fresh))
  (define p (owner-of conn))
  (define d (flow-publish! conn p fan-demo))
  (define run (flow-run-start! conn p d #:input (hasheq 'subjects '("alpha" "beta" "gamma"))))
  (drain! conn)
  (define final (flow-run-get conn p (hash-ref run 'id)))
  (check-equal? (hash-ref final 'status) "done")

  ;; the fan-out produced one child step per item, plus the parent
  (define ids (for/list ([s (in-list (hash-ref final 'steps))]) (hash-ref s 'step_id)))
  (check-equal? ids '("make" "make#0" "make#1" "make#2" "tally"))

  ;; the parent's output is the children's, in the order of `over` — not completion
  (define parent (findf (lambda (s) (equal? (hash-ref s 'step_id) "make")) (hash-ref final 'steps)))
  (define results (hash-ref (hash-ref parent 'output) 'results))
  (check-equal? (length results) 3)
  (check-regexp-match #rx"alpha" (hash-ref (first results) 'result))
  (check-regexp-match #rx"gamma" (hash-ref (third results) 'result))

  ;; the step AFTER the fan-out saw all three
  (define tally (findf (lambda (s) (equal? (hash-ref s 'step_id) "tally")) (hash-ref final 'steps)))
  (for ([w (in-list '("alpha" "beta" "gamma"))])
    (check-regexp-match (regexp w) (hash-ref (hash-ref tally 'output) 'result))))

(test-case "an empty fan-out is not a failure"
  (define conn (fresh))
  (define p (owner-of conn))
  (define d (flow-publish! conn p fan-demo))
  (define run (flow-run-start! conn p d #:input (hasheq 'subjects '())))
  (drain! conn)
  (define final (flow-run-get conn p (hash-ref run 'id)))
  (check-equal? (hash-ref final 'status) "done")
  (define parent (findf (lambda (s) (equal? (hash-ref s 'step_id) "make")) (hash-ref final 'steps)))
  (check-equal? (hash-ref (hash-ref parent 'output) 'results) '()))

(test-case "one bad item fails the fan-out, and the fan-out fails the run"
  (define conn (fresh))
  (define p (owner-of conn))
  ;; a map over a tool that does not exist: every child fails, retries are honored
  (define spec (hasheq 'spec 1 'slug "bad-fan"
                       'steps (list (hasheq 'id "fan" 'uses "map" 'over '("a" "b")
                                            'step (hasheq 'uses "tool:not_a_tool"
                                                          'with (hasheq 'x "${item}"))))))
  (define d (flow-publish! conn p spec))
  (define run (flow-run-start! conn p d))
  (drain! conn)
  (define final (flow-run-get conn p (hash-ref run 'id)))
  (check-equal? (hash-ref final 'status) "error")
  (check-regexp-match #rx"not_a_tool" (hash-ref final 'error))
  ;; the parent is marked too, so the run view shows WHERE it broke
  (define parent (findf (lambda (s) (equal? (hash-ref s 'step_id) "fan")) (hash-ref final 'steps)))
  (check-equal? (hash-ref parent 'status) "error"))

(test-case "a fan-out that would blow max_steps is refused before it starts"
  (define conn (fresh))
  (define p (owner-of conn))
  (define spec (hasheq 'spec 1 'slug "toobig" 'max_steps 3
                       'steps (list (hasheq 'id "fan" 'uses "map" 'over '("a" "b" "c" "d" "e")
                                            'step (hasheq 'uses "tool:list_notes")))))
  (define d (flow-publish! conn p spec))
  (define run (flow-run-start! conn p d))
  (drain! conn)
  (define final (flow-run-get conn p (hash-ref run 'id)))
  (check-equal? (hash-ref final 'status) "error")
  (check-regexp-match #rx"max_steps" (hash-ref final 'error)))

(test-case "${item} is confined to a map, and ${principal.locale} follows the profile"
  ;; the loop variables are meaningless outside a fan-out, so using one is a
  ;; publish-time rejection rather than a null at run time
  (check-exn exn:fail:spec?
             (lambda () (validate-spec (hasheq 'spec 1 'slug "s"
                                               'steps (list (hasheq 'id "a" 'uses "tool:x"
                                                                    'with (hasheq 'v "${item}")))))))
  (define conn (fresh))
  (define p (owner-of conn))
  (check-equal? (user-locale conn (principal-user-id p)) "en" "the default profile language")
  (set-user-locale! conn (principal-user-id p) "is")
  (define spec (hasheq 'spec 1 'slug "loc"
                       'steps (list (hasheq 'id "n" 'uses "tool:create_note"
                                            'with (hasheq 'title "${principal.locale}" 'body "x")))))
  (define d (flow-publish! conn p spec))
  (flow-run-start! conn p d)
  (drain! conn)
  (check-true (and (member "is" (for/list ([n (in-list (notes-list conn p))]) (hash-ref n 'title))) #t)
              "the step bound the user's own language, not the request's"))

(test-case "${principal.timezone} is a binding this build actually admits (#137)"
  ;; It was in `make-context`, in bind.rkt's own header and in the clock work's
  ;; notes, and NOT in `valid-ref?` — so the one documented way to reach a
  ;; person's clock from a workflow was refused at publish time, and the macro had
  ;; no spelling for it at all. Both halves of that are fixed; this pins both.
  (check-true (valid-ref? "principal.timezone"))
  (check-false (valid-ref? "principal.nickname") "and the set is still closed")
  (define conn (fresh))
  (define p (owner-of conn))
  (define spec (hasheq 'spec 1 'slug "tz"
                       'steps (list (hasheq 'id "n" 'uses "tool:create_note"
                                            'with (hasheq 'title "${principal.timezone}" 'body "x")))))
  (define d (flow-publish! conn p spec))
  (flow-run-start! conn p d)
  (drain! conn)
  ;; nothing is configured, so TZ-6's chain ends at UTC — the point is that the
  ;; reference RESOLVED rather than being rejected or left as literal text
  (check-true (and (member "UTC" (for/list ([n (in-list (notes-list conn p))]) (hash-ref n 'title))) #t)))

;; ---- the review step, from the authoring surface (issue #87 slice 2) ---------
;; The `review` step kind has existed since LAY-1 and `define-workflow` could not
;; spell it, so every workflow that parks on a person had to be hand-written JSON.
(define-workflow gated-triage
  #:description "Write a note, ask a person, then act on the verdict"
  #:input ([subject string] [threshold number])
  (step write (tool create_note #:title (in subject) #:body "filed by a workflow"
                                #:when_local (timezone)))
  (step gate  (choice (lt (in threshold) 0.5) #:then look #:else done))
  (step look  (review #:title "Is this note right?"
                      #:of (out write result)
                      #:instructions "Read it and say."
                      #:four-eyes
                      #:checklist ([verdict_note "What is wrong with it"]
                                   [follow_up "Anything to follow up" #:optional])
                      #:approve done
                      #:revise fix))
  (step fix   (tool create_note #:title "revised" #:body (out look result rationale)) #:end)
  (step done  (tool create_note #:title "done" #:body (out write result)) #:end))

(test-case "the macro spells a review step, and the normative validator accepts it"
  (check-equal? (validate-spec gated-triage) gated-triage)
  (define r (findf (lambda (s) (equal? (hash-ref s 'id) "look")) (spec-steps gated-triage)))
  (check-equal? (hash-ref r 'uses) "review")
  (check-equal? (hash-ref r 'title) "Is this note right?")
  (check-equal? (hash-ref r 'of) "${steps.write.output.result}")
  (check-equal? (hash-ref r 'instructions) "Read it and say.")
  (check-true (hash-ref r 'four_eyes))
  ;; one keyword per verdict, and an ABSENT verdict is a null branch — which the
  ;; engine reads as "end the run there", so there is no sentinel to spell
  (check-equal? (hash-ref r 'on) (hasheq 'approve "done" 'revise "fix"))
  (check-false (hash-has-key? (hash-ref r 'on) 'reject))
  ;; `required` defaults to true, as the spec's own reader does, and #:optional is
  ;; the way to say otherwise
  (check-equal? (hash-ref r 'checklist)
                (list (hasheq 'key "verdict_note" 'label "What is wrong with it" 'required #t)
                      (hasheq 'key "follow_up" 'label "Anything to follow up" 'required #f)))
  ;; and it survives the wire, which is what makes the macro's output and a
  ;; hand-written document indistinguishable (WF-9)
  (check-equal? (validate-spec (string->jsexpr (jsexpr->string gated-triage))) gated-triage))

(test-case "a review's branches are checked where the error can point at the source"
  ;; the macro's job is to fail at the line somebody wrote, rather than handing the
  ;; validator a generated document that names a step id nobody can find
  (check-exn #rx"#:approve names step 'nowhere'"
             (lambda ()
               (convert-compile-time-error
                (let ()
                  (define-workflow bad-approve
                    (step a (tool create_note #:title "x" #:body "y"))
                    (step r (review #:title "t" #:of (out a result) #:approve nowhere)))
                  bad-approve))))
  (check-exn #rx"#:revise names step 'nope'"
             (lambda ()
               (convert-compile-time-error
                (let ()
                  (define-workflow bad-revise
                    (step a (tool create_note #:title "x" #:body "y"))
                    (step r (review #:title "t" #:of (out a result) #:approve a #:revise nope)))
                  bad-revise))))
  ;; `#:end` is refused rather than ignored: where a review goes depends on the
  ;; verdict, so an `#:end` beside three branches is a contradiction, and leaving
  ;; a verdict out is how you end the run on it
  (check-exn #rx"a review has no #:end"
             (lambda ()
               (convert-compile-time-error
                (let ()
                  (define-workflow bad-end
                    (step a (tool create_note #:title "x" #:body "y"))
                    (step r (review #:title "t" #:of (out a result) #:approve a) #:end))
                  bad-end))))
  ;; the validator still owns the rule that an approval must go somewhere, so the
  ;; macro requiring #:approve cannot be the only thing enforcing it
  (check-exn exn:fail:spec?
             (lambda () (validate-spec (hasheq 'spec 1 'slug "s"
                                               'steps (list (hasheq 'id "r" 'uses "review"
                                                                    'title "t" 'of "x"
                                                                    'on (hasheq 'revise "r"))))))))

;; ---- contract discovery ------------------------------------------------------
(test-case "the schema endpoint describes what this build accepts"
  (define s (spec-schema))
  (check-equal? (hash-ref s 'spec) SPEC-FORMAT-VERSION)
  (check-equal? (hash-ref s 'unknown_fields) "rejected")
  (check-true (and (member "choice" (hash-ref s 'step_kinds)) #t))
  (check-regexp-match #rx"not conformant" (hash-ref s 'conformance)))

;; ---- what an incomparable-operand refusal may say (#186, SEC-7) -------------
;;
;; `compare` quoted BOTH operands in full, and `resolve-value` has just resolved
;; them out of the run's bindings — so each one is a step's OUTPUT, which for the
;; document pipeline is extracted document content: the class #83 r4 sealed four
;; `error` columns over. The message reaches `workflow_steps.error` AND, since
;; #123 routed every unhandled message to stderr, the container log, which r4
;; names as the copy most likely to be read by a person.

(test-case "a `gt` on mismatched types names the TYPES and quotes neither value"
  (define secret "Arun Patel, 078-05-1120, account 4111111111111111")
  (define ctx (make-context #:input (hasheq 'threshold 3)
                            #:outputs (hasheq 'extract (hasheq 'total secret))
                            #:run-id "r" #:team-id "t" #:user-id "u"))
  (define msg
    (with-handlers ([exn:fail? exn-message])
      (eval-predicate (hasheq 'gt (list "${steps.extract.output.total}" "${input.threshold}")) ctx)))
  (check-true (string? msg) "the comparison is still refused")
  (check-false (regexp-match? #rx"Arun Patel" msg) "no extracted content in the refusal")
  (check-false (regexp-match? #rx"078-05-1120" msg))
  (check-false (regexp-match? #rx"4111111111111111" msg))
  ;; …and a truncation would have been the tempting middle answer: it still
  ;; quotes content, and misleadingly. Nothing of the value at all.
  (check-false (regexp-match? #rx"Arun" msg) "not even a prefix of it")
  ;; what IS said is the whole of what the author did not know
  (check-true (and (regexp-match? #rx"string" msg) #t) "the string side is named")
  (check-true (and (regexp-match? #rx"integer|number" msg) #t) "and the numeric one")
  (check-true (and (regexp-match? #rx"incomparable" msg) #t)))

(test-case "…and a comparison that CAN be made is unaffected, which is the control"
  ;; without this, a version that refused every comparison — or one that answered
  ;; a bare #f instead of raising — would pass every refutation above.
  (define ctx (make-context #:input (hasheq 'n 3)
                            #:outputs (hasheq 'first (hasheq 'rating 5))
                            #:run-id "r" #:team-id "t" #:user-id "u"))
  (check-true (eval-predicate (hasheq 'gt (list "${steps.first.output.rating}" "${input.n}")) ctx))
  (check-false (eval-predicate (hasheq 'lt (list "${steps.first.output.rating}" "${input.n}")) ctx)))

;; ---- WF-11…WF-17: a child's error, and what it does to its siblings (#236) ----
;;
;; Reported from outside, with the measurement: `index-knowledge` over thirteen
;; documents, child `extract#1` errored, and children #2 through #11 were left
;; `queued` carrying an error they never got to act on — the run red and the work
;; not done. `index-documents` over the SAME thirteen completed 7 of 7, because
;; its extractor records an unreadable file as processed-with-nothing rather than
;; raising. The tolerance was already chosen; it lived hand-written inside one
;; tool instead of being available to a fan-out.
;;
;; A test-only tool, because none of the built-in ones fails for SOME items and
;; not others — and that is exactly the case the whole slice is about. `not_a_tool`
;; (the case above) fails every child, which cannot distinguish "the fan-out
;; carried on" from "nothing worked".
(register-tool! "wf_item_probe"
  (hasheq 'type "function"
          'function (hasheq 'name "wf_item_probe" 'description "test fixture"
                            'parameters (hasheq 'type "object"
                                                'properties (hasheq 'x (hasheq 'type "string"))
                                                'required '("x"))))
  "notes:read"
  (lambda (conn p args)
    (define x (hash-ref args 'x ""))
    (cond
      ;; "an operator must change something" — fatal to a fan-out whatever its
      ;; policy says (WF-14)
      [(equal? x "misconfigured") (raise-misconfigured 'wf_item_probe "no model configured (fixture)")]
      ;; "this item is awkward" — the twelve siblings are innocent
      [(equal? x "bad") (error 'wf_item_probe "this item is awkward")]
      [else (format "ok:~a" x)])))

(define (probe-spec slug items #:on-error [oe #f] #:retry [retry 0])
  (hasheq 'spec 1 'slug slug
          'steps (list (let* ([h (hasheq 'id "fan" 'uses "map" 'over items
                                         'step (hasheq 'uses "tool:wf_item_probe"
                                                       'with (hasheq 'x "${item}")
                                                       'retry (hasheq 'max retry)))]
                              [h (if oe (hash-set h 'on_error oe) h)])
                         h))))

(define (run-probe conn p spec)
  (define d (flow-publish! conn p spec))
  (define run (flow-run-start! conn p d))
  (drain! conn)
  (flow-run-get conn p (hash-ref run 'id)))

(define (step-named final id)
  (findf (lambda (s) (equal? (hash-ref s 'step_id) id)) (hash-ref final 'steps)))

(test-case "WF-12: `on_error` is a CLOSED vocabulary, and absent means today's behaviour"
  ;; A value invented in passing would arrive at the engine as something nothing
  ;; explains — READ-DOORS' rule, which is why the list is closed rather than
  ;; free-form.
  (check-equal? MAP-ERROR-POLICIES '("fail" "continue"))
  (check-exn #rx"on_error: must be one of"
             (lambda () (validate-spec (probe-spec "oe-bad" '("a") #:on-error "ignore"))))
  (for ([v (in-list MAP-ERROR-POLICIES)])
    (check-true (hash? (validate-spec (probe-spec "oe-ok" '("a") #:on-error v))) v))
  ;; ABSENT is "fail", so every spec published before the key existed means
  ;; exactly what it meant. This is also why adding the key is not the
  ;; spec-version change it looks like: WF-10 refuses a spec naming a field THIS
  ;; BUILD lacks (the forward direction), not an older spec on a newer engine.
  (check-equal? (map-on-error (hasheq 'id "fan" 'uses "map")) "fail")
  (check-equal? (map-on-error (hasheq 'id "fan" 'uses "map" 'on_error "continue")) "continue"))

(test-case "WF-11: with no policy, one bad item still takes the run down — the control"
  ;; The behaviour #236 reported, asserted deliberately: a `map` that says
  ;; nothing must behave exactly as it did, or this slice is a silent change to
  ;; every published spec in the field.
  (define conn (fresh))
  (define p (owner-of conn))
  (define final (run-probe conn p (probe-spec "fan-fail" '("a" "bad" "c"))))
  (check-equal? (hash-ref final 'status) "error")
  (check-regexp-match #rx"awkward" (hash-ref final 'error))
  (check-equal? (hash-ref (step-named final "fan") 'status) "error"))

(test-case "WF-11: with `continue`, the siblings are indexed and the step still reports"
  (define conn (fresh))
  (define p (owner-of conn))
  (define final (run-probe conn p (probe-spec "fan-cont" '("a" "bad" "c") #:on-error "continue")))
  ;; THE ACCEPTANCE CRITERION: one document that cannot be processed does not
  ;; prevent the others.
  (check-equal? (hash-ref final 'status) "done")
  (define parent (step-named final "fan"))
  (check-equal? (hash-ref parent 'status) "done")
  (define out (hash-ref parent 'output))
  ;; …and a partially-successful fan-out SAYS SO, with the count and the reason
  ;; per failure rather than a flag that is only ever true (CLS-27's shape)
  (check-equal? (hash-ref out 'count) 3)
  (check-equal? (hash-ref out 'succeeded) 2)
  (check-equal? (hash-ref out 'failed) 1)
  (define fs (hash-ref out 'failures))
  (check-equal? (length fs) 1)
  (check-equal? (hash-ref (car fs) 'index) 1)
  (check-equal? (hash-ref (car fs) 'step) "fan#1")
  (check-regexp-match #rx"awkward" (hash-ref (car fs) 'error))
  ;; WF-13: `results` STAYS POSITIONAL, with the jsexpr null where a child
  ;; failed. Compacting would silently re-align every downstream binding of
  ;; `${steps.fan.output.results}` by however many items happened to fail — a
  ;; hole, never a splice.
  (define results (hash-ref out 'results))
  (check-equal? (length results) 3)
  (check-equal? (hash-ref (first results) 'result) "ok:a")
  (check-equal? (second results) 'null)
  (check-equal? (hash-ref (third results) 'result) "ok:c")
  ;; the child keeps its own error — the row is the record
  (check-equal? (hash-ref (step-named final "fan#1") 'status) "error"))

(test-case "WF-15: a fan-out that achieved NOTHING is not a success"
  ;; With `continue` this would otherwise report `succeeded: 0` and go green,
  ;; which is worse than failing on the first child: the operator is told the
  ;; backlog was drained.
  (define conn (fresh))
  (define p (owner-of conn))
  (define final (run-probe conn p (probe-spec "fan-all-bad" '("bad" "bad") #:on-error "continue")))
  (check-equal? (hash-ref final 'status) "error")
  (check-regexp-match #rx"all 2 item\\(s\\)" (hash-ref final 'error))
  (check-regexp-match #rx"awkward" (hash-ref final 'error))
  (define parent (step-named final "fan"))
  (check-equal? (hash-ref parent 'status) "error")
  ;; the diagnostic is KEPT on the error path: one message about N documents is
  ;; not what an operator needs
  (check-equal? (hash-ref (hash-ref parent 'output) 'failed) 2))

(test-case "WF-14: a MISCONFIGURATION is fatal on the first child, whatever the policy"
  ;; The third acceptance criterion. `continue` would otherwise spend N model
  ;; requests and N error rows to learn what the first child already said.
  (define conn (fresh))
  (define p (owner-of conn))
  (define final (run-probe conn p (probe-spec "fan-misc" '("a" "misconfigured" "c")
                                              #:on-error "continue")))
  (check-equal? (hash-ref final 'status) "error")
  (check-regexp-match #rx"no model configured" (hash-ref final 'error))
  (check-equal? (hash-ref (step-named final "fan") 'status) "error")
  ;; …and it is the exception TYPE that decides, not the message: there is no
  ;; sound way to read "no model configured" out of a string the register sweeps
  ;; and the localizer both rewrite.
  (check-true (exn:fail:misconfigured? (exn:fail:misconfigured "x" (current-continuation-marks))))
  (check-false (exn:fail:misconfigured? (make-exn:fail "x" (current-continuation-marks)))))

(test-case "WF-11: a retry is still honoured per child under `continue`"
  ;; `continue` must not short-circuit the retry the template asked for — the
  ;; tolerance is about EXHAUSTED errors, which is where `step-failed!` decides.
  (define conn (fresh))
  (define p (owner-of conn))
  (define final (run-probe conn p (probe-spec "fan-retry" '("a" "bad") #:on-error "continue" #:retry 1)))
  (check-equal? (hash-ref final 'status) "done")
  (check-equal? (hash-ref (step-named final "fan") 'output) (hash-ref (step-named final "fan") 'output))
  (check-equal? (hash-ref (step-named final "fan#1") 'attempt) 2 "the child was retried before being tolerated"))

(test-case "WF-11: the macro can spell the policy, and refuses an unknown one at COMPILE time"
  ;; A step kind the macro cannot spell has to be hand-written JSON, which is
  ;; what kept the `review` kind unreachable for a year (CLS-14).
  (define emitted
    (let ()
      (define-workflow oe-demo
        #:input ([xs array])
        (step fan (map #:over (in xs) (tool list_notes) #:retry 1 #:on-error "continue") #:end))
      oe-demo))
  (check-equal? (hash-ref (car (hash-ref emitted 'steps)) 'on_error) "continue")
  ;; …and the closed vocabulary is checked where the error can point at the source
  (check-exn #rx"#:on-error must be one of"
             (lambda ()
               (convert-compile-time-error
                (let ()
                  (define-workflow oe-bad
                    #:input ([xs array])
                    (step fan (map #:over (in xs) (tool list_notes) #:on-error "ignore") #:end))
                  oe-bad)))))

(test-case "WF-16: a plugin can ship a SECOND version of a workflow"
  ;; FOUND WHILE FIXING #236, as its delivery mechanism. The guard asked whether
  ;; the team had a row for the SLUG at any version and the INSERT hardcoded
  ;; `version 1` whatever `#:version` said, so a bump was inert for every team
  ;; that had ever opened the Workflows tab — #113's shape, where the platform
  ;; records the right thing and nothing serves it.
  (define conn (fresh))
  (define p (owner-of conn))
  (define slug "wf16-demo")
  (define (spec-at v)
    (hasheq 'spec 1 'slug slug 'version v
            'steps (list (hasheq 'id "only" 'uses "tool:list_notes"))))
  ;; `register-plugin-workflow!` REPLACES by slug, which is what a plugin
  ;; shipping a new version does at load — so the box holds one spec and the
  ;; question is entirely what `materialize-plugin-defs!` does with it.
  (register-plugin-workflow! "wf16-plugin" (spec-at 1))
  (materialize-plugin-defs! conn (principal-team-id p))
  (check-equal? (hash-ref (flow-def-by-slug conn p slug) 'version) 1)
  ;; the plugin now ships v2 — the team has already looked, which is the state
  ;; every team using the feature is in
  (register-plugin-workflow! "wf16-plugin" (spec-at 2))
  (materialize-plugin-defs! conn (principal-team-id p))
  (check-equal? (hash-ref (flow-def-by-slug conn p slug) 'version) 2
                "the newest active version of a slug is what a run uses")
  ;; v1's row SURVIVES: #90 r3 put `version` on a run precisely so a run of a
  ;; since-superseded definition is distinguishable, and rewriting the old row's
  ;; spec in place would make every finished run's recorded version a lie
  (check-equal? (length (for/list ([d (in-list (flow-defs conn p))]
                                   #:when (equal? (hash-ref d 'slug) slug))
                          d))
                2 "a bump supersedes rather than rewrites"))

;; ---- WF-18: two maps in a row, the second over nothing --------------------------
;; A DEADLOCK, found by #191 slice 2 writing the first spec with a NON-TERMINAL
;; `map`. `complete-map!` held its own lock while calling `flow-advance!`, and an
;; advance into a `map` over an EMPTY list calls `complete-map!` again — same
;; thread, non-reentrant semaphore. The thread blocked for ever holding a claimed
;; job; its lease then expired, the reaper requeued it, and the next attempt
;; deadlocked another pool thread, so a team lost a slot per attempt with no
;; error anywhere. Every shipped spec's map is its LAST step, which is why no run
;; had ever advanced from one map into another.
;;
;; THE CASE IS RUN WITH A DEADLINE, IN A THREAD, because the failure mode is a
;; HANG and a `check-equal?` on a run that never finishes tells nobody anything.
;; This is the one place in these tests where the assertion is "it came back at
;; all".
;;
;; AND IT IS DELIBERATELY THE LAST CASE IN THIS FILE, which the positive control
;; is what taught: on a regression the deadline fires and the worker is killed
;; while holding `map-lock`, so the semaphore is never released and EVERY later
;; case that completes a map blocks too — the suite wedges instead of reporting
;; one failure. That is not a flaw in the test, it is what a process-wide lock
;; held by a stuck thread does, and it cannot be avoided from inside the same
;; process. Being last bounds the collateral to nothing. (The control confirmed
;; both halves: with the advance back inside the lock, this case does not return
;; and the run stays `running`.)
;; The second map's list is an INPUT passed as `'()`, which is exactly the shape a
;; drain has: the lister's output is a binding, and once the backlog is gone it is
;; the empty array.
(define-workflow empty-fan
  #:input ([subjects array] [nothing array])
  (step first (map #:over (in subjects) (tool create_note #:title (item) #:body "one")))
  (step second (map #:over (in nothing) (tool create_note #:title (item) #:body "two")))
  (step tally (tool list_notes) #:end))

(test-case "a map over an EMPTY list after another map does not deadlock the pool"
  (define conn (fresh))
  (define p (owner-of conn))
  (define d (flow-publish! conn p empty-fan))
  (define run (flow-run-start! conn p d #:input (hasheq 'subjects '("alpha") 'nothing '())))
  (define done (make-channel))
  (define worker (thread (lambda () (drain! conn) (channel-put done 'ok))))
  (define finished (sync/timeout 60 done))
  (unless finished (kill-thread worker))
  (check-equal? finished 'ok
                "the drain never returned — complete-map! re-entered its own lock (WF-18)")
  (define final (flow-run-get conn p (hash-ref run 'id)))
  (check-equal? (hash-ref final 'status) "done" (format "~a" (hash-ref final 'error 'null)))
  ;; …and the empty map is a settled step with an honest zero, not a skipped one
  (define second (findf (lambda (s) (equal? (hash-ref s 'step_id) "second")) (hash-ref final 'steps)))
  (check-true (and second #t) "the empty map ran as a step")
  (check-equal? (hash-ref second 'status) "done")
  (check-equal? (hash-ref (hash-ref second 'output) 'count) 0)
  (check-equal? (hash-ref (hash-ref second 'output) 'succeeded) 0)
  ;; WF-15 says a fan-out where NOTHING succeeded fails the run — and ZERO items
  ;; is not that case. `(positive? expected)` is what keeps the two apart, and it
  ;; matters for exactly this shape: a drain whose backlog is empty must report
  ;; success, or every re-run of a finished drain would error.
  (check-false (hash-has-key? (hash-ref second 'output) 'failures))
  ;; the step AFTER the empty map really did run, which is the whole point
  (check-true (and (findf (lambda (s) (equal? (hash-ref s 'step_id) "tally"))
                          (hash-ref final 'steps)) #t)))
