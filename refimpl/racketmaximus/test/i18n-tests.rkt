#lang racket/base

;; test/i18n-tests.rkt — slice 2: localization runtime + catalog + lint.
;;   raco test test/i18n-tests.rkt   (with pkgs on PLTCOLLECTS)

(require rackunit
         racket/runtime-path
         racket/file                    ; make-temporary-file, delete-directory/files
         racket/string                  ; string-contains?
         json                           ; write-json, for the catalog fixtures
         "../domain/i18n/icu.rkt"
         "../domain/i18n/catalog.rkt"
         "../domain/i18n/i18n.rkt"
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

;; ---- #282 item 6: the console's catalog, memoised and revalidated ------------
;; `GET /api/i18n/catalog` is public and fetched on every page load, and it used
;; to parse every catalog on disk per request. A memo is only safe WITH a
;; freshness key — an operator who exports a catalog has to see it — so the two
;; halves are one decision and are tested together. Both live in
;; `domain/i18n/i18n.rkt`, not in the handler, so this needs no server: #123's
;; rule, where a test that required `server/kit.rkt` passed everywhere and failed
;; in CI's sqlite leg alone.
(define (ui-cat-dir)
  (make-temporary-file "tmach-ui-cat-~a" 'directory))

(define (write-ui-catalog! dir locale pairs)
  (call-with-output-file (build-path dir (string-append locale ".json"))
    #:exists 'replace
    (lambda (o)
      (write-json (hasheq 'meta (hasheq 'locale locale)
                          ;; SYMBOL keys: a jsexpr object is keyed by symbol, and
                          ;; `write-json` refuses a string key outright
                          'messages (for/hash ([p (in-list pairs)])
                                      (values (string->symbol (car p))
                                              (hasheq 'text (cadr p) 'hash "h"))))
                  o))))

(define (with-ui-cats pairs-en pairs-ja body)
  (define dir (ui-cat-dir))
  (dynamic-wind
    void
    (lambda ()
      (write-ui-catalog! dir "en" pairs-en)
      (write-ui-catalog! dir "ja" pairs-ja)
      (body dir))
    (lambda () (delete-directory/files dir))))

(test-case "ui catalog: the chain is merged in one document, ui.* only"
  (with-ui-cats
   '(("ui.hello" "Hello") ("ui.only-en" "English only") ("notes.saved" "Note saved."))
   '(("ui.hello" "こんにちは") ("ui.blank" ""))
   (lambda (dir)
     (define body (ui-catalog-json dir "ja"))
     (check-true (string-contains? body "\"ui.hello\""))
     (check-true (string-contains? body "こんにちは") "the ja hit")
     (check-true (string-contains? body "English only") "…and the en fallback in the SAME reply")
     (check-true (string-contains? body "\"locale\":\"ja\""))
     (check-false (string-contains? body "notes.saved")
                  "the console's document carries the ui. namespace, not the server's")
     ;; an EMPTY target text falls through to English, and where English has no
     ;; string either it is simply absent — the console shows the key, visibly
     (check-false (string-contains? body "ui.blank"))
     ;; THE BODY IS ASSEMBLED BY HAND so that its keys can be sorted, which makes
     ;; "is it still JSON" a thing to assert rather than to assume: parse it back
     ;; and read a value out.
     (define parsed (with-handlers ([exn:fail? (lambda (_) #f)]) (string->jsexpr body)))
     (check-true (and (hash? parsed) #t) "the document parses as JSON")
     (check-equal? (hash-ref (hash-ref parsed 'messages) 'ui.only-en) "English only")
     ;; …and the keys are in SORTED order, which is what keeps the ETag stable
     ;; across processes (a hasheq's iteration order is not)
     (check-true (regexp-match? #px"\"ui\\.hello\":.*\"ui\\.only-en\":" body)))))

(test-case "ui catalog: the same request is answered from the memo"
  (with-ui-cats '(("ui.hello" "Hello")) '(("ui.hello" "こんにちは"))
    (lambda (dir)
      (define a (ui-catalog-json dir "ja"))
      (define b (ui-catalog-json dir "ja"))
      (check-equal? a b)
      ;; `eq?`, not `equal?`: a rebuild allocates a NEW string, so identity is
      ;; what says the memo answered rather than that two merges agreed. Without
      ;; this the test passes against a version that parses every catalog twice.
      (check-true (eq? a b) "the second request is answered from the memo")
      (check-equal? (ui-catalog-etag a) (ui-catalog-etag (ui-catalog-json dir "ja")))
      ;; a QUOTED strong validator: a bare digest is not an ETag any cache
      ;; compares, and `GET /api/repo-obj/:id/content` sends the quoted form too
      (check-true (and (regexp-match? #px"^\"[0-9a-f]{40}\"$" (ui-catalog-etag a)) #t)))))

(test-case "ui catalog: an edited catalog invalidates both the body and its ETag"
  ;; THE HALF A CACHE WITHOUT A FRESHNESS KEY WOULD BREAK. `POST /api/l10n/export`
  ;; writes a catalog; without this the operator exports, reloads, and reads the
  ;; strings they just replaced.
  (with-ui-cats '(("ui.hello" "Hello")) '(("ui.hello" "こんにちは"))
    (lambda (dir)
      (define before (ui-catalog-json dir "ja"))
      (define tag (ui-catalog-etag before))
      (write-ui-catalog! dir "ja" '(("ui.hello" "こんにちは、世界")))
      (define after (ui-catalog-json dir "ja"))
      (check-false (equal? before after) "the export is visible on the next request")
      (check-true (string-contains? after "こんにちは、世界"))
      (check-false (string=? tag (ui-catalog-etag after))
                   (string-append "a client holding the old ETag must be sent the new body,"
                                  " not answered 304"))
      ;; …and the OLD tag no longer matches the new document, which is exactly the
      ;; comparison the handler makes against `If-None-Match`
      (check-false (string=? tag (ui-catalog-etag (ui-catalog-json dir "ja")))))))

(test-case "ui catalog: a second directory is a second key"
  ;; The smoke and e2e suites point TMACH_LOCALES at a temp copy inside ONE
  ;; process, so a memo keyed only on the locale would answer from the checkout's
  ;; catalogs and the suite would pass against strings it never wrote.
  (with-ui-cats '(("ui.hello" "Hello")) '(("ui.hello" "こんにちは"))
    (lambda (dir-a)
      (with-ui-cats '(("ui.hello" "Hello")) '(("ui.hello" "別の文字列"))
        (lambda (dir-b)
          (define a (ui-catalog-json dir-a "ja"))
          (define b (ui-catalog-json dir-b "ja"))
          (check-false (equal? a b))
          (check-true (string-contains? b "別の文字列")))))))
