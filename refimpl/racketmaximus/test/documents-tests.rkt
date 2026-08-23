#lang racket/base

;; test/documents-tests.rkt — documents CRUD, offset pagination, and RBAC.
;; raco test test/documents-tests.rkt

(require rackunit db-kit/portable
         racket/file
         db-kit/migrate
         "../domain/db/migrations.rkt"
         "db-fixture.rkt"
         "../domain/authz/authz.rkt"
         "../domain/repo/blobs.rkt"
         "../domain/documents/documents.rkt")

;; documents are repository objects now (migration 0022), so their bodies land in
;; the blob store — which must NOT be the checkout's data/ when a test writes
(define BLOB-ROOT (make-temporary-file "telemachus-doc-blobs-~a" 'directory))
(current-blob-root BLOB-ROOT)

(define (fresh) (define c (fresh-db #:migrate? #f)) (migrate! c all-migrations) c)

(test-case "documents CRUD + offset pagination + RBAC"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice"))
  (define alice (user-principal c uid tid))
  (for ([i (in-list '(1 2 3))]) (documents-create c alice #:title (format "Doc ~a" i) #:content "body" #:visibility "team"))

  (define pg (documents-list c alice #:limit 2))
  (check-equal? (length (hash-ref pg 'documents)) 2)
  (check-equal? (hash-ref pg 'next_offset) 2)
  (define pg2 (documents-list c alice #:offset 2 #:limit 2))
  (check-equal? (length (hash-ref pg2 'documents)) 1)
  (check-equal? (hash-ref pg2 'next_offset) 'null)

  (define d (car (hash-ref pg 'documents)))
  (check-equal? (hash-ref (documents-get c alice (hash-ref d 'id)) 'id) (hash-ref d 'id))
  (check-equal? (hash-ref (documents-update c alice (hash-ref d 'id) #:title "Renamed") 'title) "Renamed")
  (check-true (documents-delete c alice (hash-ref d 'id)))
  (check-false (documents-get c alice (hash-ref d 'id)))

  ;; a viewer cannot create documents
  (define bob (create-user! c #:username "bob"))
  (add-member! c #:user bob #:team tid #:role "viewer")
  (define pbob (user-principal c bob tid))
  (check-exn exn:fail:forbidden? (lambda () (documents-create c pbob #:title "x" #:content "y"))))

(delete-directory/files BLOB-ROOT #:must-exist? #f)
