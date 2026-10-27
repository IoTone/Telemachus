#lang racket/base

;; #128 job 2: operator-facing variables are read through ONE accessor,
;; which tries TMACH_<name> and falls back to TELEMACHUS_<name>.
(require (only-in "../config.rkt" tmach-env))

;; test/ocr-tests.rkt — issue #92: reading text out of photographs and scans.
;;
;; The fixtures are GENERATED, with racket/draw, rather than committed as binary
;; assets: a .png in the repository is a thing nobody can diff or correct, and
;; the generator states the expected text in the same file as the assertion. It
;; also costs no new dependency — racket/draw writes both PNG and PDF, so the
;; image-only PDF (a "scan") is made the same way.
;;
;; What has to hold:
;;   1. a photograph of a printed page yields its text through the PLATFORM's
;;      own extract-text — i.e. the registry, the cap and the containment
;;   2. every span's offsets index into the text THAT SAME CALL returned. This is
;;      the property that would catch building the text from a second tesseract
;;      run, which can segment the page differently and silently point each
;;      region at the wrong characters
;;   3. a born-digital PDF is read from its TEXT LAYER and never rasterised
;;   4. an image-only PDF is OCR'd — 'needs-ocr becomes a step, not a terminus
;;   5. a rotated page still reads (--psm 1 detects orientation from content)
;;   6. no engine on the box is 'missing-tool, never a crash
;;   7. the page number is carried, and a multi-page scan numbers its pages
;;
;;   raco test test/ocr-tests.rkt

(require rackunit racket/string racket/port racket/file racket/list
         racket/draw racket/class racket/runtime-path
         (only-in "../domain/sched/scheduler.rkt" current-plugin)
         "../domain/repo/extract.rkt")

(define HAVE-TESSERACT? (and (find-executable-path "tesseract") #t))
(define HAVE-PDFTOPPM?  (and (find-executable-path "pdftoppm") #t))

;; Loudly, not silently. The s3 smoke skipped itself for want of the aws CLI and
;; that is precisely how a whole code path went unexercised for a year (issue
;; #25), so this says what is missing and CI installs it rather than tolerating
;; its absence.
(unless HAVE-TESSERACT?
  (displayln "ocr-tests: NO TESSERACT on PATH — the engine cases are skipped.")
  (displayln "           `nix develop` provides it; CI installs it. A green run")
  (displayln "           here without it proves only the refusal path."))

;; ---- fixtures -------------------------------------------------------------------
(define LINES '("Invoice ACME-4471" "Total 1250 EUR" "Due 2026-11-30"))

;; A clean page of printed text. 40pt modern is well above the ~20px tesseract
;; wants; a smaller face is a flaky test rather than a better one.
(define (draw-page! dc lines #:w [w 1000] #:h [h 300])
  (send dc set-background (make-color 255 255 255))
  (send dc clear)
  (send dc set-text-foreground (make-color 0 0 0))
  (send dc set-font (make-font #:size 40 #:family 'modern))
  (for ([l (in-list lines)] [i (in-naturals)])
    (send dc draw-text l 40 (+ 40 (* i 80)))))

(define (png-bitmap #:lines [lines LINES] #:rotate? [rotate? #f] #:w [w 1000] #:h [h 300])
  (define bm (make-bitmap w h))
  (define dc (new bitmap-dc% [bitmap bm]))
  (draw-page! dc lines #:w w #:h h)
  (if rotate? (rotate-bitmap bm) bm))

(define (png-bytes #:lines [lines LINES] #:rotate? [rotate? #f] #:w [w 1000] #:h [h 300])
  (define bm (png-bitmap #:lines lines #:rotate? rotate? #:w w #:h h))
  (define o (open-output-bytes))
  (send bm save-file o 'png)
  (get-output-bytes o))

;; A quarter turn, so the pixels really are sideways — the shape a phone photo
;; has when its EXIF says "rotate me" and nothing applied it.
;;
;; Done by TRANSPOSING PIXELS rather than with a dc transform. The transform
;; version (translate + rotate + draw-bitmap) silently produced a BLANK bitmap:
;; `file` still reported the right dimensions, tesseract read nothing, and the
;; test failed as though orientation detection were broken. A rotation test whose
;; fixture is a white rectangle proves nothing in either direction, so this is
;; both the simpler construction and the one with no geometry to get wrong —
;; and `non-blank?` below is asserted on the fixture before it is OCR'd.
(define (rotate-bitmap bm)
  (define w (send bm get-width)) (define h (send bm get-height))
  (define src (make-bytes (* 4 w h)))
  (send bm get-argb-pixels 0 0 w h src)
  (define out (make-bitmap h w))
  (define dst (make-bytes (* 4 w h) 255))
  ;; (x,y) -> (h-1-y, x): a clockwise quarter turn
  (for* ([y (in-range h)] [x (in-range w)])
    (define si (* 4 (+ (* y w) x)))
    (define di (* 4 (+ (* x h) (- h 1 y))))
    (bytes-copy! dst di src si (+ si 4)))
  (send out set-argb-pixels 0 0 h w dst)
  out)

;; Ink on the page: an all-white fixture is the failure mode above.
(define (non-blank? bm)
  (define w (send bm get-width)) (define h (send bm get-height))
  (define bs (make-bytes (* 4 w h)))
  (send bm get-argb-pixels 0 0 w h bs)
  (for/or ([i (in-range 0 (bytes-length bs) 4)])
    (< (bytes-ref bs (+ i 1)) 128)))

;; A PDF whose page is nothing but an image: no text layer at all, so the
;; built-in reader reports 'needs-ocr and this plugin has to rasterise it.
(define (image-only-pdf-bytes #:pages [pages 1])
  (define tmp (make-temporary-file "tmx-ocr-test-~a.pdf"))
  (define bm (png-bitmap))
  ;; as-eps #f: pdf-dc% defaults to ENCAPSULATED output, which is one page by
  ;; definition and answers `cannot create multiple pages for encapsulated
  ;; output` on the second start-page.
  (define dc (new pdf-dc% [interactive #f] [use-paper-bbox #f] [as-eps #f]
                  [width (send bm get-width)] [height (send bm get-height)]
                  [output tmp]))
  (send dc start-doc "scan")
  (for ([_ (in-range pages)])
    (send dc start-page)
    (send dc draw-bitmap bm 0 0)
    (send dc end-page))
  (send dc end-doc)
  (define bs (file->bytes tmp))
  (delete-file tmp)
  bs)

;; A born-digital PDF: real text drawn as text, so pdftotext finds a layer.
;; A multi-page PDF of numbered pages, for the page-ORDER boundary. Ten pages is
;; the smallest count that exercises it: pdftoppm pads to the document's digit
;; width, so this run produces pg-01…pg-10 and a lexicographic sort is page
;; order — but if it ever stopped padding, "pg-10" would sort before "pg-02" and
;; a long scan's text would come back shuffled. Numbered pages make that visible;
;; identical pages would not.
(define (numbered-pdf-bytes n)
  (define tmp (make-temporary-file "tmx-ocr-mp-~a.pdf"))
  (define dc (new pdf-dc% [interactive #f] [use-paper-bbox #f] [as-eps #f]
                  [width 600] [height 200] [output tmp]))
  (send dc start-doc "pages")
  (for ([i (in-range n)])
    (send dc start-page)
    (send dc set-font (make-font #:size 48 #:family 'modern))
    (send dc draw-text (format "PAGE ~a" (add1 i)) 40 40)
    (send dc end-page))
  (send dc end-doc)
  (define bs (file->bytes tmp)) (delete-file tmp) bs)

(define (text-pdf-bytes)
  (define tmp (make-temporary-file "tmx-ocr-text-~a.pdf"))
  (define dc (new pdf-dc% [interactive #f] [use-paper-bbox #f] [as-eps #f]
                  [width 600] [height 200] [output tmp]))
  (send dc start-doc "doc") (send dc start-page)
  (send dc set-font (make-font #:size 18 #:family 'modern))
  (send dc draw-text "BORN DIGITAL 90210" 20 40)
  (send dc end-page) (send dc end-doc)
  (define bs (file->bytes tmp)) (delete-file tmp) bs)

;; ---- the plugin under test ------------------------------------------------------
;; Registered the way the loader does it, so the ownership rules apply and the
;; call goes through extract-registered — the platform's cap and containment.
(define-runtime-path ocr-plugin "../plugins/ocr/main.rkt")
(define ocr-init! (dynamic-require ocr-plugin 'init!))

;; init! is OPT-IN on TELEMACHUS_OCR (see the plugin): the tests set it so they
;; exercise the real entry point rather than reaching past it to the registry.
(define (with-ocr thunk)
  (define saved (tmach-env "OCR"))
  (dynamic-wind
    (lambda () (putenv "TMACH_OCR" "1")
               (parameterize ([current-plugin "ocr"]) (ocr-init!)))
    thunk
    (lambda ()
      (putenv "TMACH_OCR" (or saved ""))
      (for ([ct (in-list '("image/jpeg" "image/png" "image/tiff" "image/bmp"
                           "image/webp" "image/x-portable-pixmap" "application/pdf"))])
        (unregister-extractor! ct)))))

(define (read3 bs ct)
  (extract-text/spans (open-input-bytes bs) ct))

;; ---- 1/2. an image, and the span-text agreement --------------------------------
(when HAVE-TESSERACT?
  (test-case "a photograph of a printed page yields its text, through the platform"
    (with-ocr
      (lambda ()
        (check-true (extractable? "image/png"))
        (define-values (text reason spans) (read3 (png-bytes) "image/png"))
        (check-false reason)
        (check-true (string? text))
        ;; The identifier is what a field extractor would want; assert on that
        ;; rather than on the whole page, so a single mis-read letter elsewhere
        ;; does not fail a test about whether OCR runs at all.
        (check-true (string-contains? text "ACME-4471")
                    (format "expected ACME-4471 in ~s" text))
        (check-true (string-contains? text "1250"))

        ;; THE property. Each span must name the characters it claims to name.
        (check-true (> (length spans) 3) "a page of three lines has several words")
        (for ([sp (in-list spans)])
          (check-false (span-problem sp))
          (define s (hash-ref sp 'start)) (define e (hash-ref sp 'end))
          (check-true (<= 0 s e (string-length text))
                      (format "span ~a..~a outside text of ~a" s e (string-length text)))
          (check-true (> (string-length (substring text s e)) 0)
                      "a span may not name an empty run")
          (check-false (string-contains? (substring text s e) " ")
                       "a word span may not straddle a separator"))
        ;; and a bbox really is four numbers in the image's own pixels
        (define b (hash-ref (car spans) 'bbox))
        (check-true (and (list? b) (= 4 (length b)) (andmap real? b)))
        (check-true (< (first b) (third b)) "x0 < x1")
        (check-true (< (second b) (fourth b)) "y0 < y1")))))

;; ---- 3. a born-digital PDF is NEVER rasterised ---------------------------------
(when HAVE-PDFTOPPM?
  (test-case "a PDF with a text layer is read from the layer, not OCR'd"
    (with-ocr
      (lambda ()
        (define-values (text reason spans) (read3 (text-pdf-bytes) "application/pdf"))
        (check-false reason)
        (check-true (string-contains? (or text "") "BORN DIGITAL"))
        ;; The tell: the text layer carries NO regions. Spans here would mean the
        ;; page had been rasterised and guessed at, which is the one thing the
        ;; ordering in extract-pdf/ocr exists to prevent.
        (check-equal? spans '()
                      "a text-layer read must not produce OCR regions")))))

;; ---- 4. an image-only PDF IS OCR'd ---------------------------------------------
(when (and HAVE-TESSERACT? HAVE-PDFTOPPM?)
  (test-case "an image-only PDF is OCR'd rather than reported needs-ocr"
    ;; First: what the platform says WITHOUT the plugin. This is the LAY-8
    ;; behaviour the issue is about, asserted here so the before/after is in one
    ;; place and the test cannot pass for the wrong reason.
    (define-values (t0 r0) (extract-text (open-input-bytes (image-only-pdf-bytes))
                                         "application/pdf"))
    (check-false t0)
    (check-equal? r0 'needs-ocr "the built-in must still call a scan a scan")

    (with-ocr
      (lambda ()
        (define-values (text reason spans) (read3 (image-only-pdf-bytes) "application/pdf"))
        (check-false reason)
        (check-true (string-contains? (or text "") "ACME-4471"))
        (check-true (pair? spans) "an OCR'd scan carries regions")
        (check-equal? (hash-ref (car spans) 'page) 1 "pages are 1-based")))))

;; ---- 5. a rotated page -----------------------------------------------------------
(when HAVE-TESSERACT?
  (test-case "a page whose pixels are sideways still reads"
    ;; The fixture first: see rotate-bitmap. A blank page would make this test
    ;; pass or fail for reasons that have nothing to do with orientation.
    (check-true (non-blank? (png-bitmap #:rotate? #t)) "the rotated fixture has ink on it")
    (with-ocr
      (lambda ()
        (define-values (text reason _s) (read3 (png-bytes #:rotate? #t) "image/png"))
        (check-false reason)
        (check-true (string-contains? (or text "") "ACME-4471")
                    (format "orientation detection failed; got ~s" text))))))

;; ---- 6. no engine is a named refusal -------------------------------------------
;; The engine going away AFTER boot — which is the only way this path is now
;; reached, because init! refuses up front when the switch is set and tesseract
;; is absent. So: register while it is there, then take it away. Blanking PATH
;; first would merely re-test init!'s refusal, which the case below does.
(when HAVE-TESSERACT?
  (test-case "an engine that disappears after boot is 'missing-tool, not a crash"
    (with-ocr
      (lambda ()
        (define saved (getenv "PATH"))
        (dynamic-wind
          (lambda () (putenv "PATH" ""))
          (lambda ()
            (define-values (text reason _s) (read3 (png-bytes) "image/png"))
            (check-false text)
            (check-equal? reason 'missing-tool)
            ;; check-true wants exactly #t; memq answers a LIST, which is truthy
            ;; and is not #t — the assertion passed nothing and failed anyway.
            (check-not-false (memq reason EXTRACT-REASONS)
                             "stays inside the closed vocabulary"))
          (lambda () (putenv "PATH" saved)))))))

;; ---- the switch ------------------------------------------------------------------
(test-case "unset, the switch leaves the platform's own PDF reader in place"
  (define saved (tmach-env "OCR"))
  (dynamic-wind
    (lambda () (putenv "TMACH_OCR" ""))
    (lambda ()
      (parameterize ([current-plugin "ocr"]) (ocr-init!))
      ;; nothing registered, so a scan still reports what it always did
      (check-false (memq "application/pdf" (map car (registered-extractors)))
                   "application/pdf must not be claimed when OCR is off")
      (when HAVE-PDFTOPPM?
        (define-values (t r) (extract-text (open-input-bytes (image-only-pdf-bytes))
                                           "application/pdf"))
        (check-false t)
        (check-equal? r 'needs-ocr)))
    (lambda () (putenv "TMACH_OCR" (or saved "")))))

(test-case "set with no engine, init! refuses loudly rather than reading nothing"
  (define saved-ocr (tmach-env "OCR"))
  (define saved-path (getenv "PATH"))
  (dynamic-wind
    (lambda () (putenv "TMACH_OCR" "1") (putenv "PATH" ""))
    (lambda ()
      (check-exn #px"tesseract"
                 (lambda () (parameterize ([current-plugin "ocr"]) (ocr-init!)))
                 "the operator asked for OCR; silence would look like a broken feature"))
    (lambda () (putenv "TMACH_OCR" (or saved-ocr "")) (putenv "PATH" saved-path))))

;; ---- 7. multi-page ---------------------------------------------------------------
(when (and HAVE-TESSERACT? HAVE-PDFTOPPM?)
  (test-case "a two-page scan numbers its pages, and offsets stay global"
    (with-ocr
      (lambda ()
        (define-values (text reason spans) (read3 (image-only-pdf-bytes #:pages 2)
                                                  "application/pdf"))
        (check-false reason)
        (define pages (sort (remove-duplicates (map (lambda (s) (hash-ref s 'page)) spans)) <))
        (check-equal? pages '(1 2) (format "expected two pages, got ~a" pages))
        ;; Offsets are into the ONE returned string, so a page-2 span must still
        ;; name its own word — the bug an accumulator that restarts at 0 makes.
        (for ([sp (in-list spans)])
          (define w (substring text (hash-ref sp 'start) (hash-ref sp 'end)))
          (check-false (string=? (string-trim w) "")))))))

;; ---- 8. page ORDER past the single-digit boundary -------------------------------
(when (and HAVE-TESSERACT? HAVE-PDFTOPPM?)
  (test-case "a ten-page scan comes back in page order, not lexicographic order"
    ;; 72dpi: this reads ten pages and the words are 48pt, so the cheapest
    ;; rasterisation that still reads keeps the suite quick.
    (define saved (tmach-env "OCR_DPI"))
    (dynamic-wind
      (lambda () (putenv "TMACH_OCR_DPI" "72"))
      (lambda ()
        (with-ocr
          (lambda ()
            (define-values (text reason spans) (read3 (numbered-pdf-bytes 10) "application/pdf"))
            (check-false reason)
            ;; The page numbers tesseract read, in the order they appear in the
            ;; text. Shuffled filenames would show up here as 1,10,2,3,…
            (define seen
              (for/list ([m (in-list (regexp-match* #px"PAGE ([0-9]+)" (or text "")
                                                    #:match-select cadr))])
                (string->number m)))
            (check-equal? seen '(1 2 3 4 5 6 7 8 9 10)
                          (format "pages out of order: ~a (text ~s)" seen text))
            ;; and the spans' own page numbers rise with the text
            (define pages (remove-duplicates (map (lambda (s) (hash-ref s 'page)) spans)))
            (check-equal? pages (sort pages <) "span pages must ascend with the offsets"))))
      (lambda () (putenv "TMACH_OCR_DPI" (or saved ""))))))
