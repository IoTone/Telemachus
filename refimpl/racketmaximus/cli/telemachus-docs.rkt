#lang racket/base

;; cli/telemachus-docs.rkt — generate the reference documentation from the source
;; of truth, and gate drift (slice 60, DOCGEN-1…6).
;;
;;   telemachus-docs describe                         # the model, as JSON, to stdout
;;   telemachus-docs render  [--out DIR] [--locale xx] [--locales DIR]
;;   telemachus-docs check   [--out DIR] [--locales DIR]   # regenerate, diff, exit 1 on drift
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
         "../domain/flow/run.rkt"
         "../domain/flow/spec.rkt"
         "../domain/authz/permissions.rkt"
         "../domain/i18n/catalog.rkt"
         "../server/routes.rkt")

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
(define (locales-dir opts) (hash-ref opts 'locales (or (getenv "TELEMACHUS_LOCALES") (path->string (build-path impl-root "locales")))))

;; ---- describe --------------------------------------------------------------------
(define (js-get h k [d 'null]) (if (hash? h) (hash-ref h k d) d))

(define (describe)
  (load-plugins! (build-path impl-root "plugins"))
  (define tools
    (sort
     (for/list ([t (in-list (all-tools))])
       (define fn (js-get (tool-schema t) 'function (hasheq)))
       (hasheq 'name (tool-name t)
               'description (let ([d (js-get fn 'description "")]) (if (string? d) d ""))
               'permission (or (tool-perm t) 'null)
               'source (tool-source t)
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
              'feature (or (rt-feature r) 'null) 'description (rt-doc r))))
  (define plugins
    (sort (for/list ([p (in-list (loaded-plugins))])
            (hasheq 'id (hash-ref p 'id) 'name (hash-ref p 'name) 'version (hash-ref p 'version)
                    'description (hash-ref p 'description "")
                    'tools (sort (hash-ref p 'tools '()) string<?)
                    'workflows (sort (hash-ref p 'workflows '()) string<?)))
          string<? #:key (lambda (p) (hash-ref p 'id))))
  ;; every route permission must be described, like every role permission is
  (for ([r (in-list ROUTES)]) (when (rt-perm r) (permission-doc (rt-perm r))))
  (hasheq 'version app-version 'tools tools 'workflows workflows
          'permissions permissions 'roles roles 'routes routes 'plugins plugins))

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
(define (route-id r)
  (string-append "doc.route." (string-downcase (hash-ref r 'method)) "."
                 (string-join (for/list ([s (in-list (string-split (hash-ref r 'path) "/"))]
                                         #:unless (string=? s ""))
                                (regexp-replace* #px"^[:*]" s ""))
                              ".")))

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
  (for ([r (in-list (hash-ref model 'routes))])
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
   "Every tool the agent may call and a workflow step may use, from `define-tool` "
   "declarations and plugin registrations. Each tool checks its own permission when "
   "invoked; a workflow step also needs `tools:invoke`.\n\n"
   (table '("Tool" "Permission" "Source" "Description")
          (for/list ([t (in-list tools)])
            (list (code (hash-ref t 'name))
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
                      (define retry (let ([r (hash-ref st 'retry #f)]) (if (hash? r) (format " · retry ~a" (hash-ref r 'max 0)) "")))
                      (list (code (hash-ref st 'id)) (code uses) binding (string-append nxt retry))))
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
   "The permission is the one the handler enforces on its main path — owner-ok and "
   "resource grants may admit a caller the role would not. A feature flag, when named, "
   "must be on for the team.\n\n"
   "Path segments written `:name` are parameters; `*name` takes the rest of the path.\n\n"
   (table '("Method" "Path" "Auth" "Permission" "Feature" "Description")
          (for/list ([r (in-list routes)])
            (list (hash-ref r 'method) (code (hash-ref r 'path)) (hash-ref r 'auth)
                  (let ([p (hash-ref r 'permission)]) (if (string? p) (code p) "—"))
                  (let ([f (hash-ref r 'feature)]) (if (string? f) (code f) "—"))
                  (L (route-id r) (hash-ref r 'description)))))
   "\n"))

(define (render-plugins model L)
  (define plugins (hash-ref model 'plugins))
  (string-append
   "# Plugins\n\n"
   "A plugin is a directory under `plugins/` with a `plugin.json` manifest "
   "(`id`, `name`, `version`, `description`, `entry`) and an entry module. Plugins run "
   "in-process with platform privileges; placing one in the directory is the consent.\n\n"
   "## Loaded plugins\n\n"
   (table '("Plugin" "Version" "Tools" "Workflows" "Description")
          (for/list ([p (in-list plugins)])
            (list (string-append (hash-ref p 'name) " (" (code (hash-ref p 'id)) ")") (hash-ref p 'version)
                  (let ([t (hash-ref p 'tools)]) (if (null? t) "—" (string-join (map code t) ", ")))
                  (let ([w (hash-ref p 'workflows)]) (if (null? w) "—" (string-join (map code w) ", ")))
                  (L (string-append "doc.plugin." (hash-ref p 'id)) (hash-ref p 'description)))))
   "\n## The seams a plugin may fill\n\n"
   "| Seam | How | Where it lands |\n|---|---|---|\n"
   "| Tools | `(provide tools)` — a list of `(name schema permission handler)`; the handler is `(conn principal args) -> result` | the same registry as built-ins: per-tool RBAC and per-team activation apply |\n"
   "| Workflows | `(provide workflows)` — specs from `define-workflow`, or `workflows/*.json` | validated like an API-published spec; materialized into a team on first lookup |\n"
   "| Anything else | `(provide init!)` — runs with full SDK access at load | e.g. `register-blob-store!` (the `rs3` local store), `register-onboarding!` (a beta funnel experience) |\n"
   "| A beta funnel bundle | a `bundle/` directory served at `/beta/bundle/<id>/` | a Tier-B custom frontend over `window.Telemachus.beta` |\n\n"
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
   "backend has no authorization to get wrong. `TELEMACHUS_BLOB_STORE` selects one.\n\n"
   "## The onboarding provider\n\n"
   "`register-onboarding! name experience` contributes a beta funnel experience "
   "document (fields, copy, theme, judge prompt). The published one in the database "
   "wins over any registered default.\n\n"
   "## The browser SDK\n\n"
   "`/beta-sdk.js` exposes `window.Telemachus.beta` — `config()`, `challenge()`, "
   "`signup(fields)` — for a Tier-B bundle; a Tier-C template gets the same three "
   "endpoints over CORS from its sandboxed iframe.\n\n"
   "## The route table\n\n"
   "`server/routes.rkt` declares every HTTP route with its permission, "
   "authentication, feature flag and one line of documentation; the server refuses "
   "to boot if the table and the handlers disagree. [api.md](api.md) is rendered "
   "from it.\n"))

(define (render-readme model)
  (string-append
   "# Telemachus reference\n\n"
   "Generated by `telemachus-docs` from the source of truth — do not edit by hand; "
   "`telemachus-docs check` fails CI on drift. Version " (hash-ref model 'version) ".\n\n"
   "| Page | What it documents |\n|---|---|\n"
   "| [tools.md](tools.md) | every tool: schema, permission, source |\n"
   "| [workflows.md](workflows.md) | the shipped workflow specs, step by step |\n"
   "| [permissions.md](permissions.md) | the permission catalog and the role matrix |\n"
   "| [api.md](api.md) | every HTTP route with auth, permission and feature flag |\n"
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

(define (cmd-check opts)
  (define model (describe))
  (define out (let ([o (hash-ref opts 'out #f)]) (if o (string->path o) (default-out))))
  (define pages (render-all model #f (locales-dir opts)))
  (define drift
    (for/list ([pg (in-list pages)]
               #:unless (let ([f (build-path out (car pg))])
                          (and (file-exists? f) (string=? (file->string f) (cdr pg)))))
      (car pg)))
  (cond
    [(null? drift) (printf "telemachus-docs: ~a page(s) match the sources\n" (length pages))]
    [else
     (eprintf "telemachus-docs: DRIFT — regenerate with `racket cli/telemachus-docs.rkt render`:\n")
     (for ([d (in-list drift)]) (eprintf "  ~a\n" d))
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
