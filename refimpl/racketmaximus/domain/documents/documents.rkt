#lang racket/base

;; domain/documents/documents.rkt — the ownable resource behind the research /
;; document-translation apps. Mirrors notes (team/private/shared via can?), with a
;; larger `content` body and offset-paginated listing (offset / next_offset).

(require db-kit/portable
         racket/list
         "../db/id.rkt"
         "../authz/authz.rkt")

(provide documents-create documents-list documents-get documents-update documents-delete)

(define SELECT
  "SELECT id, team_id, owner_user_id, visibility, title, content, created_at, updated_at FROM documents")

(define (row->doc r)
  (hasheq 'id (vector-ref r 0) 'team_id (vector-ref r 1) 'owner_user_id (vector-ref r 2)
          'visibility (vector-ref r 3) 'title (vector-ref r 4) 'content (vector-ref r 5)
          'created_at (vector-ref r 6) 'updated_at (vector-ref r 7)))

(define (doc->resource d)
  (hasheq 'resource_type "documents" 'resource_id (hash-ref d 'id)
          'team_id (hash-ref d 'team_id) 'owner_user_id (hash-ref d 'owner_user_id)
          'visibility (hash-ref d 'visibility)))

(define (get-row conn id) (query-maybe-row conn (string-append SELECT " WHERE id = ?") id))

(define (documents-create conn p #:title [title ""] #:content [content ""] #:visibility [vis "team"])
  (require-perm conn p "documents:write")
  (define id (new-id))
  (query-exec conn
    "INSERT INTO documents (id, team_id, owner_user_id, visibility, title, content) VALUES (?, ?, ?, ?, ?, ?)"
    id (principal-team-id p) (principal-user-id p) vis title content)
  (row->doc (get-row conn id)))

;; offset-paginated; returns { documents: [...], next_offset: n | 'null }
(define (documents-list conn p #:offset [offset 0] #:limit [limit 20])
  (define raw (query-rows conn
    (string-append SELECT " WHERE team_id = ? ORDER BY updated_at DESC, id DESC LIMIT ? OFFSET ?")
    (principal-team-id p) (add1 limit) offset))
  (define has-more (> (length raw) limit))
  (define page (if has-more (take raw limit) raw))
  (define visible
    (for/list ([r (in-list page)]
               #:when (can? conn p "documents:read" #:resource (doc->resource (row->doc r))))
      (row->doc r)))
  (hasheq 'documents visible 'next_offset (if has-more (+ offset limit) 'null)))

(define (documents-get conn p id)
  (define r (get-row conn id))
  (and r (let ([d (row->doc r)])
           (require-perm conn p "documents:read" #:resource (doc->resource d))
           d)))

(define (documents-update conn p id #:title [title #f] #:content [content #f] #:visibility [vis #f])
  (define r (get-row conn id))
  (and r (let ([d (row->doc r)])
           (require-perm conn p "documents:write" #:resource (doc->resource d))
           (query-exec conn
             (string-append "UPDATE documents SET title = COALESCE(?, title), content = COALESCE(?, content), "
                            "visibility = COALESCE(?, visibility), updated_at = CURRENT_TIMESTAMP WHERE id = ?")
             (or title sql-null) (or content sql-null) (or vis sql-null) id)
           (row->doc (get-row conn id)))))

(define (documents-delete conn p id)
  (define r (get-row conn id))
  (and r (let ([d (row->doc r)])
           (require-perm conn p "documents:write" #:resource (doc->resource d))
           (query-exec conn "DELETE FROM documents WHERE id = ?" id)
           #t)))
