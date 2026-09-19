#lang racket/base

;; test/console-tests.rkt — the console's own file, as a shipped artifact (issue #27).
;;
;; The nonce policy only holds while the console has NO inline event handlers: a
;; nonce cannot authorize an `onclick` attribute, so one new inline handler would
;; silently stop working under the very policy this slice earned. That is not
;; something the e2e gate can be relied on to catch (it exercises the main paths,
;; not all 141 handlers), so it is pinned here, statically, where it is cheap.
;;   raco test test/console-tests.rkt

(require rackunit racket/file racket/string racket/runtime-path)

(define-runtime-path console-html "../static/index.html")
(define html (file->string console-html))

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

(test-case "the shell has exactly one script block, so one nonce covers it"
  (check-equal? (length (regexp-match* #px"<script" html)) 1)
  (check-equal? (length (regexp-match* #px"</script>" html)) 1))
