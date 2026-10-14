#lang racket/base

;; test/extractor-registry-tests.rkt — LAY-7: a plugin can claim a FORMAT.
;;
;; `kind-of` was a fixed cond over text / markup / docx / pdf, so a plugin could
;; add a tool, a route, a workflow and a job kind but not a reader. The RFE's
;; "model-replaceable architecture" names PDF extraction as the thing a deployment
;; expects to swap, which is exactly what the seam did not cover.
;;
;; What has to hold:
;;   1. a registered type is readable, and extractable? agrees
;;   2. a registration REPLACES a built-in — that is how OCR takes over PDFs
;;   3. two plugins cannot claim one type; re-registering your own is fine
;;   4. a plugin that raises, or answers wrongly, is 'failed — never an exception
;;   5. the reason vocabulary stays closed, and the cap stays the platform's
;;
;;   raco test test/extractor-registry-tests.rkt

(require rackunit racket/string racket/port racket/runtime-path
         (only-in "../domain/sched/scheduler.rkt" current-plugin)
         "../domain/repo/extract.rkt")

(define-runtime-path example-plugin "../plugins/example-tools/main.rkt")

(define (read-as s ct) (let-values ([(t r) (extract-text (open-input-string s) ct)]) (cons t r)))

;; ---- 1. a format the platform cannot read -------------------------------------
(test-case "a plugin can claim a content type the platform has no reader for"
  (check-false (extractable? "application/x-demo"))
  (check-equal? (read-as "anything" "application/x-demo") (cons #f 'unsupported))
  (parameterize ([current-plugin "demo"])
    (register-extractor! "application/x-demo"
                         (lambda (in ct) (values (string-upcase (port->string in)) #f))))
  (check-true (extractable? "application/x-demo"))
  (check-equal? (read-as "levee 7" "application/x-demo") (cons "LEVEE 7" #f))
  (check-equal? (extractors-of-plugin "demo") '("application/x-demo"))
  (unregister-extractor! "application/x-demo"))

;; ---- 2. replacing a built-in ---------------------------------------------------
(test-case "a registration REPLACES the built-in reader for that type"
  ;; this is the whole point: a local OCR engine takes over application/pdf
  (check-equal? (read-as "plain words" "text/plain") (cons "plain words" #f))
  (parameterize ([current-plugin "ocr"])
    (register-extractor! "text/plain" (lambda (in ct) (values "read by the plugin" #f))))
  (check-equal? (read-as "plain words" "text/plain") (cons "read by the plugin" #f))
  (unregister-extractor! "text/plain")
  (check-equal? (read-as "plain words" "text/plain") (cons "plain words" #f)
                "and the built-in is back when the plugin goes"))

(test-case "the content type is matched without its parameters or case"
  (parameterize ([current-plugin "demo"])
    (register-extractor! "Application/X-Demo" (lambda (in ct) (values "hit" #f))))
  (check-equal? (read-as "x" "application/x-demo; charset=utf-8") (cons "hit" #f))
  (unregister-extractor! "application/x-demo"))

;; ---- 3. ownership ---------------------------------------------------------------
(test-case "two plugins cannot claim one type; re-registering your own is fine"
  (parameterize ([current-plugin "first"])
    (register-extractor! "application/x-contested" (lambda (in ct) (values "first" #f))))
  (check-exn #rx"already claimed by plugin first"
             (lambda () (parameterize ([current-plugin "second"])
                          (register-extractor! "application/x-contested" (lambda (in ct) (values "second" #f))))))
  ;; the loader may run twice in one process — a reload must not fail the plugin
  (check-not-exn (lambda () (parameterize ([current-plugin "first"])
                              (register-extractor! "application/x-contested"
                                                   (lambda (in ct) (values "first again" #f))))))
  (check-equal? (read-as "x" "application/x-contested") (cons "first again" #f))
  (unregister-extractor! "application/x-contested"))

;; ---- 4. a bad plugin cannot wedge indexing --------------------------------------
(test-case "an extractor that raises is 'failed, not an exception"
  ;; the indexer records any reason as processed-with-nothing, so one bad file
  ;; cannot wedge a team's indexing forever — a bad PLUGIN must not either
  (parameterize ([current-plugin "bad"])
    (register-extractor! "application/x-bad" (lambda (in ct) (error "boom"))))
  (check-equal? (read-as "x" "application/x-bad") (cons #f 'failed))
  (unregister-extractor! "application/x-bad"))

(test-case "an extractor that answers with the wrong shape is 'failed"
  (parameterize ([current-plugin "bad"])
    (register-extractor! "application/x-wrong" (lambda (in ct) 42)))       ; not two values
  (check-equal? (read-as "x" "application/x-wrong") (cons #f 'failed))
  (unregister-extractor! "application/x-wrong"))

;; ---- 5. the contract stays the platform's ----------------------------------------
(test-case "the reason vocabulary is closed — a plugin cannot invent a fifth"
  ;; doc_text branches on 'missing-tool and 'needs-ocr to produce named refusals;
  ;; a plugin returning 'banana would reach it as a refusal naming nothing
  (check-equal? EXTRACT-REASONS '(unsupported missing-tool needs-ocr failed))
  (parameterize ([current-plugin "odd"])
    (register-extractor! "application/x-odd" (lambda (in ct) (values #f 'banana))))
  (check-equal? (read-as "x" "application/x-odd") (cons #f 'failed))
  ;; ...but a reason that IS in the vocabulary passes through intact
  (unregister-extractor! "application/x-odd")
  (parameterize ([current-plugin "odd"])
    (register-extractor! "application/x-odd" (lambda (in ct) (values #f 'needs-ocr))))
  (check-equal? (read-as "x" "application/x-odd") (cons #f 'needs-ocr)
                "a format plugin can report a scan the same way the PDF reader does")
  (unregister-extractor! "application/x-odd"))

(test-case "the cap is the platform's, not the plugin's"
  (parameterize ([current-plugin "big"])
    (register-extractor! "application/x-big" (lambda (in ct) (values (make-string (* 3 EXTRACT-CAP) #\x) #f))))
  (check-equal? (string-length (car (read-as "x" "application/x-big"))) EXTRACT-CAP)
  (unregister-extractor! "application/x-big"))

;; ---- the shipped example ----------------------------------------------------------
(test-case "the example plugin's RTF reader works through the registry"
  (parameterize ([current-plugin "example-tools"])
    ((dynamic-require example-plugin 'init!)))
  (check-true (extractable? "application/rtf"))
  (define got (read-as "{\\rtf1\\ansi Levee 7 \\b inspected\\b0 today.}" "application/rtf"))
  (check-equal? (car got) "Levee 7 inspected today."
                "a control word becomes a separator, so the words stay searchable")
  (check-equal? (cdr (read-as "not rtf" "application/rtf")) 'failed)
  (unregister-extractor! "application/rtf"))
