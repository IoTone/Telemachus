#lang racket/base

;; Example third-party plugin. It knows nothing about Telemachus internals: it
;; provides `tools`, a list of (name schema permission handler) tuples, where the
;; schema is a plain OpenAI-compatible function-tool JSON and the handler is
;;   (conn principal args) -> string.
;; This whole file is the extension contract.

(require racket/string racket/port
         (only-in "../../domain/sched/scheduler.rkt" register-job-kind!)
         (only-in "../../domain/repo/extract.rkt" register-extractor!))

(provide tools routes init! migrations)

(define word-count-schema
  (hasheq 'type "function"
          'function (hasheq
                     'name "word_count"
                     'description "Count the number of words in a piece of text."
                     'parameters (hasheq
                                  'type "object"
                                  'properties (hasheq 'text (hasheq 'type "string"
                                                                    'description "The text to count words in"))
                                  'required '("text")))))

;; conn/principal are available for tools that need platform data; this one is pure.
(define (word-count conn principal args)
  (define text (let ([v (hash-ref args 'text "")]) (if (string? v) v "")))
  (format "~a words" (length (string-split text))))

;; ---- a plugin that owns data (issue #121) -----------------------------------
;; `migrations` is a list of (list name sql ...). The platform applies them
;; through its OWN runner, so they are ordered, recorded in `schema_migrations`
;; as `x.example-tools.<name>`, each inside a transaction, and run once — rather
;; than raced with `CREATE TABLE IF NOT EXISTS` on the first request, which is
;; what a plugin had to do before and which loses on PostgreSQL under
;; concurrency.
;;
;; EVERY TABLE AND INDEX MUST BE NAMED `x_example-tools_…` with the dashes turned
;; into underscores — `x_example_tools_*`. The loader refuses anything else, so a
;; plugin cannot land on a core table or on another plugin's, and an operator
;; reading `\dt` can see who owns what.
;;
;; The SQL has to be dialect-neutral: SQLite and PostgreSQL both ship. That is
;; the same obligation the platform's own migrations carry and nothing can check
;; it for you — `raco test test/migration-tests.rkt` is what catches it for the
;; platform, and a plugin wants its own equivalent.
(define migrations
  (list
   (list "notes-seen"
         (string-append "CREATE TABLE x_example_tools_seen ("
                        "  id TEXT PRIMARY KEY,"
                        "  team_id TEXT NOT NULL,"
                        "  word_count INTEGER NOT NULL,"
                        "  at_epoch BIGINT NOT NULL)")
         "CREATE INDEX x_example_tools_seen_team ON x_example_tools_seen (team_id)")))

(define tools
  (list (list "word_count" word-count-schema "chat:use" word-count)))

;; An authenticated HTTP route (slice 63): mounted by the platform at
;; /api/x/example-tools/word-count. `args` carries 'params (path), 'query and
;; 'body; the result is a jsexpr the server answers with as JSON. A user error is
;; the caller's 400. The permission is checked by the server before the handler
;; runs, like a tool's.
(define (word-count-route conn principal args)
  (define text (or (hash-ref (hash-ref args 'query) 'text #f)
                   (let ([b (hash-ref args 'body)]) (and (hash? b) (hash-ref b 'text #f)))))
  (unless (string? text) (raise-user-error 'word_count "text is required"))
  (hasheq 'words (length (string-split text)) 'chars (string-length text)))

(define routes
  (list (list "GET"  "/word-count" "chat:use" word-count-route "Count the words in ?text=.")
        (list "POST" "/word-count" "chat:use" word-count-route "Count the words in {text}.")))

;; A background JOB KIND (issue #21). `init!` runs at load with full SDK access,
;; and this is the documented route for a plugin to add one. The platform binds
;; the plugin's identity while init! runs, so the kind MUST be named
;; `x.<plugin-id>.<name>` — a plugin can never take a core kind's name
;; (`flow.step`, `infer.chat`) or another plugin's, and a violation fails this
;; plugin's load rather than surfacing at claim time.
;;
;; A kind's handler is (conn principal payload) -> jsexpr, run by the scheduler:
;; the job carries the enqueuing team and user, so the per-team concurrency cap,
;; quota admission, the org gate, cancellation and the lease all apply to it
;; exactly as they do to a core kind. Nothing is inherited from the plugin.
(define (word-count-job conn principal payload)
  (define text (let ([v (hash-ref payload 'text "")]) (if (string? v) v "")))
  (hasheq 'words (length (string-split text))))

;; ---- an EXTRACTOR (LAY-7) --------------------------------------------------------
;; The platform reads text, markup, DOCX and PDF. A deployment that needs another
;; format — or a better reader for one it already has — registers an extractor for
;; a content type and the search index, doc_text and the whole document pipeline
;; pick it up with no other change. Registering a type the platform already reads
;; REPLACES its reader, which is how a local OCR engine takes over application/pdf.
;;
;; The contract is the platform's own: (in content-type) -> (values text-or-#f
;; reason-or-#f), where a reason is one of unsupported / missing-tool / needs-ocr
;; / failed. Reaching a non-Racket engine is this procedure's own business —
;; the built-in PDF reader is a pipe to `pdftotext`, and a real OCR plugin would
;; shell out to YomiToku or PaddleOCR the same way.
;;
;; RTF is the demonstration because the platform genuinely cannot read it: an
;; unreadable document is invisible to search, which is the gap a format plugin
;; closes.
(define (extract-rtf in content-type)
  (define raw (port->string in))
  (cond
    [(not (string-prefix? (string-trim raw) "{\\rtf")) (values #f 'failed)]
    [else
     ;; Good enough for an index, which is all this is — not a parser. A control
     ;; word becomes a SPACE rather than nothing: in RTF the space after one is a
     ;; delimiter, so `inspected\b0 today` is correctly two adjacent words, and
     ;; deleting the control word outright would index "inspectedtoday", which
     ;; matches neither search term.
     (define no-controls (regexp-replace* #px"\\\\[a-zA-Z]+-?[0-9]*[ ]?" raw " "))
     (define no-braces (regexp-replace* #px"[{}]" no-controls " "))
     (values (string-trim (regexp-replace* #px"\\s+" no-braces " ")) #f)]))

(define (init!)
  (register-job-kind! "x.example-tools.word-count" word-count-job)
  (register-extractor! "application/rtf" extract-rtf))
