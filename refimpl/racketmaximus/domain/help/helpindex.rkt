#lang racket/base

;; domain/help/helpindex.rkt — reading a tree of Markdown into the help corpus
;; (#183, decisions HELP‑1/‑2/‑6/‑9).
;;
;; HELP‑1 — THIS IS DRIVEN BY AN OPERATOR CLI, NOT BY A WORKFLOW, and that is
;; forced rather than preferred. Every model-backed workflow here runs as a
;; principal and bills a team: `tenant-quota-record!` takes a principal, the
;; scheduler admits a job against a team's budget, and the org gate scopes it to
;; a tenant. The corpus belongs to no team (HELP‑3), and this platform has no
;; instance-tier quota subject at all — `docs/design/quotas.md` and #113's own
;; note say so. So an ingest is `cli/telemachus-help.rkt`, beside
;; `telemachus-secrets` and `telemachus-anchor`: a thing an operator does once
;; per release, out of band, like adopting a key or emitting an anchor.
;;
;; WHAT THAT COSTS, STATED: the embedding requests an ingest makes are charged to
;; nobody. They ARE logged, and that took doing — `model-request-logger` is a box
;; `server/main.rkt` fills, so the first working ingest wrote 111 requests to a
;; model endpoint and logged none of them, which `log-model-request!`'s own
;; swallow (RED‑17) made silent. `cli/telemachus-help.rkt` installs a logger of
;; its own for that reason. The row carries NO TEAM, which is honest rather than
;; a gap — an ingest acts for the instance, and this platform has had no system
;; principal since 0051 — so those rows are in `model_requests` and are not on
;; `GET /api/model-requests`, which filters by team (#187's shape, met
;; deliberately).
;;
;; HELP‑2 — AND THE CORPUS IS INGESTED RATHER THAN READ OFF DISK AT REQUEST
;; TIME, WHICH A MEASUREMENT DECIDED. #183 offers "shipping docs ingested per
;; instance at boot" as one answer, and on this project it cannot be one:
;; `nix/telemachus.nix` sets `src = ../refimpl/racketmaximus`, so **`docs/` is
;; not in the derivation, not in the store and not in the container image**. A
;; boot-time read of `docs/` would work in every developer's checkout and find an
;; empty directory on every packaged install — which is exactly the shape #119
;; was filed against, a feature that reports healthy and does nothing. Adding
;; `docs/` to the derivation was the alternative and would put the committed book
;; PDF and every screenshot into the image, whose size `docs/ops/container.md`
;; already guards twice. So the operator points the ingest at a tree, and what
;; travels with the instance is the DATABASE.

(require racket/list racket/string racket/file racket/path
         (only-in "../i18n/catalog.rkt" source-hash)
         (only-in "../ai/chunk.rkt" chunk-text CHUNK-SIZE-DEFAULT CHUNK-OVERLAP-DEFAULT)
         (only-in "../ai/vectors.rkt" vec-normalize)
         (only-in racket/flonum flvector? make-flvector flvector-set!)
         (only-in "../ai/executor.rkt" embed-exchange embed-model embed-configured?)
         (only-in "helpstore.rkt" help-replace-doc! help-forget! help-doc-hash help-doc-paths))

(provide help-ingest! current-help-embed
         help-markdown-files help-locale-of help-title-of help-heading-before
         help-chunk-embed-text HELP-EMBED-BATCH HELP-DEFAULT-LOCALES)

;; How many chunk texts go to the embedder in one request — `CHUNK-EMBED-BATCH`'s
;; number, for its reason, and not shared with it: that constant is justified by
;; the per-team `ai.requests` default of 200/day, which does not apply here at
;; all (HELP‑1). Two constants that happen to be equal for different reasons are
;; not LIVE‑IN's shape; one constant used for two unrelated arguments is.
(define HELP-EMBED-BATCH 32)

;; The locales an ingest will recognise in a path when the caller names none.
;; The CLI passes the catalogs actually on disk (`available-locales`), which is
;; the `available` rule: an instance must not build a help corpus in a language
;; it cannot render a single string of.
(define HELP-DEFAULT-LOCALES '("en"))

;; ---- the embedding seam ------------------------------------------------------
;;
;; A SECOND PARAMETER BESIDE `current-doc-embed`, AND NOT A REUSE OF IT.
;; `doc-tools.rkt`'s parameter is the document tools' seam: requiring it would
;; instantiate the repository, the classifier, the sensitivity policy and four
;; tool registrations as a side effect, in a CLI and in a test that wants none of
;; them. What must not be duplicated is `embed-exchange` itself (RED‑16), and it
;; is not — both parameters default to a thin call on the same function.
(define (default-embed texts)
  (define-values (vs toks _u _m) (embed-exchange texts #:who 'help-index))
  (values vs toks))

(define current-help-embed (make-parameter default-embed))

;; ---- what is a document ------------------------------------------------------
;;
;; Markdown only. The runbooks, the design documents, the generated reference and
;; the e-book are all Markdown by rule — `docs/book/`'s source is Markdown
;; precisely so a translator never edits LaTeX — and the two built editions
;; beside them are a PDF and a single HTML page, which are renderings of text
;; this ingest already has. Pointing an extractor at them would index the same
;; prose twice and cite the copy nobody reads.
(define (help-markdown-files root)
  (define base (simplify-path (path->complete-path root) #f))
  (cond
    [(not (directory-exists? base))
     (if (file-exists? base) (list base) '())]
    [else
     (sort (for/list ([p (in-list (find-files (lambda (p) (markdown? p)) base))]) p)
           string<? #:key path->string)]))

(define (markdown? p)
  (and (file-exists? p)
       (member (path-get-extension p) (list #".md" #".markdown"))
       #t))

;; HELP‑10 — THE LOCALE COMES FROM THE PATH, AGAINST A CLOSED SET. Two spellings
;; are in this repository and both are load-bearing: a DIRECTORY segment
;; (`docs/book/ja/04-authz.md`, `docs/reference/ja/api.md`) and a SUFFIX
;; (`README.ja.md`). Anything else is the default locale, which is right for
;; `docs/ops/container.md`.
;;
;; The set is closed and passed in rather than matched by a two-letter grammar:
;; a grammar would read a directory that merely happens to be two characters
;; long as a language and tag a whole subtree with it, and a mis-tagged document
;; is invisible — it is simply never retrieved for the locale that should have
;; found it.
(define (help-locale-of path locales #:default [dflt "en"])
  (define segs (map path->string (explode-path (if (path? path) path (string->path path)))))
  (define by-dir (for/first ([s (in-list segs)] #:when (member s locales)) s))
  (define name (last segs))
  (define by-suffix
    (let ([m (regexp-match #px"\\.([A-Za-z]{2}(?:-[A-Za-z0-9]+)?)\\.(?:md|markdown)$" name)])
      (and m (let ([l (cadr m)]) (and (member l locales) l)))))
  (or by-suffix by-dir dflt))

;; The document's own title: its first ATX heading, which every Markdown file in
;; this repository has as its first line of content. A leading HTML comment is
;; skipped naturally by looking for the heading rather than at line 1 — the ja
;; e-book chapters begin with their `source-sha1` stamp in one.
(define (help-title-of text fallback)
  (or (for/first ([line (in-list (string-split text "\n"))]
                  #:when (regexp-match? #px"^#{1,6}\\s+\\S" line))
        (string-trim (regexp-replace #px"^#{1,6}\\s+" (string-trim line) "")))
      fallback))

;; The heading a chunk sits under: the nearest ATX heading at or before its
;; start. Scanned over the text before the offset, so it is the heading a reader
;; would see above the quoted passage.
;;
;; THE FIRST CHUNK OF A DOCUMENT HAS NONE, and that is the rule rather than a
;; gap: nothing precedes offset 0, and a document's own headings are INSIDE its
;; first chunk. What carries the context there is the TITLE, which is the second
;; reason `help-chunk-embed-text` includes it — a composition of heading alone
;; would leave exactly the opening of every document unlabelled.
(define (help-heading-before text offset)
  (define head (substring text 0 (min offset (string-length text))))
  (define hits
    (for/list ([line (in-list (string-split head "\n"))]
               #:when (regexp-match? #px"^#{1,6}\\s+\\S" line))
      (string-trim (regexp-replace #px"^#{1,6}\\s+" (string-trim line) ""))))
  (if (null? hits) "" (last hits)))

;; HELP‑6 — WHAT IS EMBEDDED IS MORE THAN WHAT IS QUOTED, AND THE COST IS REAL.
;; A chunk in the middle of a runbook reads "set it to 1 and restart"; the words
;; that make it findable — the document's title and the section's heading — are
;; hundreds of characters above it and are in no chunk that contains the answer.
;; So the vector is of `title / heading / text` while `start`/`end` still index
;; the raw substring, which means **a chunk's vector is of slightly more than the
;; chunk cites**. That is the trade, stated because it is the kind of thing a
;; later reader would otherwise find by surprise: a passage can be retrieved for
;; a word that appears only in its heading, and a reader comparing the quoted
;; text with the question will not see why it matched. The alternative —
;; embedding the bare chunk — makes a corpus of 1,200 paragraphs in which the
;; subject of each is unstated.
(define (help-chunk-embed-text title heading text)
  (string-join (filter (lambda (s) (not (string=? s "")))
                       (list (or title "") (or heading "") text))
               "\n"))

;; ---- the ingest --------------------------------------------------------------
;;
;; Answers a report: what was ingested, what was unchanged, what was forgotten,
;; and how many embedding requests it cost.
;;
;; HELP‑9 — AN UNCHANGED FILE COSTS NO MODEL REQUEST. The whole tree is 1,227
;; chunks of English (measured with the real chunker), which is 39 requests; a
;; re-ingest after editing one runbook should be one. The hash is the test
;; (HELP‑4), so this is `help-doc-hash` and a `continue`, and `#:force` is how an
;; operator re-embeds everything after changing the chunk size — which, unlike a
;; model change, does not invalidate the model name and so cannot be detected.
(define (help-ingest! conn roots
                      #:locales [locales HELP-DEFAULT-LOCALES]
                      #:default-locale [dflt "en"]
                      #:size [size CHUNK-SIZE-DEFAULT]
                      #:overlap [overlap CHUNK-OVERLAP-DEFAULT]
                      #:force? [force? #f]
                      #:prune? [prune? #t]
                      #:model [model (embed-model)]
                      #:relative-to [rel #f]
                      #:on-progress [on-progress void])
  (unless (or (not (eq? (current-help-embed) default-embed)) (embed-configured?))
    (error 'help-ingest!
           (string-append "no embedding model configured: set TMACH_EMBED_URL (and "
                          "TMACH_EMBED_MODEL) to the endpoint that will embed the corpus. The "
                          "help corpus is vectors, so there is nothing this can do without one.")))
  (define embed (current-help-embed))
  (define base (and rel (simplify-path (path->complete-path rel) #f)))
  (define files (remove-duplicates (append-map help-markdown-files roots)))
  (define seen (make-hash))
  (let loop ([fs files] [ingested '()] [unchanged '()] [empty '()] [chunks 0] [requests 0]
             [dropped '()])
    (cond
      [(null? fs)
       ;; A path in the corpus that this tree no longer has. Pruning is the
       ;; default because a documentation file that was renamed would otherwise
       ;; be cited for ever under a name nobody can open — and it is a flag
       ;; because an operator ingesting ONE subtree must not thereby delete the
       ;; rest of the corpus.
       (define pruned
         (if prune?
             (for/list ([p (in-list (help-doc-paths conn))]
                        #:unless (hash-ref seen p #f))
               (help-forget! conn p)
               p)
             '()))
       (hasheq 'ingested (reverse ingested)
               'unchanged (reverse unchanged)
               'empty (reverse empty)
               'pruned pruned
               'chunks chunks
               'requests requests
               ;; (path . (indices …)) per file that lost a chunk. Named rather
               ;; than counted: "three chunks were dropped" is not something an
               ;; operator can act on, and which FILE is.
               'dropped (reverse dropped)
               'model model)]
      [else
       (define f (car fs))
       (define rel-path (display-path f base))
       (hash-set! seen rel-path #t)
       (define text (file->string f))
       (define hash (source-hash text))
       (cond
         [(and (not force?) (equal? hash (help-doc-hash conn rel-path)))
          (loop (cdr fs) ingested (cons rel-path unchanged) empty chunks requests dropped)]
         [else
          (define locale (help-locale-of f locales #:default dflt))
          (define title (help-title-of text (path->string (file-name-from-path f))))
          (define-values (cs _truncated) (chunk-text text #:size size #:overlap overlap))
          (cond
            ;; A file with nothing in it is recorded as nothing rather than left
            ;; to be re-read every run: VEC‑23's termination rule — an ingest an
            ;; operator repeats until it reports no work must be able to finish.
            [(null? cs)
             (help-replace-doc! conn rel-path locale title text hash model '() '())
             (loop (cdr fs) ingested unchanged (cons rel-path empty) chunks requests dropped)]
            [else
             (define withheading
               (for/list ([c (in-list cs)])
                 (hash-set c 'heading (help-heading-before text (hash-ref c 'start)))))
             (define-values (vectors reqs)
               (embed-batches embed
                              (for/list ([c (in-list withheading)])
                                (help-chunk-embed-text title (hash-ref c 'heading) (hash-ref c 'text)))))
             ;; HELP‑15 — A CHUNK THE EMBEDDER CANNOT PLACE IS DROPPED AND
             ;; COUNTED, NOT ALLOWED TO FAIL THE INGEST, and a calibration dry
             ;; run is what found this. `help-replace-doc!` refuses a vector with
             ;; no direction, correctly — VEC‑22's invariant is that every stored
             ;; row is a UNIT vector, because that is what makes the read a bare
             ;; dot product. But this walks NINETY-TWO files in one command, so
             ;; one odd chunk in one file stopped the whole corpus and the
             ;; operator had no per-file retry to fall back on. (`repo_embed_chunks`
             ;; is the other shape: one document per step, where failing the step
             ;; IS the retry.) So the filtering happens here, the store stays
             ;; strict, and what was dropped is named — the indexer's own rule
             ;; that one bad file must not wedge the work for ever, applied a
             ;; level down.
             (define-values (keep-chunks keep-vectors lost)
               (for/fold ([cs '()] [vs '()] [lost '()]
                          #:result (values (reverse cs) (reverse vs) (reverse lost)))
                         ([c (in-list withheading)] [v (in-list vectors)])
                 (if (vec-normalize (->flvec v))
                     (values (cons c cs) (cons v vs) lost)
                     (values cs vs (cons (hash-ref c 'index) lost)))))
             ;; The ordinals stay DENSE over what was stored, because a gap would
             ;; be a key with a hole in it — CHUNK‑5's rule for a blank chunk.
             (define renumbered
               (for/list ([c (in-list keep-chunks)] [i (in-naturals)])
                 (hash-set c 'index i)))
             (help-replace-doc! conn rel-path locale title text hash model
                                renumbered keep-vectors)
             (on-progress rel-path (length renumbered))
             (loop (cdr fs)
                   (cons rel-path ingested) unchanged empty
                   (+ chunks (length renumbered)) (+ requests reqs)
                   (if (null? lost) dropped (cons (cons rel-path lost) dropped)))])])])))

;; One request per `HELP-EMBED-BATCH` texts, paired back by the response's own
;; order within the batch — `embedding-vectors` has already read the `index`
;; field, which is the only safe pairing (EMB's rule).
(define (embed-batches embed texts)
  (let loop ([rest texts] [out '()] [n 0])
    (cond
      [(null? rest) (values (reverse out) n)]
      [else
       (define batch (if (> (length rest) HELP-EMBED-BATCH)
                         (take rest HELP-EMBED-BATCH)
                         rest))
       (define-values (vs _toks) (embed batch))
       (unless (= (length vs) (length batch))
         (error 'help-ingest! "the embedder answered ~a vector(s) for ~a text(s)"
                (length vs) (length batch)))
       (loop (if (> (length rest) HELP-EMBED-BATCH) (drop rest HELP-EMBED-BATCH) '())
             (append (reverse vs) out)
             (add1 n))])))

;; The stored path is relative to the tree the operator named, so the corpus says
;; `docs/ops/container.md` rather than `/home/somebody/checkout/docs/...` — the
;; path is what a citation SHOWS, and an absolute one names a directory on a
;; machine the reader has no access to.
(define (display-path f base)
  (define s (path->string (simplify-path (path->complete-path f) #f)))
  (cond
    [(not base) s]
    [else
     (define b (path->string base))
     (define b/ (if (string-suffix? b "/") b (string-append b "/")))
     (if (string-prefix? s b/) (substring s (string-length b/)) s)]))

;; `vec-normalize` wants an `flvector`; the embedder answers a Racket `vector` of
;; reals. `flvector` has no `list->flvector`, which cost a compile in #189 step 4.
(define (->flvec v)
  (cond
    [(flvector? v) v]
    [(vector? v)
     (define n (vector-length v))
     (define out (make-flvector n))
     (for ([i (in-range n)]) (flvector-set! out i (real->double-flonum (vector-ref v i))))
     out]
    [(list? v) (->flvec (list->vector v))]
    [else #f]))
