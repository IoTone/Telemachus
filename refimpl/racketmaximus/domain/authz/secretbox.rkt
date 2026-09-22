#lang racket/base

;; domain/authz/secretbox.rkt — AES-256-GCM at rest for the secrets that cannot be
;; hashed (issue #19).
;;
;; WHAT THIS DEFENDS, EXACTLY. Passwords and API tokens are stored as hashes, so a
;; database dump reveals nothing usable. Three secrets cannot be: the two-factor
;; seed (TOTP is computed FROM it), the S3 credential secret (SigV4 is an HMAC
;; keyed by it, and an HMAC cannot be checked against a hash), and a push
;; executor's key. Those three used to sit in the clear, which made ONE dump —
;; a backup file, a replica, a `pg_dump` pasted into a ticket, a snapshot of the
;; database volume — enough to replay every one of them.
;;
;; The key lives in the environment (`TELEMACHUS_SECRET_KEY`), never in the
;; database. So this raises the bar for a DUMP and does nothing for a HOST: an
;; attacker who owns the process reads the key from its environment. That is a
;; narrow claim, and it is deliberately the whole claim — the threat in the issue
;; is a dump, and a dump is the thing that travels. Nothing here should be read as
;; protecting against someone who is already on the box.
;;
;; NOT DERIVED FROM `TELEMACHUS_SECRET`. The token pepper is rotatable on purpose
;; — rotating it signs everyone out, which is a fine emergency action. If the
;; secret key were the same value, that same action would render every stored
;; secret undecryptable. They are separate variables so the emergency actions stay
;; separate.
;;
;; STORAGE. A wrapped value is `enc:v1:<key-id>:<nonce b64>:<ciphertext+tag b64>`;
;; anything without that prefix is plaintext and is returned as-is, so an upgrade
;; needs no migration and rows encrypt themselves as they are rewritten (the
;; `telemachus-secrets rewrap` CLI does the rest). With no key configured, wrapping
;; is the identity — that is the "the database is trusted" position, still
;; available, but now chosen rather than merely inherited.
;;
;; BOUND TO ITS ROW. Every value is sealed with its column and row id as the
;; additional authenticated data, so a ciphertext lifted out of one row and pasted
;; into another fails to open. Without that, an attacker with WRITE access to the
;; database could move a known secret onto another principal's row.
;;
;; Correctness is pinned to the NIST GCM vectors in test/secretbox-tests.rkt, for
;; the same reason sha2.rkt pins its digests: we are not implementing the
;; algorithm, we are getting an FFI signature right, and a vector says so
;; immediately.

(require ffi/unsafe ffi/unsafe/define openssl/libcrypto
         racket/string racket/random net/base64
         (only-in file/sha1 bytes->hex-string)
         (only-in "crypto.rkt" pbkdf2-hmac-sha1)
         (only-in sha2-kit sha256))

(provide aes-256-gcm-encrypt aes-256-gcm-decrypt
         secrets-enabled? secret-key-id secret-wrap secret-unwrap wrapped-secret?
         current-secret-key current-previous-secret-key parse-secret-key
         KEY-BYTES NONCE-BYTES TAG-BYTES)

(define KEY-BYTES 32)
(define NONCE-BYTES 12)          ; GCM's standard IV length — no EVP_CTRL_GCM_SET_IVLEN needed
(define TAG-BYTES 16)
(define EVP_CTRL_GCM_GET_TAG #x10)
(define EVP_CTRL_GCM_SET_TAG #x11)

(define-ffi-definer defcrypto libcrypto #:default-make-fail make-not-available)

(defcrypto EVP_aes_256_gcm        (_fun -> _pointer))
(defcrypto EVP_CIPHER_CTX_new     (_fun -> _pointer))
(defcrypto EVP_CIPHER_CTX_free    (_fun _pointer -> _void))
(defcrypto EVP_CIPHER_CTX_ctrl    (_fun _pointer _int _int _pointer -> _int))
(defcrypto EVP_EncryptInit_ex     (_fun _pointer _pointer _pointer _pointer _pointer -> _int))
;; The `int *outl` out-parameters are passed as an explicit buffer rather than as
;; `(_ptr o _int)`: the wrapper's multiple-value convention is easy to get subtly
;; wrong, and this is a place where "subtly wrong" means a truncated ciphertext.
(defcrypto EVP_EncryptUpdate      (_fun _pointer _pointer _pointer _pointer _int -> _int))
(defcrypto EVP_EncryptFinal_ex    (_fun _pointer _pointer _pointer -> _int))
(defcrypto EVP_DecryptInit_ex     (_fun _pointer _pointer _pointer _pointer _pointer -> _int))
(defcrypto EVP_DecryptUpdate      (_fun _pointer _pointer _pointer _pointer _int -> _int))
(defcrypto EVP_DecryptFinal_ex    (_fun _pointer _pointer _pointer -> _int))

(define (int-out) (malloc _int 'atomic))
(define (int-of p) (ptr-ref p _int))

(define (need-libcrypto!)
  (unless libcrypto
    (error 'secretbox (string-append
                       "libcrypto is unavailable, so stored secrets cannot be encrypted or read. "
                       "Run under `nix develop` or the nix-built package — see CLAUDE.md."))))

;; A cipher context is freed on every path, including an escaping exception —
;; these run per sign-in and per signed S3 request.
(define (call-with-cipher proc)
  (need-libcrypto!)
  (define ctx (EVP_CIPHER_CTX_new))
  (unless ctx (error 'secretbox "EVP_CIPHER_CTX_new failed"))
  (dynamic-wind void (lambda () (proc ctx)) (lambda () (EVP_CIPHER_CTX_free ctx))))

(define (check! r who) (unless (= r 1) (error 'secretbox "~a failed" who)))
(define (check-key! key)
  (unless (and (bytes? key) (= (bytes-length key) KEY-BYTES))
    (error 'secretbox "the key must be ~a bytes" KEY-BYTES)))

;; key × nonce × aad × plaintext -> ciphertext||tag
(define (aes-256-gcm-encrypt key nonce aad pt)
  (check-key! key)
  (unless (= (bytes-length nonce) NONCE-BYTES) (error 'secretbox "the nonce must be ~a bytes" NONCE-BYTES))
  (call-with-cipher
   (lambda (ctx)
     (define outl (int-out))
     (check! (EVP_EncryptInit_ex ctx (EVP_aes_256_gcm) #f key nonce) "EVP_EncryptInit_ex")
     (unless (zero? (bytes-length aad))
       (check! (EVP_EncryptUpdate ctx #f outl aad (bytes-length aad)) "EVP_EncryptUpdate (aad)"))
     (define out (make-bytes (max 1 (bytes-length pt))))
     (check! (EVP_EncryptUpdate ctx out outl pt (bytes-length pt)) "EVP_EncryptUpdate")
     (define n (int-of outl))
     (check! (EVP_EncryptFinal_ex ctx out outl) "EVP_EncryptFinal_ex")   ; GCM streams: 0 more bytes
     (define tag (make-bytes TAG-BYTES))
     (check! (EVP_CIPHER_CTX_ctrl ctx EVP_CTRL_GCM_GET_TAG TAG-BYTES tag) "EVP_CIPHER_CTX_ctrl (get tag)")
     (bytes-append (subbytes out 0 n) tag))))

;; key × nonce × aad × ciphertext||tag -> plaintext, or #f when it does not
;; authenticate (wrong key, wrong context, or tampered bytes — indistinguishable,
;; which is the point of an AEAD).
(define (aes-256-gcm-decrypt key nonce aad ct+tag)
  (check-key! key)
  (cond
    [(< (bytes-length ct+tag) TAG-BYTES) #f]
    [else
     (define n (- (bytes-length ct+tag) TAG-BYTES))
     (define ct (subbytes ct+tag 0 n))
     (define tag (subbytes ct+tag n))
     (call-with-cipher
      (lambda (ctx)
        (define outl (int-out))
        (check! (EVP_DecryptInit_ex ctx (EVP_aes_256_gcm) #f key nonce) "EVP_DecryptInit_ex")
        (unless (zero? (bytes-length aad))
          (check! (EVP_DecryptUpdate ctx #f outl aad (bytes-length aad)) "EVP_DecryptUpdate (aad)"))
        (define out (make-bytes (max 1 n)))
        (check! (EVP_DecryptUpdate ctx out outl ct n) "EVP_DecryptUpdate")
        (define outn (int-of outl))
        (check! (EVP_CIPHER_CTX_ctrl ctx EVP_CTRL_GCM_SET_TAG TAG-BYTES tag) "EVP_CIPHER_CTX_ctrl (set tag)")
        ;; the ONLY place authentication is decided: a bad tag, a wrong key or a
        ;; ciphertext moved between rows all land here as 0
        (and (= (EVP_DecryptFinal_ex ctx out outl) 1) (subbytes out 0 outn))))]))

;; ---- the configured key ------------------------------------------------------

;; 64 hex characters are the key itself; anything else is a passphrase, stretched.
;; Operators reach for a passphrase, and silently truncating one to 32 bytes would
;; hand them a key with far less entropy than it looks like it has.
(define KDF-SALT #"telemachus.secretbox.v1")
(define KDF-ITERS 200000)
(define (parse-secret-key s)
  (cond
    [(or (not s) (string=? (string-trim s) "")) #f]
    [(regexp-match? #px"^[0-9a-fA-F]{64}$" (string-trim s))
     (let ([h (string-trim s)])
       (list->bytes (for/list ([i (in-range 0 64 2)])
                      (string->number (substring h i (+ i 2)) 16))))]
    [else (pbkdf2-hmac-sha1 (string->bytes/utf-8 s) KDF-SALT KDF-ITERS KEY-BYTES)]))

(define (env k) (let ([v (getenv k)]) (and v (not (string=? v "")) v)))
;; Stretching a passphrase costs ~200k HMACs, so the parsed key is memoized — it is
;; read on every sign-in and every signed S3 request. Keyed by the RAW value, not
;; by the variable name: a cache that only remembered "this variable was read" would
;; pin whatever was set the first time, which is wrong in a test that sets a key,
;; and wrong in a process that is handed a rotated environment.
(define *keys* (make-hash))
(define (key-for var)
  (define raw (env var))
  (hash-ref! *keys* (cons var raw) (lambda () (parse-secret-key raw))))
(define (current-secret-key) (key-for "TELEMACHUS_SECRET_KEY"))
;; the previous key, during a rotation: read with either, write with the current
(define (current-previous-secret-key) (key-for "TELEMACHUS_SECRET_KEY_OLD"))

(define (secrets-enabled?) (and (current-secret-key) #t))

;; Which key sealed a value: the first 8 hex of its SHA-256. It is a label, not a
;; secret — it says which key to try, so a rotation can read both.
(define (key-id k) (substring (bytes->hex-string (sha256 k)) 0 8))
(define (secret-key-id) (let ([k (current-secret-key)]) (and k (key-id k))))

;; ---- the stored form ---------------------------------------------------------

(define PREFIX "enc:v1:")
(define (wrapped-secret? s) (and (string? s) (string-prefix? s PREFIX)))
(define (b64 bs) (string-trim (bytes->string/utf-8 (base64-encode bs #""))))
(define (unb64 s) (base64-decode (string->bytes/utf-8 s)))

;; A context string binds the ciphertext to where it lives: "<table>.<column>:<id>".
(define (aad-for context) (string->bytes/utf-8 context))

;; plaintext -> the string to store. Identity when no key is configured.
(define (secret-wrap context plain)
  (define k (current-secret-key))
  (cond
    [(not k) plain]
    [(not (string? plain)) plain]
    [else
     (define nonce (crypto-random-bytes NONCE-BYTES))
     (define ct (aes-256-gcm-encrypt k nonce (aad-for context) (string->bytes/utf-8 plain)))
     (string-append PREFIX (key-id k) ":" (b64 nonce) ":" (b64 ct))]))

;; stored -> plaintext. A value that was never wrapped is returned unchanged, so a
;; database written before the key existed keeps working. A wrapped value that
;; will not open RAISES: a wrong key must look like a broken configuration, never
;; like an empty secret — an empty TOTP seed would silently disable someone's
;; second factor.
(define (secret-unwrap context stored)
  (cond
    [(not (wrapped-secret? stored)) stored]
    [else
     (define parts (string-split (substring stored (string-length PREFIX)) ":"))
     (unless (= (length parts) 3) (error 'secretbox "a stored secret is malformed"))
     (define kid (car parts))
     (define nonce (unb64 (cadr parts)))
     (define ct (unb64 (caddr parts)))
     (define candidates
       (for/list ([k (in-list (list (current-secret-key) (current-previous-secret-key)))]
                  #:when (and k (equal? (key-id k) kid)))
         k))
     (when (null? candidates)
       (error 'secretbox
              (string-append "no configured key matches this stored secret (sealed by key " kid "). "
                             "Set TELEMACHUS_SECRET_KEY to it, or TELEMACHUS_SECRET_KEY_OLD while rotating.")))
     (define pt (for/or ([k (in-list candidates)]) (aes-256-gcm-decrypt k nonce (aad-for context) ct)))
     (unless pt
       (error 'secretbox
              (string-append "a stored secret did not authenticate for " context
                             " — the key is wrong, or the row has been tampered with")))
     (bytes->string/utf-8 pt)]))
