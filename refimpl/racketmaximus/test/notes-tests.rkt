#lang racket/base

;; test/notes-tests.rkt — slice 5: notes CRUD through RBAC (ownership/visibility/share).
;;   raco test test/notes-tests.rkt   (with pkgs on PLTCOLLECTS)

(require rackunit
         racket/list
         db-kit/portable
         db-kit/migrate
         "../domain/db/migrations.rkt"
         "db-fixture.rkt"
         "../domain/authz/authz.rkt"
         "../domain/notes/notes.rkt")

(define (fresh) (define c (fresh-db #:migrate? #f)) (migrate! c all-migrations) c)

(define (scenario)
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice"))
  (define bob   (create-user! c #:username "bob"))
  (define carol (create-user! c #:username "carol"))
  (define dave  (create-user! c #:username "dave"))
  (define t (create-team! c #:name "T" #:slug "t"))
  (add-member! c #:user bob   #:team t #:role "member")
  (add-member! c #:user carol #:team t #:role "member")
  (add-member! c #:user dave  #:team t #:role "viewer")
  (values c (hasheq 'tid tid 'bob bob 'carol carol 'dave dave 't t)))

(define (ids-of notes) (map (lambda (n) (hash-ref n 'id)) notes))

(test-case "notes: team-visible readable by team; viewer can read, not create"
  (define-values (c ids) (scenario))
  (define pbob   (user-principal c (hash-ref ids 'bob)   (hash-ref ids 't)))
  (define pcarol (user-principal c (hash-ref ids 'carol) (hash-ref ids 't)))
  (define pdave  (user-principal c (hash-ref ids 'dave)  (hash-ref ids 't)))
  (define n (notes-create c pbob #:title "Team note" #:visibility "team"))
  (check-true (and (member (hash-ref n 'id) (ids-of (notes-list c pcarol))) #t))
  (check-equal? (hash-ref (notes-get c pcarol (hash-ref n 'id)) 'title) "Team note")
  (check-true (and (notes-get c pdave (hash-ref n 'id)) #t))               ; viewer reads
  (check-exn exn:fail:forbidden? (lambda () (notes-create c pdave #:title "no"))))  ; viewer can't create

(test-case "notes: private hidden until shared; share grants only what's given"
  (define-values (c ids) (scenario))
  (define pbob   (user-principal c (hash-ref ids 'bob)   (hash-ref ids 't)))
  (define pcarol (user-principal c (hash-ref ids 'carol) (hash-ref ids 't)))
  (define n (notes-create c pbob #:title "Secret" #:visibility "private"))
  (define nid (hash-ref n 'id))
  (check-true (and (notes-get c pbob nid) #t))                             ; owner reads
  (check-false (member nid (ids-of (notes-list c pcarol))))                ; not in carol's list
  (check-exn exn:fail:forbidden? (lambda () (notes-get c pcarol nid)))     ; carol denied
  (notes-share c pbob nid #:user (hash-ref ids 'carol) #:permission "notes:read")
  (check-equal? (hash-ref (notes-get c pcarol nid) 'title) "Secret")       ; now readable
  (check-exn exn:fail:forbidden? (lambda () (notes-delete c pcarol nid)))) ; but only read was granted

(test-case "notes: owner updates + deletes own note (even without team delete perm)"
  (define-values (c ids) (scenario))
  (define pbob (user-principal c (hash-ref ids 'bob) (hash-ref ids 't)))
  (define n (notes-create c pbob #:title "Draft"))
  (define nid (hash-ref n 'id))
  (check-equal? (hash-ref (notes-update c pbob nid #:title "Final") 'title) "Final")
  (check-true (notes-delete c pbob nid))
  (check-false (notes-get c pbob nid)))
