#lang racket/base

;; domain/ai/chunkstore.rkt — a document's chunk vectors, at rest (#189 step 4,
;; decisions VEC‑18…24).
;;
;; `docs/design/vector-store.md`'s build plan: "the table and the write path, as
;; a step in the existing indexing workflow rather than a new seam — a chunk's
;; vector is the same kind of thing as its extracted text, keyed on the version,
;; replaced wholesale by a new one." This module is the table and the write; the
;; nearest-chunk query is step 5 and is deliberately not here.
;;
;; WHAT IS NOT IN THIS MODULE, and both absences are the design:
;;
;;   * NO EMBEDDING CALL. The vectors arrive as an argument. `embed-exchange` is
;;     metered, egress-gated and quota-admitted at the seam in `doc-tools.rkt`
;;     (`current-doc-embed` + `meter-embed!`), and a second caller of it here
;;     would be a second place those three things could be forgotten — RED‑16's
;;     finding, where `model-exchange`'s own header called itself the one place
;;     content leaves while two other paths had their own. So this module is
;;     pure of the network and a test needs no endpoint.
;;
;;   * NO AUTHORIZATION. It is handed a connection and an object id, exactly as
;;     `repo-text-upsert!` is, and the caller has already been through
;;     `repo-open`/`can?`. VEC‑17's rule, and the blob store's: a layer that is
;;     never handed a principal has no authorization to get wrong.

(require db-kit/portable racket/list racket/flonum
         (only-in "../authz/sealed.rkt" define-sealed-column)
         (only-in "vectors.rkt" vec-pack vec-normalize))

(provide chunks-replace! chunks-for chunk-rows-for chunks-count
         chunks-model-for CHUNK-EMBED-BATCH
         seal-chunk-vector unseal-chunk-vector)

;; ---- the seal ----------------------------------------------------------------
;;
;; VEC‑3 arriving in code, through `#:bytes` (ENC‑24) rather than the string
;; path: the stored form is a binary frame, which is both the 51× and the 1.8×
;; the design measured. The AAD is the row's own id, so a ciphertext moved to
;; another chunk's row does not open — which is the whole purpose of binding it.
;;
;; THE CONTENT GATE, NOT `#:credential`'s UNCONDITIONAL ONE, and EMB‑9 wrote the
;; argument for this before there was a column to apply it to: "a label vector is
;; a function of operator-authored configuration … the day a DOCUMENT vector is
;; stored, the answer is the opposite, because a document vector is a function of
;; content this platform retained." Embedding inversion recovers much of a
;; chunk's source text, so an unsealed vector column beside a sealed `repo_text`
;; would undo #83 on exactly the instance that asked for it.
;;
;; Unlike `repo_text.content`, sealing these costs NOTHING in capability: no
;; search clause reads this column — the scan has to decode every vector anyway
;; (VEC's decision, reason 2), so the sealed instance and the plain one take the
;; same path and the measured difference is 4–14%.
(define-sealed-column "repo_chunks.vector" (seal-chunk-vector unseal-chunk-vector) (id) #:bytes)

;; How many chunk texts go to the embedder in one request. The dimension
;; `ai.requests` defaults to 200/day, so one request per chunk would let a single
;; 231-chunk document (a document at `EXTRACT-CAP`) spend a team's whole day;
;; one request per DOCUMENT is the other extreme and hands a provider a 231-item
;; array. 32 is a batch a provider will take and leaves an ordinary 9-chunk
;; business document at exactly one request.
(define CHUNK-EMBED-BATCH 32)

;; ---- the write ---------------------------------------------------------------
;;
;; VEC‑21 — REPLACED WHOLESALE, IN ONE TRANSACTION. The unit of correctness is
;; "the vectors of this version", never one row: a half-written set is a document
;; whose chunks 0–4 are of today's bytes and 5–11 of last week's, and nothing
;; downstream could detect that — the model name matches, the widths match, and
;; the offsets point into a string that has changed underneath them. So the
;; delete and the inserts are one transaction, and a failure leaves the previous
;; set intact rather than a mixture.
;;
;; `chunks` is a list of (hasheq 'index 'start 'end 'text) as `chunk-text`
;; answers them, and `vectors` the matching list of raw embedding vectors in the
;; SAME order — the caller has already paired them by the response's own `index`
;; field (EMB's rule: read by index, never by position, because pairing the wrong
;; vector with the wrong chunk does not fail, it retrieves confidently and
;; wrongly for ever).
;;
;; Answers the number of rows written.
(define (chunks-replace! conn object-id version-id model chunks vectors)
  (unless (= (length chunks) (length vectors))
    (error 'chunks-replace!
           "~a chunk(s) but ~a vector(s) — the pairing is the caller's and must be exact"
           (length chunks) (length vectors)))
  ;; VEC‑22 — A VECTOR WITH NO DIRECTION IS REFUSED HERE, not stored and skipped
  ;; later. `vec-normalize` answers #f for a zero or NaN vector, and the store's
  ;; invariant is that every row is a UNIT vector, because that is what makes the
  ;; read a bare dot product (VEC‑11). A row that broke it would answer 0.0
  ;; against every query — the WORST match — which is a claim where the honest
  ;; answer is "this chunk could not be embedded".
  (define prepared
    (for/list ([c (in-list chunks)] [v (in-list vectors)])
      (define fv (normalize-or-die (hash-ref c 'index) v))
      (list (hash-ref c 'index) (hash-ref c 'start) (hash-ref c 'end) (vec-pack fv))))
  ;; one width for the whole set: a set of vectors of two widths cannot have come
  ;; from one model, so it is a provider bug and storing it would leave the read
  ;; skipping rows it can never explain (VEC‑15 counts such rows, which is the
  ;; right answer for a SURVIVOR of a model change and the wrong one for a set
  ;; written this way on purpose)
  (define widths (remove-duplicates (for/list ([p (in-list prepared)]) (bytes-length (cadddr p)))))
  (when (> (length widths) 1)
    (error 'chunks-replace!
           "the embedder answered vectors of ~a different widths for one document"
           (length widths)))
  (call-with-transaction conn
    (lambda ()
      (query-exec conn "DELETE FROM repo_chunks WHERE object_id = ?" object-id)
      (define now (current-seconds))
      (for ([p (in-list prepared)])
        (define id (new-chunk-id))
        (query-exec conn
          (string-append "INSERT INTO repo_chunks "
                         "(id, object_id, version_id, idx, start_off, end_off, model, vector, created_epoch) "
                         "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)")
          id object-id version-id (car p) (cadr p) (caddr p) model
          (seal-chunk-vector id (cadddr p)) now))
      (length prepared))))

(define (normalize-or-die idx v)
  (define fv (vec-normalize (->flvector v)))
  (unless fv
    (error 'chunks-replace!
           (string-append "chunk ~a embedded to a vector with no direction (all zeros, or a NaN "
                          "component). The embedder answers one for empty input, so the chunk "
                          "is the thing to look at.")
           idx))
  fv)

;; The embedder's vectors arrive as a Racket `vector` of reals (that is what
;; `embedding-vectors` produces); `vec-normalize` wants an `flvector`.
(define (->flvector v)
  (cond
    [(flvector? v) v]
    [(vector? v)
     (define n (vector-length v))
     (define out (make-flvector n))
     (for ([i (in-range n)]) (flvector-set! out i (real->double-flonum (vector-ref v i))))
     out]
    [(list? v) (->flvector (list->vector v))]
    [else (error 'chunks-replace! "not a vector of numbers: ~e" v)]))

(define (new-chunk-id)
  (string-append "chk_" (number->string (current-inexact-milliseconds))
                 "_" (number->string (random 1000000000))))

;; ---- the reads this step needs -----------------------------------------------
;;
;; `chunk-rows-for` is the plain projection: (id idx start end model) per chunk of
;; a version, newest-first by nothing in particular — a chunk's ORDER is `idx`,
;; which is why it is the sort. No vectors: nothing in step 4 compares them, and
;; a function that handed them out would be step 5 arriving early with no scan
;; and no `can?` behind it.
(define (chunk-rows-for conn object-id version-id)
  (for/list ([r (in-list (query-rows conn
                  (string-append "SELECT id, idx, start_off, end_off, model FROM repo_chunks "
                                 "WHERE object_id = ? AND version_id = ? ORDER BY idx ASC")
                  object-id version-id))])
    (hasheq 'id (vector-ref r 0) 'index (vector-ref r 1)
            'start (vector-ref r 2) 'end (vector-ref r 3)
            'model (vector-ref r 4))))

;; …and the unsealed vectors beside them, which is what step 5's scan will be
;; handed. It exists here because the WRITE's own test has to prove a stored
;; vector comes back byte-identical and still unit — a property no other function
;; can establish, and the one thing a first binary column most needs pinned.
(define (chunks-for conn object-id version-id)
  (for/list ([r (in-list (query-rows conn
                  (string-append "SELECT id, idx, start_off, end_off, vector FROM repo_chunks "
                                 "WHERE object_id = ? AND version_id = ? ORDER BY idx ASC")
                  object-id version-id))])
    (define id (vector-ref r 0))
    (hasheq 'id id 'index (vector-ref r 1)
            'start (vector-ref r 2) 'end (vector-ref r 3)
            'vector (unseal-chunk-vector id (vector-ref r 4)))))

;; Which model a version's stored vectors are of, or #f when there are none.
;; EMB‑8: this is the question "are the vectors on disk comparable with what this
;; instance would produce today", and it is what makes a re-embed after a model
;; change necessary rather than optional.
(define (chunks-model-for conn object-id version-id)
  (query-maybe-value conn
    "SELECT model FROM repo_chunks WHERE object_id = ? AND version_id = ? LIMIT 1"
    object-id version-id))

;; One team's chunk count — the number `vector-store.md`'s "When to revisit"
;; section asks to be VISIBLE rather than profiled: "when a single team's chunk
;; count passes 50,000". It is reported by the write tool's own result, so the
;; operator draining a backlog watches it approach the threshold.
(define (chunks-count conn team-id)
  (or (query-maybe-value conn
        (string-append "SELECT COUNT(*) FROM repo_chunks c "
                       "JOIN repo_objects o ON o.id = c.object_id "
                       "WHERE o.team_id = ? AND o.deleted_at IS NULL")
        team-id)
      0))

;; There is deliberately no `chunks-delete!` here. The one place a document stops
;; existing is `repo-delete!`, which clears `repo_text` and `repo_annotations`
;; with a direct statement for the same reason — no FK cascade, SQLite
;; portability — so the erasure keeps all three lines together where somebody
;; auditing a deletion request reads them, rather than one of them being a call
;; into another module.
