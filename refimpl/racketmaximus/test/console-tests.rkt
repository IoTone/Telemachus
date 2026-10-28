#lang racket/base

;; test/console-tests.rkt — the console's own file, as a shipped artifact (issue #27).
;;
;; The nonce policy only holds while the console has NO inline event handlers: a
;; nonce cannot authorize an `onclick` attribute, so one new inline handler would
;; silently stop working under the very policy this slice earned. That is not
;; something the e2e gate can be relied on to catch (it exercises the main paths,
;; not all 141 handlers), so it is pinned here, statically, where it is cheap.
;;   raco test test/console-tests.rkt

(require rackunit racket/file racket/string racket/list racket/runtime-path)

(define-runtime-path console-html "../static/index.html")
(define-runtime-path console-dir "../static/console")
(define shell (file->string console-html))

;; #110 r6 moved the console's 2,295 lines of inline script into
;; static/console/*.js. This file named static/index.html and nothing else, so a
;; named-file read would have gone on passing while looking at a shell that no
;; longer holds a single handler — the same false PASS r3 had to fix in
;; test/route-perm-gate-tests.rkt. `html` is the shell PLUS every script it
;; loads, which is what the browser actually gets.
(define script-files
  (sort (for/list ([p (in-list (directory-list console-dir))]
                   #:when (regexp-match? #rx"[.]js$" (path->string p)))
          (path->string p))
        string<?))
(define html
  (string-join (cons shell (for/list ([n (in-list script-files)])
                             (file->string (build-path console-dir n))))
               "\n"))

(test-case "the console has no inline event handlers"
  ;; the delegated dispatcher replaced every one of them; adding a new
  ;; `onclick="…"` would need `script-src 'unsafe-inline'` back
  (define found
    (for*/list ([ev (in-list '("click" "input" "change" "keydown" "keyup" "submit"
                               "focus" "blur" "mouseover" "mouseout" "load" "error"))]
                [m (in-value (regexp-match* (pregexp (string-append "\\bon" ev "=\"")) html))]
                #:when (pair? m))
      (cons ev (length m))))
  (check-equal? found '()
                "use data-h-<event>=\"${H((el,ev)=>…)}\" instead — see the dispatcher at the top of the script"))

(test-case "…and it does use the delegated form"
  ;; a positive control: if the regexp above stopped matching for some unrelated
  ;; reason, this is what says the handlers are really there
  (check-true (> (length (regexp-match* #px"data-h-(click|input|change|keydown)=" html)) 100))
  (check-true (string-contains? html "function H(fn)") "the registry")
  (check-true (string-contains? html "ev.preventDefault()") "…and `return false` is honoured"))

;; The one bug this conversion actually produced, and the reason it is pinned:
;; `${live?'data-h-click="${H(…)}"':'disabled'}` puts the attribute inside a
;; SINGLE-QUOTED string, so `${H(…)}` is never interpolated — the button ships a
;; literal "${H(...)}" and does nothing at all. It cost the funnel's submit button
;; and was invisible until a browser test pressed it.
(test-case "no handler is stranded in a plain string instead of a template literal"
  (check-equal? (regexp-match* #px"'data-h-(click|input|change|keydown)" html) '()
                "a data-h attribute inside a single-quoted string never interpolates H()")
  ;; the double-quoted variant, spelled with a character class to keep the quote
  ;; out of the pattern's own delimiters
  (check-equal? (regexp-match* #px"[\"]data-h-(click|input|change|keydown)=" html) '())
  ;; There is no useful check here for "the RENDERED attribute holds an index": in
  ;; this file every one of them is literally the registry call, and is meant to be.
  ;; A browser is what sees the rendered form — funnel-l10n.sh is what caught the
  ;; stranded button.
  (void))

(test-case "the shell has NO inline script, and loads exactly the files on disk"
  ;; Since #110 r6 there is no inline block, which is why the console's CSP is a
  ;; plain `script-src 'self'` with neither 'unsafe-inline' nor a nonce. A bare
  ;; `<script>` reintroduced here would be silently DEAD under that policy, so it
  ;; is refused statically rather than discovered in a browser.
  (check-equal? (regexp-match* #px"<script>" shell) '()
                "no inline script: the console's CSP has no 'unsafe-inline' and no nonce")
  ;; …and the two sides agree. A file added to static/console/ but never loaded
  ;; is dead code that looks live; a tag naming a file that is not there is a 404
  ;; the console cannot recover from. Both directions, like the config gate.
  (define loaded
    (for/list ([m (in-list (regexp-match* #px"<script src=\"/console/([^\"]+)\">" shell
                                          #:match-select cadr))])
      (bytes->string/utf-8 (if (bytes? m) m (string->bytes/utf-8 m)))))
  (check-equal? loaded script-files
                "every file in static/console/ is loaded, in name order, and nothing else is")
  (check-true (> (length script-files) 1) "…and the split really happened"))

;; ---- sending a prompt (issues #174, #181) ----------------------------------
;; #174 was reported from outside: one Send billed two model calls. The console
;; has no JS test runner, so the wiring is pinned here the way the permission
;; gates are pinned — by reading the source. The claim is narrow and worth
;; stating: this proves the guard is WIRED, not that it holds under a race.
;; What makes the race uninteresting is that the check and the set are in the
;; same synchronous run (no `await` between them), which the third case pins.
(define (fn-body name)
  (define m (regexp-match
             (pregexp (string-append "(?s:(?:async )?function " name "[(][^)]*[)].*?\n[}])")) html))
  (and m (car m)))

(test-case "a send path cannot start twice"
  (for ([f '("doChat" "doAgent")] [flag '("chatAbort" "agentAbort")])
    (define body (fn-body f))
    (check-true (and body #t) (format "~a is still a function" f))
    ;; the early return IS the guard
    (check-true (string-contains? body (string-append "if(S." flag ") return;"))
                (format "~a returns early while one send is in flight" f))
    ;; …and it is released however the stream ends, or one network error leaves
    ;; the button dead with no way back but a reload
    (check-true (regexp-match? (pregexp (string-append "finally *[{] *S[.]" flag "=null")) body)
                (format "~a clears ~a in a finally" f flag))))

(test-case "the guard is set before anything can yield"
  ;; Two activations in one tick must not both get past the check, so nothing
  ;; between the early return and the assignment may `await`.
  (for ([f '("doChat" "doAgent")] [flag '("chatAbort" "agentAbort")])
    (define body (fn-body f))
    (define head (car (regexp-split (pregexp (string-append "S\\." flag "=ac")) body)))
    (check-false (string-contains? head "await")
                 (format "~a does not await between the check and the set" f))))

(test-case "Enter sends and Shift+Enter does not"
  (check-true (string-contains? html "function sendKey(ev, fn)") "the shared key handler")
  (define body (car (regexp-match #px"(?s:function sendKey[(]ev, fn[)][{].*?\n[}])" html)))
  (check-true (string-contains? body "ev.shiftKey") "Shift+Enter is not a send")
  ;; the Enter that CONFIRMS a Japanese IME conversion must not send
  (check-true (string-contains? body "ev.isComposing") "an IME confirmation is not a send")
  (check-true (string-contains? body "ev.preventDefault()") "…and the newline is suppressed when it sends")
  ;; both prompts are wired to it, through the delegated form like everything else
  (for ([id '("cp" "ap")])
    (check-true (regexp-match? (pregexp (string-append "id=\"" id "\"[^>]*data-h-keydown")) html)
                (format "#~a sends on a key" id))))

;; ---- the search control, and the fleet's figures (issues #176, #178) --------
;; Both were reported from outside, with a screenshot each, and both are layout
;; — which this file cannot judge. What it CAN pin is the half of each fix that
;; a later edit would silently undo: the Enter handler the search issue asks
;; twice to keep, and the per-figure explanations the workers issue is about.

(test-case "the search field and its button are one control, and Enter still searches"
  (define body (fn-body "searchView"))
  (check-true (and body #t) "searchView is still a function")
  (check-true (string-contains? body "class=\"searchbar\"") "one composed control")
  (check-false (string-contains? body "align-items:end")
               "not two flex columns of different heights, which is what hung the button low")
  (check-true (regexp-match? #px"id=\"sq\"[^>]*data-h-keydown" body) "#sq still sends on a key")
  ;; through #174's shared rule, so a Japanese IME confirmation is no longer a search
  (check-true (string-contains? body "sendKey(ev,doSearch)") "…and through the one Enter rule")
  ;; a button whose whole label is a glyph needs an accessible name
  (check-true (string-contains? body "aria-label=") "the magnifier button is named")
  (check-true (string-contains? shell ".searchbar:focus-within")
              "the focus ring is on the wrapper — a borderless input inside a bordered box shows none"))

(test-case "every fleet figure explains itself, and its window is selectable"
  (define body (fn-body "wkFigs"))
  (check-true (and body #t) "wkFigs is still a function")
  ;; one tooltip per figure, not one for the column: the three numbers answer
  ;; different questions and the lease expiry is the one worth finding
  (check-true (string-contains? body "title=\"${esc(t(key))}\"")
              "a figure is rendered with a tooltip of its own, not one for the column")
  (check-equal? (length (regexp-match* #px"fig[(]w[.]" body)) 3
                "done, failed and lease-expired are three figures, each with its own key")
  (for ([k '("wkdonehint" "wkerrhint" "wkexpiredhint")])
    (check-true (string-contains? body k) (format "~a is used" k)))
  ;; the header NAMES the window rather than hardcoding one, because the window moved
  (check-true (string-contains? html "t('wkwindow').replace('{window}'")
              "the column header carries the window that was actually asked for")
  (check-true (string-contains? html "function fleetQuery()") "…and the read asks for it")
  (check-true (string-contains? html "/api/admin/workers'+fleetQuery()")
              "the fleet read carries the selected window")
  (check-true (regexp-match? #px"WKWINDOWS[.]map[(]h=>`<option" html) "the window is a control")
  ;; the destructive button is not flush against an unexplained number any more
  (check-true (string-contains? html "class=\"btn sm bad\" style=\"margin-left:14px\"")
              "Retire stands apart from Drain, and looks irreversible")
  ;; `class="small"` and `class="small danger"` matched NO rule in the shell, so
  ;; these were bare user-agent buttons and the irreversible one did not look it
  (check-equal? (regexp-match* #px"class=\"small( danger)?\"" html) '()
                "the fleet card uses the shell's own button vocabulary (.btn.sm / .btn.bad)"))
