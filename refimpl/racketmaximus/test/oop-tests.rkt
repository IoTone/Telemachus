#lang racket/base

;; test/oop-tests.rkt — sandboxed out-of-process plugins: registration, the
;; capability API, and its double gate (declared scope ∩ caller RBAC).
;; Uses the real example plugin (oop-plugins/notes-helper).  raco test test/oop-tests.rkt

(require rackunit net/base64
         (only-in "../config.rkt" max-upload-bytes)
         racket/runtime-path
         racket/file
         json
         db-kit/portable
         db-kit/migrate
         "../domain/oop/host.rkt"
         "../domain/agent/registry.rkt"
         "../domain/agent/run.rkt"           ; dispatch-tool
         "../domain/notes/notes.rkt"
         "../domain/repo/blobs.rkt"
         "../domain/repo/repo.rkt"
         "../domain/db/migrations.rkt"
         "db-fixture.rkt"
         "../domain/authz/authz.rkt")

(define-runtime-path helper "../oop-plugins/notes-helper/main.rkt")
(define-runtime-path reader "../oop-plugins/doc-reader/main.rkt")
;; blobs go to a temp dir, never the checkout's data/
(define BLOB-ROOT (make-temporary-file "tmx-oop-blobs-~a" 'directory))
(current-blob-root BLOB-ROOT)
(define (fresh) (define c (fresh-db #:migrate? #f)) (migrate! c all-migrations) c)

(define (write-cfg path)
  (call-with-output-file path #:exists 'replace
    (lambda (o) (write-json (hasheq 'plugins (list (hasheq 'name "notes-helper" 'command "racket"
                                                           'args (list (path->string helper))))) o))))

(test-case "oop plugin: registers a tool, runs out-of-process, saves a note via the capability API"
  (define conn (fresh))
  (define-values (uid tid) (bootstrap! conn #:username "alice"))
  (define alice (user-principal conn uid tid))
  (define cfg (make-temporary-file "tmx-oop-~a.json"))
  (write-cfg cfg)
  (connect-oop-plugins! cfg)
  (define t (tool-by-name "oop__notes-helper__save_idea"))
  (check-true (and t #t))
  (check-equal? (tool-source t) "oop:notes-helper")
  (check-true (for/or ([pl (in-list (loaded-oop-plugins))]) (equal? (hash-ref pl 'name) "notes-helper")))
  ;; dispatch the plugin tool → it asks the host to create a note; the note appears
  (define out (dispatch-tool conn alice "oop__notes-helper__save_idea" (hasheq 'idea "ship telemachus")))
  (check-regexp-match #rx"Saved your idea as private note" out)
  (check-true (for/or ([n (in-list (notes-list conn alice))])
                (and (string=? (hash-ref n 'body) "ship telemachus")
                     (string=? (hash-ref n 'visibility) "private"))))
  (delete-file cfg))

(test-case "oop capability API: double gate — declared scope ∩ caller RBAC"
  (define conn (fresh))
  (define-values (uid tid) (bootstrap! conn #:username "alice"))
  (define alice (user-principal conn uid tid))                 ; has notes:write
  (define dave (create-user! conn #:username "dave"))
  (add-member! conn #:user dave #:team tid #:role "viewer")    ; read-only
  (define pdave (user-principal conn dave tid))
  ;; scope declared + caller authorized → runs
  (check-true (hash-has-key? (run-capability '("notes:write") conn alice "notes.create" (hasheq 'title "T" 'body "B")) 'ok))
  ;; plugin never declared the scope → denied even for a privileged caller
  (check-regexp-match #rx"not granted scope"
                      (hash-ref (run-capability '() conn alice "notes.create" (hasheq 'body "B")) 'error))
  ;; caller lacks the RBAC permission → denied even though the plugin declared the scope
  (check-regexp-match #rx"permission denied"
                      (hash-ref (run-capability '("notes:write") conn pdave "notes.create" (hasheq 'body "B")) 'error))
  ;; capability not in the host's whitelist → denied
  (check-regexp-match #rx"unknown capability"
                      (hash-ref (run-capability '("anything") conn alice "shell.exec" (hasheq)) 'error)))

;; ---- LAY-6: the repository capabilities -----------------------------------------
;; An out-of-process plugin could reach notes.create and notes.list and nothing
;; else, so a Python OCR or CV pipeline could read no bytes and write no result,
;; while an in-process Racket tool read blobs freely. The asymmetry was the bug.

(define (b64->string s) (bytes->string/utf-8 (base64-decode (string->bytes/utf-8 s))))
(define (string->b64 s) (bytes->string/utf-8 (base64-encode (string->bytes/utf-8 s) #"")))

(test-case "the repository capabilities exist and are listed"
  (check-equal? (capability-names) '("notes.create" "notes.list" "repo.get" "repo.put" "repo.text")))

(test-case "repo.get returns the bytes; repo.text returns the text"
  (define conn (fresh))
  (define-values (uid tid) (bootstrap! conn #:username "alice"))
  (define alice (user-principal conn uid tid))
  (define o (repo-put! conn alice #:key "notes/field.md" #:port (open-input-string "levee 7 looks sound")
                       #:content-type "text/markdown" #:filename "field.md"))
  (define got (run-capability '("files:read") conn alice "repo.get" (hasheq 'object (hash-ref o 'id))))
  (check-true (hash-has-key? got 'ok) (format "~a" got))
  (define r (hash-ref got 'ok))
  (check-equal? (b64->string (hash-ref r 'bytes_b64)) "levee 7 looks sound")
  (check-equal? (hash-ref r 'key) "notes/field.md")
  (define txt (hash-ref (run-capability '("files:read") conn alice "repo.text" (hasheq 'object (hash-ref o 'id))) 'ok))
  (check-equal? (hash-ref txt 'text) "levee 7 looks sound")
  (check-equal? (hash-ref txt 'reason) 'null)
  (disconnect conn))

(test-case "the double gate: the plugin's declared scope AND the caller's permission"
  (define conn (fresh))
  (define-values (uid tid) (bootstrap! conn #:username "alice"))
  (define alice (user-principal conn uid tid))
  (define o (repo-put! conn alice #:key "a.txt" #:port (open-input-string "x") #:content-type "text/plain"))
  ;; a plugin that never declared files:read
  (check-true (regexp-match? #rx"not granted scope"
    (hash-ref (run-capability '("notes:write") conn alice "repo.get" (hasheq 'object (hash-ref o 'id))) 'error)))
  ;; a caller who lacks the permission, even though the plugin declared it
  (define bob (create-user! conn #:username "bob"))
  (add-member! conn #:user bob #:team tid #:role "viewer")       ; *:read — no files:write
  (define pb (user-principal conn bob tid))
  (check-true (regexp-match? #rx"permission denied"
    (hash-ref (run-capability '("files:write") conn pb "repo.put"
                              (hasheq 'key "b.txt" 'bytes_b64 (string->b64 "hi"))) 'error)))
  (disconnect conn))

(test-case "repo.put derived from a source inherits its visibility and records provenance"
  (define conn (fresh))
  (define-values (uid tid) (bootstrap! conn #:username "alice"))
  (define alice (user-principal conn uid tid))
  (define src (repo-put! conn alice #:key "scan.pdf" #:port (open-input-string "%PDF-fake")
                         #:content-type "application/pdf" #:visibility "private"))
  (define out (hash-ref (run-capability '("files:write") conn alice "repo.put"
                          (hasheq 'key "scan.pdf.read.txt" 'content_type "text/plain"
                                  'bytes_b64 (string->b64 "recovered text")
                                  'derived_from (hash-ref src 'id))) 'ok))
  (check-equal? (hash-ref out 'derived_from) (hash-ref src 'id))
  ;; a derived document is private from its first byte — the source's visibility,
  ;; then the grants, in that order
  (define o (repo-get conn alice (hash-ref out 'object_id)))
  (check-equal? (hash-ref o 'visibility) "private")
  (check-true (for/or ([d (in-list (repo-derivations conn alice (hash-ref out 'object_id)))])
                (equal? (hash-ref d 'source_object_id #f) (hash-ref src 'id)))
              "the derivation row is what makes the provenance answerable")
  (disconnect conn))

(test-case "a plugin cannot move more past the ceiling than the front door allows"
  (define conn (fresh))
  (define-values (uid tid) (bootstrap! conn #:username "alice"))
  (define alice (user-principal conn uid tid))
  (define huge (make-string (+ (max-upload-bytes) 16) #\x))
  (check-true (regexp-match? #rx"over the"
    (hash-ref (run-capability '("files:write") conn alice "repo.put"
                              (hasheq 'key "big.txt" 'bytes_b64 (string->b64 huge))) 'error)))
  (disconnect conn))

(test-case "the worked example reads a document and files a derived one, out of process"
  (define conn (fresh))
  (define-values (uid tid) (bootstrap! conn #:username "alice"))
  (define alice (user-principal conn uid tid))
  (define o (repo-put! conn alice #:key "survey.md" #:port (open-input-string "crack width 0.8mm")
                       #:content-type "text/markdown"))
  (define cfg (make-temporary-file "tmx-oop-~a.json"))
  (call-with-output-file cfg #:exists 'replace
    (lambda (out) (write-json (hasheq 'plugins (list (hasheq 'name "doc-reader" 'command "racket"
                                                             'args (list (path->string reader))))) out)))
  (connect-oop-plugins! cfg)
  (define t (tool-by-name "oop__doc-reader__read_document"))
  (check-true (and t #t) "the plugin registered its tool")
  (define said (dispatch-tool conn alice "oop__doc-reader__read_document" (hasheq 'object (hash-ref o 'id))))
  (check-true (regexp-match? #rx"Filed 17 characters" said) said)
  ;; and the derived document is really in the repository
  (check-true (for/or ([x (in-list (repo-list conn alice))]) (equal? (hash-ref x 'key) "survey.md.read.txt"))
              "the plugin wrote through the host, with no database handle of its own")
  (delete-file cfg)
  (disconnect conn))
