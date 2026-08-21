#lang racket/base

;; domain/repo/repo.rkt — the document repository (slice 50).
;;
;; An object is an ownable resource with the same three fields notes and documents
;; carry — team_id, owner_user_id, visibility — so `can?` governs it with no new
;; authorization code. The creator sets `visibility` at upload and can change it
;; afterwards because owner-ok already grants them write on their own resource; that
;; is the whole of "the creator sets the visibility" (DOC-4).
;;
;; Bytes never pass through this module as a value. An upload arrives as a port,
;; is digested and written straight to the blob store, and a download hands back a
;; port. Nothing here holds a document in memory, so a 200 MB PDF costs the same as
;; a 2 KB one.
;;
;; Writing the same key twice appends a version rather than replacing one (DOC-9):
;; the object id is the stable thing a grant and a URL point at, and history is what
;; makes "just re-upload it" safe advice.

(require db-kit/portable
         racket/file racket/port racket/string racket/list
         "../db/id.rkt"
         "../authz/authz.rkt"
         "../quota/quota.rkt"
         "blobs.rkt")

(provide repo-put! repo-get repo-open repo-list repo-versions
         repo-set-visibility! repo-delete! repo-usage
         repo-share! repo-unshare! repo-grants
         VISIBILITIES valid-key? inline-safe? STORAGE-DIMENSION)

(define STORAGE-DIMENSION "storage.bytes")
(define VISIBILITIES '("private" "team" "shared"))

;; ---- keys --------------------------------------------------------------------
;; A key is a path within the team. It is user-supplied text that ends up in URLs and
;; in listings, so the rules are a whitelist: no empty segments, no "." or "..", no
;; leading slash, no backslash, no control characters. The blob store never sees it —
;; it is addressed by digest — so this is about the namespace being sane, not about
;; path traversal on disk.
(define (valid-key? k)
  (and (string? k)
       (< 0 (string-length k) 1024)
       (not (regexp-match? #px"[\u0000-\u001F\u007F\\\\]" k))
       (not (string-prefix? k "/"))
       (let ([segs (string-split k "/" #:trim? #f)])
         (and (pair? segs)
              (for/and ([s (in-list segs)])
                (and (not (string=? s "")) (not (string=? s ".")) (not (string=? s ".."))))))))

;; ---- active content (DOC-10) --------------------------------------------------
;; SVG, HTML and XML are documents that can carry script. Served inline from our own
;; origin they are stored XSS with the whole console behind them, so only this short
;; list is ever allowed to render in a browser tab; everything else is downloaded.
;; The list is what may be INLINED — not what may be uploaded. Any format is
;; accepted, per the requirement.
(define INLINE-SAFE
  '("image/png" "image/jpeg" "image/gif" "image/webp" "application/pdf"
    "text/plain" "text/markdown" "text/csv"))
(define (inline-safe? ct) (and (member ct INLINE-SAFE) #t))

;; ---- rows ---------------------------------------------------------------------
(define OSELECT
  (string-append "SELECT o.id, o.org_id, o.team_id, o.owner_user_id, o.visibility, o.key, "
                 "o.current_version_id, o.created_at, o.updated_at, "
                 "v.digest, v.size, v.content_type, v.filename, v.seq, v.created_at "
                 "FROM repo_objects o LEFT JOIN repo_versions v ON v.id = o.current_version_id"))

(define (nz x) (if (sql-null? x) 'null x))

(define (row->obj r)
  (hasheq 'id (vector-ref r 0) 'org_id (vector-ref r 1) 'team_id (vector-ref r 2)
          'owner_user_id (vector-ref r 3) 'visibility (vector-ref r 4) 'key (vector-ref r 5)
          'version_id (nz (vector-ref r 6))
          'created_at (vector-ref r 7) 'updated_at (vector-ref r 8)
          'digest (nz (vector-ref r 9))
          'size (let ([v (vector-ref r 10)]) (if (sql-null? v) 0 v))
          'content_type (let ([v (vector-ref r 11)]) (if (sql-null? v) "application/octet-stream" v))
          'filename (let ([v (vector-ref r 12)]) (if (sql-null? v) "" v))
          'version (let ([v (vector-ref r 13)]) (if (sql-null? v) 0 v))
          'version_created_at (nz (vector-ref r 14))))

(define (obj->resource o)
  (hasheq 'resource_type "repo" 'resource_id (hash-ref o 'id)
          'team_id (hash-ref o 'team_id) 'owner_user_id (hash-ref o 'owner_user_id)
          'visibility (hash-ref o 'visibility)))

(define (obj-row conn id)
  (query-maybe-row conn (string-append OSELECT " WHERE o.id = ? AND o.deleted_at IS NULL") id))

(define (obj-row-by-key conn team key)
  (query-maybe-row conn
    (string-append OSELECT " WHERE o.team_id = ? AND o.key = ? AND o.deleted_at IS NULL")
    team key))

;; ---- writing -------------------------------------------------------------------
;; The upload is streamed to a temporary file while being digested, because the
;; content address is not known until the last byte has been read and the blob store
;; is addressed BY that digest. The temp file is the price of content-addressing; it
;; is deleted on every path.
(define (repo-put! conn p #:key key #:port in
                   #:content-type [content-type "application/octet-stream"]
                   #:filename [filename ""]
                   #:visibility [vis #f]
                   #:max-bytes [max-bytes #f]
                   ;; who to record as the author. Multipart completes on behalf of
                   ;; whoever started the upload, which need not be who finishes it.
                   #:as [as-user #f])
  (require-perm conn p "files:write")
  (unless (valid-key? key) (raise-user-error 'repo "invalid key: ~s" key))
  (when (and vis (not (member vis VISIBILITIES)))
    (raise-user-error 'repo "visibility must be one of ~a" (string-join VISIBILITIES ", ")))

  (define team (principal-team-id p))
  (define org  (or (team-org conn team) (principal-org-id p)))
  (unless org (error 'repo "no org for team ~a" team))

  (define existing (obj-row-by-key conn team key))
  (define prior (and existing (row->obj existing)))
  ;; An overwrite is a write to an existing resource, so it is checked against THAT
  ;; resource — a member may not overwrite a colleague's private object just because
  ;; they know its key.
  (when prior (require-perm conn p "files:write" #:resource (obj->resource prior)))

  (define-values (digest size) (blob-stage! org in #:max-bytes max-bytes))
  (when (zero? size) (raise-user-error 'repo "empty upload"))
  ;; Admission runs after the bytes are in the store, because the size is not known
  ;; until they are. An over-budget upload therefore costs one write and leaves no
  ;; row behind — the alternative is trusting a client-supplied Content-Length.
  (define adm (quota-check conn "team" team STORAGE-DIMENSION size))
  (unless (hash-ref adm 'allowed)
    (raise-user-error 'repo "storage quota exceeded: ~a of ~a bytes used"
                      (hash-ref adm 'used) (hash-ref adm 'limit)))
  (when org
    (define oadm (quota-check conn "org" org STORAGE-DIMENSION size))
    (unless (hash-ref oadm 'allowed)
      (raise-user-error 'repo "organization storage quota exceeded")))

  (define oid (or (and prior (hash-ref prior 'id)) (new-id)))
  (define vid (new-id))
  (define seq (if prior (add1 (hash-ref prior 'version)) 1))
  (unless prior
    (query-exec conn
      (string-append "INSERT INTO repo_objects (id, org_id, team_id, owner_user_id, visibility, key) "
                     "VALUES (?, ?, ?, ?, ?, ?)")
      oid org team (principal-user-id p) (or vis "team") key))
  (query-exec conn
    (string-append "INSERT INTO repo_versions (id, object_id, seq, digest, size, content_type, filename, created_by) "
                   "VALUES (?, ?, ?, ?, ?, ?, ?, ?)")
    vid oid seq digest size content-type filename (principal-user-id p))
  (query-exec conn
    "UPDATE repo_objects SET current_version_id = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ?"
    vid oid)
  ;; visibility is only reset when the caller said so — an overwrite must not
  ;; silently re-open a document its owner had made private
  (when (and prior vis)
    (query-exec conn "UPDATE repo_objects SET visibility = ? WHERE id = ?" vis oid))

  (quota-record! conn "team" team STORAGE-DIMENSION size)
  (when org (quota-record! conn "org" org STORAGE-DIMENSION size))
  (audit! conn #:action (if prior "repo.update" "repo.create")
          #:actor-type "user" #:actor-id (principal-user-id p) #:team-id team
          #:resource-type "repo" #:resource-id oid
          #:meta (format "{\"key\":~s,\"size\":~a,\"version\":~a}" key size seq))
  (row->obj (obj-row conn oid)))

;; ---- reading -------------------------------------------------------------------
(define (repo-get conn p id-or-key #:by-key [team #f])
  (define r (if team (obj-row-by-key conn team id-or-key) (obj-row conn id-or-key)))
  (and r (let ([o (row->obj r)])
           (require-perm conn p "files:read" #:resource (obj->resource o))
           o)))

;; -> (values object input-port) or (values #f #f). `version` selects history.
(define (repo-open conn p id #:version [version-id #f])
  (define o (repo-get conn p id))
  (cond
    [(not o) (values #f #f)]
    [else
     (define v
       (if version-id
           (query-maybe-row conn
             (string-append "SELECT digest, size, content_type, filename, seq FROM repo_versions "
                            "WHERE id = ? AND object_id = ?") version-id id)
           (query-maybe-row conn
             (string-append "SELECT digest, size, content_type, filename, seq FROM repo_versions "
                            "WHERE id = ?") (hash-ref o 'version_id))))
     (cond
       [(not v) (values #f #f)]
       [else
        (define in (blob-get (hash-ref o 'org_id) (vector-ref v 0)))
        (values (hash-set* o 'digest (vector-ref v 0) 'size (vector-ref v 1)
                           'content_type (vector-ref v 2) 'filename (vector-ref v 3)
                           'version (vector-ref v 4))
                in)])]))

;; Listing filters by `can?` per row rather than in SQL: the visibility rules live in
;; one place, and a private object simply does not appear. Slower and correct beats
;; a WHERE clause that has to be kept in step with the authorization code.
(define (repo-list conn p #:prefix [prefix ""] #:limit [limit 100] #:offset [offset 0])
  (require-perm conn p "files:read")
  (define rows (query-rows conn
    (string-append OSELECT " WHERE o.team_id = ? AND o.deleted_at IS NULL AND o.key LIKE ? "
                   "ORDER BY o.key ASC LIMIT ? OFFSET ?")
    (principal-team-id p)
    (string-append (escape-like prefix) "%")
    limit offset))
  (for/list ([r (in-list rows)]
             #:when (can? conn p "files:read" #:resource (obj->resource (row->obj r))))
    (row->obj r)))

;; `_` and `%` in a user-supplied prefix are wildcards to LIKE; a key containing one
;; would otherwise match far more than the caller asked for.
(define (escape-like s)
  (regexp-replace* #px"([%_])" s "\\\\\\1"))

(define (repo-versions conn p id)
  (define o (repo-get conn p id))
  (and o
       (for/list ([r (in-list (query-rows conn
              (string-append "SELECT id, seq, digest, size, content_type, filename, created_by, created_at "
                             "FROM repo_versions WHERE object_id = ? ORDER BY seq DESC") id))])
         (hasheq 'id (vector-ref r 0) 'version (vector-ref r 1) 'digest (vector-ref r 2)
                 'size (vector-ref r 3) 'content_type (vector-ref r 4)
                 'filename (vector-ref r 5) 'created_by (vector-ref r 6)
                 'created_at (vector-ref r 7)
                 'current (equal? (vector-ref r 0) (hash-ref o 'version_id))))))

;; ---- visibility and sharing ------------------------------------------------------
(define (repo-set-visibility! conn p id vis)
  (unless (member vis VISIBILITIES)
    (raise-user-error 'repo "visibility must be one of ~a" (string-join VISIBILITIES ", ")))
  (define o (repo-get conn p id))
  (and o
       (let ()
         (require-perm conn p "files:write" #:resource (obj->resource o))
         (query-exec conn "UPDATE repo_objects SET visibility = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ?" vis id)
         (audit! conn #:action "repo.visibility" #:actor-type "user" #:actor-id (principal-user-id p)
                 #:team-id (hash-ref o 'team_id) #:resource-type "repo" #:resource-id id
                 #:meta (format "{\"visibility\":~s}" vis))
         (row->obj (obj-row conn id)))))

;; Sharing is what `shared` means: private, plus an explicit grant list. Only someone
;; who may write the object may hand out access to it.
(define (repo-share! conn p id #:user user-id #:permission [perm "files:read"])
  (define o (repo-get conn p id))
  (and o
       (let ()
         (require-perm conn p "files:write" #:resource (obj->resource o))
         (grant! conn #:resource-type "repo" #:resource-id id
                 #:principal-type "user" #:principal-id user-id
                 #:permission perm #:by (principal-user-id p))
         ;; a team-visible object gains nothing from a grant; sharing implies narrowing
         (when (equal? (hash-ref o 'visibility) "team")
           (query-exec conn "UPDATE repo_objects SET visibility = 'shared' WHERE id = ?" id))
         (audit! conn #:action "repo.share" #:actor-type "user" #:actor-id (principal-user-id p)
                 #:team-id (hash-ref o 'team_id) #:resource-type "repo" #:resource-id id
                 #:meta (format "{\"user\":~s,\"permission\":~s}" user-id perm))
         #t)))

(define (repo-unshare! conn p id #:user user-id #:permission [perm "files:read"])
  (define o (repo-get conn p id))
  (and o
       (let ()
         (require-perm conn p "files:write" #:resource (obj->resource o))
         (revoke! conn #:resource-type "repo" #:resource-id id
                  #:principal-type "user" #:principal-id user-id #:permission perm)
         #t)))

(define (repo-grants conn p id)
  (define o (repo-get conn p id))
  (and o
       (let ()
         (require-perm conn p "files:write" #:resource (obj->resource o))
         (for/list ([r (in-list (query-rows conn
                (string-append "SELECT g.principal_type, g.principal_id, g.permission, u.username "
                               "FROM resource_grants g LEFT JOIN users u ON u.id = g.principal_id "
                               "WHERE g.resource_type = 'repo' AND g.resource_id = ?") id))])
           (hasheq 'principal_type (vector-ref r 0) 'principal_id (vector-ref r 1)
                   'permission (vector-ref r 2)
                   'username (nz (vector-ref r 3)))))))

;; ---- deleting ---------------------------------------------------------------------
;; The object row is tombstoned rather than removed, so the key frees up while the
;; audit trail still resolves. The blob is removed only when no version anywhere
;; still names that digest — content addressing means another object, or another
;; version of this one, may be pointing at the same bytes.
(define (repo-delete! conn p id)
  (define o (repo-get conn p id))
  (and o
       (let ()
         (require-perm conn p "files:delete" #:resource (obj->resource o))
         (define org (hash-ref o 'org_id))
         (define versions (query-rows conn "SELECT id, digest, size FROM repo_versions WHERE object_id = ?" id))
         (query-exec conn "UPDATE repo_objects SET deleted_at = CURRENT_TIMESTAMP, current_version_id = NULL WHERE id = ?" id)
         (query-exec conn "DELETE FROM repo_versions WHERE object_id = ?" id)
         (define freed
           (for/sum ([r (in-list versions)])
             (define digest (vector-ref r 1))
             ;; Scoped to the ORG, because that is the namespace the blob lives in
             ;; (DOC-6). A global count would let another tenant's identical bytes
             ;; pin this org's copy forever — the mirror image of the dedup leak the
             ;; namespace exists to prevent.
             (define still (query-value conn
               (string-append "SELECT COUNT(*) FROM repo_versions v "
                              "JOIN repo_objects o ON o.id = v.object_id "
                              "WHERE v.digest = ? AND o.org_id = ?")
               digest org))
             (when (zero? still) (blob-delete! org digest))
             (vector-ref r 2)))
         ;; storage.bytes is a gauge, so a delete is a negative entry on the same
         ;; ledger rather than a second table (DOC-11)
         (quota-record! conn "team" (hash-ref o 'team_id) STORAGE-DIMENSION (- freed))
         (when org (quota-record! conn "org" org STORAGE-DIMENSION (- freed)))
         (audit! conn #:action "repo.delete" #:actor-type "user" #:actor-id (principal-user-id p)
                 #:team-id (hash-ref o 'team_id) #:resource-type "repo" #:resource-id id
                 #:meta (format "{\"key\":~s,\"freed\":~a}" (hash-ref o 'key) freed))
         #t)))

(define (repo-usage conn p)
  (require-perm conn p "files:read")
  (define team (principal-team-id p))
  (define used (quota-used conn "team" team STORAGE-DIMENSION "total"))
  (define-values (limit window) (get-limit conn "team" team STORAGE-DIMENSION))
  (hasheq 'dimension STORAGE-DIMENSION
          'used (max 0 used)
          'limit (or limit 'null)
          'objects (query-value conn
                    "SELECT COUNT(*) FROM repo_objects WHERE team_id = ? AND deleted_at IS NULL" team)
          'store (active-blob-store-name)))
