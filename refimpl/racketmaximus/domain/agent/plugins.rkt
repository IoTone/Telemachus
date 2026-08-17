#lang racket/base

;; domain/agent/plugins.rkt — load third-party tool plugins from a directory,
;; out-of-tree (not compiled into the core). Each plugin is a folder:
;;
;;   plugins/<id>/plugin.json   {id, name, version, description, entry}
;;   plugins/<id>/<entry>.rkt   (provide tools)  ; tools = (list (list name schema perm handler) …)
;;                              ; handler : (conn principal args) -> string
;;
;; Plugin tools register through the SAME registry as built-ins, so they inherit
;; per-tool RBAC and per-team activation for free — tagged with the plugin id as
;; their source.
;;
;; TRUST NOTE: in-process plugins run with platform privileges (like editor
;; extensions). Installing one — placing it in the plugins dir — IS the consent.
;; Sandboxed/out-of-process plugins are future hardening (see THREAT model).

(require json "registry.rkt")

(provide load-plugins! loaded-plugins)

(define *loaded* (box '()))
(define (loaded-plugins) (unbox *loaded*))

(define (load-plugins! dir #:log [log void])
  (set-box! *loaded* '())
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
          (when (procedure? init!) (init!))
          (define names
            (for/list ([t (in-list tools)])
              (register-tool! (list-ref t 0) (list-ref t 1) (list-ref t 2) (list-ref t 3) #:source id)
              (list-ref t 0)))
          (set-box! *loaded*
            (append (unbox *loaded*)
                    (list (hasheq 'id id 'name (hash-ref m 'name id) 'version (hash-ref m 'version "")
                                  'description (hash-ref m 'description "") 'tools names))))
          (log (format "~a v~a — ~a tool(s)~a" id (hash-ref m 'version "?") (length names)
                       (if (procedure? init!) " +init" "")))))))
  (unbox *loaded*))
