#lang racket/base

;; domain/repo/extract.rkt — pull searchable text out of a document (slice 54).
;;
;; Dispatch is by content type, and the honest shape of this module is a table of
;; what we can and cannot read:
;;
;;   text/* json md csv     decode as UTF-8, lossily — a text file with a bad byte
;;                          still yields its other 99.9%
;;   xml svg html           decode, then STRIP TAGS: the words are searchable, the
;;                          markup is not, and a <script> body is exactly the text
;;                          nobody wants matching their search
;;   docx                   a zip with word/document.xml inside; Racket's file/unzip
;;                          opens it and tag-stripping does the rest. No dependency.
;;   pdf                    `pdftotext - -` (poppler), the one subprocess. When the
;;                          binary is absent the object is SKIPPED WITH A REASON,
;;                          never half-indexed — an operator can see what to install.
;;   everything else        'unsupported — images and archives have no text to lie
;;                          about
;;
;; Output is capped: this feeds a LIKE-based search index, not an archive. The cap
;; keeps a 400-page PDF from turning every search into a scan of megabytes.

(require racket/port racket/string racket/system racket/file
         file/unzip
         db-kit/portable
         ;; `current-plugin` is the loader's parameter; it lives in the scheduler
         ;; because job-kind ownership needed it first, and both registries read it.
         (only-in "../sched/scheduler.rkt" current-plugin))

(provide extract-text extractable? EXTRACT-CAP EXTRACT-REASONS
         strip-tags pdftotext-available?
         register-extractor! unregister-extractor! registered-extractors extractors-of-plugin
         repo-text-upsert! repo-text-delete! repo-text-for)

(define EXTRACT-CAP 200000)   ; characters, ~50 printed pages — plenty for search

;; The reasons extract-text may give. This is a CONTRACT, not a convenience enum:
;; `doc_text` branches on 'missing-tool and 'needs-ocr to produce named refusals,
;; and the indexer records any reason as processed-with-nothing so one bad file
;; cannot wedge a team's indexing. A registered extractor is held to the same four
;; — anything else becomes 'failed — because a plugin inventing a fifth would
;; reach doc_text as a refusal naming a symbol nothing can explain.
(define EXTRACT-REASONS '(unsupported missing-tool needs-ocr failed))

;; ---- classification ----------------------------------------------------------
(define TEXTUAL
  '("application/json" "application/x-yaml" "application/yaml"))
(define MARKUP
  '("application/xml" "text/xml" "image/svg+xml" "text/html" "application/xhtml+xml"))
(define DOCX
  "application/vnd.openxmlformats-officedocument.wordprocessingml.document")
(define PDF "application/pdf")

;; ---- the extractor registry (LAY-7) ---------------------------------------------
;; `kind-of` was a fixed cond, so a plugin could add a tool, a route, a workflow
;; and a job kind — but not a FORMAT. "Model-replaceable architecture" names PDF
;; extraction and image classification as exactly the parts a deployment expects
;; to swap, which is the one list this seam did not cover.
;;
;; A registered extractor is IN-PROCESS Racket with the same contract extract-text
;; has: (in content-type) -> (values text-or-#f reason-or-#f). Reaching a
;; non-Racket engine is the extractor's own business, and shelling out is the
;; established way here — the built-in PDF reader is a pipe to `pdftotext`, so a
;; plugin wrapping YomiToku or PaddleOCR is a few lines of Racket around a
;; subprocess. Shipping bytes TO an out-of-process plugin is the other seam
;; (LAY-6's repo.get), for a plugin that acts as a tool rather than as a reader.
;;
;; A registration REPLACES the built-in for that type — swapping the PDF reader is
;; the point. Two different plugins claiming one type is refused, the same call
;; the job-kind registry makes, and re-registering your own is fine because the
;; loader may run twice in one process.
(define *extractors* (make-hash))          ; content-type -> (cons owner-plugin-id proc)

(define (normalize-ct content-type)
  (string-downcase (string-trim (car (string-split (or content-type "") ";")))))

(define (register-extractor! content-type proc)
  (define ct (normalize-ct content-type))
  (define pid (current-plugin))
  (when (string=? ct "") (error 'register-extractor! "a content type is required"))
  (unless (procedure? proc) (error 'register-extractor! "~a: an extractor must be a procedure" ct))
  (define owner (let ([e (hash-ref *extractors* ct #f)]) (and e (car e))))
  (when (and owner (not (equal? owner pid)))
    (error 'register-extractor! "content type ~s is already claimed by plugin ~a" ct owner))
  (hash-set! *extractors* ct (cons pid proc)))

(define (unregister-extractor! content-type) (hash-remove! *extractors* (normalize-ct content-type)))

;; content-type -> owner plugin id (or #f for one registered outside a plugin)
(define (registered-extractors)
  (for/list ([ct (in-list (sort (hash-keys *extractors*) string<?))])
    (cons ct (car (hash-ref *extractors* ct)))))

(define (extractors-of-plugin id)
  (sort (for/list ([(ct e) (in-hash *extractors*)] #:when (equal? (car e) id)) ct) string<?))

(define (kind-of content-type)
  (define ct (string-downcase (car (string-split (or content-type "") ";"))))
  (cond
    [(member ct MARKUP) 'markup]
    [(string-prefix? ct "text/") 'text]
    [(member ct TEXTUAL) 'text]
    [(string=? ct DOCX) 'docx]
    [(string=? ct PDF) 'pdf]
    [else #f]))

(define (extractable? content-type)
  (or (hash-has-key? *extractors* (normalize-ct content-type))
      (and (kind-of content-type) #t)))

;; ---- the extractors ------------------------------------------------------------
(define (bytes->text/lossy bs)
  (bytes->string/utf-8 bs #\uFFFD))

;; Good enough for indexing, which is all this is: drop <...> runs, unescape the
;; five entities, collapse whitespace. NOT a parser and NOT a sanitizer — the
;; sanitizing decision (DOC-10) is that this text is only ever stored and matched,
;; never rendered.
(define (strip-tags s)
  (define no-blocks
    (regexp-replace* #px"(?is:<(script|style)[^>]*>.*?</\\1>)" s " "))
  (define no-tags (regexp-replace* #px"<[^>]*>" no-blocks " "))
  (define unescaped
    (regexp-replaces no-tags '((#rx"&lt;" "<") (#rx"&gt;" ">") (#rx"&quot;" "\"")
                               (#rx"&#39;" "'") (#rx"&apos;" "'") (#rx"&amp;" "\\&"))))
  (string-trim (regexp-replace* #px"\\s+" unescaped " ")))

(define (extract-docx in)
  ;; word/document.xml is the body; if the zip lacks it, this is not a docx
  (define text #f)
  (with-handlers ([exn:fail? (lambda (_) #f)])
    (unzip in
           (lambda (name dir? entry-in . _rest)
             (when (and (not dir?) (equal? name #"word/document.xml"))
               (set! text (bytes->text/lossy (port->bytes entry-in))))))
    (and text
         ;; Word puts every run in its own <w:t>; a paragraph boundary is </w:p>.
         ;; Turning those into spaces before the generic strip keeps words apart.
         (strip-tags (regexp-replace* #px"</w:p>" text " ")))))

(define (pdftotext-available?) (and (find-executable-path "pdftotext") #t))

(define (extract-pdf in)
  (define exe (find-executable-path "pdftotext"))
  (and exe
       (let ()
         ;; feed stdin, read stdout; "-" twice means exactly that
         (define-values (proc p-out p-in p-err)
           (subprocess #f #f #f exe "-q" "-" "-"))
         (define feeder (thread (lambda ()
                                  (with-handlers ([exn:fail? void])
                                    (copy-port in p-in))
                                  (close-output-port p-in))))
         (define text (port->string p-out))
         (close-input-port p-out) (close-input-port p-err)
         (subprocess-wait proc)
         (thread-wait feeder)
         (and (zero? (subprocess-status proc))
              (string-trim (regexp-replace* #px"\\s+" text " "))))))

;; port + content type -> (values text-or-#f reason)
;;   text     extraction worked (possibly empty for a text format — an empty file
;;            is still indexed, so the workflow will not retry it forever)
;;   #f 'unsupported   no extractor for this type; expected, not an error
;;   #f 'missing-tool  pdftotext is not installed; the reason an operator can fix
;;   #f 'needs-ocr     a PDF with no TEXT LAYER — a scan. See below.
;;   #f 'failed        the extractor raised or the subprocess died
(define (extract-text in content-type)
  (define (cap s) (if (> (string-length s) EXTRACT-CAP) (substring s 0 EXTRACT-CAP) s))
  (define registered (hash-ref *extractors* (normalize-ct content-type) #f))
  (cond
    [registered (extract-registered (cdr registered) in content-type cap)]
    [else (extract-built-in in content-type cap)]))

;; A plugin's extractor is held to the platform's contract, not its own: it is
;; wrapped so that raising, or answering with the wrong shape, is the SAME
;; `'failed` an in-tree extractor would produce. One plugin must not be able to
;; wedge a team's indexing — the rule the index workflow already lives by, where
;; an unreadable file is recorded as processed-with-nothing rather than raised.
;; The cap is the platform's too, so a plugin cannot put megabytes in the index.
(define (extract-registered proc in content-type cap)
  (with-handlers ([exn:fail? (lambda (_) (values #f 'failed))])
    (define-values (text reason) (proc in content-type))
    (cond
      [(string? text) (values (cap text) #f)]
      [(memq reason EXTRACT-REASONS) (values #f reason)]
      [else (values #f 'failed)])))

(define (extract-built-in in content-type cap)
  (case (kind-of content-type)
    [(text)   (values (cap (bytes->text/lossy (port->bytes in))) #f)]
    [(markup) (values (cap (strip-tags (bytes->text/lossy (port->bytes in)))) #f)]
    [(docx)   (let ([t (extract-docx in)])
                (if t (values (cap t) #f) (values #f 'failed)))]
    ;; A PDF that yields NO text has no text layer: it is a scan, or an image
    ;; wrapped in a page. Reporting that as a successful empty extraction made a
    ;; scan indistinguishable from a blank page — the row was written, the object
    ;; was never listed again, and the real failure surfaced much later and much
    ;; further away, as a schema refusal on an empty document that named nothing.
    ;; Scanned paperwork is the normal case for the documents this platform is
    ;; for, so the one thing the extractor must not do is call it success.
    [(pdf)    (cond
                [(not (pdftotext-available?)) (values #f 'missing-tool)]
                [else
                 (define t (extract-pdf in))
                 (cond
                   [(not t) (values #f 'failed)]
                   [(string=? (string-trim t) "") (values #f 'needs-ocr)]
                   [else (values (cap t) #f)])])]
    [else (values #f 'unsupported)]))

;; ---- the index rows -------------------------------------------------------------
(define (repo-text-upsert! conn object-id version-id content)
  (query-exec conn
    (string-append "INSERT INTO repo_text (object_id, version_id, content, extracted_at) "
                   "VALUES (?, ?, ?, CURRENT_TIMESTAMP) "
                   "ON CONFLICT(object_id) DO UPDATE SET "
                   "version_id = excluded.version_id, content = excluded.content, "
                   "extracted_at = CURRENT_TIMESTAMP")
    object-id version-id content))

(define (repo-text-delete! conn object-id)
  (query-exec conn "DELETE FROM repo_text WHERE object_id = ?" object-id))

(define (repo-text-for conn object-id)
  (query-maybe-value conn "SELECT content FROM repo_text WHERE object_id = ?" object-id))
