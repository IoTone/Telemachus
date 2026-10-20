#lang racket/base

;; cli/telemachus-blobs.rkt — move blobs from the local store into a bucket (#82 r6).
;;
;;   racket cli/telemachus-blobs.rkt plan       # what would move, nothing written
;;   racket cli/telemachus-blobs.rkt migrate    # copy rs3 -> s3, verifying each
;;   racket cli/telemachus-blobs.rkt verify     # re-read from the bucket and rehash
;;
;; WHY A CLI AND NOT A MIGRATION. `domain/db/migrations.rkt` runs at startup, and
;; this moves an unbounded number of potentially very large objects over a
;; network — a startup step that might take hours, cost money and fail halfway is
;; the wrong shape. It is also not a schema change: no row moves, because
;; `repo_versions` stores the DIGEST and the store is addressed by it, so the
;; same rows describe the blobs wherever they live. That is what makes this
;; copyable at all, and what makes it safe to run while the instance is up.
;;
;; EVERY STEP RE-HASHES. A migration that trusts the filename is a migration that
;; silently propagates a corrupt blob: rs3's layout takes the digest FROM the
;; path, so a file whose bytes rotted still looks right. Each blob is read,
;; hashed, and compared with its own name before it is written anywhere, and
;; `verify` reads it BACK out of the bucket and hashes that too. Nothing here
;; deletes from rs3 — the local copy is the fallback until an operator has
;; satisfied themselves, and deleting it is a decision, not a step.

(require racket/file racket/port racket/string racket/list racket/path
         (only-in "../domain/repo/blobs.rkt" digest-of-port valid-digest?)
         (only-in "../plugins/s3blobs/main.rkt" s3-blob-config s3-blob-key)
         (only-in "../plugins/rs3/main.rkt" rs3-root)
         (only-in "../domain/s3/client.rkt"
                  s3-put-stream s3-head s3-get-stream
                  s3-config-bucket s3-config-prefix))

(define (die fmt . args)
  (eprintf "telemachus-blobs: ~a\n" (apply format fmt args))
  (exit 1))

;; ---- what is on disk ------------------------------------------------------------
;; rs3's layout is <root>/<org>/<ab>/<cd>/<digest>, so the org is the first
;; segment under the root and the digest is the file name. The two fan-out levels
;; carry no information — they are derived from the digest — so they are not
;; reconstructed here, only walked past.
(struct local-blob (ns digest path size) #:transparent)

(define (scan-local)
  (define root (rs3-root))
  (unless (directory-exists? root) (die "no local blob store at ~a" root))
  (for*/list ([org (in-list (directory-list root))]
              #:when (directory-exists? (build-path root org))
              [p (in-directory (build-path root org))]
              #:when (file-exists? p)
              [name (in-value (path->string (file-name-from-path p)))]
              ;; A `.part` file is an upload that was interrupted; it is not a
              ;; blob and must never be copied under a name it does not own.
              #:when (valid-digest? name))
    (local-blob (path->string org) name p (file-size p))))

(define (human n)
  (cond [(>= n (* 1024 1024 1024)) (format "~a GiB" (/ (round (/ n 107374182.4)) 10.0))]
        [(>= n (* 1024 1024)) (format "~a MiB" (/ (round (/ n 104857.6)) 10.0))]
        [else (format "~a KiB" (max 1 (quotient n 1024)))]))

(define (plan)
  (define blobs (scan-local))
  (printf "local store: ~a\n" (rs3-root))
  (define by-org (make-hash))
  (for ([b (in-list blobs)])
    (hash-update! by-org (local-blob-ns b) (lambda (v) (cons (add1 (car v)) (+ (cdr v) (local-blob-size b)))) (cons 0 0)))
  (for ([(org v) (in-hash by-org)])
    (printf "  ~a: ~a blob(s), ~a\n" org (car v) (human (cdr v))))
  (printf "total: ~a blob(s), ~a\n" (length blobs) (human (for/sum ([b blobs]) (local-blob-size b))))
  (when (null? blobs) (printf "nothing to move\n")))

;; ---- the copy -------------------------------------------------------------------
(define (migrate #:verify-readback? [verify-readback? #f])
  (define cfg (s3-blob-config))
  (define blobs (scan-local))
  (printf "moving ~a blob(s) to s3://~a/~a\n"
          (length blobs) (s3-config-bucket cfg) (s3-config-prefix cfg))
  (define copied 0) (define skipped 0) (define corrupt 0) (define failed 0)
  (for ([b (in-list blobs)] [i (in-naturals 1)])
    (define key (s3-blob-key cfg (local-blob-ns b) (local-blob-digest b)))
    (with-handlers ([exn:fail?
                     (lambda (e)
                       (set! failed (add1 failed))
                       (eprintf "  [~a/~a] FAILED ~a — ~a\n" i (length blobs) key (exn-message e)))])
      (cond
        ;; Already there, and the size agrees. A content-addressed key means a
        ;; present object of the right length is the right object, so this is
        ;; what makes the command RESUMABLE after an interruption.
        [(let ([n (s3-head cfg key)]) (and n (= n (local-blob-size b))))
         (set! skipped (add1 skipped))]
        [else
         ;; Re-hash before writing. See the header: rs3 takes the digest from the
         ;; path, so a rotted file still looks correct until something hashes it.
         (define-values (d size)
           (call-with-input-file (local-blob-path b) digest-of-port))
         (cond
           [(not (string=? d (local-blob-digest b)))
            (set! corrupt (add1 corrupt))
            (eprintf "  [~a/~a] CORRUPT ~a — bytes hash to ~a; NOT copied\n"
                     i (length blobs) (local-blob-path b) d)]
           [else
            (call-with-input-file (local-blob-path b)
              (lambda (in) (s3-put-stream cfg key in size d)))
            (when verify-readback? (verify-one cfg key d))
            (set! copied (add1 copied))])])))
  (printf "copied ~a · already present ~a · corrupt ~a · failed ~a\n" copied skipped corrupt failed)
  (when (> corrupt 0)
    (printf "\nA CORRUPT blob was left alone, deliberately. Its row still points at a\n")
    (printf "digest nothing can satisfy, which is a data-loss question for an operator\n")
    (printf "and not something a copy tool should paper over.\n"))
  ;; A non-zero exit when anything did not land, so this is usable in a script.
  (when (or (> failed 0) (> corrupt 0)) (exit 1)))

;; Read it back OUT of the bucket and hash that. A PUT that reported success and
;; an object that reads back correctly are different claims, and the second is
;; the one an operator is about to delete their local copy on the strength of.
(define (verify-one cfg key expect)
  (define in (s3-get-stream cfg key))
  (unless in (error 'verify "~a is not in the bucket" key))
  (define-values (d _n) (digest-of-port in))
  (close-input-port in)
  (unless (string=? d expect)
    (error 'verify "~a reads back as ~a, not ~a" key d expect)))

(define (verify)
  (define cfg (s3-blob-config))
  (define blobs (scan-local))
  (printf "verifying ~a blob(s) by reading them back out of the bucket\n" (length blobs))
  (define ok 0) (define bad 0) (define missing 0)
  (for ([b (in-list blobs)] [i (in-naturals 1)])
    (define key (s3-blob-key cfg (local-blob-ns b) (local-blob-digest b)))
    (with-handlers ([exn:fail?
                     (lambda (e)
                       (if (regexp-match? #px"not in the bucket" (exn-message e))
                           (begin (set! missing (add1 missing))
                                  (eprintf "  MISSING ~a\n" key))
                           (begin (set! bad (add1 bad))
                                  (eprintf "  BAD ~a — ~a\n" key (exn-message e)))))])
      (verify-one cfg key (local-blob-digest b))
      (set! ok (add1 ok))))
  (printf "verified ~a · missing ~a · mismatched ~a\n" ok missing bad)
  (when (or (> bad 0) (> missing 0)) (exit 1)))

(module+ main
  (define args (vector->list (current-command-line-arguments)))
  (define cmd (if (null? args) "" (car args)))
  (case cmd
    [("plan") (plan)]
    [("migrate") (migrate #:verify-readback? (and (member "--verify" args) #t))]
    [("verify") (verify)]
    [else (die "usage: telemachus-blobs <plan|migrate [--verify]|verify>")]))
