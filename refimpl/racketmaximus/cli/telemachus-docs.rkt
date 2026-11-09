#lang racket/base

;; #128 job 2: operator-facing variables are read through ONE accessor,
;; which tries TMACH_<name> and falls back to TELEMACHUS_<name>.
(require (only-in "../config.rkt" tmach-env))

;; cli/telemachus-docs.rkt — generate the reference documentation from the source
;; of truth, and gate drift (slice 60, DOCGEN-1…6).
;;
;;   telemachus-docs describe                         # the model, as JSON, to stdout
;;   telemachus-docs render  [--out DIR] [--locale xx] [--locales DIR]
;;   telemachus-docs check   [--out DIR] [--locale xx] [--locales DIR]
;;       regenerate, diff, exit 1 on drift. With no --locale it checks English
;;       AND every locale directory committed under --out, derived from what is
;;       there rather than from a list anybody has to remember.
;;
;; `describe` EVALUATES the modules — the tool registry, the plugin loader, the
;; workflow specs, the permission catalog, the route table — and emits one JSON
;; model. `render` turns the model into Markdown under docs/reference/ plus
;; strings.json, the JSON surface that makes every description a `doc.*` message
;; the Localization Manager can translate. `check` is the CI gate: byte-identical
;; output or a non-zero exit.
;;
;; Deterministic on purpose (DOCGEN-6): every list is sorted, every object's keys
;; are written in sorted order, and the app version is the only input that is not
;; source. A hasheq's iteration order is NOT stable across Racket processes, so
;; nothing here calls write-json on a hash; see `json-out`.

(require racket/list racket/string racket/file racket/port racket/path
         json
         "../config.rkt"
         "../domain/agent/registry.rkt"
         "../domain/agent/plugins.rkt"
         (only-in "../domain/agent/tools.rkt")            ; registers the built-in catalog
         (only-in "../domain/repo/index-tools.rkt")       ; …and the indexing tools
         (only-in "../domain/repo/doc-tools.rkt")         ; …and the pipeline tools
         (only-in "../domain/kg/kg-tools.rkt")            ; …and the knowledge-graph tools
         ;; …and the retrieval tool (#189 step 6). It needs a line of its own where
         ;; `index-tools` and `embed-tools` would have been covered anyway: the CLI
         ;; loads the plugins, and `doc-indexer` requires both of those for its two
         ;; workflows, so their tools reach the reference either way. NOTHING owns a
         ;; workflow over `repo_retrieve`, so without this line it is registered only
         ;; by `server/main.rkt` — the tool would be live on every instance and absent
         ;; from the generated reference, with the drift gate green because the
         ;; committed page was rendered in that same state. #110 r3's side-effect-
         ;; require trap, met from the generator's side.
         (only-in "../domain/repo/retrieve-tools.rkt")
         ;; #192's two, for the same reason. `transcribe-documents` lives in
         ;; `doc-indexer`, which does require this module — but relying on that is
         ;; relying on a plugin being loaded, and the CLI skips symlinked plugins
         ;; deliberately.
         (only-in "../domain/repo/voice-tools.rkt")
         ;; #245's one, same trap again: `note_autotag` is registered by
         ;; `note-tools.rkt`, which the SERVER instantiates through
         ;; server/api/content.rkt and no plugin owns at all — so without this
         ;; line the tool is live on every instance and absent from tools.md,
         ;; with the drift gate agreeing because the committed page was rendered
         ;; in that state.
         (only-in "../domain/notes/note-tools.rkt")
         "../domain/flow/run.rkt"
         "../domain/flow/spec.rkt"
         "../domain/authz/permissions.rkt"
         "../domain/i18n/catalog.rkt"
         "../server/routes.rkt")

;; Exported FOR test/openapi-tests.rkt. #110 r4's rule is that an export with a
;; test behind it is not an over-wide export; nothing else in the tree requires
;; this module, and `oa-paths`' refusal in particular cannot be reached any other
;; way — the committed document is by definition one that did not collide.
(provide describe render-openapi route-key route-id ROUTE-ID-PREFIX
         oa-path-template oa-parameters oa-tag oa-security oa-paths
         OPENAPI-VERSION OPENAPI-NOTE)

(define (usage)
  (eprintf "usage: telemachus-docs <describe|render|check> [--out DIR] [--locale xx] [--locales DIR]\n")
  (exit 2))

(define (split-flags args)
  (let loop ([xs args] [pos '()] [opts (hasheq)])
    (cond
      [(null? xs) (values (reverse pos) opts)]
      [(and (member (car xs) '("--out" "--locale" "--locales")) (pair? (cdr xs)))
       (loop (cddr xs) pos (hash-set opts (string->symbol (substring (car xs) 2)) (cadr xs)))]
      [else (loop (cdr xs) (cons (car xs) pos) opts)])))

(define (repo-root) (simplify-path (build-path impl-root 'up 'up)))
(define (default-out) (build-path (repo-root) "docs" "reference"))
(define (locales-dir opts) (hash-ref opts 'locales (or (tmach-env "LOCALES") (path->string (build-path impl-root "locales")))))

;; ---- describe --------------------------------------------------------------------
(define (js-get h k [d 'null]) (if (hash? h) (hash-ref h k d) d))

(define (describe)
  ;; #:skip-links? — the committed reference describes the COMMITTED tree. A
  ;; downstream plugin symlinked in for local development is somebody else's, and
  ;; documenting it here would fail the drift gate everywhere that link is absent.
  (load-plugins! (build-path impl-root "plugins") #:skip-links? #t)
  (define tools
    (sort
     (for/list ([t (in-list (all-tools))])
       (define fn (js-get (tool-schema t) 'function (hasheq)))
       (hasheq 'name (tool-name t)
               'description (let ([d (js-get fn 'description "")]) (if (string? d) d ""))
               'permission (or (tool-perm t) 'null)
               'source (tool-source t)
               'agent (tool-agent? t)
               'parameters (js-get fn 'parameters (hasheq))))
     string<? #:key (lambda (t) (hash-ref t 'name))))
  (define workflows
    (sort
     (for/list ([w (in-list (plugin-workflows))])
       (define spec (hash-ref w 'spec))
       (hasheq 'slug (spec-slug spec)
               'plugin (hash-ref w 'plugin)
               'name (hash-ref spec 'name (spec-slug spec))
               'description (hash-ref spec 'description "")
               'version (hash-ref spec 'version 1)
               'max_steps (spec-max-steps spec)
               'start (spec-start spec)
               'input (hash-ref spec 'input (hasheq))
               'steps (spec-steps spec)))
     string<? #:key (lambda (w) (hash-ref w 'slug))))
  (define permissions
    (for/list ([p (in-list (all-permissions))])
      (hasheq 'name p 'tier (permission-tier p) 'description (permission-doc p))))
  (define roles
    (for/list ([k (in-list builtin-role-keys)])
      (hasheq 'key k 'name (hash-ref builtin-role-names k k)
              'tier (if (org-role-key? k) "org" "team")
              'permissions (hash-ref builtin-role-perms k '()))))
  (define routes
    (for/list ([r (in-list ROUTES)])
      (hasheq 'method (rt-method r) 'path (rt-path r) 'handler (symbol->string (rt-handler r))
              'auth (symbol->string (rt-auth r)) 'permission (or (rt-perm r) 'null)
              'scope (symbol->string (rt-scope r))
              'feature (or (rt-feature r) 'null) 'description (rt-doc r))))
  (define plugins
    (sort (for/list ([p (in-list (loaded-plugins))])
            (hasheq 'id (hash-ref p 'id) 'name (hash-ref p 'name) 'version (hash-ref p 'version)
                    'description (hash-ref p 'description "")
                    'tools (sort (hash-ref p 'tools '()) string<?)
                    'workflows (sort (hash-ref p 'workflows '()) string<?)
                    ;; the plugin's job kinds (issue #21) — the model carried them
                    ;; from the loader but this projection dropped the key, so the
                    ;; column rendered "—" for a plugin that has one
                    'job_kinds (sort (hash-ref p 'job_kinds '()) string<?)
                    ;; LAY-7: the content types this plugin claims a reader for.
                    ;; Projected explicitly for the same reason job_kinds is —
                    ;; a key dropped here renders as "—" for a plugin that has one.
                    'extractors (sort (hash-ref p 'extractors '()) string<?)
                    'routes (sort (hash-ref p 'routes '()) string<?)))
          string<? #:key (lambda (p) (hash-ref p 'id))))
  ;; the plugins' authenticated routes, in api.md beside the core ones
  (define proutes
    (for/list ([r (in-list (plugin-routes))])
      (hasheq 'method (hash-ref r 'method) 'path (plugin-route-path (hash-ref r 'plugin) (hash-ref r 'path))
              'handler (string-append "plugin:" (hash-ref r 'plugin))
              'auth "bearer" 'permission (or (hash-ref r 'perm) 'null) 'scope "role" 'feature 'null
              'description (hash-ref r 'doc) 'plugin (hash-ref r 'plugin))))
  ;; every route permission must be described, like every role permission is
  (for ([r (in-list ROUTES)]) (when (rt-perm r) (permission-doc (rt-perm r))))
  (for ([r (in-list proutes)]) (when (string? (hash-ref r 'permission)) (permission-doc (hash-ref r 'permission))))
  (hasheq 'version app-version 'tools tools 'workflows workflows
          'permissions permissions 'roles roles 'routes routes 'plugin_routes proutes 'plugins plugins))

;; ---- deterministic JSON ---------------------------------------------------------------
(define (json-out v out [indent 0])
  (define pad (make-string indent #\space))
  (define pad+ (make-string (+ indent 2) #\space))
  (cond
    [(hash? v)
     (define ks (sort (hash-keys v) string<? #:key (lambda (k) (format "~a" k))))
     (cond
       [(null? ks) (write-string "{}" out)]
       [else
        (write-string "{\n" out)
        (for ([k (in-list ks)] [i (in-naturals)])
          (write-string pad+ out)
          (write-json (format "~a" k) out) (write-string ": " out)
          (json-out (hash-ref v k) out (+ indent 2))
          (write-string (if (< i (sub1 (length ks))) ",\n" "\n") out))
        (write-string pad out) (write-string "}" out)])]
    [(list? v)
     (cond
       [(null? v) (write-string "[]" out)]
       [else
        (write-string "[\n" out)
        (for ([x (in-list v)] [i (in-naturals)])
          (write-string pad+ out)
          (json-out x out (+ indent 2))
          (write-string (if (< i (sub1 (length v))) ",\n" "\n") out))
        (write-string pad out) (write-string "]" out)])]
    [else (write-json v out)]))

(define (json-string v) (let ([o (open-output-string)]) (json-out v o) (write-string "\n" o) (get-output-string o)))

;; ---- prose ids (the localization surface) ----------------------------------------------
;; ONE derivation with TWO askers: the `doc.route.*` message id and the OpenAPI
;; operationId below. A second spelling of "which route is this" would drift, and
;; what it would cost is the ability to map an operation in openapi.json back to
;; the catalog entry that carries its prose. `route-id` is a COMMITTED catalog key
;; (it is in locales/ja.json), so this must keep producing exactly what it always
;; has, trailing dot and all: the path "/" has no segments and its key is "get.".
(define (route-key r)
  (string-append (string-downcase (hash-ref r 'method)) "."
                 (string-join (for/list ([s (in-list (string-split (hash-ref r 'path) "/"))]
                                         #:unless (string=? s ""))
                                (regexp-replace* #px"^[:*]" s ""))
                              ".")))

(define ROUTE-ID-PREFIX "doc.route.")
(define (route-id r) (string-append ROUTE-ID-PREFIX (route-key r)))

(define (strings-of model)
  (define h (make-hash))
  (for ([t (in-list (hash-ref model 'tools))])
    (hash-set! h (string-append "doc.tool." (hash-ref t 'name)) (hash-ref t 'description))
    (for ([(pk pv) (in-hash (hash-ref (hash-ref t 'parameters) 'properties (hasheq)))])
      (define d (js-get pv 'description #f))
      (when (string? d) (hash-set! h (format "doc.tool.~a.~a" (hash-ref t 'name) pk) d))))
  (for ([w (in-list (hash-ref model 'workflows))])
    (hash-set! h (string-append "doc.workflow." (hash-ref w 'slug) ".name") (hash-ref w 'name))
    (hash-set! h (string-append "doc.workflow." (hash-ref w 'slug)) (hash-ref w 'description)))
  (for ([p (in-list (hash-ref model 'permissions))])
    (hash-set! h (string-append "doc.perm." (hash-ref p 'name)) (hash-ref p 'description)))
  (for ([r (in-list (append (hash-ref model 'routes) (hash-ref model 'plugin_routes '())))])
    (hash-set! h (route-id r) (hash-ref r 'description)))
  (for ([p (in-list (hash-ref model 'plugins))])
    (hash-set! h (string-append "doc.plugin." (hash-ref p 'id)) (hash-ref p 'description)))
  ;; an empty description is not a message — and not documentation either
  (for ([(k v) (in-hash h)]) (when (string=? (string-trim v) "") (hash-remove! h k)))
  (for/hash ([(k v) (in-hash h)]) (values (string->symbol k) v)))

;; ---- rendering --------------------------------------------------------------------------
;; `L` resolves a prose id to the locale's text, falling back to English (the
;; model's own string). Structure is never translated.
(define (make-localizer locale ldir)
  (cond
    [(or (not locale) (string=? locale "en")) (lambda (id en) en)]
    [else
     (define path (build-path ldir (string-append locale ".json")))
     (unless (file-exists? path) (error 'telemachus-docs "no catalog for locale ~a at ~a" locale path))
     (define cat (read-catalog path))
     (lambda (id en)
       (define m (catalog-ref cat id))
       (define t (and m (msg-text m)))
       (if (and (string? t) (not (string=? t ""))) t en))]))

(define (md-escape s) (regexp-replace* #rx"\\|" (regexp-replace* #rx"\n" s " ") "\\\\|"))
(define (code s) (string-append "`" s "`"))
(define (table headers rows)
  (string-append
   "| " (string-join headers " | ") " |\n"
   "|" (string-join (for/list ([_ headers]) "---") "|") "|\n"
   (string-join (for/list ([r (in-list rows)]) (string-append "| " (string-join (map md-escape r) " | ") " |")) "\n")
   "\n"))

(define (type-of-param pv)
  (define t (js-get pv 'type #f))
  (define e (js-get pv 'enum #f))
  (define items (js-get pv 'items #f))
  (string-append (cond [(string? t) t] [(list? t) (string-join t "|")] [else "any"])
                 (if (and (hash? items) (string? (js-get items 'type #f))) (string-append " of " (js-get items 'type)) "")
                 (if (list? e) (string-append " (" (string-join (map (lambda (x) (format "~a" x)) e) ", ") ")") "")))

(define (render-tools model L)
  (define tools (hash-ref model 'tools))
  (string-append
   "# Tools\n\n"
   "Every tool a workflow step may use, from `define-tool` declarations and plugin "
   "registrations. Each tool checks its own permission when invoked; a workflow step "
   "also needs `tools:invoke`.\n\n"
   "**Agent** says whether the conversational agent is OFFERED the tool. A tool whose "
   "required arguments are spec-authored — a label set, a JSON Schema, a template and "
   "its data, a form's own field names — is a workflow tool: nobody asks for it in a "
   "sentence, and a model handed one with no such structure invents it. It is not a "
   "permission and not the per-team switch; a workflow tool is registered, documented "
   "and dispatchable exactly as any other. Keeping them off that surface is also what "
   "makes the agent's whole tool list fit a 4,096-token window.\n\n"
   (table '("Tool" "Agent" "Permission" "Source" "Description")
          (for/list ([t (in-list tools)])
            (list (code (hash-ref t 'name))
                  (if (hash-ref t 'agent #t) "yes" "—")
                  (let ([p (hash-ref t 'permission)]) (if (string? p) (code p) "—"))
                  (hash-ref t 'source)
                  (L (string-append "doc.tool." (hash-ref t 'name)) (hash-ref t 'description)))))
   "\n"
   (apply string-append
          (for/list ([t (in-list tools)])
            (define params (hash-ref t 'parameters))
            (define props (js-get params 'properties (hasheq)))
            (define required (let ([r (js-get params 'required '())]) (if (list? r) r '())))
            (define pnames (sort (map (lambda (k) (format "~a" k)) (hash-keys props)) string<?))
            (string-append
             "## " (code (hash-ref t 'name)) "\n\n"
             (L (string-append "doc.tool." (hash-ref t 'name)) (hash-ref t 'description)) "\n\n"
             "Permission: " (let ([p (hash-ref t 'permission)]) (if (string? p) (code p) "none")) " · source: " (hash-ref t 'source) "\n\n"
             (if (null? pnames)
                 "No parameters.\n\n"
                 (table '("Parameter" "Type" "Required" "Description")
                        (for/list ([n (in-list pnames)])
                          (define pv (hash-ref props (string->symbol n)))
                          (list (code n) (type-of-param pv) (if (member n required) "yes" "no")
                                (L (format "doc.tool.~a.~a" (hash-ref t 'name) n) (let ([d (js-get pv 'description "")]) (if (string? d) d "")))))))
             "\n")))))

(define (value->md v)
  (cond [(string? v) (code v)]
        [(hash? v) (code (json-line v))]
        [(list? v) (code (json-line v))]
        [else (code (format "~a" v))]))

;; one-line JSON with sorted keys, for step bindings
(define (json-line v)
  (cond
    [(hash? v) (string-append "{" (string-join (for/list ([k (in-list (sort (hash-keys v) string<? #:key (lambda (k) (format "~a" k))))])
                                                 (string-append (format "~s" (format "~a" k)) ":" (json-line (hash-ref v k)))) ",") "}")]
    [(list? v) (string-append "[" (string-join (map json-line v) ",") "]")]
    [(string? v) (format "~s" v)]
    [(eq? v 'null) "null"]
    [(boolean? v) (if v "true" "false")]
    [else (format "~a" v)]))

(define (render-workflows model L)
  (define wfs (hash-ref model 'workflows))
  (string-append
   "# Workflows\n\n"
   "Workflows shipped by plugins. Each is a validated spec (the public contract, WF‑9); "
   "a team sees them under `GET /api/workflows` and runs one with "
   "`POST /api/workflows/<slug>/run {input}`. Declared inputs are required and typed.\n\n"
   (table '("Workflow" "Plugin" "Version" "Steps" "Description")
          (for/list ([w (in-list wfs)])
            (list (code (hash-ref w 'slug)) (hash-ref w 'plugin) (format "~a" (hash-ref w 'version))
                  (format "~a" (length (hash-ref w 'steps)))
                  (L (string-append "doc.workflow." (hash-ref w 'slug)) (hash-ref w 'description)))))
   "\n"
   (apply string-append
          (for/list ([w (in-list wfs)])
            (define input (hash-ref w 'input))
            (define ikeys (sort (map (lambda (k) (format "~a" k)) (hash-keys input)) string<?))
            (string-append
             "## " (code (hash-ref w 'slug)) " — " (L (string-append "doc.workflow." (hash-ref w 'slug) ".name") (hash-ref w 'name)) "\n\n"
             (L (string-append "doc.workflow." (hash-ref w 'slug)) (hash-ref w 'description)) "\n\n"
             "Plugin: " (code (hash-ref w 'plugin)) " · version " (format "~a" (hash-ref w 'version))
             " · max steps " (format "~a" (hash-ref w 'max_steps)) " · starts at " (code (hash-ref w 'start)) "\n\n"
             (if (null? ikeys)
                 "Takes no input.\n\n"
                 (string-append "Input:\n\n"
                                (table '("Name" "Type")
                                       (for/list ([k (in-list ikeys)]) (list (code k) (format "~a" (hash-ref input (string->symbol k))))))
                                "\n"))
             "Steps:\n\n"
             (table '("Step" "Uses" "Binding" "Next")
                    (for/list ([st (in-list (hash-ref w 'steps))])
                      (define uses (hash-ref st 'uses))
                      (define binding
                        (cond
                          [(equal? uses "map")
                           (string-append "over " (value->md (hash-ref st 'over)) " → "
                                          (code (hash-ref (hash-ref st 'step) 'uses)) " with "
                                          (value->md (hash-ref (hash-ref st 'step) 'with (hasheq))))]
                          [(equal? uses "choice")
                           (string-append "when " (value->md (hash-ref st 'when)) " then " (code (hash-ref st 'then))
                                          (let ([e (hash-ref st 'else #f)]) (if e (string-append " else " (code e)) "")))]
                          [else (value->md (hash-ref st 'with (hasheq)))]))
                      (define nxt (cond [(hash-ref st 'end #f) "end"]
                                        [(hash-ref st 'next #f) => (lambda (n) (code n))]
                                        [else "next in order"]))
                      ;; A MAP'S RETRY LIVES ON THE TEMPLATE, not on the step —
                      ;; `MAP-STEP-KEYS` is `(uses with retry)` — so reading it off
                      ;; `st` showed nothing for exactly the fan-outs that ask for
                      ;; one, which is every shipped drain. Found while surfacing
                      ;; `on_error` below.
                      (define tmpl (if (equal? uses "map") (hash-ref st 'step (hasheq)) st))
                      (define retry (let ([r (hash-ref tmpl 'retry #f)])
                                      (if (hash? r) (format " · retry ~a" (hash-ref r 'max 0)) "")))
                      ;; WF-11: which fan-outs tolerate a failing child is part of
                      ;; the public contract (WF-9), so the generated page says it.
                      ;; `"fail"` is the default and is left unsaid — a column that
                      ;; is only ever one value tells a reader nothing (#178).
                      (define oe (let ([v (hash-ref st 'on_error #f)])
                                   (if (and (equal? uses "map") (equal? v "continue"))
                                       " · on a child's error, continue"
                                       "")))
                      (list (code (hash-ref st 'id)) (code uses) binding
                            (string-append nxt retry oe))))
             "\n")))))

(define (render-permissions model L)
  (define perms (hash-ref model 'permissions))
  (define roles (hash-ref model 'roles))
  (define (granted? role p)
    (for/or ([g (in-list (hash-ref role 'permissions))]) (perm-matches? g p)))
  (string-append
   "# Permissions\n\n"
   "Permissions are `resource:action` strings; roles are named sets of them. "
   "`instance:*` is held only by the operator and `org:*` only by a company's org role — "
   "neither is reachable from a team role, whatever wildcard it grants. A resource's "
   "owner holds every team-tier permission on it (owner-ok), and a grant on one "
   "resource delegates the permission it names.\n\n"
   "## Catalog\n\n"
   (table '("Permission" "Tier" "Description")
          (for/list ([p (in-list perms)])
            (list (code (hash-ref p 'name)) (hash-ref p 'tier)
                  (L (string-append "doc.perm." (hash-ref p 'name)) (hash-ref p 'description)))))
   "\n## Built-in roles\n\n"
   (table '("Role" "Tier" "Grants")
          (for/list ([r (in-list roles)])
            (list (string-append (hash-ref r 'name) " (" (code (hash-ref r 'key)) ")") (hash-ref r 'tier)
                  (string-join (map code (hash-ref r 'permissions)) ", "))))
   "\n## Role matrix\n\n"
   "Which built-in role covers which permission (wildcards expanded).\n\n"
   (table (append '("Permission") (for/list ([r (in-list roles)]) (hash-ref r 'key)))
          (for/list ([p (in-list perms)] #:unless (regexp-match? #rx"\\*" (hash-ref p 'name)))
            (append (list (code (hash-ref p 'name)))
                    (for/list ([r (in-list roles)])
                      (if (and (granted? r (hash-ref p 'name))
                               ;; instance:* is never reachable from a role's wildcard
                               (not (and (equal? (hash-ref p 'tier) "instance") (equal? (hash-ref r 'tier) "team")))
                               (not (and (equal? (hash-ref p 'tier) "org") (equal? (hash-ref r 'tier) "team"))))
                          "✓" "")))))
   "\n"))

(define (render-api model L)
  (define routes (hash-ref model 'routes))
  (string-append
   "# HTTP API\n\n"
   "Every route the server dispatches, in matching order, from the declared route table "
   "(`server/routes.rkt`). `auth` is how a route authenticates: **public** needs no "
   "credential; **bearer** a session or API token; **provision** the hosted-mode "
   "provisioning token; **superadmin** and **org-admin** the two multi-tenancy planes. "
   "The permission column says what a caller needs. A **role** permission is checked "
   "by the dispatcher before the handler runs, so the table is the enforcement and not "
   "a description of it. A **resource** permission is weighed against the particular "
   "note or document by `can?`, which also admits the OWNER and anyone holding a "
   "matching grant — so a caller whose role does not carry it may still be admitted "
   "for one object, which is what sharing is. A feature flag, when named, must be on "
   "for the team.\n\n"
   "Path segments written `:name` are parameters; `*name` takes the rest of the path.\n\n"
   "A machine-readable form of this same table is "
   "[openapi.json](openapi.json) (OpenAPI 3.1), generated from the same source and "
   "gated by the same drift check. **It carries no request or response schemas** — "
   "those are not declared anywhere in the source either page is generated from, so "
   "neither page can tell you what to send. What the table declares rides in "
   "`x-tmach-*` on each operation.\n\n"
   (table '("Method" "Path" "Auth" "Permission" "Checked" "Feature" "Description")
          (for/list ([r (in-list routes)])
            (list (hash-ref r 'method) (code (hash-ref r 'path)) (hash-ref r 'auth)
                  (let ([p (hash-ref r 'permission)]) (if (string? p) (code p) "—"))
                  (let ([p (hash-ref r 'permission)])
                    (if (string? p) (hash-ref r 'scope "role") "—"))
                  (let ([f (hash-ref r 'feature)]) (if (string? f) (code f) "—"))
                  (L (route-id r) (hash-ref r 'description)))))
   "\n"
   (let ([pr (hash-ref model 'plugin_routes '())])
     (if (null? pr) ""
         (string-append
          "## Plugin routes\n\n"
          "Routes contributed by loaded plugins, mounted under `/api/x/<plugin>/`. Every one "
          "requires a bearer token; the permission, when named, is checked before the "
          "plugin's handler runs. Matched after the core routes above.\n\n"
          (table '("Method" "Path" "Plugin" "Permission" "Description")
                 (for/list ([r (in-list pr)])
                   (list (hash-ref r 'method) (code (hash-ref r 'path)) (code (hash-ref r 'plugin))
                         (let ([p (hash-ref r 'permission)]) (if (string? p) (code p) "—"))
                         (L (route-id r) (hash-ref r 'description)))))
          "\n")))))


;; ---- OpenAPI 3.1 (issue #227 slice 2a) ------------------------------------------------
;;
;; A machine-readable form of what the ROUTE TABLE DECLARES, and deliberately
;; nothing more: method, path, how a route authenticates, the permission it
;; enforces and whether the dispatcher pre-checks it by role, the feature flag,
;; the handler key.
;;
;; IT CARRIES NO REQUEST OR RESPONSE SCHEMAS, AND SAYS SO IN ITS OWN
;; `info.description`. They do not exist in declarative form anywhere in this
;; tree — they are read out of 290-odd handler bodies — so emitting them is not a
;; generation problem but a contract decision about where a shape LIVES (a field
;; on the `R` entry, a form beside the handler, a catalogue), with 259 core
;; instances behind it. That is #227 slice 2b. A reference that implied
;; completeness would be worse than no reference at all: the whole value of this
;; one is that every field in it is a field somebody declared.
;;
;; `responses` is omitted entirely rather than stubbed. OpenAPI 3.1 made it
;; optional — 3.0 required it — and a fabricated `"200": {"description": "OK"}` on
;; every operation would be this generator asserting a status code it has not
;; read, for the 202s, 204s and 302s as well as the 200s.
;;
;; IT IS A PAGE OF `render`, NOT A SUBCOMMAND OF ITS OWN. #227 proposed an
;; `openapi` target; a target needs its own line in ci.yml, and a gate CI has to
;; remember is a gate that rots — this file's own `check --locale` defect, where
;; `--locale` was parsed and then silently ignored and the Japanese reference
;; drifted for five slices. As a page it is written by `render`, diffed by
;; `check` and covered by the workflow that already runs.
;;
;; It adds NO new localization strings: every description is the `doc.route.*`
;; message api.md already renders, resolved through the same `L`.

(define OPENAPI-VERSION "3.1.0")

(define OPENAPI-NOTE
  (string-append
   "Generated by `telemachus-docs` from the declared route table "
   "(`server/routes.rkt`) — do not edit by hand; `telemachus-docs check` fails CI "
   "on drift. The Markdown form of the same table, with the prose in context, is "
   "`api.md` beside this file.\n\n"
   "**This document carries no request or response schemas, and no `responses` at "
   "all.** It describes what the route table declares — the path, how the route "
   "authenticates, the permission it enforces, the feature flag it sits behind — "
   "and the request and response shapes are not declared anywhere in the source "
   "it is generated from, so there is nothing here to generate them from. Treat a "
   "missing body or response as unknown, never as absent. Supplying them is a "
   "separate piece of work that has to decide where a shape lives before anything "
   "can emit one.\n\n"
   "What the table does declare rides in `x-tmach-*` on each operation. "
   "`x-tmach-auth` is how the route authenticates: `public` needs no credential, "
   "`bearer` a session or API token, `provision` the hosted-mode provisioning "
   "token, `superadmin` and `org-admin` the two multi-tenancy planes (whose "
   "feature gate answers 404 when multi-tenancy is off, so a single-tenant "
   "instance does not admit that these routes exist), and `handler` the one route "
   "that accepts a bearer OR a bundle ticket and decides for itself. "
   "`x-tmach-permission` is what a caller needs, and `x-tmach-permission-checked` "
   "says who checks it: `role` is pre-checked by the dispatcher before the handler "
   "runs, so the declaration is the enforcement; `resource` is weighed against a "
   "particular note or document by `can?`, which also admits the owner and anyone "
   "holding a matching grant — so a caller whose role does not carry it may still "
   "be admitted for one object, which is what sharing is.\n\n"
   "Two shapes here are the generator's and not the table's. A path parameter "
   "written `{name}` that carries `x-tmach-rest` takes the REST of the path and its "
   "value may contain `/`: OpenAPI has no form for a multi-segment parameter, so it "
   "is declared as one string. And `tags` are derived from the path, to group "
   "operations in a viewer; nothing in the source declares them."))

;; A route pattern becomes an OpenAPI path template: `:name` and `*name` both
;; become `{name}`, because OpenAPI has one form and the table has two.
(define (oa-path-segments path)
  (for/list ([s (in-list (string-split path "/"))] #:unless (string=? s "")) s))

(define (oa-path-template path)
  (define segs
    (for/list ([s (in-list (oa-path-segments path))])
      (if (regexp-match #px"^[:*]" s) (string-append "{" (substring s 1) "}") s)))
  (if (null? segs) "/" (string-append "/" (string-join segs "/"))))

;; Nothing declares a description for a path parameter, so none is invented. The
;; REST parameter is the exception and has to be: declared as a plain string it
;; would say "one segment" and mean "the remainder", which is the one place this
;; document would be actively misleading if it said nothing.
(define (oa-parameters path)
  (for/list ([s (in-list (oa-path-segments path))] #:when (regexp-match #px"^[:*]" s))
    (define base (hasheq 'name (substring s 1) 'in "path" 'required #t
                         'schema (hasheq 'type "string")))
    (if (string-prefix? s "*")
        (hash-set* base
                   'description (string-append
                                 "The rest of the path, slash-separated. OpenAPI has no form "
                                 "for a multi-segment parameter, so this is one string and the "
                                 "value may contain `/`.")
                   'x-tmach-rest #t)
        base)))

;; Derived from the path to group operations in a viewer, and SAID to be derived
;; in info.description — 292 ungrouped operations is a wall. `/api/<x>/…` tags as
;; `<x>`; everything outside `/api/` is the console and its static assets.
(define (oa-tag path)
  (define segs (oa-path-segments path))
  (cond
    [(null? segs) "console"]
    [(not (string=? (car segs) "api")) "console"]
    [(null? (cdr segs)) "api"]
    [else (regexp-replace* #px"^[:*]" (cadr segs) "")]))

(define (oa-security auth)
  (cond
    ;; an explicit empty requirement list is how OpenAPI spells "no credential",
    ;; rather than leaving the root default to be inferred
    [(string=? auth "public") '()]
    ;; #43's one route: a bearer OR a bundle ticket. Two requirement objects mean
    ;; "either", and the EMPTY one is what says the bearer is optional.
    [(string=? auth "handler") (list (hasheq 'bearerAuth '()) (hasheq))]
    [else (list (hasheq 'bearerAuth '()))]))

(define (oa-operation r L)
  (define perm (hash-ref r 'permission))
  (define feat (hash-ref r 'feature))
  (define plug (hash-ref r 'plugin #f))
  (define params (oa-parameters (hash-ref r 'path)))
  (let* ([op (hasheq 'operationId (route-key r)
                     'description (L (route-id r) (hash-ref r 'description))
                     'tags (list (oa-tag (hash-ref r 'path)))
                     'security (oa-security (hash-ref r 'auth))
                     'x-tmach-auth (hash-ref r 'auth)
                     'x-tmach-handler (hash-ref r 'handler))]
         [op (if (null? params) op (hash-set op 'parameters params))]
         [op (if (string? perm)
                 (hash-set* op 'x-tmach-permission perm
                            'x-tmach-permission-checked (hash-ref r 'scope "role"))
                 op)]
         [op (if (string? feat) (hash-set op 'x-tmach-feature feat) op)]
         [op (if (string? plug) (hash-set op 'x-tmach-plugin plug) op)])
    op))

;; A COLLAPSE IS REFUSED, NOT RESOLVED. `paths` is keyed by template, so a second
;; operation at one (template, method) would quietly REPLACE the first and the
;; document would describe 312 of 313 routes with nothing failing — the shape a
;; generated reference must never have (#119). Two patterns can collapse without
;; being equal, because the table has two forms where OpenAPI has one: `/a/:x`
;; and `/a/*x` both template to `/a/{x}`. (A parameter and a LITERAL of the same
;; spelling do not — `{x}` keeps its braces — which is a correction the test made
;; to this comment.) So it raises and names the pair rather than resolving it.
(define (oa-paths routes L)
  (for/fold ([acc (hasheq)]) ([r (in-list routes)])
    (define tmpl (oa-path-template (hash-ref r 'path)))
    (define m (string->symbol (string-downcase (hash-ref r 'method))))
    (define cur (hash-ref acc (string->symbol tmpl) (hasheq)))
    (when (hash-has-key? cur m)
      (error 'telemachus-docs
             (string-append "two routes collapse to one OpenAPI operation: ~a ~a (from ~a). "
                            "One of them would be described and the other silently dropped — "
                            "rename a path parameter, or the table has a duplicate entry.")
             (hash-ref r 'method) tmpl (hash-ref r 'path)))
    (hash-set acc (string->symbol tmpl) (hash-set cur m (oa-operation r L)))))

(define (render-openapi model L)
  (define routes (append (hash-ref model 'routes) (hash-ref model 'plugin_routes '())))
  (define tags (sort (remove-duplicates (for/list ([r (in-list routes)]) (oa-tag (hash-ref r 'path))))
                     string<?))
  (json-string
   (hasheq
    'openapi OPENAPI-VERSION
    'info (hasheq 'title "TMach HTTP API"
                  'version (hash-ref model 'version)
                  'description OPENAPI-NOTE)
    ;; A TEMPLATED URL, NOT A RELATIVE `/`, and the comment I first wrote here —
    ;; "relative, because this document is served from the instance it describes"
    ;; — was false twice over. No route serves it: it is committed in the
    ;; repository and copied onto the published site. And a relative server URL
    ;; is resolved against where the DOCUMENT was loaded from, so a viewer
    ;; opening it from the documentation site would have aimed every request at
    ;; the documentation site. A self-hosted platform has no canonical origin, so
    ;; the honest shape is to ask: the variable's default is the server's own
    ;; documented one (config.rkt's PORT default).
    'servers (list (hasheq 'url "{instance}"
                           'description "The TMach instance you are calling."
                           'variables
                           (hasheq 'instance
                                   (hasheq 'default "http://127.0.0.1:8835"
                                           'description
                                           (string-append
                                            "Scheme, host and port of the instance, with no "
                                            "trailing slash. This document is not served by the "
                                            "instance — it is committed in the repository and "
                                            "published with the documentation — so there is no "
                                            "origin to infer and a self-hosted platform has no "
                                            "canonical one.")))))
    'tags (for/list ([t (in-list tags)]) (hasheq 'name t))
    'components (hasheq 'securitySchemes
                        (hasheq 'bearerAuth
                                (hasheq 'type "http" 'scheme "bearer"
                                        'description
                                        (string-append
                                         "A session token (POST /api/login), an API token "
                                         "(POST /api/tokens) or a worker token. A token's SCOPES "
                                         "cap what it may do below the permissions its holder has, "
                                         "so a token scoped narrower than the route's permission is "
                                         "refused."))))
    'paths (oa-paths routes L))))

(define (render-plugins model L)
  (define plugins (hash-ref model 'plugins))
  (string-append
   "# Plugins\n\n"
   "A plugin is a directory under `plugins/` with a `plugin.json` manifest "
   "(`id`, `name`, `version`, `description`, `entry`) and an entry module. Plugins run "
   "in-process with platform privileges; placing one in the directory is the consent.\n\n"
   "## Loaded plugins\n\n"
   (table '("Plugin" "Version" "Tools" "Workflows" "Routes" "Job kinds" "Formats" "Description")
          (for/list ([p (in-list plugins)])
            (list (string-append (hash-ref p 'name) " (" (code (hash-ref p 'id)) ")") (hash-ref p 'version)
                  (let ([t (hash-ref p 'tools)]) (if (null? t) "—" (string-join (map code t) ", ")))
                  (let ([w (hash-ref p 'workflows)]) (if (null? w) "—" (string-join (map code w) ", ")))
                  (let ([r (hash-ref p 'routes '())]) (if (null? r) "—" (string-join (map code r) ", ")))
                  (let ([k (hash-ref p 'job_kinds '())]) (if (null? k) "—" (string-join (map code k) ", ")))
                  (let ([x (hash-ref p 'extractors '())]) (if (null? x) "—" (string-join (map code x) ", ")))
                  (L (string-append "doc.plugin." (hash-ref p 'id)) (hash-ref p 'description)))))
   "\n## The seams a plugin may fill\n\n"
   "| Seam | How | Where it lands |\n|---|---|---|\n"
   "| Tools | `(provide tools)` — a list of `(name schema permission handler [agent?])`; the handler is `(conn principal args) -> result`, and the optional fifth element is `#f` for a tool only a workflow step should call | the same registry as built-ins: per-tool RBAC and per-team activation apply |\n"
   "| Workflows | `(provide workflows)` — specs from `define-workflow`, or `workflows/*.json` | validated like an API-published spec; materialized into a team on first lookup |\n"
   "| HTTP routes | `(provide routes)` — a list of `(method path permission handler doc)`; the handler is `(conn principal args) -> jsexpr or response` with `args` = `{params, query, body, headers}` | mounted at `/api/x/<plugin>/<path>`, always authenticated, permission checked first; listed in [api.md](api.md) |\n"
   "| Job kinds | `(provide init!)` calling `register-job-kind!`; the kind must be named `x.<plugin-id>.<name>` | the same queue as core kinds: per-team cap, quota admission, the org gate, cancel and the lease |\n"
   "| Formats | `(provide init!)` calling `register-extractor!` with a content type | the search index, `doc_text` and every workflow over them. Claiming a type the platform already reads REPLACES its reader — that is how a local OCR engine takes over `application/pdf` |\n"
   "| Anything else | `(provide init!)` — runs with full SDK access at load | e.g. `register-blob-store!` (the `rs3` local store), `register-onboarding!` (a beta funnel experience) |\n"
   "| A beta funnel bundle | a `landing/` directory, served PUBLICLY at `/beta/bundle/<id>/` | a Tier-B custom frontend over `window.Telemachus.beta`, for prospects who have no token |\n"
   "| Authenticated screens | a `bundle/` directory, served at `/api/x/<id>/bundle/` | a bearer token is required and the response is `private, no-store`; assets must ship in the bundle (the CSP is same-origin) |\n\n"
   "See [sdk.md](sdk.md) for the authoring surfaces.\n"))

(define (render-sdk model L)
  (string-append
   "# SDK\n\n"
   "The authoring surfaces a plugin, a tool or a workflow is written against. The "
   "durable product is the contract: a second implementation targets the same specs, "
   "APIs and security model.\n\n"
   "## `define-tool`\n\n"
   "A tool is a declaration that expands to the OpenAI-compatible function schema the "
   "model sees. Parameters are required unless `#:optional`; `#:enum`, `#:items` and "
   "`#:items-of` (arrays of objects) are supported.\n\n"
   "```racket\n"
   "(define-tool doc_text\n"
   "  #:description \"Return the text of a repository document.\"\n"
   "  (object string #:description \"The repository object id\")\n"
   "  (version string #:optional #:description \"A specific version id\"))\n\n"
   "(register-tool! \"doc_text\" doc_text \"files:read\"\n"
   "                (lambda (conn principal args) ...))   ; -> a string or a jsexpr\n"
   "```\n\n"
   "The handler receives the database connection, the calling principal and the "
   "parsed arguments. It checks its own permission (`require-perm`) and meters its "
   "own AI spend (`tenant-quota-record!`); a result that is not a string is JSON-"
   "encoded at the agent boundary and kept as a value for a workflow step.\n\n"
   "## Artifact-shaped results\n\n"
   "A handler may return a string, a JSON value, or an **artifact** — a result that "
   "names a thing rather than carrying it:\n\n"
   "```racket\n"
   "(artifact #:kind \"document\" #:title (hash-ref o 'key) #:summary \"the filled form\"\n"
   "          #:content-type ct #:object-id (hash-ref o 'id) #:version-id (hash-ref o 'version_id)\n"
   "          #:extra (hasheq 'object_id (hash-ref o 'id)))   ; keys a workflow step may bind\n"
   "```\n\n"
   "Kinds are `document`, `table`, `text`, `link`, `image`. The model receives one "
   "line (`[document] inbox/acme.pdf.form.docx — the filled form (application/…) "
   "object_id=…`) instead of the payload; the console renders a card that opens the "
   "document or follows the link; a workflow step keeps the whole value, so "
   "`(out step result object_id)` binds as before. Every document-pipeline tool "
   "returns one.\n\n"
   "## `define-workflow`\n\n"
   "A workflow is a validated data spec; the macro emits it, and a JSON document "
   "posted to `POST /api/workflows` goes through the same validator. Unknown fields "
   "are rejected. Bindings are the frozen sublanguage: `(in name)`, `(out step path…)`, "
   "`(item path…)`, `(index)`, `(locale)`, `(run-id)`, `(team-id)`, `(user-id)`, "
   "and seven predicates for `choice`.\n\n"
   "```racket\n"
   "(define-workflow process-upload\n"
   "  #:input ([object_id string] [schema object] [template string] [locales array])\n"
   "  (step text   (tool doc_text #:object (in object_id)))\n"
   "  (step fields (tool doc_extract_fields #:text (out text result) #:schema (in schema)\n"
   "                                        #:object (in object_id) #:run (run-id) #:step \"fields\")\n"
   "               #:retry 1)\n"
   "  (step has_form (choice (empty (in template)) #:then translate_source #:else form))\n"
   "  ...)\n"
   "```\n\n"
   "Every step is a scheduler job: durability, cancellation, quota admission and "
   "the org gate are inherited. `map` fans out over a list, one job per item. "
   "The shipped workflows are in [workflows.md](workflows.md); the format is served "
   "at `GET /api/workflows/schema`.\n\n"
   "## The blob store\n\n"
   "`register-blob-store! name (hash 'put! 'get 'delete! 'stat)`. The store is "
   "handed a namespace (the org id) and a SHA-256 digest, never a principal — a "
   "backend has no authorization to get wrong. `TMACH_BLOB_STORE` selects one.\n\n"
   "## The onboarding provider\n\n"
   "`register-onboarding! name experience` contributes a beta funnel experience "
   "document (fields, copy, theme, judge prompt). The published one in the database "
   "wins over any registered default.\n\n"
   "## The browser SDK\n\n"
   "`/beta-sdk.js` exposes `window.Telemachus.beta` — `config()`, `challenge()`, "
   "`signup(fields)` — for a Tier-B bundle; a Tier-C template gets the same three "
   "endpoints over CORS from its sandboxed iframe.\n\n"
   "## Plugin routes\n\n"
   "A plugin may contribute authenticated HTTP endpoints — the API a Tier-B "
   "onboarding bundle or an app-specific console calls:\n\n"
   "```racket\n"
   "(define (word-count-route conn principal args)   ; args: {params, query, body, headers}\n"
   "  (define text (hash-ref (hash-ref args 'query) 'text #f))\n"
   "  (unless (string? text) (raise-user-error 'word_count \"text is required\"))   ; -> 400\n"
   "  (hasheq 'words (length (string-split text))))               ; -> 200 JSON\n\n"
   "(define (rename-route conn principal args)                     ; a response keeps control\n"
   "  (json-response (hasheq 'error \"conflict: stale revision\")       ; of the status and headers\n"
   "                 #:code 409\n"
   "                 #:headers (list (make-header #\"Retry-After\" #\"5\"))))\n\n"
   "(define routes\n"
   "  (list (list \"GET\" \"/word-count\" \"chat:use\" word-count-route \"Count the words in ?text=.\")\n"
   "        (list \"PATCH\" \"/rename\" \"chat:use\" rename-route \"Refuses a stale revision.\")))\n"
   "```\n\n"
   "The platform mounts it at `/api/x/<plugin-id>/word-count`, so a plugin can never "
   "shadow a core route. Every plugin route requires a bearer token; the named "
   "permission is checked through `can?` before the handler runs, exactly as a "
   "tool's is. A malformed entry fails the plugin's load.\n\n"
   "`args` carries the path params, the query, the parsed JSON body and the request "
   "headers, which are a hash of lowercase field name to string value with the first "
   "value kept when a field repeats. A handler that returns a response decides its own "
   "status, headers and media type, which is what a core handler already does. "
   "Anything else keeps the older contract: a jsexpr is a 200, a `raise-user-error` "
   "is a 400, and a value that is not JSON-shaped is stringified under `result`.\n\n"
   "## Plugin bundles\n\n"
   "A plugin serves its own screens from two directories, and the difference is "
   "who may read them:\n\n"
   "| Directory | Served at | Who |\n|---|---|---|\n"
   "| `landing/` | `/beta/bundle/<id>/` | anyone — the Tier-B onboarding funnel, a "
   "public page a prospect is linked to, cached `public, max-age=300` |\n"
   "| `bundle/` | `/api/x/<id>/bundle/` | a caller with a bearer token; "
   "`Cache-Control: private, no-store` and `Vary: Authorization`, so no shared "
   "cache ever holds one |\n\n"
   "`bundle/` is reserved by the platform under every plugin's prefix, and core "
   "routes match before plugin ones, so a plugin cannot take that path for "
   "something else. The path is resolved segment by segment against the *loaded* "
   "plugin's directory: it can never climb out of `bundle/` into the plugin's "
   "source, and it can never reach a directory nobody installed. The bundle is "
   "code — one copy for everyone; anything that varies by organisation comes from "
   "the plugin's own API routes, which see the principal and the org. Assets must "
   "ship in the bundle: the console's Content-Security-Policy is same-origin, so a "
   "CDN script or font is blocked.\n\n"
   "`plugins/example-tools/bundle/index.html` is the worked example — a screen "
   "that calls its own `/api/x/example-tools/word-count` route.\n\n"
   "## Job kinds\n\n"
   "A plugin may add background work of its own. `init!` runs at load with full "
   "SDK access, and that is the documented route:\n\n"
   "```racket\n"
   "(define (word-count-job conn principal payload)       ; -> a jsexpr result\n"
   "  (hasheq 'words (length (string-split (hash-ref payload 'text \"\")))))\n\n"
   "(define (init!)\n"
   "  (register-job-kind! \"x.example-tools.word-count\" word-count-job))\n"
   "```\n\n"
   "The name is **platform-fixed**: `x.<plugin-id>.<name>`, the same rule plugin "
   "routes follow, enforced while the plugin's `init!` runs — so a plugin can never "
   "take a core kind's name (`flow.step`, `infer.chat`) or another plugin's, and a "
   "violation fails that plugin's load rather than surfacing at claim time.\n\n"
   "A plugin kind is an ordinary job. It inherits everything the row carries, not "
   "anything from the plugin: the enqueuing team and user, the per-team concurrency "
   "cap and quota admission at claim, the org gate on whatever the handler touches, "
   "cancellation, and the lease that returns it to the queue if the worker dies. "
   "`enqueue-job!` submits one; `GET /api/jobs` lists it like any other.\n\n"
   "A **remote** kind (`#:remote? #t`) has no in-process handler — it is claimed by "
   "a pull executor over HTTP — and must carry `#:validate`, a procedure returning a "
   "string naming the problem or `#f`. It is the only thing standing between a "
   "worker's reply and the rest of the system, so it is required, not optional.\n\n"
   "## The route table\n\n"
   "`server/routes.rkt` declares every HTTP route with its permission, "
   "authentication, feature flag and one line of documentation; the server refuses "
   "to boot if the table and the handlers disagree. [api.md](api.md) is rendered "
   "from it.\n"))

(define (render-readme model)
  (string-append
   "# TMach reference\n\n"
   "Generated by `telemachus-docs` from the source of truth — do not edit by hand; "
   "`telemachus-docs check` fails CI on drift. Version " (hash-ref model 'version) ".\n\n"
   "| Page | What it documents |\n|---|---|\n"
   "| [tools.md](tools.md) | every tool: schema, permission, source |\n"
   "| [workflows.md](workflows.md) | the shipped workflow specs, step by step |\n"
   "| [permissions.md](permissions.md) | the permission catalog and the role matrix |\n"
   "| [api.md](api.md) | every HTTP route with auth, permission and feature flag |\n"
   "| [openapi.json](openapi.json) | the same routes as OpenAPI 3.1, for tooling — paths, parameters, auth and permissions, and no request or response schemas |\n"
   "| [plugins.md](plugins.md) | loaded plugins and the seams a plugin may fill |\n"
   "| [sdk.md](sdk.md) | the authoring surfaces |\n\n"
   "Prose is localizable: `strings.json` beside these pages is a JSON surface for "
   "`telemachus-localize`, so every description is a `doc.*` message the Localization "
   "Manager can translate; `telemachus-docs render --locale ja` writes `ja/`.\n"))

(define (render-all model locale ldir)
  (define L (make-localizer locale ldir))
  (define pages
    (list (cons "README.md" (render-readme model))
          (cons "tools.md" (render-tools model L))
          (cons "workflows.md" (render-workflows model L))
          (cons "permissions.md" (render-permissions model L))
          (cons "api.md" (render-api model L))
          (cons "openapi.json" (render-openapi model L))
          (cons "plugins.md" (render-plugins model L))
          (cons "sdk.md" (render-sdk model L))))
  (if (or (not locale) (string=? locale "en"))
      (append pages (list (cons "strings.json" (json-string (strings-of model)))))
      pages))

(define (write-pages pages dir)
  (make-directory* dir)
  (for ([pg (in-list pages)])
    (call-with-output-file (build-path dir (car pg)) (lambda (out) (write-string (cdr pg) out)) #:exists 'truncate)))

;; ---- subcommands ---------------------------------------------------------------------
(define (cmd-describe opts)
  (write-string (json-string (describe)) (current-output-port)))

(define (cmd-render opts)
  (define model (describe))
  (define locale (hash-ref opts 'locale #f))
  (define out (let ([o (hash-ref opts 'out #f)]) (if o (string->path o) (default-out))))
  (define dir (if (and locale (not (string=? locale "en"))) (build-path out locale) out))
  (write-pages (render-all model locale (locales-dir opts)) dir)
  (printf "wrote ~a page(s) to ~a\n" (length (render-all model locale (locales-dir opts))) dir))

;; EVERY COMMITTED LOCALE, not just English. `check` rendered with the locale
;; hardcoded to #f, and `--locale` was parsed by the flag splitter and then
;; silently ignored here — so `check --locale ja` reported "8 page(s) match the
;; sources" with deliberate drift sitting in docs/reference/ja/api.md. That is
;; how the Japanese reference lost #110 r2's whole "Checked" column and two
;; plugins without anything failing, and it is why this was re-rendered by hand
;; in five separate slices.
;;
;; The locale list is DERIVED from the directories that are committed under
;; `out`, not from a list kept here or a flag CI has to remember: a translation
;; that exists is a translation that is gated, and a new one is covered the day
;; it is committed. Same rule as `available` locales being derived from the
;; catalogs on disk rather than stored.
(define (committed-locales out ldir)
  (cond
    [(not (directory-exists? out)) '()]
    [else
     (sort
      (for/list ([e (in-list (directory-list out))]
                 #:when (and (directory-exists? (build-path out e))
                             ;; a locale directory is one with a catalog behind it,
                             ;; so a stray folder under docs/reference is not
                             ;; mistaken for a language
                             (file-exists? (build-path ldir (string-append (path->string e) ".json")))))
        (path->string e))
      string<?)]))

(define (drifted pages dir)
  (for/list ([pg (in-list pages)]
             #:unless (let ([f (build-path dir (car pg))])
                        (and (file-exists? f) (string=? (file->string f) (cdr pg)))))
    (car pg)))

(define (cmd-check opts)
  (define model (describe))
  (define out (let ([o (hash-ref opts 'out #f)]) (if o (string->path o) (default-out))))
  (define ldir (locales-dir opts))
  ;; `--locale xx` narrows to one; with none, every committed locale is checked
  (define only (hash-ref opts 'locale #f))
  (define locales
    (cond [(and only (not (string=? only "en"))) (list only)]
          [only '()]                                   ; --locale en: English alone
          [else (committed-locales out ldir)]))
  (define english (if (and only (not (string=? only "en"))) '() (list (cons #f out))))
  (define targets (append english (for/list ([l (in-list locales)]) (cons l (build-path out l)))))
  (define results
    (for/list ([t (in-list targets)])
      (define pages (render-all model (car t) ldir))
      (cons (cons (or (car t) "en") (length pages)) (drifted pages (cdr t)))))
  (define bad (filter (lambda (r) (pair? (cdr r))) results))
  (cond
    [(null? bad)
     (printf "telemachus-docs: ~a match the sources\n"
             (string-join (for/list ([r (in-list results)])
                            (format "~a page(s) in ~a" (cdar r) (caar r)))
                          ", "))]
    [else
     (eprintf "telemachus-docs: DRIFT — regenerate with `racket cli/telemachus-docs.rkt render`:\n")
     (for ([r (in-list bad)])
       (define loc (caar r))
       (eprintf "  ~a: ~a\n" loc (string-join (cdr r) " "))
       (unless (string=? loc "en")
         (eprintf "    racket cli/telemachus-docs.rkt render --locale ~a\n" loc)))
     (exit 1)]))

(module+ main
  (define args (vector->list (current-command-line-arguments)))
  (when (null? args) (usage))
  (define-values (pos opts) (split-flags (cdr args)))
  (case (car args)
    [("describe") (cmd-describe opts)]
    [("render") (cmd-render opts)]
    [("check") (cmd-check opts)]
    [else (usage)]))
