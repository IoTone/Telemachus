#lang racket/base

;; domain/authz/passwords.rkt — password hashing + verification + TOTP checks.
;; Format: "pbkdf2_sha1$<iters>$<salt-hex>$<dk-hex>". The KDF is the swappable
;; seam (argon2id in production); see crypto.rkt.

(require racket/random
         racket/string
         "crypto.rkt")

(provide hash-password verify-password DEFAULT-ITERS
         new-totp-secret totp-uri totp-valid?)

(define DEFAULT-ITERS 50000)
(define DKLEN 20)

(define (hash-password pw #:iters [iters DEFAULT-ITERS])
  (define salt (crypto-random-bytes 16))
  (define dk (pbkdf2-hmac-sha1 (string->bytes/utf-8 pw) salt iters DKLEN))
  (string-append "pbkdf2_sha1$" (number->string iters) "$" (bytes->hex salt) "$" (bytes->hex dk)))

;; constant-time-ish byte compare
(define (ct-eq? a b)
  (and (= (bytes-length a) (bytes-length b))
       (zero? (for/fold ([acc 0]) ([x (in-bytes a)] [y (in-bytes b)]) (bitwise-ior acc (bitwise-xor x y))))))

(define (verify-password pw stored)
  (define parts (string-split stored "$"))
  (and (= (length parts) 4)
       (string=? (car parts) "pbkdf2_sha1")
       (let ([iters (string->number (cadr parts))]
             [salt (hex->bytes (caddr parts))]
             [dk (hex->bytes (cadddr parts))])
         (and iters
              (ct-eq? (pbkdf2-hmac-sha1 (string->bytes/utf-8 pw) salt iters (bytes-length dk)) dk)))))

;; ---- TOTP (2FA) -------------------------------------------------------------
(define (new-totp-secret [nbytes 20])
  (base32-encode (crypto-random-bytes nbytes)))

(define (totp-uri secret #:issuer [issuer "Telemachus"] #:account [account "user"])
  (string-append "otpauth://totp/" issuer ":" account "?secret=" secret "&issuer=" issuer))

;; accept the current 30s window ±1 for clock skew
(define (totp-valid? b32secret code #:now [now (current-seconds)])
  (define secret (base32-decode b32secret))
  (for/or ([w (in-list '(-1 0 1))])
    (string=? (totp secret (+ now (* w 30)) 30 6) code)))
