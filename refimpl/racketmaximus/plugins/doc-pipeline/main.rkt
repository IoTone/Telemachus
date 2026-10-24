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

;; classify-and-extract (issue #87): the same tools, routed by TYPE.
;;
;;   classify  ->  the schema for THIS kind of document  ->  text  ->  fields
;;
;; A mixed inbox is the case this exists for: letters, invoices and photographs
;; under one prefix, where one schema cannot serve all three and `doc_text ->
;; doc_extract_fields` had to be told in advance which it was reading.
;;
;; THE CLASSIFICATION COMES BEFORE THE TEXT, and that order is the whole reason
;; `text` is optional on `doc_classify`. `doc_text` RAISES for a scan, a
;; photograph and anything else with no text layer — correctly, because somebody
;; is waiting for fields — so a pipeline that reads the document first cannot
;; classify the documents that most need classifying. Put the other way round, a
;; content-type rule answers "photo" without reading a byte, and the text is read
;; only on a branch that is about to extract from it. The first version of this
;; workflow had `text` first and its own test is what found it.
;;
;; THERE IS NO `switch` STEP KIND, and there must not be. The issue writes the
;; routing as switch(doc.type); `choice` CHAINS into exactly that, and adding a
;; kind is a spec-version change (WF-10 refuses an unknown one, deliberately) for
;; sugar over two lines. The chain also makes the fall-through explicit, which a
;; switch would hide: a `photo` reaches neither extraction and the run ENDS —
;; right, because a photograph has no fields, and the type is on the document
;; either way.
;;
;; `labels`, `rules` and `schemas` are input, so a team configures its own types
;; without new code. `rules` may be `[]` (then the model decides every document);
;; `schemas` is keyed by label, which is what `(in schemas invoice)` reads.
(define-workflow classify-and-extract
  #:name "Classify a document, then extract its fields"
  #:description "Decide which kind of document this is (deterministic rules first, then the model), record the type on the document, and extract fields against the schema for THAT type. A type with no schema is classified and left alone."
  #:input ([object_id string] [labels array] [rules array] [schemas object])
  #:max-steps 20

  (step classify (tool doc_classify #:object (in object_id)
                                    #:labels (in labels) #:rules (in rules)
                                    #:run (run-id) #:step "classify"))
  (step is_invoice (choice (eq (out classify result label) "invoice")
                           #:then invoice_text #:else is_letter))
  ;; each branch reads the document it is about to extract from. One shared
  ;; `text` step would have to run before the routing, which is what this
  ;; workflow deliberately does not do.
  (step invoice_text (tool doc_text #:object (in object_id)))
  (step invoice_fields (tool doc_extract_fields #:text (out invoice_text result)
                                                #:schema (in schemas invoice)
                                                #:object (in object_id)
                                                #:run (run-id) #:step "invoice_fields")
                       #:retry 1 #:end)
  (step letter_text (tool doc_text #:object (in object_id)))
  (step letter_fields (tool doc_extract_fields #:text (out letter_text result)
                                               #:schema (in schemas letter)
                                               #:object (in object_id)
                                               #:run (run-id) #:step "letter_fields")
                      #:retry 1 #:end)
  ;; `is_letter` IS LAST ON PURPOSE. A `choice` with no `#:else` does not end the
  ;; run — it falls through to the next step IN LIST ORDER (`step-next`), so
  ;; written anywhere else this would have sent a photograph into the letter
  ;; branch, where `doc_text` fails on an image. For the LAST step there is no
  ;; next, so the cursor empties and the run finishes: that is the fall-through
  ;; for a type with no schema. Its own test is what found this, by failing with
  ;; "step 'letter_text' failed: cannot read mixed/c.jpg as image/jpeg".
  (step is_letter (choice (eq (out classify result label) "letter") #:then letter_text)))

(define workflows (list process-upload classify-and-extract))
