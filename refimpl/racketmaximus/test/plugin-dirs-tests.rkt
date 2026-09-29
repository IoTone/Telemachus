#lang racket/base

;; test/plugin-dirs-tests.rkt — how the loader finds plugins, and what it does
;; when one will not load (issues #44, #45, #48).
;;
;; The shape all three share: the instance came up looking healthy while a tool,
;; a workflow or a whole directory of plugins was quietly absent.
;;   raco test test/plugin-dirs-tests.rkt

(require rackunit racket/file racket/list racket/string racket/runtime-path
         "../domain/agent/plugins.rkt"
         "../domain/agent/registry.rkt")

(define-runtime-path builtin-dir "../plugins")

;; a throwaway plugin directory: (name . entry-source), written to a temp dir
(define (make-plugin-dir specs)
  (define root (make-temporary-file "tmx-plugins-~a" 'directory))
  (for ([spec (in-list specs)])
    (define id (car spec))
    (define pdir (build-path root id))
    (make-directory pdir)
    (call-with-output-file (build-path pdir "plugin.json")
      (lambda (o) (fprintf o "{\"id\":\"~a\",\"name\":\"~a\",\"version\":\"9.9.9\",\"description\":\"test\",\"entry\":\"main.rkt\"}" id id)))
    (call-with-output-file (build-path pdir "main.rkt")
      (lambda (o) (display (cdr spec) o))))
  root)

(define GOOD "#lang racket/base\n(provide tools)\n(define tools (list (list \"t_ok\" (hasheq 'type \"function\") \"chat:use\" (lambda (c p a) \"ok\"))))\n")
(define BROKEN "#lang racket/base\n(provide tools)\n(define tools (this-identifier-does-not-exist))\n")

(test-case "a list of directories loads them all, built-ins included (#45)"
  (define extra (make-plugin-dir (list (cons "zz-extra" GOOD))))
  (define loaded (load-plugins! (list builtin-dir extra)))
  (define ids (map (lambda (p) (hash-ref p 'id)) loaded))
  (check-true (and (member "zz-extra" ids) #t) "the extra plugin loaded")
  ;; …and the shipped ones are still there, which is the whole point: pointing
  ;; TELEMACHUS_PLUGINS at your own directory used to remove them
  (check-true (and (member "doc-pipeline" ids) #t) "doc-pipeline survived")
  (check-true (and (member "example-tools" ids) #t))
  (check-true (> (length ids) 3))
  (delete-directory/files extra))

(test-case "a plugin's directory is remembered, so its pages can be found (#44)"
  (define extra (make-plugin-dir (list (cons "zz-dir" GOOD))))
  (load-plugins! (list builtin-dir extra))
  ;; the pages helpers ask the loader rather than rebuilding impl-root/plugins/…,
  ;; which is why a plugin outside the checkout used to 404 every page it had
  (check-equal? (plugin-dir "zz-dir") (build-path extra "zz-dir"))
  (check-true (path? (plugin-dir "example-tools")))
  (check-false (plugin-dir "no-such-plugin"))
  (delete-directory/files extra))

(test-case "a plugin that will not load is REPORTED, and the rest still load (#48)"
  (define d (make-plugin-dir (list (cons "aa-broken" BROKEN) (cons "bb-fine" GOOD))))
  (define logged '())
  (define loaded (load-plugins! (list d) #:log (lambda (s) (set! logged (cons s logged)))))
  (check-equal? (map (lambda (p) (hash-ref p 'id)) loaded) '("bb-fine")
                "one bad plugin does not stop the others")
  (define bad (plugin-failures))
  (check-equal? (length bad) 1)
  (check-equal? (hash-ref (car bad) 'plugin) "aa-broken")
  (check-true (string? (hash-ref (car bad) 'error)))
  (check-true (for/or ([l (in-list logged)]) (regexp-match? #rx"FAILED" l))
              "…and the log says FAILED, not something that reads like progress")
  ;; a later load with nothing broken clears the report
  (load-plugins! (list builtin-dir))
  (check-equal? (plugin-failures) '())
  (delete-directory/files d))

(test-case "two plugins with the same id: the first wins and the second is a failure"
  (define shadow (make-plugin-dir (list (cons "example-tools" GOOD))))
  (load-plugins! (list builtin-dir shadow))
  ;; the SHIPPED example-tools is the one that loaded…
  (check-true (path? (plugin-dir "example-tools")))
  (check-false (equal? (plugin-dir "example-tools") (build-path shadow "example-tools")))
  ;; …and the shadowing copy is reported rather than silently ignored
  (check-true (for/or ([f (in-list (plugin-failures))])
                (regexp-match? #rx"already loaded" (hash-ref f 'error))))
  (delete-directory/files shadow)
  (void (load-plugins! (list builtin-dir))))
