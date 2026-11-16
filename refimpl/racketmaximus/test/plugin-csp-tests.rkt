#lang racket/base

;; test/plugin-csp-tests.rkt — the policy a plugin bundle page is served under
;; (0.13.0).
;;
;; The rule has two halves and they can fail independently:
;;
;;   1. WHAT is sent. Every bundle page gets the strict policy — no inline
;;      script, this origin only — unless the plugin's manifest declares the
;;      `"csp": "relaxed"` escape hatch, in which case it gets the baseline it
;;      has always had. A mode with no policy behind it must fail the plugin's
;;      LOAD rather than silently receive the wrong one.
;;   2. Whether the shipped pages can LIVE under it. A strict header over a page
;;      with an inline `<script>` is a page that does not work, so the four pages
;;      the platform ships are scanned: no inline script, no `on*=` attribute, and
;;      every `src` they name is a file that exists. That scan is what keeps the
;;      migration from rotting back the first time somebody adds a quick script
;;      block to a bundle.
;;
;; WHAT THIS FILE DOES NOT ESTABLISH: that a browser enforced the header. That is
;; a runtime fact and it is asserted where a real page is loaded — the console's
;; own CSP is proven by `test/e2e/validate.sh` failing on any console error, and
;; the bundle routes carry the same header mechanism. The header VALUE is what is
;; pinned here, plus `test/server-smoke.sh`'s assertion over HTTP.
;;
;;   raco test test/plugin-csp-tests.rkt

(require rackunit
         racket/file
         racket/list
         racket/path
         racket/runtime-path
         racket/string
         "../domain/agent/plugins.rkt"
         "../surface/csp.rkt")

(define-runtime-path plugins-dir "../plugins")
(define-runtime-path static-dir "../static")

(define (temp-plugin-dir manifest-body entry-body)
  (define root (make-temporary-file "tmx-csp-~a" 'directory))
  (define pdir (build-path root "zz-csp"))
  (make-directory pdir)
  (call-with-output-file (build-path pdir "plugin.json")
    (lambda (o) (write-string manifest-body o))
    #:exists 'truncate)
  (call-with-output-file (build-path pdir "main.rkt")
    (lambda (o) (write-string entry-body o))
    #:exists 'truncate)
  root)

(define GOOD-ENTRY "#lang racket/base\n(provide tools)\n(define tools '())\n")

;; The directives of a policy, as (name . value) pairs — so a test can ask what
;; `script-src` says without the answer being confused by `style-src`, which keeps
;; its `'unsafe-inline'` in BOTH policies on purpose.
(define (directives policy)
  (for/list ([part (in-list (string-split policy ";"))]
             #:unless (string=? (string-trim part) ""))
    (define toks (string-split (string-trim part)))
    (cons (car toks) (cdr toks))))

(define (directive policy name)
  (let ([hit (assoc name (directives policy))]) (and hit (cdr hit))))

;; ---------------------------------------------------------------------------
;; 1. the two policies, and the difference between them
(test-case "the strict bundle policy forbids inline script; the relaxed one permits it"
  (check-false (member "'unsafe-inline'" (directive STRICT-BUNDLE-CSP "script-src"))
               "the whole point: an inline <script> or an on* attribute cannot run")
  (check-true (and (member "'unsafe-inline'" (directive CONSOLE-CSP "script-src")) #t)
              "the escape hatch is today's policy, which does permit it")
  ;; …and both close the doors that matter regardless of which one a page gets
  (for ([p (in-list (list STRICT-BUNDLE-CSP CONSOLE-CSP))] [who (in-list '("strict" "relaxed"))])
    (check-equal? (directive p "object-src") '("'none'") (format "~a: object-src" who))
    (check-equal? (directive p "base-uri") '("'self'") (format "~a: base-uri" who))
    (check-equal? (directive p "frame-ancestors") '("'self'") (format "~a: frame-ancestors" who))
    (check-equal? (directive p "default-src") '("'self'") (format "~a: default-src" who)))
  ;; the strict policy reaches this origin only for script and connections, which
  ;; is what makes a CDN a non-answer
  (check-equal? (directive STRICT-BUNDLE-CSP "script-src") '("'self'"))
  (check-equal? (directive STRICT-BUNDLE-CSP "connect-src") '("'self'"))
  ;; style keeps its inline allowance in both, deliberately (a theme is written as
  ;; inline custom properties); asserting it here says the difference between the
  ;; policies is script, not style
  (check-true (and (member "'unsafe-inline'" (directive STRICT-BUNDLE-CSP "style-src")) #t)))

;; ---------------------------------------------------------------------------
;; 2. every mode has a policy, and nothing else does
(test-case "the closed vocabulary and the policies agree in both directions"
  (for ([m (in-list PLUGIN-CSP-MODES)])
    (check-true (string? (bundle-csp m)) (format "~a has a policy" m)))
  (check-exn exn:fail? (lambda () (bundle-csp 'nonexistent)))
  ;; the default is strict, and a shipped plugin that says nothing gets it
  (check-eq? PLUGIN-CSP-DEFAULT 'strict)
  (check-equal? PLUGIN-CSP-MODES '(strict relaxed) "exactly two, and no third without a policy"))

;; ---------------------------------------------------------------------------
;; 3. the manifest field, judged like every other one
(test-case "check-csp!: absent is strict, relaxed is accepted, anything else fails BY NAME"
  (check-eq? (check-csp! "p" (hasheq)) 'strict)
  (check-eq? (check-csp! "p" (hasheq 'csp "strict")) 'strict)
  (check-eq? (check-csp! "p" (hasheq 'csp "relaxed")) 'relaxed)
  (define msg
    (with-handlers ([exn:fail? exn-message])
      (check-csp! "acme" (hasheq 'csp "loose"))))
  ;; a refusal that does not say what IS allowed is a guessing game for the
  ;; plugin author, so both the offending value and the vocabulary are named
  (check-true (string? msg))
  (check-true (and (regexp-match? #rx"loose" msg) #t) (format "names the value: ~a" msg))
  (check-true (and (regexp-match? #rx"relaxed" msg) #t) (format "names the allowed modes: ~a" msg))
  ;; a non-string is refused too rather than coerced — `true` in JSON is not a mode
  (check-exn exn:fail? (lambda () (check-csp! "p" (hasheq 'csp #t)))))

;; ---------------------------------------------------------------------------
;; 4. a loaded plugin, and the listing an operator reads
(test-case "a manifest that declares relaxed is served the baseline; one that says nothing is strict"
  (define relaxed-dir
    (temp-plugin-dir
     "{\"id\":\"zz-csp\",\"name\":\"csp\",\"version\":\"9.9.9\",\"description\":\"t\",\"entry\":\"main.rkt\",\"csp\":\"relaxed\"}"
     GOOD-ENTRY))
  (load-plugins! (list plugins-dir relaxed-dir))
  (check-eq? (plugin-csp-mode "zz-csp") 'relaxed)
  (check-equal? (bundle-csp (plugin-csp-mode "zz-csp")) CONSOLE-CSP)
  (check-true (for/or ([p (in-list (loaded-plugins))])
                (and (string=? (hash-ref p 'id) "zz-csp")
                     (string=? (hash-ref p 'csp "?") "relaxed"))))
  ;; an UNLOADED plugin answers the default rather than raising: the routes 404
  ;; before they build a header, so the accessor must not be the thing that throws
  (check-eq? (plugin-csp-mode "no-such-plugin") 'strict)
  ;; a reload without the declaration must not keep the old mode — the second load
  ;; runs in the same process, and a stale entry is a page served under a policy
  ;; its plugin no longer asks for
  (call-with-output-file (build-path relaxed-dir "zz-csp" "plugin.json")
    (lambda (o) (write-string
                 "{\"id\":\"zz-csp\",\"name\":\"csp\",\"version\":\"9.9.9\",\"description\":\"t\",\"entry\":\"main.rkt\"}" o))
    #:exists 'truncate)
  (load-plugins! (list relaxed-dir))
  (check-eq? (plugin-csp-mode "zz-csp") 'strict)
  (delete-directory/files relaxed-dir)
  ;; the shipped set is strict, every one of them
  (load-plugins! (list plugins-dir))
  (for ([p (in-list (loaded-plugins))])
    (check-equal? (hash-ref p 'csp "?") "strict"
                  (format "~a ships strict" (hash-ref p 'id)))))

;; ---------------------------------------------------------------------------
;; 5. the pages the platform ships can live under the policy it sends them
;;
;; Four pages: three authenticated bundles and the beta funnel's landing page,
;; which is served by the PUBLIC bundle route and carries the same policy. A
;; strict header over an inline block is a page that silently does nothing, so
;; this is the half that makes the header honest.
(define (html-pages dir)
  (cond
    [(not (directory-exists? dir)) '()]
    [else
     (for/list ([p (in-directory dir)]
                #:when (and (file-exists? p) (regexp-match? #rx"[.]html$" (path->string p))))
       (path->complete-path p))]))

;; AN HTML COMMENT IS NOT A SCRIPT, and a scan that reads one has failed its own
;; subject: the comments on these pages explain the policy and therefore MENTION
;; `<script>`. This is the tree's sixth appearance of a text scan reading its own
;; prose, so the remedy is the scan's — strip the comments, then look.
(define (page-markup html)
  (regexp-replace* #px"<!--[\\s\\S]*?-->" html ""))

(define (page-scripts markup)
  ;; every `<script …>` open tag, as its attribute text
  (regexp-match* #px"<script\\b[^>]*>" markup))

(test-case "no shipped bundle page carries an inline script or an inline handler"
  (define pages
    (append* (for/list ([d (in-list (sort (map path->string (directory-list plugins-dir)) string<?))])
               (append (html-pages (build-path plugins-dir d "bundle"))
                       (html-pages (build-path plugins-dir d "landing"))))))
  (check-true (>= (length pages) 4) "the four pages this policy was migrated for")
  (for ([p (in-list pages)])
    (define markup (page-markup (file->string p)))
    (define where (path->string p))
    ;; `.html` pages are the ones the bundle routes serve; a `<script>` with no
    ;; `src` is exactly what `script-src 'self'` refuses
    (for ([tag (in-list (page-scripts markup))])
      (check-true (regexp-match? #px"\\bsrc=" tag)
                  (format "~a: <script> needs a src under the strict policy: ~a" where tag)))
    ;; an `on*=` attribute is the other thing the policy refuses (and could not
    ;; authorize even with a nonce). `\son` needs the whitespace, so `content=`
    ;; inside a <meta> is not a false positive.
    (define evt (regexp-match #px"\\son[a-z]+\\s*=\\s*[\"']" markup))
    (check-false evt (format "~a: inline event handler ~a" where (and evt (car evt))))
    ;; every same-bundle `src` names a file that is really there — a migration
    ;; that points at a script nobody wrote is a page that does not work either
    (for ([m (in-list (regexp-match* #px"<script\\b[^>]*\\bsrc=\"([^\"]+)\"" markup #:match-select cadr))])
      (cond
        [(string-prefix? m "/")
         ;; an absolute path is served by a core route, not the bundle
         (check-equal? m "/beta-sdk.js" (format "~a: the only absolute script is the SDK" where))
         (check-true (file-exists? (build-path static-dir "beta-sdk.js")))]
        [else
         (define f (build-path (path-only p) (string-replace m "./" "")))
         (check-true (file-exists? f) (format "~a: script ~a is missing" where m))]))))
