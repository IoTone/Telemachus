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
         (only-in "../../config.rkt" data-dir)
         (only-in "../sched/scheduler.rkt" current-plugin)
         sha2-kit)

(provide register-blob-store! blob-store-names blob-store-owners active-blob-store-name
         blob-store-probe
         blob-put! blob-get blob-delete! blob-size blob-exists? blob-stage!
         digest-of-bytes digest-of-port valid-digest?
         current-blob-root blob-root)

;; ---- registry ----------------------------------------------------------------
(define *stores* (box (hash)))

;; store: a hash with 'put! 'get 'delete! 'stat, each taking the namespace first.
;;   put!    : (namespace digest input-port expected-size) -> void
;;   get     : (namespace digest) -> input-port or #f
;;   delete! : (namespace digest) -> void
;;   stat    : (namespace digest) -> exact-nonnegative-integer or #f
;; A SECOND registration of a name another plugin owns is REFUSED and names both
;; sides (issue #120). It used to be a bare `hash-set`, so a later plugin replaced
;; an earlier one silently — and the direction that was reported is the one that
;; reads worst: a downstream plugin registered "s3", the platform's own s3blobs
;; registered "s3" later in directory order, the platform's won, and every upload
;; then failed with an error naming configuration the integrator had never set. A
;; collision that reads as a platform bug rather than as their own name clash.
;;
;; Re-registering your OWN name is fine: the loader may run twice in one process.
;; That is `register-extractor!`'s rule, and the reason it tracks the OWNER rather
;; than just the name — a flat "refuse any duplicate" breaks a reload. Job kinds
;; (scheduler.rkt) and plugin ids (plugins.rkt) both refuse and name the
;; collision too; this registry was the only plugin-owned one that did not.
(define *store-owners* (box (hash)))
(define (register-blob-store! name store)
  (define pid (current-plugin))
  (define owner (hash-ref (unbox *store-owners*) name 'none))
  (when (and (not (eq? owner 'none)) (not (equal? owner pid)))
    (error 'register-blob-store!
           (string-append "blob store ~s is already registered by ~a, so ~a cannot claim it. "
                          "Pick another name and select it with TELEMACHUS_BLOB_STORE.")
           name (or owner "the platform") (or pid "the platform")))
  (set-box! *store-owners* (hash-set (unbox *store-owners*) name pid))
  (set-box! *stores* (hash-set (unbox *stores*) name store)))

;; name -> owning plugin id (#f for one registered outside a plugin), so
;; GET /api/plugins can say who owns which store
(define (blob-store-owners)
  (for/list ([n (in-list (blob-store-names))])
    (cons n (hash-ref (unbox *store-owners*) n #f))))

(define (blob-store-names) (sort (hash-keys (unbox *stores*)) string<?))

(define (active-blob-store-name)
  (define want (let ([v (getenv "TELEMACHUS_BLOB_STORE")]) (and v (not (string=? v "")) v)))
  (define ps (unbox *stores*))
  (cond [(and want (hash-ref ps want #f)) want]
        [(hash-ref ps "rs3" #f) "rs3"]
        [else "builtin"]))

(define (active-store)
  (or (hash-ref (unbox *stores*) (active-blob-store-name) #f) BUILTIN))

;; ---- is the store that is in use actually usable? (issue #119) ---------------
;; `server/startup.rkt`'s probe took a filesystem PATH and wrote a file under the
;; local blob root, so with TELEMACHUS_BLOB_STORE=s3 it never touched the store
;; that would be used: an instance whose bucket was unreachable, whose
;; credentials were wrong or whose endpoint was unset started HEALTHY and failed
;; on the first upload. Three places — the ops documentation, s3blobs' own
;; header and CLAUDE.md — claimed it probed the active store, and #82's
;; requirement 5 was recorded as satisfied on the strength of that claim.
;;
;; This is the probe those three described: a real put, get, compare and delete
;; through whatever store is selected. It lives HERE rather than in startup.rkt
;; because the store seam is here, and a probe that takes a path instead of a
;; store is the whole bug — handing the old one a different path would not fix it.
;;
;; -> #f when the store works, else a one-line reason.
(define PROBE-NAMESPACE "startup-probe")
(define (blob-store-probe)
  (define name (active-blob-store-name))
  (define body (string->bytes/utf-8 (format "telemachus blob store probe ~a" (current-milliseconds))))
  (define digest (digest-of-bytes body))
  (with-handlers ([exn:fail? (lambda (e) (format "blob store ~a: ~a" name (exn-message e)))])
    (blob-put! PROBE-NAMESPACE digest (open-input-bytes body) (bytes-length body))
    (define back
      (dynamic-wind
       void
       (lambda ()
         (define in (blob-get PROBE-NAMESPACE digest))
         (and in (let ([bs (port->bytes in)]) (close-input-port in) bs)))
       ;; the probe blob goes whatever happens, including when the read failed —
       ;; otherwise a store that can write and not read accumulates one per boot
       (lambda ()
         (with-handlers ([exn:fail? (lambda (_) (void))])
           (blob-delete! PROBE-NAMESPACE digest)))))
    (cond
      [(not back) (format "blob store ~a: wrote a blob and could not read it back" name)]
      ;; not merely "some bytes came back": a store that answers a GET with the
      ;; wrong object is worse than one that answers nothing, and digest equality
      ;; is the one check this seam can make without knowing anything else
      [(not (equal? (digest-of-bytes back) digest))
       (format "blob store ~a: read back ~a bytes that are not what was written" name (bytes-length back))]
      [else #f])))

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

;; Stream a port into the store and return (values digest size).
;;
;; The temp file is the price of content addressing: the name IS the digest, and the
;; digest is not known until the last byte has been read. Everything that stores
;; bytes goes through here — a whole object, one multipart part — so there is one
;; place where "spill, hash, commit, clean up on every path" is written down.
(define (blob-stage! ns in #:max-bytes [max-bytes #f])
  (define tmp (make-temporary-file "telemachus-blob-~a"))
  (with-handlers ([(lambda (_) #t) (lambda (e) (delete-file* tmp) (raise e))])
    (call-with-output-file tmp #:exists 'truncate/replace
      (lambda (out) (copy-limited in out max-bytes)))
    (define-values (digest size) (call-with-input-file tmp digest-of-port))
    (call-with-input-file tmp (lambda (bin) (blob-put! ns digest bin size)))
    (delete-file* tmp)
    (values digest size)))

(define (delete-file* p) (when (and p (file-exists? p)) (delete-file p)))

;; A ceiling so a client cannot spend unbounded disk before anything gets to judge it.
(define (copy-limited in out limit)
  (define buf (make-bytes (* 128 1024)))
  (let loop ([total 0])
    (define n (read-bytes-avail! buf in))
    (cond
      [(eof-object? n) total]
      [else
       (define t (+ total n))
       (when (and limit (> t limit))
         (raise-user-error 'blob-stage! "upload exceeds the ~a byte limit" limit))
       (write-bytes buf out 0 n)
       (loop t)])))

;; ---- the built-in filesystem store -------------------------------------------
;; `rs3` is the shipped plugin and is what a deployment uses; this identical
;; implementation lives here so a bare checkout, and the unit tests, work with no
;; plugins directory at all. rs3 registers over it by name.
(define current-blob-root (make-parameter #f))

;; ABSOLUTE, always. A relative default here resolved against `current-directory`,
;; which `serve/servlet` repoints at the web server's own web root for the duration
;; of a request — inside the read-only Nix store on a packaged install. The symptom
;; was a doc edit failing with EACCES on a path under
;; .../web-server-lib/web-server/default-web-root/htdocs/data/. See `anchor-path`.
(define (blob-root) (root))   ; exported so a test can assert the invariant below

(define (root)
  (or (current-blob-root)
      (build-path (data-dir) "blobs")))

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
