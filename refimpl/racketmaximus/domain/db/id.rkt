#lang racket/base

;; domain/db/id.rkt — UUIDv4 primary keys + random tokens (decision DB-2).
;; UUIDs travel across sqlite/Postgres and survive federation/merge without
;; sequence divergence.

(require racket/random)

(provide uuid4 new-id random-token byte->hex)

(define (byte->hex b)
  (define s (number->string b 16))
  (if (= (string-length s) 1) (string-append "0" s) s))

(define (hex-bytes bs)
  (apply string-append (for/list ([b (in-bytes bs)]) (byte->hex b))))

;; RFC 4122 version-4 UUID from 16 crypto-random bytes.
(define (uuid4)
  (define b (bytes-copy (crypto-random-bytes 16)))
  (bytes-set! b 6 (bitwise-ior (bitwise-and (bytes-ref b 6) #x0f) #x40))   ; version 4
  (bytes-set! b 8 (bitwise-ior (bitwise-and (bytes-ref b 8) #x3f) #x80))   ; variant 10xx
  (define (hx s e) (hex-bytes (subbytes b s e)))
  (string-append (hx 0 4) "-" (hx 4 6) "-" (hx 6 8) "-" (hx 8 10) "-" (hx 10 16)))

(define new-id uuid4)

;; a high-entropy opaque token string, e.g. "tk_<48 hex>"
(define (random-token [nbytes 24])
  (string-append "tk_" (hex-bytes (crypto-random-bytes nbytes))))
