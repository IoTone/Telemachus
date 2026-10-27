#lang racket/base

;; domain/repo/docxpdf.rkt — a filled DOCX, converted to PDF (issue #88
;; requirement 3). PURE OF THE REPOSITORY, like htmlpdf.rkt and pdfform.rkt
;; beside it: bytes in, bytes out, so the whole surface is testable with a zip
;; built in the test and `can?` stays in doc-tools.rkt.
;;
;; `doc_render` has filled DOCX templates since slice 59 and has REFUSED to turn
;; one into a PDF ever since, on the grounds that LibreOffice is not a dependency
;; this platform takes on. That is still the default. What changes here is that
;; an integrator who needs it can have it: `engine: "libreoffice"` converts the
;; filled document with `soffice --headless --convert-to pdf`, and the binary is
;; found at CALL time, so a box without it behaves exactly as before.
;;
;; THE SANDBOX IS NOT A FLAG HERE, AND THAT IS THE HONEST DIFFERENCE FROM THE
;; HTML ENGINE. WeasyPrint takes `--allowed-protocols data` and refuses a `file:`
;; or `http:` URL by name; soffice has no equivalent, and no amount of
;; command-line argument will give it one. So the constraint is applied to the
;; INPUT instead: a template that DECLARES an external relationship — which is
;; how Word stores a linked image or an OLE object — is refused by name before
;; anything is converted. That is the shape of the guarantee the HTML engine gets
;; from its own flag, achieved the only way available here.
;;
;; What it is NOT is a proof. A field code (`INCLUDEPICTURE`), or a reference
;; this check does not know about, is not covered; headless soffice does not
;; update document links on load, but that is the engine's behaviour and not
;; something this platform enforces. Which is the whole reason the engine is
;; opt-in, off by default, and absent from the shipped image.

(provide soffice-path DOCX-PDF-SECONDS
         docx-external-refs docx->pdf)

(require racket/string racket/list racket/file racket/port
         file/unzip
         (only-in "pdfform.rkt" run-bounded))

;; A conversion is a whole office suite starting up. Measured at a few seconds
;; for a small document on a warm store; the bound is for the one that never
;; finishes, which is the case a request thread must not wait on.
(define DOCX-PDF-SECONDS 180)

(define (soffice-path)
  (or (find-executable-path "soffice") (find-executable-path "libreoffice")))

;; bytes -> (listof string), the Targets of every relationship a part declares
;; as EXTERNAL. Empty is the ordinary case: a template whose images are embedded.
;;
;; Read off the `.rels` parts rather than from a full XML parse, and matched by
;; looking for `TargetMode="External"` ANYWHERE in a relationship element — so
;; the check FAILS CLOSED. A shape this regexp does not understand is treated as
;; external and refused, which is the safe direction; the opposite reading would
;; convert a template whose links nobody had looked at.
(define (docx-external-refs bs #:who [who 'doc_render])
  (define dir (make-temporary-file "docx-rels-~a" 'directory))
  (dynamic-wind
    void
    (lambda ()
      (with-handlers ([exn:fail? (lambda (e)
                                   (error who "the template is not a .docx (not a zip: ~a)" (exn-message e)))])
        (call-with-input-bytes bs (lambda (in) (unzip in (make-filesystem-entry-reader #:dest dir)))))
      (define rels (find-files (lambda (p) (regexp-match? #rx"[.]rels$" (path->string p))) dir))
      (remove-duplicates
       (for*/list ([f (in-list rels)]
                   [el (in-list (regexp-match* #rx"<Relationship[^>]*>" (file->string f #:mode 'text)))]
                   #:when (regexp-match? #rx"TargetMode=\"External\"" el))
         (let ([m (regexp-match #rx"Target=\"([^\"]*)\"" el)])
           (if m (cadr m) "(an unnamed target)")))))
    (lambda () (delete-directory/files dir #:must-exist? #f))))

;; bytes -> bytes
(define (docx->pdf bs #:who [who 'doc_render])
  ;; THE INPUT IS CHECKED BEFORE THE BINARY IS LOOKED FOR, deliberately: a
  ;; template that will not be converted whatever is installed should say so on
  ;; every box, and that also makes the refusal testable where LibreOffice
  ;; cannot be — which is this project's own development platform.
  (define external (docx-external-refs bs #:who who))
  (unless (null? external)
    (error who "this template declares ~a external reference~a and will not be converted — a linked image or object would be fetched while the document is rendered, and unlike the HTML engine this one has no flag that can forbid it. Embed the image in the template instead. (~a)"
           (length external) (if (= 1 (length external)) "" "s")
           (string-join (map (lambda (t) (format "~s" t)) external) ", ")))
  (define exe (or (soffice-path)
                  (error who "DOCX to PDF needs LibreOffice (`soffice`) on the server's PATH — it is deliberately NOT in the shipped container image; add it with the image's extraPath, as the OCR engine is added")))
  (define dir (make-temporary-file "docx-pdf-~a" 'directory))
  (dynamic-wind
    void
    (lambda ()
      (define in (build-path dir "form.docx"))
      (define out (build-path dir "form.pdf"))
      (define profile (build-path dir "profile"))
      (call-with-output-file in (lambda (o) (write-bytes bs o)))
      ;; A PRIVATE PROFILE PER CALL, and it is not optional for two independent
      ;; reasons. The container's HOME is /data, the one declared volume, and
      ;; under `--read-only` there is no writable home at all — soffice wants
      ;; one. And two conversions sharing a profile collide: the second finds
      ;; "another instance is already running", which is the classic way this
      ;; tool fails under any concurrency at all.
      (define-values (code log)
        (run-bounded exe (list (string-append "-env:UserInstallation=file://" (path->string profile))
                               "--headless" "--invisible" "--norestore"
                               "--nolockcheck" "--nodefault" "--nologo"
                               "--convert-to" "pdf"
                               "--outdir" (path->string dir)
                               (path->string in))
                     #:seconds DOCX-PDF-SECONDS))
      (when (eq? code 'timeout)
        (error who "converting this document took longer than ~a seconds and was stopped" DOCX-PDF-SECONDS))
      ;; THE EXIT CODE IS NOT THE VERDICT HERE EITHER, and for a different
      ;; reason than the HTML engine's: soffice exits 0 having converted nothing
      ;; at all when it dislikes the input, printing its complaint and writing no
      ;; output file. So the OUTPUT is what is checked, not the status.
      (unless (file-exists? out)
        (error who "converting this document to PDF produced nothing (soffice exit ~a): ~a"
               code (tail-of log)))
      (define pdf (file->bytes out))
      (unless (and (>= (bytes-length pdf) 5) (bytes=? (subbytes pdf 0 5) #"%PDF-"))
        (error who "the converter wrote a file that is not a PDF"))
      pdf)
    (lambda () (delete-directory/files dir #:must-exist? #f))))

(define (tail-of s [n 600])
  (define t (string-trim s))
  (if (> (string-length t) n) (substring t (- (string-length t) n)) t))
