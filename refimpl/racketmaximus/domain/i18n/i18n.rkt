#lang racket/base

;; domain/i18n/i18n.rkt — the runtime Localizer.
;;
;; Surface code calls (t "namespace.id" #:default "English {x}" #:args (hasheq 'x v)).
;; Resolution walks the locale fallback chain (…→ en), then the inline default,
;; then a visible ⟦id⟧ marker. `no-i18n` marks a string as intentionally not
;; localized (the linter treats it, like `t`, as exempt).

(require racket/string
         json
         "icu.rkt")

(provide (struct-out localizer)
         current-localizer current-locale
         empty-localizer load-localizer locale-chain
         t no-i18n)

;; catalogs : (hash locale-string → (hash id-string → text))
(struct localizer (locale fallback catalogs) #:transparent)

(define empty-localizer (localizer "en" '("en") (hash)))
(define current-localizer (make-parameter empty-localizer))
(define (current-locale) (localizer-locale (current-localizer)))

;; "es-419" → '("es-419" "es" "en"); "ja" → '("ja" "en"); "en" → '("en")
(define (locale-chain locale)
  (define parts (string-split locale "-"))
  (define chain                              ; most-specific first: es-419 → es
    (let loop ([acc '()] [used '()] [ps parts])
      (if (null? ps) acc
          (let ([cur (string-join (append used (list (car ps))) "-")])
            (loop (cons cur acc) (append used (list (car ps))) (cdr ps))))))
  (if (member "en" chain) chain (append chain '("en"))))

;; Build a localizer from a directory of <locale>.json catalogs (only the given
;; locale + its fallbacks are needed at runtime). Empty translations are dropped
;; so lookup misses and falls through the chain.
(define (load-localizer dir #:locale [locale "en"])
  (define chain (locale-chain locale))
  (define catalogs
    (for/hash ([loc (in-list chain)]
               #:when (file-exists? (build-path dir (string-append loc ".json"))))
      (define j (call-with-input-file (build-path dir (string-append loc ".json")) read-json))
      (define msgs (hash-ref j 'messages (hasheq)))
      (values loc
              (for/hash ([(k v) (in-hash msgs)]
                         #:when (not (string=? (hash-ref v 'text "") "")))
                (values (symbol->string k) (hash-ref v 'text ""))))))
  (localizer locale chain catalogs))

(define (t id #:default [default #f] #:args [args (hasheq)])
  (define L (current-localizer))
  (define text
    (or (for/or ([loc (in-list (localizer-fallback L))])
          (define c (hash-ref (localizer-catalogs L) loc #f))
          (and c (hash-ref c id #f)))
        default
        (string-append "⟦" id "⟧")))    ; ⟦id⟧ — visibly missing
  (format-message text args (localizer-locale L)))

(define (no-i18n s) s)
