#lang racket/base

;; The localization CI gate: is locales/en.json still the catalog the surfaces
;; define? `target-files` deliberately excludes en.json, so `locale-report` never
;; had a row for "en" and `--required en` could never fail — a forgotten
;; `extract` was invisible. Issue #43 added a route whose doc string reached
;; docs/reference/strings.json and never reached en.json, so the Localization
;; Manager imported a base one string short and reported Japanese as fully
;; translated while an English-only string shipped.

(require rackunit
         racket/file
         racket/runtime-path
         racket/list
         "../domain/i18n/catalog.rkt"
         "../domain/i18n/policy.rkt"
         db-kit/portable db-kit/migrate
         "db-fixture.rkt"
         "../domain/db/migrations.rkt"
         (file "../cli/telemachus-localize.rkt"))

(define (with-locales-dir proc)
  (define dir (make-temporary-file "tmx-loc-~a" 'directory))
  (dynamic-wind void (lambda () (proc dir)) (lambda () (delete-directory/files dir))))

(define (base-of . pairs) (build-en-catalog pairs))

(define (write-en! dir cat) (write-catalog (build-path dir "en.json") cat))

;; ---- the extract is current --------------------------------------------------
(with-locales-dir
 (lambda (dir)
   (define base (base-of (list "a.one" "One") (list "a.two" "Two")))
   (write-en! dir base)
   (define r (en-report dir base))
   (check-true (hash-ref r 'present))
   (check-equal? (hash-ref r 'missing) '())
   (check-equal? (hash-ref r 'changed) '())
   (check-false (en-stale? r) "a current extract is not stale")))

;; ---- a surface gained a string and nobody re-extracted (the #43 shape) -------
(with-locales-dir
 (lambda (dir)
   (write-en! dir (base-of (list "a.one" "One")))
   (define base (base-of (list "a.one" "One") (list "a.new" "Brand new")))
   (define r (en-report dir base))
   (check-equal? (hash-ref r 'missing) '("a.new"))
   (check-true (en-stale? r) "a string the surfaces define but en.json lacks is a stale extract")))

;; ---- the English text was edited and nobody re-extracted --------------------
(with-locales-dir
 (lambda (dir)
   (write-en! dir (base-of (list "a.one" "One")))
   (define base (base-of (list "a.one" "One, revised")))
   (define r (en-report dir base))
   (check-equal? (hash-ref r 'changed) '("a.one"))
   (check-true (en-stale? r) "an edited English string must re-extract")))

;; ---- an ORPHAN is reported but never blocking -------------------------------
;; An orphan only means something when the surface list is COMPLETE, and a caller
;; may legitimately gate a subset: nix/telemachus.nix checks two surfaces, which
;; would otherwise make every ui.* and doc.* string in en.json look orphaned.
(with-locales-dir
 (lambda (dir)
   (write-en! dir (base-of (list "a.one" "One") (list "a.gone" "Removed")))
   (define base (base-of (list "a.one" "One")))
   (define r (en-report dir base))
   (check-equal? (hash-ref r 'removed) '("a.gone"))
   (check-false (en-stale? r) "an orphan is advisory, so a partial surface list still passes")))

;; ---- no en.json at all is the loudest failure -------------------------------
(with-locales-dir
 (lambda (dir)
   (define r (en-report dir (base-of (list "a.one" "One"))))
   (check-false (hash-ref r 'present))
   (check-true (en-stale? r) "a missing source catalog cannot be current")))

;; ---- a key that appears TWICE in the file -----------------------------------
;; `read-json` keeps the last copy, so `diff` saw a single message and the gate
;; stayed green while locales/en.json carried two texts for `ui.troverlimit` —
;; the stale wording first and the current one second. Any reader that is not
;; this parser picks the other one.
(with-locales-dir
 (lambda (dir)
   (define f (build-path dir "en.json"))
   (display-to-file
    (string-append
     "{\n  \"meta\": {\"locale\": \"en\"},\n  \"messages\": {\n"
     "    \"a.one\": {\"text\": \"One\", \"hash\": \"x\"},\n"
     "    \"a.two\": {\"text\": \"Two\", \"hash\": \"y\"},\n"
     "    \"a.one\": {\"text\": \"One, again\", \"hash\": \"z\"}\n"
     "  }\n}\n")
    f #:exists 'truncate)
   (check-equal? (catalog-duplicate-keys f) '("a.one"))))

;; ---- the same LEAF NAME in different messages is not a duplicate ------------
;; Every message carries a `text` and a `hash` key. A scan that counted the leaf
;; name rather than the message id would fail every catalog ever written.
(with-locales-dir
 (lambda (dir)
   (define f (build-path dir "en.json"))
   (write-en! dir (base-of (list "a.one" "One") (list "a.two" "Two")))
   (check-equal? (catalog-duplicate-keys f) '())))

;; ---- a target catalog is checked too ----------------------------------------
(with-locales-dir
 (lambda (dir)
   (define f (build-path dir "ja.json"))
   (display-to-file
    (string-append
     "{\n  \"meta\": {\"locale\": \"ja\", \"fallback\": \"en\"},\n  \"messages\": {\n"
     "    \"a.one\": {\"text\": \"一\", \"hash\": \"x\"},\n"
     "    \"a.one\": {\"text\": \"壱\", \"hash\": \"x\"}\n"
     "  }\n}\n")
    f #:exists 'truncate)
   (check-equal? (catalog-duplicate-keys f) '("a.one"))))

;; ---- a locale is ADVERTISED only if it is translated ------------------------
;;
;; `available` was "whichever `<locale>.json` files exist", which is right about
;; what the build can OPEN and wrong about what it can OFFER: `nl` and `es-419`
;; ship 190 of 1,179 messages (16%), so the console offered Dutch and answered
;; five strings of every six in English. The switcher derives from `available`,
;; so a floor is the rule that makes those two questions different — a locale
;; below it keeps its file, keeps its rows in the manager and stops being offered.
(with-locales-dir
 (lambda (dir)
   (define base (build-en-catalog (for/list ([i (in-range 10)])
                                    (list (format "a.~a" i) (format "T~a" i)))))
   (write-en! dir base)
   ;; one locale at the floor (8 of 10) and one below it (7 of 10). A catalog
   ;; names only the strings it has, so the missing ones are missing rather than
   ;; blank — both count as uncovered in `coverage`, which is what makes this the
   ;; same number the report prints.
   (define (partial! loc n)
     (define msgs (catalog-messages base))
     (define kept
       (for/hash ([(k v) (in-hash msgs)] [i (in-naturals)] #:when (< i n)) (values k v)))
     (write-catalog (build-path dir (format "~a.json" loc)) (make-catalog loc "en" kept)))
   (partial! "atfloor" 8)
   (partial! "under" 7)
   (check-equal? LOCALE-COVERAGE-FLOOR 80)
   (check-equal? (locale-coverage dir "en") 100)
   (check-equal? (locale-coverage dir "atfloor") 80)
   (check-equal? (locale-coverage dir "under") 70)
   (check-true (advertised? dir "atfloor") "the floor is inclusive")
   (check-false (advertised? dir "under"))
   (check-equal? (sort (available-locales dir) string<?) '("atfloor" "en" "under"))
   (check-equal? (sort (advertised-locales dir) string<?) '("atfloor" "en"))
   ;; …and the POLICY the instance serves from uses the advertised set, so a
   ;; language too thin to answer in cannot be chosen as the default any more
   (define c (fresh-db #:migrate? #f)) (migrate! c all-migrations)
   (check-false (member "under" (hash-ref (i18n-policy c dir) 'available)))
   (check-exn exn:fail? (lambda () (i18n-policy-set! c dir (hasheq 'default "under"))))
   (check-equal? (hash-ref (i18n-policy-set! c dir (hasheq 'default "atfloor")) 'default) "atfloor")
   (close-db! c)))

;; ---- the catalogs this build actually ships --------------------------------
;;
;; Measured, not asserted from a comment: `ja` is complete and must stay
;; advertised, and `nl`/`es-419` are drafts the switcher must not offer. If a
;; translation is finished, this case fails and is updated deliberately — which
;; is the point of a floor that a report and a switcher both read.
(define-runtime-path locales-dir-path "../locales")
(test-case "the shipped catalogs: ja is offered, nl and es-419 are not"
  (define dir (path->string locales-dir-path))
  (check-true (advertised? dir "ja"))
  (check-equal? (locale-coverage dir "ja") 100)
  (check-false (advertised? dir "nl"))
  (check-false (advertised? dir "es-419"))
  (check-equal? (sort (advertised-locales dir) string<?) '("en" "ja")))
