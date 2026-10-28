#lang racket/base

;; #128 job 2: operator-facing variables are read through ONE accessor,
;; which tries TMACH_<name> and falls back to TELEMACHUS_<name>.
(require (only-in "../config.rkt" tmach-env))

;; cli/telemachus-localize.rkt — the localization CLI + CI gate.
;;
;;   telemachus-localize extract <surface…>        [--locales DIR]
;;   telemachus-localize sync-locale <loc> <surface…> [--locales DIR]
;;   telemachus-localize check   <surface…>        [--locales DIR] [--required a,b]
;;   telemachus-localize report  <surface…>        [--locales DIR]
;;
;; `check` exits non-zero on bare-literal violations (always) and on missing/stale
;; strings for any --required locale — for a pre-commit hook / CI step. Target
;; coverage is otherwise advisory (decision LOC-4).
;;
;; `--required en` means the SOURCE catalog: en.json must still be the catalog the
;; surfaces define, i.e. `extract` has been run since the last English edit. It is
;; not a target locale and never was — see `en-report`.

(require racket/list
         racket/path
         racket/string
         racket/file
         cli-kit
         "../domain/i18n/lint.rkt"
         "../domain/i18n/catalog.rkt")

(provide en-report en-stale?)

(define (usage)
  (eprintf "usage: telemachus-localize <extract|sync-locale|check|report> …\n")
  (exit 2))

(define (split-flags args)
  (let loop ([xs args] [pos '()] [opts (hasheq)])
    (cond
      [(null? xs) (values (reverse pos) opts)]
      [(and (string=? (car xs) "--locales") (pair? (cdr xs)))
       (loop (cddr xs) pos (hash-set opts 'locales (cadr xs)))]
      [(and (string=? (car xs) "--required") (pair? (cdr xs)))
       (loop (cddr xs) pos (hash-set opts 'required (cadr xs)))]
      [else (loop (cdr xs) (cons (car xs) pos) opts)])))

(define (locales-dir opts)
  (hash-ref opts 'locales (or (tmach-env "LOCALES") "locales")))

;; scan surface paths → (values en-base-catalog violations)
(define (scan surface)
  (define-values (tforms violations) (analyze-paths (map string->path surface)))
  (values (build-en-catalog (map (lambda (tf) (list (car tf) (cadr tf))) tforms))
          violations))

(define (target-files dir)
  (if (directory-exists? dir)
      (for/list ([f (in-directory dir)]
                 #:when (and (file-exists? f)
                             (path-has-extension? f #".json")
                             (not (equal? (path->string (file-name-from-path f)) "en.json"))))
        f)
      '()))

(define (locale-of path)
  (define n (path->string (file-name-from-path path)))
  (substring n 0 (- (string-length n) 5)))    ; strip ".json"

(define (locale-report dir base)
  (for/list ([f (in-list (sort (target-files dir) (lambda (a b) (string<? (path->string a) (path->string b)))))])
    (define target (read-catalog f))
    (define-values (missing stale unused) (diff base target))
    (define-values (covered total) (coverage base target))
    (hasheq 'locale (locale-of f)
            'covered covered 'total total
            'pct (if (zero? total) 100 (quotient (* 100 covered) total))
            'missing missing 'stale stale 'unused unused)))

;; ---- subcommands ------------------------------------------------------------
(define (cmd-extract surface opts)
  (when (null? surface) (usage))
  (define-values (base _v) (scan surface))
  (define dir (locales-dir opts))
  (make-directory* dir)
  (define en (build-path dir "en.json"))
  (write-catalog en base)
  (emit (hasheq 'wrote (path->string en) 'messages (hash-count (catalog-messages base))) #:pretty? #t))

(define (cmd-sync positionals opts)
  (when (< (length positionals) 2) (usage))
  (define loc (car positionals))
  (define surface (cdr positionals))
  (define-values (base _v) (scan surface))
  (define dir (locales-dir opts))
  (make-directory* dir)
  (define path (build-path dir (string-append loc ".json")))
  (define existing (and (catalog-exists? path) (read-catalog path)))
  (define synced (sync-target base loc existing))
  (write-catalog path synced)
  (define-values (covered total) (coverage base synced))
  (emit (hasheq 'wrote (path->string path) 'locale loc 'translated covered 'total total) #:pretty? #t))

(define (cmd-report surface opts)
  (when (null? surface) (usage))
  (define-values (base _v) (scan surface))
  (emit (hasheq 'base_messages (hash-count (catalog-messages base))
                'locales (locale-report (locales-dir opts) base))
        #:pretty? #t))

;; Is the en.json on disk still the catalog the surfaces define?
;;
;; `target-files` deliberately excludes en.json, so `locale-report` never had a row
;; for "en" and `--required en` could never fail — a forgotten `extract` was
;; invisible. That is not hypothetical: issue #43 added a route whose doc string
;; reached docs/reference/strings.json and never reached en.json, so the
;; Localization Manager imported a base that was one string short and reported a
;; locale as fully translated while a string it had never seen shipped in English.
;; `diff` against the surface-derived catalog is exactly the shape of a stale
;; extract: `missing` are strings the surfaces gained, `changed` are ones whose
;; English was edited, `removed` are ones no surface defines any more.
(define (en-report dir base)
  (define path (build-path dir "en.json"))
  (cond
    [(not (catalog-exists? path))
     (hasheq 'present #f 'missing '() 'changed '() 'removed '())]
    [else
     (define-values (missing changed removed) (diff base (read-catalog path)))
     (hasheq 'present #t 'missing missing 'changed changed 'removed removed)]))

;; `removed` is REPORTED but never blocking: an orphan only means something when
;; the surface list is complete, and a caller may legitimately check a subset —
;; nix/telemachus.nix gates two surfaces, which would make every ui.* and doc.*
;; string in en.json look orphaned (528 of them). `missing` and `changed` are the
;; two that mean the shipped English is absent or wrong, and they are sound under
;; any surface list.
(define (en-stale? r)
  (or (not (hash-ref r 'present))
      (pair? (hash-ref r 'missing))
      (pair? (hash-ref r 'changed))))

(define (cmd-check surface opts)
  (when (null? surface) (usage))
  (define-values (base violations) (scan surface))
  (define required (let ([r (hash-ref opts 'required #f)]) (if r (string-split r ",") '())))
  (define dir (locales-dir opts))
  (define locales (locale-report dir base))
  (define en (en-report dir base))
  (define required-broken
    (for/or ([lr (in-list locales)])
      (and (member (hash-ref lr 'locale) required)
           (or (pair? (hash-ref lr 'missing)) (pair? (hash-ref lr 'stale))))))
  ;; "en" names the SOURCE catalog rather than a target, so requiring it means
  ;; requiring the extract to be current.
  (define en-broken (and (member "en" required) (en-stale? en) #t))
  (define blocking (or (pair? violations) (and required-broken #t) en-broken))
  (for ([v (in-list violations)])
    (eprintf "~a:~a:~a  unlocalized string literal ~s\n"
             (hash-ref v 'file) (hash-ref v 'line) (hash-ref v 'col) (hash-ref v 'text)))
  (when en-broken
    (if (hash-ref en 'present)
        (begin
          (for ([id (in-list (hash-ref en 'missing))])
            (eprintf "en.json: MISSING ~a — the surfaces define it\n" id))
          (for ([id (in-list (hash-ref en 'changed))])
            (eprintf "en.json: STALE ~a — the English in the surface has changed\n" id))
          (void))
        (eprintf "en.json: not found in ~a\n" dir))
    (eprintf "run: telemachus-localize extract ~a\n" (string-join surface " ")))
  (for ([lr (in-list locales)])
    (when (and (member (hash-ref lr 'locale) required)
               (pair? (hash-ref lr 'stale)))
      (for ([id (in-list (hash-ref lr 'stale))])
        (eprintf "~a.json: STALE ~a — the English changed since this was translated\n"
                 (hash-ref lr 'locale) id))))
  (emit (hasheq 'ok (not blocking)
                'violations violations
                'base_messages (hash-count (catalog-messages base))
                'required required
                'en en
                'locales locales)
        #:pretty? #t)
  (exit (if blocking 1 0)))

;; ---- dispatch ---------------------------------------------------------------
(define (main)
  (define args (vector->list (current-command-line-arguments)))
  (when (null? args) (usage))
  (define-values (pos opts) (split-flags (cdr args)))
  (case (car args)
    [("extract")     (cmd-extract pos opts)]
    [("sync-locale") (cmd-sync pos opts)]
    [("report")      (cmd-report pos opts)]
    [("check")       (cmd-check pos opts)]
    [else (usage)]))

(module+ main
  (run "telemachus-localize" "0.1.0" main))
