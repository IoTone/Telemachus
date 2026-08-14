#lang racket/base

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

(require racket/list
         racket/path
         racket/string
         racket/file
         cli-kit
         "../domain/i18n/lint.rkt"
         "../domain/i18n/catalog.rkt")

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
  (hash-ref opts 'locales (or (getenv "TELEMACHUS_LOCALES") "locales")))

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

(define (cmd-check surface opts)
  (when (null? surface) (usage))
  (define-values (base violations) (scan surface))
  (define required (let ([r (hash-ref opts 'required #f)]) (if r (string-split r ",") '())))
  (define locales (locale-report (locales-dir opts) base))
  (define required-broken
    (for/or ([lr (in-list locales)])
      (and (member (hash-ref lr 'locale) required)
           (or (pair? (hash-ref lr 'missing)) (pair? (hash-ref lr 'stale))))))
  (define blocking (or (pair? violations) (and required-broken #t)))
  (for ([v (in-list violations)])
    (eprintf "~a:~a:~a  unlocalized string literal ~s\n"
             (hash-ref v 'file) (hash-ref v 'line) (hash-ref v 'col) (hash-ref v 'text)))
  (emit (hasheq 'ok (not blocking)
                'violations violations
                'base_messages (hash-count (catalog-messages base))
                'required required
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
