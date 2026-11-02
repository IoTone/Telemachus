#lang racket/base

;; domain/apps/search.rkt — keyword search across a team's content, RBAC-filtered:
;; every row is checked with `can?` (so someone else's private note or document never
;; leaks); translations are included only for members who may use AI (chat:use). A
;; retrieval app built entirely on existing data.
;;
;; Repository objects match on key, filename, AND extracted text: the indexing
;; workflow (plugins/doc-indexer) pulls a document's words into `repo_text`, so a
;; PDF is findable by what it says, not just what it is called. An object nobody has
;; indexed yet still matches by its path — extraction improves a hit, it is never a
;; precondition for one.
;;
;; This is deliberately NOT the fold of `documents` into `repo_objects` (DOC-14).
;; That is a real migration — documents have titles where objects have paths, and no
;; org_id — and it deserves its own slice rather than being smuggled in behind a
;; search fix.

(require db-kit/portable
         racket/string
         (only-in racket/list last)
         "../authz/authz.rkt"
         "../kg/kg.rkt"
         ;; #189 step 6: the semantic half. One asker of `passages-for`, the
         ;; retrieval tool being the other — and the question is embedded there,
         ;; so nothing in this module makes a model request of its own.
         (only-in "../repo/passages.rkt" passages-for semantic-available?)
         ;; #239: "is this a text document?" lives with the storage that decides it
         (only-in "../repo/repo.rkt" DOC-CONTENT-TYPE)
         ;; issue #83: with the extracted text sealed, a LIKE over it cannot match
         (only-in "../../config.rkt" content-encryption-enabled?))

(provide search-all search-passages SEMANTIC-REASONS SEMANTIC-SNIPPET
         ;; exported FOR the test: three shapes, each of which really occurs
         title-like?)

(define (like q) (string-append "%" q "%"))

;; ---- does this row have a human TITLE to show instead of a path? (#239) -------
;;
;; `type` on a repository hit DECIDES AN AFFORDANCE, not a category: the console
;; offers Download on a `file` row and uses the title as the download filename. So
;; the question is narrower than "is this a text document", and the answer is one
;; idea — a document's `filename` holds a TITLE where a file's holds a filename.
;;
;; THE TEST USED TO BE THE `documents/` KEY PREFIX, and #239 makes that wrong in
;; one direction: a chapter filed into `levee-7/` would be presented as an
;; untitled file. Swapping it for the content type ALONE is wrong in the other
;; direction, and `index-tests` is what said so — every uploaded `.md` would
;; become a `document` and lose its download button. Each clause below earns its
;; place against a case that really occurs:
;;
;;   markdown            — only a text document has a title at all
;;   not empty           — an object written with no filename falls back to its key
;;   no "/" in it        — `repo-put! #:filename key` is what test fixtures and
;;                         several callers do, and a path is not a title
;;   not the basename    — an ordinary upload names the file it came from
;;
;; Derived from the row rather than from a migration's prefix, so it survives a
;; document being filed anywhere — which is the whole point of #239.
(define (title-like? key filename content-type)
  (and (equal? content-type DOC-CONTENT-TYPE)
       (not (string=? filename ""))
       (not (string-contains? filename "/"))
       (let ([segs (string-split key "/")])
         (not (string=? filename (if (null? segs) "" (last segs)))))))

(define (snippet text q)
  (define t (if (or (not text) (sql-null? text)) "" text))
  (define lo (string-downcase t))
  (define ql (string-downcase q))
  (define n (string-length lo)) (define m (string-length ql))
  (define i (let loop ([k 0])
              (cond [(> (+ k m) n) 0]
                    [(string=? (substring lo k (+ k m)) ql) k]
                    [else (loop (add1 k))])))
  (define start (max 0 (- i 30)))
  (define end (min (string-length t) (+ i m 60)))
  (string-append (if (> start 0) "…" "") (substring t start end) (if (< end (string-length t)) "…" "")))

;; #:scope 'org searches every team in the caller's company (TEN-2h). Each row's
;; resource carries ITS OWN team, so the per-row can? is the same rule as always.
(define (search-all conn p q #:limit [lim 20] #:scope [scope 'team])
  (define team (principal-team-id p))
  (define teams
    (if (eq? scope 'org)
        (let ([org (or (principal-org-id p) (team-org conn team))])
          (if org (org-teams-of conn org) (list team)))
        (list team)))
  (define pat (like q))
  (define note-hits
    (for*/list ([t (in-list teams)]
                [r (in-list (query-rows conn
         (string-append "SELECT id, owner_user_id, visibility, title, body FROM notes "
                        "WHERE team_id = ? AND (title LIKE ? OR body LIKE ?) ORDER BY updated_at DESC LIMIT ?")
         t pat pat lim))]
         #:when (can? conn p "notes:read"
                      #:resource (hasheq 'resource_type "notes" 'resource_id (vector-ref r 0)
                                         'team_id t 'owner_user_id (vector-ref r 1)
                                         'visibility (vector-ref r 2))))
      (hasheq 'type "note" 'id (vector-ref r 0) 'title (vector-ref r 3)
              'snippet (snippet (vector-ref r 4) q))))
  ;; Content-addressed objects: the key is the searchable text we have. `filename`
  ;; is checked too because the key is often a tidy path while the filename is what
  ;; the person actually remembers typing.
  ;; With the extracted text sealed (#83) a `LIKE` over it matches ciphertext and
  ;; so matches nothing. The clause is DROPPED rather than left in to return no
  ;; rows — a key or filename match still works — and `content_search` on the
  ;; reply says the other half is unavailable. Silently keeping a clause that
  ;; cannot match is how a search quietly starts missing documents.
  ;;
  ;; The SQL and its ARGUMENTS are built together. Interpolating a clause while
  ;; passing a fixed argument list is how the two come apart, which CLAUDE.md
  ;; records from `blob-referenced?` — and which this code did on its first
  ;; attempt, passing `(void)` as a query parameter.
  (define sealed? (content-encryption-enabled?))
  (define repo-sql
    (string-append "SELECT o.id, o.owner_user_id, o.visibility, o.key, "
                   "COALESCE(v.filename, ''), COALESCE(v.content_type, ''), "
                   "COALESCE(t.content, '') "
                   "FROM repo_objects o "
                   "LEFT JOIN repo_versions v ON v.id = o.current_version_id "
                   "LEFT JOIN repo_text t ON t.object_id = o.id "
                   "WHERE o.team_id = ? AND o.deleted_at IS NULL "
                   (if sealed?
                       "AND (o.key LIKE ? OR v.filename LIKE ?) "
                       "AND (o.key LIKE ? OR v.filename LIKE ? OR t.content LIKE ?) ")
                   "ORDER BY o.updated_at DESC LIMIT ?"))
  (define (repo-args t) (if sealed? (list t pat pat lim) (list t pat pat pat lim)))
  (define repo-hits
    (for*/list ([t (in-list teams)]
                [r (in-list (apply query-rows conn repo-sql (repo-args t)))]
         #:when (can? conn p "files:read"
                      #:resource (hasheq 'resource_type "repo" 'resource_id (vector-ref r 0)
                                         'team_id t 'owner_user_id (vector-ref r 1)
                                         'visibility (vector-ref r 2))))
      ;; when the CONTENT matched, show the words around the match, like a note;
      ;; when only the path matched, the content type is the most useful line
      (define text (vector-ref r 6))
      (define content-hit?
        (and (> (string-length text) 0)
             (regexp-match? (regexp-quote (string-downcase q)) (string-downcase text))))
      ;; WHAT `type` DECIDES HERE IS AN AFFORDANCE, NOT A CATEGORY — the console
      ;; offers Download on a `file` row and uses the title as the download
      ;; filename — so the question is narrower than "is this a text document":
      ;; it is "does this row have a human TITLE to show instead of its path?".
      ;;
      ;; The test used to be the `documents/` key prefix, which #239 makes wrong in
      ;; one direction: a chapter filed into `levee-7/` would be presented as an
      ;; untitled file. Swapping it for the content type alone is wrong in the
      ;; OTHER direction, and `index-tests` is what said so — every uploaded `.md`
      ;; would become a `document` and LOSE ITS DOWNLOAD BUTTON. So both
      ;; conditions, each carrying its own half: markdown, because only a text
      ;; document has a title where a file has a filename; and a filename that is
      ;; not simply the key's own basename, which is exactly what distinguishes
      ;; the one from the other. Derived from the row rather than from a
      ;; migration's prefix, so it survives a document being filed anywhere.
      (define doc? (title-like? (vector-ref r 3) (vector-ref r 4) (vector-ref r 5)))
      (hasheq 'type (if doc? "document" "file")
              'id (vector-ref r 0)
              ;; #239: WHERE it is. A file's title has always been its key, so this
              ;; is new only for a document — and for a document it is the whole of
              ;; "which project is this in", which is the question #239 asks.
              'key (vector-ref r 3)
              'title (if (and doc? (not (string=? (vector-ref r 4) "")))
                         (vector-ref r 4)
                         (vector-ref r 3))
              'snippet (if content-hit?
                           (snippet text q)
                           (let ([ct (vector-ref r 5)]) (if (string=? ct "") "" ct))))))
  ;; Sealed with the rest of the derived content (#83 r1): the pipeline's
  ;; `doc_translate` writes a document's text into these two columns, so a LIKE
  ;; over them matches ciphertext. Translations drop out of search entirely in
  ;; that mode — there is no key or filename to fall back on, unlike a repository
  ;; object — which `content_search: false` on the reply already covers.
  (define tr-hits
    (if (and (not sealed?) (can? conn p "chat:use"))
        (for/list ([r (in-list (query-rows conn
             (string-append "SELECT id, target_lang, source_text, result_text FROM translations "
                            "WHERE team_id = ? AND (source_text LIKE ? OR result_text LIKE ?) ORDER BY created_at DESC LIMIT ?")
             team pat pat lim))])
          (hasheq 'type "translation" 'id (vector-ref r 0) 'title (string-append "→ " (vector-ref r 1))
                  'snippet (snippet (vector-ref r 2) q)))
        '()))
  ;; the knowledge graph's fourth kind (slice 61): entities by name, each with at
  ;; least one mention the caller can read — the mention rule is inside kg-find
  (define entity-hits
    (with-handlers ([exn:fail:forbidden? (lambda (_) '())])
      (for/list ([e (in-list (kg-find conn p q #:limit lim))])
        (hasheq 'type "entity" 'id (hash-ref e 'id)
                'title (string-append (hash-ref e 'name) " (" (hash-ref e 'type) ")")
                'snippet (let ([d (hash-ref e 'description)])
                           (if (string=? d "")
                               (format "~a mention(s), ~a relation(s)" (hash-ref e 'mention_count) (hash-ref e 'relation_count))
                               d))))))
  (append note-hits repo-hits entity-hits tr-hits))

;; ---- searching by MEANING (#189 step 6, VEC‑39/‑40) ---------------------------
;;
;; VEC‑39 — IT DEGRADES AND SAYS SO, WHICH IS `content_search: false`'s RULE IN
;; THE MODULE THAT RULE LIVES IN. The caller asked for a SEARCH; answering the
;; keyword half and reporting that the other one did not run is strictly better
;; than refusing the lot, and it is what this file already does when #83 seals the
;; extracted text out of reach of a `LIKE`. The retrieval TOOL takes the opposite
;; call for the opposite reason (it was asked for exactly this, so it refuses by
;; name) — `passages-for` exports the predicate and makes neither decision.
;;
;; The three ways it can be unavailable are a CLOSED vocabulary, not an exception
;; message. `embed-exchange` classifies a transport failure and FEED‑6-redacts a
;; URL, but the message is still somebody else's gateway talking, and #123's line
;; is that a reply may carry what the CALLER supplied and not what we choked on.
;; A short label is also the only form a client can branch on.
;;
;;   unconfigured  no TMACH_EMBED_URL on this instance
;;   forbidden     the caller may not spend the team's AI budget (chat:use)
;;   unavailable   it was asked and the attempt failed — a provider, a quota, a
;;                 question that embedded to nothing
;;
;; Answers (values rows reason-or-#f): a reason is present exactly when the rows
;; are empty BECAUSE the half did not run, never when it ran and matched nothing —
;; QUOTA‑3's rule, that a field nothing stands behind is one a reader learns to
;; distrust.
(define SEMANTIC-REASONS '("unconfigured" "forbidden" "unavailable"))

;; VEC‑40 — A SEMANTIC SNIPPET IS THE PASSAGE'S HEAD, NOT A WINDOW ON A MATCH,
;; and that difference is the whole point of the feature rather than a shortcut.
;; `snippet` above centres on the query substring because there IS one; a passage
;; was chosen for its meaning and may not contain a single word of the question,
;; so there is nothing to centre on and pretending otherwise would put the
;; ellipses in a place that implies a match. The full passage is reachable from
;; the offsets the row carries.
(define SEMANTIC-SNIPPET 240)

(define (search-passages conn p q #:limit [lim 5])
  (cond
    [(not (semantic-available? conn p))
     (values '() (if (can? conn p "chat:use") "unconfigured" "forbidden"))]
    [else
     (with-handlers ([exn:fail? (lambda (_) (values '() "unavailable"))])
       (define rep (passages-for conn p q #:limit lim))
       (values
        (for/list ([h (in-list (hash-ref rep 'passages))])
          (define text (hash-ref h 'text))
          (hasheq 'type "passage"
                  'id (hash-ref h 'chunk_id)
                  'title (hash-ref h 'key)
                  'snippet (if (> (string-length text) SEMANTIC-SNIPPET)
                               (string-append (substring text 0 SEMANTIC-SNIPPET) "…")
                               text)
                  ;; what makes the row citable, and the reason a passage carries
                  ;; more than the other kinds do: `spans-covering` turns these
                  ;; into a page and a bbox (CHUNK‑1)
                  'object_id (hash-ref h 'object_id)
                  'start (hash-ref h 'start)
                  'end (hash-ref h 'end)
                  'score (hash-ref h 'score)))
        #f))]))
