#lang racket/base

;; test/notes-tests.rkt — slice 5: notes CRUD through RBAC (ownership/visibility/share).
;;   raco test test/notes-tests.rkt   (with pkgs on PLTCOLLECTS)

(require rackunit
         racket/file
         racket/runtime-path
         racket/string
         racket/list
         db-kit/portable
         db-kit/migrate
         "../domain/db/migrations.rkt"
         "db-fixture.rkt"
         "../domain/authz/authz.rkt"
         "../domain/notes/notes.rkt")

(define-runtime-path notes-module "../domain/notes/notes.rkt")

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

;; ---- a delete is all or nothing -------------------------------------------
;;
;; Five statements ran as five autocommits, so a failure on the fourth left the
;; note still THERE with its tags and its grants already gone: visible to the
;; team, unfilterable by tag, and re-shareable only from scratch.
;;
;; The failure is injected by RENAMING `note_links` for the duration — one
;; statement both dialects accept, no schema duplicated in a test, and it makes
;; the third statement raise on either engine. A trigger was the first attempt
;; and worked on SQLite only: Racket's driver will not carry the plpgsql body's
;; semicolons through a prepared statement.
(define (block-note-link-deletes! c)
  (query-exec c "ALTER TABLE note_links RENAME TO tmx_blocked_note_links"))

(define (unblock-note-link-deletes! c)
  (query-exec c "ALTER TABLE tmx_blocked_note_links RENAME TO note_links"))

(define (count-where c sql . args) (apply query-value c sql args))

(test-case "notes: a delete that fails half way leaves the note and its rows intact"
  (define-values (c ids) (scenario))
  (define pbob   (user-principal c (hash-ref ids 'bob)   (hash-ref ids 't)))
  (define pcarol (user-principal c (hash-ref ids 'carol) (hash-ref ids 't)))
  ;; an org note with one link and one tag, so the trigger has a row to refuse
  ;; and the tag row has something to lose
  (define n (notes-create c pbob #:title "Doomed" #:format "org"
                          #:body "#+FILETAGS: keep\n[[Somewhere]]"))
  (define nid (hash-ref n 'id))
  (notes-share c pbob nid #:user (hash-ref ids 'carol) #:permission "notes:read")
  (block-note-link-deletes! c)
  (check-exn exn:fail? (lambda () (notes-delete c pbob nid)))
  (unblock-note-link-deletes! c)
  ;; the note survived — and so did every row the earlier statements had already
  ;; removed, which is the half a five-autocommit version lost
  (check-true (and (notes-get c pbob nid) #t))
  (check-equal? (count-where c "SELECT COUNT(*) FROM note_tags WHERE note_id = ?" nid) 1)
  (check-equal? (count-where c (string-append "SELECT COUNT(*) FROM resource_grants "
                                              "WHERE resource_type = 'notes' AND resource_id = ?")
                             nid)
                1)
  (check-equal? (hash-ref (notes-get c pcarol nid) 'title) "Doomed")   ; the grant still works
  ;; …and a delete that does land takes all five with it
  (check-true (notes-delete c pbob nid))
  (check-false (notes-get c pbob nid))
  (check-equal? (count-where c "SELECT COUNT(*) FROM note_tags WHERE note_id = ?" nid) 0)
  (check-equal? (count-where c (string-append "SELECT COUNT(*) FROM resource_grants "
                                              "WHERE resource_type = 'notes' AND resource_id = ?")
                             nid)
                0))

;; ---- one spelling for "who may read a note" -------------------------------
;;
;; The predicate was written three times in one module — inline in notes-list's
;; `#:when`, as a local `readable?` inside note-graph, and again in the links
;; section — so a change to how a share reaches a note had three places to land
;; and one of them was a comprehension clause. The behaviour is unchanged by
;; collapsing them, which is exactly why it needs a gate: nothing else can tell
;; a fourth copy from the third.
(test-case "notes: the read predicate is spelled once"
  ;; comment lines are stripped: this file's own prose names the rule, and a scan
  ;; that reads its own comments reports what it was told to look for (the
  ;; vocabulary gate paid for that once already)
  (define code
    (for/list ([l (in-list (string-split (file->string notes-module) "\n"))]
               #:unless (regexp-match? #px"^\\s*;" l))
      l))
  (check-equal? (length (filter (lambda (l) (regexp-match? #px"[(]can[?] conn p \"notes:read\"" l)) code))
                1
                "one `can? … \"notes:read\"` in the module, and it is readable-note?"))
