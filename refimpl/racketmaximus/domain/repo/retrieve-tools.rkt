#lang racket/base

;; domain/repo/retrieve-tools.rkt — the retrieval tool (#189 step 6, VEC‑38/‑39).
;;
;; The half of step 6 a MODEL or a workflow reaches. The other half is
;; `?semantic=` on `GET /api/search`, which a person reaches; both go through
;; `passages-for`, so there is one place the question is embedded, one place the
;; budget is spent and one place the scan is asked.
;;
;; Registered at module level like the rest of the catalog, so requiring this
;; module is all it takes for a workflow — or the agent — to see the tool. It is
;; one of the side-effect requires `server/main.rkt` carries by name, beside
;; `index-tools.rkt` and `embed-tools.rkt`, for the instance that loads no
;; plugins (#110 r3's trap).

(require "../tools/dsl.rkt"
         "../agent/registry.rkt"
         (only-in "passages.rkt" passages-for PASSAGE-LIMIT PASSAGE-MAX))

(provide PASSAGE-LIMIT PASSAGE-MAX)   ; re-exported so the tests pin one home

(define-tool repo_retrieve
  #:description
  "Find the passages of the team's repository documents closest in MEANING to a question, for answering from them. Returns a passage's text with its document key and the character offsets it was read at, so an answer can cite where it came from. Needs TMACH_EMBED_URL and documents that the Embed Documents workflow has already processed; it finds nothing on a team with no embeddings, rather than falling back to keyword search."
  (question string #:description "The question to find passages for, in any language")
  (limit number #:optional #:description "How many passages to return (default 8, at most 20)"))

;; VEC‑38 — IT ANSWERS STRUCTURE, NOT PROSE WITH CITATIONS, and `kg_query` is the
;; precedent it is weighed against: that one "answers in text with [key]
;; citations" because an entity's answer IS a sentence. A passage's is not. The
;; whole point of carrying offsets (VEC‑32, CHUNK‑1) is that a citation be
;; MACHINE-READABLE — `spans-covering` turns one into a page and a bbox — and
;; flattening them into prose would leave a model retyping a key it had been
;; handed, which is the one step in a citation that can silently be wrong. The
;; agent boundary JSON-encodes a non-string result (`dispatch-tool`), so a model
;; sees a JSON array and a workflow's `map #:over` gets the real list —
;; `repo_list_unindexed`'s documented contract, for its reason.
(define (retrieve conn p args)
  (define k (let ([v (hash-ref args 'limit #f)])
              (if (and (number? v) (exact-positive-integer? (inexact->exact (floor v))))
                  (inexact->exact (floor v))
                  PASSAGE-LIMIT)))
  (define rep (passages-for conn p (hash-ref args 'question "") #:limit k))
  ;; The report rides BESIDE the passages rather than being dropped: `truncated`
  ;; is how a caller learns the answer may be short of the best matches, and
  ;; `model` is how it learns which checkpoint the comparison was made under —
  ;; EMB‑8, where vectors of two checkpoints are not comparable and the failure
  ;; has no name of its own.
  (hasheq 'passages (hash-ref rep 'passages)
          'count (length (hash-ref rep 'passages))
          'model (hash-ref rep 'model)
          'scanned (hash-ref rep 'scanned)
          'truncated (hash-ref rep 'truncated)))

;; `files:read` is the permission the registry gates on; `passages-for` also
;; requires `chat:use`, because asking costs a model request. Declaring the
;; stricter one here would make the tool unavailable to the role that holds both,
;; and declaring only `chat:use` would let it past the repository's own gate — so
;; the registry keeps the resource permission and the seam keeps the budget one.
(register-tool! "repo_retrieve" repo_retrieve "files:read" retrieve)
