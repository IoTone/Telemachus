#lang racket/base

;; research — #191 slice 2, and it is a COMPOSITION with no new work in it.
;;
;; THE FINDING FIRST, BECAUSE IT DECIDES HOW SMALL THIS IS. An archived bookmark
;; already reaches the knowledge graph through the SHIPPED drains with no
;; research-specific code: `text/html` is in `extract.rkt`'s markup list so Index
;; Documents reads it, `kg-list-unextracted` excludes only DERIVED documents and
;; an archive is deliberately not one so Index Knowledge extracts from it, and
;; the mention that lands names the archived page AND the version it was read
;; from. `test/research-distil-tests.rkt` asserts that end to end through those
;; very specs, so RG-5's "the graph fills by itself" is a measured property
;; rather than a claim.
;;
;; SO WHAT THIS WORKFLOW ADDS IS A RATE AND A SCOPE, which is precisely the
;; argument `embed-documents` already makes for existing separately: "an operator
;; can drain the text backlog and the vector backlog at different rates, which is
;; what they will want: one is free and one spends the AI budget". Here the first
;; step is free and the second spends the AI budget, and the thing an operator
;; has just done is bookmark twelve pages — not upload twelve documents. Without
;; this they would have to drain the whole team's backlog at the text indexer's
;; batch of 40 and the graph drain's of 40 to get at those twelve.
;;
;; TWO MAPS OVER THE SAME ID LIST, not one map over three tools, because `map`
;; fans out over ONE tool (the engine ships `tool:`, `choice` and `map`; `flow:`
;; is deferred). Both steps bind `(out find result)`, which is the list the lister
;; answered — so the second step does not depend on the first's output shape, and
;; a page whose extraction failed is simply one `kg_extract` declines.
;;
;; `doc_classify` IS NOT HERE, and RG-4 named it. It needs a `labels` list, which
;; is a team's own vocabulary and a spec-authored literal (CLS-5) — there is no
;; label set a research plugin could supply that would be right for anybody, and
;; guessing one would write `doc_type` values no trigger and no `?attr=` filter
;; will ever match. Classifying bookmarks is `classify-backfill` with the team's
;; own labels, which already exists.

;; THE THREE TOOL MODULES ARE REQUIRED FOR THEIR SIDE EFFECT and for nothing
;; else — each registers its tools on instantiation. So they are required with an
;; EMPTY `only-in`, which is this tree's idiom for exactly that (#110 r3 records
;; what happens when a computed import list drops such a line: the tool stays
;; registered anyway, because some other loaded plugin requires it, so the
;; omission only bites on an instance that does NOT load that plugin — which is
;; the case nothing tests). It also avoids a collision that a plain require
;; produces here: `index-tools.rkt` and `kg-tools.rkt` both export `LIST-BATCH`.
(require "../../domain/flow/dsl.rkt"
         (only-in "../../domain/research/research-tools.rkt")   ; research_list_stale
         (only-in "../../domain/repo/index-tools.rkt")          ; repo_extract_text
         (only-in "../../domain/kg/kg-tools.rkt"))              ; kg_extract

(provide workflows)

(define-workflow distil-bookmarks
  #:name "Distil Bookmarks"
  #:description "Take what is in the archived pages of bookmarked URLs: extract their text for search, then extract entities and relations into the knowledge graph. Finds the bookmarks whose archive is still behind — never extracted, or re-fetched since — and leaves the rest alone. A page that was read and had no text in it is not offered again. Safe to re-run; processes up to 25 bookmarks per run and the second half spends the team's AI budget."
  #:version 1
  #:max-steps 60                       ; find + two map parents + two batches of 25, with room
  (step find (tool research_list_stale))
  ;; WF-17: both halves are DRAINS over a backlog rather than fan-outs over a
  ;; list somebody named, so `on_error: "continue"` — one awkward page must not
  ;; stop the other eleven, which is #236's whole complaint. The step still
  ;; reports `succeeded`, `failed` and a reason per failure; a drain where
  ;; NOTHING succeeded still fails the run (WF-15), and a misconfiguration still
  ;; fails on the first child (WF-14), which is how "no model configured" arrives
  ;; once rather than twenty-five times.
  (step text (map #:over (out find result)
                  (tool repo_extract_text #:id (item))
                  #:retry 1 #:on-error "continue"))
  ;; OVER THE SAME LIST, deliberately — not over the previous step's output. The
  ;; lister answered "these are behind"; a page whose extraction just failed is
  ;; one `kg_extract` declines for its own reason, and threading the first map's
  ;; results through would make the second step depend on a shape WF-11 defines
  ;; as positional-with-nulls rather than on the ids it actually wants.
  ;; `#:object`, NOT `#:id` — and the two tools this spec chains disagree about
  ;; the name, `repo_extract_text` taking `id`. Worth knowing why that is only
  ;; caught at run time: `validate-spec` refuses an unknown FIELD of a step and
  ;; `check-input!` requires every declared workflow INPUT, but nothing checks a
  ;; tool step's bindings against the tool's own schema — so a wrong keyword is a
  ;; binding the tool simply never sees, and arrives as "no such document: " with
  ;; nothing after the colon. The test is what caught it.
  (step facts (map #:over (out find result)
                   (tool kg_extract #:object (item))
                   #:retry 1 #:on-error "continue")
        #:end))

(define workflows (list distil-bookmarks))
