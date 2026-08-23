#lang racket/base

;; domain/documents/documents.rkt — the /api/documents COMPATIBILITY SHIM (slice 55).
;;
;; The documents table is gone (migration 0022): a text document is a repository
;; object with content_type text/markdown, its title in the version's `filename`,
;; its body a content-addressed blob, its text in repo_text. This module keeps the
;; old five-function API — same signatures, same return shapes — so the server
;; routes, the console tab and the sample seeder did not change on the day the
;; storage did.
;;
;; What the fold buys, without any of those callers knowing: documents now VERSION
;; on every edit, dedup against identical bodies, sync over S3, and share by
;; presigned link — because they are objects, and that is what objects do.
;;
;; The shim owns its LIST query (ordering and offset pagination match the old API
;; exactly: updated_at DESC, not the repository's key ASC) and delegates every
;; MUTATION to repo.rkt, so authorization stays in one place.

(require db-kit/portable
         racket/list racket/port racket/string
         "../db/id.rkt"
         "../authz/authz.rkt"
         "../repo/repo.rkt"
         "../repo/blobs.rkt"
         "../repo/extract.rkt")

(provide documents-create documents-list documents-get documents-update documents-delete)

(define PREFIX "documents/")

(define (slugify title)
  (define t (string-trim (regexp-replace* #px"[^a-z0-9]+" (string-downcase title) "-") "-"))
  (if (string=? t "") "untitled" (substring t 0 (min 60 (string-length t)))))

;; the row shape the old API promised, reconstructed from an object row + its body
(define (doc-json o body)
  (hasheq 'id (hash-ref o 'id) 'team_id (hash-ref o 'team_id)
          'owner_user_id (hash-ref o 'owner_user_id)
          'visibility (hash-ref o 'visibility)
          'title (hash-ref o 'filename)
          'content body
          'created_at (hash-ref o 'created_at) 'updated_at (hash-ref o 'updated_at)))

(define (body-of o)
  (define in (blob-get (hash-ref o 'org_id) (hash-ref o 'digest)))
  (if in (begin0 (port->string in) (close-input-port in)) ""))

;; writes go through repo-put!, so quota, versioning and audit all apply; the
;; repo_text upsert keeps the body searchable IMMEDIATELY, as the old table was —
;; markdown extracts to itself, so there is nothing to wait for a workflow for
(define (put-doc! conn p #:id [id #f] #:key [key #f] #:title title #:content content
                  #:visibility [vis #f])
  (define k (or key (format "~a~a-~a.md" PREFIX (slugify title) (substring (new-id) 0 8))))
  (define o (repo-put! conn p #:key k
                       #:port (open-input-bytes (string->bytes/utf-8 content))
                       #:content-type "text/markdown"
                       #:filename title
                       #:visibility vis
                       #:allow-empty? #t))
  (repo-text-upsert! conn (hash-ref o 'id) (hash-ref o 'version_id) content)
  (doc-json o content))

(define (documents-create conn p #:title [title ""] #:content [content ""] #:visibility [vis "team"])
  (put-doc! conn p #:title title #:content content #:visibility vis))

;; offset-paginated; returns { documents: [...], next_offset: n | 'null } — the old
;; contract verbatim, including full content in the listing
(define (documents-list conn p #:offset [offset 0] #:limit [limit 20])
  (define team (principal-team-id p))
  (define raw (query-rows conn
    (string-append
     "SELECT o.id, o.org_id, o.team_id, o.owner_user_id, o.visibility, "
     "COALESCE(v.filename, ''), COALESCE(t.content, ''), o.created_at, o.updated_at "
     "FROM repo_objects o "
     "LEFT JOIN repo_versions v ON v.id = o.current_version_id "
     "LEFT JOIN repo_text t ON t.object_id = o.id "
     "WHERE o.team_id = ? AND o.deleted_at IS NULL AND o.key LIKE ? "
     "ORDER BY o.updated_at DESC, o.id DESC LIMIT ? OFFSET ?")
    team (string-append PREFIX "%") (add1 limit) offset))
  (define has-more (> (length raw) limit))
  (define page (if has-more (take raw limit) raw))
  (define visible
    (for/list ([r (in-list page)]
               #:when (can? conn p "files:read"
                            #:resource (hasheq 'resource_type "repo" 'resource_id (vector-ref r 0)
                                               'team_id team 'owner_user_id (vector-ref r 3)
                                               'visibility (vector-ref r 4))))
      (hasheq 'id (vector-ref r 0) 'team_id (vector-ref r 2)
              'owner_user_id (vector-ref r 3) 'visibility (vector-ref r 4)
              'title (vector-ref r 5) 'content (vector-ref r 6)
              'created_at (vector-ref r 7) 'updated_at (vector-ref r 8))))
  (hasheq 'documents visible 'next_offset (if has-more (+ offset limit) 'null)))

(define (documents-get conn p id)
  (define o (repo-get conn p id))                 ; authorized read, or forbidden
  (and o (doc-json o (body-of o))))

(define (documents-update conn p id #:title [title #f] #:content [content #f] #:visibility [vis #f])
  (define o (repo-get conn p id))
  (and o
       (let ()
         ;; an edit is a NEW VERSION — the old body survives, which the old API
         ;; never offered; an unchanged body dedups to the same blob
         (define new-title (or title (hash-ref o 'filename)))
         (define new-content (or content (body-of o)))
         (define o2 (if (or title content)
                        (hash-ref (put-doc! conn p #:key (hash-ref o 'key)
                                            #:title new-title #:content new-content) 'id)
                        id))
         (when vis (repo-set-visibility! conn p id vis))
         (documents-get conn p id))))

(define (documents-delete conn p id)
  (repo-delete! conn p id))
