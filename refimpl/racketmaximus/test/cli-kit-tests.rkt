#lang racket/base
;; cli-kit — the exit contract and the JSON emitters.
;;
;; Exits are intercepted with `exit-handler` rather than spawned as
;; subprocesses, so the suite stays in-process and fast.

;; rackunit also exports `fail`; cli-kit's is the one under test here.
(require (except-in rackunit fail) racket/port json cli-kit)

;; Run `thunk`, capturing its exit code, stdout and stderr.
(define (run-cli thunk)
  (define code 'no-exit)
  (define out (open-output-string))
  (define err (open-output-string))
  (parameterize ([exit-handler (lambda (c) (set! code c) (raise 'exited))]
                 [current-output-port out]
                 [current-error-port err])
    (with-handlers ([(lambda (e) (eq? e 'exited)) void]) (thunk)))
  (values code (get-output-string out) (get-output-string err)))

;; ---- the four exits --------------------------------------------------------
(check-equal? (list EXIT-OK EXIT-CANNOT-RUN EXIT-REFUSED EXIT-MISUSE) '(0 1 2 64))

(test-case "refuse: exit 2, an error object on stdout, reasons included"
  (define-values (code out err)
    (run-cli (lambda () (refuse "stdin is not valid JSON"
                                #:tool "t" #:codes '("invalid_json")))))
  (check-equal? code EXIT-REFUSED)
  (define j (string->jsexpr out))
  (check-equal? (hash-ref j 'reason) "stdin is not valid JSON")
  (check-equal? (hash-ref j 'reasonCodes) '("invalid_json"))
  (check-equal? (hash-ref j 'tool) "t")
  (check-equal? (hash-ref j 'error) "cli-kit.error/v1"))

(test-case "refuse: the caller may name its own error schema"
  (define-values (code out err)
    (run-cli (lambda () (refuse "no" #:codes '("x") #:schema "rcnt.tool-error/v1"))))
  (check-equal? (hash-ref (string->jsexpr out) 'error) "rcnt.tool-error/v1"))

(test-case "refuse: a refusal that says nothing is refused itself"
  (check-exn #rx"must say why"
             (lambda () (run-cli (lambda () (refuse "silent" #:codes '()))))))

(test-case "cannot-run: exit 1 and stdout stays EMPTY"
  (define-values (code out err)
    (run-cli (lambda () (cannot-run "the model host is unreachable" #:tool "t"))))
  (check-equal? code EXIT-CANNOT-RUN)
  (check-equal? out "" "a run that did not happen must not hand anyone a document")
  (check-regexp-match #rx"unreachable" err))

(test-case "misuse: exit 64, message on stderr, nothing on stdout"
  (define-values (code out err) (run-cli (lambda () (misuse "unknown option --wat"))))
  (check-equal? code EXIT-MISUSE)
  (check-equal? out "")
  (check-regexp-match #rx"--wat" err))

(test-case "fail keeps its old meaning: could-not-run"
  (define-values (code out err) (run-cli (lambda () (fail "boom"))))
  (check-equal? code EXIT-CANNOT-RUN))

;; ---- emitters --------------------------------------------------------------
(test-case "emit writes one compact JSON line when not pretty"
  (define-values (code out err)
    (run-cli (lambda () (emit (hasheq 'a 1)) (exit EXIT-OK))))
  (check-equal? code EXIT-OK)
  (check-equal? (string->jsexpr out) (hasheq 'a 1)))

(test-case "pretty output is still valid JSON"
  (define s (jsexpr->pretty-string (hasheq 'a (list 1 2) 'b (hasheq 'c "x"))))
  (check-regexp-match #rx"\n" s)
  (check-equal? (string->jsexpr s) (hasheq 'a (list 1 2) 'b (hasheq 'c "x"))))

(test-case "pretty-from-args? reads the flag"
  (check-true  (pretty-from-args? '("--pretty")))
  (check-false (pretty-from-args? '("--other"))))
