#lang racket/base

;; test/feed-queue-tests.rkt — the feed work queue and its proposals
;; (issue #114 slices 5 and 6; decisions FEED-8, FEED-10, QUEUE-1…9).
;;
;; THE TABLE IS CREATED FROM THE PLUGIN'S OWN `migrations` LIST, not from a copy
;; of the DDL written here. A test that declared its own schema would agree with
;; any change to the plugin's — and #121 made that list data precisely so the
;; platform could apply it, which means the suite can too.
;;
;;   raco test test/feed-queue-tests.rkt

(require rackunit db-kit/portable
         racket/file racket/list racket/port racket/string
         db-kit/migrate
         "../domain/db/migrations.rkt"
         "db-fixture.rkt"
         "../domain/authz/authz.rkt"
         "../domain/repo/blobs.rkt"
         "../domain/repo/repo.rkt"
         "../plugins/feeds/main.rkt")

(define BLOB-ROOT (make-temporary-file "tmx-feedq-blobs-~a" 'directory))
(current-blob-root BLOB-ROOT)

(define (fresh)
  (define c (fresh-db #:migrate? #f))
  (migrate! c all-migrations)
  ;; the plugin's own DDL, exactly as the loader applies it
  (for* ([m (in-list migrations)] [sql (in-list (cdr m))])
    (query-exec c sql))
  c)

(define (setup)
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "root"))
  (values c (user-principal c uid tid) tid))

;; A pulled item, shaped the way `poll.rkt` writes one: a JSON document under
;; `feeds/<slug>/` carrying `feed_*` attributes.
(define (item c p key #:slug [slug "gh"] #:visibility [vis "team"] #:body [body "{\"n\":1}"])
  (define o (repo-put! c p #:key key #:port (open-input-string body)
                       #:content-type "application/json" #:visibility vis))
  (hash-ref o 'id))

(define (ids rows) (map (lambda (r) (hash-ref r 'key)) rows))

;; ---- 1. the closed vocabulary and the clamps -----------------------------------
;; PINNED, not re-derived (vocabulary-tests' rule): the point of a closed
;; vocabulary is that adding a member is a decision somebody makes on purpose.
(test-case "the statuses are a closed, pinned vocabulary"
  (check-equal? QUEUE-STATUSES '("open" "claimed" "done" "dropped")))

;; A priority range that is OPEN-ENDED is the failure this clamp prevents: one
;; workflow passing 10 and another 1,000,000 makes "the first actionable task"
;; depend on who wrote the workflow rather than on what is urgent.
(test-case "a priority is clamped into the range, and a non-number defaults"
  (check-equal? (clamp-priority 0) 0)
  (check-equal? (clamp-priority 100) 100)
  (check-equal? (clamp-priority -5) PRIORITY-MIN)
  (check-equal? (clamp-priority 10000) PRIORITY-MAX)
  (check-equal? (clamp-priority 72.6) 73 "a real is rounded, not truncated")
  (check-equal? (clamp-priority "high") 50 "a non-number is the default, never an error")
  (check-equal? (clamp-priority 'null) 50))

(test-case "skills are normalized, de-duplicated, lower-cased and capped"
  (check-equal? (normalize-skills '("Racket" " ops " "racket")) ",racket,ops,")
  (check-equal? (normalize-skills '()) "")
  (check-equal? (normalize-skills "racket, ops") ",racket,ops,")
  (check-equal? (normalize-skills 42) "")
  (check-equal? (length (string-split (normalize-skills
                                       (for/list ([i (in-range 50)]) (format "s~a" i)))
                                      "," #:trim? #t))
                MAX-SKILLS))

;; THE DELIMITING IS THE WHOLE REASON THE COLUMN IS A STRING. A `LIKE '%racket%'`
;; over a bare list matches "racketeering"; the leading and trailing commas are
;; what make a skill filter mean one skill. `differ`'s trap, in SQL.
(test-case "a skill is stored delimited, so one skill cannot straddle another"
  (check-equal? (normalize-skills '("racket")) ",racket,")
  (check-true (regexp-match? #rx",racket," (normalize-skills '("ops" "racket"))))
  (check-false (regexp-match? #rx",racket," (normalize-skills '("racketeering")))))

;; ---- 2. the index ---------------------------------------------------------------
(test-case "an item goes on the queue, and triaging it again updates rather than duplicates"
  (define-values (c p tid) (setup))
  (define a (item c p "feeds/gh/acme-repo-1.json"))
  (check-equal? (hash-ref (queue-upsert! c p a #:priority 70 #:skills '("racket")) 'priority) 70)
  (check-equal? (length (queue-rows c p)) 1)
  ;; the PRIMARY KEY on object_id is the dedup rule, so a re-triage is an update
  (check-equal? (hash-ref (queue-upsert! c p a #:priority 20) 'priority) 20)
  (check-equal? (length (queue-rows c p)) 1 "one row, not two")
  (check-equal? (hash-ref (car (queue-rows c p)) 'priority) 20)
  ;; …and the skills really round-trip as a list rather than the stored string
  (check-equal? (hash-ref (car (queue-rows c p)) 'skills) '()
                "the second triage passed no skills, so they are cleared"))

;; THE ORDER IS THE FEATURE (QUEUE-4), and the NULL due date is the half that
;; would break silently: the two dialects sort NULLs opposite ways under ASC, so
;; without the COALESCE an item with no deadline would come first on one engine
;; and last on the other.
(test-case "the queue is ordered by priority, then the soonest due date, with no due date last"
  (define-values (c p tid) (setup))
  (define low  (item c p "feeds/gh/low.json"))
  (define soon (item c p "feeds/gh/soon.json"))
  (define late (item c p "feeds/gh/late.json"))
  (define none (item c p "feeds/gh/none.json"))
  (queue-upsert! c p low  #:priority 10)
  (queue-upsert! c p none #:priority 90)
  (queue-upsert! c p late #:priority 90 #:due 2000000000)
  (queue-upsert! c p soon #:priority 90 #:due 1000000000)
  (check-equal? (ids (queue-rows c p))
                '("feeds/gh/soon.json" "feeds/gh/late.json" "feeds/gh/none.json" "feeds/gh/low.json")))

(test-case "the default listing is the ACTIONABLE statuses, and ?status= narrows"
  (define-values (c p tid) (setup))
  (define a (item c p "feeds/gh/a.json"))
  (define b (item c p "feeds/gh/b.json"))
  (define d (item c p "feeds/gh/d.json"))
  (queue-upsert! c p a #:status "open")
  (queue-upsert! c p b #:status "claimed")
  (queue-upsert! c p d #:status "done")
  (check-equal? (length (queue-rows c p)) 2 "done is not actionable")
  (check-equal? (length (queue-rows c p #:status 'all)) 3)
  (check-equal? (ids (queue-rows c p #:status "done")) '("feeds/gh/d.json"))
  (check-exn #rx"not a status this queue has"
             (lambda () (queue-rows c p #:status "urgent"))))

(test-case "the skill filter matches one skill and not a longer one containing it"
  (define-values (c p tid) (setup))
  (define a (item c p "feeds/gh/a.json"))
  (define b (item c p "feeds/gh/b.json"))
  (queue-upsert! c p a #:skills '("racket" "ops"))
  (queue-upsert! c p b #:skills '("racketeering"))
  (check-equal? (ids (queue-rows c p #:skill "racket")) '("feeds/gh/a.json"))
  (check-equal? (ids (queue-rows c p #:skill "RACKET")) '("feeds/gh/a.json") "case does not matter")
  (check-equal? (ids (queue-rows c p #:skill "racketeering")) '("feeds/gh/b.json")))

(test-case "the feed slug filter reads the item's own attribute, not the caller's word for it"
  (define-values (c p tid) (setup))
  (define a (item c p "feeds/gh/a.json"))
  (repo-fields-declare! c tid (list (hasheq 'key "feed_slug" 'label "Feed")) #:subject "feeds")
  (repo-set-attributes! c p a (hasheq 'feed_slug "gh"))
  (queue-upsert! c p a)
  (check-equal? (ids (queue-rows c p #:slug "gh")) '("feeds/gh/a.json"))
  (check-equal? (queue-rows c p #:slug "other") '()))

;; ---- 3. the row confers nothing -------------------------------------------------
;; QUEUE-3. The queue is an index over documents and the DOCUMENT is what is
;; authorized — after the SQL window, per row, as `repo-list` does. So a row
;; pointing at something the caller cannot read is simply absent, and the count
;; is "what you may read" rather than "what is there".
(test-case "a row pointing at a document the caller cannot read is not listed"
  (define-values (c p tid) (setup))
  (define buid (create-user! c #:username "bob"))
  (add-member! c #:user buid #:team tid #:role "member")
  (define bob (user-principal c buid tid))
  ;; root's own private item, queued by root
  (define secret (item c p "feeds/gh/secret.json" #:visibility "private"))
  (define shared (item c p "feeds/gh/shared.json"))
  (queue-upsert! c p secret)
  (queue-upsert! c p shared)
  (check-equal? (length (queue-rows c p)) 2 "the owner sees both")
  ;; bob is an ordinary member: private is private from everybody but the owner
  (check-equal? (ids (queue-rows c bob)) '("feeds/gh/shared.json")))

(test-case "an object that does not exist cannot be queued"
  (define-values (c p tid) (setup))
  (check-exn #rx"no such item"
             (lambda () (queue-upsert! c p "11111111-2222-3333-4444-555555555555"))))

(test-case "a status outside the vocabulary is refused on the way in and on the way out"
  (define-values (c p tid) (setup))
  (define a (item c p "feeds/gh/a.json"))
  (check-exn #rx"not a status this queue has"
             (lambda () (queue-upsert! c p a #:status "urgent")))
  (queue-upsert! c p a)
  (check-exn #rx"not a status this queue has"
             (lambda () (queue-set-status! c p a "urgent")))
  (check-equal? (hash-ref (queue-set-status! c p a "claimed") 'status) "claimed")
  (check-equal? (hash-ref (car (queue-rows c p)) 'status) "claimed"))

;; An object id is instance-global, so without the team clause a caller could
;; name another company's row and learn whether it exists — `org-team-resolve`'s
;; lesson, which cost that slice a unit test.
(test-case "another team's queue is not this team's"
  (define-values (c p tid) (setup))
  (define a (item c p "feeds/gh/a.json"))
  (queue-upsert! c p a)
  (define other (create-team! c #:name "Other" #:slug "other"))
  (define ouid (create-user! c #:username "carol"))
  (add-member! c #:user ouid #:team other #:role "owner")
  (define carol (user-principal c ouid other))
  (check-equal? (queue-rows c carol) '() "the listing is scoped to the caller's team")
  ;; and she cannot move it — though NOT because of the team clause: `can?`
  ;; refuses her the DOCUMENT first, which is the next case's whole point
  (check-exn #rx"no such item" (lambda () (queue-set-status! c carol a "done"))))

;; THE TEAM CLAUSE ON THE WRITE NEEDS ITS OWN CASE, and a positive control is
;; what showed that: the case above passes with the clause removed, because
;; `readable` refuses the document before the SQL is reached. So the clause —
;; defence in depth against an object id, which is instance-global — was
;; untested while looking tested, which is #113's shape in a test file.
;;
;; The state it defends against is a caller who CAN read the document while the
;; queue row belongs to somebody else. The row is made by hand, because no code
;; path here produces it: that is what defence in depth means, and a guard with
;; no reachable caller still has to be exercised or it is decoration.
(test-case "a row whose team is not the caller's cannot be moved, even on a readable document"
  (define-values (c p tid) (setup))
  (define a (item c p "feeds/gh/a.json"))
  (query-exec c (string-append "INSERT INTO x_feeds_items"
                               " (object_id, team_id, feed_slug, title, priority, due_epoch,"
                               "  status, skills, updated_epoch)"
                               " VALUES (?, ?, NULL, ?, ?, NULL, ?, ?, ?)")
              a "some-other-team" "a.json" 50 "open" "" 1700000000)
  ;; root can read the document perfectly well …
  (check-true (hash? (repo-get c p a)))
  ;; … and still cannot move a row that is not this team's
  (check-exn #rx"no such item" (lambda () (queue-set-status! c p a "done")))
  (check-equal? (query-value c "SELECT status FROM x_feeds_items WHERE object_id = ?" a) "open"))

;; ---- 4. slice 6: a proposal, which is NOT an act -------------------------------
;; FEED-10, and the owner's answer to question 3 on #114: the agent PROPOSES and
;; a `review` step gates anything that would act. The model is scripted here,
;; which is the only reason these cases can exist — the first version of the
;; plugin called `run-chat` directly and this whole section was unwritable.

(define (scripted reply #:tokens [tokens 11])
  (lambda (prompt #:system [sys #f] #:conn [conn #f] #:team [team #f])
    (values reply tokens)))

(define SAMPLE-PROPOSAL
  (string-append "## What this is\nA flaky webhook test.\n\n"
                 "## Proposed action\nRe-run the job once, then close it.\n\n"
                 "## Why this and not something else\nA re-run that goes green is cheap."))

(test-case "a proposal is a DOCUMENT derived from the item, and it says it is a proposal"
  (define-values (c p tid) (setup))
  (define a (item c p "feeds/gh/acme-repo-7.json" #:body "{\"title\":\"flaky webhook test\"}"))
  (define r (parameterize ([current-feed-chat (scripted SAMPLE-PROPOSAL)])
              (propose! c p (hasheq 'object a))))
  ;; beside the item, with the item's own key as the stem — so a listing reads
  ;; as a family and "Processed by" finds it through the derivation row
  (check-equal? (hash-ref r 'key) "feeds/gh/acme-repo-7.json.proposal.md")
  ;; NOTHING ACTED, and the result says so rather than leaving a reader to assume
  (check-false (hash-ref r 'acted))
  (check-equal? (hash-ref r 'item) a)
  ;; the document carries the model's text AND the standing warning, because the
  ;; person reading it in a month has no other way to know it was never carried out
  (check-true (regexp-match? #rx"Re-run the job once" (hash-ref r 'proposal)))
  (check-true (regexp-match? #rx"A PROPOSAL, not an action" (hash-ref r 'proposal)))
  ;; and it really is in the repository, with a derivation row naming the item it
  ;; is about. `repo-derivations` is asked about the DERIVED document and answers
  ;; its SOURCES — the first version of this case asked it about the item and got
  ;; an empty list, which is the function working.
  (define sources (repo-derivations c p (hash-ref r 'object_id)))
  (check-equal? (length sources) 1)
  (check-equal? (hash-ref (car sources) 'source_object_id) a))

;; A DERIVED DOCUMENT IS PRIVATE FROM ITS FIRST BYTE (DWF-4), and this case
;; asserts the END STATE only — which a positive control is what established.
;; Patching `repo-derive!` to put the document at `team` visibility leaves this
;; green, because `repo-inherit!` (DSH-5) copies the source's visibility
;; afterwards and would correct it. The put's `#:visibility` closes the WINDOW
;; between the two statements, and no test at this level can observe a window;
;; it is stated here rather than left for a reader to assume this assertion
;; covers it. What this case does catch is the pair failing together.
(test-case "a proposal ends up with the item's visibility"
  (define-values (c p tid) (setup))
  (define a (item c p "feeds/gh/private.json" #:visibility "private"))
  (define r (parameterize ([current-feed-chat (scripted SAMPLE-PROPOSAL)])
              (propose! c p (hasheq 'object a))))
  (define doc (repo-get c p (hash-ref r 'object_id)))
  (check-equal? (hash-ref doc 'visibility) "private"))

(test-case "an empty reply is refused rather than stored as a proposal"
  (define-values (c p tid) (setup))
  (define a (item c p "feeds/gh/a.json"))
  (check-exn #rx"empty proposal"
             (lambda () (parameterize ([current-feed-chat (scripted "   \n ")])
                          (propose! c p (hasheq 'object a))))))

(test-case "a proposal about an item the caller cannot read is refused by id"
  (define-values (c p tid) (setup))
  (define buid (create-user! c #:username "dave"))
  (add-member! c #:user buid #:team tid #:role "member")
  (define dave (user-principal c buid tid))
  (define a (item c p "feeds/gh/secret.json" #:visibility "private"))
  (check-exn #rx"no such item"
             (lambda () (parameterize ([current-feed-chat (scripted SAMPLE-PROPOSAL)])
                          (propose! c dave (hasheq 'object a))))))

;; ---- 5. the workflows -----------------------------------------------------------
;; A plugin's spec goes through the SAME `validate-spec` a posted document does
;; (WF-9), so these assertions are about what the specs SAY rather than about
;; whether they parse — the loader already refused to load the plugin when the
;; checklist item used the wrong key, which is how that mistake surfaced.
(test-case "the propose workflow parks on a person, and no verdict leads to an act"
  (define spec (for/first ([w (in-list workflows)]
                           #:when (equal? (hash-ref w 'slug) "feed-propose"))
                 w))
  (check-true (hash? spec))
  (define steps (hash-ref spec 'steps))
  (check-equal? (map (lambda (s) (hash-ref s 'id)) steps) '("propose" "decide"))
  (define decide (cadr steps))
  (check-equal? (hash-ref decide 'uses) "review")
  ;; EVERY verdict ends the run or sends it back. There is no acting step for
  ;; `approve` to name, because v1 has nothing that acts — and this assertion is
  ;; what would fail the day somebody adds one without a second thought.
  (define on (hash-ref decide 'on))
  (check-equal? (hash-ref on 'approve) 'null "approve ends the run — v1 has no acting tool")
  (check-equal? (hash-ref on 'reject) 'null)
  (check-equal? (hash-ref on 'revise) "propose" "a revision asks the model again")
  ;; four eyes is OFF, deliberately: the subject is model-produced, so LAY-3's
  ;; NULL-author case applies and a team of one can still finish the run
  (check-false (hash-ref decide 'four_eyes #f)))

(test-case "no tool this plugin registers claims to act"
  ;; FEED-10's line, as a check rather than a sentence: an acting tool must
  ;; declare that it acts, run behind a review step and receive only the
  ;; credentials it declared. None of these three do anything outside the
  ;; instance, and the day one does, this assertion is where it is noticed.
  (check-equal? (sort (map car tools) string<?)
                '("feed_propose" "feed_queue_put" "feed_queue_status")))
