#lang racket/base

;; domain/repo/embed-tools.rkt — the two tools the chunk-embedding workflow is
;; made of (#189 step 4, decisions VEC‑18…24).
;;
;; `index-tools.rkt`'s shape, one layer along: find what has text but no
;; vectors, then embed each one. The composition ships in `plugins/doc-indexer/`
;; as a SECOND workflow beside `index-documents`, and everything the engine
;; already does — retries, cancel, quota admission, the org gate, per-step
;; RBAC — applies without a line here knowing about it.
;;
;; VEC‑24 — A SECOND WORKFLOW, NOT TWO MORE STEPS ON `index-documents`, and the
;; build plan's own words are what it is weighed against: "as a step in the
;; existing indexing workflow rather than a new seam". The seam is what that
;; sentence is about — no daemon, no new execution path, the plugin's spec and
;; the core's tools — and this is that. What it is NOT is two steps appended to
;; the published `index-documents` spec, because a step that errors FAILS THE
;; RUN: on every instance with no `TMACH_EMBED_URL` — which is every instance
;; today — text indexing would start failing the moment this landed. The
;; precedent is `classify-backfill` (CLS‑24), a separate spec rather than a flag
;; on a published one, for the same reason adding an INPUT to a published spec is
;; a breaking change.
;;
;; This module is deliberately separate from `index-tools.rkt`, whose two tools
;; reach no model: these are model-backed, metered and quota-admitted, so the
;; requires of each module stay honest about what it needs.

(require db-kit/portable racket/list
         (only-in racket/string string-trim)
         "../tools/dsl.rkt"
         "../agent/registry.rkt"
         "../authz/authz.rkt"
         (only-in "../ai/executor.rkt" embed-configured? embed-model)
         (only-in "../ai/chunk.rkt" chunk-text chunk-blank?)
         (only-in "../ai/chunkstore.rkt"
                  chunks-replace! chunks-count chunks-model-for CHUNK-EMBED-BATCH)
         (only-in "doc-tools.rkt" current-doc-embed meter-embed!)
         (only-in "extract.rkt" repo-text-for repo-text-version-for)
         "repo.rkt")

(provide EMBED-BATCH EMBED-SCAN REVISIT-CHUNKS)   ; the tests pin all three

;; `LIST-BATCH`'s reason, with the model's cost added: every document here is at
;; least one embedding request, and `ai.requests` defaults to 200/day. 40 would
;; make five runs exhaust a team's day on requests alone.
(define EMBED-BATCH 25)

;; CLS‑27's shape. The lister has a filter it cannot express in SQL (below), so a
;; page can contribute fewer ids than it holds, and "this page was short" cannot
;; be told from "this is the last page" without a wider window to look at.
(define EMBED-SCAN 200)

;; `vector-store.md`'s "When to revisit" is a NUMBER rather than "if it gets
;; slow": 50,000 chunks for one team, which is where the scan crosses half a
;; second. It is here, beside the count, because the design asks for it to be
;; something an operator can SEE — so the write tool reports the team's total and
;; says when it is past.
(define REVISIT-CHUNKS 50000)

(define-tool repo_list_unembedded
  #:description
  "List repository documents whose extracted text has no chunk embeddings yet for the current version, or whose embeddings are from a different model. Returns object ids, capped at a batch; run the workflow again to continue.")

(define-tool repo_embed_chunks
  #:description "Chunk one repository document's extracted text and store an embedding per chunk, replacing any previous set for that version."
  (id string #:description "The repository object id"))

;; ---- the lister --------------------------------------------------------------

;; THE REFUSAL IS HERE RATHER THAN IN THE MAP, which is the same call
;; `repo_list_unindexed` makes about an unsupported content type and
;; `repo_extract_text` makes about a missing `pdftotext`. With no embedding
;; endpoint the lister would otherwise hand back 25 ids and the run would fail 25
;; times for one unset variable; failing at step one names it once.
(define (require-embedder! who)
  (unless (embed-configured?)
    (error who
           (string-append "no embedding model configured — set TMACH_EMBED_URL "
                          "(and TMACH_EMBED_MODEL, e.g. nomic-embed-text). "
                          "Text indexing does not need it; chunk embeddings do."))))

;; VEC‑23 — A DOCUMENT WITH BLANK TEXT IS FILTERED IN THE LISTER, and it has to
;; be filtered SOMEWHERE or the drain never terminates. `repo_extract_text`
;; records an unreadable document as processed-with-nothing — an empty
;; `repo_text` row, deliberately, so one corrupt file cannot wedge a team's
;; indexing — and the chunker answers zero chunks for an empty string, so such a
;; document can never acquire a vector row and would be listed by every run for
;; ever. That is index-tools' own objection to filtering in the map ("an image
;; would otherwise be unindexed forever and every run would fan out over it
;; again"), and here it also means an operator draining a backlog by running the
;; workflow until it finds nothing never finishes.
;;
;; IT CANNOT BE A SQL TEST, and that is forced by #83: under
;; `TMACH_ENCRYPT_CONTENT` the stored `content` is a sealed string, so an empty
;; text is NOT an empty column — `t.content <> ''` is true for it. A test that
;; worked on the documented default and silently stopped working on a sealed
;; instance is the dialect-divergence class this codebase already watches for,
;; wearing a different hat. So the window is bounded in SQL and the blank test is
;; made in Racket on the unsealed text, with `truncated` reporting both ways of
;; stopping.
(define (list-unembedded conn p args)
  (require-perm conn p "files:read")
  (require-embedder! 'repo_list_unembedded)
  (define model (embed-model))
  (define rows (query-rows conn
    (string-append
     "SELECT o.id "
     "FROM repo_objects o "
     "JOIN repo_text t ON t.object_id = o.id AND t.version_id = o.current_version_id "
     "LEFT JOIN repo_chunks c ON c.object_id = o.id "
     "  AND c.version_id = o.current_version_id AND c.model = ? "
     "WHERE o.team_id = ? AND o.deleted_at IS NULL AND c.id IS NULL "
     "ORDER BY o.updated_at ASC LIMIT ?")
    model (principal-team-id p) EMBED-SCAN))
  (let loop ([ids (for/list ([r (in-list rows)]) (vector-ref r 0))] [out '()])
    (cond
      [(null? ids) (reverse out)]
      [(>= (length out) EMBED-BATCH) (reverse out)]
      [else
       ;; readability FIRST: it is a cheap indexed read, where the blank test
       ;; unseals a document's whole text. And it is not an optimisation — a
       ;; colleague's private document listed here fails the step that follows,
       ;; and with it the run (see `repo-readable?`).
       (define ok?
         (and (repo-readable? conn p (car ids))
              (let ([text (repo-text-for conn (car ids))])
                (and (string? text) (not (chunk-blank? text))))))
       (loop (cdr ids) (if ok? (cons (car ids) out) out))])))

;; ---- the write ---------------------------------------------------------------

(define (embed-one conn p args)
  (define id (hash-ref args 'id ""))
  (require-embedder! 'repo_embed_chunks)
  ;; `repo-open` is the authorized read path — the org gate, visibility and
  ;; grants all apply — so a run can only ever embed what its starter could read.
  ;; The PORT is closed immediately: the bytes are not what is wanted here, the
  ;; extracted text is, and leaking a descriptor on a per-document step is the
  ;; measured failure `http-post-json`'s note already records.
  (define-values (o in) (repo-open conn p id))
  (unless in (error 'repo_embed_chunks "no such object: ~a" id))
  (close-input-port in)
  (require-perm conn p "files:write" #:resource (obj->resource o))
  (define version (repo-text-version-for conn id))
  (define text (repo-text-for conn id))
  ;; The text is read from `repo_text`, never re-extracted: a chunk's offsets are
  ;; offsets INTO THAT STRING (CHUNK‑1, and the coordinates `repo_text.spans`
  ;; uses), so re-extracting here would risk indexing one string and citing
  ;; another. "Run the indexing workflow first" is the honest refusal.
  (unless (and version (string? text))
    (error 'repo_embed_chunks
           "~a has no extracted text — run the Index Documents workflow first"
           (hash-ref o 'key)))
  (unless (equal? version (hash-ref o 'version_id))
    (error 'repo_embed_chunks
           (string-append "the extracted text of ~a is of an older version — run the Index "
                          "Documents workflow first, or the vectors would cite a string that "
                          "has changed")
           (hash-ref o 'key)))
  (define-values (chunks truncated?) (chunk-text text))
  (when (null? chunks)
    (error 'repo_embed_chunks "~a has no text to embed" (hash-ref o 'key)))
  (define model (embed-model))
  (define vectors (embed-all conn p chunks))
  (define n (chunks-replace! conn id version model chunks vectors))
  (define total (chunks-count conn (principal-team-id p)))
  (format "embedded ~a — ~a chunk(s) of ~a character(s) with ~a~a. The team now stores ~a chunk vector(s)~a."
          (hash-ref o 'key) n (string-length text) model
          (if truncated?
              (format ", stopping at the ~a-chunk cap (the rest of the document is not embedded)"
                      (length chunks))
              "")
          total
          (if (>= total REVISIT-CHUNKS)
              (format " — past the ~a at which `docs/design/vector-store.md` says to revisit the no-index decision"
                      REVISIT-CHUNKS)
              "")))

;; One request per `CHUNK-EMBED-BATCH` chunks, through the seam in `doc-tools.rkt`
;; so the egress policy, the request log and BOTH meters are the ones every other
;; embedding goes through. Metered per batch rather than once at the end: a run
;; that fails on its third batch has still spent the first two, and a meter that
;; only fires on success makes a failing document free to retry for ever (FEED‑9's
;; rule, which charges a fetch before making it).
(define (embed-all conn p chunks)
  (define embed (current-doc-embed))
  (append*
   (for/list ([batch (in-list (chunk-batches chunks CHUNK-EMBED-BATCH))])
     (define-values (vs toks) (embed (for/list ([c (in-list batch)]) (hash-ref c 'text))))
     (meter-embed! conn p toks)
     (unless (= (length vs) (length batch))
       (error 'repo_embed_chunks
              "the embedder answered ~a vector(s) for ~a chunk(s)" (length vs) (length batch)))
     vs)))

(define (chunk-batches xs n)
  (cond [(null? xs) '()]
        [(<= (length xs) n) (list xs)]
        [else (cons (take xs n) (chunk-batches (drop xs n) n))]))

(register-tool! "repo_list_unembedded" repo_list_unembedded "files:read" list-unembedded)
(register-tool! "repo_embed_chunks" repo_embed_chunks "files:write" embed-one)
