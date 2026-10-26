#lang racket/base

;; test/pdfform-tests.rkt — the fields of a PDF form (#88 req 2).
;;
;; THE FIXTURE IS HAND-BUILT, not produced by the tool under test. pdfcpu can
;; `create` a form from JSON, and a form filled by the same program that wrote it
;; proves only that the program agrees with itself — the documents this tool
;; exists for come out of Acrobat, LibreOffice and a government website. So
;; `acroform-pdf` below writes the PDF objects by hand: merged field/widget
;; dictionaries under the catalog's /AcroForm, one text field per /Tx, a /Btn
;; checkbox WITH its /AP appearance dictionary and a /Ch combo box with /Opt.
;;
;; The suite SKIPS, loudly, when pdfcpu is not on PATH — the toolchain is found
;; at call time by design, and a box without it is a supported box. CI's devShell
;; carries both binaries, so the skip cannot hide a regression there.

(require rackunit racket/string racket/list racket/port racket/file
         json
         "../domain/repo/pdfform.rkt")

;; ---- the fixture ---------------------------------------------------------------

(define (obj n body) (cons n body))

(define (pdf-bytes objs)
  (define o (open-output-bytes))
  (write-bytes #"%PDF-1.7\n%\342\343\317\323\n" o)
  (define offs
    (for/list ([e (in-list objs)])
      (define at (file-position o))
      (write-bytes (string->bytes/utf-8 (format "~a 0 obj\n" (car e))) o)
      (write-bytes (cdr e) o)
      (write-bytes #"\nendobj\n" o)
      (cons (car e) at)))
  (define xref (file-position o))
  (write-bytes (string->bytes/utf-8 (format "xref\n0 ~a\n" (add1 (length objs)))) o)
  (write-bytes #"0000000000 65535 f \n" o)
  (for ([e (in-list offs)])
    (write-bytes (string->bytes/utf-8 (format "~a 00000 n \n" (~pad (cdr e)))) o))
  (write-bytes (string->bytes/utf-8
                (format "trailer\n<< /Size ~a /Root 1 0 R >>\nstartxref\n~a\n%%EOF\n"
                        (add1 (length objs)) xref)) o)
  (get-output-bytes o))

(define (~pad n)
  (define s (number->string n))
  (string-append (make-string (max 0 (- 10 (string-length s))) #\0) s))

(define (stream-obj dict body)
  (bytes-append (string->bytes/utf-8 (format "<< ~a /Length ~a >>\nstream\n" dict (bytes-length body)))
                body #"\nendstream"))

(define (text-field name y)
  (string->bytes/utf-8
   (format "<< /Type /Annot /Subtype /Widget /FT /Tx /T (~a) /V () /Rect [120 ~a 400 ~a] /F 4 /DA (/Helv 11 Tf 0 g) /P 3 0 R /MK << /BC [0 0 0] >> >>"
           name y (+ y 20))))

(define PAGE-CONTENT
  #"BT /Helv 16 Tf 60 700 Td (Acme Service Request) Tj ET\nBT /Helv 11 Tf 60 606 Td (Applicant) Tj ET\nBT /Helv 11 Tf 60 566 Td (Reference) Tj ET\nBT /Helv 11 Tf 60 522 Td (Urgent) Tj ET\nBT /Helv 11 Tf 60 476 Td (Region) Tj ET\n")

;; #:checkbox-ap? #f drops the checkbox's /AP, which is the state a real form
;; sometimes arrives in and which pdfcpu cannot toggle — the refusal is asserted.
;; #:lock-reference? locks one field, so the read-only refusal has a subject.
(define (acroform-pdf #:checkbox-ap? [ap? #t] #:lock-reference? [lock? #f])
  (define off-ap #"q 1 1 12 12 re W n Q")
  (define on-ap #"q BT /ZaDb 10 Tf 0 g 2 2 Td (4) Tj ET Q")
  (pdf-bytes
   (list
    (obj 1 #"<< /Type /Catalog /Pages 2 0 R /AcroForm << /Fields [5 0 R 6 0 R 7 0 R 8 0 R] /DA (/Helv 0 Tf 0 g) /DR << /Font << /Helv 4 0 R /ZaDb 11 0 R >> >> /NeedAppearances true >> >>")
    (obj 2 #"<< /Type /Pages /Kids [3 0 R] /Count 1 >>")
    (obj 3 #"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /Helv 4 0 R /ZaDb 11 0 R >> >> /Contents 9 0 R /Annots [5 0 R 6 0 R 7 0 R 8 0 R] >>")
    (obj 4 #"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding /WinAnsiEncoding >>")
    (obj 5 (text-field "applicant" 600))
    (obj 6 (let ([base (text-field "reference" 560)])
             (if lock?
                 ;; /Ff bit 1 is ReadOnly
                 (regexp-replace #rx#"/FT /Tx" base #"/FT /Tx /Ff 1")
                 base)))
    (obj 7 (string->bytes/utf-8
            (string-append
             "<< /Type /Annot /Subtype /Widget /FT /Btn /T (urgent) /V /Off /AS /Off /Rect [120 520 134 534] /F 4 /DA (/ZaDb 0 Tf 0 g) /P 3 0 R /MK << /BC [0 0 0] /CA (4) >>"
             (if ap? " /AP << /N << /Off 10 0 R /Yes 12 0 R >> >>" "")
             " >>")))
    (obj 8 #"<< /Type /Annot /Subtype /Widget /FT /Ch /T (region) /V (emea) /Opt [(amer) (emea) (apac)] /Rect [120 470 300 490] /F 4 /Ff 131072 /DA (/Helv 11 Tf 0 g) /P 3 0 R >>")
    (obj 9 (stream-obj "" PAGE-CONTENT))
    (obj 10 (stream-obj "/Type /XObject /Subtype /Form /BBox [0 0 14 14] /Resources << /Font << /ZaDb 11 0 R >> >>" off-ap))
    (obj 11 #"<< /Type /Font /Subtype /Type1 /BaseFont /ZapfDingbats >>")
    (obj 12 (stream-obj "/Type /XObject /Subtype /Form /BBox [0 0 14 14] /Resources << /Font << /ZaDb 11 0 R >> >>" on-ap)))))

;; A perfectly ordinary PDF with no form at all.
(define (plain-pdf)
  (pdf-bytes
   (list
    (obj 1 #"<< /Type /Catalog /Pages 2 0 R >>")
    (obj 2 #"<< /Type /Pages /Kids [3 0 R] /Count 1 >>")
    (obj 3 #"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /Helv 4 0 R >> >> /Contents 5 0 R >>")
    (obj 4 #"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
    (obj 5 (stream-obj "" #"BT /Helv 12 Tf 60 700 Td (not a form) Tj ET\n")))))

(define (names fields) (map (lambda (f) (hash-ref f 'name)) fields))
(define (kind-of fields n)
  (for/first ([f (in-list fields)] #:when (equal? (hash-ref f 'name) n)) (hash-ref f 'kind)))

;; the filled text ends up in the page content once flattened; before that it is
;; in the field's /V, which `pdf-form-fields` reads back
(define (value-of fields n)
  (for/first ([f (in-list fields)] #:when (equal? (hash-ref f 'name) n)) (hash-ref f 'value)))

;; qpdf's own QDF mode decompresses every stream — the shortest way to read a
;; flattened document's page content without a zlib binding.
(define (uncompressed bs)
  (define dir (make-temporary-file "pdfform-t-~a" 'directory))
  (dynamic-wind
    void
    (lambda ()
      (define in (build-path dir "in.pdf"))
      (define out (build-path dir "out.pdf"))
      (call-with-output-file in (lambda (o) (write-bytes bs o)))
      (define-values (code _m)
        (run-bounded (qpdf-path) (list "--qdf" "--object-streams=disable"
                                       (path->string in) (path->string out))))
      (if (file-exists? out) (file->bytes out) bs))
    (lambda () (delete-directory/files dir #:must-exist? #f))))

(define have-pdfcpu? (and (pdfcpu-path) #t))
(define have-qpdf? (and (qpdf-path) #t))

(unless have-pdfcpu?
  (printf "pdfform-tests: SKIPPING the form cases — no pdfcpu on PATH (this is a supported box; CI's devShell has it)\n"))
(when (and have-pdfcpu? (not have-qpdf?))
  (printf "pdfform-tests: SKIPPING the flatten cases — no qpdf on PATH\n"))

;; ---- 1. the closed vocabulary --------------------------------------------------
;; PINNED, not re-derived: a test that rebuilt the list from the source would
;; agree with any change to it, and the point of a closed vocabulary is that
;; adding a member is a decision somebody makes on purpose (vocabulary-tests).
(test-case "the field kinds are a closed, pinned vocabulary"
  (check-equal? FORM-FIELD-KINDS
                '("textfield" "datefield" "checkbox" "radiobuttongroup" "combobox" "listbox"))
  ;; the partition is asserted, not assumed — `group-for-fill` branches on it
  (check-equal? (sort (append TEXT-KINDS '("checkbox") CHOICE-KINDS) string<?)
                (sort FORM-FIELD-KINDS string<?))
  (check-equal? (length (remove-duplicates FORM-FIELD-KINDS)) (length FORM-FIELD-KINDS)))

(when have-pdfcpu?

  ;; ---- 2. discovery ------------------------------------------------------------
  (test-case "every field is found, with its kind and its options"
    (define fs (pdf-form-fields (acroform-pdf)))
    (check-equal? (names fs) '("applicant" "reference" "region" "urgent"))
    (check-equal? (kind-of fs "applicant") "textfield")
    (check-equal? (kind-of fs "urgent") "checkbox")
    (check-equal? (kind-of fs "region") "combobox")
    (check-equal? (value-of fs "region") "emea")
    (check-equal? (for/first ([f (in-list fs)] #:when (equal? (hash-ref f 'name) "region"))
                    (hash-ref f 'options))
                  '("amer" "emea" "apac")))

  ;; A document that is not a form is an ANSWER, never an error: the discovery
  ;; endpoint is reachable for any document somebody can read, and a 500 there
  ;; would make every ordinary PDF look like a broken server.
  (test-case "a PDF with no form answers with no fields, rather than failing"
    (check-equal? (pdf-form-fields (plain-pdf)) '()))

  (test-case "bytes that are not a PDF at all are a named failure, not an empty answer"
    (check-exn #rx"could not be read"
               (lambda () (pdf-form-fields #"this is not a PDF"))))

  ;; ---- 3. filling --------------------------------------------------------------
  (test-case "a form is filled from a JSON object, and reads back with the values"
    (define-values (out unmatched)
      (pdf-form-fill (acroform-pdf)
                     (hasheq 'applicant "Arun Patel" 'reference "ACME-2026-0042"
                             'urgent #t 'region "apac")))
    (check-equal? unmatched '())
    (define fs (pdf-form-fields out))
    (check-equal? (value-of fs "applicant") "Arun Patel")
    (check-equal? (value-of fs "reference") "ACME-2026-0042")
    (check-equal? (value-of fs "region") "apac")
    ;; the checkbox's on-state is the /AP key, which for this form is Yes
    (check-not-equal? (value-of fs "urgent") #f))

  ;; THE REASON THE UNMATCHED LIST IS COMPUTED HERE. pdfcpu takes a field name no
  ;; field carries, writes the output and exits 0 — so a caller who misspells one
  ;; would otherwise be handed a document that looks filled with nothing saying
  ;; which half of their request was ignored.
  (test-case "a field the form does not have is REPORTED, and the rest still land"
    (define-values (out unmatched)
      (pdf-form-fill (acroform-pdf)
                     (hasheq 'applicant "Arun Patel" 'middle_name "Q" 'birth_place "Pune")))
    (check-equal? unmatched '("birth_place" "middle_name"))
    (check-equal? (value-of (pdf-form-fields out) "applicant") "Arun Patel"))

  ;; …and every name wrong is a refusal rather than a report, because a report is
  ;; no use to somebody addressing the wrong document (CLS-15's shape: the
  ;; refusal lists what IS on offer).
  (test-case "every field wrong is refused, and the refusal lists the form's own fields"
    (check-exn #rx"none of the fields given.*applicant"
               (lambda () (pdf-form-fill (acroform-pdf) (hasheq 'nope "x" 'also_nope "y")))))

  (test-case "a document with no form is refused by name, not filled with nothing"
    (check-exn #rx"no AcroForm fields"
               (lambda () (pdf-form-fill (plain-pdf) (hasheq 'applicant "x")))))

  (test-case "no values at all is refused"
    (check-exn #rx"no values" (lambda () (pdf-form-fill (acroform-pdf) (hasheq)))))

  ;; ---- 4. a value is held to its field's kind ----------------------------------
  (test-case "a checkbox takes a boolean and a text field takes text"
    (check-exn #rx"checkbox and takes true or false"
               (lambda () (pdf-form-fill (acroform-pdf) (hasheq 'urgent "yes"))))
    (check-exn #rx"takes text"
               (lambda () (pdf-form-fill (acroform-pdf) (hasheq 'applicant 42)))))

  ;; A choice field's options are known, so a value outside them is a typo this
  ;; tool can see — and one it must not write, because a /V the form's own reader
  ;; cannot interpret renders as blank while the document says it was filled.
  (test-case "a choice field takes one of ITS OWN options, and the refusal names them"
    (check-exn #rx"not an option of the field region.*amer, emea, apac"
               (lambda () (pdf-form-fill (acroform-pdf) (hasheq 'region "antarctica")))))

  (test-case "a read-only field is refused rather than silently skipped"
    (check-exn #rx"read-only"
               (lambda () (pdf-form-fill (acroform-pdf #:lock-reference? #t)
                                         (hasheq 'reference "ACME-1")))))

  ;; A property of the FORM, not of the request, so the message has to say which:
  ;; a checkbox with no appearance dictionary cannot be toggled by anything, and
  ;; the remedy is to fix the form.
  (test-case "a checkbox with no appearance dictionary fails by name"
    (check-exn #rx"filling this form failed"
               (lambda () (pdf-form-fill (acroform-pdf #:checkbox-ap? #f)
                                         (hasheq 'urgent #t)))))

  ;; ---- 5. flattening -----------------------------------------------------------
  (when have-qpdf?
    (test-case "flattening leaves no fields and puts the values in the page content"
      (define-values (out unmatched)
        (pdf-form-fill (acroform-pdf)
                       (hasheq 'applicant "Arun Patel" 'reference "ACME-2026-0042")
                       #:flatten? #t))
      (check-equal? unmatched '())
      ;; the acceptance criterion, both halves: nothing is editable any more…
      (check-equal? (pdf-form-fields out) '())
      ;; …AND THE VALUES ARE STILL THERE, which is the half that says flattening
      ;; did not simply delete the fields. The page content is compressed, so it
      ;; has to be decompressed to be read: dropping this assertion because the
      ;; literal is not findable in the raw bytes would leave the case passing
      ;; against a version that threw the answers away.
      (define plain (uncompressed out))
      (check-true (regexp-match? #rx#"Arun Patel" plain)
                  "the filled text survives into the flattened page content")
      (check-true (regexp-match? #rx#"ACME-2026-0042" plain)
                  "…and so does the second field"))

    (test-case "an unfilled form flattens to a document with no fields"
      (define-values (out _u)
        (pdf-form-fill (acroform-pdf) (hasheq 'applicant "x") #:flatten? #t))
      (check-equal? (pdf-form-fields out) '())))

  ;; ---- 6. the bounded runner ---------------------------------------------------
  ;; Exported because what matters is what ONE run DECIDES, not when it happens —
  ;; `lease-tick!`'s rule. A tool that will not stop must not hold a request
  ;; thread for ever, and these parse somebody else's bytes.
  (test-case "a tool that will not finish is stopped, and says so"
    (define sleep-exe (find-executable-path "sleep"))
    (when sleep-exe
      (define-values (code out) (run-bounded sleep-exe '("5") #:seconds 1))
      (check-equal? code 'timeout)))

  (test-case "a tool that finishes hands back its exit code and its output"
    (define echo (find-executable-path "echo"))
    (when echo
      (define-values (code out) (run-bounded echo '("hello")))
      (check-equal? code 0)
      (check-equal? (string-trim out) "hello"))))
