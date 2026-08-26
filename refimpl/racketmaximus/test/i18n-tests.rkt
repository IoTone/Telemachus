#lang racket/base

;; test/i18n-tests.rkt — slice 2: localization runtime + catalog + lint.
;;   raco test test/i18n-tests.rkt   (with pkgs on PLTCOLLECTS)

(require rackunit
         racket/runtime-path
         db-kit/migrate
         "../domain/db/migrations.rkt"
         "db-fixture.rkt"
         "../domain/i18n/icu.rkt"
         "../domain/i18n/catalog.rkt"
         "../domain/i18n/i18n.rkt"
         "../domain/i18n/policy.rkt"
         "../domain/i18n/lint.rkt")

;; ---- ICU MessageFormat ------------------------------------------------------
(test-case "icu: interpolation, plural, select, embedded"
  (check-equal? (format-message "Hello, {name}!" (hasheq 'name "Bob") "en") "Hello, Bob!")
  (check-equal? (format-message "{c, plural, one {# item} other {# items}}" (hasheq 'c 1) "en") "1 item")
  (check-equal? (format-message "{c, plural, one {# item} other {# items}}" (hasheq 'c 5) "en") "5 items")
  (check-equal? (format-message "{c, plural, one {# item} other {# items}}" (hasheq 'c 1) "ja") "1 items")
  (check-equal? (format-message "{g, select, female {she} other {they}}" (hasheq 'g "female") "en") "she")
  (check-equal? (format-message "{g, select, female {she} other {they}}" (hasheq 'g "x") "en") "they")
  (check-equal? (format-message "You have {c, plural, one {# msg} other {# msgs}}." (hasheq 'c 3) "en")
                "You have 3 msgs."))

(test-case "icu: plural categories"
  (check-equal? (plural-category "en" 1) "one")
  (check-equal? (plural-category "en" 2) "other")
  (check-equal? (plural-category "ja" 1) "other")
  (check-equal? (plural-category "es-419" 1) "one"))

;; ---- catalog build / diff / coverage ---------------------------------------
(test-case "catalog: build-en + diff + coverage"
  (define base (build-en-catalog '(("a" "Hello") ("b" "World"))))
  (define ha (msg-hash (catalog-ref base "a")))
  (define hb (msg-hash (catalog-ref base "b")))
  ;; a translated (matching hash), b empty (missing), c unused
  (define target (make-catalog "ja" "en" (hash "a" (cons "こんにちは" ha)
                                               "b" (cons "" hb)
                                               "c" (cons "X" "oldhash"))))
  (define-values (missing stale unused) (diff base target))
  (check-equal? missing '("b"))
  (check-equal? stale '())
  (check-equal? unused '("c"))
  (define-values (covered total) (coverage base target))
  (check-equal? total 2)
  (check-equal? covered 1)
  ;; stale: a present with a wrong (outdated) source hash
  (define target2 (make-catalog "ja" "en" (hash "a" (cons "こ" "WRONG"))))
  (define-values (m2 s2 u2) (diff base target2))
  (check-equal? s2 '("a")))

;; ---- runtime localizer ------------------------------------------------------
(test-case "i18n: locale chain + fallback + default + ICU"
  (check-equal? (locale-chain "es-419") '("es-419" "es" "en"))
  (check-equal? (locale-chain "ja") '("ja" "en"))
  (check-equal? (locale-chain "en") '("en"))
  (define L (localizer "ja" '("ja" "en")
              (hash "ja" (hash "greeting.hello" "こんにちは、{name}さん！")
                    "en" (hash "greeting.hello" "Hello, {name}!"
                               "notes.saved" "Note saved."
                               "inbox.summary" "You have {count, plural, one {# new message} other {# new messages}}."))))
  (parameterize ([current-localizer L])
    (check-equal? (t "greeting.hello" #:args (hasheq 'name "太郎")) "こんにちは、太郎さん！")  ; ja hit
    (check-equal? (t "notes.saved") "Note saved.")                                            ; ja miss → en
    (check-equal? (t "inbox.summary" #:args (hasheq 'count 3)) "You have 3 new messages.")    ; en + plural
    (check-equal? (t "x.y" #:default "Def {v}" #:args (hasheq 'v 9)) "Def 9")                 ; inline default
    (check-equal? (t "no.such") "⟦no.such⟧")))                                                ; visibly missing

;; ---- lint / extract ---------------------------------------------------------
(define-runtime-path ok-fixture "fixtures/surface-ok.rkt")
(define-runtime-path bad-fixture "fixtures/surface-bad.rkt")

(test-case "lint: clean surface has no violations, extracts t-forms"
  (define-values (tforms violations) (analyze-file ok-fixture))
  (check-equal? violations '())
  (check-true (and (assoc "fix.hello" (map (lambda (x) (cons (car x) (cadr x))) tforms)) #t)))

(test-case "lint: bare literal is flagged; require paths + no-i18n are not"
  (define-values (tforms violations) (analyze-file bad-fixture))
  (check-equal? (length violations) 1)
  (check-equal? (hash-ref (car violations) 'text) "Unlocalized!"))

;; ---- instance locale policy (i18n review, finding 2) -----------------------
;; `resolve-locale` runs on EVERY request, off an unauthenticated header. A
;; degenerate tag must resolve, not raise: `string-split` drops empty pieces, so
;; "-" split on "-" is '() and the old `(car ...)` took the head of an empty list.
(define-runtime-path locales-path "../locales")

(test-case "a degenerate locale tag resolves instead of raising"
  (define c (fresh-db #:migrate? #f))
  (migrate! c all-migrations)
  (define dir (path->string locales-path))
  (define dflt (hash-ref (i18n-policy c dir) 'default))
  (for ([bad (in-list (list "-" "--" "---" "" "-ja" "ja-" "-----"))])
    (check-not-exn (lambda () (resolve-locale c dir bad))
                   (format "resolve-locale raised on ~s" bad))
    (check-true (string? (resolve-locale c dir bad))))
  ;; and the ordinary paths still behave
  (check-equal? (resolve-locale c dir "ja") "ja")
  (check-equal? (resolve-locale c dir "ja-JP") "ja")
  (check-equal? (resolve-locale c dir "zz") dflt)
  (check-equal? (resolve-locale c dir #f) dflt))
