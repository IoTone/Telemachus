#lang racket/base

;; #128 job 2: operator-facing variables are read through ONE accessor,
;; which tries TMACH_<name> and falls back to TELEMACHUS_<name>.
(require (only-in "../../config.rkt" tmach-env))
;; OCR — reading text out of photographs and scanned PDFs (issue #92).
;;
;; Scanned paperwork is the normal case for the documents this platform is for.
;; Until now `image/*` was 'unsupported and a PDF with no text layer was
;; 'needs-ocr (LAY-8) — the right answers, and both dead ends. This plugin is
;; what makes 'needs-ocr a step rather than a terminus.
;;
;; WHY A PLUGIN THAT SHELLS OUT, and not the JSON-RPC out-of-process plugin
;; issue #92 suggests. LAY-7 settled this: a registered extractor is IN-PROCESS
;; Racket with the platform's own contract, and reaching a non-Racket engine is
;; the extractor's own business — the built-in PDF reader is already a pipe to
;; `pdftotext`, and extract.rkt's own comment names "a plugin wrapping YomiToku
;; or PaddleOCR" as a few lines of Racket around a subprocess. LAY-6's
;; out-of-process seam is for a plugin that acts as a TOOL (bytes shipped to it),
;; not as a READER. Building this over JSON-RPC would mean a second extractor
;; mechanism for one format, with the platform's cap, timeout, 'failed
;; containment and ownership rules all re-implemented on the far side.
;;
;; WHY IT CLAIMS application/pdf. Registering a type the platform already reads
;; REPLACES its reader, which is how an OCR engine takes over from `pdftotext` —
;; LAY-7's stated purpose. So requirement 5 ("a needs-ocr result must become an
;; automatic OCR step, not a terminal state") needs no new machinery and no
;; retry queue: this reader tries the text layer FIRST and only rasterises when
;; there is none. A born-digital PDF must never be OCR'd — it is slower, and the
;; text layer is exact where OCR guesses — so the order is load-bearing, not an
;; optimisation.
(require racket/port racket/string racket/file
         (only-in "../../domain/repo/extract.rkt" register-extractor!))

;; init! is all the platform needs. The two extractors are exported for TESTS:
;; extract-registered contains a raise as 'failed — correctly, so one plugin
;; cannot wedge a team's indexing — which also means a bug in here reaches a test
;; as an unexplained 'failed. A test that can call them directly sees the message.
(provide init! extract-image extract-pdf/ocr)

;; ---- configuration --------------------------------------------------------------
;; Every knob follows the platform's rule for interval/limit knobs: an
;; unparseable or non-positive value falls back to the default, NEVER to 0.
;; Takes the VALUE, not the name: every operator variable is spelled exactly
;; once in the tree, as `(tmach-env "<SUFFIX>")` at the call site, so neither the
;; gate in test/env-names-tests.rkt nor scripts/check-config-reference.sh has to
;; know which helpers forward to the accessor.
(define (pos-env v default)
  (define n (string->number (or v "")))
  (if (and (exact-integer? n) (> n 0)) n default))

;; Languages are passed to tesseract as-is (`eng`, `eng+spa`). The nixpkgs build
;; bundles 129 language files, so #92's "at least eng, spa" needs no override;
;; `tesseract --list-langs` is the authority on a given box.
(define (ocr-languages) (or (tmach-env "OCR_LANGUAGES") "eng"))

;; A ceiling on work per document, because this is the one extractor whose cost
;; scales with the input rather than being a single read. A 400-page scan at
;; 150dpi is minutes of CPU; without a bound one upload holds a scheduler slot
;; for the whole of it.
(define (ocr-max-pages)   (pos-env (tmach-env "OCR_MAX_PAGES") 20))
(define (ocr-timeout)     (pos-env (tmach-env "OCR_TIMEOUT") 120))
(define (ocr-dpi)         (pos-env (tmach-env "OCR_DPI") 150))

;; ---- running the engine ---------------------------------------------------------
;; Found at CALL time, never at load (DWF-6's rule for pandoc/tectonic): a box
;; without tesseract still boots, every other format still reads, and this one
;; call reports 'missing-tool — the reason an operator can act on.
(define (tesseract-path) (find-executable-path "tesseract"))
(define (pdftoppm-path)  (find-executable-path "pdftoppm"))
(define (pdftotext-path) (find-executable-path "pdftotext"))

;; Run a subprocess to completion under its own custodian with a deadline,
;; answering (values stdout-string ok?). The custodian is the point: killing the
;; waiting thread alone would leave the child and its pipes alive, which is the
;; measured mistake llm.rkt documents for HTTP.
(define (run/timeout exe args #:seconds [seconds (ocr-timeout)] #:input [input #f])
  (define cust (make-custodian))
  (define out (box ""))
  (dynamic-wind
    void
    (lambda ()
      (parameterize ([current-custodian cust])
        (define-values (proc p-out p-in p-err)
          (apply subprocess #f #f #f exe args))
        ;; Feed on a THREAD: a large image can exceed the pipe buffer, and
        ;; writing it all before reading stdout would deadlock with the child
        ;; blocked writing TSV we are not draining yet.
        (define feeder
          (thread (lambda ()
                    (with-handlers ([exn:fail? void])
                      (when input (write-bytes input p-in)))
                    (close-output-port p-in))))
        (define reader (thread (lambda () (set-box! out (port->string p-out)))))
        (define drain  (thread (lambda () (void (port->string p-err)))))
        (define done (thread (lambda () (subprocess-wait proc))))
        (define finished? (sync/timeout seconds done))
        (cond
          [(not finished?)
           (subprocess-kill proc #t)
           (values "" #f)]
          [else
           (thread-wait reader) (thread-wait drain) (thread-wait feeder)
           (values (unbox out) (eqv? 0 (subprocess-status proc)))])))
    (lambda () (custodian-shutdown-all cust))))

;; ---- the TSV, which is the whole provenance story -------------------------------
;; tesseract's `tsv` output is one row per element with a level column; level 5 is
;; a WORD, carrying page_num, left/top/width/height and a confidence.
;;
;; The text is built FROM these rows rather than by running tesseract a second
;; time in `txt` mode. Two runs can disagree — a different page-segmentation
;; decision changes the words — and LAY-5's offsets index into "the text this
;; same call returned", so a span from one run against text from another is a
;; provenance record that quietly points at the wrong characters. One run, one
;; string, offsets taken as the string is assembled.
(define TSV-LEVEL-WORD 5)

(struct tsvword (page block par line text left top width height conf) #:transparent)

(define (parse-tsv s)
  (for*/list ([line (in-list (string-split s "\n"))]
              [cols (in-value (string-split line "\t" #:trim? #f))]
              #:when (and (>= (length cols) 12)
                          (equal? (string->number (car cols)) TSV-LEVEL-WORD))
              [txt (in-value (list-ref cols 11))]
              #:when (not (string=? (string-trim txt) "")))
    (define (num i) (or (string->number (list-ref cols i)) 0))
    (tsvword (num 1) (num 2) (num 3) (num 4) txt
             (num 6) (num 7) (num 8) (num 9) (num 10))))

;; words -> (values text spans). `page-offset` lets a caller that rasterises a PDF
;; page by page number the pages globally; tesseract restarts at 1 per invocation.
(define (words->text+spans words #:page-offset [page-offset 0] #:start [start 0])
  (define out (open-output-string))
  (define pos start)
  (define spans
    (let loop ([ws words] [prev #f] [acc '()])
      (cond
        [(null? ws) (reverse acc)]
        [else
         (define w (car ws))
         ;; A new line, paragraph, block or page breaks the text; within a line,
         ;; words are separated by a single space. This is what makes the
         ;; extracted text of a form read like the form rather than one run-on
         ;; line, which matters because doc_extract_fields reads it.
         (define sep
           (cond
             [(not prev) ""]
             [(or (not (= (tsvword-page w) (tsvword-page prev)))
                  (not (= (tsvword-block w) (tsvword-block prev)))
                  (not (= (tsvword-par w) (tsvword-par prev)))
                  (not (= (tsvword-line w) (tsvword-line prev)))) "\n"]
             [else " "]))
         (write-string sep out)
         (set! pos (+ pos (string-length sep)))
         (define s pos)
         (write-string (tsvword-text w) out)
         (set! pos (+ pos (string-length (tsvword-text w))))
         (loop (cdr ws) w
               (cons (hasheq 'start s 'end pos
                             'page (+ page-offset (tsvword-page w))
                             ;; pixels of the image tesseract read, in the
                             ;; extractor's OWN units — the platform carries a
                             ;; bbox without interpreting it (LAY-5), because only
                             ;; a renderer knows whether these are points or pixels
                             'bbox (list (tsvword-left w) (tsvword-top w)
                                         (+ (tsvword-left w) (tsvword-width w))
                                         (+ (tsvword-top w) (tsvword-height w))))
                     acc))])))
  (values (get-output-string out) spans))

;; One image, as bytes -> (values text spans ok?)
(define (ocr-image-bytes bs #:page-offset [page-offset 0] #:start [start 0])
  (define exe (tesseract-path))
  (cond
    [(not exe) (values "" '() #f)]
    [else
     (define-values (tsv ok?)
       (run/timeout exe (list "-" "-" "-l" (ocr-languages)
                              ;; --psm 1: automatic page segmentation WITH
                              ;; orientation and script detection. This is how
                              ;; #92's "EXIF orientation honoured" is met, and it
                              ;; is strictly better than reading EXIF: leptonica
                              ;; does not apply an EXIF rotation, and a page fed
                              ;; through a scanner sideways has no EXIF to read.
                              ;; Detecting rotation from the CONTENT covers both.
                              "--psm" "1"
                              "tsv")
                    #:input bs))
     (cond
       [(not ok?) (values "" '() #f)]
       [else
        (define-values (text spans)
          (words->text+spans (parse-tsv tsv) #:page-offset page-offset #:start start))
        (values text spans #t)])]))

;; ---- the extractors ------------------------------------------------------------
;; THE IMAGE GOES IN ON STDIN, and never through a temp file. `tesseract - -`
;; means exactly that, the same way the built-in PDF reader pipes to `pdftotext`.
;;
;; This is not only tidier — a temp file did not work. Handed a path, leptonica
;; picks its decoder from the FILENAME, so a suffix-less temp file answers
;;
;;   Error in fopenReadStream: failed to open locally with tail tmx-ocr-...
;;   Leptonica Error in pixRead: image file not found: <PNG>
;;   Image file <PNG> cannot be read!
;;
;; and exits 1 — the PNG's own magic bytes turning up where a filename belongs,
;; because having failed to decode the file tesseract falls back to reading it as
;; a LIST OF IMAGE PATHS. Adding `.png` fixed that and the open still failed for a
;; file Racket had written into the nix-shell TMPDIR, though `file` called it a
;; valid PNG and tesseract read it from a shell. Stdin has none of these
;; questions, costs no cleanup, and cannot leave a stray file behind when a job
;; is cancelled mid-read. Nothing here needs a path, so nothing here takes one.

;; An image. An empty result here is an HONEST EMPTY: we have already run the
;; engine, so there is no further step to point at, and a photograph of a wall
;; genuinely has no text. This is deliberately NOT 'needs-ocr — that reason means
;; "a reader that can do OCR would get further", and here that reader has run.
;; Returning it would make the indexer offer the document forever.
(define (extract-image in content-type)
  (cond
    [(not (tesseract-path)) (values #f 'missing-tool '())]
    [else
     (define-values (text spans ok?) (ocr-image-bytes (port->bytes in)))
     (if ok? (values text #f spans) (values #f 'failed '()))]))

;; A PDF. The TEXT LAYER FIRST — see the header: a born-digital PDF must never be
;; rasterised and guessed at when it carries exact text.
(define (extract-pdf/ocr in content-type)
  (define bs (port->bytes in))
  (define layer (pdf-text-layer bs))
  (cond
    [(and layer (not (string=? (string-trim layer) ""))) (values layer #f '())]
    [(not (tesseract-path)) (values #f 'missing-tool '())]
    [(not (pdftoppm-path))  (values #f 'missing-tool '())]
    [else (ocr-pdf-pages bs)]))

;; The built-in reader's own answer, reused rather than re-derived: #f when
;; pdftotext is absent or failed, otherwise whatever text the layer holds.
(define (pdf-text-layer bs)
  (define exe (pdftotext-path))
  (and exe
       (let-values ([(out ok?) (run/timeout exe (list "-q" "-" "-") #:input bs)])
         (and ok? out))))

(define (ocr-pdf-pages bs)
  (define dir (make-temporary-directory "tmx-ocr-~a"))
  (dynamic-wind
    void
    (lambda ()
      (define pdf (build-path dir "in.pdf"))
      (call-with-output-file pdf #:exists 'truncate (lambda (o) (write-bytes bs o)))
      ;; -l bounds the work in pdftoppm rather than after it: rendering 400 pages
      ;; and then reading 20 would pay the whole cost to throw it away.
      (define-values (_o ok?)
        (run/timeout (pdftoppm-path)
                     (list "-r" (number->string (ocr-dpi)) "-png"
                           "-l" (number->string (ocr-max-pages))
                           (path->string pdf) (path->string (build-path dir "pg")))))
      ;; A LEXICOGRAPHIC sort is right here, and only because pdftoppm
      ;; ZERO-PADS to the width of the document's highest page number: a
      ;; 12-page scan gives pg-01…pg-12, not pg-1…pg-12, so every name is the
      ;; same width and string order is page order. Measured, because the naive
      ;; reading breaks at page 10 — unpadded, "pg-10" sorts before "pg-2" and
      ;; the text of a long scan comes back shuffled with every span pointing
      ;; into the wrong page. test/ocr-tests.rkt covers a 10-page document for
      ;; exactly this boundary. Do not "simplify" this to a plain sort on the
      ;; assumption that the names are numeric.
      (define pages
        (sort (for/list ([f (in-list (directory-list dir))]
                         #:when (regexp-match? #px"^pg.*\\.png$" (path->string f)))
                f)
              string<? #:key path->string))
      (cond
        ;; pdftoppm failing and pdftoppm producing nothing are one answer: there
        ;; are no pages to read, and the operator-fixable case (no binary at all)
        ;; was already separated out as 'missing-tool before we got here.
        [(null? pages) (values #f 'failed '())]
        [else
         ;; Accumulate across pages, carrying the running offset so every span's
         ;; start/end indexes into the ONE string this call returns.
         (let loop ([ps pages] [n 1] [texts '()] [spans '()] [pos 0] [any? #f])
           (cond
             [(null? ps)
              (if any?
                  (values (string-join (reverse texts) "\n") #f (reverse spans))
                  (values #f 'failed '()))]
             [else
              (define sep (if (null? texts) "" "\n"))
              (define start (+ pos (string-length sep)))
              (define-values (t sp ok?) (ocr-image-bytes (file->bytes (build-path dir (car ps)))
                                                         #:page-offset (sub1 n)
                                                         #:start start))
              (if ok?
                  (loop (cdr ps) (add1 n) (cons t texts)
                        (append (reverse sp) spans)
                        (+ start (string-length t)) #t)
                  ;; One unreadable page must not lose the other nineteen.
                  (loop (cdr ps) (add1 n) texts spans pos any?))]))]))
    (lambda () (with-handlers ([exn:fail? void]) (delete-directory/files dir)))))

;; ---- registration ---------------------------------------------------------------
;; The image types leptonica reads natively. HEIC is deliberately NOT here: it
;; needs libheif to become a PNG first, and claiming a type we would answer
;; 'failed for is worse than leaving it 'unsupported, which at least says the
;; truth. See the issue comment for that half.
(define IMAGE-TYPES
  '("image/jpeg" "image/png" "image/tiff" "image/bmp" "image/webp" "image/x-portable-pixmap"))

;; OPT-IN, with TELEMACHUS_OCR=1. The plugin ships in plugins/, so it is loaded
;; by default like every other — but registering `application/pdf` REPLACES the
;; platform's PDF reader for the whole instance, and a reader that silently takes
;; over because a binary happens to be on PATH is the shape of mistake the
;; blob-store check exists to refuse. #92 asks for it to be "selectable per
;; instance via config", so selection is explicit and the default is today's
;; behaviour exactly: with the switch unset, nothing here registers and a scan
;; still reports 'needs-ocr.
(define (ocr-enabled?)
  (member (string-downcase (string-trim (or (tmach-env "OCR") "")))
          '("1" "yes" "true" "on")))

(define (init!)
  (cond
    [(not (ocr-enabled?)) (void)]
    ;; Enabled and unusable is the one state worth shouting about: the operator
    ;; asked for OCR, so answering 'missing-tool on every scan while the boot log
    ;; says nothing is how a deployment concludes the feature is broken. The
    ;; plugin loader reports a RAISE as a plugin failure (issue #48) and
    ;; TELEMACHUS_PLUGINS_STRICT=1 turns that into a refusal to start, which is
    ;; the escalation an unattended deployment wants.
    [(not (find-executable-path "tesseract"))
     (error 'ocr "TMACH_OCR is set but `tesseract` is not on PATH — install it or unset the switch")]
    [else
     (for ([ct (in-list IMAGE-TYPES)]) (register-extractor! ct extract-image))
     ;; REPLACES the built-in PDF reader — LAY-7's stated purpose, and the whole
     ;; of requirement 5: 'needs-ocr becomes a step rather than a terminus,
     ;; with no retry queue and no new machinery.
     (register-extractor! "application/pdf" extract-pdf/ocr)
     (printf "ocr: enabled — ~a image type(s) + application/pdf, languages ~a
"
             (length IMAGE-TYPES) (ocr-languages))]))
