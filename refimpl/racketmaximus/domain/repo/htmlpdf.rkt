#lang racket/base

;; domain/repo/htmlpdf.rkt — a branded, paged PDF out of HTML and CSS
;; (issue #88 requirement 1). PURE OF THE REPOSITORY, like pdfform.rkt beside
;; doc_fill_form: it takes HTML text and a table of already-resolved assets and
;; answers bytes, so the whole surface is testable with a string and no database
;; while `can?` on each referenced document stays in doc-tools.rkt.
;;
;; THE ENGINE IS WeasyPrint, AND CHROMIUM WAS DECLINED. The issue offers either.
;; Six measurements decided it, and the first two are the requirement itself:
;;
;;   * CSS PAGED MEDIA. The acceptance criterion is "a logo, a wrapped table and
;;     Page X of Y". WeasyPrint implements `@page`, `position: running()` and
;;     `counter(page)`/`counter(pages)` natively — measured here at 6 pages with
;;     a running header on every one. Chromium headless implements NONE of those:
;;     it needs `--header-template` over CDP, which is a second templating
;;     language that is not CSS, and `counter(pages)` has no equivalent at all.
;;   * PDF/A. `--pdf-variant pdf/a-2b`, and the output was put through veraPDF
;;     1.30.2: 144 rules passed, 0 failed. Chromium cannot emit PDF/A, so
;;     requirement 1's flag would have been unimplementable.
;;   * NO SCRIPTING ENGINE. WeasyPrint runs no JavaScript at all. A template may
;;     be operator- or customer-authored, and this is a self-hosted, privacy-first
;;     platform: "the renderer cannot execute a template's script" is a stronger
;;     property than any sandbox configured around a browser that can.
;;   * THE SANDBOX IS A FLAG, not a configuration. `--allowed-protocols data`
;;     refuses `file:` and `http:` BY NAME — measured, including the control:
;;     without it, `file:///etc/hosts` really is fetched.
;;   * DETERMINISM, already (requirement 6). WeasyPrint 69 embeds no creation
;;     date and derives the document /ID from the content, so the same input
;;     gives byte-identical output — verified across two different
;;     `SOURCE_DATE_EPOCH` values, which is what proves there is no clock in it
;;     rather than merely that two runs a second apart agree.
;;   * CLOSURE. Chromium is a browser, in an image whose size is already a
;;     documented concern, to render an invoice.
;;
;; The deterministic-deps tenet's objection — that WeasyPrint is a Python
;; application — is answered by HOW it arrives: a pinned nixpkgs derivation in
;; `flake.lock`, exactly as pandoc and tectonic are. The tenet is about ad-hoc
;; package managers and a shared site-packages, not about a program that happens
;; to be written in Python.

(provide RENDER-ENGINES PDF-VARIANTS REPO-REF-RX
         HTML-PDF-SECONDS MAX-ASSET-BYTES MAX-ASSETS
         weasyprint-path html-pdf-object-refs render-html-pdf)

(require racket/string racket/list racket/file racket/port
         net/base64
         (only-in "pdfform.rkt" run-bounded))

;; CLOSED, and pinned by the test. `latex` is what `format: "pdf"` has meant
;; since DWF-6 (pandoc -> tectonic); naming it is what makes the other engines
;; additions rather than a change — an existing caller keeps the renderer it has.
;; `libreoffice` (#88 req 3) lives in docxpdf.rkt; the LIST lives here because
;; `doc_render` validates against it once, for every engine.
(define RENDER-ENGINES '("latex" "weasyprint" "libreoffice"))

;; ONE MEMBER, and that is deliberate. `pdf/a-2b` is the variant requirement 1
;; names and the only one whose output was put through a validator; WeasyPrint
;; will accept a dozen more, and offering one nobody checked would be a
;; conformance CLAIM rather than a flag. A member is added by validating it.
(define PDF-VARIANTS '("pdf/a-2b"))

;; A template reaches a document in the repository by id — requirement 1's
;; "images from repo objects by id". A scheme rather than a path because the
;; renderer must be able to find every one of them BEFORE anything runs, so each
;; can be authorized and inlined; a relative path would have to be fetched, and
;; fetching is exactly what `--allowed-protocols data` forbids.
(define REPO-REF-RX #px"repo:([0-9a-fA-F-]{8,64})")

(define HTML-PDF-SECONDS 120)       ; a long document legitimately takes a while
(define MAX-ASSETS 20)
(define MAX-ASSET-BYTES (* 16 1024 1024))

(define (weasyprint-path) (find-executable-path "weasyprint"))

;; html -> (listof id), de-duplicated, in first-appearance order
(define (html-pdf-object-refs html)
  (remove-duplicates
   (for/list ([m (in-list (regexp-match* REPO-REF-RX html #:match-select cadr))])
     (if (bytes? m) (bytes->string/utf-8 m) m))))

;; -> bytes
;;
;; `assets` maps an object id (string) to (cons content-type bytes); the CALLER
;; resolved them, because only the caller holds a principal and `repo-open` is
;; where `can?` answers. An id the template names and the table lacks is a
;; refusal here rather than a missing image there.
(define (render-html-pdf html
                         #:assets [assets (hash)]
                         #:variant [variant #f]
                         #:who [who 'doc_render])
  (define exe (or (weasyprint-path)
                  (error who "the HTML engine needs weasyprint on the server's PATH — the packaged wrapper carries it; a bare `racket server/main.rkt` needs it installed")))
  (when (and variant (not (member variant PDF-VARIANTS)))
    (error who "~s is not a PDF variant this build will produce (it offers: ~a)"
           variant (string-join PDF-VARIANTS ", ")))
  (define refs (html-pdf-object-refs html))
  (when (> (length refs) MAX-ASSETS)
    (error who "this template references ~a repository documents, more than the ~a this renderer will inline"
           (length refs) MAX-ASSETS))
  (define total
    (for/sum ([id (in-list refs)])
      (bytes-length (cdr (or (hash-ref assets id #f)
                             (error who "the template references repo:~a and that document was not available" id))))))
  (when (> total MAX-ASSET-BYTES)
    (error who "the documents this template inlines come to ~a bytes, more than the ~a this renderer will carry"
           total MAX-ASSET-BYTES))
  ;; Every reference becomes a `data:` URI, which is the ONLY protocol the
  ;; renderer is then allowed to fetch. So an asset is in the document before
  ;; weasyprint starts, and nothing it meets can reach the network or the disk.
  (define inlined
    (for/fold ([s html]) ([id (in-list refs)])
      (define a (hash-ref assets id))
      (string-replace s (string-append "repo:" id)
                      (string-append "data:" (car a) ";base64,"
                                     (bytes->string/utf-8 (base64-encode (cdr a) #""))))))
  (define dir (make-temporary-file "html-pdf-~a" 'directory))
  (dynamic-wind
    void
    (lambda ()
      (define in (build-path dir "doc.html"))
      (define out (build-path dir "doc.pdf"))
      (call-with-output-file in (lambda (o) (write-string inlined o)))
      (define-values (code log)
        (run-bounded exe (append
                          (list "--allowed-protocols" "data"
                                "--no-http-redirects"
                                "--custom-metadata"   ; the template's own <meta> tags
                                "--full-fonts"        ; embedded, as requirement 1 asks
                                "--timeout" "1"       ; nothing may be fetched anyway
                                "-v")
                          (if variant (list "--pdf-variant" variant) '())
                          (list (path->string in) (path->string out)))
                     #:seconds HTML-PDF-SECONDS))
      (when (eq? code 'timeout)
        (error who "rendering this document took longer than ~a seconds and was stopped" HTML-PDF-SECONDS))
      (unless (and (eqv? code 0) (file-exists? out))
        (error who "rendering this document failed (weasyprint exit ~a): ~a" code (tail-of log)))
      ;; THE EXIT CODE IS NOT THE VERDICT, and this is the one thing about this
      ;; engine that has to be handled rather than trusted: weasyprint logs a
      ;; resource it could not load as an ERROR and **exits 0**, leaving a
      ;; document with a hole where the logo was. A report that looks finished
      ;; and is not is the failure this whole area exists to avoid, so the log is
      ;; read and a refused or failed resource is a refusal.
      (define bad (resource-failures log))
      (unless (null? bad)
        (error who "this template asked for ~a that the renderer is not allowed to fetch — a template reaches a repository document as repo:<object id> and may reach nothing else: ~a"
               (if (= 1 (length bad)) "a resource" "resources")
               (string-join bad "; ")))
      (file->bytes out))
    (lambda () (delete-directory/files dir #:must-exist? #f))))

;; The two shapes weasyprint prints for a resource it did not render, which are
;; `ERROR: Failed to load <kind> at <url>: …`. Matched on the line rather than on
;; the wording after the colon, which varies by cause (a disallowed protocol, a
;; refused connection, an unsupported type).
(define (resource-failures log)
  (for/list ([line (in-list (string-split log "\n"))]
             #:when (and (regexp-match? #rx"^ERROR" line)
                         (regexp-match? #rx"Failed to load|disallowed protocol" line)))
    (string-trim (regexp-replace #rx"^ERROR: *" line ""))))

(define (tail-of s [n 600])
  (define t (string-trim s))
  (if (> (string-length t) n) (substring t (- (string-length t) n)) t))
