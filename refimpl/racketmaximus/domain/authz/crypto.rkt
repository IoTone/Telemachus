#lang racket/base

;; domain/authz/crypto.rkt — self-contained HMAC-SHA1, PBKDF2, and TOTP built on
;; the runtime's `sha1-bytes` (no external native deps). This is the password/2FA
;; primitive layer.
;;
;; NOTE: PBKDF2-HMAC-SHA1 is a real, standard KDF (RFC 2898/6070). For production
;; prefer argon2id/scrypt via a native crypto lib — this module is the seam where
;; that swaps in. Correctness here is pinned by RFC test vectors in the tests.

(require file/sha1)                       ; sha1-bytes, bytes->hex-string, hex-string->bytes

(provide hmac-sha1 pbkdf2-hmac-sha1
         hotp totp base32-decode base32-encode
         bytes->hex hex->bytes)

(define (bytes->hex bs) (bytes->hex-string bs))
(define (hex->bytes s) (hex-string->bytes s))
(define (sha1* bs) (sha1-bytes (open-input-bytes bs)))

;; ---- HMAC-SHA1 (RFC 2104) ---------------------------------------------------
(define BLOCK 64)
(define (hmac-sha1 key msg)
  (define k0 (let ([k (if (> (bytes-length key) BLOCK) (sha1* key) key)])
               (bytes-append k (make-bytes (- BLOCK (bytes-length k)) 0))))
  (define (xor-pad pad) (list->bytes (for/list ([b (in-bytes k0)]) (bitwise-xor b pad))))
  (sha1* (bytes-append (xor-pad #x5c) (sha1* (bytes-append (xor-pad #x36) msg)))))

;; ---- PBKDF2-HMAC-SHA1 (RFC 2898) -------------------------------------------
(define HLEN 20)
(define (int32be i) (bytes (bitwise-and (arithmetic-shift i -24) #xff)
                           (bitwise-and (arithmetic-shift i -16) #xff)
                           (bitwise-and (arithmetic-shift i -8) #xff)
                           (bitwise-and i #xff)))
(define (xor-bytes a b) (list->bytes (for/list ([x (in-bytes a)] [y (in-bytes b)]) (bitwise-xor x y))))

(define (pbkdf2-hmac-sha1 password salt iters dklen)
  (define (F i)
    (let loop ([u (hmac-sha1 password (bytes-append salt (int32be i)))] [acc #f] [n iters])
      (define acc* (if acc (xor-bytes acc u) u))
      (if (= n 1) acc* (loop (hmac-sha1 password u) acc* (sub1 n)))))
  (define blocks (quotient (+ dklen HLEN -1) HLEN))
  (subbytes (apply bytes-append (for/list ([i (in-range 1 (add1 blocks))]) (F i))) 0 dklen))

;; ---- HOTP / TOTP (RFC 4226 / 6238) -----------------------------------------
(define (int64be n)
  (list->bytes (for/list ([shift (in-list '(56 48 40 32 24 16 8 0))])
                 (bitwise-and (arithmetic-shift n (- shift)) #xff))))

(define (hotp secret counter [digits 6])
  (define h (hmac-sha1 secret (int64be counter)))
  (define off (bitwise-and (bytes-ref h 19) #x0f))
  (define bin (bitwise-and (+ (arithmetic-shift (bytes-ref h off) 24)
                              (arithmetic-shift (bytes-ref h (+ off 1)) 16)
                              (arithmetic-shift (bytes-ref h (+ off 2)) 8)
                              (bytes-ref h (+ off 3)))
                           #x7fffffff))
  (define code (modulo bin (expt 10 digits)))
  (define s (number->string code))
  (string-append (make-string (max 0 (- digits (string-length s))) #\0) s))

(define (totp secret unix-time [step 30] [digits 6])
  (hotp secret (quotient unix-time step) digits))

;; ---- base32 (RFC 4648, no padding needed) for otpauth secrets ---------------
(define B32 "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
(define (base32-decode s)
  (define clean (list->string (for/list ([c (in-string (string-upcase s))] #:when (not (char=? c #\=))) c)))
  (define bits (for/fold ([acc 0] [n 0] #:result (list acc n)) ([c (in-string clean)])
                 (values (+ (arithmetic-shift acc 5) (or (find-index c) 0)) (+ n 5))))
  (define total (cadr bits))
  (define value (car bits))
  (define nbytes (quotient total 8))
  (define drop (- total (* nbytes 8)))
  (define v (arithmetic-shift value (- drop)))
  (list->bytes (reverse (for/list ([i (in-range nbytes)]) (bitwise-and (arithmetic-shift v (- (* i 8))) #xff)))))

(define (find-index c)
  (for/or ([i (in-naturals)] [ch (in-string B32)]) (and (char=? ch c) i)))

(define (base32-encode bs)
  (define out (open-output-string))
  (let loop ([acc 0] [bits 0] [xs (bytes->list bs)])
    (cond
      [(>= bits 5)
       (define shift (- bits 5))
       (write-char (string-ref B32 (bitwise-and (arithmetic-shift acc (- shift)) #x1f)) out)
       (loop (bitwise-and acc (sub1 (arithmetic-shift 1 shift))) shift xs)]
      [(pair? xs) (loop (+ (arithmetic-shift acc 8) (car xs)) (+ bits 8) (cdr xs))]
      [(> bits 0)
       (write-char (string-ref B32 (bitwise-and (arithmetic-shift acc (- 5 bits)) #x1f)) out)
       (get-output-string out)]
      [else (get-output-string out)])))
