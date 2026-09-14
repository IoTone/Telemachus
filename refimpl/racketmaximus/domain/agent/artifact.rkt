#lang racket/base

;; domain/agent/artifact.rkt — artifact-shaped tool results (slice 64).
;;
;; A tool handler returns a string or a jsexpr. Both surfaces that consume a
;; result had a lossy corner: the agent transcript needs TEXT, so a structured
;; result was stringified whole (a 200 KB JSON form dumped into the model's
;; context), and the console printed the same string. An ARTIFACT is a result
;; that names a thing rather than carrying it:
;;
;;   { "artifact": { "kind":   "document" | "table" | "text" | "link" | "image",
;;                   "title":  "inbox/acme.pdf.form.docx",
;;                   "summary": "the filled purchase-approval form",
;;                   "content_type": "application/…", "object_id": "…",
;;                   "version_id": "…", "url": "…" },
;;     …any other keys the tool wants a workflow step to see… }
;;
;; The three surfaces then agree by construction:
;;   - the MODEL gets one line of text (artifact->text): title, kind, where it is
;;   - the CONSOLE gets the hash on the tool_result event and renders a card that
;;     opens the document or follows the link
;;   - a WORKFLOW step keeps the whole value, so `(out step result artifact object_id)`
;;     binds as before
;; `artifact` builds one; `artifact?` recognizes one wherever it lands.

(require racket/string)

(provide artifact artifact? artifact-of artifact->text ARTIFACT-KINDS)

(define ARTIFACT-KINDS '("document" "table" "text" "link" "image"))

(define (artifact #:kind kind #:title title
                  #:summary [summary ""] #:content-type [ct #f]
                  #:object-id [oid #f] #:version-id [vid #f] #:url [url #f]
                  #:extra [extra (hasheq)])
  (unless (member kind ARTIFACT-KINDS)
    (error 'artifact "kind must be one of ~a, got ~s" (string-join ARTIFACT-KINDS ", ") kind))
  (define a
    (for/fold ([h (hasheq 'kind kind 'title title 'summary summary)])
              ([kv (in-list (list (cons 'content_type ct) (cons 'object_id oid) (cons 'version_id vid) (cons 'url url)))]
               #:when (cdr kv))
      (hash-set h (car kv) (cdr kv))))
  (hash-set extra 'artifact a))

(define (artifact-of v)
  (and (hash? v)
       (let ([a (hash-ref v 'artifact #f)])
         (and (hash? a) (string? (hash-ref a 'kind #f)) (string? (hash-ref a 'title #f)) a))))

(define (artifact? v) (and (artifact-of v) #t))

;; the one line a model sees instead of the payload
(define (artifact->text v)
  (define a (artifact-of v))
  (string-append
   "[" (hash-ref a 'kind) "] " (hash-ref a 'title)
   (let ([s (hash-ref a 'summary "")]) (if (string=? s "") "" (string-append " — " s)))
   (let ([ct (hash-ref a 'content_type #f)]) (if ct (string-append " (" ct ")") ""))
   (let ([o (hash-ref a 'object_id #f)]) (if o (string-append " object_id=" o) ""))
   (let ([u (hash-ref a 'url #f)]) (if u (string-append " url=" u) ""))))
