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
  #:max-steps 50
  (step find (tool kg_list_unextracted))
  (step extract (map #:over (out find result)
                     (tool kg_extract #:object (item))
                     #:retry 1)
        #:end))

(define workflows (list index-knowledge))
