#lang racket/base

;; domain/repo/blobs.rkt — the content-addressed blob store seam (DOC-5).
;;
;; A blob store is four procedures over (namespace, digest). It is handed a digest
;; and bytes and NOTHING ELSE: no principal, no team, no key, no filename, no
;; content type. A backend therefore cannot make an authorization decision, because
;; it is never given one to make — every such decision happens above this line, in
;; `can?`. That is what makes it safe to let a plugin supply one.
;;
;; The registry mirrors the onboarding provider registry (domain/beta/beta.rkt):
;; plugins register by name at load time, TELEMACHUS_BLOB_STORE selects one, and a
;; built-in default keeps a bare checkout working.
;;
;; `namespace` is the org id (DOC-6). Deduplication inside one company is a feature;
;; deduplication ACROSS companies is an existence oracle — "did my upload complete
;; suspiciously fast" tells you another tenant holds that exact file. The namespace
;; is what stops that, and it is the store's job to keep the two apart.

(require racket/file racket/port racket/string
         "../authz/sha2.rkt")

(provide register-blob-store! blob-store-names active-blob-store-name
         blob-put! blob-get blob-delete! blob-size blob-exists?
         digest-of-bytes digest-of-port valid-digest?
         current-blob-root)

;; ---- registry ----------------------------------------------------------------
(define *stores* (box (hash)))

;; store: a hash with 'put! 'get 'delete! 'stat, each taking the namespace first.
;;   put!    : (namespace digest input-port expected-size) -> void
;;   get     : (namespace digest) -> input-port or #f
;;   delete! : (namespace digest) -> void
;;   stat    : (namespace digest) -> exact-nonnegative-integer or #f
(define (register-blob-store! name store)
  (set-box! *stores* (hash-set (unbox *stores*) name store)))

(define (blob-store-names) (sort (hash-keys (unbox *stores*)) string<?))

(define (active-blob-store-name)
  (define want (let ([v (getenv "TELEMACHUS_BLOB_STORE")]) (and v (not (string=? v "")) v)))
  (define ps (unbox *stores*))
  (cond [(and want (hash-ref ps want #f)) want]
        [(hash-ref ps "rs3" #f) "rs3"]
        [else "builtin"]))

(define (active-store)
  (or (hash-ref (unbox *stores*) (active-blob-store-name) #f) BUILTIN))

;; ---- digests -----------------------------------------------------------------
(define (digest-of-bytes bs) (sha256-hex bs))
(define (digest-of-port in) (sha256-port-hex in))   ; -> (values hex size)

;; A digest reaches the store from a database row, and a row can be wrong. Anything
;; that is not exactly 64 lowercase hex characters is refused before it can become a
;; path segment — this is the only thing standing between a corrupt row and a path
;; traversal, so it is a whitelist, not an escape.
(define DIGEST-RX #px"^[0-9a-f]{64}$")
(define (valid-digest? d) (and (string? d) (regexp-match? DIGEST-RX d) #t))

(define (check! ns digest who)
  (unless (valid-digest? digest) (error who "not a sha-256 digest: ~s" digest))
  (unless (and (string? ns) (regexp-match? #px"^[A-Za-z0-9_-]{1,64}$" ns))
    (error who "not a usable namespace: ~s" ns)))

;; ---- the public operations ---------------------------------------------------
;; put! is idempotent by construction: the name IS the content, so writing a blob
;; that is already present is a no-op and two writers racing cannot disagree.
(define (blob-put! ns digest in size)
  (check! ns digest 'blob-put!)
  ((hash-ref (active-store) 'put!) ns digest in size))

(define (blob-get ns digest)
  (check! ns digest 'blob-get)
  ((hash-ref (active-store) 'get) ns digest))

(define (blob-delete! ns digest)
  (check! ns digest 'blob-delete!)
  ((hash-ref (active-store) 'delete!) ns digest))

(define (blob-size ns digest)
  (check! ns digest 'blob-size)
  ((hash-ref (active-store) 'stat) ns digest))

(define (blob-exists? ns digest) (and (blob-size ns digest) #t))

;; ---- the built-in filesystem store -------------------------------------------
;; `rs3` is the shipped plugin and is what a deployment uses; this identical
;; implementation lives here so a bare checkout, and the unit tests, work with no
;; plugins directory at all. rs3 registers over it by name.
(define current-blob-root (make-parameter #f))

(define (root)
  (or (current-blob-root)
      (build-path (or (getenv "TELEMACHUS_DATA_DIR") "data") "blobs")))

;; two levels of fan-out, so no directory ends up with a million entries
(define (blob-path ns digest)
  (build-path (root) ns (substring digest 0 2) (substring digest 2 4) digest))

(define (fs-put! ns digest in size)
  (define p (blob-path ns digest))
  (unless (file-exists? p)
    (make-parent-directory* p)
    ;; write to a sibling temp then rename: a reader can only ever observe a
    ;; complete blob, and a crash mid-write leaves no half-file under the digest.
    (define tmp (build-path (path-only* p) (string-append "." digest ".part")))
    (with-handlers ([(lambda (_) #t) (lambda (e) (when (file-exists? tmp) (delete-file tmp)) (raise e))])
      (call-with-output-file tmp #:exists 'truncate/replace
        (lambda (out) (copy-port in out) (flush-output out)))
      (rename-file-or-directory tmp p #t))))

(define (path-only* p)
  (define-values (dir _name _dir?) (split-path p))
  dir)

(define (fs-get ns digest)
  (define p (blob-path ns digest))
  (and (file-exists? p) (open-input-file p)))

(define (fs-delete! ns digest)
  (define p (blob-path ns digest))
  (when (file-exists? p) (delete-file p)))

(define (fs-stat ns digest)
  (define p (blob-path ns digest))
  (and (file-exists? p) (file-size p)))

(define BUILTIN (hash 'put! fs-put! 'get fs-get 'delete! fs-delete! 'stat fs-stat))
(register-blob-store! "builtin" BUILTIN)
