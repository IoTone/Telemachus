#lang racket/base

;; rs3 — the local backing store for the document repository (DOC-5).
;;
;; This whole file is the extension contract for a blob backend. It registers four
;; procedures under a name; `TELEMACHUS_BLOB_STORE=rs3` selects them (and rs3 is the
;; default when the plugin is present). Swapping in MinIO, a real S3 bucket, or an
;; NFS mount means writing this file again with the same four procedures — nothing
;; above needs to change, and nothing here needs to understand teams or permissions.
;;
;; What it is handed: a namespace (the org id) and a 64-character hex digest. Never a
;; user, a team, a key, or a filename. Authorization happened before this was called.
;;
;; Layout:  $RS3_ROOT/<org>/<ab>/<cd>/<sha256>
;; Two levels of fan-out keep any one directory small; the org level is the
;; deduplication boundary (DOC-6), so two companies holding identical bytes hold two
;; copies on purpose.

(require racket/file racket/port racket/string
         (only-in "../../domain/repo/blobs.rkt" register-blob-store!))

(provide init! rs3-root)

;; RS3_ROOT wins, then TELEMACHUS_DATA_DIR/blobs, then ./data/blobs — the same
;; precedence the rest of the server uses for state.
(define (rs3-root)
  (define explicit (getenv "TELEMACHUS_RS3_ROOT"))
  (if (and explicit (not (string=? explicit "")))
      (string->path explicit)
      (build-path (let ([d (getenv "TELEMACHUS_DATA_DIR")])
                    (if (and d (not (string=? d ""))) d "data"))
                  "blobs")))

(define (blob-path ns digest)
  (build-path (rs3-root) ns (substring digest 0 2) (substring digest 2 4) digest))

(define (dir-of p)
  (define-values (dir _n _d?) (split-path p))
  dir)

;; Idempotent: the name is the content, so a blob that exists is already correct and
;; re-writing it can only risk making it worse. Two uploaders racing on the same
;; bytes both succeed and neither observes a partial file, because the write lands on
;; a temp name and is renamed into place — rename is atomic within a filesystem.
(define (rs3-put! ns digest in size)
  (define p (blob-path ns digest))
  (unless (file-exists? p)
    (make-parent-directory* p)
    (define tmp (build-path (dir-of p) (format ".~a.~a.part" digest (current-inexact-milliseconds))))
    (with-handlers ([(lambda (_) #t)
                     (lambda (e) (when (file-exists? tmp) (delete-file tmp)) (raise e))])
      (call-with-output-file tmp #:exists 'truncate/replace
        (lambda (out) (copy-port in out) (flush-output out)))
      ;; #t = replace: another writer may have won the race with identical bytes
      (rename-file-or-directory tmp p #t))))

(define (rs3-get ns digest)
  (define p (blob-path ns digest))
  (and (file-exists? p) (open-input-file p)))

(define (rs3-delete! ns digest)
  (define p (blob-path ns digest))
  (when (file-exists? p) (delete-file p)))

(define (rs3-stat ns digest)
  (define p (blob-path ns digest))
  (and (file-exists? p) (file-size p)))

(define (init!)
  (register-blob-store! "rs3"
    (hash 'put! rs3-put! 'get rs3-get 'delete! rs3-delete! 'stat rs3-stat)))
