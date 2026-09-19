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

(provide load-plugins! loaded-plugins plugin-routes)

(define *loaded* (box '()))
(define (loaded-plugins) (unbox *loaded*))

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

(define (load-plugins! dir #:log [log void])
  (set-box! *loaded* '())
  (set-box! *routes* '())
  (when (directory-exists? dir)
    (for ([sub (in-list (sort (map path->string (directory-list dir)) string<?))])
      (define pdir (build-path dir sub))
      (define mpath (build-path pdir "plugin.json"))
      (when (and (directory-exists? pdir) (file-exists? mpath))
        (with-handlers ([exn:fail? (lambda (e) (log (format "~a: failed — ~a" sub (exn-message e))))])
          (define m (call-with-input-file mpath read-json))
          (define id (hash-ref m 'id sub))
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
                                  'routes (for/list ([r (in-list routes)])
                                            (string-append (hash-ref r 'method) " " (hash-ref r 'path)))))))
          (log (format "~a v~a — ~a tool(s)~a~a~a~a" id (hash-ref m 'version "?") (length names)
                       (if (null? wf-slugs) "" (format ", ~a workflow(s)" (length wf-slugs)))
                       (if (null? routes) "" (format ", ~a route(s)" (length routes)))
                       (if (null? job-kinds) "" (format ", ~a job kind(s)" (length job-kinds)))
                       (if (procedure? init!) " +init" "")))))))
  (unbox *loaded*))
