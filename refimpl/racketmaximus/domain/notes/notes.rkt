#lang racket/base

;; domain/notes/notes.rkt — the first ownable resource, end to end through RBAC.
;; Every operation is authorized with the AuthzService: team-visibility, private
;; (owner-only), and shared (explicit resource_grants) all flow through `can?` /
;; `require-perm`. Functions raise exn:fail:forbidden on deny (→ 403) and return
;; #f on not-found (→ 404).

(require db-kit/portable
         "../db/id.rkt"
         "../authz/authz.rkt")

(provide notes-create notes-list notes-get notes-update notes-delete notes-share)

(define SELECT
  "SELECT id, team_id, owner_user_id, visibility, title, body, created_at, updated_at FROM notes")

(define (row->note r)
  (hasheq 'id (vector-ref r 0) 'team_id (vector-ref r 1) 'owner_user_id (vector-ref r 2)
          'visibility (vector-ref r 3) 'title (vector-ref r 4) 'body (vector-ref r 5)
          'created_at (vector-ref r 6) 'updated_at (vector-ref r 7)))

(define (note->resource n)
  (hasheq 'resource_type "notes" 'resource_id (hash-ref n 'id)
          'team_id (hash-ref n 'team_id) 'owner_user_id (hash-ref n 'owner_user_id)
          'visibility (hash-ref n 'visibility)))

(define (get-row conn id) (query-maybe-row conn (string-append SELECT " WHERE id = ?") id))

(define (notes-create conn p #:title [title ""] #:body [body ""] #:visibility [vis "team"])
  (require-perm conn p "notes:write")                       ; team-level create
  (define id (new-id))
  (query-exec conn
    "INSERT INTO notes (id, team_id, owner_user_id, visibility, title, body) VALUES (?, ?, ?, ?, ?, ?)"
    id (principal-team-id p) (principal-user-id p) vis title body)
  (row->note (get-row conn id)))

(define (notes-list conn p)
  (define rows (query-rows conn (string-append SELECT " WHERE team_id = ? ORDER BY created_at DESC")
                           (principal-team-id p)))
  (for/list ([r (in-list rows)]
             #:when (can? conn p "notes:read" #:resource (note->resource (row->note r))))
    (row->note r)))

(define (notes-get conn p id)
  (define r (get-row conn id))
  (and r (let ([n (row->note r)])
           (require-perm conn p "notes:read" #:resource (note->resource n))
           n)))

(define (notes-update conn p id #:title [title #f] #:body [body #f] #:visibility [vis #f])
  (define r (get-row conn id))
  (and r (let ([n (row->note r)])
           (require-perm conn p "notes:write" #:resource (note->resource n))
           (when title (query-exec conn "UPDATE notes SET title = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ?" title id))
           (when body  (query-exec conn "UPDATE notes SET body = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ?" body id))
           (when vis   (query-exec conn "UPDATE notes SET visibility = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ?" vis id))
           (row->note (get-row conn id)))))

(define (notes-delete conn p id)
  (define r (get-row conn id))
  (and r (let ([n (row->note r)])
           (require-perm conn p "notes:delete" #:resource (note->resource n))
           (query-exec conn "DELETE FROM notes WHERE id = ?" id)
           #t)))

;; owner (or notes:manage / operator) may share the note with another user
(define (notes-share conn p id #:user target-user #:permission [perm "notes:read"])
  (define r (get-row conn id))
  (and r (let ([n (row->note r)])
           (unless (or (equal? (hash-ref n 'owner_user_id) (principal-user-id p))
                       (principal-is-operator p))
             (require-perm conn p "notes:manage" #:resource (note->resource n)))
           (grant! conn #:resource-type "notes" #:resource-id id
                   #:principal-type "user" #:principal-id target-user
                   #:permission perm #:by (principal-user-id p))
           #t)))
