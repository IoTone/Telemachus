#lang racket/base

;; domain/authz/sha2.rkt — SHA-256 and HMAC-SHA256 over libcrypto's EVP interface.
;;
;; Deliberately NOT in crypto.rkt: that module's contract is "self-contained, no
;; native deps", built on the runtime's own `sha1-bytes`. minimal-racket ships no
;; SHA-2 at all, so this one takes the FFI — which is honest about what it needs
;; rather than quietly weakening crypto.rkt's promise.
;;
;; libcrypto resolves in `nix develop` and in the `nix build` closure alike (Racket's
;; own derivation carries openssl), and Nix is the toolchain. If it is ever missing,
;; every entry point here raises with a message that says so, rather than returning a
;; wrong digest.
;;
;; The incremental interface (sha256-port) is the one that matters: a document's
;; content address must be computable without holding the document in memory.
;;
;; Correctness is pinned to the NIST/RFC vectors in test/sha2-tests.rkt. An FFI
;; signature mistake shows up there immediately, which is the whole reason to keep
;; the vectors even though we are not implementing the algorithm ourselves.

(require ffi/unsafe ffi/unsafe/define openssl/libcrypto racket/port)

(provide sha256 sha256-hex sha256-port sha256-port-hex hmac-sha256
         bytes->hex-lower DIGEST-BYTES)

(define DIGEST-BYTES 32)
(define CHUNK (* 256 1024))

(define-ffi-definer defcrypto libcrypto #:default-make-fail make-not-available)

(defcrypto EVP_sha256        (_fun -> _pointer))
(defcrypto EVP_MD_CTX_new    (_fun -> _pointer))
(defcrypto EVP_MD_CTX_free   (_fun _pointer -> _void))
(defcrypto EVP_DigestInit_ex (_fun _pointer _pointer _pointer -> _int))
(defcrypto EVP_DigestUpdate  (_fun _pointer _bytes _size -> _int))
(defcrypto EVP_DigestFinal_ex(_fun _pointer _bytes (_ptr o _uint) -> _int))
(defcrypto HMAC              (_fun _pointer _bytes _int _bytes _size _bytes (_ptr o _uint) -> _pointer))

(define (need-libcrypto!)
  (unless libcrypto
    (error 'sha2 (string-append
                  "libcrypto is unavailable, so SHA-256 cannot be computed. "
                  "Run under `nix develop` or the nix-built package — see CLAUDE.md; "
                  "the linuxbrew toolchain is not supported."))))

;; A digest context is freed on every path, including an escaping exception: these
;; run per upload, and a leaked EVP_MD_CTX is a slow memory leak in a long-lived
;; server.
(define (call-with-digest proc)
  (need-libcrypto!)
  (define ctx (EVP_MD_CTX_new))
  (unless ctx (error 'sha2 "EVP_MD_CTX_new failed"))
  (dynamic-wind
    void
    (lambda ()
      (unless (= 1 (EVP_DigestInit_ex ctx (EVP_sha256) #f))
        (error 'sha2 "EVP_DigestInit_ex failed"))
      (proc (lambda (bs len) (EVP_DigestUpdate ctx bs len)))
      (define out (make-bytes DIGEST-BYTES))
      (unless (= 1 (EVP_DigestFinal_ex ctx out)) (error 'sha2 "EVP_DigestFinal_ex failed"))
      out)
    (lambda () (EVP_MD_CTX_free ctx))))

(define (sha256 bs)
  (call-with-digest (lambda (update!) (update! bs (bytes-length bs)))))

;; Digest a port without ever holding the whole stream. Returns (values digest size)
;; — the caller almost always wants the byte count too, and reading twice to get it
;; would defeat the point.
(define (sha256-port in)
  (define total 0)
  (define buf (make-bytes CHUNK))
  (define d
    (call-with-digest
     (lambda (update!)
       (let loop ()
         (define n (read-bytes-avail! buf in))
         (unless (eof-object? n)
           (set! total (+ total n))
           (update! (if (= n CHUNK) buf (subbytes buf 0 n)) n)
           (loop))))))
  (values d total))

(define HEX "0123456789abcdef")
(define (bytes->hex-lower bs)
  (define out (make-string (* 2 (bytes-length bs))))
  (for ([b (in-bytes bs)] [i (in-naturals)])
    (string-set! out (* 2 i)        (string-ref HEX (arithmetic-shift b -4)))
    (string-set! out (add1 (* 2 i)) (string-ref HEX (bitwise-and b #x0f))))
  out)

(define (sha256-hex bs) (bytes->hex-lower (sha256 bs)))
(define (sha256-port-hex in)
  (define-values (d n) (sha256-port in))
  (values (bytes->hex-lower d) n))

;; HMAC-SHA256 (RFC 4231). Needed by SigV4's signing-key derivation; kept here
;; because it is the same library and the same test file.
(define (hmac-sha256 key msg)
  (need-libcrypto!)
  (define out (make-bytes DIGEST-BYTES))
  (define r (HMAC (EVP_sha256) key (bytes-length key) msg (bytes-length msg) out))
  (unless r (error 'sha2 "HMAC failed"))
  out)
