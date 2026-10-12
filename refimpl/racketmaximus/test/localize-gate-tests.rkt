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
         racket/list
         "../domain/i18n/catalog.rkt"
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
