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
         racket/file racket/port racket/string racket/list racket/date
         "../db/id.rkt"
         "../authz/authz.rkt"
         "../quota/quota.rkt"
         "blobs.rkt")

(provide repo-put! set-put-hook!
         repo-get repo-open repo-list repo-versions
         repo-set-visibility! repo-delete! repo-usage
         repo-share! repo-unshare! repo-grants
         repo-inherit! repo-derivations
         CAPABILITIES capability-permissions permissions->capability
         expiry->seconds seconds->iso8601
         VISIBILITIES valid-key? inline-safe? STORAGE-DIMENSION)

(define STORAGE-DIMENSION "storage.bytes")

;; ---- the post-write seam (slice 58, DWF-1) -------------------------------------
;; Exactly one place learns that a document arrived: the end of repo-put!, once the
;; version row exists. Console upload, the documents shim and an S3 PUT all pass
;; through here, so a subscriber (domain/repo/triggers.rkt) sees every arrival
;; without three copies of the hook. The hook is a box, not a parameter: a value
;; every thread sees, set once at boot. It is called with the written object and
;; whether the caller marked it DERIVED (a pipeline output), and it must never fail
;; the upload — the subscriber owns its own error handling.
(define put-hook (box (lambda (conn p obj #:derived? derived?) (void))))
(define (set-put-hook! f) (set-box! put-hook f))
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
                   ;; the documents shim stores a body the OLD API allowed to be "" —
                   ;; the empty-upload guard exists to catch accidental empties over
                   ;; HTTP, not to forbid an empty document on purpose
                   #:allow-empty? [allow-empty? #f]
                   ;; who to record as the author. Multipart completes on behalf of
                   ;; whoever started the upload, which need not be who finishes it.
                   #:as [as-user #f]
                   ;; a pipeline OUTPUT (DWF-3): #t, or the RUN ID it came from.
                   ;; Triggers leave it alone unless they opted in — and never fire
                   ;; on the output of a run they started themselves, which is why
                   ;; the run id is worth passing: the derivation row that would
                   ;; say so is written AFTER this call returns.
                   #:derived? [derived? #f])
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
  (when (and (zero? size) (not allow-empty?)) (raise-user-error 'repo "empty upload"))
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
  (define obj (row->obj (obj-row conn oid)))
  ((unbox put-hook) conn p obj #:derived? derived?)
  obj)

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
(define (repo-list conn p #:prefix [prefix ""] #:limit [limit 100] #:offset [offset 0]
                   ;; DSH step 3: only objects the caller holds a LIVE grant on and does
                   ;; not own — what someone handed them, as distinct from what the team
                   ;; can see anyway. The per-row can? below still runs on each.
                   #:shared-with-me? [shared? #f])
  (require-perm conn p "files:read")
  (define rows
    (if shared?
        (query-rows conn
          (string-append OSELECT " WHERE o.team_id = ? AND o.deleted_at IS NULL AND o.key LIKE ? "
                         "AND o.owner_user_id <> ? "
                         "AND EXISTS (SELECT 1 FROM resource_grants g WHERE g.resource_type = 'repo' "
                         "  AND g.resource_id = o.id AND (g.expires_at IS NULL OR g.expires_at > ?) "
                         "  AND ((g.principal_type = 'user' AND g.principal_id = ?) "
                         "    OR (g.principal_type = 'team' AND g.principal_id = ?))) "
                         "ORDER BY o.updated_at DESC LIMIT ? OFFSET ?")
          (principal-team-id p) (string-append (escape-like prefix) "%")
          (principal-user-id p) (current-seconds) (principal-user-id p) (or (principal-team-id p) "")
          limit offset)
        (query-rows conn
          (string-append OSELECT " WHERE o.team_id = ? AND o.deleted_at IS NULL AND o.key LIKE ? "
                         "ORDER BY o.key ASC LIMIT ? OFFSET ?")
          (principal-team-id p)
          (string-append (escape-like prefix) "%")
          limit offset)))
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
         ;; DSH-1: changing who can see a document is `manage`, not `edit` — an
         ;; editor may replace the bytes, not widen the audience.
         (require-perm conn p "files:manage" #:resource (obj->resource o))
         (query-exec conn "UPDATE repo_objects SET visibility = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ?" vis id)
         (audit! conn #:action "repo.visibility" #:actor-type "user" #:actor-id (principal-user-id p)
                 #:team-id (hash-ref o 'team_id) #:resource-type "repo" #:resource-id id
                 #:meta (format "{\"visibility\":~s}" vis))
         (row->obj (obj-row conn id)))))

;; ---- capabilities (DSH-1) ---------------------------------------------------------
;; A person sharing a document picks one of three words. Each is a SET of permission
;; strings, granted row by row, never a wildcard: a grant row says exactly what it
;; says. `manage` implies `edit` implies `view` because the sets nest. The owner
;; holds all three by owner-ok and needs no row.
;;
;; `manage` carries files:delete as well as files:manage — the catalog has a
;; separate delete permission, and "manage" that cannot delete is not stewardship.
(define CAPABILITIES
  '(("view"   "files:read")
    ("edit"   "files:read" "files:write")
    ("manage" "files:read" "files:write" "files:delete" "files:manage")))
(define ALL-CAPABILITY-PERMS
  (remove-duplicates (append* (map cdr CAPABILITIES))))

(define (capability-permissions cap)
  (define e (assoc cap CAPABILITIES))
  (and e (cdr e)))

;; the widest capability whose whole set the given permissions cover; #f if none
;; (a hand-written grant of files:write alone is not a capability)
(define (permissions->capability perms)
  (for/fold ([best #f]) ([e (in-list CAPABILITIES)])
    (if (for/and ([q (in-list (cdr e))]) (and (member q perms) #t)) (car e) best)))

(define PRINCIPAL-TYPES '("user" "team"))

;; ---- expiry (DSH-3) --------------------------------------------------------------
;; The API accepts ISO-8601 ("2026-12-31T00:00:00Z", an offset, or a bare date) or
;; epoch seconds; the row stores epoch seconds; listings hand back ISO-8601 UTC.
(define (expiry->seconds v)
  (cond
    [(or (not v) (eq? v 'null) (equal? v "")) #f]
    [(exact-integer? v) v]
    [(and (real? v) (integer? v)) (inexact->exact v)]
    [(and (string? v) (regexp-match? #px"^[0-9]+$" v)) (string->number v)]
    [(string? v)
     (define m (regexp-match
                #px"^([0-9]{4})-([0-9]{2})-([0-9]{2})(?:[T ]([0-9]{2}):([0-9]{2})(?::([0-9]{2}))?(?:\\.[0-9]+)?)?(Z|[+-][0-9]{2}:?[0-9]{2})?$"
                v))
     (unless m (raise-user-error 'repo "expires_at must be ISO-8601 or epoch seconds"))
     (define (n i) (let ([x (list-ref m i)]) (if x (string->number x) 0)))
     (define base
       (with-handlers ([exn:fail? (lambda (_) (raise-user-error 'repo "expires_at is not a valid date"))])
         (find-seconds (n 6) (n 5) (n 4) (n 3) (n 2) (n 1) #f)))
     (define tz (list-ref m 7))
     (define offset
       (cond
         [(or (not tz) (string=? tz "Z")) 0]
         [else
          (define sign (if (char=? (string-ref tz 0) #\-) -1 1))
          (define digits (regexp-replace* #px"[^0-9]" tz ""))
          (* sign (+ (* 3600 (string->number (substring digits 0 2)))
                     (* 60 (string->number (substring digits 2 4)))))]))
     (- base offset)]
    [else (raise-user-error 'repo "expires_at must be ISO-8601 or epoch seconds")]))

(define (seconds->iso8601 secs)
  (define d (seconds->date secs #f))
  (define (two n) (if (< n 10) (format "0~a" n) (number->string n)))
  (format "~a-~a-~aT~a:~a:~aZ" (date-year d) (two (date-month d)) (two (date-day d))
          (two (date-hour d)) (two (date-minute d)) (two (date-second d))))

;; DSH-6: a grant may name a person or a team, and only one in THIS org. The org
;; gate would leave a cross-company row inert anyway; refusing it here means nobody
;; is told "shared" about something that will never open.
(define (principal-in-org? conn ptype pid org)
  (cond
    [(equal? ptype "team") (equal? (team-org conn pid) org)]
    [else
     (or (equal? (user-org conn pid) org)
         ;; an operator's users.org_id is NULL; membership in a team of the org
         ;; is the other way to belong to it
         (positive? (query-value conn
           (string-append "SELECT COUNT(*) FROM memberships m JOIN teams t ON t.id = m.team_id "
                          "WHERE m.user_id = ? AND m.status = 'active' AND t.org_id = ?")
           pid org)))]))

;; ---- sharing (DSH-1, DSH-2, DSH-3, DSH-6) -------------------------------------------
;; Sharing is what `shared` means: private, plus an explicit grant list. It is a
;; stewardship act (DSH-2): the owner, a team admin, or a `manage` grantee. A viewer
;; cannot forward what they were shown; neither can an editor.
;;
;; `#:user` is the original spelling and still means "this person, view".
;; Sharing again with the SAME principal replaces the capability — narrowing an
;; editor to a viewer drops the write row — and renews the expiry.
(define (repo-share! conn p id
                     #:user [user-id #f]
                     #:principal-type [ptype* #f] #:principal-id [pid* #f]
                     #:capability [cap "view"]
                     #:expires-at [expires-at #f])
  (define ptype (or ptype* (and user-id "user")))
  (define pid   (or pid* user-id))
  (unless (member ptype PRINCIPAL-TYPES)
    (raise-user-error 'repo "principal_type must be one of ~a" (string-join PRINCIPAL-TYPES ", ")))
  (unless (and (string? pid) (not (string=? pid "")))
    (raise-user-error 'repo "principal_id is required"))
  (define perms (capability-permissions cap))
  (unless perms
    (raise-user-error 'repo "capability must be one of ~a" (string-join (map car CAPABILITIES) ", ")))
  (when (and expires-at (<= expires-at (current-seconds)))
    (raise-user-error 'repo "expires_at is in the past"))
  (define o (repo-get conn p id))
  (and o
       (let ()
         (require-perm conn p "files:manage" #:resource (obj->resource o))
         (unless (principal-in-org? conn ptype pid (hash-ref o 'org_id))
           (raise-user-error 'repo "no such ~a in this organization" ptype))
         (for ([perm (in-list perms)])
           (grant! conn #:resource-type "repo" #:resource-id id
                   #:principal-type ptype #:principal-id pid
                   #:permission perm #:by (principal-user-id p) #:expires-at expires-at))
         (for ([perm (in-list ALL-CAPABILITY-PERMS)] #:unless (member perm perms))
           (revoke! conn #:resource-type "repo" #:resource-id id
                    #:principal-type ptype #:principal-id pid #:permission perm))
         ;; a team-visible object gains nothing from a grant; sharing implies narrowing
         (when (equal? (hash-ref o 'visibility) "team")
           (query-exec conn "UPDATE repo_objects SET visibility = 'shared' WHERE id = ?" id))
         (audit! conn #:action "repo.share" #:actor-type "user" #:actor-id (principal-user-id p)
                 #:team-id (hash-ref o 'team_id) #:resource-type "repo" #:resource-id id
                 #:meta (format "{\"principal_type\":~s,\"principal_id\":~s,\"capability\":~s,\"expires_at\":~a}"
                                ptype pid cap (if expires-at (format "~s" (seconds->iso8601 expires-at)) "null")))
         #t)))

;; Revoking removes every row the principal holds on the object — a revoke is a
;; revoke, not a permission-by-permission negotiation. (An EXPIRED row is left by
;; time, not by this; see has-grant?.)
(define (repo-unshare! conn p id
                       #:user [user-id #f]
                       #:principal-type [ptype* #f] #:principal-id [pid* #f]
                       ;; the original spelling took one permission; ignored now —
                       ;; kept so old callers still compile
                       #:permission [_perm #f])
  (define ptype (or ptype* (and user-id "user")))
  (define pid   (or pid* user-id))
  (unless (member ptype PRINCIPAL-TYPES)
    (raise-user-error 'repo "principal_type must be one of ~a" (string-join PRINCIPAL-TYPES ", ")))
  (unless (and (string? pid) (not (string=? pid "")))
    (raise-user-error 'repo "principal_id is required"))
  (define o (repo-get conn p id))
  (and o
       (let ()
         (require-perm conn p "files:manage" #:resource (obj->resource o))
         (query-exec conn
           (string-append "DELETE FROM resource_grants WHERE resource_type = 'repo' AND resource_id = ? "
                          "AND principal_type = ? AND principal_id = ?")
           id ptype pid)
         (audit! conn #:action "repo.unshare" #:actor-type "user" #:actor-id (principal-user-id p)
                 #:team-id (hash-ref o 'team_id) #:resource-type "repo" #:resource-id id
                 #:meta (format "{\"principal_type\":~s,\"principal_id\":~s}" ptype pid))
         #t)))

;; One entry per principal, with the capability its rows add up to. Expired rows
;; are listed and flagged rather than hidden — "who could see this in March" is a
;; question the list should still answer.
(define (repo-grants conn p id)
  (define o (repo-get conn p id))
  (and o
       (let ()
         (require-perm conn p "files:manage" #:resource (obj->resource o))
         (define rows (query-rows conn
                (string-append "SELECT g.principal_type, g.principal_id, g.permission, g.granted_by, "
                               "       g.created_at, g.expires_at, u.username, t.name "
                               "FROM resource_grants g "
                               "LEFT JOIN users u ON g.principal_type = 'user' AND u.id = g.principal_id "
                               "LEFT JOIN teams t ON g.principal_type = 'team' AND t.id = g.principal_id "
                               "WHERE g.resource_type = 'repo' AND g.resource_id = ? "
                               "ORDER BY g.created_at, g.principal_type, g.principal_id, g.permission") id))
         (define now (current-seconds))
         ;; group by principal, keeping first-seen order
         (define order '())
         (define groups (make-hash))
         (for ([r (in-list rows)])
           (define k (cons (vector-ref r 0) (vector-ref r 1)))
           (unless (hash-has-key? groups k) (set! order (cons k order)))
           (hash-update! groups k (lambda (l) (cons r l)) '()))
         (for/list ([k (in-list (reverse order))])
           (define rs (reverse (hash-ref groups k)))
           (define perms (map (lambda (r) (vector-ref r 2)) rs))
           (define r0 (car rs))
           (define exp (let ([e (vector-ref r0 5)]) (if (sql-null? e) #f e)))
           (hasheq 'principal_type (car k) 'principal_id (cdr k)
                   'username (nz (vector-ref r0 6))
                   'name (nz (if (equal? (car k) "team") (vector-ref r0 7) (vector-ref r0 6)))
                   'capability (or (permissions->capability perms) 'null)
                   'permissions perms
                   'granted_by (nz (vector-ref r0 3))
                   'created_at (format "~a" (vector-ref r0 4))
                   'expires_at (if exp (seconds->iso8601 exp) 'null)
                   'expired (and exp (<= exp now)))))))

;; ---- derived documents (DSH-5) --------------------------------------------------------
;; A workflow output takes the source's visibility and LIVE grants at the moment of
;; creation, and is owned by the run's principal (that is who wrote it). After this
;; call the two are independent: narrowing the source later does not narrow a
;; translation already shared. The derivation row is what records that the copy
;; happened, and from what — provenance for "where did this form come from?".
(define (repo-inherit! conn p #:source source-id #:target target-id
                       #:run-id [run-id #f] #:step-id [step-id #f])
  (define src (repo-get conn p source-id))          ; files:read on the source
  (define dst (repo-get conn p target-id))
  (unless (and src dst) (raise-user-error 'repo "inherit: no such object"))
  (when (equal? source-id target-id) (raise-user-error 'repo "inherit: a document cannot derive from itself"))
  ;; copying grants onto the target is sharing it — the same stewardship check.
  ;; The run's principal owns what it just wrote, so owner-ok covers the normal case.
  (require-perm conn p "files:manage" #:resource (obj->resource dst))
  (query-exec conn "UPDATE repo_objects SET visibility = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ?"
              (hash-ref src 'visibility) target-id)
  (for ([r (in-list (query-rows conn
              (string-append "SELECT principal_type, principal_id, permission, granted_by, expires_at "
                             "FROM resource_grants WHERE resource_type = 'repo' AND resource_id = ? "
                             "AND (expires_at IS NULL OR expires_at > ?)")
              source-id (current-seconds)))])
    (grant! conn #:resource-type "repo" #:resource-id target-id
            #:principal-type (vector-ref r 0) #:principal-id (vector-ref r 1)
            #:permission (vector-ref r 2)
            #:by (let ([b (vector-ref r 3)]) (if (sql-null? b) (principal-user-id p) b))
            #:expires-at (let ([e (vector-ref r 4)]) (if (sql-null? e) #f e))))
  (define (nullable v) (if (or (not v) (eq? v 'null)) sql-null v))
  (query-exec conn
    (string-append "INSERT INTO repo_derivations "
                   "(id, object_id, version_id, source_object_id, source_version_id, run_id, step_id) "
                   "VALUES (?, ?, ?, ?, ?, ?, ?)")
    (new-id) target-id (nullable (hash-ref dst 'version_id))
    source-id (nullable (hash-ref src 'version_id)) (nullable run-id) (nullable step-id))
  (audit! conn #:action "repo.inherit" #:actor-type "user" #:actor-id (principal-user-id p)
          #:team-id (hash-ref dst 'team_id) #:resource-type "repo" #:resource-id target-id
          #:meta (format "{\"source\":~s,\"run_id\":~s}" source-id (or run-id "")))
  (row->obj (obj-row conn target-id)))

;; where a document came from: its derivation rows, newest first. Reading
;; provenance needs only files:read on the document itself.
(define (repo-derivations conn p id)
  (define o (repo-get conn p id))
  (and o
       (for/list ([r (in-list (query-rows conn
              (string-append "SELECT source_object_id, source_version_id, version_id, run_id, step_id, created_at "
                             "FROM repo_derivations WHERE object_id = ? ORDER BY created_at DESC") id))])
         (hasheq 'source_object_id (vector-ref r 0) 'source_version_id (nz (vector-ref r 1))
                 'version_id (nz (vector-ref r 2)) 'run_id (nz (vector-ref r 3))
                 'step_id (nz (vector-ref r 4)) 'created_at (format "~a" (vector-ref r 5))))))

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
         ;; the extracted-text index row dies with the object (no FK cascade — SQLite
         ;; portability), or a deleted document would keep matching searches
         (query-exec conn "DELETE FROM repo_text WHERE object_id = ?" id)
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
