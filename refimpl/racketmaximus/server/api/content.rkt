#lang racket/base

;; server/api/content.rkt — notes, documents, search and the knowledge graph
;;
;; Split out of main.rkt by #110 r3. The shared surface every handler here
;; needs — the pool, the request accessors, with-auth/with-mt, the response
;; constructors — is server/kit.rkt.

(provide ep-notes-create ep-notes-list ep-documents-create ep-documents-list
         ep-documents-get ep-documents-update ep-documents-delete
         ep-notes-get ep-notes-update ep-notes-delete ep-notes-share
         ep-note-tags ep-notes-autotag ep-note-links ep-notes-graph ep-notes-import
         ep-search ep-kg-entities ep-kg-entity ep-kg-graph ep-kg-extract)

(require racket/string
         web-kit
         ;; `response/output`, `make-header` and `request-post-data/raw` — the
         ;; attachment the `.org` download is and the raw body the import takes
         web-server/http
         (only-in "../../config.rkt" content-encryption-enabled?)
         (only-in "../../domain/notes/notes.rkt"
                  notes-create notes-delete notes-get notes-list notes-count notes-share notes-update
                  notes-tag-list note-links-of note-backlinks-of note-graph
                  notes-import org-text-of MAX-TAGS)
         (only-in "../../domain/notes/note-tools.rkt" note-autotag!)
         (only-in "../../domain/tools/faults.rkt" exn:fail:misconfigured?)
         (only-in "../../domain/documents/documents.rkt" documents-create documents-delete documents-get documents-list documents-update)
         ;; #239: a project is a key prefix, so the folder list is derived there
         (only-in "../../domain/repo/repo.rkt" repo-prefixes)
         (only-in "../../domain/apps/search.rkt" search-all search-passages)
         (only-in "../../domain/kg/kg.rkt" STARTER-TYPES kg-entity kg-find kg-stats kg-graph)
         (only-in "../../domain/flow/run.rkt" flow-def-by-slug flow-run-start!)
         (only-in "../../domain/i18n/i18n.rkt" t)
         "../kit.rkt")

;; ---- notes (ownable/shareable resource) -------------------------------------
(define (ep-notes-create req)
  (with-auth req (lambda (p)
    (define b (read-json-body req))
    (json-response (notes-create db-conn p #:title (hash-ref b 'title "")
                                 #:body (hash-ref b 'body "")
                                 #:visibility (hash-ref b 'visibility "team")
                                 #:tags (hash-ref b 'tags '())
                                 ;; ORG-1 — absent means Markdown, which is what
                                 ;; every caller written before #246 sends
                                 #:format (hash-ref b 'format "markdown"))
                   #:code 201))))

;; #245: `?tag=` is repeatable, so it reads through `query-params` (plural) and
;; not `query-param`, which answers with the FIRST value — right for a scalar and
;; wrong for a filter you are meant to stack. LAY-4's `?attr=` paid for that
;; distinction already.
;; ---- the notes listing, paged ------------------------------------------------
;;
;; THE ONE BEHAVIOUR CHANGE IN THIS SLICE, AND IT IS VISIBLE IN THE ANSWER
;; RATHER THAN SILENT. This route used to return every note the caller could
;; read, which on a team of any size is the defect being reported; it answers a
;; PAGE now, and carries `total`, `limit` and `offset` so a caller who wants the
;; whole list can walk it. `GET /api/documents` has defaulted to a page of 20
;; since the fold, so the unbounded listing was the anomaly rather than the
;; contract — but it is a change, and anybody paging through a tag search is
;; the caller to think about first.
;;
;; `total` SUBSUMES `next_offset`, WHICH IS WHY THERE IS NO `next_offset` HERE.
;; The documents listing reports one because it has no count to offer, so "is
;; there more" is the most it can honestly say; with a total, a second field
;; computing the same fact is two spellings of it. What the total CANNOT say is
;; how much of itself the caller may read — `notes-count` is the window without
;; the per-row `can?` (CLS-27) — so a numbered pager built on it may offer a
;; page that renders short, which is the same posture `repo-count` already took.
(define NOTES-PAGE-DEFAULT 50)
(define NOTES-PAGE-MAX 200)

;; A nonsense `?limit=` falls back to the default rather than being honoured or
;; refused, and `0` is nonsense here: a page of nothing is a listing that can
;; never finish, which is the shape every interval knob in this tree already
;; declines to accept. The cap is the one bound an unauthenticated amplification
;; would otherwise be missing — `GET /api/l10n/messages` caps at 200 for it.
(define (page-limit req)
  (define n (string->number (query-param req 'limit (number->string NOTES-PAGE-DEFAULT))))
  (if (and (exact-integer? n) (positive? n)) (min n NOTES-PAGE-MAX) NOTES-PAGE-DEFAULT))

(define (page-offset req)
  (define n (string->number (query-param req 'offset "0")))
  (if (and (exact-integer? n) (>= n 0)) n 0))

(define (ep-notes-list req)
  (with-auth req (lambda (p)
    (define scope (scope-of req))
    (define tags (query-params req 'tag))
    ;; Each filter is one more EXISTS subquery, and the count was whatever the
    ;; query string held. A note carries at most MAX-TAGS, so a longer filter
    ;; can match nothing and is refused rather than run.
    (when (> (length tags) MAX-TAGS)
      (raise-user-error 'notes (format "at most ~a tag filters; ~a given" MAX-TAGS (length tags))))
    (define lim (page-limit req))
    (define off (page-offset req))
    (json-response
     (hasheq 'notes (notes-list db-conn p #:scope scope #:tags tags
                                #:limit lim #:offset off)
             'total (notes-count db-conn p #:scope scope #:tags tags)
             'limit lim
             'offset off)))))

;; TAG-1 — the team's tag list is DERIVED, so there is nothing to store and
;; nothing to keep in step. It is its own route rather than a field on the
;; listing because the console wants it to build a filter it can offer BEFORE a
;; filter has been chosen, and because `?tag=` narrows the listing it would
;; otherwise be derived from — a list that shrank as you used it.
(define (ep-note-tags req)
  (with-auth req (lambda (p)
    (json-response (hasheq 'tags (notes-tag-list db-conn p #:scope (scope-of req)))))))

;; ---- documents (offset-paginated) -------------------------------------------
;; #239: `key` files the document into a project. Absent, it composes
;; `documents/<slug>-<id8>.md` exactly as before — `put-doc!` has taken the keyword
;; since the fold and both layers above it dropped it on the floor.
(define (ep-documents-create req)
  (with-auth req (lambda (p)
    (define b (read-json-body req))
    (json-response (documents-create db-conn p #:title (hash-ref b 'title "")
                                     #:content (hash-ref b 'content "")
                                     #:key (hash-ref b 'key #f)
                                     #:visibility (hash-ref b 'visibility "team"))
                   #:code 201))))
;; The folders ride on the listing rather than on a route of their own: the tab
;; wants both to draw one screen, and a second round trip is what the sign-in
;; slice measured as the whole of what made the console feel slow.
(define (ep-documents-list req)
  (with-auth req (lambda (p)
    (define off (or (string->number (query-param req 'offset "0")) 0))
    (define prefix (query-param req 'prefix ""))
    (json-response
     (hash-set (documents-list db-conn p #:offset off #:prefix prefix)
               'folders (repo-prefixes db-conn p #:prefix prefix))))))
(define (ep-documents-get req id)
  (with-auth req (lambda (p)
    (define d (documents-get db-conn p id))
    (if d (json-response d) (err "not found" 404)))))
(define (ep-documents-update req id)
  (with-auth req (lambda (p)
    (define b (read-json-body req))
    (define d (documents-update db-conn p id #:title (hash-ref b 'title #f)
                                #:content (hash-ref b 'content #f) #:visibility (hash-ref b 'visibility #f)))
    (if d (json-response d) (err "not found" 404)))))
(define (ep-documents-delete req id)
  (with-auth req (lambda (p)
    (if (documents-delete db-conn p id) (json-response (hasheq 'ok #t 'id id)) (err "not found" 404)))))

(define (ep-notes-get req id)
  (with-auth req (lambda (p)
    ;; ORG-11 — `?as=org` answers the note as a FILE. `text/org` is NOT a
    ;; registered media type, so the bytes go out as plain text and the
    ;; EXTENSION is what carries the format — which is what every org editor
    ;; keys on anyway. `attachment` plus `nosniff` is the download path's own
    ;; posture, for the download path's own reason.
    (cond
      [(string=? (query-param req 'as "") "org")
       (define-values (name text) (org-text-of db-conn p id))
       (if name
           (response/output
            #:mime-type #"text/plain; charset=utf-8"
            #:headers (list (make-header #"X-Content-Type-Options" #"nosniff")
                            (make-header #"Content-Disposition"
                                         (string->bytes/utf-8
                                          (format "attachment; filename=\"~a\"" name))))
            (lambda (out) (write-string text out)))
           (err "not found" 404))]
      [else
       (define n (notes-get db-conn p id))
       (if n (json-response n) (err "not found" 404))]))))

;; THE BODY IS THE ORG TEXT ITSELF, not JSON, and that is the one place in this
;; plane that takes a raw body on purpose: an importer runs
;; `curl --data-binary @note.org`, and making them JSON-escape a whole file to
;; reach a route whose entire input is that file would be a surface nobody uses.
;; `?visibility=` carries the only other thing a create needs.
;;
;; ONE FILE PER CALL. A bulk form would have to decide what a partial failure
;; means — half a directory imported, with no way to say which half — and a
;; caller looping is both simpler and resumable.
(define (ep-notes-import req)
  (with-auth req (lambda (p)
    (define raw (request-post-data/raw req))
    (define text (if raw
                     (with-handlers ([exn:fail? (lambda (_) #f)]) (bytes->string/utf-8 raw))
                     #f))
    (cond
      ;; an empty body is a caller mistake worth naming: it would otherwise
      ;; import as an untitled, empty note that looks like a successful no-op
      [(or (not text) (string=? (string-trim text) ""))
       (err "the request body is the org text to import, and it is empty" 400)]
      [else
       (json-response (notes-import db-conn p text
                                    #:visibility (query-param req 'visibility "team"))
                      #:code 201)]))))

;; ORG-15 — ITS OWN ROUTE AND NOT A FIELD ON `GET /api/notes/:id`, which is the
;; shape `/api/repo-obj/:id/annotations`, `/processing`, `/derivations` and
;; `/spans` all take. Two reasons, and the first is the load-bearing one: the
;; note GET is what the LISTING's own shape is, and ORG-9 asks `can?` per edge,
;; so folding this in would make an N-note read O(N x edges) on a path that
;; already does per-row `can?`. The second is that one note's links are what a
;; detail panel wants, and the Notes tab already fetches in a `Promise.all`
;; round, so it costs no extra latency there.
;;
;; BOTH DIRECTIONS IN ONE ANSWER, because a reader looking at a note wants both
;; and the team's note index is built once for the pair rather than twice.
(define (ep-note-links req id)
  (with-auth req (lambda (p)
    (define out (note-links-of db-conn p id))
    (if out
        (json-response (hasheq 'links out
                               'backlinks (note-backlinks-of db-conn p id)))
        (err "not found" 404)))))


;; #247 — ORG-16's bound and its neighbourhood default. The `?note=` form is what
;; the console asks for; the whole-team map is the explicit control.
;;
;; `query-param`'s default is `""` AND AN EMPTY STRING IS TRUE IN RACKET, so the
;; absent case is tested rather than `or`-ed — the documented trap that once made
;; every bundle sub-resource 401 on its own cookie.
;;
;; The DEPTH IS NOT REFUSED when it is nonsense, it is clamped in the domain
;; beside the cap it shares a purpose with: a bad `?depth=` is a reader asking
;; for a picture, and refusing one over a query parameter they can see the effect
;; of is the wrong trade. `?note=` naming a note that is not there — or one the
;; caller may not read, which is ONE answer (ORG-9a) — is a 404.
(define (ep-notes-graph req)
  (with-auth req (lambda (p)
    (define asked (query-param req 'note ""))
    (define focus (if (string=? asked "") #f asked))
    (define n (string->number (query-param req 'depth "1")))
    (define out (note-graph db-conn p #:note focus
                            #:depth (if (exact-integer? n) n 1)))
    (if out (json-response out) (err "not found" 404)))))

(define (ep-notes-update req id)
  (with-auth req (lambda (p)
    (define b (read-json-body req))
    ;; a MISSING `tags` key leaves the set alone; `[]` CLEARS it. Those have to
    ;; be different or the last tag could never be removed, which is the one
    ;; place this differs from #239's "blank is absent".
    ;; ORG-2 — `{"format":"org"}` changes how the body is RENDERED and never
    ;; touches the body, so it is an ordinary absent-is-leave-alone field beside
    ;; title and visibility rather than tags' absent/clear pair.
    (define n (notes-update db-conn p id #:title (hash-ref b 'title #f)
                            #:body (hash-ref b 'body #f) #:visibility (hash-ref b 'visibility #f)
                            #:tags (hash-ref b 'tags #f)
                            #:format (hash-ref b 'format #f)))
    (if n (json-response n) (err "not found" 404)))))

;; TAG-7 — synchronous, and HELP-23 is the reasoning. One note is ONE model call,
;; so the wire is not a job and seconds fit any request budget; what would force
;; a job is a page of notes, which is the backfill and is its own slice. The
;; answer carries `added` and `dropped` separately because "it proposed nothing"
;; and "it proposed four things I could not use" have different remedies.
(define (ep-notes-autotag req id)
  (with-auth req (lambda (p)
    ;; "no model configured" is raised as `exn:fail:misconfigured`, which is
    ;; right where it comes from — WF-14 makes a fan-out fail on its FIRST child
    ;; for it, rather than reporting it once per note — and wrong on a
    ;; synchronous endpoint, where #123 classifies anything that is not a user
    ;; error as a 500 and answers `{"error":"internal error"}`. An operator
    ;; one variable away from a working feature must not be told that. So it is
    ;; translated HERE, where the caller is a person, and nowhere else: the
    ;; workflow path keeps its own semantics.
    (with-handlers ([exn:fail:misconfigured?
                     (lambda (e) (err (exn-message e) 400))])
      (define-values (n added dropped) (note-autotag! db-conn p id))
      (if n
          (json-response (hasheq 'note n 'added added 'dropped dropped))
          (err "not found" 404))))))

(define (ep-notes-delete req id)
  (with-auth req (lambda (p)
    (if (notes-delete db-conn p id) (json-response (hasheq 'deleted #t)) (err "not found" 404)))))

(define (ep-notes-share req id)
  (with-auth req (lambda (p)
    (define b (read-json-body req))
    (define target (hash-ref b 'user_id #f))
    (cond
      [(not target) (err "user_id required" 400)]
      [(notes-share db-conn p id #:user target #:permission (hash-ref b 'permission "notes:read"))
       (json-response (hasheq 'shared #t))]
      [else (err "not found" 404)]))))

(define (ep-search req)
  (with-auth req (lambda (p)
    (require-feature p "search")
    (define q (string-trim (query-param req 'q)))
    ;; `content_search` says whether document TEXT is being matched (issue #83).
    ;; With the extracted text sealed it cannot be, and a search that quietly
    ;; stopped looking inside documents would read as "we have no such document"
    ;; — the caller must be able to tell the two apart. Reported on every reply,
    ;; not only when off, so a client can branch on it without guessing.
    (define content? (not (content-encryption-enabled?)))
    ;; `?semantic=1` adds passages found by MEANING (#189 step 6). OFF by default
    ;; and that is not timidity: embedding the question is a model request, so
    ;; asking spends the team's `ai.requests` and `ai.embeddings.total`, where
    ;; every other kind of search here costs a `LIKE`. An opt-in flag is also what
    ;; keeps the console's existing search exactly as cheap as it was.
    ;;
    ;; `semantic` is reported on every reply that asked, and `semantic_reason`
    ;; only when it was asked and did not run — never when it ran and matched
    ;; nothing. **The semantic half is the first content search that survives
    ;; `TMACH_ENCRYPT_CONTENT`**: it compares vectors and reads the text back
    ;; through `repo-text-for`, which unseals, so on a sealed instance
    ;; `content_search` is false and this can still be true.
    (define semantic? (member (string-downcase (query-param req 'semantic)) '("1" "true" "yes")))
    (if (< (string-length q) 2)
         (json-response (hasheq 'query q 'results '() 'content_search content?))
         (let-values ([(passages reason)
                       (if semantic?
                           (search-passages db-conn p q)
                           (values '() #f))])
           (json-response
            (let ([base (hasheq 'query q 'content_search content?
                                'results (append passages
                                                 (search-all db-conn p q #:scope (scope-of req))))])
              (cond
                [(not semantic?) base]
                [reason (hash-set (hash-set base 'semantic #f) 'semantic_reason reason)]
                [else (hash-set base 'semantic #t)]))))))))

;; ---- knowledge graph (slice 61) --------------------------------------------------
;; Every read applies the mention rule inside domain/kg: an entity the caller can
;; see no mention of does not exist for them. Extraction is the index-knowledge
;; workflow, queued like any run.
(define (ep-kg-entities req)
  (with-auth req (lambda (p)
    (define q (query-param req 'q ""))
    (define type (let ([t (query-param req 'type "")]) (and (not (string=? t "")) t)))
    (json-response (hasheq 'entities (kg-find db-conn p q #:type type)
                           'stats (kg-stats db-conn p)
                           'types STARTER-TYPES)))))

(define (ep-kg-entity req id)
  (with-auth req (lambda (p)
    (define e (kg-entity db-conn p id))
    (if e (json-response e) (err "not found" 404)))))

;; #191 slice 3 (RG-9): the drawable neighbourhood. `?hops=` is 1 or 2 and a
;; nonsense value is CLAMPED rather than refused — its effect is on screen, and a
;; 400 for a bad query parameter on a picture is not worth anybody's time. An
;; entity the caller cannot see and one that does not exist are one 404.
(define (ep-kg-graph req id)
  (with-auth req (lambda (p)
    (define h (let ([n (string->number (query-param req 'hops "1"))])
                (if (exact-integer? n) n 1)))
    (define g (kg-graph db-conn p id #:hops h))
    (if g (json-response g) (err "not found" 404)))))

(define (ep-kg-extract req)
  (with-auth req (lambda (p)
    (require-feature p "workflows")
    (define d (flow-def-by-slug db-conn p "index-knowledge"))
    (cond
      [(not d) (err "the knowledge-graph plugin is not loaded" 404)]
      [else (json-response (flow-run-start! db-conn p d) #:code 202)]))))
