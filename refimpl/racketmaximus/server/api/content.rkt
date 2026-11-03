#lang racket/base

;; server/api/content.rkt — notes, documents, search and the knowledge graph
;;
;; Split out of main.rkt by #110 r3. The shared surface every handler here
;; needs — the pool, the request accessors, with-auth/with-mt, the response
;; constructors — is server/kit.rkt.

(provide ep-notes-create ep-notes-list ep-documents-create ep-documents-list
         ep-documents-get ep-documents-update ep-documents-delete
         ep-notes-get ep-notes-update ep-notes-delete ep-notes-share
         ep-note-tags ep-notes-autotag
         ep-search ep-kg-entities ep-kg-entity ep-kg-extract)

(require racket/string
         web-kit
         (only-in "../../config.rkt" content-encryption-enabled?)
         (only-in "../../domain/notes/notes.rkt"
                  notes-create notes-delete notes-get notes-list notes-share notes-update
                  notes-tag-list)
         (only-in "../../domain/notes/note-tools.rkt" note-autotag!)
         (only-in "../../domain/tools/faults.rkt" exn:fail:misconfigured?)
         (only-in "../../domain/documents/documents.rkt" documents-create documents-delete documents-get documents-list documents-update)
         ;; #239: a project is a key prefix, so the folder list is derived there
         (only-in "../../domain/repo/repo.rkt" repo-prefixes)
         (only-in "../../domain/apps/search.rkt" search-all search-passages)
         (only-in "../../domain/kg/kg.rkt" STARTER-TYPES kg-entity kg-find kg-stats)
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
                                 #:tags (hash-ref b 'tags '()))
                   #:code 201))))

;; #245: `?tag=` is repeatable, so it reads through `query-params` (plural) and
;; not `query-param`, which answers with the FIRST value — right for a scalar and
;; wrong for a filter you are meant to stack. LAY-4's `?attr=` paid for that
;; distinction already.
(define (ep-notes-list req)
  (with-auth req (lambda (p)
    (json-response
     (hasheq 'notes (notes-list db-conn p #:scope (scope-of req)
                                #:tags (query-params req 'tag)))))))

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
    (define n (notes-get db-conn p id))
    (if n (json-response n) (err "not found" 404)))))

(define (ep-notes-update req id)
  (with-auth req (lambda (p)
    (define b (read-json-body req))
    ;; a MISSING `tags` key leaves the set alone; `[]` CLEARS it. Those have to
    ;; be different or the last tag could never be removed, which is the one
    ;; place this differs from #239's "blank is absent".
    (define n (notes-update db-conn p id #:title (hash-ref b 'title #f)
                            #:body (hash-ref b 'body #f) #:visibility (hash-ref b 'visibility #f)
                            #:tags (hash-ref b 'tags #f)))
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

(define (ep-kg-extract req)
  (with-auth req (lambda (p)
    (require-feature p "workflows")
    (define d (flow-def-by-slug db-conn p "index-knowledge"))
    (cond
      [(not d) (err "the knowledge-graph plugin is not loaded" 404)]
      [else (json-response (flow-run-start! db-conn p d) #:code 202)]))))
