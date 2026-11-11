#lang racket/base

;; test/plugin-docs-tests.rkt — one plugin's own reference (0.13.0).
;;
;; A plugin author has no way to publish what their plugin contributes: the
;; generated reference is the INSTANCE's, so a plugin's routes are a section in
;; the middle of three hundred other routes and its tools sit among forty. The
;; answer is the same generator, filtered — `render --plugin <id> --out <dir>` —
;; and the property that matters is that the filter is NARROW and the instance's
;; own page set is untouched.
;;
;; WHAT THIS FILE DOES NOT ESTABLISH: that the CLI printed the right exit code or
;; wording. Those two lines are `main`'s handler around the two refusals below
;; (`no such plugin`, `--plugin needs --out`), and the functions they call are
;; what is asserted here; running the command as a subprocess would boot the
;; plugin loader twice to test a `printf`.
;;
;;   raco test test/plugin-docs-tests.rkt

(require rackunit racket/list racket/string
         "../cli/telemachus-docs.rkt")

;; ONE model with the plugins loaded, then the filtered ones from the same process
(define full (describe))
(define example (describe #:plugin "example-tools"))
(define ocr (describe #:plugin "ocr"))

;; ---------------------------------------------------------------------------
;; 1. the filter keeps the plugin's own things, and nothing else
(test-case "a plugin model keeps its own tools, routes, workflows and the permissions they name"
  ;; the plugin's tools, and only its tools
  (check-true (pair? (hash-ref example 'tools)))
  (for ([t (in-list (hash-ref example 'tools))])
    (check-equal? (hash-ref t 'source) "example-tools"))
  (check-equal? (length (hash-ref example 'tools))
                (length (for/list ([t (in-list (hash-ref full 'tools))]
                                   #:when (equal? (hash-ref t 'source) "example-tools"))
                           t)))
  ;; its routes are in `plugin_routes`, and the CORE route table is EMPTY rather
  ;; than filtered: a plugin contributes no core routes, so an unfiltered table
  ;; here would describe the whole instance under one plugin's name
  (check-equal? (hash-ref example 'routes) '())
  (check-true (pair? (hash-ref example 'plugin_routes)))
  (for ([r (in-list (hash-ref example 'plugin_routes))])
    (check-equal? (hash-ref r 'plugin) "example-tools"))
  ;; the permissions are the ones its tools and routes NAME — `example-tools`
  ;; asks for `chat:use` and nothing else
  (check-equal? (map (lambda (p) (hash-ref p 'name)) (hash-ref example 'permissions))
                '("chat:use"))
  ;; a plugin reference carries no roles: the role matrix is the instance's
  (check-equal? (hash-ref example 'roles) '())
  ;; and the plugin row itself, which the README names
  (check-equal? (map (lambda (p) (hash-ref p 'id)) (hash-ref example 'plugins))
                '("example-tools"))
  (check-equal? (hash-ref example 'plugin) "example-tools")
  (check-equal? (hash-ref example 'version) (hash-ref full 'version)))

(test-case "a plugin that contributes nothing still renders five pages, saying so"
  (check-equal? (hash-ref ocr 'tools) '())
  (check-equal? (hash-ref ocr 'plugin_routes) '())
  (check-equal? (hash-ref ocr 'workflows) '())
  (check-equal? (hash-ref ocr 'permissions) '())
  (define pages (render-all ocr #f (locales-dir (hasheq))))
  (define (page name) (cdr (assoc name pages)))
  ;; every one of the four says WHY it is empty rather than rendering a header
  ;; with no rows, which reads as a generator that failed
  (check-true (and (regexp-match? #rx"contributes no tools" (page "tools.md")) #t))
  (check-true (and (regexp-match? #rx"ships no workflows" (page "workflows.md")) #t))
  (check-true (and (regexp-match? #rx"declares no routes" (page "api.md")) #t))
  (check-true (and (regexp-match? #rx"names no permission" (page "permissions.md")) #t)))

;; ---------------------------------------------------------------------------
;; 2. the page SET: the plugin's five, and the platform's three are absent
(test-case "a plugin reference is five pages plus its strings, not the instance's eight"
  (define names (map car (render-all example #f (locales-dir (hasheq)))))
  (check-equal? names '("README.md" "tools.md" "workflows.md" "permissions.md" "api.md"
                        "strings.json"))
  ;; the three that are absent, each for its own reason: openapi.json describes
  ;; the INSTANCE's API, and plugins.md/sdk.md are the platform's plugin system
  (for ([absent (in-list '("openapi.json" "plugins.md" "sdk.md"))])
    (check-false (and (member absent names) #t) (format "~a is not a plugin page" absent)))
  ;; the locale pass writes no strings.json, as the instance pass does not
  (check-equal? (map car (render-all example "ja" (locales-dir (hasheq))))
                '("README.md" "tools.md" "workflows.md" "permissions.md" "api.md")))

(test-case "the platform reference is UNCHANGED by the filter's existence"
  (define names (map car (render-all full #f (locales-dir (hasheq)))))
  (check-equal? names '("README.md" "tools.md" "workflows.md" "permissions.md" "api.md"
                        "openapi.json" "plugins.md" "sdk.md" "strings.json"))
  ;; and the unfiltered model still carries everything it did
  (check-true (> (length (hash-ref full 'routes)) 100))
  (check-true (pair? (hash-ref full 'roles)))
  (check-false (hash-ref full 'plugin #f)))

;; ---------------------------------------------------------------------------
;; 3. an unknown plugin id is REFUSED, and the refusal is useful
(test-case "an unknown plugin id is refused by name, and the ids that exist are listed"
  (define msg
    (with-handlers ([exn:fail:user? exn-message])
      (describe #:plugin "no-such-plugin")))
  (check-true (string? msg) "it raises rather than answering an empty document")
  (check-true (and (regexp-match? #rx"no-such-plugin" msg) #t) (format "names the id: ~a" msg))
  ;; a reference that is silently empty is the worst shape a generated page can
  ;; take, so the message hands back the vocabulary to choose from
  (check-true (and (regexp-match? #rx"example-tools" msg) #t)
              (format "lists a plugin that exists: ~a" msg)))

;; ---------------------------------------------------------------------------
;; 4. the README says what the reference does NOT cover
(test-case "the plugin README points at the instance's reference for everything else"
  (define readme (cdr (assoc "README.md" (render-all example #f (locales-dir (hasheq))))))
  (check-true (and (regexp-match? #rx"telemachus-docs render" readme) #t))
  (for ([absent (in-list '("openapi.json" "plugins.md" "sdk.md"))])
    (check-true (and (regexp-match? (pregexp (regexp-quote absent)) readme) #t)
                (format "names ~a as existing only in the instance's reference" absent)))
  (check-true (and (regexp-match? #rx"not the instance" readme) #t)
              "and says the routes are this plugin's, not the instance's API"))

;; ---------------------------------------------------------------------------
;; 5. the two CLI refusals, at the function the command calls
(test-case "--plugin without --out is refused, because docs/reference is the instance's"
  (check-exn exn:fail:user? (lambda () (plugin-out-required "example-tools" (hasheq))))
  ;; …and accepted once a directory is named
  (check-true (void? (plugin-out-required "example-tools" (hasheq 'out "/tmp/whatever"))))
  ;; no plugin at all needs no --out, which is every existing invocation
  (check-true (void? (plugin-out-required #f (hasheq)))))
