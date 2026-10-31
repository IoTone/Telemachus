#lang racket/base

;; cli/telemachus-help.rkt — the operator side of the in-product help corpus
;; (#183, decision HELP‑1).
;;
;;   racket cli/telemachus-help.rkt status                  # what is in the corpus
;;   racket cli/telemachus-help.rkt ingest [roots …]        # read a tree of Markdown into it
;;   racket cli/telemachus-help.rkt clear                   # empty it
;;
;; WHY THIS IS A CLI AND NOT A WORKFLOW: every model-backed workflow here runs as
;; a principal and bills a team, and the corpus belongs to no team — there is no
;; instance-tier quota subject on this platform, deliberately. So an ingest is an
;; operator action, out of band, like `telemachus-secrets rewrap` or
;; `telemachus-anchor emit`. `domain/help/helpindex.rkt`'s header has the whole
;; argument, including what it costs: an ingest's embedding requests are logged
;; and charged to nobody.
;;
;; WHY IT TAKES A PATH: `nix/telemachus.nix` packages `refimpl/racketmaximus`
;; only, so `docs/` is not in the store and not in the image. A packaged instance
;; therefore has no documentation on disk at all, and the operator ingests from a
;; checkout of the release they are running (HELP‑2). The corpus then lives in the
;; database, which travels with the instance.
;;
;;   DATABASE_URL=… TMACH_EMBED_URL=… TMACH_EMBED_MODEL=nomic-embed-text \
;;     racket cli/telemachus-help.rkt ingest

(require racket/string racket/list racket/path db-kit db-kit/portable
         "../config.rkt"
         (only-in "../domain/i18n/policy.rkt" available-locales)
         (only-in "../domain/ai/executor.rkt" embed-model embed-configured? model-request-logger)
         (only-in "../domain/ai/requestlog.rkt" model-request-record!)
         (only-in "../domain/ai/chunk.rkt" CHUNK-SIZE-DEFAULT CHUNK-OVERLAP-DEFAULT)
         (only-in "../domain/help/helpstore.rkt" help-stats help-clear!)
         (only-in "../domain/help/helpindex.rkt" help-ingest!))

(define (die msg) (eprintf "~a\n" msg) (exit 2))

(define (open-db) ((db-connector (database-url) #:base-dir impl-root)))

;; A missing schema is a message, not a stack trace (#123's rule, as
;; `telemachus-anchor` applies it): pointing this at a fresh data directory is an
;; ordinary mistake, and `no such table: help_docs` reads as a broken build.
(define (with-db proc)
  (define conn (open-db))
  (install-request-logger! conn)
  (with-handlers ([exn:fail?
                   (lambda (e)
                     (if (regexp-match? #px"(no such table|does not exist|relation .* does not)"
                                        (exn-message e))
                         (die (format (string-append
                                       "this database has no help tables, so it has not been "
                                       "migrated by this build.\n  DATABASE_URL=~a\n"
                                       "Start the server once against it, or point DATABASE_URL "
                                       "at the instance's own database.")
                                      ;; REDACTED: a DATABASE_URL carries its
                                      ;; password in the clear, and this prints to
                                      ;; an operator's terminal and into whatever
                                      ;; captures it (#186, SEC-6).
                                      (redact-db-url (database-url))))
                         (raise e)))])
    (proc conn)))

;; RED‑16 — THE REQUEST LOG IS INSTALLED HERE, AND IT WAS NOT UNTIL RUNNING THIS
;; SHOWED IT. `model-request-logger` is a BOX that `server/main.rkt` fills, so a
;; CLI making model requests makes them with the box empty — and
;; `log-model-request!` swallows a failure by design (RED‑17), so an ingest wrote
;; 111 embedding requests to a model endpoint and logged NONE of them, silently.
;; `helpindex.rkt`'s own header claimed otherwise, which is the "I documented a
;; NOTE I had not read" shape; the fix is the logger, not the sentence.
;;
;; The row carries NO TEAM, and that is honest rather than a gap: an ingest acts
;; for the instance and this platform has no system principal (0051). So an
;; ingest's requests are in `model_requests` and are NOT on
;; `GET /api/model-requests`, which filters by team — #187's shape, met
;; deliberately this time.
(define (install-request-logger! conn)
  (set-box! model-request-logger
    (lambda (#:executor executor #:transport transport #:model model #:endpoint endpoint
             #:messages msgs #:tokens tokens #:status status #:error-kind error-kind
             #:http-status http-status #:operation operation #:ms ms)
      (model-request-record! conn
        #:team #f #:user #f #:org #f
        #:executor executor #:transport transport #:model model #:endpoint endpoint
        #:messages msgs #:tokens tokens #:status status #:error-kind error-kind
        #:http-status http-status #:operation operation #:ms ms)
      (void))))

(define (flag args name)
  (let loop ([a args])
    (cond [(or (null? a) (null? (cdr a))) #f]
          [(equal? (car a) name) (cadr a)]
          [else (loop (cdr a))])))

(define (switch? args name) (and (member name args) #t))

(define (positional args)
  (let loop ([a args] [out '()])
    (cond [(null? a) (reverse out)]
          [(member (car a) '("--force" "--no-prune")) (loop (cdr a) out)]
          [(string-prefix? (car a) "--")
           (loop (if (null? (cdr a)) '() (cddr a)) out)]
          [else (loop (cdr a) (cons (car a) out))])))

;; The repository root, from this file's own location — `impl-root` is
;; `refimpl/racketmaximus`, so the documentation is two levels up. In a checkout
;; this is the default root and the whole command is `ingest`; on a packaged
;; install the directory does not exist and the operator names one.
(define (repo-root) (simplify-path (build-path impl-root 'up 'up) #f))

;; `docs/` plus the two READMEs, which are the front door and are not under it.
;; `help-markdown-files` takes a single FILE as a root for exactly this.
(define (default-docs-root)
  (define up (repo-root))
  (define d (build-path up "docs"))
  (and (directory-exists? d)
       (append (list (path->string d))
               (for/list ([n (in-list '("README.md" "README.ja.md"))]
                          #:when (file-exists? (build-path up n)))
                 (path->string (build-path up n))))))

(define (locales-dir) (or (tmach-env "LOCALES") (path->string (build-path impl-root "locales"))))

;; ---- status -------------------------------------------------------------------

(define (cmd-status)
  (with-db (lambda (conn)
    (define st (help-stats conn))
    (printf "embedder:   ~a\n" (if (embed-configured?)
                                   (format "~a" (embed-model))
                                   "NOT CONFIGURED (set TMACH_EMBED_URL)"))
    (printf "documents:  ~a\n" (hash-ref st 'documents))
    (printf "chunks:     ~a\n" (hash-ref st 'chunks))
    (printf "model(s):   ~a\n" (let ([m (hash-ref st 'models)])
                                 (if (null? m) "—" (string-join m ", "))))
    (for ([l (in-list (hash-ref st 'locales))])
      (printf "  ~a: ~a document(s), ~a chunk(s), last ingested ~a\n"
              (hash-ref l 'locale) (hash-ref l 'documents) (hash-ref l 'chunks)
              (let ([e (hash-ref l 'updated_epoch)])
                (if (number? e) (date->string* e) "—"))))
    (when (zero? (hash-ref st 'chunks))
      (displayln "")
      (displayln "The corpus is empty, so in-product help has nothing to answer with.")
      (displayln "Run `ingest` against a checkout of the release this instance is running."))
    ;; A model change invalidates every vector and does not raise (EMB‑8), so the
    ;; one state an operator cannot see for themselves is said out loud.
    (let ([m (hash-ref st 'models)])
      (when (and (pair? m) (embed-configured?) (not (member (embed-model) m)))
        (displayln "")
        (printf (string-append "WARNING: the corpus was embedded with ~a and this instance is "
                               "configured for ~a.\nVectors from two checkpoints are not "
                               "comparable and mixing them does not fail — it retrieves\nthe "
                               "wrong passage. Run `clear` then `ingest`.\n")
                (string-join m ", ") (embed-model)))))))

(define (date->string* epoch)
  (define d (seconds->date epoch #f))
  (format "~a-~a-~aT~a:~aZ"
          (date-year d) (pad (date-month d)) (pad (date-day d))
          (pad (date-hour d)) (pad (date-minute d))))

(define (pad n) (if (< n 10) (format "0~a" n) (number->string n)))

;; ---- ingest -------------------------------------------------------------------

(define (cmd-ingest args)
  (define given (positional args))
  (define roots (let ([p given])
                  (cond [(pair? p) p]
                        [(default-docs-root) => values]
                        [else (die (string-append
                                    "no documentation tree given and none found beside this "
                                    "install.\nThis is the normal case on a packaged instance: "
                                    "`docs/` is not in the image.\nName a checkout, e.g. "
                                    "`ingest /path/to/Telemachus/docs`."))])))
  (unless (embed-configured?)
    (die (string-append "no embedding model configured: set TMACH_EMBED_URL (and "
                        "TMACH_EMBED_MODEL).\nThe help corpus is vectors, so there is nothing "
                        "to ingest without one.")))
  (define rel (flag args "--relative-to"))
  (define size (let ([s (flag args "--size")]) (if s (string->number s) CHUNK-SIZE-DEFAULT)))
  (define overlap (let ([s (flag args "--overlap")]) (if s (string->number s) CHUNK-OVERLAP-DEFAULT)))
  (with-db (lambda (conn)
    (define locales (available-locales (locales-dir)))
    (printf "ingesting ~a into the help corpus\n  locales recognised in a path: ~a\n  model: ~a\n"
            (string-join roots ", ") (string-join locales ", ") (embed-model))
    (define rep
      (help-ingest! conn roots
                    #:locales locales
                    #:size size
                    #:overlap overlap
                    #:force? (switch? args "--force")
                    #:prune? (not (switch? args "--no-prune"))
                    ;; the stored path is what a citation shows, so it is
                    ;; relative to the tree's own parent unless told otherwise
                    ;; With no roots named, the default set spans `docs/` and
                    ;; the two READMEs, so paths are relative to the REPOSITORY
                    ;; root and read exactly as they do in a checkout.
                    #:relative-to (or rel
                                      (if (null? given)
                                          (path->string (repo-root))
                                          (common-parent roots)))
                    #:on-progress (lambda (p n) (printf "  ~a (~a chunk(s))\n" p n))))
    (printf "\ningested ~a document(s), ~a chunk(s), ~a embedding request(s)\n"
            (length (hash-ref rep 'ingested)) (hash-ref rep 'chunks) (hash-ref rep 'requests))
    (printf "unchanged: ~a    empty: ~a    forgotten: ~a\n"
            (length (hash-ref rep 'unchanged)) (length (hash-ref rep 'empty))
            (length (hash-ref rep 'pruned)))
    (for ([p (in-list (hash-ref rep 'pruned))])
      (printf "  forgotten (no longer in the tree): ~a\n" p)))))

;; So `ingest /path/to/checkout/docs` stores `docs/ops/container.md` rather than
;; `ops/container.md` — the path is what a citation shows, and it should be the
;; one a reader can find in the repository.
(define (common-parent roots)
  (and (= 1 (length roots))
       (let ([p (simplify-path (path->complete-path (car roots)) #f)])
         (define-values (base _name _dir) (split-path p))
         (and (path? base) (path->string base)))))

;; ---- clear --------------------------------------------------------------------

(define (cmd-clear)
  (with-db (lambda (conn)
    (printf "cleared ~a document(s) from the help corpus\n" (help-clear! conn)))))

;; ---- main ---------------------------------------------------------------------

(define (usage)
  (displayln "usage: telemachus-help <status|ingest|clear> [roots …] [options]")
  (displayln "")
  (displayln "  status                      what the corpus holds, and whether it is stale")
  (displayln "  ingest [roots …]            read Markdown into the corpus (default: docs/ + both READMEs)")
  (displayln "    --force                   re-embed every file, not only changed ones")
  (displayln "    --no-prune                keep corpus entries whose file is absent")
  (displayln "    --relative-to DIR         what stored paths are relative to")
  (displayln "    --size N / --overlap N    chunking, for a recall measurement")
  (displayln "  clear                       empty the corpus (needed after a model change)")
  (exit 2))

(module+ main
  (define argv (vector->list (current-command-line-arguments)))
  (when (null? argv) (usage))
  (case (car argv)
    [("status") (cmd-status)]
    [("ingest") (cmd-ingest (cdr argv))]
    [("clear") (cmd-clear)]
    [else (usage)]))
