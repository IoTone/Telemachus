#lang racket/base

;; test/note-template-tests.rkt — a note may be marked as a template.
;;
;;   raco test test/note-template-tests.rkt
;;   DATABASE_URL="postgres://…" raco test test/note-template-tests.rkt
;;
;; A template is an ordinary note with a flag. What is pinned here is the flag
;; itself: it defaults to off, a request that does not mention it leaves it
;; alone, the listing can ask for either side, and the tidying lists skip it.

(require rackunit db-kit/portable
         db-kit/migrate
         "../domain/db/migrations.rkt"
         "db-fixture.rkt"
         "../domain/authz/authz.rkt"
         "../domain/notes/notes.rkt")

(define (fresh) (define c (fresh-db #:migrate? #f)) (migrate! c all-migrations) c)
(define (setup)
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "root"))
  (values c (user-principal c uid tid) tid))
(define (titles ns) (sort (map (lambda (n) (hash-ref n 'title)) ns) string<?))

(test-case "a note is not a template unless it says so, and every read reports it"
  (define-values (c p tid) (setup))
  (define plain (notes-create c p #:title "Plain" #:body "x"))
  (define tpl (notes-create c p #:title "Meeting" #:body "## Agenda" #:template #t))
  (check-false (hash-ref plain 'template))
  (check-true (hash-ref tpl 'template))
  (check-true (hash-ref (notes-get c p (hash-ref tpl 'id)) 'template))
  (check-false (hash-ref (notes-get c p (hash-ref plain 'id)) 'template)))

(test-case "a note written before the column existed is an ordinary note"
  (define-values (c p tid) (setup))
  (query-exec c
    (string-append "INSERT INTO notes (id, team_id, owner_user_id, visibility, title, body) "
                   "VALUES (?, ?, ?, 'team', 'Old', 'body')")
    "old-note-1" tid (principal-user-id p))
  (check-false (hash-ref (notes-get c p "old-note-1") 'template)))

(test-case "an update that does not mention the flag leaves it alone"
  (define-values (c p tid) (setup))
  (define id (hash-ref (notes-create c p #:title "T" #:body "x" #:template #t) 'id))
  (check-true (hash-ref (notes-update c p id #:title "Renamed") 'template))
  (check-true (hash-ref (notes-update c p id #:body "new body") 'template))
  (check-false (hash-ref (notes-update c p id #:template #f) 'template))
  (check-false (hash-ref (notes-update c p id #:title "Again") 'template))
  (check-true (hash-ref (notes-update c p id #:template #t) 'template)))

(test-case "the listing and the count can ask for templates, for ordinary notes, or for both"
  (define-values (c p tid) (setup))
  (notes-create c p #:title "A" #:body "x")
  (notes-create c p #:title "B" #:body "x")
  (notes-create c p #:title "Tpl" #:body "x" #:template #t)
  (check-equal? (titles (notes-list c p)) '("A" "B" "Tpl"))
  (check-equal? (titles (notes-list c p #:template 'only)) '("Tpl"))
  (check-equal? (titles (notes-list c p #:template 'exclude)) '("A" "B"))
  (check-equal? (notes-count c p) 3)
  (check-equal? (notes-count c p #:template 'only) 1)
  (check-equal? (notes-count c p #:template 'exclude) 2))

(test-case "a private template is listed for its owner and for nobody else"
  (define-values (c owner tid) (setup))
  (define u (create-user! c #:username "bob" #:password "pw-fixture-1"))
  (add-member! c #:user u #:team tid #:role "member")
  (define bob (user-principal c u tid))
  (notes-create c owner #:title "Mine" #:body "x" #:template #t #:visibility "private")
  (notes-create c owner #:title "Ours" #:body "x" #:template #t)
  (check-equal? (titles (notes-list c owner #:template 'only)) '("Mine" "Ours"))
  (check-equal? (titles (notes-list c bob #:template 'only)) '("Ours")))

(test-case "a template is on neither tidying list, and a link to one still connects a note"
  (define-values (c p tid) (setup))
  (notes-create c p #:title "Template" #:format "org"
                #:body "see [[The note you will write]]" #:template #t)
  (notes-create c p #:title "Uses it" #:format "org" #:body "from [[Template]]")
  (notes-create c p #:title "Loner" #:body "x")
  (define T (note-tidying c p))
  (check-equal? (titles (hash-ref T 'unlinked)) '("Loner"))
  (check-equal? (hash-ref T 'broken) '())
  (check-equal? (hash-ref T 'broken_total) 0))
