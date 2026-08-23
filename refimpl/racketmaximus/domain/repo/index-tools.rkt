#lang racket/base

;; domain/repo/index-tools.rkt — the two tools the document-indexing workflow is
;; made of (slice 54). Registered at module level like the built-in catalog, so
;; requiring this module is all it takes for a workflow — or the agent — to see them.
;;
;; This is the payoff for WF-1: "extract text from every new document and index it"
;; is not new machinery, it is two tools and a spec. The workflow that composes them
;; ships in plugins/doc-indexer/, and everything the engine already does — retries,
;; cancel, quota admission, the org gate, per-step RBAC — applies without a line of
;; code here knowing about it.
;;
;; CONTRACT NOTE: `repo_list_unindexed` returns a jsexpr LIST, not a string. A
;; workflow's `map #:over` needs a real array, and a whole-string binding reference
;; preserves the value's type, so the list survives the trip through the step's
;; stored output. The agent surface JSON-encodes non-string results at its boundary
;; (dispatch-tool), so a model that calls this tool sees a JSON array in text form.

(require db-kit/portable racket/string
         "../tools/dsl.rkt"
         "../agent/registry.rkt"
         "../authz/authz.rkt"
         "repo.rkt"
         "extract.rkt")

(provide LIST-BATCH)   ; the tests pin the batch cap

;; Bounded so one workflow run is one bounded fan-out; the workflow is re-runnable
;; and the next run picks up where this one stopped. max_steps would refuse an
;; unbounded fan-out anyway — better to never offer one.
(define LIST-BATCH 40)

(define-tool repo_list_unindexed
  #:description
  "List repository documents whose text has not been extracted for search yet (or is stale after an overwrite). Returns object ids, capped at a batch; run the indexing workflow again to continue.")

(define-tool repo_extract_text
  #:description "Extract the text of one repository document into the search index."
  (id string #:description "The repository object id"))

;; every object whose CURRENT version has no matching repo_text row — which covers
;; both never-indexed and re-written-since-indexed, because the row is keyed to the
;; version it came from
(define (list-unindexed conn p args)
  (require-perm conn p "files:read")
  (define rows (query-rows conn
    (string-append
     "SELECT o.id, COALESCE(v.content_type, '') "
     "FROM repo_objects o "
     "JOIN repo_versions v ON v.id = o.current_version_id "
     "LEFT JOIN repo_text t ON t.object_id = o.id AND t.version_id = o.current_version_id "
     "WHERE o.team_id = ? AND o.deleted_at IS NULL AND t.object_id IS NULL "
     "ORDER BY o.updated_at ASC LIMIT ?")
    (principal-team-id p) LIST-BATCH))
  ;; unsupported types are filtered HERE, not in the map — an image would otherwise
  ;; be "unindexed" forever and every run would fan out over it again
  (for/list ([r (in-list rows)]
             #:when (extractable? (vector-ref r 1)))
    (vector-ref r 0)))

(define (extract-one conn p args)
  (define id (hash-ref args 'id ""))
  ;; repo-open is the authorized read path: the org gate, visibility and grants all
  ;; apply, so a workflow can only ever index what its starter could read
  (define-values (o in) (repo-open conn p id))
  (unless in (error 'repo_extract_text "no such object: ~a" id))
  (define-values (text reason)
    (dynamic-wind void
                  (lambda () (extract-text in (hash-ref o 'content_type)))
                  (lambda () (close-input-port in))))
  (cond
    [text
     (repo-text-upsert! conn id (hash-ref o 'version_id) text)
     (format "indexed ~a (~a characters)" (hash-ref o 'key) (string-length text))]
    [(eq? reason 'missing-tool)
     ;; a real error, so the step FAILS and the run says why — an operator installs
     ;; poppler and re-runs, rather than discovering months later that no PDF was
     ;; ever searchable
     (error 'repo_extract_text
            "pdftotext is not installed — PDF text extraction needs poppler-utils")]
    [else
     ;; A document that CANNOT be read — corrupt, or mislabeled as a type it is not —
     ;; is recorded as processed-with-nothing rather than raised. Raising would fail
     ;; the run, and the next run would list the same object and fail again: one bad
     ;; file would wedge indexing for the whole team, forever. An empty row matches
     ;; no search and, keyed to this version, stops the object being re-listed; a
     ;; re-upload makes it eligible again.
     (repo-text-upsert! conn id (hash-ref o 'version_id) "")
     (format "skipped ~a — unreadable as ~a (~a)"
             (hash-ref o 'key) (hash-ref o 'content_type) reason)]))

(register-tool! "repo_list_unindexed" repo_list_unindexed "files:read" list-unindexed)
(register-tool! "repo_extract_text" repo_extract_text "files:write" extract-one)
