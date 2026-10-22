#lang racket/base

;; s3blobs — the object-storage backing store for the document repository (#82).
;;
;; The same four procedures `plugins/rs3/` registers, over a bucket instead of a
;; disk. Nothing above this line changes: the store is handed a namespace (the
;; org id) and a 64-character hex digest and nothing else, so it still cannot
;; make an authorization decision because it is still never given one.
;;
;; Layout:  <prefix>/<org>/<sha256>
;; Flat under the org, unlike rs3's two levels of directory fan-out: that exists
;; because a filesystem directory gets slow with a million entries, and a bucket's
;; keyspace does not. The org level is the DEDUPLICATION BOUNDARY (DOC-6) and is
;; the one part of the layout that is load-bearing — global dedup across tenants
;; is an existence oracle, so two companies holding identical bytes hold two
;; objects, on purpose.
;;
;; WHERE THE BOOT HEALTH CHECK IS — and it took issue #119 to make this comment
;; true. Requirement 5 asks for one that verifies bucket access and encryption
;; settings at boot. It was recorded as satisfied by `server/startup.rkt`'s
;; existing probe, "which goes through `s3-put!` below"; it did not, because that
;; probe took a filesystem PATH and wrote a file under the local blob root, so
;; with the endpoint unset an instance started healthy and every upload answered
;; 500. `blob-store-probe` (domain/repo/blobs.rkt) is the real one: a put, a get,
;; a digest compare and a delete through the ACTIVE store, fatal on failure. It
;; does go through `s3-put!` below, which asserts the bucket reported
;; server-side encryption — so credentials, endpoint reachability, bucket
;; existence, Put/Get/Delete permission and the encryption posture are all
;; checked by one probe, which is what the original note wanted to be able to say.

(require racket/port racket/string
         (only-in "../../domain/repo/blobs.rkt" register-blob-store!)
         (only-in "../../domain/s3/client.rkt"
                  s3-config s3-config-prefix
                  s3-put-stream s3-get-stream s3-head s3-delete))

(provide init! s3-blob-config s3-blob-key)

;; ---- configuration --------------------------------------------------------------
;; Read at CALL time rather than captured at load, which is what `rs3-root` does
;; and what lets a test point the store somewhere else without reloading plugins.
;;
;; NAMING, because there are now two S3s in this tree and confusing them is
;; expensive. TELEMACHUS_S3_PORT and TELEMACHUS_S3_REGION belong to the S3 API
;; this server SERVES (slice 52); the variables read below describe the bucket it
;; WRITES TO, and every one of them carries BLOB in its name to keep the two
;; apart. An instance can legitimately do both at once.
;;
;; No bare prefix is written anywhere in this file on purpose: the
;; configuration-reference gate greps TELEMACHUS_ tokens out of the source, and a
;; prefix in a comment reads to it as a variable nobody documented. It reported
;; exactly that, twice, while this note was being written.
(define (env name [default #f])
  (define v (getenv name))
  (if (and v (not (string=? (string-trim v) ""))) (string-trim v) default))

(define (env-bool name default)
  (define v (env name))
  (cond [(not v) default]
        [(member (string-downcase v) '("1" "yes" "true" "on")) #t]
        [(member (string-downcase v) '("0" "no" "false" "off")) #f]
        [else default]))

(define (env-int name default)
  (define n (string->number (or (env name) "")))
  (if (and (exact-integer? n) (> n 0)) n default))

(define (s3-blob-config)
  (define sse (string-downcase (or (env "TELEMACHUS_S3_BLOB_SSE") "kms")))
  (unless (member sse '("kms" "s3" "none"))
    (error 's3blobs "TELEMACHUS_S3_BLOB_SSE must be kms, s3 or none — got ~s" sse))
  (s3-config
   (or (env "TELEMACHUS_S3_BLOB_ENDPOINT")
       (error 's3blobs "TELEMACHUS_S3_BLOB_ENDPOINT is required (http(s)://host[:port])"))
   (or (env "TELEMACHUS_S3_BLOB_BUCKET")
       (error 's3blobs "TELEMACHUS_S3_BLOB_BUCKET is required"))
   (or (env "TELEMACHUS_S3_BLOB_REGION") "us-east-1")
   (or (env "TELEMACHUS_S3_BLOB_PREFIX") "blobs")
   ;; The AWS_* names are accepted as a fallback because that is how most
   ;; deployments already inject credentials, and refusing to read them would
   ;; make an operator duplicate what their platform has set.
   (or (env "TELEMACHUS_S3_BLOB_ACCESS_KEY") (env "AWS_ACCESS_KEY_ID")
       (error 's3blobs "no access key: set TELEMACHUS_S3_BLOB_ACCESS_KEY or AWS_ACCESS_KEY_ID"))
   (or (env "TELEMACHUS_S3_BLOB_SECRET_KEY") (env "AWS_SECRET_ACCESS_KEY")
       (error 's3blobs "no secret key: set TELEMACHUS_S3_BLOB_SECRET_KEY or AWS_SECRET_ACCESS_KEY"))
   sse
   (env "TELEMACHUS_S3_BLOB_KMS_KEY_ID")
   ;; Defaults to ON whenever encryption was asked for. An operator who sets
   ;; sse=none has said they want plaintext, and asserting a header they
   ;; deliberately turned off would refuse every write.
   (env-bool "TELEMACHUS_S3_BLOB_REQUIRE_ENCRYPTION" (not (string=? sse "none")))
   ;; Path-style by DEFAULT, unlike the AWS SDKs: MinIO and Ceph RGW are the
   ;; deployments this exists for and neither gets virtual-host DNS for free,
   ;; while AWS still accepts path-style.
   (env-bool "TELEMACHUS_S3_BLOB_PATH_STYLE" #t)
   (env-int "TELEMACHUS_S3_BLOB_RETRIES" 3)
   (env-int "TELEMACHUS_S3_BLOB_TIMEOUT" 120)))

;; <prefix>/<org>/<digest>. The digest reached us through blobs.rkt's whitelist
;; (exactly 64 lowercase hex), which is what stands between a corrupt database row
;; and a crafted key; this does not re-validate it, it relies on that.
(define (s3-blob-key cfg ns digest)
  (string-join (list (s3-config-prefix cfg) ns digest) "/"))

;; ---- the four procedures --------------------------------------------------------
(define (s3-put! ns digest in size)
  (define cfg (s3-blob-config))
  ;; Idempotent by construction — the name is the content — so an existing blob
  ;; is already correct and re-writing it can only risk making it worse. The HEAD
  ;; costs one round trip and saves uploading bytes the bucket already holds,
  ;; which on a re-upload of the same document is the whole object.
  (unless (s3-head cfg (s3-blob-key cfg ns digest))
    (s3-put-stream cfg (s3-blob-key cfg ns digest) in size digest)))

(define (s3-get ns digest)
  (define cfg (s3-blob-config))
  (s3-get-stream cfg (s3-blob-key cfg ns digest)))

(define (s3-delete! ns digest)
  (define cfg (s3-blob-config))
  (s3-delete cfg (s3-blob-key cfg ns digest)))

(define (s3-stat ns digest)
  (define cfg (s3-blob-config))
  (s3-head cfg (s3-blob-key cfg ns digest)))

;; Registration does NOT read the configuration, so an instance with this plugin
;; present and TELEMACHUS_BLOB_STORE unset still boots with rs3 and needs no
;; bucket at all. A missing endpoint is an error at the first call, and the first
;; call is startup.rkt's probe — which is fatal, named, and before serving.
(define (init!)
  (register-blob-store! "s3"
    (hash 'put! s3-put! 'get s3-get 'delete! s3-delete! 'stat s3-stat)))
