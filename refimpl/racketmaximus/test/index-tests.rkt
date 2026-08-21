#lang racket/base

;; test/index-tests.rkt — slice 54: text extraction into the search index.
;;   raco test test/index-tests.rkt
;;
;; Two layers, deliberately separate:
;;   1. the extractors, as pure functions over bytes — including a real docx built
;;      with Racket's own zip writer, because "a docx is a zip we can open" is a
;;      claim worth a test rather than a comment
;;   2. the WHOLE PIPELINE through the real engine: upload -> run the doc-indexer
;;      workflow via the scheduler's claim path -> search finds the document by a
;;      word that appears only in its bytes. This is the slice's promise, end to end.

(require rackunit
         db
         racket/port racket/string racket/file racket/list
         file/zip
         db-kit/migrate
         "../domain/db/migrations.rkt"
         "../domain/authz/authz.rkt"
         "../domain/repo/blobs.rkt"
         "../domain/repo/repo.rkt"
         "../domain/repo/extract.rkt"
         "../domain/repo/index-tools.rkt"        ; registers the tools
         "../domain/agent/tools.rkt"             ; the rest of the catalog
         "../domain/sched/scheduler.rkt"
         "../domain/flow/run.rkt"
         "../domain/apps/search.rkt"
         (prefix-in indexer: "../plugins/doc-indexer/main.rkt"))

;; ---- fixtures -----------------------------------------------------------------
(define BLOB-ROOT (make-temporary-file "telemachus-index-blobs-~a" 'directory))
(current-blob-root BLOB-ROOT)

(define (fresh)
  (define conn (sqlite3-connect #:database 'memory))
  (migrate! conn all-migrations)
  conn)

(define (drain! conn [limit 200])
  (let loop ([n 0]) (when (and (< n limit) (process-one! conn)) (loop (add1 n)))))

;; ---- helpers ---------------------------------------------------------------------
(define DOCX-TYPE "application/vnd.openxmlformats-officedocument.wordprocessingml.document")

;; The smallest PDF that is honestly a PDF: catalog, page tree, one page, one
;; content stream drawing `text`, and a valid xref. pdftotext reads it.
(define (minimal-pdf text)
  (define stream (format "BT /F1 12 Tf 72 720 Td (~a) Tj ET" text))
  (define objs
    (list
     "1 0 obj << /Type /Catalog /Pages 2 0 R >> endobj\n"
     "2 0 obj << /Type /Pages /Kids [3 0 R] /Count 1 >> endobj\n"
     (string-append "3 0 obj << /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] "
                    "/Contents 4 0 R /Resources << /Font << /F1 5 0 R >> >> >> endobj\n")
     (format "4 0 obj << /Length ~a >> stream\n~a\nendstream endobj\n"
             (string-length stream) stream)
     "5 0 obj << /Type /Font /Subtype /Type1 /BaseFont /Helvetica >> endobj\n"))
  (define header "%PDF-1.4\n")
  (define offsets
    (for/fold ([acc (list (string-length header))] #:result (reverse (cdr acc)))
              ([o (in-list objs)])
      (cons (+ (car acc) (string-length o)) acc)))
  (define body (apply string-append header objs))
  (define xref-at (string-length body))
  (define xref
    (string-append "xref\n0 6\n0000000000 65535 f \n"
                   (apply string-append
                          (for/list ([off (in-list offsets)])
                            (format "~a 00000 n \n"
                                    (let ([s (number->string off)])
                                      (string-append (make-string (- 10 (string-length s)) #\0) s)))))
                   (format "trailer << /Size 6 /Root 1 0 R >>\nstartxref\n~a\n%%EOF" xref-at)))
  (string->bytes/utf-8 (string-append body xref)))


;; ---- 1. the extractors ----------------------------------------------------------

;; plain text: lossy decode, so one bad byte does not cost the file
(let-values ([(text reason) (extract-text (open-input-bytes #"hello \xff world") "text/plain")])
  (check-false reason)
  (check-true (and (regexp-match? #rx"hello" text) (regexp-match? #rx"world" text))
              "a bad byte costs one character, not the file"))

;; markup: tags go, words stay, script bodies go WITH their tags
(let-values ([(text reason)
              (extract-text
               (open-input-bytes #"<svg><script>alert('evil')</script><text>quarterly figures</text></svg>")
               "image/svg+xml")])
  (check-false reason)
  (check-equal? text "quarterly figures"
                "markup is stripped and a script body is not searchable text"))

;; entities unescape, whitespace collapses
(let-values ([(text _r) (extract-text (open-input-bytes #"<p>a&amp;b   c\n\nd</p>") "text/html")])
  (check-equal? text "a&b c d"))

;; docx: build a real one with the zip writer — word/document.xml inside a zip
(let ()
  (define dir (make-temporary-file "docx-~a" 'directory))
  (make-directory* (build-path dir "word"))
  (call-with-output-file (build-path dir "word" "document.xml")
    (lambda (out)
      (write-string "<w:document><w:body><w:p><w:r><w:t>synergy</w:t></w:r><w:r><w:t> report</w:t></w:r></w:p><w:p><w:r><w:t>appendix</w:t></w:r></w:p></w:body></w:document>" out)))
  (define zpath (build-path dir "d.docx"))
  (parameterize ([current-directory dir])
    (zip zpath (build-path "word" "document.xml")))
  (define-values (text reason)
    (call-with-input-file zpath (lambda (in) (extract-text in DOCX-TYPE))))
  (check-false reason)
  (check-true (regexp-match? #rx"synergy report" text) "runs in one paragraph join")
  (check-true (regexp-match? #rx"report appendix" text) "paragraph boundaries become spaces")
  (delete-directory/files dir))

;; pdf — only when pdftotext is present; the extractor must SAY SO when it is not
(if (pdftotext-available?)
    (let ()
      ;; a minimal but real PDF, one page, one text object
      (define pdf (minimal-pdf "confidential roadmap"))
      (define-values (text reason) (extract-text (open-input-bytes pdf) "application/pdf"))
      (check-false reason)
      (check-true (regexp-match? #rx"confidential roadmap" text)
                  "pdftotext extracts the words"))
    (let-values ([(text reason) (extract-text (open-input-bytes #"%PDF-1.4") "application/pdf")])
      (check-false text)
      (check-equal? reason 'missing-tool "a missing binary is named, never silent")))

;; unsupported types say so
(let-values ([(text reason) (extract-text (open-input-bytes #"\x89PNG") "image/png")])
  (check-false text)
  (check-equal? reason 'unsupported))
(check-false (extractable? "image/png"))
(check-true (extractable? "text/markdown"))
(check-true (extractable? "application/pdf"))

;; the cap holds
(let-values ([(text _r) (extract-text (open-input-bytes (make-bytes (* 2 EXTRACT-CAP) 97)) "text/plain")])
  (check-equal? (string-length text) EXTRACT-CAP))

;; ---- 2. the pipeline, end to end -------------------------------------------------
(test-case "upload -> index-documents workflow -> search finds the words"
  (define conn (fresh))
  (define-values (uid tid) (bootstrap! conn #:username "alice"))
  (define p (user-principal conn uid tid))

  ;; the workflow arrives exactly as the plugin loader delivers it
  (register-plugin-workflow! "doc-indexer" (car indexer:workflows))

  ;; three documents: two extractable, one image that must be ignored, one private
  (define (up! key bytes ct #:vis [vis "team"])
    (repo-put! conn p #:key key #:port (open-input-bytes bytes)
               #:content-type ct #:filename key #:visibility vis))
  (up! "notes/minutes.md" #"the octopus initiative is approved" "text/markdown")
  (up! "www/page.html" #"<html><body>walrus budget<script>x()</script></body></html>" "text/html")
  (up! "img/logo.png" #"\x89PNG not text" "image/png")
  ;; mislabeled: docx content-type over garbage. One bad file must not wedge the run.
  (up! "broken/fake.docx" #"this is not a zip" DOCX-TYPE)
  (up! "hr/secret.md" #"the zebra severance plan" "text/markdown" #:vis "private")

  ;; nothing is searchable by content yet…
  (check-false (for/or ([x (in-list (search-all conn p "octopus"))]) (equal? (hash-ref x 'type) "file"))
               "before indexing, content does not match")

  ;; …run the workflow through the real engine
  (define def (flow-def-by-slug conn p "index-documents"))
  (check-true (and def #t) "the plugin workflow materialized")
  (define run (flow-run-start! conn p def))
  (drain! conn)
  (define done (flow-run-get conn p (hash-ref run 'id)))
  (check-equal? (hash-ref done 'status) "done"
                (format "the run finished (error: ~a)" (hash-ref done 'error)))

  ;; the fan-out covered the three extractable objects (secret.md included — alice
  ;; owns it) and skipped the image entirely
  (define steps (hash-ref done 'steps))
  (define kids (filter (lambda (s) (regexp-match? #rx"extract#" (hash-ref s 'step_id))) steps))
  (check-equal? (length kids) 4 "four extractable-typed documents fan out; the image is skipped")
  (check-true (for/and ([k (in-list kids)]) (equal? (hash-ref k 'status) "done"))
              "the corrupt docx is recorded as processed, not raised — the run survives it")

  ;; search now matches by CONTENT, with the words as the snippet
  (define hit (findf (lambda (x) (equal? (hash-ref x 'type) "file"))
                     (search-all conn p "octopus")))
  (check-true (and hit #t) "content match")
  (check-equal? (hash-ref hit 'title) "notes/minutes.md")
  (check-true (regexp-match? #rx"octopus initiative" (hash-ref hit 'snippet))
              "the snippet shows the words around the match")
  (check-true (for/or ([x (in-list (search-all conn p "walrus"))])
                (equal? (hash-ref x 'type) "file"))
              "html content matches after tag stripping")
  (check-false (for/or ([x (in-list (search-all conn p "alert"))])
                 (equal? (hash-ref x 'type) "file"))
               "a script body is not searchable")

  ;; a colleague: sees team content, never the private document's content
  (define bob (create-user! conn #:username "bob" #:password "pw"))
  (add-member! conn #:user bob #:team tid #:role "member")
  (define pbob (user-principal conn bob tid))
  (check-true (for/or ([x (in-list (search-all conn pbob "octopus"))])
                (equal? (hash-ref x 'type) "file")))
  (check-false (for/or ([x (in-list (search-all conn pbob "zebra"))])
                 (equal? (hash-ref x 'type) "file"))
               "extraction does not leak a private document through search")

  ;; a second run finds nothing to do — the workflow is idempotent
  (define run2 (flow-run-start! conn p def))
  (drain! conn)
  (define done2 (flow-run-get conn p (hash-ref run2 'id)))
  (check-equal? (hash-ref done2 'status) "done")
  (check-equal? (length (filter (lambda (s) (regexp-match? #rx"extract#" (hash-ref s 'step_id)))
                                (hash-ref done2 'steps)))
                0 "an already-indexed team fans out over nothing — the corrupt file included")

  ;; an overwrite makes exactly that object stale, and the next run re-indexes it
  (up! "notes/minutes.md" #"the octopus initiative is cancelled" "text/markdown")
  (define run3 (flow-run-start! conn p def))
  (drain! conn)
  (define hit3 (findf (lambda (x) (equal? (hash-ref x 'type) "file"))
                      (search-all conn p "cancelled")))
  (check-true (and hit3 #t) "re-indexed after an overwrite")

  ;; deleting the object removes its text from search
  (define o (repo-get conn p "notes/minutes.md" #:by-key tid))
  (repo-delete! conn p (hash-ref o 'id))
  (check-false (for/or ([x (in-list (search-all conn p "cancelled"))])
                 (equal? (hash-ref x 'type) "file"))
               "a deleted document stops matching")
  (disconnect conn))

(delete-directory/files BLOB-ROOT #:must-exist? #f)
