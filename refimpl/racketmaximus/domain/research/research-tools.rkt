#lang racket/base

;; domain/research/research-tools.rkt — which bookmarks are behind (#191 slice 2).
;;
;; THE SURPRISE OF THIS SLICE IS HOW LITTLE IT NEEDS, and the measurement is in
;; `test/research-distil-tests.rkt`: an archived page already reaches the
;; knowledge graph through the SHIPPED drains with no research-specific code at
;; all. `text/html` is in `extract.rkt`'s markup list, so Index Documents reads
;; it; `kg-list-unextracted` excludes only DERIVED documents and an archive is
;; deliberately not one, so Index Knowledge extracts from it; and the mention
;; that lands names the archived page AND the version it was read from, which is
;; RG-5's whole promise. So "the graph fills by itself" is now asserted rather
;; than claimed.
;;
;; WHAT IS ACTUALLY MISSING IS THE QUESTION, not the work: nothing answers "which
;; bookmarks are still behind". The shipped drains are keyed on the whole team's
;; documents, so an operator who has just bookmarked twelve pages cannot distil
;; THOSE without draining everything else at the same batch size — which is
;; exactly the argument `embed-documents` already makes for existing as its own
;; workflow ("an operator can drain the text backlog and the vector backlog at
;; different rates, which is what they will want: one is free and one spends the
;; AI budget"). Here text extraction is free and fact extraction spends the AI
;; budget, so the argument lands the same way.
;;
;; NO MARKER OF ITS OWN (RG-4: "the distillation produces nothing new in the
;; schema"). Being behind is a JOIN against the markers the document already
;; carries — `repo_text` for the text and `kg_extractions` for the facts — never
;; a `distilled` column on `research_sources`, which would be a second copy of a
;; decision the next re-fetch re-makes and could disagree with the document.

(require db-kit/portable
         racket/string
         "../tools/dsl.rkt"
         "../agent/registry.rkt"
         (only-in "../authz/authz.rkt" require-perm principal-team-id)
         (only-in "../repo/repo.rkt" repo-readable?)
         (only-in "../repo/extract.rkt" repo-text-for))

(provide RESEARCH-STALE-SCAN RESEARCH-STALE-BATCH list-stale)

;; The window is bounded in SQL and the answer is filtered in Racket, so the
;; limit bounds the SCAN rather than the answer — `repo-list`'s rule, and
;; CLS-27's reason for reporting a short page honestly.
(define RESEARCH-STALE-SCAN 200)
;; Smaller than the text indexer's 40 for CLS-24's measured reason: every item
;; here may become a model request against a 200/day `ai.requests` default,
;; because the second half of a distillation is `kg_extract`.
(define RESEARCH-STALE-BATCH 25)

(define-tool research_list_stale
  #:description "List bookmarked URLs whose archived page is still behind: the text has not been extracted for search yet, or it has and no facts have been taken out of it for the knowledge graph. Returns repository object ids — the archived pages, not the bookmark rows — capped at a batch; run the workflow again to continue. A page that was read and had no text in it is NOT listed, because it would otherwise be offered for ever.")
;; Deliberately no arguments. A prefix or a limit would be a knob on a drain whose
;; whole shape is "find what is behind, in one team"; the batch is the platform's
;; because it is sized against `ai.requests`.

(define (list-stale conn p args)
  (require-perm conn p "research:use")
  (require-perm conn p "files:read")
  ;; ONE statement, and the two halves of "behind" are the two LEFT JOINs:
  ;;   • no `repo_text` row for the current version          -> needs extracting
  ;;   • a `repo_text` row and no `kg_extractions` row       -> needs distilling
  ;; An archive whose text row exists and is EMPTY is the case that has to be
  ;; excluded or the drain never terminates — see below, where it is done in
  ;; Racket because it cannot be done here.
  (define rows (query-rows conn
    (string-append
     "SELECT o.id, (CASE WHEN t.object_id IS NULL THEN 0 ELSE 1 END) AS has_text "
     "FROM research_sources s "
     "JOIN repo_objects o ON o.id = s.object_id AND o.deleted_at IS NULL "
     "LEFT JOIN repo_text t ON t.object_id = o.id AND t.version_id = o.current_version_id "
     "LEFT JOIN kg_extractions x ON x.object_id = o.id AND x.version_id = o.current_version_id "
     "WHERE s.team_id = ? AND s.active = 1 "
     "  AND (t.object_id IS NULL OR x.object_id IS NULL) "
     "ORDER BY s.fetched_epoch ASC, o.id LIMIT ?")
    (principal-team-id p) RESEARCH-STALE-SCAN))
  (let loop ([rs rows] [out '()])
    (cond
      [(null? rs) (reverse out)]
      [(>= (length out) RESEARCH-STALE-BATCH) (reverse out)]
      [else
       (define id (vector-ref (car rs) 0))
       (define has-text? (= 1 (vector-ref (car rs) 1)))
       ;; Readability FIRST, because it is a cheap indexed read where the blank
       ;; test unseals a whole page — and because it is not an optimisation: a
       ;; colleague's private archive listed here would fail the step that
       ;; follows and with it the run, which is the defect #189 step 4 found in
       ;; `repo_list_unindexed` and fixed with this same predicate.
       (define ok?
         (and (repo-readable? conn p id)
              (or (not has-text?)
                  ;; A TEXT ROW THAT IS EMPTY MEANS "WE LOOKED AND THERE WAS
                  ;; NOTHING", AND THE DRAIN MUST NOT OFFER IT AGAIN.
                  ;; `repo_extract_text` records an unreadable document as
                  ;; processed-with-nothing, deliberately, so one bad page cannot
                  ;; wedge a team's indexing — and `kg-list-unextracted` then
                  ;; declines it (`t.content <> ''`), so it can never acquire a
                  ;; `kg_extractions` row. Without this clause it would be listed
                  ;; by every run for ever, and an operator draining until the
                  ;; workflow finds nothing would never finish (VEC-23).
                  ;;
                  ;; IT CANNOT BE A SQL TEST, and that is forced by #83: under
                  ;; `TMACH_ENCRYPT_CONTENT` the stored content is a sealed
                  ;; string, so an empty text is NOT an empty column and
                  ;; `t.content <> ''` is TRUE for it. A check that worked on the
                  ;; documented default and silently stopped working on a sealed
                  ;; instance is this codebase's dialect-divergence class wearing
                  ;; another hat.
                  ;;
                  ;; THE HONEST CONSEQUENCE, STATED: a single-page application
                  ;; archives as its loader shell (RG-2), which extracts to
                  ;; nothing — so such a bookmark is archived, versioned and
                  ;; searchable by its URL and title, and is never offered for
                  ;; distillation. That is the right answer and it is why RG-2
                  ;; says the remedy is a reader-mode copy the person uploads.
                  (let ([text (repo-text-for conn id)])
                    (and (string? text) (not (string=? (string-trim text) "")))))))
       (loop (cdr rs) (if ok? (cons id out) out))])))

;; A WORKFLOW TOOL, NOT A CONVERSATIONAL ONE (`#:agent? #f`), for the rule the
;; agent-window gate established: a drain LISTER exists to hand a `map` step a
;; page of ids, and an answer that is a JSON array of uuids is of no use to a
;; model talking to a person — while its schema would spend room in a window the
;; four tools the system prompt names actually need. It stays dispatchable by a
;; workflow step, which is its only caller.
;;
;; `research:use` is the permission, not `files:read`: the question is about the
;; research surface, and RG-11's split is that `research:use` governs the surface
;; while the resource permissions govern the documents. The handler asks for both.
(register-tool! "research_list_stale" research_list_stale "research:use" list-stale
                #:agent? #f)
