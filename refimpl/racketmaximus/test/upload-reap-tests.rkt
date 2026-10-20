#lang racket/base

;; test/upload-reap-tests.rkt — issue #54: an abandoned multipart upload is
;; reaped, and its staged bytes are charged and refunded.
;;   raco test test/upload-reap-tests.rkt
;;
;; What this has to prove:
;;   1. an upload whose newest PART is older than the horizon is dropped — rows,
;;      blobs and the storage charge with it
;;   2. one still making progress is NOT, however old the upload row is
;;   3. `never` disables the sweep, and a nonsense horizon falls back to the
;;      default rather than to 0 (which would reap on arrival)

(require rackunit db-kit/portable
         racket/file racket/port
         db-kit/migrate
         "../domain/db/migrations.rkt"
         "db-fixture.rkt"
         "../domain/authz/authz.rkt"
         "../domain/db/id.rkt"
         "../domain/quota/quota.rkt"
         "../domain/repo/blobs.rkt"
         "../domain/repo/repo.rkt"
         "../domain/s3/server.rkt")

(define BLOB-ROOT (make-temporary-file "telemachus-reap-~a" 'directory))
(current-blob-root BLOB-ROOT)

(define (fresh) (define c (fresh-db #:migrate? #f)) (migrate! c all-migrations) c)

;; Stage an upload with one part, as op-create-multipart + op-upload-part would,
;; and charge it the way the live path does — the reaper's job is the refund, so
;; the test has to put a real charge there to refund.
(define (stage! c team org #:age-part [age-part 0] #:age-upload [age-upload 0] #:bytes [bytes #"a part"])
  (define uid (new-id))
  (define now (current-seconds))
  (query-exec c (string-append "INSERT INTO repo_uploads (id, org_id, team_id, user_id, key, "
                               "content_type, created_epoch) VALUES (?, ?, ?, ?, ?, ?, ?)")
              uid org team "u1" "big.bin" "application/octet-stream" (- now age-upload))
  (define-values (d _size) (blob-stage! org (open-input-bytes bytes)))
  (query-exec c (string-append "INSERT INTO repo_upload_parts (id, upload_id, part_number, digest, "
                               "size, created_epoch) VALUES (?, ?, ?, ?, ?, ?)")
              (new-id) uid 1 d (bytes-length bytes) (- now age-part))
  (quota-record! c "team" team "storage.bytes" (bytes-length bytes))
  (values uid d))

(define (uploads c) (query-value c "SELECT COUNT(*) FROM repo_uploads"))
(define (parts c)   (query-value c "SELECT COUNT(*) FROM repo_upload_parts"))

(test-case "an upload older than the horizon is reaped: rows, blob and charge"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice"))
  (define org "org-reap")
  (define-values (up d) (stage! c tid org #:age-part (* 8 24 3600) #:age-upload (* 8 24 3600)))
  (check-equal? (uploads c) 1)
  (check-equal? (quota-used c "team" tid "storage.bytes" "total") 6)
  (check-true (blob-exists? org d))
  (check-equal? (reap-uploads! c) 1)
  (check-equal? (uploads c) 0)
  (check-equal? (parts c) 0)
  ;; the gauge goes back to zero — a reaped upload must not leave a team
  ;; permanently charged for bytes nobody can see or delete
  (check-equal? (quota-used c "team" tid "storage.bytes" "total") 0)
  (check-false (blob-exists? org d))
  ;; and it is auditable: "where did my upload go" has an answer
  (check-true (for/or ([e (in-list (audit-list c tid))])
                (equal? (hash-ref e 'action) "repo.upload.reaped"))))

(test-case "an upload still making progress is never reaped"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice"))
  ;; the upload ROW is ancient — a 2 GB transfer over a bad link — but a part
  ;; landed a minute ago. The clock is the part, not the create time.
  (define-values (up d) (stage! c tid "org-slow" #:age-part 60 #:age-upload (* 30 24 3600)))
  (check-equal? (reap-uploads! c) 0)
  (check-equal? (uploads c) 1))

(test-case "an upload that never sent a part falls back to its create time"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice"))
  (query-exec c (string-append "INSERT INTO repo_uploads (id, org_id, team_id, user_id, key, "
                               "content_type, created_epoch) VALUES (?, ?, ?, ?, ?, ?, ?)")
              (new-id) "org-empty" tid "u1" "never-sent.bin" "application/octet-stream"
              (- (current-seconds) (* 8 24 3600)))
  (check-equal? (reap-uploads! c) 1)
  (check-equal? (uploads c) 0))

(test-case "the horizon: never disables it, and nonsense falls back, never to 0"
  (define default (upload-reap-seconds))
  (check-equal? default (* 7 24 3600))
  (putenv "TELEMACHUS_UPLOAD_REAP_HOURS" "never")
  (check-false (upload-reap-seconds))
  (putenv "TELEMACHUS_UPLOAD_REAP_HOURS" "2")
  (check-equal? (upload-reap-seconds) 7200)
  ;; 0 would reap an upload the instant its first part landed
  (putenv "TELEMACHUS_UPLOAD_REAP_HOURS" "0")
  (check-equal? (upload-reap-seconds) default)
  (putenv "TELEMACHUS_UPLOAD_REAP_HOURS" "soon")
  (check-equal? (upload-reap-seconds) default)
  (putenv "TELEMACHUS_UPLOAD_REAP_HOURS" ""))

(test-case "never means nothing is swept, however old"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice"))
  (define-values (up d) (stage! c tid "org-never" #:age-part (* 90 24 3600) #:age-upload (* 90 24 3600)))
  (putenv "TELEMACHUS_UPLOAD_REAP_HOURS" "never")
  (check-equal? (reap-uploads! c) 0)
  (check-equal? (uploads c) 1)
  (putenv "TELEMACHUS_UPLOAD_REAP_HOURS" "")
  (check-equal? (reap-uploads! c) 1))

;; ---- one blob-release rule, org-scoped on BOTH halves (issue #86 r6) -----------
;; There were two implementations of "may this blob go", and each was wrong in a
;; different way. Both cases below FAIL against the code as it was.
;;
;;   1. `repo-delete!` counted versions in the org and never looked at
;;      `repo_upload_parts`. A staged part IS a blob in its upload's org
;;      namespace, so deleting an object whose digest a live upload had also
;;      staged destroyed the bytes that upload needed. Reachable on the ordinary
;;      dedup path: re-uploading a document that already exists is exactly when
;;      a part and a version share a digest.
;;   2. `release-blob!` counted parts GLOBALLY, so one tenant's in-flight upload
;;      pinned another tenant's identical bytes for ever.
(test-case "deleting an object does NOT destroy bytes a live upload has staged"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice"))
  (define org (query-maybe-value c "SELECT org_id FROM teams WHERE id = ?" tid))
  (define p (user-principal c uid tid))
  (define payload #"the same bytes twice")

  ;; an object holding the bytes …
  (define o (repo-put! c p #:key "docs/a.bin" #:port (open-input-bytes payload)
                       #:content-type "application/octet-stream" #:filename "a.bin"))
  (define d (query-value c "SELECT digest FROM repo_versions WHERE object_id = ?" (hash-ref o 'id)))
  ;; … and an in-flight multipart upload staging the SAME digest, which is what a
  ;; re-upload of an existing document produces
  (define-values (up d2) (stage! c tid org #:bytes payload))
  (check-equal? d d2 "the fixture only means anything if the digests match")
  (check-true (blob-exists? org d) "staged and stored")

  ;; delete the object: its version rows go, the part's reference remains
  (check-true (repo-delete! c p (hash-ref o 'id)))
  (check-true (blob-referenced? c org d) "the live upload's part still points at it")
  (check-true (blob-exists? org d)
              "the bytes a live multipart upload needs must survive the object's deletion")

  ;; and once the upload's part row goes, nothing points at the bytes any more.
  ;; The part row is removed directly rather than through `drop-upload!`: that
  ;; procedure is internal to the S3 listener and what is under test here is the
  ;; REFCOUNT RULE, not the upload lifecycle (which reap-uploads! covers above).
  (query-exec c "DELETE FROM repo_upload_parts WHERE upload_id = ?" up)
  (check-false (blob-referenced? c org d))
  (release-blob-if-unreferenced! c org d)
  (check-false (blob-exists? org d) "…and now they are collected")
  (close-db! c))

(test-case "one org's staged part does not pin another org's identical bytes"
  (define c (fresh))
  (define-values (uid-a tid-a) (bootstrap! c #:username "alice"))
  (define org-a (query-maybe-value c "SELECT org_id FROM teams WHERE id = ?" tid-a))
  ;; A second org with its own team, holding byte-identical content. The two
  ;; copies are deliberately separate blobs (DOC-6): global dedup across tenants
  ;; is an existence oracle.
  (define org-b (new-id))
  (define tid-b (new-id))
  (query-exec c "INSERT INTO orgs (id, name, slug) VALUES (?, ?, ?)" org-b "B Ltd" "b-ltd")
  (query-exec c "INSERT INTO teams (id, org_id, name, slug) VALUES (?, ?, ?, ?)"
              tid-b org-b "B team" "b-team")
  (define payload #"shared by coincidence")
  (define-values (d _n) (blob-stage! org-b (open-input-bytes payload)))
  (check-true (blob-exists? org-b d))

  ;; org A stages a part with the same digest …
  (define-values (up da) (stage! c tid-a org-a #:bytes payload))
  (check-equal? d da)
  ;; … which says nothing about org B's copy
  (check-false (blob-referenced? c org-b d)
               "a part in ANOTHER org must not count as a reference here")
  (release-blob-if-unreferenced! c org-b d)
  (check-false (blob-exists? org-b d) "org B's unreferenced copy is collected")
  ;; and org A's own copy is untouched by that
  (check-true (blob-referenced? c org-a d))
  (check-true (blob-exists? org-a d))
  (close-db! c))
