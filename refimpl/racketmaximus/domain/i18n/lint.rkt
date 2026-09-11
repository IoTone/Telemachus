#lang racket/base
(require json)

;; domain/i18n/lint.rkt — reader-based extractor + bare-literal scanner.
;;
;; Convention (LOC-2/LOC-3): in a *surface* module, every user-facing string
;; literal must be wrapped by `(t "id" #:default "…" …)` or explicitly exempted
;; by `(no-i18n "…")`. Any other string literal is a violation. `extract` pulls
;; (id, default) pairs from `t` forms to build the English base catalog.
;;
;; A "surface" file is one the CLI is pointed at — enforcement is opt-in by path,
;; so ordinary modules full of SQL/keys/format specs are never scanned.

(require racket/list
         racket/path)

(provide analyze-file analyze-json-file analyze-paths rkt-files-under)

;; ---- JSON surfaces ------------------------------------------------------------
;; A flat {"id": "English text"} object. This is how a frontend that is not
;; Racket — the console — contributes its English to the SAME base catalog the
;; Racket surfaces do, so one `extract` produces one en.json and one Manager
;; reviews one catalog. The console's ids carry a `ui.` prefix, which is what
;; makes them a namespace in the coverage report.
;;
;; It yields (id default line) triples and NO violations: JSON has no code in it
;; to scan for bare literals. Bare-literal detection for JavaScript is a separate
;; extractor, not this one.
(define (analyze-json-file path)
  (define j (call-with-input-file path read-json))
  (unless (hash? j)
    (error 'analyze-json-file "~a: expected a JSON object of id → text" path))
  (values (for/list ([(k v) (in-hash j)] #:when (string? v))
            (list (symbol->string k) v 0))
          '()))

;; (values t-forms violations)
;;   t-forms    : (listof (list id default line))
;;   violations : (listof (hash 'file 'line 'col 'text))
(define (analyze-file path)
  (define t-forms '())
  (define violations '())
  (define pstr (if (path? path) (path->string path) path))

  (define (record-violation! stx s)
    (set! violations (cons (hasheq 'file pstr
                                   'line (or (syntax-line stx) 0)
                                   'col  (or (syntax-column stx) 0)
                                   'text s)
                           violations)))
  (define (capture-t! lst)
    (define args (cdr lst))
    (define id (for/or ([a (in-list args)]) (let ([e (syntax-e a)]) (and (string? e) e))))
    (define default
      (let loop ([xs args])
        (cond [(or (null? xs) (null? (cdr xs))) #f]
              [(eq? (syntax-e (car xs)) '#:default)
               (let ([e (syntax-e (cadr xs))]) (and (string? e) e))]
              [else (loop (cdr xs))])))
    (when id (set! t-forms (cons (list id (or default "") (or (syntax-line (car lst)) 0)) t-forms))))

  ;; module paths (require/provide) are not user-facing text — don't scan them
  (define (walk stx)
    (define lst (syntax->list stx))
    (when lst
      (define op (and (pair? lst) (let ([o (syntax-e (car lst))]) (and (symbol? o) o))))
      (unless (memq op '(require provide #%require #%provide))
        (when (eq? op 't) (capture-t! lst))
        (define exempt? (and (memq op '(t no-i18n)) #t))
        (for ([child (in-list lst)])
          (define ce (syntax-e child))
          (cond
            [(string? ce) (unless exempt? (record-violation! child ce))]
            [(syntax->list child) (walk child)]
            [else (void)])))))

  ;; read the file as a module (handles the #lang line); one read yields the
  ;; whole (module …) form, which walk recurses into.
  (call-with-input-file path
    (lambda (in)
      (port-count-lines! in)
      (parameterize ([read-accept-reader #t] [read-accept-lang #t])
        (let loop ()
          (define stx (read-syntax path in))
          (unless (eof-object? stx) (walk stx) (loop))))))
  (values (reverse t-forms) (reverse violations)))

;; every *.rkt under a file-or-directory path
(define (rkt-files-under p)
  (cond
    [(directory-exists? p)
     (for/list ([f (in-directory p)]
                #:when (and (file-exists? f) (path-has-extension? f #".rkt")))
       f)]
    [(file-exists? p) (list (if (path? p) p (string->path p)))]
    [else '()]))

;; aggregate analysis over many paths → (values t-forms violations)
(define (json-surface? p)
  (define pp (if (path? p) p (string->path p)))
  (and (file-exists? pp) (path-has-extension? pp #".json")))

(define (analyze-paths paths)
  (define jsons (filter json-surface? paths))
  (define files (append-map (lambda (p) (rkt-files-under p)) (filter (lambda (p) (not (json-surface? p))) paths)))
  (for/fold ([tf '()] [vs '()])
            ([f (in-list (append (map (lambda (p) (cons 'json p)) jsons)
                                 (map (lambda (p) (cons 'rkt p)) files)))])
    (define-values (t v)
      (if (eq? (car f) 'json) (analyze-json-file (cdr f)) (analyze-file (cdr f))))
    (values (append tf t) (append vs v))))
