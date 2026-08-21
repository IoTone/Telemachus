#lang racket/base

;; domain/apps/search.rkt — keyword search across a team's content, RBAC-filtered:
;; every row is checked with `can?` (so someone else's private note or document never
;; leaks); translations are included only for members who may use AI (chat:use). A
;; retrieval app built entirely on existing data.
;;
;; Repository objects are indexed by KEY AND FILENAME ONLY — their bytes are opaque
;; here. Until text extraction lands, "search finds my PDF by its path" is the whole
;; promise, and it is worth keeping honest: before this, uploading a PDF made it
;; invisible to search while an identically-named text document was findable, which
;; is an inconsistency a person hits within a day of using both tabs.
;;
;; This is deliberately NOT the fold of `documents` into `repo_objects` (DOC-14).
;; That is a real migration — documents have titles where objects have paths, and no
;; org_id — and it deserves its own slice rather than being smuggled in behind a
;; search fix.

(require db-kit/portable
         racket/string
         "../authz/authz.rkt")

(provide search-all)

(define (like q) (string-append "%" q "%"))

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

(define (search-all conn p q #:limit [lim 20])
  (define team (principal-team-id p))
  (define pat (like q))
  (define note-hits
    (for/list ([r (in-list (query-rows conn
         (string-append "SELECT id, owner_user_id, visibility, title, body FROM notes "
                        "WHERE team_id = ? AND (title LIKE ? OR body LIKE ?) ORDER BY updated_at DESC LIMIT ?")
         team pat pat lim))]
         #:when (can? conn p "notes:read"
                      #:resource (hasheq 'resource_type "notes" 'resource_id (vector-ref r 0)
                                         'team_id team 'owner_user_id (vector-ref r 1)
                                         'visibility (vector-ref r 2))))
      (hasheq 'type "note" 'id (vector-ref r 0) 'title (vector-ref r 3)
              'snippet (snippet (vector-ref r 4) q))))
  (define doc-hits
    (for/list ([r (in-list (query-rows conn
         (string-append "SELECT id, owner_user_id, visibility, title, content FROM documents "
                        "WHERE team_id = ? AND (title LIKE ? OR content LIKE ?) ORDER BY updated_at DESC LIMIT ?")
         team pat pat lim))]
         #:when (can? conn p "documents:read"
                      #:resource (hasheq 'resource_type "documents" 'resource_id (vector-ref r 0)
                                         'team_id team 'owner_user_id (vector-ref r 1)
                                         'visibility (vector-ref r 2))))
      (hasheq 'type "document" 'id (vector-ref r 0) 'title (vector-ref r 3)
              'snippet (snippet (vector-ref r 4) q))))
  ;; Content-addressed objects: the key is the searchable text we have. `filename`
  ;; is checked too because the key is often a tidy path while the filename is what
  ;; the person actually remembers typing.
  (define repo-hits
    (for/list ([r (in-list (query-rows conn
         (string-append "SELECT o.id, o.owner_user_id, o.visibility, o.key, "
                        "COALESCE(v.filename, ''), COALESCE(v.content_type, '') "
                        "FROM repo_objects o LEFT JOIN repo_versions v ON v.id = o.current_version_id "
                        "WHERE o.team_id = ? AND o.deleted_at IS NULL "
                        "AND (o.key LIKE ? OR v.filename LIKE ?) "
                        "ORDER BY o.updated_at DESC LIMIT ?")
         team pat pat lim))]
         #:when (can? conn p "files:read"
                      #:resource (hasheq 'resource_type "repo" 'resource_id (vector-ref r 0)
                                         'team_id team 'owner_user_id (vector-ref r 1)
                                         'visibility (vector-ref r 2))))
      (hasheq 'type "file" 'id (vector-ref r 0) 'title (vector-ref r 3)
              'snippet (let ([ct (vector-ref r 5)])
                         (if (string=? ct "") "" ct)))))
  (define tr-hits
    (if (can? conn p "chat:use")
        (for/list ([r (in-list (query-rows conn
             (string-append "SELECT id, target_lang, source_text, result_text FROM translations "
                            "WHERE team_id = ? AND (source_text LIKE ? OR result_text LIKE ?) ORDER BY created_at DESC LIMIT ?")
             team pat pat lim))])
          (hasheq 'type "translation" 'id (vector-ref r 0) 'title (string-append "→ " (vector-ref r 1))
                  'snippet (snippet (vector-ref r 2) q)))
        '()))
  (append note-hits doc-hits repo-hits tr-hits))
