#lang racket/base

;; test/docxpdf-tests.rkt — a filled DOCX, converted to PDF (#88 req 3).
;;
;; MOST OF THIS SUITE RUNS EVERYWHERE, and that is the point of the ordering in
;; `docx->pdf`: the input is checked before the binary is looked for, so the
;; external-reference refusal — the only sandbox this engine can have — is
;; exercised on a box where LibreOffice cannot be installed at all, which
;; includes this project's own development platform. Only the conversion itself
;; needs soffice, and that case says so when it skips.

(require rackunit racket/string racket/list racket/file racket/port racket/system
         file/zip file/unzip
         "../domain/repo/docxpdf.rkt")

;; ---- a real .docx, built here --------------------------------------------------
;; file/zip, as the DOCX renderer's own tests do: a fixture produced by Word
;; cannot be committed and a fixture produced by LibreOffice would be the tool
;; under test writing its own input.

(define DOCUMENT-XML
  (string-append
   "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
   "<w:document xmlns:w=\"http://schemas.openxmlformats.org/wordprocessingml/2006/main\">"
   "<w:body><w:p><w:r><w:t>Service report for {{customer}}</w:t></w:r></w:p>"
   "<w:p><w:r><w:t>Total: {{total}}</w:t></w:r></w:p></w:body></w:document>"))

(define CONTENT-TYPES
  (string-append
   "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
   "<Types xmlns=\"http://schemas.openxmlformats.org/package/2006/content-types\">"
   "<Default Extension=\"rels\" ContentType=\"application/vnd.openxmlformats-package.relationships+xml\"/>"
   "<Default Extension=\"xml\" ContentType=\"application/xml\"/>"
   "<Override PartName=\"/word/document.xml\" ContentType=\"application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml\"/>"
   "</Types>"))

(define ROOT-RELS
  (string-append
   "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
   "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
   "<Relationship Id=\"rId1\" Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument\" Target=\"word/document.xml\"/>"
   "</Relationships>"))

;; `#:external` adds the one thing this engine refuses: a relationship the
;; package declares as living somewhere else. It is how Word stores a LINKED
;; image, which is exactly the case that would reach the network mid-render.
(define (docx-bytes #:external [external #f])
  (define doc-rels
    (string-append
     "<?xml version=\"1.0\" encoding=\"UTF-8\" standalone=\"yes\"?>"
     "<Relationships xmlns=\"http://schemas.openxmlformats.org/package/2006/relationships\">"
     (if external
         (format (string-append "<Relationship Id=\"rId9\" "
                                "Type=\"http://schemas.openxmlformats.org/officeDocument/2006/relationships/image\" "
                                "Target=\"~a\" TargetMode=\"External\"/>")
                 external)
         "")
     "</Relationships>"))
  (define dir (make-temporary-file "docx-fix-~a" 'directory))
  (dynamic-wind
    void
    (lambda ()
      (define (put! rel content)
        (define p (build-path dir rel))
        (make-directory* (let-values ([(base _n _d) (split-path p)]) base))
        (call-with-output-file p (lambda (o) (write-string content o))))
      (put! "[Content_Types].xml" CONTENT-TYPES)
      (put! "_rels/.rels" ROOT-RELS)
      (put! "word/document.xml" DOCUMENT-XML)
      (put! "word/_rels/document.xml.rels" doc-rels)
      (define out (build-path dir "out.docx"))
      (parameterize ([current-directory dir])
        (apply zip out (for/list ([e (in-list (directory-list dir))]
                                  #:unless (equal? (path->string e) "out.docx"))
                         e)))
      (file->bytes out))
    (lambda () (delete-directory/files dir #:must-exist? #f))))

(define have? (and (soffice-path) #t))
(unless have?
  (printf "docxpdf-tests: SKIPPING the conversion case — no soffice on PATH. LibreOffice is deliberately absent from the image and is unsupported on this project's development platform; the case runs on Linux (CI's container leg does not install it either, so this is verified by hand on the test lab box).\n"))

;; ---- 1. the fixture is a real package ------------------------------------------
(test-case "the fixture is a zip carrying a word/document.xml"
  (define bs (docx-bytes))
  (check-true (> (bytes-length bs) 300))
  (define names
    (call-with-input-bytes bs (lambda (in) (map (lambda (e) (bytes->string/utf-8 e)) (zip-directory-entries (read-zip-directory in))))))
  (check-true (and (member "word/document.xml" names) #t))
  (check-true (and (member "word/_rels/document.xml.rels" names) #t)))

;; ---- 2. the only sandbox this engine can have ----------------------------------
(test-case "a template with no external reference reports none"
  (check-equal? (docx-external-refs (docx-bytes)) '()))

(test-case "a declared external relationship is found, by target"
  (check-equal? (docx-external-refs (docx-bytes #:external "https://cdn.example/logo.png"))
                '("https://cdn.example/logo.png")))

;; THE REFUSAL IS WHAT STANDS IN FOR `--allowed-protocols`. WeasyPrint takes a
;; flag that forbids a fetch; soffice has none and no argument will give it one,
;; so the constraint is applied to the INPUT. This case is the whole reason the
;; engine can be offered at all.
(test-case "a template that declares an external reference is refused, naming it"
  (check-exn #rx"external reference"
             (lambda () (docx->pdf (docx-bytes #:external "https://cdn.example/logo.png"))))
  (check-exn #rx"cdn.example"
             (lambda () (docx->pdf (docx-bytes #:external "https://cdn.example/logo.png"))))
  ;; …and it says what to do instead, because "refused" with no remedy is how a
  ;; caller concludes the feature is broken
  (check-exn #rx"Embed the image"
             (lambda () (docx->pdf (docx-bytes #:external "file:///etc/hosts")))))

(test-case "a local relationship is NOT external, and is not refused for it"
  ;; the ordinary embedded-image shape: a Target with no TargetMode
  (check-equal? (docx-external-refs (docx-bytes)) '()))

(test-case "something that is not a zip is a named error, not a crash"
  (check-exn #rx"not a [.]docx"
             (lambda () (docx-external-refs #"this is not a docx at all"))))

;; ---- 3. the engine's absence is an ANSWER --------------------------------------
;; It is off unless installed, so the message has to say where it is meant to
;; come from — the OCR plugin's rule, where "enabled with nothing on PATH" used
;; to be a silent failure.
(unless have?
  (test-case "with no LibreOffice the refusal names it and says where it belongs"
    (check-exn #rx"needs LibreOffice"
               (lambda () (docx->pdf (docx-bytes))))
    (check-exn #rx"extraPath"
               (lambda () (docx->pdf (docx-bytes))))))

;; ---- 4. the conversion itself (Linux, with soffice) ---------------------------
(when have?
  (test-case "a filled DOCX becomes a PDF"
    (define pdf (docx->pdf (docx-bytes)))
    (check-true (> (bytes-length pdf) 500))
    (check-equal? (subbytes pdf 0 5) #"%PDF-")
    ;; the document's own text survived the conversion — a converter that wrote a
    ;; blank page of the right size would pass every assertion above
    (define exe (find-executable-path "pdftotext"))
    (when exe
      (define dir (make-temporary-file "docx-t-~a" 'directory))
      (dynamic-wind
        void
        (lambda ()
          (define in (build-path dir "in.pdf"))
          (define out (build-path dir "out.txt"))
          (call-with-output-file in (lambda (o) (write-bytes pdf o)))
          (system*/exit-code exe (path->string in) (path->string out))
          (define text (if (file-exists? out) (string-join (string-split (file->string out)) " ") ""))
          (check-true (regexp-match? #rx"Service report" text)
                      "the template's text is in the PDF"))
        (lambda () (delete-directory/files dir #:must-exist? #f)))))

  ;; A PRIVATE PROFILE PER CALL is what makes this safe under any concurrency at
  ;; all: two conversions sharing one profile make the second report "another
  ;; instance is already running". Two in a row through the same code path is the
  ;; cheapest check that each call really gets its own.
  (test-case "two conversions in succession both produce a PDF"
    (check-equal? (subbytes (docx->pdf (docx-bytes)) 0 5) #"%PDF-")
    (check-equal? (subbytes (docx->pdf (docx-bytes)) 0 5) #"%PDF-")))
