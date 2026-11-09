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

;; ---- P1: a note's visibility is a CLOSED vocabulary -----------------------
;;
;; `notes-create` and `notes-update` took the value verbatim, and
;; `resource-reachable?` ended on `[else #t]` — so `"privte"` was stored and then
;; answered "team-visible" about a word nothing defines. A note intended as
;; private was readable by every colleague, and the estimate that the value was
;; private came from the person who typed it. `repo.rkt` validated the same
;; vocabulary on the same kind of resource, one module away; this is the same
;; check, from the one home both now read.
(test-case "notes: an unknown visibility is REFUSED, on create and on update"
  (define-values (c ids) (scenario))
  (define pbob (user-principal c (hash-ref ids 'bob) (hash-ref ids 't)))
  (define pcarol (user-principal c (hash-ref ids 'carol) (hash-ref ids 't)))
  (define before (length (ids-of (notes-list c pbob))))
  ;; a typo, and the value a capitalising client sends — both are words nothing
  ;; defines, and both used to be stored
  (check-exn exn:fail:user? (lambda () (notes-create c pbob #:title "typo" #:visibility "privte")))
  (check-exn exn:fail:user? (lambda () (notes-create c pbob #:title "case" #:visibility "Private")))
  ;; a refusal changes NOTHING: no row, no tag rows, no link rows
  (check-equal? (length (ids-of (notes-list c pbob))) before)
  ;; …and the same on the update path, where the value was written before any
  ;; validation at all
  (define n (notes-create c pbob #:title "Real" #:body "[[Other]]" #:format "org"))
  (define nid (hash-ref n 'id))
  (check-exn exn:fail:user?
             (lambda () (notes-update c pbob nid #:title "Changed" #:visibility "privte")))
  (define after (notes-get c pbob nid))
  (check-equal? (hash-ref after 'visibility) "team")     ; unchanged
  (check-equal? (hash-ref after 'title) "Real")          ; and so is the title beside it
  (check-true (and (notes-get c pcarol nid) #t)))

;; The writers now refuse one, so the only way a row carries an unknown value is
;; a database written by another build (or by hand). `authz.rkt`'s fallthrough
;; used to answer "team-visible" for exactly that case — a word the running build
;; cannot interpret opening a note to the whole team. It fails SHUT now, and the
;; stylised row below is the state only that path can produce.
(test-case "authz: a stored visibility nothing recognises is reachable by nobody"
  (define-values (c ids) (scenario))
  (define pbob   (user-principal c (hash-ref ids 'bob)   (hash-ref ids 't)))
  (define pcarol (user-principal c (hash-ref ids 'carol) (hash-ref ids 't)))
  (define nid "n-unknown-vis")
  (query-exec c
    (string-append "INSERT INTO notes (id, team_id, owner_user_id, visibility, title, body) "
                   "VALUES (?, ?, ?, ?, ?, ?)")
    nid (hash-ref ids 't) (hash-ref ids 'bob) "privte" "Stored by another build" "")
  (check-true (and (notes-get c pbob nid) #t))              ; the owner still reaches it
  (check-exn exn:fail:forbidden? (lambda () (notes-get c pcarol nid)))
  (check-false (member nid (ids-of (notes-list c pcarol)))))
