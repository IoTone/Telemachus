#lang racket/base

;; test/artifact-tests.rkt — slice 64: artifact-shaped tool results.
;;   raco test test/artifact-tests.rkt
;; The three surfaces must agree: the model gets one line, the console gets the
;; hash, a workflow step keeps the value.

(require rackunit racket/string json
         "../domain/agent/artifact.rkt")

(define a (artifact #:kind "document" #:title "inbox/acme.pdf.form.docx" #:summary "the filled form"
                    #:content-type "application/vnd.openxmlformats-officedocument.wordprocessingml.document"
                    #:object-id "obj-1" #:version-id "ver-1"
                    #:extra (hasheq 'object_id "obj-1" 'key "inbox/acme.pdf.form.docx")))
(check-true (artifact? a))
(check-equal? (hash-ref a 'object_id) "obj-1" "extra keys ride beside the artifact for a workflow binding")
(check-equal? (hash-ref (artifact-of a) 'kind) "document")
(check-equal? (artifact->text a)
              "[document] inbox/acme.pdf.form.docx — the filled form (application/vnd.openxmlformats-officedocument.wordprocessingml.document) object_id=obj-1")
(check-false (artifact? "just text"))
(check-false (artifact? (hasheq 'result 1)))
(check-false (artifact? (hasheq 'artifact "not a hash")))
(check-false (artifact? (hasheq 'artifact (hasheq 'kind "document"))) "a title is required")
(check-exn #rx"kind must be one of" (lambda () (artifact #:kind "blob" #:title "x")))
(let ([l (artifact #:kind "link" #:title "Dashboard" #:url "https://example.test/d")])
  (check-equal? (artifact->text l) "[link] Dashboard url=https://example.test/d")
  (check-false (hash-has-key? (artifact-of l) 'object_id) "absent fields are absent, not null"))
;; it survives the JSON round trip a workflow step stores it through
(let ([back (string->jsexpr (jsexpr->string a))])
  (check-true (artifact? back))
  (check-equal? (artifact->text back) (artifact->text a)))
