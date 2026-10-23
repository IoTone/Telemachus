#lang racket/base

;; domain/agent/plugins.rkt — load third-party tool plugins from a directory,
;; out-of-tree (not compiled into the core). Each plugin is a folder:
;;
;;   plugins/<id>/plugin.json   {id, name, version, description, entry}
;;   plugins/<id>/<entry>.rkt   (provide tools)  ; tools = (list (list name schema perm handler) …)
;;                              ; handler : (conn principal args) -> string
;;                              (provide workflows) ; workflows = (listof spec-jsexpr)
;;                              (provide routes)    ; routes = (list (list method path perm handler doc) …)
;;                              ; mounted at /api/x/<id>/<path>; always authenticated;
;;                              ; handler : (conn principal args) -> jsexpr, where args is
;;                              ; (hasheq 'params {…path params} 'query {…} 'body <json>)
;;                              ; (provide init!)     ; anything else, incl.
;;                              ; register-job-kind! — a plugin's kinds are named
;;                              ; x.<id>.<name> and the loader enforces it
;;   plugins/<id>/workflows/*.json                 ; …or the same specs as plain files
;;
;; Plugin tools register through the SAME registry as built-ins, so they inherit
;; per-tool RBAC and per-team activation for free — tagged with the plugin id as
;; their source.
;;
;; TRUST NOTE: in-process plugins run with platform privileges (like editor
;; extensions). Installing one — placing it in the plugins dir — IS the consent.
;; Sandboxed/out-of-process plugins are future hardening (see THREAT model).

(require (only-in "../repo/extract.rkt" extractors-of-plugin)
         (only-in "../feeds/adapters.rkt" feed-adapters-of-plugin) json racket/list racket/string
         db-kit/portable
         (only-in db-kit/migrate migration migration-id)
         "registry.rkt" "../flow/run.rkt" "../sched/scheduler.rkt")

(provide load-plugins! loaded-plugins plugin-routes plugin-dir plugin-failures
         ;; issue #121: a plugin that owns data
         plugin-migrations plugin-table-prefix check-migrations!)

(define *loaded* (box '()))
(define (loaded-plugins) (unbox *loaded*))

;; Where each plugin was loaded FROM (issue #44). Kept beside the listing rather
;; than inside it: the listing is JSON on `GET /api/plugins`, and a server's
;; filesystem layout is nobody's business. Anything that serves a plugin's files
;; asks here instead of rebuilding a path from a constant, which is what made
;; TELEMACHUS_PLUGINS work for the loader and not for the pages.
(define *dirs* (make-hash))                       ; plugin id -> its directory
(define (plugin-dir id) (hash-ref *dirs* id #f))

;; Plugins that did NOT load (issue #48). One bad plugin must not stop the
;; server — but an instance that is quietly missing a tool, a workflow or a job
;; kind is worse than one that says so, and a single line among sixty is quiet.
(define *failed* (box '()))
(define (plugin-failures) (unbox *failed*))

;; the routes every plugin contributed, in load order, as plain hashes — the
;; server turns them into dispatch entries and the docs CLI into api.md rows
(define *routes* (box '()))
(define (plugin-routes) (unbox *routes*))

;; every loaded plugin's migrations, in load order, ready for `migrate!`
(define *migrations* (box '()))
(define (plugin-migrations) (unbox *migrations*))

(define METHODS '("GET" "POST" "PUT" "PATCH" "DELETE"))
(define (check-route! id r)
  (unless (and (list? r) (>= (length r) 4))
    (error 'plugins "~a: a route is (list method path perm handler [doc])" id))
  (define-values (method path perm handler) (values (list-ref r 0) (list-ref r 1) (list-ref r 2) (list-ref r 3)))
  (unless (member method METHODS) (error 'plugins "~a: route method must be one of ~a" id METHODS))
  (unless (and (string? path) (regexp-match? #px"^/?[A-Za-z0-9_.:*/-]+$" path))
    (error 'plugins "~a: route path ~s is not a plain path (letters, digits, :name, *rest)" id path))
  (unless (or (not perm) (string? perm)) (error 'plugins "~a: route permission must be a string or #f" id))
  (unless (procedure? handler) (error 'plugins "~a: route handler must be a procedure" id))
  (hasheq 'plugin id 'method method 'path path 'perm perm 'handler handler
          'doc (if (and (>= (length r) 5) (string? (list-ref r 4))) (list-ref r 4) "")))

;; `dirs` is one directory or a LIST of them, searched in order (issue #45): the
;; built-in directory and an operator's own, rather than one replacing the other.
;; A plugin id already loaded from an earlier directory wins, so a local copy
;; cannot silently shadow a shipped plugin — it is reported as a failure instead.
;;
;; `#:skip-links?` leaves SYMLINKED plugin directories alone. The server wants
;; them — symlinking a downstream plugin into `plugins/` is how you develop one,
;; and it is the only way for a plugin that requires Telemachus modules by
;; relative path (`../../domain/...`) to resolve them at all. The GENERATED
;; reference must not see them: `docs/reference/` is committed and CI fails on
;; drift, so one developer's local symlink would otherwise write a customer's
;; routes and descriptions into the repository and break the gate on every
;; machine that does not have that link.
;; ---- a plugin that owns data (issue #121) -----------------------------------
;; A plugin had no connection at load time, so one that keeps data worked around
;; it: `CREATE TABLE IF NOT EXISTS` on first use, which on PostgreSQL lost a
;; duplicate-key race in 1 of 6 rounds at 48 concurrent first requests, and then
;; needed a hand-rolled lock around the statements.
;;
;; WHY NOT JUST PASS A CONNECTION TO `init!`, which the issue offers as its second
;; option: that does not remove the race, it MOVES it. `load-plugins!` runs once
;; per process, so on two replicas two processes run `init!` concurrently and both
;; run the plugin's DDL — the same collision, now in the platform's boot instead
;; of the plugin's first request. The platform solved this for itself years ago
;; and the machinery is sitting there: an ordered list, applied once, recorded in
;; `schema_migrations`, each inside a transaction.
;;
;; So a plugin declares `(provide migrations)` and the platform runs them like its
;; own. The id recorded is `x.<plugin-id>.<name>`, the same platform-fixed prefix
;; job kinds and routes already carry, so a plugin's migration can never be
;; mistaken for a core one or for another plugin's.
;;
;; DATA, NOT A PROCEDURE. A plugin already runs arbitrary code in `init!`, so a
;; thunk would add no authority — but a list of SQL strings can be VALIDATED, and
;; the validation is the point: every table and index a plugin creates must be
;; named `x_<id>_…`, which is what keeps it off the platform's tables and out of
;; another plugin's. A procedure could create `users` and nothing could tell.
;;
;; Shape: (list (list "name" "SQL" "SQL" ...) ...)
;;
;; The SQL must be dialect-neutral — the same obligation the platform's own
;; migrations carry, and for the same reason (SQLite and PostgreSQL both ship).
;; Nothing can enforce that here; `raco test test/migration-tests.rkt` is what
;; catches it for the platform, and a plugin wants its own equivalent.
(define (plugin-table-prefix id) (string-append "x_" (regexp-replace* #rx"[^a-z0-9]" id "_") "_"))

;; every identifier this statement creates or alters, lower-cased
(define (ddl-targets sql)
  (define s (string-downcase sql))
  (for*/list ([rx (in-list (list #px"create\\s+table\\s+(?:if\\s+not\\s+exists\\s+)?([a-z0-9_\"\\.]+)"
                                 #px"create\\s+(?:unique\\s+)?index\\s+(?:if\\s+not\\s+exists\\s+)?([a-z0-9_\"\\.]+)"
                                 #px"alter\\s+table\\s+([a-z0-9_\"\\.]+)"
                                 #px"drop\\s+table\\s+(?:if\\s+exists\\s+)?([a-z0-9_\"\\.]+)"))]
              [m (in-list (regexp-match* rx s #:match-select cadr))])
    (regexp-replace* #rx"\"" m "")))

;; -> (listof migration), or raises so THIS plugin fails to load rather than a
;; request later — the rule `check-route!` and the workflow validator follow
(define (check-migrations! id v)
  (unless (list? v) (error 'plugins "~a: `migrations` must be a list" id))
  (define prefix (plugin-table-prefix id))
  (for/list ([entry (in-list v)] [i (in-naturals)])
    (unless (and (list? entry) (>= (length entry) 2) (andmap string? entry))
      (error 'plugins "~a: migration ~a must be (list name sql ...) of strings" id i))
    (define name (car entry))
    (define stmts (cdr entry))
    (unless (regexp-match? #px"^[a-z0-9][a-z0-9-]*$" name)
      (error 'plugins "~a: migration name ~s must be lower-case letters, digits and dashes" id name))
    (for ([sql (in-list stmts)])
      (for ([t (in-list (ddl-targets sql))])
        ;; a bare table name only; a schema-qualified one would sidestep the prefix
        (when (regexp-match? #rx"\\." t)
          (error 'plugins "~a: migration ~s may not name a schema-qualified table (~a)" id name t))
        (unless (regexp-match? (regexp (string-append "^" (regexp-quote prefix))) t)
          (error 'plugins
                 (string-append "~a: migration ~s creates or alters ~s, which is not named ~a*. "
                                "A plugin's tables carry its own prefix so they cannot collide "
                                "with the platform's or another plugin's.")
                 id name t prefix))))
    (migration (format "x.~a.~a" id name)
               (lambda (conn) (for ([sql (in-list stmts)]) (query-exec conn sql))))))

(define (load-plugins! dirs #:log [log void] #:skip-links? [skip-links? #f])
  (set-box! *loaded* '())
  (set-box! *routes* '())
  (set-box! *failed* '())
  (hash-clear! *dirs*)
  (for ([dir (in-list (if (list? dirs) dirs (list dirs)))])
    (load-plugin-dir! dir log skip-links?))
  (unbox *loaded*))

(define (fail! log where msg)
  (set-box! *failed* (append (unbox *failed*) (list (hasheq 'plugin where 'error msg))))
  (log (format "~a: FAILED — ~a" where msg)))

(define (load-plugin-dir! dir log [skip-links? #f])
  (when (directory-exists? dir)
    (for ([sub (in-list (sort (map path->string (directory-list dir)) string<?))])
      (define pdir (build-path dir sub))
      (define mpath (build-path pdir "plugin.json"))
      ;; `link-exists?` is asked BEFORE `directory-exists?`, which follows links
      (when (and (not (and skip-links? (link-exists? pdir)))
                 (directory-exists? pdir) (file-exists? mpath))
        (with-handlers ([exn:fail? (lambda (e) (fail! log sub (exn-message e)))])
          (define m (call-with-input-file mpath read-json))
          (define id (hash-ref m 'id sub))
          (when (hash-has-key? *dirs* id)
            (error 'plugins "a plugin with id ~a is already loaded from ~a" id (hash-ref *dirs* id)))
          (define entry (build-path pdir (hash-ref m 'entry "main.rkt")))
          ;; A plugin may (provide tools) and/or (provide init!). init! runs with full
          ;; SDK access so a plugin can register anything (tools, an onboarding
          ;; provider, …), not just agent tools. Both are optional.
          (define tools (dynamic-require entry 'tools (lambda () '())))
          (define init! (dynamic-require entry 'init! (lambda () #f)))
          ;; workflow definitions the plugin contributes (slice 47). Both the
          ;; `workflows` export and workflows/*.json land in the same registry and
          ;; go through the same validator as an API-published document.
          (define wf-dir (build-path pdir "workflows"))
          (define wfs
            (append (let ([w (dynamic-require entry 'workflows (lambda () '()))]) (if (list? w) w '()))
                    (if (directory-exists? wf-dir)
                        (for/list ([f (in-list (sort (map path->string (directory-list wf-dir)) string<?))]
                                   #:when (regexp-match #rx"[.]json$" f))
                          (call-with-input-file (build-path wf-dir f) read-json))
                        '())))
          (define wf-slugs
            (for/list ([w (in-list wfs)])
              (hash-ref (register-plugin-workflow! id w) 'slug)))
          ;; init! runs with the plugin's identity bound, so anything it registers
          ;; that the platform namespaces — job kinds (issue #21) — is checked
          ;; against this plugin's prefix, and a violation fails THIS plugin.
          (when (procedure? init!) (parameterize ([current-plugin id]) (init!)))
          (define job-kinds (job-kinds-of-plugin id))
          (define names
            (for/list ([t (in-list tools)])
              (register-tool! (list-ref t 0) (list-ref t 1) (list-ref t 2) (list-ref t 3) #:source id)
              (list-ref t 0)))
          ;; authenticated HTTP routes the plugin contributes (slice 63), checked
          ;; here so a malformed one fails the PLUGIN's load, not a request later
          (define routes
            (for/list ([r (in-list (let ([v (dynamic-require entry 'routes (lambda () '()))]) (if (list? v) v '())))])
              (check-route! id r)))
          (set-box! *routes* (append (unbox *routes*) routes))
          ;; #121: validated here, so a badly-named table fails THIS plugin's
          ;; load. Applied by main.rkt after every plugin has loaded, through the
          ;; platform's own `migrate!` — which is what makes them ordered,
          ;; recorded and run once instead of raced on first use.
          (define migs (check-migrations! id (dynamic-require entry 'migrations (lambda () '()))))
          (set-box! *migrations* (append (unbox *migrations*) migs))
          (set-box! *loaded*
            (append (unbox *loaded*)
                    (list (hasheq 'id id 'name (hash-ref m 'name id) 'version (hash-ref m 'version "")
                                  'description (hash-ref m 'description "") 'tools names
                                  'workflows wf-slugs
                                  'job_kinds job-kinds
                                  ;; #121: which tables this plugin owns, by id —
                                  ;; an operator reading `\dt` should be able to
                                  ;; tell who owns what
                                  'migrations (for/list ([m (in-list migs)]) (migration-id m))
                                  ;; LAY-7: which content types this plugin claims
                                  ;; an extractor for. Reported for the same reason
                                  ;; job kinds are — an operator should be able to
                                  ;; see who reads which format before trusting it.
                                  'extractors (extractors-of-plugin id)
                                  ;; FEED-14: which feed kinds this plugin can
                                  ;; pull. Same reason again — a plugin that
                                  ;; polls somebody's API on a timer, as this
                                  ;; team's own user, should be visible from the
                                  ;; listing and not only from its own source.
                                  'feed_adapters (feed-adapters-of-plugin id)
                                  ;; issue #43: does this plugin have a page to open?
                                  ;; A boolean, never the path — the listing is JSON
                                  ;; on an API and the server's layout is not the
                                  ;; caller's business.
                                  'bundle (directory-exists? (build-path pdir "bundle"))
                                  'routes (for/list ([r (in-list routes)])
                                            (string-append (hash-ref r 'method) " " (hash-ref r 'path)))))))
          (hash-set! *dirs* id pdir)
          (log (format "~a v~a — ~a tool(s)~a~a~a~a~a" id (hash-ref m 'version "?") (length names)
                       (if (null? wf-slugs) "" (format ", ~a workflow(s)" (length wf-slugs)))
                       (if (null? routes) "" (format ", ~a route(s)" (length routes)))
                       (if (null? job-kinds) "" (format ", ~a job kind(s)" (length job-kinds)))
                       (if (null? migs) "" (format ", ~a migration(s)" (length migs)))
                       (if (procedure? init!) " +init" ""))))))))
