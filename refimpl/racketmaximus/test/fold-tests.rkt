#lang racket/base

;; test/fold-tests.rkt — migration 0022, the DOC-14 fold, run against a database
;; that actually contains pre-fold documents. The other suites all start from a
;; fresh schema where the fold has nothing to do; this one builds the OLD world
;; first — rows in `documents`, a share grant against them — applies the migration,
;; and asserts nothing was lost:
;;
;;   * the object keeps the DOCUMENT'S id, so grants and client references survive
;;   * the title rides in the version's filename, verbatim, weird characters and all
;;   * the body round-trips byte-for-byte through the blob store
;;   * the text is searchable the moment the migration ends — no workflow needed
;;   * visibility and the share grant still hold: the shared user reads, others do not
;;   * the table is gone, and the shim serves the same data through the old API

(require rackunit db-kit/portable
         racket/file racket/list racket/string racket/port
         db-kit/migrate
         "../domain/db/migrations.rkt"
         "db-fixture.rkt"
         "../domain/db/id.rkt"
         "../domain/authz/authz.rkt"
         "../domain/repo/blobs.rkt"
         "../domain/repo/repo.rkt"
         "../domain/documents/documents.rkt"
         "../domain/apps/search.rkt")

(define BLOB-ROOT (make-temporary-file "telemachus-fold-blobs-~a" 'directory))
(current-blob-root BLOB-ROOT)

;; the migrations BEFORE the fold — the world as slice 54 left it
(define pre-fold
  (let loop ([ms all-migrations] [acc '()])
    (cond [(null? ms) (reverse acc)]
          [(equal? (migration-id (car ms)) "0022-fold-documents") (reverse acc)]
          [else (loop (cdr ms) (cons (car ms) acc))])))

(test-case "the fold carries every document across, losslessly"
  (define c (fresh-db #:migrate? #f))
  (migrate! c pre-fold)

  (define-values (uid tid) (bootstrap! c #:username "alice"))
  (define alice (user-principal c uid tid))
  (define bob (create-user! c #:username "bob" #:password "pw"))
  (add-member! c #:user bob #:team tid #:role "member")
  (define pbob (user-principal c bob tid))
  (define carol (create-user! c #:username "carol" #:password "pw"))
  (add-member! c #:user carol #:team tid #:role "member")
  (define pcarol (user-principal c carol tid))

  ;; the OLD world: rows in the documents table, exactly as slice 26 wrote them
  (define (old-doc! id title content vis)
    (query-exec c
      (string-append "INSERT INTO documents (id, team_id, owner_user_id, visibility, title, content) "
                     "VALUES (?, ?, ?, ?, ?, ?)")
      id tid uid vis title content))
  (define plan-id (new-id))
  (define secret-id (new-id))
  (define odd-id (new-id))
  (old-doc! plan-id "Quarterly Plan" "launch the platform in autumn" "team")
  (old-doc! secret-id "Salary Bands" "the walrus number is 90000" "private")
  (old-doc! odd-id "  Ünïcode / slashes & <tags>!  " "" "team")   ; hostile title, EMPTY body
  ;; a pre-fold share: alice shared the private doc with bob (not carol)
  (grant! c #:resource-type "documents" #:resource-id secret-id
          #:principal-type "user" #:principal-id bob #:permission "files:read")

  ;; ---- the fold ----------------------------------------------------------------
  (migrate! c all-migrations)
  (check-exn exn:fail? (lambda () (query-value c "SELECT COUNT(*) FROM documents"))
             "the documents table is gone")

  ;; identity survives: the object IS the document, same id
  (define o (repo-get c alice plan-id))
  (check-true (and o #t) "the object kept the document's id")
  (check-equal? (hash-ref o 'filename) "Quarterly Plan" "the title rides in filename")
  (check-equal? (hash-ref o 'content_type) "text/markdown")
  (check-true (string-prefix? (hash-ref o 'key) "documents/quarterly-plan-")
              "the key is a readable slug")

  ;; the body round-trips through the blob store
  (define-values (_o in) (repo-open c alice plan-id))
  (check-equal? (port->string in) "launch the platform in autumn")
  (close-input-port in)

  ;; …including the empty one with the hostile title
  (define odd (repo-get c alice odd-id))
  (check-equal? (hash-ref odd 'filename) "  Ünïcode / slashes & <tags>!  "
                "the title is preserved verbatim — the SLUG is sanitized, not the title")
  (check-equal? (hash-ref odd 'size) 0 "an empty body folds as an empty blob")
  (check-true (regexp-match? #px"^documents/[a-z0-9-]+-[0-9a-f]{8}\\.md$" (hash-ref odd 'key))
              "a hostile title still yields a clean key")

  ;; searchable the moment the migration ends — no indexing workflow required
  (define hit (findf (lambda (x) (equal? (hash-ref x 'type) "document"))
                     (search-all c alice "autumn")))
  (check-true (and hit #t) "content matches immediately after the fold")
  (check-equal? (hash-ref hit 'title) "Quarterly Plan" "presented by its human title")

  ;; visibility and the grant both survived the type move
  (check-equal? (hash-ref (documents-get c pbob secret-id) 'content)
                "the walrus number is 90000"
                "the pre-fold share still admits bob")
  (check-exn exn:fail:forbidden? (lambda () (documents-get c pcarol secret-id))
             "carol was never granted access, and still is not")
  (check-false (for/or ([x (in-list (search-all c pcarol "walrus"))])
                 (member (hash-ref x 'type) '("document" "file")))
               "a private folded document does not leak through search either")

  ;; the shim serves the same data through the old API shape
  (define listing (documents-list c alice))
  (check-equal? (length (hash-ref listing 'documents)) 3)
  (define via-shim (findf (lambda (d) (equal? (hash-ref d 'id) plan-id))
                          (hash-ref listing 'documents)))
  (check-equal? (hash-ref via-shim 'title) "Quarterly Plan")
  (check-equal? (hash-ref via-shim 'content) "launch the platform in autumn")

  ;; …and an edit through the shim now VERSIONS, which the old table never did
  (documents-update c alice plan-id #:content "launch the platform in winter")
  (check-equal? (hash-ref (documents-get c alice plan-id) 'content)
                "launch the platform in winter")
  (define vs (repo-versions c alice plan-id))
  (check-equal? (length vs) 2 "the edit is a new version; the old body survives")
  (disconnect c))

(delete-directory/files BLOB-ROOT #:must-exist? #f)
