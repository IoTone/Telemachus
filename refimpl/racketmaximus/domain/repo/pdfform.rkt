#lang racket/base

;; domain/repo/pdfform.rkt — the fields of a PDF form: what they are, and what a
;; caller may put in them (issue #88 requirement 2). PURE OF THE REPOSITORY, like
;; classify.rkt beside doc_classify: everything here takes and answers BYTES, so
;; the whole surface is testable with a fixture and no database, and `can?`,
;; derivation and provenance stay in doc-tools.rkt where they already live.
;;
;; TWO BINARIES, each for the half it is good at, and the split is not an
;; accident of packaging:
;;
;;   pdfcpu  — `form list --json` (discovery) and `form fill` (filling). Its
;;             export format IS a JSON document describing every field with its
;;             kind, value and options, which is exactly the shape requirement 2
;;             asks a discovery endpoint to return, and a trimmed copy of it is
;;             the fill input. Nothing has to be composed in FDF.
;;   qpdf    — `--generate-appearances --flatten-annotations=all` (flattening).
;;             pdfcpu 0.15 has no flatten of any kind; qpdf's pass builds the
;;             appearance streams a filled field needs and then draws the
;;             annotations into the page content, which is what "flattened"
;;             means to everybody downstream.
;;
;; Both are looked up with `find-executable-path` at CALL time — DWF-6's rule for
;; pandoc and tectonic — so a box with neither still boots and every other tool
;; keeps working; the failure is a named error on the one call that asked. And
;; they are looked up SEPARATELY: a box with pdfcpu and no qpdf can fill a form
;; perfectly well, and only `flatten: true` is refused there.

(provide FORM-FIELD-KINDS CHOICE-KINDS TEXT-KINDS
         PDF-TOOL-SECONDS MAX-FORM-FIELDS
         pdfcpu-path qpdf-path
         pdf-form-fields pdf-form-fill
         run-bounded)

(require racket/string racket/list racket/file racket/port racket/system
         json)

;; The kinds pdfcpu's export can name. CLOSED, and the test pins the list
;; (vocabulary-tests' rule: a closed vocabulary somebody adds to in passing is
;; not closed). A kind outside it is refused by name rather than filled as text —
;; a signature or a push button is not a value this tool can set, and writing one
;; as a string would produce a document that looks filled and is not.
(define TEXT-KINDS '("textfield" "datefield"))
(define CHOICE-KINDS '("radiobuttongroup" "combobox" "listbox"))
(define FORM-FIELD-KINDS (append TEXT-KINDS '("checkbox") CHOICE-KINDS))

;; A form with more fields than this is refused before anything runs. The cap is
;; the platform's, as EXTRACT-CAP is: this is a tool for filling a form somebody
;; designed, not for walking a pathological one.
(define MAX-FORM-FIELDS 500)

;; A hostile or merely broken PDF can keep a parser busy, and these run on the
;; request path. `render-pdf` has no bound and that is a gap named in CLAUDE.md
;; rather than fixed here — it is pandoc's and tectonic's, and tectonic
;; legitimately spends a minute fetching TeX packages on a cold cache.
(define PDF-TOOL-SECONDS 60)

(define (pdfcpu-path) (find-executable-path "pdfcpu"))
(define (qpdf-path) (find-executable-path "qpdf"))

;; ---- running one of them -------------------------------------------------------
;; -> (values exit-code-or-'timeout combined-output)
;;
;; stdout and stderr are drained by their own threads into their own ports: one
;; port written by two threads interleaves, and NOT draining at all deadlocks the
;; moment a tool says more than a pipe buffer holds — which the verbose failure
;; messages here do.
(define (run-bounded exe args #:seconds [secs PDF-TOOL-SECONDS])
  (define-values (sp sout sin serr) (apply subprocess #f #f #f exe args))
  (close-output-port sin)
  (define o (open-output-string))
  (define e (open-output-string))
  (define t1 (thread (lambda () (copy-port sout o))))
  (define t2 (thread (lambda () (copy-port serr e))))
  (define finished (sync/timeout secs sp))
  (define (text) (string-trim (string-append (get-output-string o) "\n" (get-output-string e))))
  (cond
    [finished
     (sync t1) (sync t2)
     (close-input-port sout) (close-input-port serr)
     (values (subprocess-status sp) (text))]
    [else
     (subprocess-kill sp #t)
     (sync/timeout 2 sp)
     (kill-thread t1) (kill-thread t2)
     (close-input-port sout) (close-input-port serr)
     (values 'timeout (text))]))

;; Every pdfcpu invocation carries these two, and both matter here:
;;   -c disable  — it otherwise CREATES a configuration directory under the
;;                 server's HOME on first use. In the container HOME is /data,
;;                 the one declared volume, and under `--read-only` there is no
;;                 writable home at all.
;;   --offline   — a PDF may name a remote resource; requirement 1's sandbox says
;;                 no network, and the same answer is right for a form.
;; NOT `-q`: that suppresses stdout, which is where `form list --json` writes the
;; export — the first run of this suite reported "the form export was not a JSON
;; object" against a perfectly good PDF for exactly that reason.
(define (pdfcpu! exe . args)
  (run-bounded exe (append (list "-c" "disable" "--offline") args)))

(define (with-temp-dir proc)
  (define dir (make-temporary-file "pdfform-~a" 'directory))
  (dynamic-wind void (lambda () (proc dir))
                (lambda () (delete-directory/files dir #:must-exist? #f))))

(define (need-pdfcpu who)
  (or (pdfcpu-path)
      (error who "PDF form support needs pdfcpu on the server's PATH — the packaged wrapper carries it; a bare `racket server/main.rkt` needs it installed")))

;; ---- discovery -----------------------------------------------------------------
;; bytes -> (listof (hasheq 'name 'kind 'value 'options 'locked 'pages))
;;
;; An ordinary PDF that is not a form answers '() rather than raising: "this
;; document has no fields" is an ANSWER a discovery endpoint owes its caller, and
;; a 500 there would make every non-form document look like a broken server.
;; pdfcpu says so by failing with `no form available`, which is the one string
;; that has to be matched — a real parse failure still raises.
(define (pdf-form-fields bs #:who [who 'pdf-form-fields])
  (define exe (need-pdfcpu who))
  (with-temp-dir
    (lambda (dir)
      (define in (build-path dir "in.pdf"))
      (call-with-output-file in (lambda (o) (write-bytes bs o)))
      (define-values (code out) (pdfcpu! exe "form" "list" "--json" (path->string in)))
      (cond
        [(eq? code 'timeout)
         (error who "reading this document's form fields took longer than ~a seconds and was stopped" PDF-TOOL-SECONDS)]
        [(and (not (eqv? code 0)) (regexp-match? #rx"no form available" out)) '()]
        [(not (eqv? code 0))
         (error who "this document's form fields could not be read (pdfcpu exit ~a): ~a" code (tail-of out))]
        [else (parse-export out who)]))))

(define (tail-of s [n 400])
  (define t (string-trim s))
  (if (> (string-length t) n) (substring t (- (string-length t) n)) t))

;; pdfcpu writes `{header: …, forms: [ {textfield: [...], checkbox: [...], …} ]}`.
;; One input file is one form entry; the array exists for the `*.pdf` listing mode.
(define (parse-export out who)
  ;; pdfcpu writes progress lines to stdout beside the export, so the document is
  ;; taken from the first `{` on — `outer-json`'s rule, for the same reason.
  (define js
    (with-handlers ([exn:fail? (lambda (e) (error who "this document's form export could not be read as JSON"))])
      (define i (let loop ([k 0]) (cond [(>= k (string-length out)) #f]
                                        [(char=? (string-ref out k) #\{) k]
                                        [else (loop (add1 k))])))
      (if i (string->jsexpr (substring out i)) #f)))
  (unless (hash? js) (error who "this document's form export was not a JSON object"))
  (define forms (hash-ref js 'forms '()))
  (define form (if (and (list? forms) (pair? forms) (hash? (car forms))) (car forms) (hasheq)))
  (define rows
    (for*/list ([kind (in-list FORM-FIELD-KINDS)]
                [f (in-list (let ([v (hash-ref form (string->symbol kind) '())])
                              (if (list? v) v '())))]
                #:when (hash? f))
      (hasheq 'name (let ([n (hash-ref f 'name #f)]) (if (string? n) n (format "~a" (hash-ref f 'id ""))))
              'kind kind
              'value (hash-ref f 'value 'null)
              'options (let ([o (hash-ref f 'options #f)]) (if (list? o) o 'null))
              'locked (and (eq? (hash-ref f 'locked #f) #t) #t)
              'pages (let ([p (hash-ref f 'pages #f)]) (if (list? p) p 'null)))))
  (when (> (length rows) MAX-FORM-FIELDS)
    (error who "this document declares ~a form fields, more than the ~a this tool will work with"
           (length rows) MAX-FORM-FIELDS))
  (sort rows string<? #:key (lambda (r) (hash-ref r 'name))))

;; ---- filling -------------------------------------------------------------------
;; bytes (hash name->value) -> (values filled-bytes unmatched-names)
;;
;; THE UNMATCHED LIST IS COMPUTED HERE, and it has to be: pdfcpu accepts a field
;; name no field carries, writes the output and exits 0 — measured, not assumed.
;; So requirement 2's "reports unmatched fields" cannot be delegated to the tool,
;; and a caller who misspells a field would otherwise get a document that looks
;; filled with nothing to say it is not.
(define (pdf-form-fill bs vals
                       #:flatten? [flatten? #f]
                       #:who [who 'pdf-form-fill])
  (define exe (need-pdfcpu who))
  (define qpdf (and flatten? (or (qpdf-path)
                                 (error who "flattening needs qpdf on the server's PATH — fill without `flatten` and the fields stay editable"))))
  (define fields (pdf-form-fields bs #:who who))
  (when (null? fields)
    (error who "this document carries no AcroForm fields, so there is nothing to fill"))
  (define by-name (for/hash ([f (in-list fields)]) (values (hash-ref f 'name) f)))
  (define supplied (sort (map symbol->string (hash-keys vals)) string<?))
  (when (null? supplied) (error who "no values were given"))
  (define unmatched (for/list ([n (in-list supplied)] #:unless (hash-ref by-name n #f)) n))
  ;; Every name wrong is a caller addressing the wrong document or using the
  ;; wrong vocabulary, and a report is no use to them — so it is a refusal that
  ;; LISTS the fields the form has (CLS-15's shape). A PARTIAL match is
  ;; legitimate: filling four of nine fields now is an ordinary thing to do.
  (when (= (length unmatched) (length supplied))
    (error who "none of the fields given (~a) is on this form — it has: ~a"
           (string-join unmatched ", ")
           (string-join (map (lambda (f) (hash-ref f 'name)) fields) ", ")))
  (define matched
    (for/list ([n (in-list supplied)] #:when (hash-ref by-name n #f))
      (cons (hash-ref by-name n) (hash-ref vals (string->symbol n)))))
  (define groups (group-for-fill matched who))
  (with-temp-dir
    (lambda (dir)
      (define in (build-path dir "in.pdf"))
      (define data (build-path dir "data.json"))
      (define out (build-path dir "out.pdf"))
      (call-with-output-file in (lambda (o) (write-bytes bs o)))
      (call-with-output-file data
        (lambda (o) (write-json (hasheq 'forms (list groups)) o)))
      (define-values (code msg)
        (pdfcpu! exe "form" "fill" (path->string in) (path->string data) (path->string out)))
      (when (eq? code 'timeout)
        (error who "filling this form took longer than ~a seconds and was stopped" PDF-TOOL-SECONDS))
      (unless (and (eqv? code 0) (file-exists? out))
        ;; A checkbox with no /AP appearance dictionary cannot be toggled, and
        ;; pdfcpu says `missing entry "AP"`. It is a property of the form, not of
        ;; the request, so the message says which so somebody can fix the form.
        (error who "filling this form failed (pdfcpu exit ~a): ~a" code (tail-of msg)))
      (define filled
        (cond
          [(not flatten?) (file->bytes out)]
          [else
           (define flat (build-path dir "flat.pdf"))
           (define-values (qc qmsg)
             (run-bounded qpdf (list "--generate-appearances" "--flatten-annotations=all"
                                     (path->string out) (path->string flat))))
           (when (eq? qc 'timeout)
             (error who "flattening this form took longer than ~a seconds and was stopped" PDF-TOOL-SECONDS))
           ;; qpdf exits 3 for warnings and still writes a correct file; only a
           ;; missing output is a failure.
           (unless (file-exists? flat)
             (error who "flattening this form failed (qpdf exit ~a): ~a" qc (tail-of qmsg)))
           (file->bytes flat)]))
      (values filled unmatched))))

;; (listof (cons field value)) -> the `forms` entry pdfcpu fills from
;;
;; Each value is held to its FIELD's kind. A checkbox takes a boolean and a
;; choice field takes one of its own options — the second is what stops a typo
;; becoming a value the form's own reader cannot interpret, and it is the same
;; call CLS-5 makes about a label: the set is known, so guessing is not needed.
(define (group-for-fill matched who)
  (for/fold ([acc (hasheq)]) ([pair (in-list matched)])
    (define f (car pair))
    (define v (cdr pair))
    (define name (hash-ref f 'name))
    (define kind (hash-ref f 'kind))
    (when (hash-ref f 'locked)
      (error who "the field ~a is read-only on this form, so it cannot be filled" name))
    (define value
      (cond
        [(member kind TEXT-KINDS)
         (unless (string? v) (error who "the field ~a takes text, not ~a" name (describe v)))
         v]
        [(string=? kind "checkbox")
         (unless (boolean? v) (error who "the field ~a is a checkbox and takes true or false, not ~a" name (describe v)))
         v]
        [else
         (unless (string? v) (error who "the field ~a takes one of its options, not ~a" name (describe v)))
         (define opts (let ([o (hash-ref f 'options)]) (if (list? o) o '())))
         (unless (or (null? opts) (member v opts))
           (error who "~s is not an option of the field ~a (it offers: ~a)" v name (string-join (map (lambda (x) (format "~a" x)) opts) ", ")))
         v]))
    (define k (string->symbol kind))
    (hash-set acc k (append (hash-ref acc k '()) (list (hasheq 'name name 'value value))))))

(define (describe v)
  (cond [(eq? v 'null) "null"] [(boolean? v) "true or false"] [(number? v) "a number"]
        [(list? v) "a list"] [(hash? v) "an object"] [else "that"]))
