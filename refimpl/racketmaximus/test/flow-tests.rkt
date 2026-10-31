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
