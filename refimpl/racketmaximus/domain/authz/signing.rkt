#lang racket/base

;; domain/authz/signing.rkt — Ed25519 signatures over libcrypto's EVP interface,
;; for issue #66's anchor receipts (decision ANCHOR‑4).
;;
;; WHY ASYMMETRIC, when this codebase already has HMAC-SHA256 in sha2-kit. An
;; anchor receipt has to be evidence to somebody who is NOT the operator. With a
;; shared secret, a verifier who holds the key could have produced the receipt,
;; so it proves nothing to them — which is no better than keeping an unsigned
;; copy. Ed25519 lets the public key be published: verification does not confer
;; the ability to sign.
;;
;; A SIBLING OF sha2-kit, not an addition to it, and deliberately not in
;; crypto.rkt — that module's contract is "self-contained, no native deps", and
;; this needs the FFI. It lives under domain/authz beside secretbox.rkt (the
;; AES-GCM one) rather than in pkgs/ because, unlike SHA-256, nothing outside the
;; server has asked for it: pkgs/ is for a kit with callers of its own (#110 r4),
;; and an export with no caller is a claim rather than an API.
;;
;; THE KEY MUST BE 64 HEX, and a passphrase is REFUSED — unlike
;; `TELEMACHUS_SECRET_KEY`, which accepts one and stretches it. The difference is
;; who types it: a sealing key may reasonably be a human-chosen phrase an
;; operator can recite, while a signing key is machine-generated once by
;; `telemachus-anchor keygen` and then lives in a secret store. Stretching a
;; passphrase into an Ed25519 seed would make the instance's published IDENTITY
;; guessable at whatever rate the phrase allows, and a forged receipt is not
;; recoverable by rotating afterwards. So the refusal names the generator.
;;
;; Correctness is pinned to RFC 8032's own test vectors in test/signing-tests.rkt.
;; An FFI marshalling mistake is exactly the failure those vectors exist to
;; catch: writing this module, a probe agreed with a vector for its first 53
;; bytes and diverged after — which cannot happen for a deterministic signature
;; and meant the LITERAL had been recalled rather than read. Take a vector from a
;; source, never from memory.

(require ffi/unsafe ffi/unsafe/define openssl/libcrypto racket/random racket/string)

(provide anchor-key-seed anchor-signing-enabled?
         ed25519-public-key ed25519-sign ed25519-verify?
         ed25519-generate-seed bytes->hex hex->bytes
         SEED-BYTES PUBLIC-KEY-BYTES SIGNATURE-BYTES)

(define SEED-BYTES 32)
(define PUBLIC-KEY-BYTES 32)
(define SIGNATURE-BYTES 64)

;; EVP_PKEY_ED25519. A literal because the header's constant is not exported
;; through any symbol the FFI can read; it is pinned by the RFC 8032 vectors —
;; a wrong id fails to construct a key at all, loudly, rather than signing with
;; something else.
(define EVP_PKEY_ED25519 1087)

(define-ffi-definer defcrypto libcrypto #:default-make-fail make-not-available)

(defcrypto EVP_PKEY_new_raw_private_key (_fun _int _pointer _bytes _size -> _pointer))
(defcrypto EVP_PKEY_new_raw_public_key  (_fun _int _pointer _bytes _size -> _pointer))
(defcrypto EVP_PKEY_get_raw_public_key  (_fun _pointer _bytes (len : (_ptr io _size))
                                              -> (rc : _int) -> (values rc len)))
(defcrypto EVP_PKEY_free                (_fun _pointer -> _void))
(defcrypto EVP_MD_CTX_new               (_fun -> _pointer))
(defcrypto EVP_MD_CTX_free              (_fun _pointer -> _void))
(defcrypto EVP_DigestSignInit           (_fun _pointer _pointer _pointer _pointer _pointer -> _int))
(defcrypto EVP_DigestSign               (_fun _pointer _bytes (len : (_ptr io _size)) _bytes _size
                                              -> (rc : _int) -> (values rc len)))
(defcrypto EVP_DigestVerifyInit         (_fun _pointer _pointer _pointer _pointer _pointer -> _int))
(defcrypto EVP_DigestVerify             (_fun _pointer _bytes _size _bytes _size -> _int))

(define (need-libcrypto!)
  (unless libcrypto
    (error 'signing (string-append
                     "libcrypto is unavailable, so an anchor receipt cannot be signed. "
                     "Run under `nix develop` or the nix-built package — see CLAUDE.md."))))

(define (bytes->hex bs)
  (apply string-append
         (for/list ([b (in-bytes bs)]) (if (< b 16) (format "0~x" b) (format "~x" b)))))

(define (hex->bytes s)
  (define t (string-trim s))
  (unless (even? (string-length t)) (error 'signing "hex string has an odd length"))
  (list->bytes
   (for/list ([i (in-range 0 (string-length t) 2)])
     (or (string->number (substring t i (+ i 2)) 16)
         (error 'signing "not a hex string")))))

;; A private key or a public key, freed on every path including an escaping
;; exception — sha2-kit's rule, and these run on a timer in a long-lived server.
(define (call-with-pkey make proc)
  (need-libcrypto!)
  (define pkey (make))
  (unless pkey (error 'signing "EVP_PKEY construction failed (is this libcrypto built with Ed25519?)"))
  (dynamic-wind void (lambda () (proc pkey)) (lambda () (EVP_PKEY_free pkey))))

(define (call-with-md-ctx proc)
  (define ctx (EVP_MD_CTX_new))
  (unless ctx (error 'signing "EVP_MD_CTX_new failed"))
  (dynamic-wind void (lambda () (proc ctx)) (lambda () (EVP_MD_CTX_free ctx))))

(define (check-seed! seed)
  (unless (and (bytes? seed) (= SEED-BYTES (bytes-length seed)))
    (error 'signing "an Ed25519 seed is exactly ~a bytes" SEED-BYTES)))

(define (with-private seed proc)
  (check-seed! seed)
  (call-with-pkey (lambda () (EVP_PKEY_new_raw_private_key EVP_PKEY_ED25519 #f seed SEED-BYTES))
                  proc))

;; seed -> the 32-byte public key. Derived, never stored: a public key kept
;; beside the seed is a second copy that can disagree with it.
(define (ed25519-public-key seed)
  (with-private seed
    (lambda (pkey)
      (define out (make-bytes PUBLIC-KEY-BYTES))
      (define-values (rc len) (EVP_PKEY_get_raw_public_key pkey out PUBLIC-KEY-BYTES))
      (unless (and (= rc 1) (= len PUBLIC-KEY-BYTES))
        (error 'signing "EVP_PKEY_get_raw_public_key failed"))
      out)))

(define (ed25519-sign seed msg)
  (with-private seed
    (lambda (pkey)
      (call-with-md-ctx
       (lambda (ctx)
         (unless (= 1 (EVP_DigestSignInit ctx #f #f #f pkey))
           (error 'signing "EVP_DigestSignInit failed"))
         (define sig (make-bytes SIGNATURE-BYTES))
         (define-values (rc len) (EVP_DigestSign ctx sig SIGNATURE-BYTES msg (bytes-length msg)))
         (unless (and (= rc 1) (= len SIGNATURE-BYTES))
           (error 'signing "EVP_DigestSign failed"))
         sig)))))

;; -> #t / #f. A malformed key or signature answers #f rather than raising: this
;; is called on data from outside (a retained file somebody hands us), so a
;; wrong-length signature is an answer, not a crash.
(define (ed25519-verify? public-key msg sig)
  (cond
    [(not (and (bytes? public-key) (= PUBLIC-KEY-BYTES (bytes-length public-key)))) #f]
    [(not (and (bytes? sig) (= SIGNATURE-BYTES (bytes-length sig)))) #f]
    [else
     (with-handlers ([exn:fail? (lambda (_) #f)])
       (call-with-pkey
        (lambda () (EVP_PKEY_new_raw_public_key EVP_PKEY_ED25519 #f public-key PUBLIC-KEY-BYTES))
        (lambda (pkey)
          (call-with-md-ctx
           (lambda (ctx)
             (and (= 1 (EVP_DigestVerifyInit ctx #f #f #f pkey))
                  (= 1 (EVP_DigestVerify ctx sig SIGNATURE-BYTES msg (bytes-length msg)))))))))]))

(define (ed25519-generate-seed) (crypto-random-bytes SEED-BYTES))

;; ---- the configured key ------------------------------------------------------

(define (env k) (let ([v (getenv k)]) (and v (not (string=? (string-trim v) "")) (string-trim v))))

;; Memoized by the RAW value, not by the variable name — secretbox.rkt's rule and
;; its reason: a cache that remembered only "this variable was read" would pin
;; whatever was set first, which is wrong in a test that sets a key and wrong in
;; a process handed a rotated environment.
(define *seeds* (make-hash))

(define (anchor-key-seed)
  (define raw (env "TELEMACHUS_ANCHOR_KEY"))
  (and raw
       (hash-ref! *seeds* raw
                  (lambda ()
                    (unless (regexp-match? #px"^[0-9a-fA-F]{64}$" raw)
                      (error 'signing
                             (string-append
                              "TELEMACHUS_ANCHOR_KEY must be 64 hex characters (a 32-byte Ed25519 seed). "
                              "Unlike TELEMACHUS_SECRET_KEY it is NOT a passphrase: generate one with "
                              "`racket cli/telemachus-anchor.rkt keygen` and keep it in a secret store.")))
                    (hex->bytes raw)))))

(define (anchor-signing-enabled?) (and (anchor-key-seed) #t))
