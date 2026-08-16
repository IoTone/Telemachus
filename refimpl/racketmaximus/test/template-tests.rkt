#lang racket/base

;; test/template-tests.rkt — Tier-C custom HTML templates (slice 44): the sanitizer
;; (strips active content), placeholder substitution with escaping, and the wrapped
;; page. raco test test/template-tests.rkt

(require rackunit
         "../domain/beta/template.rkt")

(define (has? hay needle) (and (regexp-match? (regexp (regexp-quote needle)) hay) #t))

(test-case "sanitizer strips scripts, handlers, javascript: URIs, dangerous tags"
  (check-false (has? (sanitize-template "<script>alert(1)</script><h1>hi</h1>") "<script"))
  (check-true  (has? (sanitize-template "<script>x</script><h1>hi</h1>") "<h1>hi</h1>"))     ; keeps benign HTML
  (check-false (has? (sanitize-template "<div onclick=\"steal()\">x</div>") "onclick"))
  (check-false (has? (sanitize-template "<img src=x onerror='hack()'>") "onerror"))
  (check-false (has? (sanitize-template "<a href=\"javascript:evil()\">x</a>") "javascript:"))
  (check-false (has? (sanitize-template "<iframe src=//evil></iframe>") "<iframe"))
  (check-false (has? (sanitize-template "<object data=x></object>") "<object"))
  (check-false (has? (sanitize-template "<meta http-equiv=refresh content=0>") "<meta"))
  (check-false (has? (sanitize-template "<form action=\"//evil\">x</form>") "action"))
  ;; presentational content survives
  (check-true  (has? (sanitize-template "<style>body{color:red}</style><p>ok</p>") "<style>"))
  (check-true  (has? (sanitize-template "<form><input name=email></form>") "<form>")))

(test-case "render-template substitutes placeholders and escapes text values"
  (define cfg (hasheq 'title "Join us" 'subtitle "now" 'eyebrow "Beta" 'logo "ACME"
                      'cta "Apply" 'footer "©"
                      'fields (list (hasheq 'key "email" 'label "Email" 'type "email" 'required #t))))
  (define out (render-template "<h1>{{title}}</h1><p>{{subtitle}}</p><b>{{logo}}</b><button>{{cta}}</button>{{fields}}{{message}}{{unknown}}" cfg))
  (check-true (has? out "<h1>Join us</h1>"))
  (check-true (has? out "<b>ACME</b>"))
  (check-true (has? out "<button>Apply</button>"))
  (check-true (has? out "name=\"email\""))          ; {{fields}} generated a named input
  (check-true (has? out "data-beta-msg"))           ; {{message}}
  (check-false (has? out "{{unknown}}")))           ; unknown → removed

(test-case "a malicious config value is escaped, not injected"
  (define out (render-template "<h1>{{title}}</h1>" (hasheq 'title "<img src=x onerror=alert(1)>" 'fields '())))
  (check-false (has? out "<img src=x"))
  (check-true  (has? out "&lt;img")))

(test-case "template-page wraps with the trusted bootstrap only"
  (define page (template-page (hasheq 'title "T" 'fields '()) "<h1>{{title}}</h1>"))
  (check-true (has? page "<!doctype html>"))
  (check-true (has? page "data-beta-submit"))       ; bootstrap wires the submit trigger
  (check-true (has? page "/api/beta/signup"))       ; bootstrap posts to the gate
  (check-true (has? page "<h1>T</h1>")))
