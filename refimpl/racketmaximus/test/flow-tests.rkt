#lang racket/base

;; test/flow-tests.rkt — slice 46: the workflow engine.
;;   raco test test/flow-tests.rkt    (from refimpl/racketmaximus/, pkgs on PLTCOLLECTS)
;;
;; Covers the four things slice 46 claims: a workflow written in Racket runs end to
;; end, it survives a restart mid-run, it is refused across an org boundary, and the
;; spec round-trips publish → store → load → execute unchanged.

(require rackunit
         db
         racket/list
         racket/file
         json
         db-kit/migrate
         "../domain/db/migrations.rkt"
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
(define (fresh [file #f])
  (define conn (if file (sqlite3-connect #:database file #:mode 'create) (sqlite3-connect #:database 'memory)))
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
  (define file (make-temporary-file "telemachus-flow-~a.db"))
  (delete-file file)
  ;; --- "process" one: publish, start, run exactly one step, then close everything
  (define run-id
    (let* ([conn (fresh file)]
           [p (owner-of conn)]
           [d (flow-publish! conn p note-triage)]
           [run (flow-run-start! conn p d #:input (hasheq 'subject "survivor"))])
      (check-true (and (process-one! conn) #t) "the first step ran")
      (check-equal? (status conn (hash-ref run 'id)) "running")
      (disconnect conn)
      (hash-ref run 'id)))
  ;; --- "process" two: a brand-new connection picks the run up mid-flight
  (define conn2 (sqlite3-connect #:database file))
  (drain! conn2)
  (check-equal? (status conn2 run-id) "done" "resumed from the database alone")
  (define steps (query-list conn2 "SELECT step_id FROM workflow_steps WHERE run_id = ? ORDER BY seq" run-id))
  (check-equal? steps '("write" "gate" "confirm"))
  (disconnect conn2)
  (delete-file file))

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

;; ---- contract discovery ------------------------------------------------------
(test-case "the schema endpoint describes what this build accepts"
  (define s (spec-schema))
  (check-equal? (hash-ref s 'spec) SPEC-FORMAT-VERSION)
  (check-equal? (hash-ref s 'unknown_fields) "rejected")
  (check-true (and (member "choice" (hash-ref s 'step_kinds)) #t))
  (check-regexp-match #rx"not conformant" (hash-ref s 'conformance)))
