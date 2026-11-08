#lang racket/base

;; test/note-graph-tests.rkt — #247's edge set as a drawable graph, decisions
;; ORG-13, ORG-14 and ORG-16.
;;
;;   raco test test/note-graph-tests.rkt
;;   DATABASE_URL="postgres://…" raco test test/note-graph-tests.rkt
;;
;; Runs whole on both dialects. That is not a formality: the read leans on a
;; bounded `LIMIT` over `note_links` and on a fold computed in RACKET rather than
;; with SQL's `lower()`, and the cap's ordering is `created_at DESC, id DESC`
;; over a TEXT column at second resolution — the three things the two engines
;; could disagree about.
;;
;; WHAT THIS FILE IS FOR, AND IT IS NOT THE PICTURE. The layout is in
;; `static/console/21-notegraph.js` and is pinned in the browser, where a seeded
;; run can be compared with itself (`demo-validate.mjs` §3c6) — a question about
;; what code COMPUTES cannot be answered by reading it, which is §3c's rule for
;; the Markdown sanitiser. What is here is the NODE SET and the EDGE SET: who is
;; in the picture, who is deliberately not, and what the reader is told about
;; the difference.
;;
;; 🔑 AND THE CASE THAT MATTERS MOST IS ORG-9a's, AT A THIRD READER. Slice 2
;; enforced ORG-9 by dropping an edge, which was an oracle; the graph draws a
;; node for a target that resolves to nothing, so under that resolution this
;; picture would have told a reader which of their colleagues' private notes
;; exist. The property is not "the private note is absent" — it is that the two
;; answers are INDISTINGUISHABLE, which is strictly stronger and is what the
;; case asserts.

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
(define (member-of c team username)
  (define u (create-user! c #:username username #:password "pw"))
  (add-member! c #:user u #:team team #:role "member")
  (user-principal c u team))
(define (org c p title body #:visibility [vis "team"])
  (hash-ref (notes-create c p #:title title #:body body
                          #:format "org" #:visibility vis) 'id))
(define (md c p title body #:visibility [vis "team"])
  (hash-ref (notes-create c p #:title title #:body body #:visibility vis) 'id))

(define (node-ids G) (sort (map (lambda (n) (hash-ref n 'id)) (hash-ref G 'nodes)) string<?))
(define (titles G) (sort (map (lambda (n) (hash-ref n 'title)) (hash-ref G 'nodes)) string<?))
(define (edge-set G)
  (sort (map (lambda (e) (string-append (hash-ref e 'from) ">" (hash-ref e 'to)))
             (hash-ref G 'edges))
        string<?))
(define (phantoms G) (filter (lambda (n) (hash-ref n 'missing)) (hash-ref G 'nodes)))
;; the REAL notes among the nodes. An unresolved target is a node as well, so an
;; assertion about which notes are drawn has to say so — the first version of
;; this file compared against `node-ids` and failed on its own phantoms.
(define (real-ids G)
  (sort (for/list ([n (in-list (hash-ref G 'nodes))] #:unless (hash-ref n 'missing))
          (hash-ref n 'id))
        string<?))

;; ---- the whole-team map ----------------------------------------------------
(test-case "the whole-team map draws every readable note, isolated ones included"
  ;; ORG-16 — a MAP, so a note nobody has linked yet is on it: that is exactly
  ;; what somebody opening this is looking for, and a drawing of only the
  ;; connected part would make an unlinked note invisible in the one view meant
  ;; to show the shape of the team's thinking.
  (define-values (c p tid) (setup))
  (define a (org c p "Alpha" "see [[Beta]]"))
  (define b (org c p "Beta" "back to [[Alpha]]"))
  (define lonely (md c p "Lonely" "nothing points here"))
  (define G (note-graph c p))
  (check-equal? (node-ids G) (sort (list a b lonely) string<?))
  (check-equal? (edge-set G) (sort (list (string-append a ">" b)
                                         (string-append b ">" a)) string<?))
  (check-equal? (hash-ref G 'total) 3)
  (check-false (hash-ref G 'truncated))
  ;; QUOTA-3's rule — the reason is ABSENT when nothing was cut, so a reader
  ;; never has to decide whether a stated one means anything
  (check-equal? (hash-ref G 'reason) 'null)
  (check-equal? (hash-ref G 'focus) 'null)
  (check-equal? (hash-ref G 'depth) 'null)
  (close-db! c))

(test-case "an unresolved target is a node of its own, carrying the text its author typed"
  ;; ORG-8 through the drawing: "four notes point at a note nobody has written"
  ;; is the most useful thing this picture says, and it is org-roam's and
  ;; Obsidian's own behaviour. The node carries the RAW target, because that is
  ;; what the author typed and what they would search for.
  (define-values (c p tid) (setup))
  (define a (org c p "Alpha" "[[Levee 7 survey]]"))
  (define b (org c p "Beta" "also [[levee 7 SURVEY]]"))
  (define G (note-graph c p))
  (check-equal? (length (hash-ref G 'nodes)) 3)
  ;; ONE phantom for two spellings: the fold is the identity, so two authors who
  ;; typed it differently are pointing at the same unwritten note — which is the
  ;; whole reason the fold is stored beside the raw target
  (check-equal? (length (phantoms G)) 1)
  (check-equal? (hash-ref (car (phantoms G)) 'title) "Levee 7 survey")
  ;; both real notes point at it, and there is no edge between them
  (check-equal? (length (hash-ref G 'edges)) 2)
  ;; `total` counts NOTES, so a phantom does not inflate it — otherwise a team
  ;; would appear to own notes nobody has written
  (check-equal? (hash-ref G 'total) 2)
  (close-db! c))

(test-case "which spelling labels an unresolved node is decided by the DATA, not by a row order"
  ;; THIS CASE IS WHAT FOUND THE DEFECT and it had to be rewritten to catch it
  ;; RELIABLY. Taking whichever link row arrived first is `ORDER BY
  ;; src_note_id`, i.e. whichever SOURCE NOTE owns the smaller random uuid — so
  ;; two authors who spelled one unwritten note differently would label it
  ;; differently on every instance, and ORG-13's determinism is about the whole
  ;; drawing and not only the layout.
  ;;
  ;; A SINGLE PAIR CANNOT PIN IT: against the row-order version the right label
  ;; comes back half the time, which is a control that bites on a coin flip and
  ;; a case that passes by luck. TWELVE pairs make the broken version agree with
  ;; the rule on all twelve with probability 2^-12, which is the honest way to
  ;; pin a property whose failure is a random choice — and the odds are stated
  ;; here rather than left for somebody to rediscover.
  (define-values (c p tid) (setup))
  (define pairs
    (for/list ([i (in-range 12)])
      (define upper (format "Target ~a" i))        ; sorts before, by codepoint
      (define lower (format "target ~a" i))        ; …and folds to the same key
      (void (org c p (format "Src upper ~a" i) (format "[[~a]]" upper)))
      (void (org c p (format "Src lower ~a" i) (format "[[~a]]" lower)))
      (cons (string-downcase upper) upper)))
  (define G (note-graph c p))
  (check-equal? (length (phantoms G)) 12 "one unwritten note per pair, not two")
  (define got
    (for/hash ([n (in-list (phantoms G))])
      (values (string-downcase (hash-ref n 'title)) (hash-ref n 'title))))
  (for ([pr (in-list pairs)])
    (check-equal? (hash-ref got (car pr) #f) (cdr pr)
                  "the smallest spelling labels the node, whatever the source ids are"))
  (close-db! c))

;; ---- 🔑 ORG-9a at a third reader -------------------------------------------
(test-case "a target the caller may not read is indistinguishable from one nobody has written"
  ;; THE PROPERTY IS INDISTINGUISHABILITY, not absence. Slice 2's own test
  ;; asserted that the private note was simply gone, which passed while the
  ;; answer still differed from the nonexistent case — and here a differing
  ;; answer would be a NODE, labelled with a title the reader guessed, which is
  ;; the strongest form that oracle could have taken.
  ;;
  ;; Asserted as a PLAIN MEMBER and never as the operator, who passes everything
  ;; team-tier and would pass this against a server that checks nothing
  ;; (HELP-7's lesson).
  (define-values (c root tid) (setup))
  (define root-private (org c root "Secret plan" "root's own" #:visibility "private"))
  (define bob (member-of c tid "bob"))
  (define guess (org c bob "Bob guesses" "[[Secret plan]]"))
  (define absent (org c bob "Bob invents" "[[No Such Thing]]"))
  (define G (note-graph c bob))
  ;; bob's own two notes, plus one phantom per target — and the private note is
  ;; NOT among the nodes
  (check-equal? (real-ids G) (sort (list guess absent) string<?)
                "a note bob cannot read is not a node")
  (check-equal? (length (phantoms G)) 2)
  ;; THE TWO PHANTOMS AGREE IN EVERY FIELD BUT THE TEXT BOB HIMSELF TYPED
  (define (shape n) (sort (hash-keys n) symbol<?))
  (define ph (sort (phantoms G) string<? #:key (lambda (n) (hash-ref n 'title))))
  (check-equal? (shape (car ph)) (shape (cadr ph))
                "the two kinds of unresolved target have the same shape")
  (check-equal? (map (lambda (n) (hash-ref n 'missing)) ph) '(#t #t))
  (check-equal? (map (lambda (n) (hash-ref n 'focus)) ph) '(#f #f))
  ;; and nothing anywhere in the answer — any field of any node, not only the
  ;; id — carries the private note's id or a title bob did not himself type
  (define flat (format "~s" G))
  (check-false (regexp-match? (regexp (regexp-quote root-private)) flat)
               "no field of the answer carries the id of a note bob may not read")
  ;; bob's own notes are drawn, so the silence above is not simply an empty graph
  (check-equal? (length (hash-ref G 'edges)) 2)
  (close-db! c))

(test-case "an edge whose SOURCE the caller may not read is absent, with nothing said about it"
  ;; ORG-9's other end. There is deliberately no `withheld` figure, where CLS-27
  ;; and VEC-29 both report one: that is the difference between a bound somebody
  ;; should know about and a fact about somebody else's note.
  (define-values (c root tid) (setup))
  (define target (org c root "Public target" "anyone may read me"))
  (void (org c root "Root's private source" "[[Public target]]" #:visibility "private"))
  (define bob (member-of c tid "bob"))
  (define G (note-graph c bob))
  (check-equal? (node-ids G) (list target))
  (check-equal? (hash-ref G 'edges) '())
  (check-equal? (hash-ref G 'ambiguous) 0)
  (check-false (hash-ref G 'truncated))
  ;; the root's own view of the same team HAS that edge, or the assertion above
  ;; would pass against a build that extracted nothing
  (check-equal? (length (hash-ref (note-graph c root) 'edges)) 1)
  (close-db! c))

(test-case "an ambiguous target is counted and drawn as nothing"
  ;; The one place this read differs from ORG-9's silence, and the reason is who
  ;; the fact is about: every note involved is one the caller can read, and the
  ;; remedy is theirs (link by id, or rename one). A phantom for it would sit on
  ;; the canvas beside the two real notes that already carry that title, naming
  ;; the same words three times.
  (define-values (c p tid) (setup))
  (define d1 (org c p "Dup" "one"))
  (define d2 (org c p "Dup" "two"))
  (define src (org c p "Points at both" "[[Dup]]"))
  (define G (note-graph c p))
  (check-equal? (hash-ref G 'ambiguous) 1)
  (check-equal? (phantoms G) '() "an ambiguous target gets no node")
  (check-equal? (hash-ref G 'edges) '() "and no edge, because it reaches neither")
  (check-equal? (node-ids G) (sort (list d1 d2 src) string<?))
  ;; and an ambiguous target is NOT a truncation: nothing was left out for want
  ;; of room, so the reader is told about it separately
  (check-false (hash-ref G 'truncated))
  ;; 🔑 AND THE COUNT IS SCOPED TO THE VIEW, which the HTTP smoke is what found.
  ;; Counted over the whole team, a reader looking at one note's neighbourhood
  ;; was told about an ambiguous link in a note that is not in the picture and
  ;; that they may never have seen — a figure with no remedy beside it, which is
  ;; #178's decoration. A neighbourhood of the two twins contains neither the
  ;; source nor its ambiguous link.
  (define far (org c p "Far away" "unrelated"))
  (check-equal? (hash-ref (note-graph c p #:note far) 'ambiguous) 0
                "an ambiguity elsewhere in the team is not this view's business")
  (check-equal? (hash-ref (note-graph c p #:note src) 'ambiguous) 1
                "…and the source's own is")
  (close-db! c))

;; ---- ORG-16's neighbourhood ------------------------------------------------
(test-case "a neighbourhood is one note and what reaches it, undirected, and depth walks out"
  ;; UNDIRECTED, because "what links here" is the half people actually use
  ;; (ORG-15) and a reader looking at a note wants both sides of it on the
  ;; canvas. Directed, `C` below — which only LINKS TO the focus — would vanish
  ;; from a picture of the focus, which is the opposite of useful.
  (define-values (c p tid) (setup))
  (define hub (org c p "Hub" "out to [[Spoke]]"))
  (define spoke (org c p "Spoke" "nothing out"))
  (define inbound (org c p "Inbound" "in to [[Hub]]"))
  (define far (org c p "Far" "two hops via [[Inbound]]"))
  (void (org c p "Unrelated" "no links at all"))
  (define one (note-graph c p #:note hub #:depth 1))
  (check-equal? (titles one) '("Hub" "Inbound" "Spoke")
                "depth 1 is the focus and both directions around it")
  (check-equal? (hash-ref one 'focus) hub)
  (check-equal? (hash-ref one 'depth) 1)
  (check-equal? (length (filter (lambda (n) (hash-ref n 'focus)) (hash-ref one 'nodes))) 1
                "exactly one node is marked as the focus, for the drawing to emphasise")
  (define two (note-graph c p #:note hub #:depth 2))
  (check-equal? (titles two) '("Far" "Hub" "Inbound" "Spoke"))
  ;; `total` is still the TEAM's note count, so the reader can see that a
  ;; neighbourhood of four is a view of five
  (check-equal? (hash-ref two 'total) 5)
  (check-false (hash-ref two 'truncated))
  ;; a further hop adds nothing, and that is not a truncation either
  (check-equal? (titles (note-graph c p #:note hub #:depth 3)) (titles two))
  (close-db! c))

(test-case "a focus that is not there and one the caller may not read are ONE answer"
  ;; `repo-get`'s collapse, and ORG-9a's rule reaching the FOCUS as well as the
  ;; targets: `#f` either way, which the endpoint renders as a 404. Answering
  ;; differently would make the graph read an existence oracle on a note id.
  (define-values (c root tid) (setup))
  (define private (org c root "Root's own" "private" #:visibility "private"))
  (define bob (member-of c tid "bob"))
  (check-false (note-graph c bob #:note private))
  (check-false (note-graph c bob #:note "no-such-id"))
  ;; root's own read of the same id is a graph, so the two #f above are the rule
  ;; and not a broken read
  (check-true (hash? (note-graph c root #:note private)))
  (close-db! c))

(test-case "a nonsense depth is clamped, not refused"
  ;; A bad `?depth=` is a reader asking for a picture, and refusing one over a
  ;; query parameter whose effect they can see is the wrong trade — the cap it
  ;; shares a purpose with is clamped for the same reason.
  (define-values (c p tid) (setup))
  (define a (org c p "A" "[[B]]"))
  (void (org c p "B" "[[C]]"))
  (void (org c p "C" "end"))
  (check-equal? (hash-ref (note-graph c p #:note a #:depth 0) 'depth) 1)
  (check-equal? (hash-ref (note-graph c p #:note a #:depth -5) 'depth) 1)
  (check-equal? (hash-ref (note-graph c p #:note a #:depth 99) 'depth) NOTE-GRAPH-DEPTH-MAX)
  (close-db! c))

;; ---- ORG-16's two bounds, which have different remedies --------------------
(test-case "past the cap the whole-team map keeps the NEWEST notes and says which bound it hit"
  ;; A CAP HAS TO DROP NOTES IN SOME ORDER, and an arbitrary one makes the
  ;; picture a different picture per query — so ORG-13's determinism reaches the
  ;; NODE SET and not only the layout: a seeded layout over an arbitrary subset
  ;; is still arbitrary. The order is the notes listing's own, `created_at DESC,
  ;; id DESC` (NPG-3), because `created_at` is TEXT at SECOND resolution and `id`
  ;; is a random uuid.
  ;;
  ;; AND THE HUB IS WHAT GETS DROPPED HERE, which is the honest demonstration of
  ;; why the remedy is a neighbourhood rather than a bigger cap: it is the oldest
  ;; note, so the view loses the one node every edge ran through and comes back
  ;; with no edges at all. A team this size has no whole-graph picture, which is
  ;; ORG-16 and RG-9's own argument.
  (define-values (c p tid) (setup))
  (define hub (org c p "Hub" "the centre"))
  (define spokes
    (for/list ([i (in-range (+ NOTE-GRAPH-MAX 10))])
      (org c p (format "Spoke ~a" i) "to [[Hub]]")))
  ;; THE FIXTURE HAS TO AGE THE HUB, and the first version of this case did not
  ;; and failed. All 161 notes are written inside one second — `created_at` is
  ;; TEXT `CURRENT_TIMESTAMP` at second resolution — so they TIE, and the
  ;; tiebreak is then a random uuid: the order is stable and arbitrary, and
  ;; "the oldest is the hub" was reasoning from a key that does not resolve.
  ;; CLS-27's fixture lesson, paid again here.
  (query-exec c "UPDATE notes SET created_at = '2020-01-01 00:00:00' WHERE id = ?" hub)
  (define G (note-graph c p))
  (check-equal? (length (hash-ref G 'nodes)) NOTE-GRAPH-MAX)
  (check-true (hash-ref G 'truncated))
  (check-equal? (hash-ref G 'reason) "cap")
  (check-equal? (hash-ref G 'total) (+ NOTE-GRAPH-MAX 11))
  (check-false (and (member hub (real-ids G)) #t)
               "the oldest note is the one dropped, and here that is the hub")
  (check-equal? (hash-ref G 'edges) '()
                "so the whole-team view of an over-cap team can be edgeless")
  ;; the kept set is exactly the newest by the listing's own key, computed here
  ;; rather than taken from the answer — a control that removed the sort would
  ;; otherwise agree with whatever the engine returned
  (define expected
    (take (sort (query-rows c "SELECT id, created_at FROM notes WHERE team_id = ?" tid)
                (lambda (a b)
                  (define ca (vector-ref a 1)) (define cb (vector-ref b 1))
                  (if (string=? ca cb)
                      (string>? (vector-ref a 0) (vector-ref b 0))
                      (string>? ca cb))))
          NOTE-GRAPH-MAX))
  (check-equal? (node-ids G) (sort (map (lambda (r) (vector-ref r 0)) expected) string<?))
  ;; …and the SAME fixture's neighbourhood reports the OTHER bound, because the
  ;; remedies differ: fewer hops here, a smaller question there. A single
  ;; `truncated` boolean could not tell a reader which to try.
  (define N (note-graph c p #:note hub #:depth 1))
  (check-equal? (length (hash-ref N 'nodes)) NOTE-GRAPH-MAX)
  (check-true (hash-ref N 'truncated))
  (check-equal? (hash-ref N 'reason) "neighbourhood")
  ;; the focus survives the cut — a picture of a note that does not contain it
  ;; would be unreadable rather than merely incomplete
  (check-true (and (member hub (real-ids N)) #t))
  (check-equal? (length (filter (lambda (n) (hash-ref n 'focus)) (hash-ref N 'nodes))) 1)
  ;; a partially drawn neighbourhood is the SAME one every time, which is what
  ;; the sorted frontier is for — the walk cannot just read a hash's values
  (check-equal? (node-ids (note-graph c p #:note hub #:depth 1)) (node-ids N))
  (close-db! c))

(test-case "the ways this read can stop are a closed vocabulary, in both directions"
  ;; #113's shape, and `vocabulary-tests.rkt`'s rule: the list is PINNED rather
  ;; than re-derived, because a test that rebuilt it from the source would agree
  ;; with any change whatsoever.
  (check-equal? NOTE-GRAPH-STOPS '("cap" "neighbourhood" "scan"))
  ;; `cap` and `neighbourhood` are each produced by the case above. `scan` is the
  ;; link window and is STATED rather than pinned here: reaching it needs over
  ;; 2,000 link rows among at most 150 notes — roughly 150 notes carrying 14
  ;; links each — which is a fixture several times the size of this whole file
  ;; for a bound whose remedy is nobody's to apply. It is reported LAST for that
  ;; reason: a reader can act on the two above by asking a different question,
  ;; and cannot act on this one at all.
  (check-true (and (member "scan" NOTE-GRAPH-STOPS) #t)))
