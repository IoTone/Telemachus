#lang racket/base

;; domain/i18n/i18n.rkt — the runtime Localizer.
;;
;; Surface code calls (t "namespace.id" #:default "English {x}" #:args (hasheq 'x v)).
;; Resolution walks the locale fallback chain (…→ en), then the inline default,
;; then a visible ⟦id⟧ marker. `no-i18n` marks a string as intentionally not
;; localized (the linter treats it, like `t`, as exempt).

(require racket/string
         racket/port                    ; open-input-string, for the ETag
         file/sha1                      ; sha1 — the primitive `source-hash` uses
         json
         "icu.rkt")

(provide (struct-out localizer)
         current-localizer
         empty-localizer load-localizer locale-chain
         t no-i18n
         ;; the console's catalog as one document, and the cache that keeps the
         ;; most-visited public route from re-parsing every catalog per request
         ui-catalog-json ui-catalog-etag)

;; catalogs : (hash locale-string → (hash id-string → text))
(struct localizer (locale fallback catalogs) #:transparent)

(define empty-localizer (localizer "en" '("en") (hash)))
(define current-localizer (make-parameter empty-localizer))

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

;; ---- the console's catalog, as ONE document (#282 item 6) ---------------------
;; `GET /api/i18n/catalog` answers every `ui.*` string the console draws,
;; already resolved through the fallback chain, in one reply — because a locale
;; with 40% of its strings should not cost two requests. It is PUBLIC and it is
;; fetched on EVERY page load, including the sign-in screen's before anybody has
;; a token, and until now every one of those reads parsed each catalog on disk
;; and merged them again.
;;
;; The memo is keyed by (directory, locale) and validated by a STAMP of the
;; catalog files. The directory is part of the key because `TMACH_LOCALES` points
;; the smoke and e2e suites at a temp copy inside ONE process; the stamp is what
;; lets an operator see the strings they just exported, which a cache with no
;; freshness key would break. It holds at most one entry per (instance directory,
;; shipped locale) — a handful — so it cannot grow.
;;
;; NANOSECONDS, because `file-or-directory-modify-seconds` rounds to a whole
;; second and two exports inside one second is something a person does.
(define ui-catalog-memo (make-hash))          ; (dir . locale) -> (cons stamp body)

(define (catalog-stamp dir)
  (if (not (directory-exists? dir)) '()
      (for/list ([f (in-list (sort (for/list ([p (in-list (directory-list dir))]
                                              #:when (regexp-match? #rx"[.]json$" (path->string p)))
                                     (path->string p))
                                  string<?))])
        (define st (with-handlers ([exn:fail? (lambda (_) #f)])
                     (file-or-directory-stat (build-path dir f) #f)))
        (list f
              (and st (hash-ref st 'size 0))
              (and st (hash-ref st 'modify-time-seconds 0))
              (and st (hash-ref st 'modify-time-nanoseconds 0))))))

;; `locale` in the document is the locale that ANSWERED, not the one asked for:
;; an unknown locale falls back whole, and a client that got Japanese back has to
;; be able to say so.
(define (ui-catalog-doc dir locale)
  (define L (load-localizer dir #:locale locale))
  (define msgs
    (for*/fold ([acc (hasheq)])
               ([l (in-list (localizer-fallback L))]
                [(key v) (in-hash (hash-ref (localizer-catalogs L) l (hash)))]
                #:when (and (> (string-length key) 3) (string=? (substring key 0 3) "ui."))
                #:unless (hash-has-key? acc (string->symbol key)))
      (hash-set acc (string->symbol key) v)))
  (hasheq 'locale locale 'messages msgs))

;; THE BODY IS A STRING, and it is also the entity a cache revalidates: one
;; serialisation, so the bytes the ETag is computed from are the bytes sent.
;;
;; SORTED KEYS, deliberately — the docs generator's `json-out` rule. A hasheq's
;; iteration order is not stable across processes, so an unsorted body would give
;; two replicas, or one instance before and after a restart, DIFFERENT ETags for
;; the SAME strings. Neither is wrong on its own, and the effect is a client
;; refetching a body that never changed. Each key and each value still goes
;; through `jsexpr->string`, which is what escapes them; only the order is ours.
;; JUDGE-13's ordered writer exists for the same reason and the inverse risk.
(define (ui-catalog-messages-text msgs)
  (string-append
   "{"
   (string-join
    (for/list ([k (in-list (sort (map symbol->string (hash-keys msgs)) string<?))])
      ;; the KEY is written as a JSON string, which is what `jsexpr->string` of a
      ;; string is: a symbol is a legal jsexpr OBJECT KEY but not a legal value,
      ;; so serialising one on its own is refused
      (format "~a:~a"
              (jsexpr->string k)
              (jsexpr->string (hash-ref msgs (string->symbol k)))))
    ",")
   "}"))

(define (ui-catalog-text doc)
  (string-append "{\"locale\":" (jsexpr->string (hash-ref doc 'locale))
                 ",\"messages\":" (ui-catalog-messages-text (hash-ref doc 'messages))
                 "}"))

(define (ui-catalog-json dir locale)
  (define stamp (catalog-stamp dir))
  (define k (cons (path->string dir) locale))
  (define hit (hash-ref ui-catalog-memo k #f))
  (if (and hit (equal? (car hit) stamp))
      (cdr hit)
      (let ([body (ui-catalog-text (ui-catalog-doc dir locale))])
        (hash-set! ui-catalog-memo k (cons stamp body))
        body)))

;; The entity tag, in the one form a cache compares: a QUOTED STRONG validator,
;; which is what `If-None-Match` carries back and what `GET /api/repo-obj/:id/
;; content` already sends for a document digest. sha1 of the BODY, never of the
;; catalog files: an ETag identifies a representation, and two edits that cancel
;; out are the same representation even though the files moved.
(define (ui-catalog-etag body)
  (string-append "\"" (sha1 (open-input-string body)) "\""))
