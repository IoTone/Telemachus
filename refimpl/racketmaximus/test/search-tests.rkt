#lang racket/base

;; test/search-tests.rkt — keyword search across notes, documents, repository
;; objects and translations, RBAC-filtered.
;; raco test test/search-tests.rkt

(require rackunit
         db
         db-kit/migrate
         "../domain/db/migrations.rkt"
         "../domain/authz/authz.rkt"
         "../domain/notes/notes.rkt"
         "../domain/apps/search.rkt"
         "../domain/repo/repo.rkt"
         "../domain/repo/blobs.rkt"
         racket/file racket/port
         "../domain/db/id.rkt")

(define (fresh) (define c (sqlite3-connect #:database 'memory)) (migrate! c all-migrations) c)

(test-case "search matches notes + translations; RBAC filters private notes and gates translations"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice"))
  (define alice (user-principal c uid tid))
  (notes-create c alice #:title "Quarterly plan" #:body "launch the platform" #:visibility "team")
  (notes-create c alice #:title "Secret" #:body "hidden treasure" #:visibility "private")
  (query-exec c
    "INSERT INTO translations (id,team_id,owner_user_id,source_lang,target_lang,source_text,result_text) VALUES (?,?,?,?,?,?,?)"
    (new-id) tid uid "auto" "ja" "hello world" "こんにちは世界")

  (check-true (for/or ([x (in-list (search-all c alice "plan"))])
                (and (equal? (hash-ref x 'type) "note") (equal? (hash-ref x 'title) "Quarterly plan"))))
  (check-true (for/or ([x (in-list (search-all c alice "hello"))])
                (equal? (hash-ref x 'type) "translation")))

  ;; a viewer: cannot read alice's private note, and lacks chat:use → no translations
  (define bob (create-user! c #:username "bob"))
  (add-member! c #:user bob #:team tid #:role "viewer")
  (define pbob (user-principal c bob tid))
  (check-false (for/or ([x (in-list (search-all c pbob "hidden"))]) (equal? (hash-ref x 'title) "Secret")))
  (check-equal? (length (search-all c pbob "hello")) 0))


;; A repository object must be findable by its path, and must obey the SAME
;; visibility rules a note does — before this, uploading a PDF made it invisible to
;; search while an identically-named text document was findable.
(test-case "search finds repository objects, and respects who may read them"
  (define root (make-temporary-file "telemachus-search-blobs-~a" 'directory))
  (current-blob-root root)
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice"))
  (define alice (user-principal c uid tid))
  (define bob-id (create-user! c #:username "bob"))
  (add-member! c #:user bob-id #:team tid #:role "member")
  (define bob (user-principal c bob-id tid))

  (repo-put! c alice #:key "reports/quarterly-plan.pdf" #:port (open-input-bytes #"%PDF-1.7 body")
             #:content-type "application/pdf" #:filename "quarterly-plan.pdf"
             #:visibility "team")
  (repo-put! c alice #:key "hr/salaries.xlsx" #:port (open-input-bytes #"secret numbers")
             #:content-type "application/vnd.ms-excel" #:filename "salaries.xlsx"
             #:visibility "private")

  ;; found by path…
  (check-true (for/or ([x (in-list (search-all c alice "quarterly"))])
                (and (equal? (hash-ref x 'type) "file")
                     (equal? (hash-ref x 'title) "reports/quarterly-plan.pdf")))
              "a team-visible object is found by its key")
  ;; …and the content type is the snippet, since the bytes are opaque until extraction
  (check-true (for/or ([x (in-list (search-all c alice "quarterly"))])
                (equal? (hash-ref x 'snippet) "application/pdf")))
  ;; …and by filename, which is what a person actually remembers typing
  (check-true (for/or ([x (in-list (search-all c alice "salaries"))])
                (equal? (hash-ref x 'type) "file"))
              "the owner finds their own private object")

  ;; a colleague sees the team-visible one and NOT the private one
  (check-true (for/or ([x (in-list (search-all c bob "quarterly"))]) (equal? (hash-ref x 'type) "file")))
  (check-false (for/or ([x (in-list (search-all c bob "salaries"))]) (equal? (hash-ref x 'type) "file"))
               "a private object never leaks through search")

  ;; a deleted object stops being findable
  (define o (repo-get c alice "reports/quarterly-plan.pdf" #:by-key tid))
  (repo-delete! c alice (hash-ref o (quote id)))
  (check-false (for/or ([x (in-list (search-all c alice "quarterly"))]) (equal? (hash-ref x 'type) "file"))
               "a deleted object is not a search hit")
  (delete-directory/files root #:must-exist? #f))
