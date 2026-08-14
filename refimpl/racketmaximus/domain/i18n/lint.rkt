#lang racket/base

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

(provide analyze-file analyze-paths rkt-files-under)

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
(define (analyze-paths paths)
  (define files (append-map (lambda (p) (rkt-files-under p)) paths))
  (for/fold ([tf '()] [vs '()]) ([f (in-list files)])
    (define-values (t v) (analyze-file f))
    (values (append tf t) (append vs v))))
