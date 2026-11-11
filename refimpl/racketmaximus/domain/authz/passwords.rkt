#lang racket/base

;; #128 job 2: operator-facing variables are read through ONE accessor,
;; which tries TMACH_<name> and falls back to TELEMACHUS_<name>.
(require (only-in "../../config.rkt" tmach-env))

;; domain/authz/passwords.rkt — password hashing + TOTP, with a pluggable KDF.
;;
;; Backends (auto-selected, hashes are versioned so they interoperate):
;;   • argon2id      — via the optional `crypto` package. Used only when it is
;;     installed AND passes a self-test at load. IT IS NOT IN THE NIX CLOSURE,
;;     so on a supported install this branch is never taken; it is kept for a
;;     build that adds the collection. Hashes start "$argon2id$".
;;   • pbkdf2_sha256 — PBKDF2-HMAC-SHA256 through libcrypto, 600,000 rounds.
;;     What every supported install runs. Hashes start "pbkdf2_sha256$".
;;     TMACH_PBKDF2_ITERS raises the count.
;;   • pbkdf2_sha1   — the pure-Racket construction this module shipped with.
;;     Still VERIFIED, never written while libcrypto is present.
;;
;; verify-password dispatches by hash prefix, and `authenticate` re-hashes a row
;; `password-needs-rehash?` names, so a scheme change reaches existing accounts
;; at their owner's next sign-in. Force PBKDF2 with TMACH_KDF=pbkdf2.

(require racket/random
         racket/string
         racket/promise
         ffi/unsafe ffi/unsafe/define openssl/libcrypto
         "crypto.rkt")

(provide hash-password verify-password verify-absent-password kdf-name
         password-needs-rehash? pbkdf2-hmac-sha256 PBKDF2-SHA256-ITERS
         new-totp-secret totp-uri totp-valid?)

;; issue #117: a sign-in that fails because the ACCOUNT does not exist must cost
;; what one that fails on the password costs. `authenticate` used to return #f
;; before any hashing for an unknown username AND for a user whose
;; `password_hash` is NULL — `POST /api/orgs` without `owner_password` creates
;; exactly those — so both were distinguishable from a real account by timing.
;;
;; The dummy hash is minted from the LIVE KDF at first use, not baked in as a
;; literal: `kdf-name` and the iteration count are read at runtime, so a literal
;; would silently stop matching the real cost the first time an operator raised
;; TELEMACHUS_PBKDF2_ITERS. `delay` keeps the cost off module load, so a test
;; that never signs in does not pay for it.
;;
;; It always answers #f. Callers use it as the RESULT of the not-found branch, so
;; the branch cannot accidentally be written as a cheap #f again.
(define absent-hash
  (delay (hash-password (bytes->hex (crypto-random-bytes 16)))))
(define (verify-absent-password pw)
  (verify-password (if (string? pw) pw "") (force absent-hash))
  #f)

;; ---- PBKDF2-HMAC-SHA256 over libcrypto ---------------------------------------
;; What every supported install actually runs. The header of this module used to
;; promise argon2id "when available", and it never is: the `crypto` collection is
;; not in the Nix closure and Nix is the only toolchain, so every instance fell
;; through to PBKDF2-HMAC-SHA1 at 100,000 rounds — a thirteenth of what OWASP
;; asks of that construction (1,300,000). Raising the count on the pure-Racket
;; SHA-1 loop in crypto.rkt is not an option: 100,000 rounds already cost 250 ms
;; there, so 1.3 million is over three seconds a sign-in. libcrypto's own
;; PKCS5_PBKDF2_HMAC does 600,000 rounds of SHA-256 (OWASP's figure for THAT
;; construction) in about the time the old one took, and libcrypto is already a
;; hard dependency — the token hash, the sealed columns and the anchor all use it.
;;
;; Stored as `pbkdf2_sha256$<iters>$<salt hex>$<dk hex>`. The old
;; `pbkdf2_sha1$…` form still VERIFIES, so the upgrade locks nobody out, and
;; `password-needs-rehash?` is how `authenticate` moves a row forward the next
;; time its owner proves they know the password — the only moment the plaintext
;; is in hand.
(define-ffi-definer defcrypto libcrypto #:default-make-fail make-not-available)
(defcrypto EVP_sha256 (_fun -> _pointer))
(defcrypto PKCS5_PBKDF2_HMAC
  (_fun _bytes _int _bytes _int _int _pointer _int _bytes -> _int))

(define sha256-available?
  (delay (with-handlers ([(lambda (_) #t) (lambda (_) #f)])
           (and libcrypto (EVP_sha256) #t))))

(define (pbkdf2-hmac-sha256 password salt iters dklen)
  (define out (make-bytes dklen))
  (unless (= 1 (PKCS5_PBKDF2_HMAC password (bytes-length password)
                                  salt (bytes-length salt)
                                  iters (EVP_sha256) dklen out))
    (error 'passwords "PBKDF2-HMAC-SHA256 failed in libcrypto"))
  out)

;; OWASP's Password Storage Cheat Sheet figure for PBKDF2-HMAC-SHA256.
(define PBKDF2-SHA256-ITERS 600000)
;; A count below this is not honoured from the environment: the variable exists
;; to RAISE the cost, and a typo or a stale `100000` carried over from the SHA-1
;; days would otherwise quietly put an instance back where it was.
(define PBKDF2-SHA256-FLOOR 100000)
(define DEFAULT-ITERS
  (let* ([v (tmach-env "PBKDF2_ITERS")]
         [n (and v (string->number v))])
    (if (and n (exact-positive-integer? n))
        (max n PBKDF2-SHA256-FLOOR)
        PBKDF2-SHA256-ITERS)))
(define DKLEN 32)

(define (pbkdf2-hash pw iters)
  (define salt (crypto-random-bytes 16))
  (cond
    [(force sha256-available?)
     (define dk (pbkdf2-hmac-sha256 (string->bytes/utf-8 pw) salt iters DKLEN))
     (string-append "pbkdf2_sha256$" (number->string iters) "$" (bytes->hex salt) "$" (bytes->hex dk))]
    [else
     ;; no libcrypto: the pure-Racket construction, which is what there is.
     ;; `kdf-name` says so, and so does the boot line.
     (define dk (pbkdf2-hmac-sha1 (string->bytes/utf-8 pw) salt iters 20))
     (string-append "pbkdf2_sha1$" (number->string iters) "$" (bytes->hex salt) "$" (bytes->hex dk))]))

(define (ct-eq? a b)
  (and (= (bytes-length a) (bytes-length b))
       (zero? (for/fold ([acc 0]) ([x (in-bytes a)] [y (in-bytes b)]) (bitwise-ior acc (bitwise-xor x y))))))

(define (pbkdf2-verify pw stored #:prf [prf pbkdf2-hmac-sha1])
  (define parts (string-split stored "$"))
  (and (= (length parts) 4)
       (let ([iters (string->number (cadr parts))]
             [salt (hex->bytes (caddr parts))]
             [dk (hex->bytes (cadddr parts))])
         (and iters (exact-positive-integer? iters) (positive? (bytes-length dk))
              (ct-eq? (prf (string->bytes/utf-8 pw) salt iters (bytes-length dk)) dk)))))

;; ---- argon2id backend (optional `crypto` package), self-tested at load ------
;; Resolves to (list pwhash pwhash-verify factory) or #f. Catches everything —
;; missing package, API drift, native-lib absence — and only activates if a real
;; hash+verify round-trips, so it can never break the tested PBKDF2 path.
(define argon2-backend
  (delay
    (with-handlers ([(lambda (_) #t) (lambda (_) #f)])
      (define crypto-factories (dynamic-require 'crypto 'crypto-factories))
      (define libcrypto-factory (dynamic-require 'crypto/libcrypto 'libcrypto-factory))
      (define pwhash        (dynamic-require 'crypto 'pwhash))
      (define pwhash-verify (dynamic-require 'crypto 'pwhash-verify))
      (parameterize ([crypto-factories (list libcrypto-factory)])
        (define h (pwhash 'argon2id #"self-test" '((t 16) (m 4096) (p 1))))
        (and (string? h) (string-prefix? h "$argon2")
             (pwhash-verify #f #"self-test" h)
             (list pwhash pwhash-verify libcrypto-factory crypto-factories))))))

(define (argon2-disabled?) (equal? (tmach-env "KDF") "pbkdf2"))
(define (argon2-active?) (and (not (argon2-disabled?)) (force argon2-backend) #t))

(define (argon2-hash pw)
  (define b (force argon2-backend))
  (define pwhash (car b)) (define factories (cadddr b)) (define fac (caddr b))
  (parameterize ([factories (list fac)])
    (pwhash 'argon2id (string->bytes/utf-8 pw) '((t 256) (m 65536) (p 1)))))

(define (argon2-verify pw stored)
  (define b (force argon2-backend))
  (and b (let ([pwhash-verify (cadr b)] [fac (caddr b)] [factories (cadddr b)])
           (parameterize ([factories (list fac)])
             (with-handlers ([(lambda (_) #t) (lambda (_) #f)])
               (and (pwhash-verify #f (string->bytes/utf-8 pw) stored) #t))))))

;; ---- public API -------------------------------------------------------------
(define (kdf-name)
  (cond [(argon2-active?) "argon2id"]
        [(force sha256-available?) "pbkdf2_sha256"]
        [else "pbkdf2_sha1"]))

(define (hash-password pw #:iters [iters DEFAULT-ITERS])
  (if (argon2-active?) (argon2-hash pw) (pbkdf2-hash pw iters)))

(define (verify-password pw stored)
  (cond
    [(string-prefix? stored "$argon2")       (and (argon2-active?) (argon2-verify pw stored))]
    [(string-prefix? stored "pbkdf2_sha256$")
     (and (force sha256-available?) (pbkdf2-verify pw stored #:prf pbkdf2-hmac-sha256))]
    [(string-prefix? stored "pbkdf2_sha1$")  (pbkdf2-verify pw stored)]
    [else #f]))

;; Would `hash-password` store this password differently today? Asked by
;; `authenticate` straight after a successful verify, which is the only time the
;; plaintext exists to hash again. True for the SHA-1 form, and for a SHA-256
;; row made at a lower count than this instance now asks for — so raising
;; TMACH_PBKDF2_ITERS reaches existing accounts too, one sign-in at a time.
;; Never true in the other direction: a row stronger than today's setting is
;; left alone.
(define (password-needs-rehash? stored)
  (cond
    [(not (string? stored)) #f]
    [(argon2-active?) (not (string-prefix? stored "$argon2"))]
    [(not (force sha256-available?)) #f]
    [(string-prefix? stored "pbkdf2_sha1$") #t]
    [(string-prefix? stored "pbkdf2_sha256$")
     (let* ([parts (string-split stored "$")]
            [n (and (= (length parts) 4) (string->number (cadr parts)))])
       (and n (< n DEFAULT-ITERS)))]
    [else #f]))

;; ---- TOTP (2FA) -------------------------------------------------------------
(define (new-totp-secret [nbytes 20]) (base32-encode (crypto-random-bytes nbytes)))

(define (totp-uri secret #:issuer [issuer "Telemachus"] #:account [account "user"])
  (string-append "otpauth://totp/" issuer ":" account "?secret=" secret "&issuer=" issuer))

(define (totp-valid? b32secret code #:now [now (current-seconds)])
  (define secret (base32-decode b32secret))
  (for/or ([w (in-list '(-1 0 1))])
    (string=? (totp secret (+ now (* w 30)) 30 6) code)))
