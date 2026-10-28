#lang racket/base

;; #128 job 2: operator-facing variables are read through ONE accessor,
;; which tries TMACH_<name> and falls back to TELEMACHUS_<name>.
(require (only-in "../config.rkt" tmach-env))

;; test/blob-sweep-tests.rkt — bytes with nothing pointing at them (issue #122).
;;
;; `repo-put!` writes the blob BEFORE admission (the size is not known until it
;; has, and trusting a client-supplied Content-Length is not enforcement), so an
;; over-budget upload costs one write. What was missing is anything that ever
;; collects it: `release-blob-if-unreferenced!` runs from the delete path only,
;; so a refused upload's bytes stayed for ever — and uncounted, so the quota that
;; refused it was measuring the wrong number from then on.
;;
;; What has to hold:
;;   1. a refused upload's bytes are collectable, and are collected
;;   2. the AGE FLOOR protects an upload in progress — a blob with no version row
;;      yet is the normal state for a few milliseconds, so a sweep with no floor
;;      deletes bytes somebody is about to reference
;;   3. a blob another object SHARES is never collected (the dedup path a
;;      synchronous delete-on-refusal could not survive)
;;
;;   raco test test/blob-sweep-tests.rkt

(require rackunit racket/file racket/port db-kit/portable
         db-kit/migrate
         "../domain/db/migrations.rkt"
         "db-fixture.rkt"
         "../domain/authz/authz.rkt"
         "../domain/repo/repo.rkt"
         "../domain/repo/blobs.rkt"
         (only-in "../domain/quota/quota.rkt" set-limit!))

(define (fresh) (define c (fresh-db #:migrate? #f)) (migrate! c all-migrations) c)
(define (setup)
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "root" #:password "root-pass-1"))
  (values c (user-principal c uid tid) uid tid (team-org c tid)))

;; tests MUST point the blob root at a temp dir or they write into the checkout
(define (with-blobs thunk)
  (define root (make-temporary-file "tmx-sweep-~a" 'directory))
  (dynamic-wind void
                (lambda () (parameterize ([current-blob-root root]) (thunk)))
                (lambda () (delete-directory/files root #:must-exist? #f))))

(define (put c p key body)
  (repo-put! c p #:key key #:content-type "text/plain"
             #:port (open-input-bytes body) #:filename key))

;; ---- 1. a refused upload leaves collectable bytes ---------------------------
(test-case "an over-quota upload leaves its bytes, and the sweep collects them"
  (with-blobs (lambda ()
    (define-values (c p uid tid org) (setup))
    ;; the reporter's repro: a 100-byte limit and a larger upload
    (set-limit! c "team" tid "storage.bytes" 100 #:window "total")
    (define body (make-bytes 6756 65))
    (define digest (digest-of-bytes body))
    (check-exn exn:fail? (lambda () (put c p "big.txt" body)) "the upload is refused")
    ;; …and the bytes are there, with nothing pointing at them
    (check-true (blob-exists? org digest) "the write happened before admission, as designed")
    (check-false (blob-referenced? c org digest) "and no version row points at it")
    ;; the staging row is what makes it findable without listing the store
    (check-equal? (query-value c "SELECT COUNT(*) FROM repo_blob_staging") 1)
    ;; the floor has not passed, so a sweep now must NOT touch it
    (define-values (c0 k0) (reap-staged-blobs! c))
    (check-equal? (list c0 k0) '(0 0) "nothing is collected inside the floor")
    (check-true (blob-exists? org digest))
    ;; age the row past the floor rather than sleeping an hour
    (query-exec c "UPDATE repo_blob_staging SET staged_epoch = ?" (- (current-seconds) 100000))
    (define-values (c1 k1) (reap-staged-blobs! c))
    (check-equal? c1 1 "collected")
    (check-equal? k1 0)
    (check-false (blob-exists? org digest) "the bytes are gone")
    (check-equal? (query-value c "SELECT COUNT(*) FROM repo_blob_staging") 0 "and so is the row")
    (disconnect c))))

;; ---- 2. the floor is a correctness requirement ------------------------------
(test-case "a SUCCESSFUL upload leaves no staging row at all"
  (with-blobs (lambda ()
    (define-values (c p uid tid org) (setup))
    (define o (put c p "fine.txt" #"hello"))
    (check-true (hash? o))
    (check-equal? (query-value c "SELECT COUNT(*) FROM repo_blob_staging") 0
                  "the row goes once a version row points at the blob — otherwise every
                   later sweep would re-ask the same question for ever")
    ;; a sweep cannot touch a live document however long it runs
    (query-exec c "UPDATE repo_blob_staging SET staged_epoch = 0")
    (define-values (n k) (reap-staged-blobs! c))
    (check-equal? (list n k) '(0 0))
    (check-true (blob-exists? org (digest-of-bytes #"hello")))
    (disconnect c))))

;; ---- 3. a shared blob is never collected ------------------------------------
(test-case "a blob a second object shares is kept, bytes and all"
  ;; THE case delete-on-refusal could not survive: content is stored once per
  ;; ORG, so two objects in one company with the same bytes share one blob.
  ;; #86 slice 1 had to fix this exact class once already.
  (with-blobs (lambda ()
    (define-values (c p uid tid org) (setup))
    (define body #"shared bytes")
    (define digest (digest-of-bytes body))
    (define oa (put c p "a.txt" body))
    (void (put c p "b.txt" body))
    (check-true (blob-referenced? c org digest))
    ;; now forge the state a refusal would leave: a staging row for a digest that
    ;; IS referenced, which is also exactly what a concurrent upload of the same
    ;; bytes produces
    (stage-blob! c org digest)
    (query-exec c "UPDATE repo_blob_staging SET staged_epoch = 0")
    (define-values (n k) (reap-staged-blobs! c))
    (check-equal? n 0 "nothing collected")
    (check-equal? k 1 "the row is cleared, having been found referenced")
    (check-true (blob-exists? org digest) "THE BYTES SURVIVE — two objects need them")
    (check-equal? (query-value c "SELECT COUNT(*) FROM repo_objects") 2)
    ;; both documents still read back
    ;; `repo-get` takes an ID, not a key — use the object `put` handed back. And
    ;; `repo-open` answers TWO values (the port and the version's metadata).
    (define-values (meta in) (repo-open c p (hash-ref oa (quote id))))
    (check-equal? (port->bytes in) body "the shared document still reads back")
    (disconnect c))))

;; ---- the knob ---------------------------------------------------------------
(test-case "the floor is configurable, disablable, and never falls back to zero"
  (define old (tmach-env "BLOB_STAGE_REAP_MINUTES"))
  (dynamic-wind
   void
   (lambda ()
     (putenv "TMACH_BLOB_STAGE_REAP_MINUTES" "")      (check-equal? (stage-reap-seconds) 3600)
     (putenv "TMACH_BLOB_STAGE_REAP_MINUTES" "5")     (check-equal? (stage-reap-seconds) 300)
     (putenv "TMACH_BLOB_STAGE_REAP_MINUTES" "never") (check-false (stage-reap-seconds))
     ;; a zero floor would delete the bytes of an upload in progress, so these
     ;; fall back to the default rather than to 0 — the platform's rule
     (putenv "TMACH_BLOB_STAGE_REAP_MINUTES" "0")      (check-equal? (stage-reap-seconds) 3600)
     (putenv "TMACH_BLOB_STAGE_REAP_MINUTES" "-10")    (check-equal? (stage-reap-seconds) 3600)
     (putenv "TMACH_BLOB_STAGE_REAP_MINUTES" "banana") (check-equal? (stage-reap-seconds) 3600))
   (lambda () (if old (putenv "TMACH_BLOB_STAGE_REAP_MINUTES" old)
                  (putenv "TMACH_BLOB_STAGE_REAP_MINUTES" "")))))

(test-case "`never` really disables it, even for a row past any floor"
  (with-blobs (lambda ()
    (define-values (c p uid tid org) (setup))
    (stage-blob! c org (digest-of-bytes #"x"))
    (query-exec c "UPDATE repo_blob_staging SET staged_epoch = 0")
    (define old (tmach-env "BLOB_STAGE_REAP_MINUTES"))
    (dynamic-wind
     (lambda () (putenv "TMACH_BLOB_STAGE_REAP_MINUTES" "never"))
     (lambda ()
       (define-values (n k) (reap-staged-blobs! c))
       (check-equal? (list n k) '(0 0))
       (check-equal? (query-value c "SELECT COUNT(*) FROM repo_blob_staging") 1
                     "the row is left alone too, not silently cleared"))
     (lambda () (if old (putenv "TMACH_BLOB_STAGE_REAP_MINUTES" old)
                    (putenv "TMACH_BLOB_STAGE_REAP_MINUTES" ""))))
    (disconnect c))))
