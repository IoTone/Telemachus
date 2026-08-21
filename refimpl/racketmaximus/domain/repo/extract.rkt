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
         db-kit/portable)

(provide extract-text extractable? EXTRACT-CAP
         strip-tags pdftotext-available?
         repo-text-upsert! repo-text-delete! repo-text-for)

(define EXTRACT-CAP 200000)   ; characters, ~50 printed pages — plenty for search

;; ---- classification ----------------------------------------------------------
(define TEXTUAL
  '("application/json" "application/x-yaml" "application/yaml"))
(define MARKUP
  '("application/xml" "text/xml" "image/svg+xml" "text/html" "application/xhtml+xml"))
(define DOCX
  "application/vnd.openxmlformats-officedocument.wordprocessingml.document")
(define PDF "application/pdf")

(define (kind-of content-type)
  (define ct (string-downcase (car (string-split (or content-type "") ";"))))
  (cond
    [(member ct MARKUP) 'markup]
    [(string-prefix? ct "text/") 'text]
    [(member ct TEXTUAL) 'text]
    [(string=? ct DOCX) 'docx]
    [(string=? ct PDF) 'pdf]
    [else #f]))

(define (extractable? content-type) (and (kind-of content-type) #t))

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
;;   text     extraction worked (possibly empty — an empty PDF is still indexed,
;;            so the workflow will not retry it forever)
;;   #f 'unsupported   no extractor for this type; expected, not an error
;;   #f 'missing-tool  pdftotext is not installed; the reason an operator can fix
;;   #f 'failed        the extractor raised or the subprocess died
(define (extract-text in content-type)
  (define (cap s) (if (> (string-length s) EXTRACT-CAP) (substring s 0 EXTRACT-CAP) s))
  (case (kind-of content-type)
    [(text)   (values (cap (bytes->text/lossy (port->bytes in))) #f)]
    [(markup) (values (cap (strip-tags (bytes->text/lossy (port->bytes in)))) #f)]
    [(docx)   (let ([t (extract-docx in)])
                (if t (values (cap t) #f) (values #f 'failed)))]
    [(pdf)    (cond
                [(not (pdftotext-available?)) (values #f 'missing-tool)]
                [else (let ([t (extract-pdf in)])
                        (if t (values (cap t) #f) (values #f 'failed)))])]
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
