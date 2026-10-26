#lang racket/base

;; test/htmlpdf-tests.rkt — a branded, paged PDF out of HTML and CSS (#88 req 1).
;;
;; The suite SKIPS, loudly, without weasyprint on PATH: the engine is found at
;; call time by design and a box without it is a supported box. CI's devShell
;; carries it, so the skip cannot hide a regression there.
;;
;; Everything here goes through `render-html-pdf`, which takes HTML and a table
;; of ALREADY-RESOLVED assets — so the whole engine is exercised with a string
;; and no database, and the `can?` on each referenced document is asserted where
;; it lives, in the smoke.

(require rackunit racket/string racket/list racket/file racket/port
         net/base64
         "../domain/repo/htmlpdf.rkt"
         (only-in "../domain/repo/pdfform.rkt" run-bounded))

(define have? (and (weasyprint-path) #t))
(unless have?
  (printf "htmlpdf-tests: SKIPPING the render cases — no weasyprint on PATH (a supported box; CI's devShell has it)\n"))

;; ---- fixtures ------------------------------------------------------------------

(define LOGO-ID "11111111-2222-3333-4444-555555555555")

;; A VECTOR logo, and the reason is PDF/A: weasyprint marks a raster image
;; `/Interpolate true`, which ISO 19005-2 clause 6.2.8 forbids — measured with
;; veraPDF, one failed rule out of 144. An SVG is drawn as paths and conforms.
(define LOGO-SVG
  #"<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"16\" height=\"16\" viewBox=\"0 0 16 16\"><circle cx=\"8\" cy=\"8\" r=\"7\" fill=\"#334455\"/></svg>")

(define (assets) (hash LOGO-ID (cons "image/svg+xml" LOGO-SVG)))

;; The acceptance criterion's own document: a logo, a table whose cells wrap, and
;; a footer reading "Page X of Y" — all of it the TEMPLATE's own CSS, which is
;; what this engine exists for.
(define (report-html #:rows [rows 40] #:extra-head [extra ""] #:body-extra [bextra ""])
  (string-append
   "<!doctype html><html><head><meta charset=\"utf-8\">"
   "<title>Acme Service Report</title>"
   "<meta name=\"author\" content=\"Acme Operations\">"
   extra
   "<style>"
   "@page { size: A4; margin: 2.2cm 2cm 2.4cm 2cm;"
   "  @top-left { content: element(brandhdr); }"
   "  @bottom-center { content: \"Page \" counter(page) \" of \" counter(pages); font: 9pt sans-serif; } }"
   "#brandhdr { position: running(brandhdr); font: 10pt sans-serif; }"
   "body { font: 10.5pt/1.45 serif; }"
   "table { width: 100%; border-collapse: collapse; }"
   "th, td { border: 1px solid #bbb; padding: 4pt 6pt; vertical-align: top; text-align: left; }"
   "td.wrap { width: 55%; }"
   "</style></head><body>"
   "<div id=\"brandhdr\"><img src=\"repo:" LOGO-ID "\" width=\"16\" height=\"16\"> Acme Operations</div>"
   "<h1>Service Report</h1>"
   bextra
   "<table><thead><tr><th>Item</th><th class=\"wrap\">Description</th><th>Amount</th></tr></thead><tbody>"
   (apply string-append
          (for/list ([i (in-range 1 (add1 rows))])
            (format (string-append "<tr><td>SKU-~a</td><td class=\"wrap\">A deliberately long description that has to "
                                   "wrap inside its cell several times over, so the row grows taller than one line and "
                                   "the table has to break across a page boundary. Row ~a.</td><td>~a.00</td></tr>")
                    i i (* i 7))))
   "</tbody></table></body></html>"))

;; qpdf's QDF mode decompresses every stream; pdftotext reads the laid-out text.
(define (pdf-text bs)
  (define exe (find-executable-path "pdftotext"))
  (cond
    [(not exe) #f]
    [else
     (define dir (make-temporary-file "htmlpdf-t-~a" 'directory))
     (dynamic-wind
       void
       (lambda ()
         (define in (build-path dir "in.pdf"))
         (define out (build-path dir "out.txt"))
         (call-with-output-file in (lambda (o) (write-bytes bs o)))
         (run-bounded exe (list (path->string in) (path->string out)))
         ;; WHITESPACE IS NORMALIZED, because pdftotext breaks a laid-out line
         ;; wherever the renderer did: the first version of this suite asserted a
         ;; phrase that the table had wrapped across two lines and failed against
         ;; a perfectly good document.
         (if (file-exists? out)
             (string-join (string-split (file->string out)) " ")
             ""))
       (lambda () (delete-directory/files dir #:must-exist? #f)))]))

(define (count-matches rx s) (length (regexp-match* rx s)))

;; qpdf's own QDF mode decompresses every stream — the shortest way to read a
;; document's XMP without a zlib binding (pdfform-tests uses it for the same
;; reason, one directory along).
(define (uncompressed bs)
  (define exe (find-executable-path "qpdf"))
  (cond
    [(not exe) bs]
    [else
     (define dir (make-temporary-file "htmlpdf-q-~a" 'directory))
     (dynamic-wind
       void
       (lambda ()
         (define in (build-path dir "in.pdf"))
         (define out (build-path dir "out.pdf"))
         (call-with-output-file in (lambda (o) (write-bytes bs o)))
         (run-bounded exe (list "--qdf" "--object-streams=disable"
                                (path->string in) (path->string out)))
         (if (file-exists? out) (file->bytes out) bs))
       (lambda () (delete-directory/files dir #:must-exist? #f)))]))

;; ---- 1. the closed vocabularies ------------------------------------------------
;; PINNED, not re-derived: a test that rebuilt the list from the source agrees
;; with any change to it, and the point of a closed vocabulary is that adding a
;; member is a decision somebody makes on purpose (vocabulary-tests' rule).
(test-case "the engines are a closed, pinned vocabulary"
  (check-equal? RENDER-ENGINES '("latex" "weasyprint"))
  ;; `latex` is named so the SECOND engine is an addition rather than a change —
  ;; an existing `format: "pdf"` caller keeps the renderer it has.
  (check-true (and (member "latex" RENDER-ENGINES) #t)))

;; ONE member, and that is the decision: `pdf/a-2b` is the variant requirement 1
;; names and the only one whose output was put through a validator. A member
;; nobody checked would be a conformance CLAIM wearing a flag's clothes.
(test-case "one PDF variant, because one was validated"
  (check-equal? PDF-VARIANTS '("pdf/a-2b")))

;; ---- 2. finding what a template reaches for ------------------------------------
(test-case "repository references are found, de-duplicated, in order"
  (check-equal? (html-pdf-object-refs
                 (string-append "<img src=\"repo:" LOGO-ID "\"><img src='repo:" LOGO-ID "'>"
                                "<img src=\"repo:aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee\">"))
                (list LOGO-ID "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"))
  (check-equal? (html-pdf-object-refs "<p>no references here</p>") '()))

(when have?

  ;; ---- 3. THE ISSUE'S ACCEPTANCE CRITERION ------------------------------------
  (test-case "a logo, a wrapped table and Page X of Y render correctly"
    (define bs (render-html-pdf (report-html) #:assets (assets)))
    (check-true (> (bytes-length bs) 1000))
    (check-true (regexp-match? #rx#"^%PDF-" bs) "it is a PDF")
    (define text (pdf-text bs))
    (when text
      ;; the table really did break across pages — the single-page case would
      ;; pass every other assertion here while proving nothing about paged media
      (define pages (count-matches #px"Page [0-9]+ of ([0-9]+)" text))
      (check-true (> pages 1) (format "the report runs to more than one page (found ~a)" pages))
      ;; …and the TOTAL is right on every one, which is `counter(pages)`: a
      ;; running total is the thing Chromium headless cannot express at all
      (define totals (remove-duplicates (regexp-match* #px"Page [0-9]+ of ([0-9]+)" text #:match-select cadr)))
      (check-equal? (length totals) 1 "every footer names the same page total")
      (check-equal? (car totals) (number->string pages) "the total equals the number of footers")
      ;; the running header is on EVERY page, which is `position: running()`
      (check-equal? (count-matches #rx"Acme Operations" text) pages
                    "the running header repeats on every page")
      ;; the long cells wrapped rather than being clipped
      (check-true (regexp-match? #rx"wrap inside its cell" text))
      (check-true (regexp-match? #rx"Row 40" text) "the last row is present")))

  ;; ---- 4. the sandbox ----------------------------------------------------------
  ;; THE EXIT CODE IS NOT THE VERDICT. weasyprint logs a resource it refused as
  ;; an ERROR and exits 0, leaving a document with a hole where the logo was — so
  ;; without reading the log this renderer would hand back a report that looks
  ;; finished. Measured, which is why the log is parsed at all.
  (test-case "a template that reaches for a local file is REFUSED, not quietly rendered"
    (check-exn #rx"not allowed to fetch"
               (lambda ()
                 (render-html-pdf
                  (report-html #:body-extra "<img src=\"file:///etc/hosts\" alt=\"x\">")
                  #:assets (assets)))))

  (test-case "…and so is one that reaches for the network"
    (check-exn #rx"not allowed to fetch"
               (lambda ()
                 (render-html-pdf
                  (report-html #:extra-head "<link rel=\"stylesheet\" href=\"http://127.0.0.1:1/x.css\">")
                  #:assets (assets)))))

  ;; The refusal's partner: the SAME document with its references served from the
  ;; repository renders. A renderer that refused everything would pass both cases
  ;; above.
  (test-case "a template that reaches only the repository renders"
    (check-true (> (bytes-length (render-html-pdf (report-html #:rows 3) #:assets (assets))) 1000)))

  ;; An id the template names and the caller could not resolve is a refusal HERE,
  ;; rather than a missing image THERE.
  (test-case "a reference with no asset behind it is refused by id"
    (check-exn #rx"repo:11111111"
               (lambda () (render-html-pdf (report-html #:rows 2) #:assets (hash)))))

  ;; ---- 5. PDF/A ----------------------------------------------------------------
  ;; The output was put through veraPDF 1.30.2 by hand: 144 rules passed, 0
  ;; failed, for this document with its SVG logo. veraPDF is a 300 MB Java
  ;; validator and is deliberately NOT a dependency of this suite — what is
  ;; asserted here is that the flag reached the engine and the document says
  ;; which part it claims, which is the half that can regress.
  (test-case "pdf/a-2b reaches the engine and the document declares it"
    (define bs (render-html-pdf (report-html #:rows 3) #:assets (assets) #:variant "pdf/a-2b"))
    ;; the XMP packet is a compressed stream, so it has to be decompressed to be
    ;; read — asserting over the raw bytes passes vacuously against a build that
    ;; dropped the flag entirely, which is how this case first failed
    (define plain (uncompressed bs))
    (check-true (regexp-match? #rx#"pdfaid" plain) "the XMP carries the PDF/A identification")
    (check-true (regexp-match? #rx#"OutputIntent" plain) "…and an output intent, which PDF/A requires")
    ;; and the ordinary render does NOT claim it, or the assertion above would
    ;; hold whatever the flag did
    (check-false (regexp-match? #rx#"pdfaid"
                                (uncompressed (render-html-pdf (report-html #:rows 3) #:assets (assets))))))

  (test-case "a variant nobody validated is refused by name, listing what is offered"
    (check-exn #rx"not a PDF variant.*pdf/a-2b"
               (lambda () (render-html-pdf (report-html #:rows 2) #:assets (assets) #:variant "pdf/x-4"))))

  ;; ---- 6. determinism (requirement 6) -----------------------------------------
  ;; TWO RENDERS A SECOND APART AGREEING PROVES NOTHING — a document carrying a
  ;; creation date to the second would pass that. The claim is that the engine
  ;; embeds NO clock, and what establishes it is two renders under DIFFERENT
  ;; wall-clock times: SOURCE_DATE_EPOCH is the one knob a reproducible-build
  ;; toolchain reads, and weasyprint ignores it because it writes no date at all.
  (test-case "the same template and data give byte-identical output across time"
    (define (render-at epoch)
      (define before (getenv "SOURCE_DATE_EPOCH"))
      (dynamic-wind
        (lambda () (void (putenv "SOURCE_DATE_EPOCH" epoch)))
        (lambda () (render-html-pdf (report-html #:rows 5) #:assets (assets)))
        (lambda () (void (putenv "SOURCE_DATE_EPOCH" (or before ""))))))
    (define a (render-at "1700000000"))
    (define b (render-at "1800000000"))
    (check-equal? (bytes-length a) (bytes-length b))
    (check-true (equal? a b) "no creation date and a content-derived document id")
    ;; stated rather than left to be inferred: there is no `deterministic` flag,
    ;; because there is nothing to pin — a knob that did nothing would be the
    ;; #113 shape
    (check-false (regexp-match? #rx#"CreationDate" a)))

  ;; ---- 7. the caps -------------------------------------------------------------
  (test-case "a template that inlines too many documents is refused before anything runs"
    (define ids (for/list ([i (in-range (add1 MAX-ASSETS))])
                  (format "~a0000000-0000-0000-0000-00000000000~a"
                          (number->string i 16) (number->string i 16))))
    (define html (apply string-append
                        (cons "<html><body>"
                              (append (for/list ([id (in-list ids)]) (format "<img src=\"repo:~a\">" id))
                                      (list "</body></html>")))))
    (check-exn #rx"more than the"
               (lambda () (render-html-pdf html #:assets (for/hash ([id (in-list ids)])
                                                           (values id (cons "image/svg+xml" LOGO-SVG))))))))
