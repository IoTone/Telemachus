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
         "../authz/authz.rkt"
         "../kg/kg.rkt")

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
  ;; Content-addressed objects: the key is the searchable text we have. `filename`
  ;; is checked too because the key is often a tidy path while the filename is what
  ;; the person actually remembers typing.
  (define repo-hits
    (for/list ([r (in-list (query-rows conn
         (string-append "SELECT o.id, o.owner_user_id, o.visibility, o.key, "
                        "COALESCE(v.filename, ''), COALESCE(v.content_type, ''), "
                        "COALESCE(t.content, '') "
                        "FROM repo_objects o "
                        "LEFT JOIN repo_versions v ON v.id = o.current_version_id "
                        "LEFT JOIN repo_text t ON t.object_id = o.id "
                        "WHERE o.team_id = ? AND o.deleted_at IS NULL "
                        "AND (o.key LIKE ? OR v.filename LIKE ? OR t.content LIKE ?) "
                        "ORDER BY o.updated_at DESC LIMIT ?")
         team pat pat pat lim))]
         #:when (can? conn p "files:read"
                      #:resource (hasheq 'resource_type "repo" 'resource_id (vector-ref r 0)
                                         'team_id team 'owner_user_id (vector-ref r 1)
                                         'visibility (vector-ref r 2))))
      ;; when the CONTENT matched, show the words around the match, like a note;
      ;; when only the path matched, the content type is the most useful line
      (define text (vector-ref r 6))
      (define content-hit?
        (and (> (string-length text) 0)
             (regexp-match? (regexp-quote (string-downcase q)) (string-downcase text))))
      ;; a folded document (migration 0022) is an object under documents/ whose
      ;; filename is its human title — present it the way its tab does
      (define doc? (string-prefix? (vector-ref r 3) "documents/"))
      (hasheq 'type (if doc? "document" "file")
              'id (vector-ref r 0)
              'title (if (and doc? (not (string=? (vector-ref r 4) "")))
                         (vector-ref r 4)
                         (vector-ref r 3))
              'snippet (if content-hit?
                           (snippet text q)
                           (let ([ct (vector-ref r 5)]) (if (string=? ct "") "" ct))))))
  (define tr-hits
    (if (can? conn p "chat:use")
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
