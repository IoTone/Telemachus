#lang racket/base

;; test/note-format-tests.rkt — a note's body format (#246 slice 1), ORG-1/ORG-2.
;;
;; THE RENDERER IS NOT TESTED HERE AND CANNOT BE. `orgRender` is JavaScript in
;; `static/console/15-editor.js`, and "does it escape" is a question about what
;; the code COMPUTES — ED-4's rule, which is why the Markdown preview has its own
;; runtime case in `test/e2e/demo-validate.mjs` §3c and not a source assertion.
;; The org renderer gets its own block there, with an `<img onerror>`, a
;; `<script>`, an `[[javascript:…][click]]` and its entity-encoded form, and a
;; `#+BEGIN_SRC` block whose asterisks must stay literal.
;;
;; What IS decidable on this side is the column, the closed vocabulary, the
;; refusal, and ORG-2's promise that converting a note does not touch its body.
;;
;;   raco test test/note-format-tests.rkt
;;   DATABASE_URL="postgres://…" raco test test/note-format-tests.rkt
;;
;; Runs whole on both dialects: the column is added by an `ALTER TABLE … ADD
;; COLUMN … NOT NULL DEFAULT`, which is one of the few DDL shapes both engines
;; spell the same way, and that is exactly the kind of thing not to take on trust
;; from one of them.

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

;; ---- ORG-1: the vocabulary is closed, and the SET is pinned ----------------
(test-case "NOTE-FORMATS is pinned as a literal, Markdown first"
  ;; PINNED, NOT RE-DERIVED — `vocabulary-tests.rkt`'s rule. A test that rebuilt
  ;; this list from the module would agree with any change whatsoever, and the
  ;; point of a closed vocabulary is that adding to it is a decision somebody
  ;; makes on purpose: the console switches on it, `orgRender` is picked from it,
  ;; and a third member nothing can draw would arrive as a note that renders
  ;; blank.
  (check-equal? NOTE-FORMATS '("markdown" "org"))
  ;; the head and the COLUMN's default have to agree, or a note created with no
  ;; format carries one the vocabulary leads with somewhere else
  (check-equal? (car NOTE-FORMATS) "markdown"))

(test-case "an unknown format is refused by name, never coerced"
  ;; The alternative is a silent substitution, which is a note that renders as
  ;; something other than what its author asked for with no way to find out but
  ;; to look. The message NAMES the acceptable set, as CLS-15's label refusal
  ;; does.
  (check-false (format-problem "markdown"))
  (check-false (format-problem "org"))
  (define p (format-problem "orgmode"))
  (check-true (string? p))
  (check-true (and (regexp-match? #rx"markdown" p) (regexp-match? #rx"org" p)) p)
  ;; a non-string is its own refusal rather than a contract violation deep in a
  ;; `member` call
  (check-true (string? (format-problem 7)))
  (check-true (string? (format-problem 'org))))

;; ---- ORG-1: the default, which is the whole of the upgrade promise ---------
(test-case "a note created with no format is Markdown"
  (define-values (c p tid) (setup))
  (define n (notes-create c p #:title "plain" #:body "# hi"))
  (check-equal? (hash-ref n 'format) "markdown")
  ;; and it is on every READ, not only on the create's answer — RED-20's shape,
  ;; where the gap is reported rather than assumed, and what makes a default of
  ;; "markdown" honest rather than quiet
  (check-equal? (hash-ref (notes-get c p (hash-ref n 'id)) 'format) "markdown")
  (check-equal? (hash-ref (car (notes-list c p)) 'format) "markdown")
  (close-db! c))

(test-case "a row written before the column existed reads as Markdown"
  ;; THE UPGRADE PROMISE, and it is the reason the migration carries a DEFAULT
  ;; rather than a backfill: every note that exists is Markdown, and `mdRender`
  ;; is the only renderer the §3c sanitiser case covers. A raw INSERT that names
  ;; no format is the closest this suite can come to a pre-0073 row.
  (define-values (c p tid) (setup))
  (query-exec c (string-append "INSERT INTO notes (id, team_id, owner_user_id, visibility, title, body) "
                               "VALUES (?, ?, ?, ?, ?, ?)")
              "old-note" tid (principal-user-id p) "team" "older" "* a markdown bullet")
  (define n (notes-get c p "old-note"))
  (check-equal? (hash-ref n 'format) "markdown")
  ;; and this is the body ORG-1's "never auto-detected" is about: `* something`
  ;; is a valid Markdown bullet AND a valid org headline, so a detector would
  ;; silently re-render it
  (check-equal? (hash-ref n 'body) "* a markdown bullet")
  (close-db! c))

(test-case "a note can be created as org"
  (define-values (c p tid) (setup))
  (define n (notes-create c p #:title "org" #:body "* Heading\n- one\n" #:format "org"))
  (check-equal? (hash-ref n 'format) "org")
  (close-db! c))

(test-case "a malformed format refuses the whole create"
  ;; VEC-21's order: every validation runs before anything is written, so a bad
  ;; format leaves no note behind for somebody to notice is rendering wrongly.
  (define-values (c p tid) (setup))
  (check-exn exn:fail? (lambda () (notes-create c p #:title "no" #:body "x" #:format "ORG")))
  (check-equal? (length (notes-list c p)) 0)
  (close-db! c))

;; ---- ORG-2: converting is a declaration, never a rewrite ------------------
(test-case "converting a note changes the format and NOT the body"
  ;; THE WHOLE OF ORG-2, and the reason a conversion was declined: running the
  ;; org renderer over Markdown source produces a readable mess rather than an
  ;; error, which is honest and REVERSIBLE — where a conversion is neither, and
  ;; one that got a single construct wrong would have eaten the only copy.
  (define-values (c p tid) (setup))
  (define body "# Title\n\n**bold** and [a link](https://example.test/x)\n")
  (define n (notes-create c p #:title "convert me" #:body body))
  (define id (hash-ref n 'id))
  (define as-org (notes-update c p id #:format "org"))
  (check-equal? (hash-ref as-org 'format) "org")
  (check-equal? (hash-ref as-org 'body) body "the body is untouched by a conversion")
  ;; and BACK, which is what "reversible" means: nothing was lost on the way out
  (define back (notes-update c p id #:format "markdown"))
  (check-equal? (hash-ref back 'format) "markdown")
  (check-equal? (hash-ref back 'body) body)
  (close-db! c))

(test-case "a missing format on an update leaves the stored one alone"
  ;; An ordinary absent-is-leave-alone field beside title and visibility, and
  ;; deliberately NOT tags' absent/clear pair: there is no "no format", so there
  ;; is nothing for `null` to mean.
  (define-values (c p tid) (setup))
  (define id (hash-ref (notes-create c p #:title "o" #:body "x" #:format "org") 'id))
  (define n (notes-update c p id #:title "renamed"))
  (check-equal? (hash-ref n 'format) "org")
  (check-equal? (hash-ref n 'title) "renamed")
  (close-db! c))

(test-case "a malformed format on an update writes nothing at all"
  (define-values (c p tid) (setup))
  (define id (hash-ref (notes-create c p #:title "keep" #:body "x") 'id))
  (check-exn exn:fail? (lambda () (notes-update c p id #:title "moved" #:format "wiki")))
  (define n (notes-get c p id))
  (check-equal? (hash-ref n 'format) "markdown")
  (check-equal? (hash-ref n 'title) "keep"
                "the title is not written either — the format is cleaned first")
  (close-db! c))

;; ---- what does not change -------------------------------------------------
(test-case "the format is not a permission and does not reach can?"
  ;; "There is no new permission and no feature switch: both renderers ship on
  ;; every instance, because a format is not a capability." A member reads and
  ;; writes an org note exactly as they do a Markdown one.
  (define-values (c p tid) (setup))
  (define u (create-user! c #:username "mem" #:password "pw"))
  (add-member! c #:user u #:team tid #:role "member")
  (define mp (user-principal c u tid))
  (define id (hash-ref (notes-create c p #:title "team org" #:body "* h" #:format "org") 'id))
  (check-equal? (hash-ref (notes-get c mp id) 'format) "org")
  (check-equal? (hash-ref (notes-update c mp id #:format "markdown") 'format) "markdown")
  (close-db! c))

(test-case "tags and the format DO interact now, and ORG-12 is why"
  ;; THIS CASE USED TO ASSERT THE OPPOSITE, and its own comment said that saying
  ;; so was what would make the next slice's change visible as a change. It did:
  ;; slice 3 makes an org note's `#+FILETAGS:` line authoritative, so a `tags`
  ;; field against one is refused by name rather than stored and then quietly
  ;; undone by the next body save. The failing test is what said the behaviour
  ;; had moved, which is the whole point of having written it.
  (define-values (c p tid) (setup))
  (check-exn exn:fail?
             (lambda () (notes-create c p #:title "both" #:body "* h"
                                      #:format "org" #:tags '("Levee" "q3"))))
  ;; …and an EMPTY list asks for nothing, so there is nothing to refuse: `#:tags`
  ;; defaults to `'()` and the endpoint maps an absent key to it, which makes a
  ;; caller who said nothing indistinguishable from one who sent `[]`.
  (define n (notes-create c p #:title "both" #:body "* h" #:format "org"))
  (check-equal? (hash-ref n 'tags) '())
  (check-equal? (hash-ref n 'format) "org")
  ;; a MARKDOWN note is untouched by any of it — #245 works exactly as it did
  (define m (notes-create c p #:title "md" #:body "x" #:tags '("Levee" "q3")))
  (check-equal? (hash-ref m 'tags) '("levee" "q3"))
  (close-db! c))
