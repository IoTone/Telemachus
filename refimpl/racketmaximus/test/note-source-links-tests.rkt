#lang racket/base

;; test/note-source-links-tests.rkt — a note's links to documents and bookmarks,
;; and wiki-links in Markdown (#191).
;;
;;   raco test test/note-source-links-tests.rkt
;;   DATABASE_URL="postgres://…" raco test test/note-source-links-tests.rkt
;;
;; WHAT THIS FILE IS FOR is the rule that a source the reader may not open
;; answers EXACTLY as one that does not exist. The cases compare the two answers
;; with each other rather than checking that something is absent, because an
;; absence check passes against a server that says "forbidden".

(require rackunit db-kit/portable racket/list racket/string racket/file
         db-kit/migrate
         "../domain/db/migrations.rkt"
         "db-fixture.rkt"
         "../domain/authz/authz.rkt"
         "../domain/repo/repo.rkt"
         "../domain/repo/blobs.rkt"
         "../domain/research/research.rkt"
         "../domain/notes/notes.rkt"
         "../domain/notes/org-links.rkt")

(define BLOB-ROOT (make-temporary-file "tmx-nsl-~a" 'directory))
(current-blob-root BLOB-ROOT)

(define (fresh) (define c (fresh-db #:migrate? #f)) (migrate! c all-migrations) c)
(define (setup)
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "root"))
  (values c (user-principal c uid tid) tid))
(define (member-of c team username #:role [role "member"])
  (define u (create-user! c #:username username #:password "pw-fixture-1"))
  (add-member! c #:user u #:team team #:role role)
  (user-principal c u team))
(define (doc! c p key #:visibility [vis "team"] #:filename [fn ""])
  (repo-put! c p #:key key #:port (open-input-bytes #"x") #:content-type "text/plain"
             #:filename fn #:visibility vis))
(define (bookmark! c p team url #:title [title #f])
  (research-create! c #:team team #:user (principal-user-id p) #:url url #:title title
                    #:note #f #:created-by (principal-user-id p)))
(define (md c p title body) (notes-create c p #:title title #:body body))
(define (links c p n) (note-links-of c p (hash-ref n 'id)))
(define (shape l) (hash-remove l 'target))

;; ---- the two parsers, with no database ---------------------------------------
(test-case "markdown wiki-links: bare, piped, and never inside code"
  (check-equal? (md-link-targets "see [[Alpha]] and [[Beta|the second]]")
                '(("Alpha" "alpha" "") ("Beta" "beta" "the second")))
  (check-equal? (md-link-targets "inline `[[NotALink]]` stays text") '()
                "an inline code span is text about a link")
  (check-equal? (md-link-targets "```\n[[InFence]]\n```\nthen [[Real]]")
                '(("Real" "real" ""))
                "a fenced block is lifted out first, as the renderer does")
  (check-equal? (md-link-targets "[[https://example.test/x|site]]") '()
                "an external target is still no edge")
  (check-equal? (md-link-targets "[[A]] [[a]] [[ A ]]") '(("A" "a" ""))
                "deduped by fold, first spelling kept")
  (check-equal? (md-link-targets "[[Org][style]]") '()
                "org's labelled form is not markdown syntax")
  (check-equal? (link-targets "[[X][y]]" "org") '(("X" "x" "y")))
  (check-equal? (link-targets "[[X|y]]" "markdown") '(("X" "x" "y"))))

(test-case "a typed target names its kind, and its fold keeps case"
  (check-equal? (typed-target "doc:reports/A.md") '("document" . "reports/A.md"))
  (check-equal? (typed-target " DOC: reports/A.md ") '("document" . "reports/A.md"))
  (check-equal? (typed-target "bookmark:https://example.com/a") '("bookmark" . "https://example.com/a"))
  (check-false (typed-target "doc:"))
  (check-false (typed-target "docs:thing"))
  (check-false (typed-target "Levee 7 survey"))
  ;; a key and a URL path are case-sensitive, so these are two documents
  (check-equal? (map cadr (md-link-targets "[[doc:Reports/A.md]] [[doc:reports/a.md]] [[DOC:reports/a.md]]"))
                '("doc:Reports/A.md" "doc:reports/a.md"))
  (check-equal? (map car (org-link-targets "[[bookmark:https://example.com/a][the page]]"))
                '("bookmark:https://example.com/a")
                "a bookmark target is not an external one, although it contains a URL"))

;; ---- documents -----------------------------------------------------------------
(test-case "a note links to a document by key or by id"
  (define-values (c root tid) (setup))
  (define alice (member-of c tid "alice"))
  (define o (doc! c alice "surveys/levee-7.txt" #:filename "Levee 7 field survey"))
  (define n (md c alice "n" (format "from [[doc:surveys/levee-7.txt|the survey]] and [[doc:~a]]"
                                    (hash-ref o 'id))))
  (define ls (links c alice n))
  (check-equal? (length ls) 2)
  (for ([l (in-list ls)])
    (check-false (hash-ref l 'broken))
    (check-equal? (hash-ref l 'kind) "document")
    (check-equal? (hash-ref l 'object_id) (hash-ref o 'id))
    (check-equal? (hash-ref l 'key) "surveys/levee-7.txt")
    (check-equal? (hash-ref l 'title) "Levee 7 field survey"))
  (check-equal? (hash-ref (car ls) 'label) "the survey")
  (close-db! c))

(test-case "a document the reader may not open answers exactly as one that is not there"
  (define-values (c root tid) (setup))
  (define alice (member-of c tid "alice"))
  (define bob (member-of c tid "bob"))
  (define secret (doc! c alice "legal/secret.txt" #:visibility "private"))
  (define n (md c bob "n" (format "[[doc:legal/secret.txt]] [[doc:legal/no-such.txt]] [[doc:~a]] [[doc:00000000-0000-0000-0000-000000000000]]"
                                  (hash-ref secret 'id))))
  (define ls (links c bob n))
  (check-equal? (length ls) 4)
  (check-equal? (shape (first ls)) (shape (second ls))
                "by key: private and nonexistent are one answer")
  (check-equal? (shape (third ls)) (shape (fourth ls))
                "by id: private and nonexistent are one answer")
  (check-true (hash-ref (first ls) 'broken))
  (check-equal? (hash-ref (first ls) 'reason) "missing")
  ;; …and the owner's own read of the same note resolves it, or the equality
  ;; above would hold for a link that never resolves for anybody
  (define own (links c alice n))
  (check-false (hash-ref (first own) 'broken))
  (check-equal? (hash-ref (first own) 'object_id) (hash-ref secret 'id))
  (close-db! c))

(test-case "a document in another team resolves to nothing"
  ;; What this case does NOT establish, checked by removing the team test in
  ;; `note-sources.rkt`: it still passes, because the reader's ordinary
  ;; permission check already refuses another team's document. The explicit team
  ;; test is there for a document SHARED across teams, which this fixture does
  ;; not create.
  (define-values (c root tid) (setup))
  (define alice (member-of c tid "alice"))
  (define t2 (create-team! c #:name "Other" #:slug "other"))
  (add-member! c #:user (principal-user-id alice) #:team t2 #:role "member")
  (define alice2 (user-principal c (principal-user-id alice) t2))
  (define o (doc! c alice2 "there/x.txt"))
  (define n (md c alice "n" (format "[[doc:~a]] [[doc:there/x.txt]]" (hash-ref o 'id))))
  (check-equal? (map (lambda (l) (hash-ref l 'broken)) (links c alice n)) '(#t #t))
  (close-db! c))

;; ---- bookmarks -----------------------------------------------------------------
(test-case "a note links to a bookmark by URL or by id, and a link written first heals"
  (define-values (c root tid) (setup))
  (define alice (member-of c tid "alice"))
  (define n (md c alice "n" "read [[bookmark:https://Example.com/a#top|the page]]"))
  (check-true (hash-ref (car (links c alice n)) 'broken)
              "nothing is bookmarked yet")
  (define sid (bookmark! c alice tid "https://example.com/a" #:title "Example A"))
  (define l (car (links c alice n)))
  (check-false (hash-ref l 'broken) "bookmarking the page afterwards is what resolves the link")
  (check-equal? (hash-ref l 'kind) "bookmark")
  (check-equal? (hash-ref l 'source_id) sid)
  (check-equal? (hash-ref l 'url) "https://example.com/a")
  (check-equal? (hash-ref l 'title) "Example A")
  (define n2 (md c alice "n2" (format "[[bookmark:~a]]" sid)))
  (check-equal? (hash-ref (car (links c alice n2)) 'source_id) sid)
  (research-delete! c sid tid)
  (check-true (hash-ref (car (links c alice n)) 'broken)
              "and forgetting the bookmark breaks it again, with nothing to reset")
  (close-db! c))

(test-case "a reader without research:use sees a bookmark link as missing"
  (define-values (c root tid) (setup))
  (define alice (member-of c tid "alice"))
  (define vera (member-of c tid "vera" #:role "viewer"))
  (bookmark! c alice tid "https://example.com/a")
  (define n (md c alice "n" "[[bookmark:https://example.com/a]] [[bookmark:https://example.com/none]]"))
  (define ls (links c vera n))
  (check-equal? (shape (first ls)) (shape (second ls))
                "bookmarked and not bookmarked are one answer for her")
  (check-false (hash-ref (first (links c alice n)) 'broken))
  (close-db! c))

;; ---- the graph -----------------------------------------------------------------
(test-case "the graph draws a cited source as a node of its own kind"
  (define-values (c root tid) (setup))
  (define alice (member-of c tid "alice"))
  (define bob (member-of c tid "bob"))
  (define o (doc! c alice "surveys/levee-7.txt"))
  (define secret (doc! c alice "legal/secret.txt" #:visibility "private"))
  (define sid (bookmark! c alice tid "https://example.com/a" #:title "Example A"))
  (define a (md c alice "A" "[[doc:surveys/levee-7.txt]] [[bookmark:https://example.com/a]] [[doc:legal/secret.txt]]"))
  (define b (md c alice "B" (format "[[doc:~a]] [[A]]" (hash-ref o 'id))))
  (define (kinds g) (sort (map (lambda (n) (hash-ref n 'kind)) (hash-ref g 'nodes)) string<?))
  (define (node g id) (findf (lambda (n) (equal? (hash-ref n 'id) id)) (hash-ref g 'nodes)))
  (define g (note-graph c alice))
  (check-equal? (kinds g) '("bookmark" "document" "document" "note" "note"))
  (define dn (node g (string-append "doc:" (hash-ref o 'id))))
  (check-true (hash? dn) "two spellings of one document are ONE node")
  (check-equal? (hash-ref dn 'object_id) (hash-ref o 'id))
  (check-equal? (hash-ref (node g (string-append "bookmark:" sid)) 'url) "https://example.com/a")
  (check-equal? (length (filter (lambda (e) (equal? (hash-ref e 'to) (hash-ref dn 'id)))
                                (hash-ref g 'edges)))
                2)
  ;; bob may not open the private document: for him it is an unwritten target,
  ;; labelled with what the author typed and nothing else
  (define gb (note-graph c bob))
  (check-equal? (kinds gb) '("bookmark" "document" "missing" "note" "note"))
  (define ph (findf (lambda (n) (hash-ref n 'missing)) (hash-ref gb 'nodes)))
  (check-equal? (hash-ref ph 'title) "doc:legal/secret.txt")
  (check-false (hash-has-key? ph 'object_id))
  ;; a neighbourhood reaches a source through the walk like any other node
  (define gn (note-graph c alice #:note (hash-ref b 'id) #:depth 1))
  (check-equal? (kinds gn) '("document" "note" "note"))
  (close-db! c))
