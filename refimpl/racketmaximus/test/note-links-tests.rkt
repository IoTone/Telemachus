#lang racket/base

;; test/note-links-tests.rkt — the edges a note's body declares (#246 slice 2),
;; decisions ORG-6…ORG-10 and ORG-15.
;;
;;   raco test test/note-links-tests.rkt
;;   DATABASE_URL="postgres://…" raco test test/note-links-tests.rkt
;;
;; Runs whole on both dialects, and that is not a formality here: the write leans
;; on a transaction and on `CREATE UNIQUE INDEX`, and the reads lean on an
;; indexed equality over a fold computed in RACKET rather than with SQL's
;; `lower()` — which is the thing to check on both engines, since they do not
;; fold non-ASCII the same way and this console ships `ja`.
;;
;; THE TWO ASYMMETRIES ARE WHAT THIS FILE IS FOR. ORG-8 says a broken link is
;; REPORTED; ORG-9 says an unreadable one is DROPPED AND NOT REPORTED. They look
;; different on purpose, and a test that only counted edges could not tell them
;; apart.

(require rackunit db-kit/portable racket/list racket/string
         db-kit/migrate
         "../domain/db/migrations.rkt"
         "db-fixture.rkt"
         "../domain/authz/authz.rkt"
         "../domain/notes/notes.rkt"
         "../domain/notes/org-links.rkt")

(define (fresh) (define c (fresh-db #:migrate? #f)) (migrate! c all-migrations) c)
(define (setup)
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "root"))
  (values c (user-principal c uid tid) tid))
(define (member-of c team username #:role [role "member"])
  (define u (create-user! c #:username username #:password "pw"))
  (add-member! c #:user u #:team team #:role role)
  (user-principal c u team))
(define (org c p title body #:visibility [vis "team"])
  (notes-create c p #:title title #:body body #:format "org" #:visibility vis))
(define (targets ls) (sort (map (lambda (l) (hash-ref l 'target)) ls) string<?))
(define (ids ls) (sort (map (lambda (l) (hash-ref l 'note_id)) ls) string<?))

;; ---- the parser, with no database in sight ---------------------------------
(test-case "an external target creates no edge, and the scheme set is the renderer's"
  ;; ORG-6 — the graph is the team's own notes, and an external URL already has
  ;; a home that archives it (a bookmark, #191 slice 1). That narrowing is what
  ;; keeps the whole edge set inside one authorization domain.
  ;;
  ;; THESE ARE THE INPUTS THE E2E GATE HANDS THE RENDERER in §3c2, which is how
  ;; two parsers for one syntax are kept to one rule: they are in different
  ;; languages and cannot share an implementation, so what they agree about is
  ;; pinned on both sides.
  (check-equal? (org-link-targets "[[https://example.test/x][docs]]") '())
  (check-equal? (org-link-targets "[[HTTP://example.test/x]]") '())
  (check-equal? (org-link-targets "[[mailto:a@b.test][mail]]") '())
  (check-equal? (org-link-targets "[[/local/path]]") '())
  (check-equal? (org-link-targets "[[#anchor]]") '())
  ;; …and a `javascript:` target is NOT external by this rule, so it becomes an
  ;; ordinary internal target that resolves to nothing. That is the honest
  ;; answer: the renderer already refuses to make it an anchor, and inventing a
  ;; third category here would be a rule with one member.
  (check-equal? (map car (org-link-targets "[[javascript:alert(1)][click]]"))
                '("javascript:alert(1)")))

(test-case "a note's targets are deduped by FOLD, in order, keeping the first label"
  (define got (org-link-targets "[[Budget review][b]] then [[Levee 7]] then [[BUDGET   REVIEW][again]]"))
  (check-equal? (map car got) '("Budget review" "Levee 7"))
  (check-equal? (map caddr got) '("b" "") "the FIRST label is the one kept")
  ;; the fold is what matched, and it is `fold-key`'s — downcase and collapse
  (check-equal? (map cadr got) '("budget review" "levee 7")))

(test-case "a bracket or a newline cannot be smuggled into a target"
  ;; org's own rule, and it is what stops a run of links on one line from being
  ;; read as one enormous target
  (check-equal? (map car (org-link-targets "[[a]] [[b]]")) '("a" "b"))
  (check-equal? (org-link-targets "[[a\nb]]") '())
  (check-equal? (org-link-targets "[[ ]]") '() "a whitespace-only target is nothing"))

(test-case "fold-key is ONE rule with two askers"
  ;; TAG-3 argued it for a tag and #246 is the second asker, so `tag-normalize`
  ;; delegates here rather than being a second copy. The behaviour is
  ;; byte-identical, which is what `note-tags-tests.rkt` pins from the other
  ;; side.
  (for ([s '("  Q3   Goals " "INVOICE" "\tlevee\n7 ")])
    (check-equal? (tag-normalize s) (fold-key s) s)))

;; ---- only an org note has links --------------------------------------------
(test-case "a markdown note extracts nothing, and converting is what fills and clears"
  ;; `[[target][description]]` is ORG syntax. Markdown wiki-links were declined
  ;; as a product question (RG-5's parked note, which #246 answered for org and
  ;; not for Markdown), so a Markdown body carrying that text has no edges —
  ;; which is also what makes converting org → markdown clear the rows, with no
  ;; second mechanism for it.
  (define-values (c p tid) (setup))
  (define t (notes-create c p #:title "Target" #:body "x"))
  (define n (notes-create c p #:title "md" #:body "see [[Target]]"))
  (define id (hash-ref n 'id))
  (check-equal? (note-links-of c p id) '() "a markdown note has no edges")
  (notes-update c p id #:format "org")
  (check-equal? (targets (note-links-of c p id)) '("Target") "converting to org extracts")
  (notes-update c p id #:format "markdown")
  (check-equal? (note-links-of c p id) '() "…and converting back clears them")
  (close-db! c))

(test-case "editing a body replaces the edge set wholesale"
  (define-values (c p tid) (setup))
  (notes-create c p #:title "A" #:body "x")
  (notes-create c p #:title "B" #:body "x")
  (define id (hash-ref (org c p "src" "[[A]]") 'id))
  (check-equal? (targets (note-links-of c p id)) '("A"))
  (notes-update c p id #:body "[[B]]")
  (check-equal? (targets (note-links-of c p id)) '("B")
                "the body is the truth about which links it contains")
  (close-db! c))

;; ---- ORG-6: what a target resolves to --------------------------------------
(test-case "a target is a note id, or an exact case-folded title"
  (define-values (c p tid) (setup))
  (define t (notes-create c p #:title "Levee 7 Survey" #:body "x"))
  (define tid* (hash-ref t 'id))
  (define byid (org c p "by id" (format "[[~a][the one]]" tid*)))
  (define bytitle (org c p "by title" "[[  levee 7   survey ]]"))
  (define l1 (note-links-of c p (hash-ref byid 'id)))
  (check-equal? (length l1) 1)
  (check-equal? (hash-ref (car l1) 'note_id) tid*)
  (check-false (hash-ref (car l1) 'broken))
  (check-equal? (hash-ref (car l1) 'label) "the one")
  (check-equal? (hash-ref (car l1) 'title) "Levee 7 Survey"
                "the DESTINATION's title comes back, so a reader sees the note rather than the id")
  (define l2 (note-links-of c p (hash-ref bytitle 'id)))
  (check-equal? (hash-ref (car l2) 'note_id) tid* "a folded title resolves")
  (check-equal? (hash-ref (car l2) 'target) "levee 7   survey"
                "and the target comes back AS WRITTEN, which is what ORG-8 needs")
  (close-db! c))

(test-case "an ambiguous title is a broken link that SAYS it is ambiguous"
  ;; ORG-6 — titles are not unique, so picking one would make a link mean a
  ;; different note depending on which was created first. It is also why
  ;; org-roam links by id.
  (define-values (c p tid) (setup))
  (notes-create c p #:title "Survey" #:body "one")
  (define n (org c p "src" "[[Survey]]"))
  (check-false (hash-ref (car (note-links-of c p (hash-ref n 'id))) 'broken)
               "one holder of the title resolves")
  (notes-create c p #:title "survey" #:body "two")
  (define l (car (note-links-of c p (hash-ref n 'id))))
  (check-true (hash-ref l 'broken) "a second holder breaks it")
  (check-equal? (hash-ref l 'reason) "ambiguous")
  (check-equal? (hash-ref l 'target) "Survey" "with the target as written")
  (close-db! c))

;; ---- 🔑 the case that decided migration 0074's shape -----------------------
(test-case "a link written BEFORE its target exists heals when the target arrives"
  ;; THE DECIDING CASE. ORG-8 named a `dst_note_id` column; a stored resolution
  ;; would be NULL here and would stay NULL for ever, while the note it names sat
  ;; in the same team — and linking forward is exactly how org-roam is used.
  ;; Healing a stored column would mean re-resolving on create, on rename and on
  ;; delete; resolving at READ means there is nothing to heal.
  (define-values (c p tid) (setup))
  (define n (org c p "src" "[[Levee 7 survey]]"))
  (define id (hash-ref n 'id))
  (define before (car (note-links-of c p id)))
  (check-true (hash-ref before 'broken))
  (check-equal? (hash-ref before 'reason) "missing")
  (define t (notes-create c p #:title "Levee 7 survey" #:body "at last"))
  (define after (car (note-links-of c p id)))
  (check-false (hash-ref after 'broken) "it resolves with NOTHING having rewritten the row")
  (check-equal? (hash-ref after 'note_id) (hash-ref t 'id))
  (close-db! c))

(test-case "deleting the target reports the link broken, rather than losing it"
  ;; the commonest failure this feature will have, and ORG-8's whole point: a
  ;; link that silently became plain text is how a reader concludes the editor
  ;; ate their markup.
  (define-values (c p tid) (setup))
  (define t (notes-create c p #:title "Doomed" #:body "x"))
  (define n (org c p "src" "[[Doomed][see it]]"))
  (define id (hash-ref n 'id))
  (check-false (hash-ref (car (note-links-of c p id)) 'broken))
  (notes-delete c p (hash-ref t 'id))
  (define l (car (note-links-of c p id)))
  (check-true (hash-ref l 'broken))
  (check-equal? (hash-ref l 'reason) "missing")
  (check-equal? (hash-ref l 'target) "Doomed")
  (check-equal? (hash-ref l 'label) "see it" "and the label survives, so it still reads")
  (close-db! c))

(test-case "deleting the SOURCE takes its rows with it"
  (define-values (c p tid) (setup))
  (define t (notes-create c p #:title "Target" #:body "x"))
  (define n (org c p "src" "[[Target]]"))
  (check-equal? (length (note-backlinks-of c p (hash-ref t 'id))) 1)
  (notes-delete c p (hash-ref n 'id))
  (check-equal? (note-backlinks-of c p (hash-ref t 'id)) '()
                "a row naming a note that no longer exists would be an edge from nowhere")
  (check-equal? (query-value c "SELECT COUNT(*) FROM note_links") 0)
  (close-db! c))

;; ---- ORG-10: a cross-team target --------------------------------------------
(test-case "a cross-team target is treated exactly as a nonexistent one"
  ;; `notes.id` is instance-global, so a resolution written in SQL without the
  ;; team clause would have resolved it. The reader learns their own link does
  ;; not work and learns NOTHING about whether an id elsewhere in the instance
  ;; exists — `repo-get`'s collapse of a refusal and a miss, and the one place
  ;; ORG-8's answer and ORG-9's rule meet.
  (define-values (c p tid) (setup))
  (define other (create-team! c #:name "Other" #:slug "other"))
  (define op2 (member-of c other "elsewhere" #:role "owner"))
  (define far (notes-create c op2 #:title "Far away" #:body "x"))
  (define n (org c p "src" (format "[[~a]] and [[Far away]]" (hash-ref far 'id))))
  (define ls (note-links-of c p (hash-ref n 'id)))
  (check-equal? (length ls) 2)
  (for ([l (in-list ls)])
    (check-true (hash-ref l 'broken) (hash-ref l 'target))
    (check-equal? (hash-ref l 'reason) "missing"
                  "and the reason is a MISS, which says nothing about another team"))
  (close-db! c))

;; ---- 🔑 ORG-9: AN UNREADABLE TARGET AND A NONEXISTENT ONE ARE ONE ANSWER ----
;;
;; THIS CASE USED TO ASSERT THE DEFECT. Slice 2 enforced ORG-9 by DROPPING an
;; edge whose far end the caller may not read — no count, no placeholder, no
;; field — and this file asserted exactly that. It is an oracle, because ORG-8's
;; report is the BASELINE: silence is itself a signal, so the ABSENCE of a broken
;; marker told the author that a note with the title they typed exists in their
;; team and is not theirs. The second order needed no comparison at all — once
;; they created their own note of that title, the link answered `ambiguous`,
;; which affirmatively states that there is another one they cannot see.
;;
;; The collapse is structural now: `team-note-index` is the CALLER'S view, so an
;; unreadable target is not in it and resolves exactly as a nonexistent one does.
;; What this case pins is that the two answers are INDISTINGUISHABLE, which is
;; strictly stronger than the old "it is absent" and is what ORG-9 was after.
(test-case "an unreadable far end answers exactly as a nonexistent one does"
  ;; READ AS A PLAIN MEMBER, not as the operator, who passes everything
  ;; team-tier — HELP-7's lesson, which the #245 smoke paid for with chat:use.
  (define-values (c p tid) (setup))
  (define mem (member-of c tid "mem"))
  (define secret (notes-create c p #:title "Secret plan" #:body "x" #:visibility "private"))
  (define open (notes-create c p #:title "Open plan" #:body "x"))
  ;; THE LINK IS BY ID, which is what makes the leak visible if there is one: the
  ;; raw target is then a uuid the member typed themselves, so anything about the
  ;; private note in the answer — its title above all — came from resolution.
  (define byid (org c mem "by id" (format "[[~a]]" (hash-ref secret 'id))))
  (define nope (org c mem "by nothing" "[[00000000-0000-0000-0000-000000000000]]"))
  (define l1 (car (note-links-of c mem (hash-ref byid 'id))))
  (define l2 (car (note-links-of c mem (hash-ref nope 'id))))
  (check-true (hash-ref l1 'broken) "an unreadable target is broken, as a missing one is")
  (check-equal? (hash-ref l1 'reason) "missing")
  (check-equal? (hash-ref l1 'reason) (hash-ref l2 'reason))
  (check-equal? (sort (map symbol->string (hash-keys l1)) string<?)
                (sort (map symbol->string (hash-keys l2)) string<?)
                "the same FIELDS, so a client cannot branch on which it got")
  (check-false (hash-has-key? l1 'note_id) "no id of a note the caller may not read")
  (check-false (hash-has-key? l1 'title)   "…and not its title either")
  (check-false (regexp-match? #rx"Secret plan" (format "~s" l1)) (format "~s" l1))
  (check-false (regexp-match? #rx"(?i:withheld|hidden|forbidden)" (format "~s" l1)))
  ;; AND BY TITLE, which is the form a person actually types
  (define n (org c mem "src" "[[Open plan]] and [[Secret plan]] and [[No such note]]"))
  (define ls (note-links-of c mem (hash-ref n 'id)))
  (check-equal? (length ls) 3)
  (define by-target (for/hash ([l (in-list ls)]) (values (hash-ref l 'target) l)))
  (check-false (hash-ref (hash-ref by-target "Open plan") 'broken) "the readable one resolves")
  (check-equal? (hash-ref (hash-ref by-target "Secret plan") 'reason) "missing")
  (check-equal? (hash-ref (hash-ref by-target "No such note") 'reason) "missing")
  (check-equal? (hash-ref (hash-ref by-target "Secret plan") 'broken)
                (hash-ref (hash-ref by-target "No such note") 'broken))
  ;; …and the OWNER still sees the edge resolve, which is what says it was really
  ;; there and that the member's answer was a refusal rather than a dead link
  (define owned (note-links-of c p (hash-ref n 'id)))
  (check-equal? (length owned) 3)
  (check-equal? (length (filter (lambda (l) (hash-ref l 'broken)) owned)) 1
                "for the owner only `No such note` is broken")
  (close-db! c))

;; 🔑 THE SECOND-ORDER ORACLE, which needed no comparison with a baseline: it
;; stated outright that there was another note of that title.
(test-case "a colleague's private note does not make the caller's own title ambiguous"
  (define-values (c p tid) (setup))
  (define mem (member-of c tid "mem"))
  (notes-create c p #:title "Secret plan" #:body "x" #:visibility "private")
  (define n (org c mem "src" "[[Secret plan]]"))
  ;; before the member has one of their own: a miss, exactly as for any title
  (check-equal? (hash-ref (car (note-links-of c mem (hash-ref n 'id))) 'reason) "missing")
  ;; now the member creates THEIR OWN note with that title. Against the whole
  ;; team's index two notes shared the fold and the answer was `ambiguous` — a
  ;; statement about a note they cannot see. Against their own view theirs is the
  ;; unique holder, so the link simply works.
  (define mine (notes-create c mem #:title "Secret plan" #:body "mine"))
  (define l (car (note-links-of c mem (hash-ref n 'id))))
  (check-false (hash-ref l 'broken) (format "~s" l))
  (check-equal? (hash-ref l 'note_id) (hash-ref mine 'id)
                "it resolves to the caller's own note, and says nothing about the other")
  ;; AND AMBIGUITY STILL WORKS WHERE IT IS REAL: two notes the member CAN read
  ;; sharing a fold is a link that reaches neither, which is ORG-6 and must not
  ;; have been thrown away with the oracle.
  (notes-create c mem #:title "SECRET  plan" #:body "also mine")
  (check-equal? (hash-ref (car (note-links-of c mem (hash-ref n 'id))) 'reason) "ambiguous")
  (close-db! c))

(test-case "a backlink FROM a note the caller may not read is absent too"
  (define-values (c p tid) (setup))
  (define mem (member-of c tid "mem"))
  (define t (notes-create c mem #:title "Everybody's" #:body "x"))
  (org c p "public src" "[[Everybody's]]")
  (org c p "private src" "[[Everybody's]]" #:visibility "private")
  (define bs (note-backlinks-of c mem (hash-ref t 'id)))
  (check-equal? (map (lambda (b) (hash-ref b 'title)) bs) '("public src"))
  (check-false (regexp-match? #rx"private src" (format "~s" bs)) (format "~s" bs))
  ;; the owner sees both, so the private edge really exists
  (check-equal? (length (note-backlinks-of c p (hash-ref t 'id))) 2)
  (close-db! c))

;; ---- ORG-15: what links here ------------------------------------------------
(test-case "backlinks are found by id AND by folded title"
  ;; ORG-6 admits both spellings, so a reader wants every inbound edge whichever
  ;; way its author typed it.
  (define-values (c p tid) (setup))
  (define t (notes-create c p #:title "Hub" #:body "x"))
  (define hub (hash-ref t 'id))
  (org c p "one" (format "[[~a][by id]]" hub))
  (org c p "two" "[[hub][by title]]")
  (org c p "three" "[[Something else]]")
  (define bs (note-backlinks-of c p hub))
  (check-equal? (sort (map (lambda (b) (hash-ref b 'title)) bs) string<?) '("one" "two"))
  (check-equal? (sort (map (lambda (b) (hash-ref b 'label)) bs) string<?) '("by id" "by title"))
  (close-db! c))

(test-case "a backlink by TITLE is suppressed while that title is ambiguous"
  ;; an inbound title link resolves to NEITHER note when two share the fold
  ;; (ORG-6), so reporting it here would put a backlink on a note the link does
  ;; not actually reach.
  (define-values (c p tid) (setup))
  (define a (notes-create c p #:title "Twin" #:body "x"))
  (org c p "src" "[[Twin]]")
  (check-equal? (length (note-backlinks-of c p (hash-ref a 'id))) 1)
  (notes-create c p #:title "twin" #:body "x")
  (check-equal? (note-backlinks-of c p (hash-ref a 'id)) '()
                "while an ID link to the same note would still count")
  ;; …and an id link does still count, which is what separates the two spellings
  (org c p "byid" (format "[[~a]]" (hash-ref a 'id)))
  (check-equal? (map (lambda (b) (hash-ref b 'title)) (note-backlinks-of c p (hash-ref a 'id)))
                '("byid"))
  (close-db! c))

(test-case "a note may link to itself, and it appears in both directions"
  (define-values (c p tid) (setup))
  (define n (org c p "Ouroboros" "[[Ouroboros]]"))
  (define id (hash-ref n 'id))
  (check-equal? (ids (note-links-of c p id)) (list id))
  (check-equal? (map (lambda (b) (hash-ref b 'note_id)) (note-backlinks-of c p id)) (list id))
  (close-db! c))

;; ---- the bound ---------------------------------------------------------------
(test-case "too many distinct links is refused by name, and writes nothing"
  ;; `tags-clean`'s call at a second asker: a silent drop is an edge that never
  ;; appears in a graph with nothing saying why. The cost is stated at
  ;; MAX-NOTE-LINKS' definition — slice 3's import of somebody's real org files
  ;; is the thing most likely to meet it.
  (define-values (c p tid) (setup))
  (define body (string-join (for/list ([i (in-range (add1 MAX-NOTE-LINKS))])
                              (format "[[t~a]]" i)) " "))
  ;; THE MESSAGE, NOT MERELY `exn:fail?`. A bare `exn:fail?` passed against a
  ;; version whose refusal could not even be COMPOSED — a parameter named
  ;; `format` shadowed the procedure, so the raise died with a contract error
  ;; and this case agreed with it. Slice 3 found that; naming the message is
  ;; what stops it coming back.
  (check-exn #px"at most 500 distinct links" (lambda () (org c p "too many" body)))
  (check-equal? (length (notes-list c p)) 0 "the note itself is not left behind")
  (check-equal? (query-value c "SELECT COUNT(*) FROM note_links") 0)
  ;; one under the cap is fine
  (define ok-body (string-join (for/list ([i (in-range MAX-NOTE-LINKS)])
                                 (format "[[t~a]]" i)) " "))
  (check-equal? (length (note-links-of c p (hash-ref (org c p "at the cap" ok-body) 'id)))
                MAX-NOTE-LINKS)
  (close-db! c))

(test-case "a links read on a note that is not there is #f, not an empty answer"
  ;; the endpoint turns this into a 404; an empty list would say the note exists
  ;; and has no links
  (define-values (c p tid) (setup))
  (check-false (note-links-of c p "no-such-note"))
  (check-false (note-backlinks-of c p "no-such-note"))
  (close-db! c))

;; ---- a refused update changes NOTHING -------------------------------------
;;
;; `notes-update` committed the title and the visibility BEFORE the body, and the
;; body is where a refusal lives: `write-links!` refuses past MAX-NOTE-LINKS, so
;; the commonest 400 on this path left the new name — and the new AUDIENCE —
;; written beside the old body. The caller was told the update failed and half of
;; it had landed, which is the half nobody re-checks after an error.
(test-case "an update refused for too many links leaves title and visibility alone"
  (define-values (c p tid) (setup))
  (define n (org c p "Original" "no links" #:visibility "team"))
  (define id (hash-ref n 'id))
  (define too-many
    (string-join (for/list ([i (in-range (add1 MAX-NOTE-LINKS))]) (format "[[T~a]]" i)) " "))
  (check-exn exn:fail:user?
             (lambda () (notes-update c p id #:title "Renamed" #:visibility "private" #:body too-many)))
  (define after (notes-get c p id))
  (check-equal? (hash-ref after 'title) "Original")
  (check-equal? (hash-ref after 'visibility) "team")
  (check-equal? (hash-ref after 'body) "no links")
  ;; …and the same for a tag write, which is the other statement that can refuse
  (check-exn exn:fail:user?
             (lambda () (notes-update c p id #:title "Renamed" #:tags (list (make-string 200 #\a)))))
  (check-equal? (hash-ref (notes-get c p id) 'title) "Original"))
