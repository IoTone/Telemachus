#lang racket/base

;; domain/repo/staging.rkt — an upload assembled from parts (#192 slice 2).
;;
;; THIS IS NOT NEW MACHINERY. The S3 listener has staged multipart uploads since
;; slice 52 and reaped abandoned ones since #54: parts arrive out of order, each
;; is its own content-addressed blob, the object is assembled at Complete through
;; `input-port-append` into the same `repo-put!` an ordinary upload uses, and the
;; bytes are charged against `storage.bytes` on arrival and refunded in one place
;; (S3‑8). What #192 requirement 3 wants — streamed capture, chunk by chunk, with
;; a failed chunk retried rather than the whole recording re-sent — is that
;; protocol, and it was reachable only through SigV4.
;;
;; So the table-level operations move HERE and `domain/s3/server.rkt` delegates,
;; which is the move `release-blob!` already made in that same file when it got a
;; second asker: "two implementations of one rule, each missing a different half,
;; which is why there is one now and it lives with the tables it reads." Nothing
;; about the S3 behaviour changes; what changes is that the JSON plane can reach
;; it without composing a signature (STG‑1).
;;
;; WHAT STAYS IN THE LISTENER is everything S3-shaped: the XML, the error codes,
;; the ACL mapping, the ETag spelling and the part-order element. This module
;; answers values and raises `exn:fail:user?` with a sentence, so each surface
;; renders its own refusal.

(require db-kit/portable racket/string racket/list racket/port
         "../db/id.rkt"
         (only-in "../authz/authz.rkt" require-perm principal-team-id principal-user-id
                  principal-org-id team-org audit!)
         (only-in "repo.rkt" repo-put! release-blob-if-unreferenced! STORAGE-DIMENSION
                  valid-key?)
         (only-in "blobs.rkt" blob-stage! blob-get)
         (only-in "../quota/quota.rkt" quota-check quota-record!)
         (only-in "../../config.rkt" tmach-env max-upload-bytes))

(provide staging-begin! staging-row staging-put-part! staging-parts
         staging-complete! staging-drop! staging-charge!
         reap-uploads! upload-reap-seconds
         STAGING-MAX-PARTS)

;; STG‑2 — A PART HAS NO MINIMUM SIZE HERE, AND S3's 5 MiB FLOOR MUST NOT BE
;; INHERITED. That floor exists so a bucket is not asked to assemble a million
;; tiny fragments, and it is enforced by AWS rather than by this platform — the
;; listener never checked it either. A voice note recorded in the browser arrives
;; as whatever `MediaRecorder` emits on its timeslice, which for a 60-second
;; chunk of 16 kbps opus is about 120 KB. A floor would make the obvious client
;; impossible.
;;
;; What bounds it instead is the COUNT. `max-upload-bytes` caps one part and
;; nothing caps their number, which is the hole S3‑8's charge-on-arrival closed
;; for bytes; this closes the row count, because ten thousand 1-byte parts is a
;; cheap way to make Complete's `input-port-append` chain ten thousand ports.
;; 10,000 is AWS's own part limit, which makes it a number a client author has
;; already read.
(define STAGING-MAX-PARTS 10000)

;; ---- beginning one -----------------------------------------------------------
;;
;; Answers the upload id. The caller has already decided the key and the
;; visibility; this writes the row and nothing else, so an upload that is never
;; completed has cost one row and no bytes.
(define (staging-begin! conn p key content-type #:visibility [visibility #f])
  (require-perm conn p "files:write")
  ;; STG‑4 — THE KEY IS VALIDATED HERE, NOT LEFT TO `repo-put!` AT COMPLETE, and
  ;; a control is what put it here rather than in the route. `repo-put!` checks
  ;; it too and would refuse at the END — after the client had uploaded the whole
  ;; recording, which for a long voice note is minutes of somebody's time and a
  ;; storage charge that then has to be refunded. The same argument
  ;; `doc_fill_form` makes for refusing by content type before reaching the
  ;; engine, and OFFICE‑4's for checking the input before looking for the binary.
  ;;
  ;; In the MODULE so both surfaces get it: the S3 listener's Initiate did not
  ;; validate either, so `aws` could begin a multipart upload to a key that could
  ;; never be completed.
  (unless (valid-key? key) (raise-user-error 'staging "invalid key: ~s" key))
  (define uid (new-id))
  (query-exec conn
    (string-append "INSERT INTO repo_uploads "
                   "(id, org_id, team_id, user_id, key, content_type, visibility, created_epoch) "
                   "VALUES (?, ?, ?, ?, ?, ?, ?, ?)")
    uid (or (team-org conn (principal-team-id p)) (principal-org-id p))
    (principal-team-id p) (principal-user-id p) key
    (or content-type "application/octet-stream")
    (or visibility sql-null) (current-seconds))
  uid)

;; The upload, SCOPED TO THE CALLER'S TEAM. An upload id is instance-global, so
;; the team clause is what stops one team's id reaching another's row —
;; `org-team-resolve`'s lesson, and the reason this is one function rather than a
;; lookup each surface writes.
(define (staging-row conn p upload-id)
  (define r (query-maybe-row conn
    (string-append "SELECT id, org_id, team_id, user_id, key, content_type, visibility "
                   "FROM repo_uploads WHERE id = ? AND team_id = ?")
    upload-id (principal-team-id p)))
  (and r (hasheq 'id (vector-ref r 0) 'org_id (vector-ref r 1) 'team_id (vector-ref r 2)
                 'user_id (vector-ref r 3) 'key (vector-ref r 4)
                 'content_type (vector-ref r 5)
                 'visibility (let ([v (vector-ref r 6)]) (and (not (sql-null? v)) v)))))

(define (staging-parts conn upload-id)
  (for/list ([r (in-list (query-rows conn
                  (string-append "SELECT part_number, digest, size, created_epoch "
                                 "FROM repo_upload_parts WHERE upload_id = ? "
                                 "ORDER BY part_number ASC")
                  upload-id))])
    (hasheq 'part (vector-ref r 0) 'digest (vector-ref r 1)
            'size (vector-ref r 2) 'created_epoch (vector-ref r 3))))

;; ---- one part ----------------------------------------------------------------
;;
;; A part is a blob in its own right, staged exactly as a whole object is — so a
;; retried part with identical bytes costs nothing, and `UNIQUE(upload_id,
;; part_number)` means a retry REPLACES rather than duplicates. That is what
;; makes a chunk recoverable without re-sending the recording, which is
;; requirement 3's whole point.
;;
;; Answers (values digest size). Raises `exn:fail:user?` on a refusal, so the
;; surface renders its own: the listener an S3 error code, the JSON plane a 400.
(define (staging-put-part! conn up part-number in #:who [who 'staging])
  (unless (exact-positive-integer? part-number)
    (raise-user-error who "a positive part number is required"))
  (define existing (query-maybe-value conn
                     "SELECT size FROM repo_upload_parts WHERE upload_id = ? AND part_number = ?"
                     (hash-ref up 'id) part-number))
  (define prior-size (if (and existing (not (sql-null? existing))) existing 0))
  ;; STG‑2's count bound, checked BEFORE the bytes are staged: a part that would
  ;; be the 10,001st must not cost a blob write first. A REPLACEMENT is exempt,
  ;; because it adds no row — which is also what keeps a client's retry working
  ;; on an upload that has reached the ceiling.
  (when (and (not existing)
             (>= (or (query-maybe-value conn
                       "SELECT COUNT(*) FROM repo_upload_parts WHERE upload_id = ?"
                       (hash-ref up 'id))
                     0)
                 STAGING-MAX-PARTS))
    (raise-user-error who "this upload already holds ~a parts, which is the limit"
                      STAGING-MAX-PARTS))
  (define-values (digest size)
    (blob-stage! (hash-ref up 'org_id) in #:max-bytes (max-upload-bytes)))
  (define delta (- size prior-size))
  (define adm (quota-check conn "team" (hash-ref up 'team_id) STORAGE-DIMENSION delta))
  (cond
    [(not (hash-ref adm 'allowed))
     ;; the staged blob is released through the ONE rule, so a refused part never
     ;; leaves bytes another upload or object shares
     (release-blob-if-unreferenced! conn (hash-ref up 'org_id) digest)
     (raise-user-error who "storage quota exceeded: ~a of ~a bytes used"
                       (hash-ref adm 'used) (hash-ref adm 'limit))]
    [else
     (query-exec conn
       (string-append "INSERT INTO repo_upload_parts "
                      "(id, upload_id, part_number, digest, size, created_epoch) "
                      "VALUES (?, ?, ?, ?, ?, ?) "
                      "ON CONFLICT(upload_id, part_number) DO UPDATE SET "
                      "digest = excluded.digest, size = excluded.size, "
                      "created_epoch = excluded.created_epoch")
       (new-id) (hash-ref up 'id) part-number digest size (current-seconds))
     (staging-charge! conn up delta)
     (values digest size)]))

;; both tiers, as `repo-put!` bills them
(define (staging-charge! conn up amount)
  (unless (zero? amount)
    (quota-record! conn "team" (hash-ref up 'team_id) STORAGE-DIMENSION amount)
    (let ([org (team-org conn (hash-ref up 'team_id))])
      (when org (quota-record! conn "org" org STORAGE-DIMENSION amount)))))

;; ---- assembling ---------------------------------------------------------------
;;
;; `order` is the part numbers to chain, or #f for "every part, ascending". The
;; S3 surface passes the client's own list, because parts arrive concurrently and
;; the client decides the order; a streamed capture has one writer and ascending
;; IS the order, so the JSON surface passes #f and cannot get it wrong.
;;
;; The finished object is written by the same `repo-put!` an ordinary upload uses:
;; same versioning, same quota, same audit entry, same trigger seam — so a
;; completed voice note fires `transcribe-documents`' trigger exactly as a
;; single-shot PUT would.
(define (staging-complete! conn p up [order #f] #:who [who 'staging])
  (define have (for/hash ([pt (in-list (staging-parts conn (hash-ref up 'id)))])
                 (values (hash-ref pt 'part) (hash-ref pt 'digest))))
  (define wanted (or order (sort (hash-keys have) <)))
  (when (null? wanted) (raise-user-error who "no parts were uploaded"))
  (define missing (filter (lambda (n) (not (hash-ref have n #f))) wanted))
  (unless (null? missing)
    (raise-user-error who "part ~a was never uploaded" (car missing)))
  (define org (hash-ref up 'org_id))
  (define ports (for/list ([n (in-list wanted)]) (blob-get org (hash-ref have n))))
  (cond
    [(memf not ports)
     (for ([q (in-list ports)]) (when q (close-input-port q)))
     (raise-user-error who "a part's data is missing from the store")]
    [else
     (define joined (apply input-port-append #t ports))
     (define o (repo-put! conn p #:key (hash-ref up 'key) #:port joined
                          #:content-type (hash-ref up 'content_type)
                          #:filename (car (reverse (string-split (hash-ref up 'key) "/")))
                          #:visibility (hash-ref up 'visibility)))
     (staging-drop! conn up)
     o]))

;; Parts are blobs, so dropping an upload must not delete bytes something else
;; still points at — another in-flight upload with an identical part, or a
;; finished object. Same org-scoped refcount as `repo-delete!` (DOC‑6).
;;
;; THIS IS THE ONE PLACE AN UPLOAD STOPS EXISTING — Complete, Abort and the
;; reaper all come through here — so the charge in `staging-put-part!` cannot be
;; left dangling by a path that forgot. At Complete the refund lands AFTER
;; `repo-put!` has charged the assembled object, so the steady state is exactly
;; what a single-shot PUT leaves.
(define (staging-drop! conn up)
  (define org (hash-ref up 'org_id))
  (define parts (query-rows conn "SELECT digest, size FROM repo_upload_parts WHERE upload_id = ?"
                            (hash-ref up 'id)))
  (define staged (for/sum ([r (in-list parts)]) (vector-ref r 1)))
  (query-exec conn "DELETE FROM repo_upload_parts WHERE upload_id = ?" (hash-ref up 'id))
  (query-exec conn "DELETE FROM repo_uploads WHERE id = ?" (hash-ref up 'id))
  (staging-charge! conn up (- staged))
  (for ([r (in-list parts)]) (release-blob-if-unreferenced! conn org (vector-ref r 0))))

;; ---- reaping an abandoned upload (issue #54) ----------------------------------
;; A client that disconnects mid-upload leaves rows and blobs behind. Nothing
;; collected them, so the bytes were invisible to the team and never reclaimed.
;;
;; The horizon is generous on purpose: a 2 GB upload over a bad link legitimately
;; takes hours, and the clock is the NEWEST PART's arrival rather than the create
;; time, so an upload still making progress is never reaped out from under the
;; client sending it. Seven days matches the lifecycle rule AWS's own guidance
;; suggests for incomplete multipart uploads.
;;
;; MOVED HERE WITH THE TABLES, and that matters for #192: it used to live in
;; `domain/s3/server.rkt`, which is a listener that is OFF BY DEFAULT. The sweep
;; always rode the pool's reaper seam rather than the listener (S3‑7's own
;; decision, "an instance that staged parts and then turned it off would hold
;; those bytes for ever") — and now that a second surface stages uploads with the
;; listener never started at all, the sweep lives where the rows do.
(define UPLOAD-REAP-DEFAULT (* 7 24 3600))

(define (upload-reap-seconds)
  (define v (tmach-env "UPLOAD_REAP_HOURS"))
  (define t (and v (string-trim v)))
  (cond
    [(and t (string-ci=? t "never")) #f]
    [else
     (define n (and t (string->number t)))
     ;; an unparseable or non-positive value falls back to the default, never to
     ;; 0 — which would reap an upload the moment its first part landed
     (if (and (real? n) (> n 0)) (inexact->exact (floor (* n 3600))) UPLOAD-REAP-DEFAULT)]))

(define (reap-uploads! conn)
  (define horizon (upload-reap-seconds))
  (cond
    [(not horizon) 0]
    [else
     (define cutoff (- (current-seconds) horizon))
     (define ids (query-list conn
       (string-append
        "SELECT u.id FROM repo_uploads u WHERE "
        ;; the newest part's arrival, falling back to the create time for an
        ;; upload that never sent one
        "COALESCE((SELECT MAX(p.created_epoch) FROM repo_upload_parts p WHERE p.upload_id = u.id), "
        "         u.created_epoch) < ?")
       cutoff))
     (for ([id (in-list ids)])
       (define r (query-maybe-row conn
         "SELECT id, org_id, team_id FROM repo_uploads WHERE id = ?" id))
       (when r
         (staging-drop! conn (hasheq 'id (vector-ref r 0) 'org_id (vector-ref r 1)
                                     'team_id (vector-ref r 2)))
         (audit! conn #:action "repo.upload.reaped" #:actor-type "system"
                 #:team-id (vector-ref r 2)
                 #:resource-type "upload" #:resource-id id)))
     (length ids)]))
