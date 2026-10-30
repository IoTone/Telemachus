#lang racket/base

;; domain/help/helpstore.rkt — the in-product help corpus, at rest (#183,
;; decisions HELP‑1…8).
;;
;; #183's first question is "whose documents, and where do they live?". This is
;; the answer: the product's own documentation, ingested into two tables of the
;; INSTANCE's own, keyed by the source path and made stale by a hash of the file.
;; Not a team's repository documents (HELP‑3), and not read off disk at request
;; time (HELP‑2).
;;
;; WHAT IS NOT IN THIS MODULE, and each absence is deliberate:
;;
;;   * NO EMBEDDING CALL. Vectors arrive as an argument, exactly as in
;;     `chunkstore.rkt`, for RED‑16's reason: the one place a model request
;;     leaves the process is `embed-exchange`, and a second caller here would be
;;     a second place the egress gate and the request log could be forgotten.
;;     The ingest in `helpindex.rkt` is that caller.
;;
;;   * NO AUTHORIZATION, and here that is not merely a layering rule but the
;;     whole shape of the feature (HELP‑7). A repository chunk needs `can?` per
;;     row because it is somebody's document; a paragraph of
;;     `docs/ops/container.md` is the manual for the software the asker is
;;     signed in to. So `help-nearest` takes no principal and there is no
;;     per-row filter to get wrong — which also removes VEC‑28's authorization
;;     headroom, and with it the one approximation #189's read had to make.
;;
;;   * NO DELETE OF A DOCUMENT'S CHUNKS ON ITS OWN. `help-replace-doc!` is the
;;     only writer and replaces a path wholesale; `help-forget!` removes a path
;;     entirely, for a file the ingest no longer finds.

(require db-kit/portable racket/list racket/flonum
         (only-in "../ai/vectors.rkt" vec-pack vec-normalize))

(provide help-replace-doc! help-forget! help-clear!
         help-any?
         help-doc-by-path help-doc-paths help-doc-hash
         help-stats help-locales help-chunk-count
         help-text-for help-doc-row)

;; ---- the write ---------------------------------------------------------------
;;
;; HELP‑8 — ONE PATH, ONE TRANSACTION, REPLACED WHOLESALE. VEC‑21's argument
;; applies unchanged: the unit of correctness is "the chunks of this file", never
;; one row, because a half-written set is a document whose chunks 0–4 index
;; today's text and 5–11 last release's, and nothing downstream could detect it —
;; the model matches, the widths match, and the offsets point into a string that
;; has changed underneath them.
;;
;; `chunks` is a list of (hasheq 'index 'start 'end 'text 'heading) and `vectors`
;; the matching list in the SAME order, already paired by the caller off the
;; embedding response's own `index` field (EMB's rule: never by position).
;;
;; Answers the number of chunk rows written.
(define (help-replace-doc! conn path locale title content source-hash model chunks vectors)
  (unless (= (length chunks) (length vectors))
    (error 'help-replace-doc!
           "~a chunk(s) but ~a vector(s) — the pairing is the caller's and must be exact"
           (length chunks) (length vectors)))
  ;; A unit vector per row, refused here rather than stored and skipped later:
  ;; VEC‑22's invariant is what makes the read a bare dot product.
  (define prepared
    (for/list ([c (in-list chunks)] [v (in-list vectors)])
      (define fv (vec-normalize (->flvector v)))
      (unless fv
        (error 'help-replace-doc!
               (string-append "chunk ~a of ~a embedded to a vector with no direction (all "
                              "zeros, or a NaN component). An embedder answers one for empty "
                              "input, so the chunk is the thing to look at.")
               (hash-ref c 'index) path))
      (list (hash-ref c 'index) (hash-ref c 'start) (hash-ref c 'end)
            (hash-ref c 'heading "") (vec-pack fv))))
  (define widths (remove-duplicates (for/list ([p (in-list prepared)]) (bytes-length (list-ref p 4)))))
  (when (> (length widths) 1)
    (error 'help-replace-doc!
           "the embedder answered vectors of ~a different widths for ~a" (length widths) path))
  (call-with-transaction conn
    (lambda ()
      (define id (or (query-maybe-value conn "SELECT id FROM help_docs WHERE path = ?" path)
                     (new-id "hdoc")))
      (query-exec conn "DELETE FROM help_chunks WHERE doc_id = ?" id)
      (query-exec conn "DELETE FROM help_docs WHERE id = ?" id)
      (define now (current-seconds))
      (query-exec conn
        (string-append "INSERT INTO help_docs "
                       "(id, path, locale, title, content, source_hash, chunk_count, bytes, updated_epoch) "
                       "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)")
        id path locale title content source-hash (length prepared)
        (string-utf-8-length content) now)
      (for ([p (in-list prepared)])
        (query-exec conn
          (string-append "INSERT INTO help_chunks "
                         "(id, doc_id, idx, start_off, end_off, heading, model, vector, created_epoch) "
                         "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)")
          (new-id "hchk") id (car p) (cadr p) (caddr p) (cadddr p) model (list-ref p 4) now))
      (length prepared))))

;; A file the ingest no longer finds. The row is removed rather than kept as a
;; tombstone: unlike a feed item (FEED's rule, where a tombstone stops a deleted
;; document being re-created) there is nobody to protect from a re-ingest — the
;; file reappearing means the documentation has it again.
(define (help-forget! conn path)
  (call-with-transaction conn
    (lambda ()
      (define id (query-maybe-value conn "SELECT id FROM help_docs WHERE path = ?" path))
      (cond
        [id (query-exec conn "DELETE FROM help_chunks WHERE doc_id = ?" id)
            (query-exec conn "DELETE FROM help_docs WHERE id = ?" id)
            #t]
        [else #f]))))

;; The whole corpus. This is what a model change means (EMB‑8): vectors from two
;; checkpoints are not comparable and mixing them does not raise, so changing
;; `TMACH_EMBED_MODEL` means ingesting again from empty rather than merging.
(define (help-clear! conn)
  (call-with-transaction conn
    (lambda ()
      (define n (or (query-maybe-value conn "SELECT COUNT(*) FROM help_docs") 0))
      (query-exec conn "DELETE FROM help_chunks")
      (query-exec conn "DELETE FROM help_docs")
      n)))

;; ---- the reads ---------------------------------------------------------------

(define (help-doc-by-path conn path)
  (define r (query-maybe-row conn
              (string-append "SELECT id, path, locale, title, source_hash, chunk_count, bytes, "
                             "updated_epoch FROM help_docs WHERE path = ?")
              path))
  (and r (row->doc r)))

(define (help-doc-row conn id)
  (define r (query-maybe-row conn
              (string-append "SELECT id, path, locale, title, source_hash, chunk_count, bytes, "
                             "updated_epoch FROM help_docs WHERE id = ?")
              id))
  (and r (row->doc r)))

(define (row->doc r)
  (hasheq 'id (vector-ref r 0) 'path (vector-ref r 1) 'locale (vector-ref r 2)
          'title (vector-ref r 3) 'source_hash (vector-ref r 4)
          'chunks (vector-ref r 5) 'bytes (vector-ref r 6)
          'updated_epoch (vector-ref r 7)))

;; Every path in the corpus, which is what the ingest diffs against the tree it
;; was given so a file that has been deleted upstream can be forgotten.
(define (help-doc-paths conn)
  (for/list ([r (in-list (query-rows conn "SELECT path FROM help_docs ORDER BY path ASC"))])
    (vector-ref r 0)))

;; HELP‑4's staleness test, as one question: has this exact text already been
;; ingested? #f for a path that is not there at all.
(define (help-doc-hash conn path)
  (query-maybe-value conn "SELECT source_hash FROM help_docs WHERE path = ?" path))

;; The text a hit's offsets index into. Keyed by the DOC id rather than the path,
;; because the scan already holds the id and a path lookup would be a second
;; chance to disagree about which row the offsets belong to.
(define (help-text-for conn doc-id)
  (query-maybe-value conn "SELECT content FROM help_docs WHERE id = ?" doc-id))

;; Which locales the corpus actually holds — DERIVED, never stored, the rule
;; `available` locales already follow: an instance must not offer help in a
;; language it has ingested nothing for.
(define (help-locales conn)
  (for/list ([r (in-list (query-rows conn
                  "SELECT DISTINCT locale FROM help_docs ORDER BY locale ASC"))])
    (vector-ref r 0)))

;; "is there anything to answer with", as an EXISTENCE test rather than a count.
;; It matters because `GET /api/whoami` asks it on every console render pass, and
;; a `COUNT(*)` over the corpus is a full scan of 1,600 rows for a boolean. The
;; counts are for `status` and the report, where the number is the point.
(define (help-any? conn [locale #f])
  (and (if locale
           (query-maybe-value conn
             (string-append "SELECT 1 FROM help_chunks c JOIN help_docs d ON d.id = c.doc_id "
                            "WHERE d.locale = ? LIMIT 1")
             locale)
           (query-maybe-value conn "SELECT 1 FROM help_chunks LIMIT 1"))
       #t))

(define (help-chunk-count conn [locale #f])
  (or (if locale
          (query-maybe-value conn
            (string-append "SELECT COUNT(*) FROM help_chunks c JOIN help_docs d ON d.id = c.doc_id "
                           "WHERE d.locale = ?")
            locale)
          (query-maybe-value conn "SELECT COUNT(*) FROM help_chunks"))
      0))

;; What `telemachus-help status` prints and what the help endpoint reports when
;; it has nothing to answer with: per locale, how many documents and chunks, of
;; which model, and when they were last ingested.
(define (help-stats conn)
  (define rows
    (query-rows conn
      (string-append
       "SELECT d.locale, COUNT(DISTINCT d.id), COUNT(c.id), MAX(d.updated_epoch) "
       "FROM help_docs d LEFT JOIN help_chunks c ON c.doc_id = d.id "
       "GROUP BY d.locale ORDER BY d.locale ASC")))
  (hasheq 'locales
          (for/list ([r (in-list rows)])
            (hasheq 'locale (vector-ref r 0)
                    'documents (vector-ref r 1)
                    'chunks (vector-ref r 2)
                    'updated_epoch (vector-ref r 3)))
          'documents (or (query-maybe-value conn "SELECT COUNT(*) FROM help_docs") 0)
          'chunks (help-chunk-count conn)
          ;; One model for the whole corpus or none: see `help-clear!`.
          'models (for/list ([r (in-list (query-rows conn
                          "SELECT DISTINCT model FROM help_chunks ORDER BY model ASC"))])
                    (vector-ref r 0))))

;; ---- small helpers -----------------------------------------------------------

(define (new-id prefix)
  (string-append prefix "_" (number->string (current-inexact-milliseconds))
                 "_" (number->string (random 1000000000))))

;; `flvector` has no `list->flvector`, which cost a compile in #189 step 4.
(define (->flvector v)
  (cond
    [(flvector? v) v]
    [(vector? v)
     (define n (vector-length v))
     (define out (make-flvector n))
     (for ([i (in-range n)]) (flvector-set! out i (real->double-flonum (vector-ref v i))))
     out]
    [(list? v) (->flvector (list->vector v))]
    [else (error 'help-replace-doc! "not a vector of numbers: ~e" v)]))
