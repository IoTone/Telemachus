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

(require rackunit db-kit/portable racket/list racket/string
         db-kit/migrate
         "../domain/db/migrations.rkt"
         "db-fixture.rkt"
         "../domain/authz/authz.rkt"
         "../domain/notes/notes.rkt"
         "../domain/notes/note-tools.rkt"
         (only-in "../domain/quota/quota.rkt" quota-used set-limit!))

(define (fresh) (define c (fresh-db #:migrate? #f)) (migrate! c all-migrations) c)
(define (setup)
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "root"))
  (values c (user-principal c uid tid) tid))
(define (member-of c team username #:role [role "member"])
  (define u (create-user! c #:username username #:password "pw-fixture-1"))
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


;; ---- TAG-6/TAG-7: what the model is allowed to do ---------------------------------
;; The model is a PARAMETER, so these run with no endpoint and no budget. The
;; scripted reply is the whole fixture: a tool that only works against a live
;; model is a tool whose refusals nobody has read.
(define (scripted reply [tokens 11])
  (lambda (prompt #:system [sys #f]) (values reply tokens)))

(test-case "a proposal ADDS, is normalized, and never removes what somebody typed"
  (define-values (c p tid) (setup))
  (define id (hash-ref (notes-create c p #:title "Levee 7" #:body "survey due" #:tags '("mine")) 'id))
  (define-values (n added dropped)
    (note-autotag! c p id #:chat (scripted "{\"tags\": [\"Survey\", \"  LEVEE 7 \"]}")))
  (check-equal? (hash-ref n 'tags) '("levee 7" "mine" "survey") "added to, not replaced")
  (check-equal? added '("levee 7" "survey") "and it reports only what it added")
  (check-equal? dropped '()))

(test-case "a tag the model invents that cannot be cleaned is DROPPED and REPORTED"
  ;; the other four may be perfectly good; a tag that silently vanishes is
  ;; indistinguishable from a model that said nothing
  (define-values (c p tid) (setup))
  (define id (hash-ref (notes-create c p #:title "n" #:body "b") 'id))
  (define-values (n added dropped)
    (note-autotag! c p id #:chat (scripted "{\"tags\": [\"good\", \"\", 7, \"also good\"]}")))
  (check-equal? added '("also good" "good"))
  (check-equal? (length dropped) 2 "the empty one and the number")
  (check-true (for/or ([d (in-list dropped)]) (regexp-match? #px"7" d))))

(test-case "a reply that is not an object, or carries no tags, is reported and writes nothing"
  (define-values (c p tid) (setup))
  (define id (hash-ref (notes-create c p #:title "n" #:body "b" #:tags '("kept")) 'id))
  (define-values (n1 a1 d1) (note-autotag! c p id #:chat (scripted "I could not say.")))
  (check-equal? a1 '())
  (check-equal? (hash-ref n1 'tags) '("kept") "the note is untouched")
  (check-equal? (length d1) 1)
  ;; the model declining is a legitimate answer, not a failure
  (define-values (n2 a2 d2) (note-autotag! c p id #:chat (scripted "{\"tags\": []}")))
  (check-equal? a2 '())
  (check-equal? d2 '() "declining is not a dropped tag")
  (check-equal? (hash-ref n2 'tags) '("kept")))

(test-case "an extra key does not throw the tags away"
  ;; OPEN schema, JUDGE-6's call — the prompt is ours and every tag is checked
  (define-values (c p tid) (setup))
  (define id (hash-ref (notes-create c p #:title "n" #:body "b") 'id))
  (define-values (n added dropped)
    (note-autotag! c p id #:chat (scripted "{\"reasoning\": \"it is about budgets\", \"tags\": [\"budget\"]}")))
  (check-equal? added '("budget")))

(test-case "the proposal is capped, and the RESULT is still held to MAX-TAGS"
  (define-values (c p tid) (setup))
  (define id (hash-ref (notes-create c p #:title "n" #:body "b") 'id))
  (define many (string-join (for/list ([i 9]) (format "\"t~a\"" i)) ", "))
  (define-values (n added dropped)
    (note-autotag! c p id #:chat (scripted (string-append "{\"tags\": [" many "]}"))))
  (check-equal? (length added) TAG-PROPOSAL-MAX "five at most per call"))

(test-case "it is metered, and a note the caller cannot read is #f"
  (define-values (c p tid) (setup))
  (set-limit! c "team" tid "ai.tokens.total" 1000000 #:window "day")
  (define id (hash-ref (notes-create c p #:title "n" #:body "b") 'id))
  (note-autotag! c p id #:chat (scripted "{\"tags\": [\"x\"]}" 42))
  (check-equal? (quota-used c "team" tid "ai.tokens.total" "day") 42
                "the provider's own token count, recorded whatever the reply was")
  ;; three values ALWAYS, including for a note that is not there — a bare #f here
  ;; is a result arity mismatch at every call site that destructures it
  (define-values (missing m-added m-dropped)
    (note-autotag! c p "no-such-note" #:chat (scripted "{\"tags\": []}")))
  (check-false missing)
  (check-equal? m-added '())
  (check-equal? m-dropped '()))

(test-case "the model is shown only the tags the CALLER can see"
  ;; a proposal must not be steered by a word that exists only on somebody's
  ;; private note — the same reason the derived list is authorized
  (define-values (c p tid) (setup))
  (define bob (member-of c tid "bob"))
  (notes-create c p #:title "mine" #:visibility "private" #:tags '("confidential-codename"))
  (define bobs (hash-ref (notes-create c bob #:title "bobs" #:body "b") 'id))
  (define seen (box ""))
  (note-autotag! c bob bobs
                 #:chat (lambda (prompt #:system [sys #f])
                          (set-box! seen prompt)
                          (values "{\"tags\": []}" 1)))
  (check-false (regexp-match? #px"confidential-codename" (unbox seen))))

(test-case "a caller who may not WRITE is refused before the model is called"
  ;; TAG-8, and this case exists because a positive control did not bite: the
  ;; rule was covered only by the HTTP smoke, so nothing here would have noticed
  ;; the check being removed. The model call sits between a read and a write, so
  ;; what must be asserted is not merely the refusal but that NOTHING WAS SPENT —
  ;; the seam was never reached. EMB-9's shape: the case asserts the seams were
  ;; never called, which is the only way a "declines before spending" claim means
  ;; anything.
  (define-values (c p tid) (setup))
  (define vera (member-of c tid "vera" #:role "viewer"))
  (define id (hash-ref (notes-create c p #:title "team note" #:tags '("kept")) 'id))
  (define called (box 0))
  (define counting (lambda (prompt #:system [sys #f])
                     (set-box! called (add1 (unbox called)))
                     (values "{\"tags\": [\"sneaked\"]}" 5)))
  (check-exn exn:fail:forbidden?
             (lambda () (note-autotag! c vera id #:chat counting)))
  (check-equal? (unbox called) 0 "the model was never called, so nothing was spent")
  (check-equal? (note-tags c id) '("kept") "and the note is untouched"))
