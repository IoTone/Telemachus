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
         "../../domain/repo/index-tools.rkt"    ; registers the two text tools on load
         "../../domain/repo/embed-tools.rkt")   ; …and the two chunk-vector ones (#189 step 4)

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


;; #189 step 4, and it is a SECOND workflow rather than two more steps above
;; (VEC-24). A step that errors fails the RUN, and `repo_embed_chunks` refuses
;; without `TMACH_EMBED_URL` — which is unset on every instance today — so
;; appending it to `index-documents` would make text indexing start failing
;; everywhere the moment this landed. Separate specs also means an operator can
;; drain the text backlog and the vector backlog at different rates, which is
;; what they will want: one is free and one spends the AI budget.
;;
;; It takes the text index as given rather than extracting: a chunk's offsets are
;; offsets into `repo_text.content` (CHUNK-1), so the two workflows run in order
;; — Index Documents, then this.
(define-workflow embed-documents
  #:name "Embed Documents"
  #:description "Chunk the extracted text of repository documents and store an embedding per chunk, for semantic retrieval. Finds documents whose text has no vectors for the current version (or vectors from a different model), then embeds each one. Needs TMACH_EMBED_URL. Safe to re-run; processes up to 25 documents per run and spends the team's embedding budget."
  #:max-steps 35                       ; find + map parent + a full batch of 25, with room
  (step find (tool repo_list_unembedded))
  (step embed (map #:over (out find result)
                   (tool repo_embed_chunks #:id (item))
                   #:retry 1)
        #:end))

(define workflows (list index-documents embed-documents))
