#lang racket/base

;; test/note-tags-tests.rkt — tags on a note (issue #245), decisions TAG-1…8.
;;
;; Notes were the last ownable resource in this tree with no structure at all:
;; documents have keys, versions, LAY-4 attributes and a derived folder list, and
;; a note had a title, a body and a visibility. #245 asks for tags a person adds
;; and tags the model proposes, which is the same question #239 answered for the
;; other table — so it is answered the same way: the tag list is DERIVED from the
;; tags in use, and nothing stores which tags exist.
;;
;;   raco test test/note-tags-tests.rkt
;;   DATABASE_URL="postgres://…" raco test test/note-tags-tests.rkt
;;
;; Runs whole on both dialects by design: the write path leans on
;; `ON CONFLICT (note_id, tag) DO NOTHING` and on a transaction, and neither is
;; something to take on trust from one engine.

(require rackunit db-kit/portable racket/list
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
(define (member-of c team username #:role [role "member"])
  (define u (create-user! c #:username username #:password "pw"))
  (add-member! c #:user u #:team team #:role role)
  (user-principal c u team))
(define (tags-of n) (hash-ref n 'tags '()))

;; ---- TAG-3: what a tag IS --------------------------------------------------------
(test-case "a tag is trimmed, whitespace-collapsed and lower-cased"
  ;; the KG's dedup rule rather than LAY-4's field-key?, which cannot express a
  ;; Japanese tag — and this console ships ja
  (check-equal? (tag-normalize "  Q3   Goals ") "q3 goals")
  (check-equal? (tag-normalize "INVOICE") "invoice")
  (check-equal? (tag-normalize "\tlevee\n7 ") "levee 7")
  (check-equal? (tag-normalize "予算") "予算" "a CJK tag survives intact")
  (check-equal? (tag-normalize "Überprüfung") "überprüfung" "and so does a non-ASCII case fold"))

(test-case "an unusable tag is refused BY NAME, never dropped"
  ;; a tag silently dropped is a filter that silently never matches
  (check-true (string? (tag-problem "")))
  (check-true (string? (tag-problem "   ")))
  (check-true (string? (tag-problem (string #\a #\nul #\b))) "a control character")
  (check-true (string? (tag-problem (make-string (add1 MAX-TAG-CHARS) #\x))) "over the length cap")
  (check-false (tag-problem "q3 goals"))
  (check-false (tag-problem (make-string MAX-TAG-CHARS #\x)) "exactly at the cap is fine"))

(test-case "tags-clean dedupes case-insensitively, sorts, and caps the count"
  (check-equal? (tags-clean '("Invoice" "invoice" "  INVOICE  ")) '("invoice")
                "three spellings are one tag")
  (check-equal? (tags-clean '("zebra" "apple")) '("apple" "zebra") "sorted, so the set is deterministic")
  (check-equal? (tags-clean '()) '())
  (check-exn #px"at most" (lambda () (tags-clean (for/list ([i (add1 MAX-TAGS)]) (format "t~a" i)))))
  (check-exn #px"list of strings" (lambda () (tags-clean "invoice"))
             "a bare string is a caller mistake, not one tag"))

;; ---- TAG-1/TAG-4: the write path -------------------------------------------------
(test-case "tags ride on create, and come back on every read"
  (define-values (c p tid) (setup))
  (define n (notes-create c p #:title "Q3" #:body "b" #:tags '("Planning" "q3 GOALS")))
  (check-equal? (tags-of n) '("planning" "q3 goals") "normalized and sorted on the way in")
  (check-equal? (tags-of (notes-get c p (hash-ref n 'id))) '("planning" "q3 goals"))
  (check-equal? (tags-of (car (notes-list c p))) '("planning" "q3 goals")))

(test-case "a malformed tag refuses the whole create — no untagged note is left behind"
  (define-values (c p tid) (setup))
  (check-exn #px"tag" (lambda () (notes-create c p #:title "bad" #:tags '("ok" ""))))
  (check-equal? (notes-list c p) '() "nothing was written"))

(test-case "replace is the editor's save; [] clears and #f leaves alone"
  (define-values (c p tid) (setup))
  (define id (hash-ref (notes-create c p #:title "n" #:tags '("a" "b")) 'id))
  (check-equal? (tags-of (notes-update c p id #:title "renamed")) '("a" "b")
                "#:tags absent does not touch the set")
  (check-equal? (tags-of (notes-update c p id #:tags '("c"))) '("c") "replace")
  (check-equal? (tags-of (notes-update c p id #:tags '())) '()
                "[] CLEARS — or the last tag could never be removed"))

(test-case "a refused update leaves the previous set intact"
  ;; VEC-21's order: every validation runs before anything is deleted
  (define-values (c p tid) (setup))
  (define id (hash-ref (notes-create c p #:title "n" #:tags '("keep")) 'id))
  (check-exn #px"tag" (lambda () (notes-update c p id #:tags '("fine" ""))))
  (check-equal? (note-tags c id) '("keep")))

(test-case "add never removes what somebody typed, and the cap is on the RESULT"
  (define-values (c p tid) (setup))
  (define id (hash-ref (notes-create c p #:title "n" #:tags '("mine")) 'id))
  (check-equal? (tags-of (notes-set-tags! c p id '("proposed") #:mode 'add))
                '("mine" "proposed") "TAG-6 — a proposal adds")
  (check-equal? (tags-of (notes-set-tags! c p id '("proposed") #:mode 'add))
                '("mine" "proposed") "and is idempotent, by the primary key")
  (check-equal? (tags-of (notes-set-tags! c p id '("only") #:mode 'replace)) '("only"))
  ;; 'add could otherwise walk a note past the cap one proposal at a time
  (notes-set-tags! c p id (for/list ([i MAX-TAGS]) (format "t~a" i)) #:mode 'replace)
  (check-exn #px"at most" (lambda () (notes-set-tags! c p id '("one more") #:mode 'add))))

(test-case "tagging needs notes:write on THAT note, and says so before judging the tag"
  (define-values (c p tid) (setup))
  (define bob (member-of c tid "bob"))
  (define mine (hash-ref (notes-create c p #:title "private" #:visibility "private" #:tags '("a")) 'id))
  ;; a caller who may not write it is refused on the permission, not told their
  ;; tag was malformed
  (check-exn exn:fail:forbidden? (lambda () (notes-set-tags! c bob mine '("") #:mode 'add)))
  (check-equal? (note-tags c mine) '("a")))

;; ---- TAG-5: the filter -----------------------------------------------------------
(test-case "?tag= narrows, several tags are an AND, and it cannot widen"
  (define-values (c p tid) (setup))
  (notes-create c p #:title "both"  #:tags '("q3" "risk"))
  (notes-create c p #:title "one"   #:tags '("q3"))
  (notes-create c p #:title "none"  #:tags '())
  (check-equal? (length (notes-list c p)) 3)
  ;; sorted, NOT asserted in listing order: `notes.created_at` is TEXT
  ;; CURRENT_TIMESTAMP at second resolution, so three notes written in one second
  ;; tie and come back in whatever order the engine chose. That is issue #47's
  ;; ordering key met from the other side — a position assertion here would be
  ;; testing something unspecified, and would flap rather than fail.
  (check-equal? (sort (map (lambda (n) (hash-ref n 'title)) (notes-list c p #:tags '("q3"))) string<?)
                '("both" "one"))
  (check-equal? (map (lambda (n) (hash-ref n 'title)) (notes-list c p #:tags '("q3" "risk")))
                '("both") "an AND, not an OR")
  (check-equal? (notes-list c p #:tags '("nonesuch")) '())
  (check-equal? (sort (map (lambda (n) (hash-ref n 'title)) (notes-list c p #:tags '("  Q3  "))) string<?)
                '("both" "one") "the filter is normalized like the tag it matches"))

(test-case "a filter cannot reach a note the caller could not already read"
  (define-values (c p tid) (setup))
  (define bob (member-of c tid "bob"))
  (notes-create c p #:title "mine" #:visibility "private" #:tags '("secret"))
  (check-equal? (notes-list c bob #:tags '("secret")) '()
                "asking for the tag does not open the note"))

;; ---- TAG-1/TAG-6: the derived list -----------------------------------------------
(test-case "the team's tag list is derived from the notes you can READ"
  ;; #239's PATH-6 at a second asker: a count is a count, but a tag is somebody's
  ;; words, so one readable note settles a tag
  (define-values (c p tid) (setup))
  (define bob (member-of c tid "bob"))
  (notes-create c p #:title "team"    #:visibility "team"    #:tags '("shared"))
  (notes-create c p #:title "private" #:visibility "private" #:tags '("hidden" "shared"))
  (check-equal? (notes-tag-list c p)
                (list (hasheq 'tag "hidden" 'notes 1) (hasheq 'tag "shared" 'notes 2))
                "the owner sees both, with counts")
  (check-equal? (notes-tag-list c bob) (list (hasheq 'tag "shared" 'notes 1))
                "a colleague never learns the word on a private note")
  ;; and it stops existing when its last reachable note drops it
  (define team-note (findf (lambda (n) (equal? (hash-ref n 'title) "team")) (notes-list c p)))
  (notes-set-tags! c p (hash-ref team-note 'id) '() #:mode 'replace)
  (check-equal? (notes-tag-list c bob) '() "a tag cannot be empty — it simply stops being there"))

;; ---- TAG-8 ------------------------------------------------------------------------
(test-case "a tag dies with its note"
  (define-values (c p tid) (setup))
  (define id (hash-ref (notes-create c p #:title "n" #:tags '("doomed")) 'id))
  (check-equal? (map (lambda (x) (hash-ref x 'tag)) (notes-tag-list c p)) '("doomed"))
  (check-true (notes-delete c p id))
  (check-equal? (notes-tag-list c p) '())
  (check-equal? (query-value c "SELECT COUNT(*) FROM note_tags") 0
                "the rows are gone, not merely unreachable"))
