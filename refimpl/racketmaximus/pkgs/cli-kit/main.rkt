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
;;
;; Tools that can be REFUSED as well as fail -- anything where "your input was
;; wrong" and "the tool is broken" are different answers -- use the exit
;; contract below: `refuse`, `cannot-run`, `misuse`.

(require json racket/port)

(provide emit fail run pretty-from-args? jsexpr->pretty-string
         EXIT-OK EXIT-CANNOT-RUN EXIT-REFUSED EXIT-MISUSE
         refuse cannot-run misuse)

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

(define (fail msg #:code [code EXIT-CANNOT-RUN])
  (eprintf "error: ~a\n" msg)
  (exit code))

;; ---- the exit contract -----------------------------------------------------
;; Four outcomes, because a caller that cannot tell them apart retries the one
;; it should escalate:
;;
;;   0   the tool ran            the result is on stdout
;;   2   the DOMAIN refused      an error object on stdout, always with reasons
;;   1   the tool COULD NOT run  stdout is EMPTY
;;   64  CLI misuse              text on stderr
;;
;; 1 and 2 are the distinction worth having: "your input was wrong" and "the
;; tool is broken" call for different responses -- fix the input versus page an
;; operator. And on 1 stdout stays empty on purpose: a run that did not happen
;; must not hand anyone a document.

(define EXIT-OK 0)
(define EXIT-CANNOT-RUN 1)
(define EXIT-REFUSED 2)
(define EXIT-MISUSE 64)

;; The domain refused the input. `codes` is never empty -- a refusal that says
;; nothing is a 1 wearing a 2's exit code, so an empty list is a contract
;; violation here rather than a silently vague answer.
(define (refuse reason
                #:tool [tool #f]
                #:codes [codes '()]
                #:schema [schema "cli-kit.error/v1"]
                #:pretty? [pretty? #f])
  (when (null? codes)
    (raise-arguments-error 'refuse
                           "a refusal must say why: #:codes cannot be empty"
                           "reason" reason))
  (emit (let* ([h (hasheq 'error schema 'reason reason 'reasonCodes codes)]
               [h (if tool (hash-set h 'tool tool) h)])
          h)
        #:pretty? pretty?)
  (exit EXIT-REFUSED))

;; The tool could not run. Nothing goes to stdout.
(define (cannot-run msg #:tool [tool #f])
  (eprintf "~a~a\n" (if tool (format "~a: " tool) "") msg)
  (exit EXIT-CANNOT-RUN))

;; The caller drove the CLI wrongly -- not a domain answer at all.
(define (misuse msg #:tool [tool #f])
  (eprintf "~a~a\n" (if tool (format "~a: " tool) "") msg)
  (exit EXIT-MISUSE))

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
