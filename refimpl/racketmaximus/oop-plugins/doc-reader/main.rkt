#lang racket/base

;; oop-plugins/doc-reader/main.rkt — the worked example for LAY-6: an
;; out-of-process plugin that READS a document and WRITES a derived one.
;;
;; This is the shape an OCR or image-classification plugin takes. It has no
;; database handle and no platform imports; it declares the scopes it needs
;; (files:read, files:write) and asks the host for `repo.text` and `repo.put`.
;; The host runs each only if this plugin declared the scope AND the calling user
;; holds the matching permission.
;;
;; It branches on the one answer an OCR plugin exists for: a PDF with no text
;; layer comes back as text=null with reason="needs-ocr", which is an ANSWER
;; rather than an error, so a plugin can act on it without matching error strings.

(require json racket/string)

(define (emit obj) (write-json obj) (newline) (flush-output))

(define (next)
  (let loop ()
    (define l (read-line))
    (cond [(eof-object? l) eof]
          [(string=? (string-trim l) "") (loop)]
          [else (with-handlers ([exn:fail? (lambda (_) (loop))]) (string->jsexpr l))])))

;; ask the host for one capability and return its result hash, or #f with the error
(define (host-call! id cap args)
  (emit (hasheq 'type "host" 'id id 'cap cap 'args args))
  (define hr (next))
  (cond
    [(and (hash? hr) (equal? (hash-ref hr 'type #f) "host_result")) (values (hash-ref hr 'result (hasheq)) #f)]
    [(hash? hr) (values #f (format "~a" (hash-ref hr 'error "denied")))]
    [else (values #f "no answer from the host")]))

(define manifest
  (hasheq 'type "manifest" 'name "doc-reader" 'version "0.1.0"
          'scopes '("files:read" "files:write")
          'tools (list (hasheq 'name "read_document"
                               'description "Read a repository document's text and file it back as a plain-text document derived from the original. Reports a scanned PDF as needing OCR rather than as empty."
                               'permission "files:write"
                               'inputSchema
                               (hasheq 'type "object"
                                       'properties (hasheq 'object (hasheq 'type "string" 'description "the repository object id"))
                                       'required '("object"))))))

;; base64 without a platform import: this is a sandboxed process, so it brings
;; its own. Racket's net/base64 is in the standard distribution, not the host.
(require net/base64)
(define (b64 s) (bytes->string/utf-8 (base64-encode (string->bytes/utf-8 s) #"")))

(let loop ()
  (define m (next))
  (unless (eof-object? m)
    (when (hash? m)
      (case (hash-ref m 'type "")
        [("describe") (emit manifest)]
        [("call")
         (define obj (hash-ref (hash-ref m 'args (hasheq)) 'object ""))
         (define-values (got err) (host-call! 1 "repo.text" (hasheq 'object obj)))
         (define text
           (cond
             [err (format "Could not read the document: ~a" err)]
             [else
              (define t (hash-ref got 'text 'null))
              (define reason (hash-ref got 'reason 'null))
              (cond
                ;; the branch this example exists to show
                [(equal? reason "needs-ocr")
                 (format "~a has no text layer — it is a scan. An OCR plugin would take it from here."
                         (hash-ref got 'key "the document"))]
                [(not (string? t)) (format "No text could be read (~a)." reason)]
                [else
                 (define-values (put perr)
                   (host-call! 2 "repo.put"
                               (hasheq 'key (string-append (hash-ref got 'key "doc") ".read.txt")
                                       'content_type "text/plain"
                                       'bytes_b64 (b64 t)
                                       'derived_from obj)))
                 (if perr
                     (format "Read ~a characters but could not file them: ~a" (string-length t) perr)
                     (format "Filed ~a characters as ~a, derived from the original."
                             (string-length t) (hash-ref put 'key "?")))])]))
         (emit (hasheq 'type "result" 'id (hash-ref m 'id 1) 'text text))]
        [else (void)]))
    (loop)))
