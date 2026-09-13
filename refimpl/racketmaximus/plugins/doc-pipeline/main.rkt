#lang racket/base

;; doc-pipeline — the first-user path (slice 57, DWF-8): a team uploads a file and
;; a workflow processes it. Like doc-indexer, this plugin contains NO tool code:
;; the four tools live in the core (domain/repo/doc-tools.rkt) and the engine
;; supplies durability, retries, cancel, quota admission and the org gate. What the
;; plugin contributes is the COMPOSITION, as a spec anyone can read:
;;
;;   text  ->  fields (validated against the schema)  ->  form  ->  translations
;;
;; `schema`, `template` and `locales` are INPUT, so one workflow serves invoices
;; and intake forms with different configuration and no new code. Two of them may
;; be empty, in the obvious way: no `template` ("") skips the form and translates
;; the SOURCE instead; no `locales` ([]) stops after the form. All four inputs are
;; declared, so a run that omits one is refused at start rather than resolving a
;; binding to null three steps in.
;;
;; Every step names the run and its own id, so each output's `repo_derivations`
;; row says which run and which step made it.

(require "../../domain/flow/dsl.rkt"
         "../../domain/repo/doc-tools.rkt")   ; registers the four tools on load

(provide workflows)

(define-workflow process-upload
  #:name "Process an uploaded document"
  #:description "Extract text, pull structured fields against a JSON schema (refused if they do not conform), fill a form template, and translate the result into the team's languages. Every output is a repository document beside the source, with provenance."
  #:input ([object_id string] [schema object] [template string] [locales array])
  #:max-steps 40

  (step text      (tool doc_text #:object (in object_id)))
  ;; one retry: a schema mismatch is the model's mistake, and a second reading at
  ;; temperature 0 often conforms; a third would not
  (step fields    (tool doc_extract_fields #:text (out text result) #:schema (in schema)
                                           #:object (in object_id) #:run (run-id) #:step "fields")
                  #:retry 1)
  (step has_form  (choice (empty (in template)) #:then translate_source #:else form))
  (step form      (tool doc_render #:template (in template) #:data (out fields result fields)
                                   #:object (in object_id) #:run (run-id) #:step "form"))
  (step translate_form (map #:over (in locales)
                            (tool doc_translate #:object (out form result object_id) #:locale (item)
                                                #:run (run-id) #:step "translate")
                            #:retry 1)
        #:end)
  (step translate_source (map #:over (in locales)
                              (tool doc_translate #:object (in object_id) #:locale (item)
                                                  #:run (run-id) #:step "translate")
                              #:retry 1)
        #:end))

(define workflows (list process-upload))
