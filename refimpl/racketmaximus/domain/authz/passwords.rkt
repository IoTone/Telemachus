#lang racket/base

;; #128 job 2: operator-facing variables are read through ONE accessor,
;; which tries TMACH_<name> and falls back to TELEMACHUS_<name>.
(require (only-in "../../config.rkt" tmach-env))

;; domain/authz/passwords.rkt — password hashing + TOTP, with a pluggable KDF.
;;
;; Backends (auto-selected, hashes are versioned so they interoperate):
;;   • argon2id  — via the optional `crypto` package (native libcrypto). Preferred
;;     when installed AND it passes a self-test at load. Hashes start "$argon2id$".
;;   • pbkdf2    — PBKDF2-HMAC-SHA1, self-contained fallback. Hashes start
;;     "pbkdf2_sha1$". Iterations via TELEMACHUS_PBKDF2_ITERS (default 100000).
;;
;; verify-password dispatches by hash prefix, so a deployment that later installs
;; `crypto` keeps verifying old PBKDF2 hashes while minting new argon2id ones.
;; Force PBKDF2 with TELEMACHUS_KDF=pbkdf2.

(require racket/random
         racket/string
         racket/promise
         "crypto.rkt")

(provide hash-password verify-password verify-absent-password kdf-name
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

(define DEFAULT-ITERS
  (or (let ([v (tmach-env "PBKDF2_ITERS")]) (and v (string->number v))) 100000))
(define DKLEN 20)

;; ---- PBKDF2-HMAC-SHA1 backend ----------------------------------------------
(define (pbkdf2-hash pw iters)
  (define salt (crypto-random-bytes 16))
  (define dk (pbkdf2-hmac-sha1 (string->bytes/utf-8 pw) salt iters DKLEN))
  (string-append "pbkdf2_sha1$" (number->string iters) "$" (bytes->hex salt) "$" (bytes->hex dk)))

(define (ct-eq? a b)
  (and (= (bytes-length a) (bytes-length b))
       (zero? (for/fold ([acc 0]) ([x (in-bytes a)] [y (in-bytes b)]) (bitwise-ior acc (bitwise-xor x y))))))

(define (pbkdf2-verify pw stored)
  (define parts (string-split stored "$"))
  (and (= (length parts) 4)
       (let ([iters (string->number (cadr parts))]
             [salt (hex->bytes (caddr parts))]
             [dk (hex->bytes (cadddr parts))])
         (and iters (ct-eq? (pbkdf2-hmac-sha1 (string->bytes/utf-8 pw) salt iters (bytes-length dk)) dk)))))

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
(define (kdf-name) (if (argon2-active?) "argon2id" "pbkdf2_sha1"))

(define (hash-password pw #:iters [iters DEFAULT-ITERS])
  (if (argon2-active?) (argon2-hash pw) (pbkdf2-hash pw iters)))

(define (verify-password pw stored)
  (cond
    [(string-prefix? stored "$argon2")       (and (argon2-active?) (argon2-verify pw stored))]
    [(string-prefix? stored "pbkdf2_sha1$")  (pbkdf2-verify pw stored)]
    [else #f]))

;; ---- TOTP (2FA) -------------------------------------------------------------
(define (new-totp-secret [nbytes 20]) (base32-encode (crypto-random-bytes nbytes)))

(define (totp-uri secret #:issuer [issuer "Telemachus"] #:account [account "user"])
  (string-append "otpauth://totp/" issuer ":" account "?secret=" secret "&issuer=" issuer))

(define (totp-valid? b32secret code #:now [now (current-seconds)])
  (define secret (base32-decode b32secret))
  (for/or ([w (in-list '(-1 0 1))])
    (string=? (totp secret (+ now (* w 30)) 30 6) code)))
