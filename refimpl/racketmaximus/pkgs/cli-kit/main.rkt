#lang racket/base

;; cli-kit — generic scaffolding for JSON-emitting CLIs.
;;
;; App-agnostic on purpose: nothing here knows about the consuming app, so this
;; package can be spun out and published unchanged. App-specific config (repo
;; paths, version string) lives in the consuming app, which passes the version
;; into `run`.
;;
;;   (require cli-kit)
;;   (define (go) (emit (hasheq 'ok #t) #:pretty? (pretty-from-args? (argv))))
;;   (module+ main (run "my-tool" "1.0.0" go))

(require json racket/port)

(provide emit fail run pretty-from-args? jsexpr->pretty-string)

;; ---- pretty JSON (write-json has no indent option) -------------------------
(define (write-json-pretty x out ind)
  (cond
    [(and (hash? x) (positive? (hash-count x)))
     (write-string "{\n" out)
     (define ind2 (+ ind 2))
     (let loop ([ps (hash->list x)])
       (define p (car ps))
       (write-string (make-string ind2 #\space) out)
       (write-json (symbol->string (car p)) out)
       (write-string ": " out)
       (write-json-pretty (cdr p) out ind2)
       (cond [(null? (cdr ps)) (write-string "\n" out)]
             [else (write-string ",\n" out) (loop (cdr ps))]))
     (write-string (make-string ind #\space) out)
     (write-string "}" out)]
    [(and (list? x) (pair? x))
     (write-string "[\n" out)
     (define ind2 (+ ind 2))
     (let loop ([xs x])
       (write-string (make-string ind2 #\space) out)
       (write-json-pretty (car xs) out ind2)
       (cond [(null? (cdr xs)) (write-string "\n" out)]
             [else (write-string ",\n" out) (loop (cdr xs))]))
     (write-string (make-string ind #\space) out)
     (write-string "]" out)]
    [else (write-json x out)]))

(define (jsexpr->pretty-string x)
  (define o (open-output-string))
  (write-json-pretty x o 0)
  (get-output-string o))

;; ---- output / errors -------------------------------------------------------
(define (emit obj #:pretty? [pretty? #f])
  (define out (current-output-port))
  (if (or pretty? (terminal-port? out))
      (write-json-pretty obj out 0)
      (write-json obj out))
  (newline out))

(define (fail msg #:code [code 1])
  (eprintf "error: ~a\n" msg)
  (exit code))

;; ---- arg helpers + run harness ---------------------------------------------
(define (pretty-from-args? args)
  (and (member "--pretty" args) #t))

;; Intercept --version/-V; map Ctrl-C to 130; turn uncaught errors into a
;; friendly stderr line + exit 1. `version` is supplied by the app.
(define (run prog version thunk)
  (define args (vector->list (current-command-line-arguments)))
  (when (or (member "--version" args) (member "-V" args))
    (printf "~a ~a\n" prog version)
    (exit 0))
  (with-handlers ([exn:break? (lambda (_) (eprintf "interrupted\n") (exit 130))]
                  [exn:fail?  (lambda (e) (fail (exn-message e)))])
    (thunk)
    (exit 0)))
