# Workflows


## The spec is the contract

A workflow is a validated data document: a slug, typed inputs, and steps that use a tool, branch on a predicate, or fan out over a list. `define-workflow` is a macro that emits that document; a JSON document posted to the API goes through the same validator, and there is no second path. Unknown fields are rejected, including a newer spec version and a step kind this build lacks. The binding sublanguage is frozen — references and seven predicates, no arithmetic, no evaluation — and the escape hatch is “write a tool”.

    (define-workflow process-upload
      #:input ([object_id string] [schema object] [template string] [locales array])
      (step text     (tool doc_text #:object (in object_id)))
      (step fields   (tool doc_extract_fields #:text (out text result) #:schema (in schema)
                                              #:object (in object_id) #:run (run-id) #:step "fields")
                     #:retry 1)
      (step has_form (choice (empty (in template)) #:then translate_source #:else form))
      (step form     (tool doc_render #:template (in template)
                                      #:data (out fields result fields) ...))
      (step translate_form (map #:over (in locales)
                                (tool doc_translate #:object (out form result object_id)
                                                    #:locale (item) ...))
            #:end)
      ...)

## Execution is a reducer

The engine keeps nothing in memory. `flow-advance!` reads a run from the database and enqueues its next step as a scheduler job; when the job finishes, the step’s output is written and the cursor moves. Durability, cancellation, quota admission, per-team concurrency caps and the org gate are therefore inherited from the scheduler rather than reimplemented. A fan-out is one parent row and N child jobs; the last child to finish advances the cursor under a lock, or two children would each enqueue the next step.

Declared inputs are required and typed; a run that omits one is refused at start rather than resolving a binding to null three steps in. Plugin-contributed workflows are materialized into a team’s definitions on first lookup; that insert is idempotent because the console fires two lookups in parallel and the second once produced a 500 — found by the end-to-end gate, not by any smoke that looked things up one at a time.

## Files to open

`domain/flow/spec.rkt` (normative), `domain/flow/dsl.rkt`, `domain/flow/bind.rkt`, `domain/flow/run.rkt`, `docs/design/workflow-engine.md`, `docs/reference/workflows.md`.
