#lang racket/base

;; doc-indexer — the slice-54 payoff plugin. It contains NO extraction code and NO
;; scheduling code: the tools live in the core (domain/repo/index-tools.rkt) and the
;; engine supplies durability, retries, cancel, quota admission and the org gate.
;; What a plugin contributes is the COMPOSITION, as a spec anyone can read:
;;
;;   find what is unindexed  ->  fan out  ->  extract each, once, with one retry
;;
;; Re-running is always safe: `repo_list_unindexed` keys staleness to the current
;; version, so a finished run followed by another run does nothing; an overwrite
;; makes exactly that object eligible again. A batch is capped at 40, so a large
;; backlog is drained by running the workflow until it finds nothing — which is a
;; loop an operator (or a cron job) drives, visibly, rather than a daemon nobody
;; can see.

(require "../../domain/flow/dsl.rkt"
         "../../domain/repo/index-tools.rkt")   ; registers the two tools on load

(provide workflows)

(define-workflow index-documents
  #:name "Index Documents"
  #:description "Extract text from repository documents into the search index. Finds what is unindexed (or stale after an overwrite), then extracts each one. Safe to re-run; processes up to 40 documents per run."
  #:max-steps 50                       ; find + map parent + a full batch of 40, with room
  (step find (tool repo_list_unindexed))
  (step extract (map #:over (out find result)
                     (tool repo_extract_text #:id (item))
                     #:retry 1)
        #:end))

(define workflows (list index-documents))
