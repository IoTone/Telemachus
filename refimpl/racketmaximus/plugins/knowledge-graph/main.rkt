#lang racket/base

;; knowledge-graph — the extraction workflow (slice 61). Like doc-indexer it
;; contains NO extraction code: the tools live in domain/kg/kg-tools.rkt and the
;; engine supplies durability, retries, cancel, quota admission and the org gate.
;; The composition:
;;
;;   find what is unextracted  ->  fan out  ->  extract each, once, with one retry
;;
;; It reads repo_text, so `index-documents` must have run first; a document with
;; no text is marked extracted-with-nothing and not listed again for that version.
;; Re-running is always safe; a batch is 40, so a large backlog is drained by
;; running until it finds nothing.

(require "../../domain/flow/dsl.rkt"
         "../../domain/kg/kg-tools.rkt")   ; registers the tools on load

(provide workflows)

(define-workflow index-knowledge
  #:name "Index Knowledge"
  #:description "Extract entities and relations from indexed repository documents into the knowledge graph. Finds what is unextracted (or stale after an overwrite), then extracts each one with the model; a reply that does not validate is refused. Safe to re-run; processes up to 40 documents per run."
  #:version 2
  #:max-steps 50
  (step find (tool kg_list_unextracted))
  ;; WF-17, AND THIS IS THE WORKFLOW #236 WAS REPORTED AGAINST. Observed on the
  ;; demo: thirteen documents, child `extract#1` errored, children #2 through
  ;; #11 left `queued` carrying an error they never acted on — while
  ;; `index-documents` over the same thirteen completed 7 of 7, because its
  ;; extractor records an unreadable file rather than raising.
  ;;
  ;; KG-3's refusal is CORRECT and is not what changes: nothing enters the graph
  ;; without a verbatim snippet, and a model that cannot produce one for THIS
  ;; document says nothing about the other twelve. What changes is only what that
  ;; refusal does to its siblings.
  (step extract (map #:over (out find result)
                     (tool kg_extract #:object (item))
                     #:retry 1 #:on-error "continue")
        #:end))

(define workflows (list index-knowledge))
