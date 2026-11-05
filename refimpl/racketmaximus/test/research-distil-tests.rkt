#lang racket/base

;; test/research-distil-tests.rkt — #191 slice 2, and the finding is that most of
;; it is already true.
;;
;;   raco test test/research-distil-tests.rkt
;;
;; RG-5 says "there is no second graph: a distilled bookmark is another document
;; in the one that exists", and the build plan's slice 2 says "the graph fills by
;; itself". **Those are claims about the SHIPPED drains, and nothing asserted
;; them.** This file does, end to end and through the real workflow specs rather
;; than by calling the tools directly, because what is being established is that
;; the PUBLISHED pipelines cover an archived page with no research-specific code:
;;
;;   bookmark -> research-fetch! -> Index Documents -> Index Knowledge
;;     -> an entity whose mention names the archived page AND the version it was
;;        read from
;;
;; That last line is RG-5's actual promise and the one a bookmark manager cannot
;; make. If this file ever fails, the thing to check first is whether a lister
;; grew a filter that excludes an archived page — `kg-list-unextracted` already
;; excludes DERIVED documents (CLS-26), which is exactly why `research-fetch!`
;; passes `#:derived? #f` deliberately rather than by omission.

(require rackunit db-kit/portable
         racket/port racket/string racket/file json
         db-kit/migrate
         "../domain/db/migrations.rkt"
         "db-fixture.rkt"
         "../domain/authz/authz.rkt"
         "../domain/repo/blobs.rkt"
         (only-in "../domain/repo/repo.rkt" repo-list repo-put! repo-set-visibility!)
         (only-in "../domain/repo/extract.rkt" repo-text-for)
         "../domain/repo/doc-tools.rkt"              ; current-doc-chat
         (only-in "../domain/repo/index-tools.rkt")  ; registers the indexing tools
         "../domain/kg/kg.rkt"
         "../domain/kg/kg-tools.rkt"
         "../domain/research/research.rkt"
         "../domain/research/research-tools.rkt"
         (only-in "../domain/apps/search.rkt" search-all)
         "../domain/agent/registry.rkt"
         "../domain/sched/scheduler.rkt"
         "../domain/flow/run.rkt"
         (prefix-in indexer: "../plugins/doc-indexer/main.rkt")
         (prefix-in kgp: "../plugins/knowledge-graph/main.rkt")
         (prefix-in rp: "../plugins/research/main.rkt"))

(define BLOB-ROOT (make-temporary-file "telemachus-rdistil-~a" 'directory))
(current-blob-root BLOB-ROOT)

(define (fresh)
  (define c (fresh-db #:migrate? #f))
  (migrate! c all-migrations)
  c)
(define (drain! conn [limit 300])
  (let loop ([n 0]) (when (and (< n limit) (process-one! conn)) (loop (add1 n)))))

;; A page worth distilling, and deliberately HTML — the format a bookmark
;; actually arrives in. `text/html` is in `extract.rkt`'s markup list, so the
;; built-in extractor strips the tags; that is the whole reason this needs no
;; research-specific reader.
(define PAGE
  (string-append
   "<html><head><title>Levee 7</title></head><body>"
   "<h1>Levee 7 inspection</h1>"
   "<p>Acme Robotics inspected Levee 7 for the Port Authority in 2026.</p>"
   "</body></html>"))

(define (extraction)
  (hasheq 'entities (list (hasheq 'type "organization" 'name "Acme Robotics" 'description "an inspection contractor"
                                  'snippet "Acme Robotics inspected Levee 7")
                          (hasheq 'type "organization" 'name "Port Authority" 'description ""
                                  'snippet "for the Port Authority"))
          'relations (list (hasheq 'subject "Acme Robotics" 'predicate "inspected_for" 'object "Port Authority"
                                   'snippet "Acme Robotics inspected Levee 7 for the Port Authority"))))

(define (scripted-chat)
  (lambda (prompt #:system [sys #f])
    (values (jsexpr->string (extraction)) 1)))

(define ((canned status headers body) _url) (values status headers body))

;; ---- the whole chain, through the SHIPPED specs ----------------------------------
(test-case "an archived bookmark reaches the knowledge graph through the existing drains, with no research-specific code"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice" #:org-name "Acme" #:org-slug "acme"
                                       #:team-name "Eng" #:team-slug "eng"))
  (define alice (user-principal c uid tid))
  (register-plugin-workflow! "doc-indexer" (car indexer:workflows))
  (register-plugin-workflow! "knowledge-graph" (car kgp:workflows))

  ;; 1. bookmark and archive. The fetch goes through the `#:fetch` seam for
  ;;    RG-19's reason: `'untrusted` refuses every address a suite can listen on,
  ;;    which is the policy working rather than something to work around.
  (define id (research-create! c #:team tid #:user uid #:url "https://example.com/levee-7"
                               #:title "Levee 7 inspection" #:note #f #:created-by uid))
  (define out (research-fetch! c alice (research-get c id tid)
                               #:fetch (canned 200 '(("content-type" . "text/html"))
                                               (string->bytes/utf-8 PAGE))))
  (check-true (hash-ref out 'ok) (format "~a" out))
  (define oid (hash-ref out 'object_id))

  ;; 2. THE ARCHIVED PAGE IS OFFERED TO THE TEXT DRAIN. Not asserted through the
  ;;    tool but through the shipped workflow, because what is in question is
  ;;    whether the PUBLISHED pipeline covers it.
  (void (flow-run-start! c alice (flow-def-by-slug c alice "index-documents")))
  (drain! c)
  (define text (repo-text-for c oid))
  (check-true (and (string? text) (string-contains? text "Acme Robotics"))
              (format "the built-in markup extractor read the page: ~s" text))
  (check-false (and (string? text) (string-contains? text "<h1>"))
               "…and stripped the tags, which is why no research-specific reader is needed")

  ;; 3. …AND THEN TO THE GRAPH DRAIN. `kg-list-unextracted` excludes DERIVED
  ;;    documents, so this is also the assertion that an archived page is not one
  ;;    — `research-fetch!` passes `#:derived? #f` deliberately.
  (check-true (and (member oid (kg-list-unextracted c alice)) #t)
              "the archived page is offered to the graph drain")
  (parameterize ([current-doc-chat (scripted-chat)])
    (void (flow-run-start! c alice (flow-def-by-slug c alice "index-knowledge")))
    (drain! c))

  ;; 4. RG-5's ACTUAL PROMISE: a fact carries the page AND the version it was read
  ;;    from. That is what a bookmark manager cannot say, and it is the reason the
  ;;    design refused a second graph.
  (define found (kg-find c alice "Acme"))
  (check-true (pair? found) "the entity landed in the graph")
  (define acme (car found))
  (define ms (hash-ref (kg-entity c alice (hash-ref acme 'id)) 'mentions '()))
  (check-true (pair? ms) "with a mention")
  (define m (car ms))
  (check-equal? (hash-ref m 'object_id) oid "the mention names the archived page")
  (check-equal? (hash-ref m 'version_id) (hash-ref out 'version_id)
                "…AND the version it was read from, which is the provenance RG-5 promises")
  ;; the relation too, so "what do we know about Acme" is a graph and not a list
  (check-true (pair? (hash-ref (kg-entity c alice (hash-ref acme 'id)) 'relations '()))
              "and the relation between the two entities")

  ;; 5. and the page is searchable by its own content, which is what makes the
  ;;    archive worth keeping rather than merely stored.
  (check-true (pair? (search-all c alice "Levee"))
              "the archived page answers a keyword search"))

;; ---- what IS research-specific: knowing which bookmarks are behind ---------------
(test-case "`research-list` is not an answer to \"which bookmarks still need distilling\""
  ;; The honest reason slice 2 wants a lister of its own. The chain above is
  ;; covered by the shipped drains, but those are keyed on the whole team's
  ;; documents — so an operator who has just bookmarked twelve pages cannot drain
  ;; THOSE without draining everything else at the same batch size, and nothing
  ;; answers "is this bookmark distilled yet" at all.
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice"))
  (define alice (user-principal c uid tid))
  (define id (research-create! c #:team tid #:user uid #:url "https://example.com/a"
                               #:title "A" #:note #f #:created-by uid))
  (void (research-fetch! c alice (research-get c id tid)
                         #:fetch (canned 200 '(("content-type" . "text/html"))
                                         (string->bytes/utf-8 PAGE))))
  (define row (research-get c id tid))
  ;; `archived` says the bytes are there. NOTHING on the row says whether the
  ;; text, the type or the facts have been taken out of them — those markers live
  ;; on the DOCUMENT (`repo_text`, `doc_type`, `kg_extractions`), which is right
  ;; (RG-4: the distillation produces nothing new in the schema) and is why the
  ;; question needs a join rather than a column.
  (check-true (hash-ref row 'archived))
  (check-false (hash-has-key? row 'distilled)
               "deliberately absent: a column here would be a second copy of a marker the document already carries"))

;; ---- the lister: the two halves of "behind" ---------------------------------------
(define (bookmark-and-archive! c p uid tid url #:body [body PAGE] #:type [ct "text/html"])
  (define id (research-create! c #:team tid #:user uid #:url url #:title "T" #:note #f
                               #:created-by uid))
  (define out (research-fetch! c p (research-get c id tid)
                               #:fetch (canned 200 (list (cons "content-type" ct))
                                               (if (bytes? body) body (string->bytes/utf-8 body)))))
  (check-true (hash-ref out 'ok) (format "~a" out))
  (hash-ref out 'object_id))

(test-case "`research_list_stale` answers both halves of behind, and only for bookmarks"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice"))
  (define alice (user-principal c uid tid))
  ;; a document that is NOT a bookmark, equally un-distilled. The lister must not
  ;; offer it — that is the whole point of a research-scoped drain.
  (define plain (repo-put! c alice #:key "uploads/notes.md" #:port (open-input-string "Acme Robotics is here.")
                           #:content-type "text/markdown"))
  (define oid (bookmark-and-archive! c alice uid tid "https://example.com/a"))
  ;; HALF ONE: no text extracted yet.
  (check-equal? (list-stale c alice (hasheq)) (list oid)
                "a freshly archived page is behind on its text, and the upload is not a bookmark")
  ;; …extract it, and it is STILL behind, on the other half.
  (void (flow-run-start! c alice (flow-def-by-slug c alice "index-documents")))
  (drain! c)
  (check-equal? (list-stale c alice (hasheq)) (list oid)
                "HALF TWO: the text is in, the facts are not")
  ;; …take the facts out, and it is done.
  (parameterize ([current-doc-chat (scripted-chat)])
    (void (flow-run-start! c alice (flow-def-by-slug c alice "index-knowledge")))
    (drain! c))
  (check-equal? (list-stale c alice (hasheq)) '()
                "nothing is behind, so a drain run finds nothing — which is how an operator knows to stop")
  ;; …and a RE-FETCH makes it behind again, because the markers are keyed to the
  ;; version. That is the property that makes re-running safe AND makes a changed
  ;; page get distilled again.
  (void (research-fetch! c alice (research-get c (car (map (lambda (r) (hash-ref r 'id))
                                                           (research-list c tid))) tid)
                         #:fetch (canned 200 '(("content-type" . "text/html"))
                                         (string->bytes/utf-8 (string-append PAGE "<p>Globex Media too.</p>")))))
  (check-equal? (list-stale c alice (hasheq)) (list oid)
                "a re-fetch is a new version, so the distillation is behind again")
  (void plain))

;; THE TERMINATION RULE, and it is the one thing in this slice that is easy to get
;; wrong and silent when wrong.
(test-case "a page that was read and had no text in it is NEVER offered again"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice"))
  (define alice (user-principal c uid tid))
  ;; RG-2's stated limitation, arriving as a test: a single-page application
  ;; archives as its loader shell, which extracts to nothing.
  (define shell "<html><head><script src=\"/app.js\"></script></head><body></body></html>")
  (define oid (bookmark-and-archive! c alice uid tid "https://example.com/spa" #:body shell))
  (check-equal? (list-stale c alice (hasheq)) (list oid) "behind on its text, like any other")
  (void (flow-run-start! c alice (flow-def-by-slug c alice "index-documents")))
  (drain! c)
  ;; The extractor wrote a row and it is EMPTY, so `kg-list-unextracted` declines
  ;; it (`t.content <> ''`) and it can NEVER acquire a `kg_extractions` row.
  (check-equal? (string-trim (or (repo-text-for c oid) "")) ""
                "the loader shell extracted to nothing, which is the case this is about")
  (check-false (member oid (kg-list-unextracted c alice))
               "the graph drain declines it, so nothing will ever mark it")
  ;; …therefore the research drain must decline it too, or an operator running the
  ;; workflow until it finds nothing never finishes (VEC-23).
  (check-equal? (list-stale c alice (hasheq)) '()
                "offered for ever is the defect; read-and-empty is a terminal state"))

(test-case "a colleague's private archive is not offered, because the step that follows could not read it"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice"))
  (define alice (user-principal c uid tid))
  (define bob (create-user! c #:username "bob"))
  (void (add-member! c #:team tid #:user bob #:role "member"))
  (define bobp (user-principal c bob tid))
  ;; alice bookmarks, and makes her archive private.
  (define oid (bookmark-and-archive! c alice uid tid "https://example.com/hers"))
  (repo-set-visibility! c alice oid "private")
  ;; BOB's drain must not be handed it: #189 step 4 found exactly this in
  ;; `repo_list_unindexed` — the id comes back, the next step raises `forbidden`,
  ;; and the run fails in a way that reads as a broken extractor.
  (check-false (member oid (list-stale c bobp (hasheq)))
               "a private archive is not offered to somebody who cannot read it")
  (check-equal? (list-stale c alice (hasheq)) (list oid) "…and its owner still sees it"))

;; ---- the whole drain, through the shipped spec ------------------------------------
(test-case "`distil-bookmarks` drains a bookmark's archive in ONE run, text then facts"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice"))
  (define alice (user-principal c uid tid))
  (register-plugin-workflow! "research" (car rp:workflows))
  (define oid (bookmark-and-archive! c alice uid tid "https://example.com/levee-7"))
  (define def (flow-def-by-slug c alice "distil-bookmarks"))
  (check-true (and def #t) "the plugin's workflow materialized")
  (define run
    (parameterize ([current-doc-chat (scripted-chat)])
      (define r (flow-run-start! c alice def))
      (drain! c)
      (flow-run-get c alice (hash-ref r 'id))))
  (check-equal? (hash-ref run 'status) "done" (format "~a" (hash-ref run 'error 'null)))
  ;; BOTH halves, in one run: the text is searchable and the facts are in the graph.
  (check-true (string-contains? (or (repo-text-for c oid) "") "Acme Robotics"))
  (define found (kg-find c alice "Acme"))
  (check-true (pair? found) "the facts landed")
  (check-equal? (hash-ref (car (hash-ref (kg-entity c alice (hash-ref (car found) 'id)) 'mentions '()))
                          'object_id)
                oid
                "and the mention names the archived page")
  ;; …and a second run finds nothing, which is what makes a drain a drain — AND
  ;; it is the case that found WF-18: with both lists empty the engine used to
  ;; deadlock a pool thread, because `complete-map!` advanced the run while
  ;; holding its own lock and the next step was another empty `map`.
  (define again
    (parameterize ([current-doc-chat (scripted-chat)])
      (define r (flow-run-start! c alice def))
      (drain! c)
      (flow-run-get c alice (hash-ref r 'id))))
  (check-equal? (hash-ref again 'status) "done")
  (check-equal? (list-stale c alice (hasheq)) '()))
