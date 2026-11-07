#lang racket/base

;; test/note-page-tests.rkt — the notes listing as a PAGE.
;;
;; Reported from outside, with #245's filter already shipped: "Notes should
;; paginate and filter." The filter existed (`?tag=`, repeatable, ANDed); the
;; listing returned every note the caller could read, which on a team of any
;; size is the whole of the report. `GET /api/documents` has answered a page of
;; 20 since the fold, so the unbounded one was the anomaly.
;;
;;   raco test test/note-page-tests.rkt
;;   DATABASE_URL="postgres://…" raco test test/note-page-tests.rkt
;;
;; RUNS WHOLE ON BOTH DIALECTS BY DESIGN, and here that is not a formality: the
;; window is a `team_id IN (…)` built from a placeholder per team plus an EXISTS
;; per tag, and `db-kit/portable` rewrites `?` → `$n` IN ORDER — so an argument
;; list that does not match the clause order is invisible on SQLite's `?` and
;; fails on PostgreSQL. The two dialects also sort NULLs and compare text
;; differently, which is what an ORDER BY carrying a tiebreak has to survive.

(require rackunit db-kit/portable racket/list racket/string
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
(define (titles ns) (for/list ([n (in-list ns)]) (hash-ref n 'title)))

;; ---- the window is one home ---------------------------------------------------
;;
;; The count and the listing must agree about what is in scope, or the pager
;; offers a page the listing can never fill — LIVE-IN's shape, in the one place
;; where the symptom is a control that does nothing.
(test-case "the count is the window the listing pages over"
  (define-values (c p tid) (setup))
  (for ([i (in-range 7)]) (notes-create c p #:title (format "n~a" i)))
  (check-equal? (notes-count c p) 7)
  (check-equal? (length (notes-list c p #:limit 3 #:offset 0)) 3)
  (check-equal? (length (notes-list c p #:limit 3 #:offset 6)) 1)
  (check-equal? (length (notes-list c p #:limit 3 #:offset 7)) 0
                "past the end is empty, not an error")
  ;; `#:limit #f` is the DEFAULT and is unbounded — `notes-tag-list` derives the
  ;; team's whole tag vocabulary by walking this listing, so a default page would
  ;; silently shrink it to whatever the first page held
  (check-equal? (length (notes-list c p)) 7))

;; ---- the pages TILE, which is what the tiebreak buys -------------------------
;;
;; `created_at` is TEXT `CURRENT_TIMESTAMP` at SECOND resolution and `id` is a
;; random UUID, so every note in this fixture is written in the same second and
;; the sort has nothing but the tiebreak to settle it. Without `id DESC` the
;; engine is free to order the ties differently per query, which is how an offset
;; walk shows one note twice and never shows another at all — issue #47's rule
;; for the audit log, arriving where it first becomes observable.
;;
;; THE ASSERTION IS THAT THE UNION OF THE PAGES IS THE WHOLE SET WITH NO
;; DUPLICATE, which is the property a reader paging through actually has; a test
;; that merely compared two orderings could pass on an engine that happened to be
;; stable twice in a row.
(test-case "a walk by pages visits every note exactly once"
  (define-values (c p tid) (setup))
  (for ([i (in-range 25)]) (notes-create c p #:title (format "n~a" i)))
  (define walked
    (append*
     (for/list ([off (in-range 0 25 4)])
       (titles (notes-list c p #:limit 4 #:offset off)))))
  (check-equal? (length walked) 25 "no page was short and none overran")
  (check-equal? (length (remove-duplicates walked)) 25 "and no note was visited twice")
  (check-equal? (sort walked string<?)
                (sort (for/list ([i (in-range 25)]) (format "n~a" i)) string<?))
  ;; and the walk is the same walk twice: an unstable sort is free to disagree
  ;; with itself, so the control for the tiebreak is a repeat rather than a guess
  (check-equal? walked
                (append*
                 (for/list ([off (in-range 0 25 4)])
                   (titles (notes-list c p #:limit 4 #:offset off))))
                "two identical walks agree, which is what the tiebreak promises")
  ;; THE TIEBREAK IS NOT FALSIFIABLE BY THIS FILE ON EITHER ENGINE, AND SAYING SO
  ;; IS THE POINT. With `id DESC` removed, all five cases pass on SQLite AND on
  ;; PostgreSQL 18 — both planners sort these ties stably, so insertion order
  ;; alone cannot see the key. Nor can a write between two pages: the guess was
  ;; that an UPDATE moving a tuple to the end of PostgreSQL's heap would reshuffle
  ;; a bare `created_at DESC`, and it was measured and it does not (25 rows sort
  ;; in memory, stably). That is VEC-13's unpinnable pin — a reason to WRITE the
  ;; key down, never evidence it is redundant, because neither engine PROMISES
  ;; this and a tie whose order is an accident of the plan is one the next
  ;; release may settle differently. The case below still pins the property a
  ;; reader paging through a live list actually has.
  (define first-page (titles (notes-list c p #:limit 4 #:offset 0)))
  (notes-update c p (hash-ref (car (notes-list c p #:limit 1 #:offset 20)) 'id)
                #:body "edited mid-walk")
  (define live
    (append first-page
            (append* (for/list ([off (in-range 4 25 4)])
                       (titles (notes-list c p #:limit 4 #:offset off))))))
  (check-equal? (length (remove-duplicates live)) 25
                "a note edited between two pages is served exactly once"))

;; ---- the tag filter is in the WINDOW now -------------------------------------
;;
;; TAG-5's rule is that a filter may only NARROW what the caller was already
;; allowed to see, and that is unchanged: `can?` still runs on every row the
;; window returns, so the result set does not depend on the order the two
;; narrowing tests are applied in. What moving it into SQL buys is the only thing
;; pagination needs — a page of a tag search comes back FULL rather than being
;; whatever survived of an unfiltered page.
(test-case "a tag page is a page of matching notes, not a filtered page of all notes"
  (define-values (c p tid) (setup))
  ;; 20 notes, every fourth tagged — so an unfiltered page of 4 holds exactly one
  ;; match, and a filter applied after the window would answer pages of one
  (for ([i (in-range 20)])
    (notes-create c p #:title (format "n~a" i)
                  #:tags (if (zero? (modulo i 4)) '("keep") '())))
  (check-equal? (notes-count c p #:tags '("keep")) 5 "the count is filtered too")
  (check-equal? (length (notes-list c p #:tags '("keep") #:limit 4 #:offset 0)) 4
                "a full page of matches, which is the whole point of the move")
  (check-equal? (length (notes-list c p #:tags '("keep") #:limit 4 #:offset 4)) 1)
  ;; several tags are an AND, one EXISTS each — and the arguments have to land in
  ;; the clause order, which is the half PostgreSQL is what checks
  (notes-create c p #:title "both" #:tags '("keep" "also"))
  (check-equal? (titles (notes-list c p #:tags '("keep" "also"))) '("both"))
  (check-equal? (notes-count c p #:tags '("keep" "also")) 1)
  (check-equal? (notes-count c p #:tags '("nonesuch")) 0))

;; ---- CLS-27: a short page is NOT the last page -------------------------------
;;
;; `can?` runs per row AFTER the SQL window, so a page can come back empty with
;; notes still behind it. That is why the COUNT is the pager's authority and the
;; length of a page is not, and it is why the count is deliberately NOT filtered
;; by `can?` — `repo-count`'s precedent and its stated cost: the total may exceed
;; what the caller can ever see.
;;
;; THE FIXTURE AGES ROOT'S NOTES BY HAND, and it has to. `created_at` is TEXT
;; `CURRENT_TIMESTAMP` at second resolution, so every note a test writes shares
;; one second and the tiebreak that settles them is a RANDOM uuid — stable, which
;; is what the walk above needs, and arbitrary, so a case that assumed insertion
;; order would pass or fail on the shape of two id strings. It did: this case
;; failed on its first run for exactly that reason.
(test-case "a page emptied by a colleague's private notes still has pages behind it"
  (define-values (c p tid) (setup))
  (define bob (member-of c tid "bob"))
  (for ([i (in-range 4)]) (notes-create c p #:title (format "secret~a" i) #:visibility "private"))
  ;; older than anything bob writes, so they sort LAST under `created_at DESC`
  (query-exec c "UPDATE notes SET created_at = '2020-01-01 00:00:00' WHERE visibility = 'private'")
  (for ([i (in-range 2)]) (notes-create c bob #:title (format "mine~a" i)))
  (check-equal? (notes-count c bob) 6
                "the count is the window: six rows are there, four of them not bob's")
  (check-equal? (length (notes-list c bob #:limit 2 #:offset 0)) 2 "bob's own two")
  (check-equal? (notes-list c bob #:limit 2 #:offset 2) '()
                "a page `can?` emptied — and the count above is what says it is not the end")
  (check-equal? (length (notes-list c bob)) 2 "bob only ever sees his own two")
  ;; the count is the WINDOW and not the answer, which is the cost this inherits
  ;; from `repo-count` rather than a defect to fix here
  (check-true (> (notes-count c bob) (length (notes-list c bob)))))

;; ---- the org scope is ONE ordered query --------------------------------------
;;
;; The old shape ran an ordered query per team and appended the results, so
;; `?scope=org` came back team-by-team rather than newest-first. That was merely
;; untidy while nothing paged; an OFFSET into a list that is not globally ordered
;; names a different row on every request, so the ordering had to become real for
;; the window to mean anything.
(test-case "an org-scoped walk tiles across the company's teams"
  (define-values (c p tid) (setup))
  (define org (create-org! c #:name "Acme" #:slug "acme"))
  (define t1 (create-team! c #:name "One" #:slug "one" #:org org))
  (define t2 (create-team! c #:name "Two" #:slug "two" #:org org))
  ;; an ORG READER, which is the role `?scope=org` exists for (TEN-2h): a plain
  ;; member of both teams reads only the team it is ACTING as, so the walk below
  ;; would have been five of ten and would have been `can?` working rather than
  ;; the ordering failing. It was, on the first run.
  (define u (create-user! c #:username "reader" #:password "pw" #:org org #:org-role "org_reader"))
  (add-member! c #:user u #:team t1 #:role "member")
  (define writer (create-user! c #:username "writer" #:password "pw" #:org org))
  (add-member! c #:user writer #:team t1 #:role "member")
  (add-member! c #:user writer #:team t2 #:role "member")
  (define p1 (user-principal c u t1))
  (define w1 (user-principal c writer t1))
  (define w2 (user-principal c writer t2))
  (for ([i (in-range 5)]) (notes-create c w1 #:title (format "a~a" i)))
  (for ([i (in-range 5)]) (notes-create c w2 #:title (format "b~a" i)))
  (check-equal? (notes-count c p1 #:scope 'org) 10)
  (define walked
    (append* (for/list ([off (in-range 0 10 3)])
               (titles (notes-list c p1 #:scope 'org #:limit 3 #:offset off)))))
  (check-equal? (length (remove-duplicates walked)) 10
                "every note in the company, once — not one team's list after the other's")
  ;; AND A PAGE IS NEVER LONGER THAN ITS LIMIT, which is the half the union above
  ;; cannot see: the old per-team shape applied `LIMIT`/`OFFSET` to EACH team's
  ;; query and appended the results, so a page of 3 across two teams came back
  ;; with 6 rows and every page over-fetched while the union stayed complete.
  ;; The pager's whole arithmetic assumes `total / size` pages of `size`, so a
  ;; page that quietly doubles is a pager that offers twice as many pages as
  ;; there are. This is the assertion that control bites on.
  (for ([off (in-range 0 10 3)])
    (check-true (<= (length (notes-list c p1 #:scope 'org #:limit 3 #:offset off)) 3)
                (format "page at offset ~a is within its limit" off)))
  (check-equal? (notes-count c p1) 5 "and the team scope is still one team's"))
