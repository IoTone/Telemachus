#lang racket/base

;; domain/i18n/policy.rkt — the instance's LOCALIZATION POLICY: which language an
;; unconfigured request gets, and whether per-request negotiation happens at all.
;;
;; Before this, locale resolution was `X-Telemachus-Locale` → `Accept-Language` →
;; the string "en", hardcoded in the request wrapper. That meant an operator
;; running a Japanese-speaking instance had no way to say so: every visitor whose
;; browser did not volunteer `ja` got English, including on the sign-in screen,
;; which is the one page you cannot ask someone to configure their way out of.
;;
;; Two settings, both instance-wide (`instance:manage`), both stored as one
;; document in `instance_settings`:
;;
;;   default   the locale a request gets when it names none, when it names one
;;             this build has no catalog for, or when negotiation is off.
;;   enabled   #t (the default) negotiates per request; #f pins EVERY request to
;;             `default` and tells the console to hide its language switcher.
;;
;; `enabled: #f` is a real operator need and not the same as "only ship one
;; catalog": a bilingual instance may still want one voice — support scripts,
;; screenshots in a manual, and audit conversations all get simpler when the
;; product answers everyone the same way. Turning it off does NOT delete or hide
;; the other catalogs; flip it back on and they return.
;;
;; `available` is a FACT, not a setting: it is whichever `<locale>.json` files
;; the build actually ships, so it can never claim a language the instance cannot
;; render. That is also why `default` is validated against it — an operator who
;; types `de` on a build with no German catalog gets a 400, not an instance that
;; silently serves English while claiming German.

(require racket/string racket/list
         "catalog.rkt"                    ; coverage, and the floor a locale must clear
         "../settings/settings.rkt")

(provide i18n-policy i18n-policy-set!
         resolve-locale
         ;; EXPORTED FOR A SECOND ASKER, with a test behind it (#110 r4's stated
         ;; exception): the help corpus recognises a locale in a documentation
         ;; path only if this build ships a catalog for it (HELP‑10), which is
         ;; the same `available` rule — derived from the files on disk, never
         ;; stored — rather than a second list that would drift from this one.
         available-locales
         ;; and the list the instance OFFERS, which is a different question: the
         ;; catalogs it ships, minus the ones too incomplete to answer in
         advertised-locales)

(define KEY "i18n")

(define (i18n-defaults) (hasheq 'default "en" 'enabled #t))

;; Whichever catalogs this build ships. Scanned once PER DIRECTORY — the tree
;; does not change under a running process, but a test points this at a temp copy
;; (`TMACH_LOCALES`), and a single memo answered the first directory it ever saw
;; for every later one. Keyed by the path, so the runtime keeps the scan and the
;; suite keeps its isolation.
(define scanned (make-hash))
(define (available-locales dir)
  (define key (path->string (simplify-path (path->complete-path dir) #f)))
  (hash-ref! scanned key
    (lambda ()
      (let ([ls (sort (for/list ([f (in-list (directory-list dir))]
                                 #:when (regexp-match? #px"\\.json$" (path->string f)))
                        (regexp-replace #px"\\.json$" (path->string f) ""))
                      string<?)])
        ;; A build with no catalogs at all still has to answer something.
        (if (null? ls) '("en") ls)))))

;; WHAT THE INSTANCE OFFERS, which is not the same as what it ships.
;;
;; A catalog file on disk can be opened; a locale can be OFFERED only if it is
;; translated enough to answer in. `en` and `ja` are; `nl` and `es-419` ship 190
;; of 1,179 messages each and are therefore not advertised — the file stays, the
;; Localization Manager still imports it and a translator still works on it, and
;; the switcher stops offering a language that answers in English. The floor and
;; the measurement live in `catalog.rkt` (LOCALE-COVERAGE-FLOOR), because they
;; are a property of a catalog rather than of an instance's policy.
(define (advertised-locales dir)
  (filter (lambda (l) (advertised? dir l)) (available-locales dir)))

(define (normalize h dir)
  (define d (i18n-defaults))
  (define avail (advertised-locales dir))
  (define want (let ([v (hash-ref h 'default (hash-ref d 'default))])
                 (if (string? v) (string-trim v) "")))
  ;; a build can, in principle, advertise nothing above the floor — every
  ;; catalog is a draft. Then the default is `en`, which is the source and is
  ;; always complete by definition, rather than a locale with no file behind it.
  (hasheq 'default (if (member want avail) want (if (member "en" avail) "en" (if (pair? avail) (car avail) "en")))
          'enabled (not (eq? (hash-ref h 'enabled #t) #f))))

(define (i18n-policy conn dir)
  (define v (setting-ref conn KEY #f))
  (define p (normalize (if v v (i18n-defaults)) dir))
  (hash-set p 'available (advertised-locales dir)))

;; Returns the stored document plus `available`, so a caller can render the new
;; state without a second read. Raises on an unknown locale rather than quietly
;; substituting one — see the header.
(define (i18n-policy-set! conn dir h)
  (define avail (advertised-locales dir))
  (define want (let ([v (hash-ref h 'default #f)]) (and (string? v) (string-trim v))))
  (when (and want (not (member want avail)))
    (error 'i18n-policy-set! "unknown locale ~s; this build ships ~a"
           want (string-join avail ", ")))
  (define merged (normalize h dir))
  (setting-set! conn KEY merged)
  (hash-set merged 'available avail))

;; The single seam every request goes through.
;;   requested : the locale the caller asked for, or #f if it asked for none.
;; With negotiation off, the request does not get a say. With it on, a request
;; for a locale this build cannot render falls back to the instance default —
;; NOT to English, which would be the wrong answer on a Japanese instance.
(define (resolve-locale conn dir requested)
  (define p (i18n-policy conn dir))
  (define dflt (hash-ref p 'default))
  (cond
    [(not (hash-ref p 'enabled)) dflt]
    [(not requested) dflt]
    [else
     (define avail (hash-ref p 'available))
     (define base (car (string-split requested "-")))
     (cond
       [(member requested avail) requested]
       ;; `ja-JP` should reach the `ja` catalog; the localizer's own chain would
       ;; do this too, but only after deciding the locale is legitimate.
       [(member base avail) base]
       [else dflt])]))
