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

(require json racket/list "registry.rkt" "../flow/run.rkt" "../sched/scheduler.rkt")

(provide load-plugins! loaded-plugins plugin-routes plugin-dir plugin-failures)

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
          (set-box! *loaded*
            (append (unbox *loaded*)
                    (list (hasheq 'id id 'name (hash-ref m 'name id) 'version (hash-ref m 'version "")
                                  'description (hash-ref m 'description "") 'tools names
                                  'workflows wf-slugs
                                  'job_kinds job-kinds
                                  ;; issue #43: does this plugin have a page to open?
                                  ;; A boolean, never the path — the listing is JSON
                                  ;; on an API and the server's layout is not the
                                  ;; caller's business.
                                  'bundle (directory-exists? (build-path pdir "bundle"))
                                  'routes (for/list ([r (in-list routes)])
                                            (string-append (hash-ref r 'method) " " (hash-ref r 'path)))))))
          (hash-set! *dirs* id pdir)
          (log (format "~a v~a — ~a tool(s)~a~a~a~a" id (hash-ref m 'version "?") (length names)
                       (if (null? wf-slugs) "" (format ", ~a workflow(s)" (length wf-slugs)))
                       (if (null? routes) "" (format ", ~a route(s)" (length routes)))
                       (if (null? job-kinds) "" (format ", ~a job kind(s)" (length job-kinds)))
                       (if (procedure? init!) " +init" ""))))))))
