#lang racket/base

;; SHA-256 / HMAC-SHA256 pinned to published vectors. We do not implement these —
;; libcrypto does — so these tests are not checking the algorithm. They are checking
;; that our FFI signatures, buffer sizes and chunking are right, which is the part we
;; actually wrote and the part that fails silently when it is wrong.

(require rackunit racket/port "../domain/authz/sha2.rkt")

;; ---- SHA-256: NIST FIPS 180-4 examples ---------------------------------------
(check-equal? (sha256-hex #"abc")
              "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
(check-equal? (sha256-hex #"")
              "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
(check-equal? (sha256-hex #"abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq")
              "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")

;; the empty digest is the one SigV4 puts in X-Amz-Content-SHA256 for a bodyless
;; request, so it is worth naming explicitly
(check-equal? (sha256-hex #"") (sha256-hex (bytes)))

;; ---- streaming must agree with one-shot, across the chunk boundary -----------
;; CHUNK is 256 KiB; these straddle it in both directions so an off-by-one in the
;; read loop cannot hide.
(for ([n (in-list (list 0 1 1023 (* 256 1024) (add1 (* 256 1024)) (* 700 1024)))])
  (define bs (make-bytes n 65))
  (define-values (hex size) (sha256-port-hex (open-input-bytes bs)))
  (check-equal? hex (sha256-hex bs) (format "streaming digest matches at ~a bytes" n))
  (check-equal? size n (format "streaming byte count at ~a bytes" n)))

;; non-uniform content, so a mistake that ignores buffer contents still fails
(let* ([bs (apply bytes-append (for/list ([i (in-range 3000)]) (bytes (modulo i 256))))]
       [_  (void)])
  (define-values (hex size) (sha256-port-hex (open-input-bytes bs)))
  (check-equal? hex (sha256-hex bs))
  (check-equal? size (bytes-length bs)))

;; a port that yields in small pieces (a socket, not a file) must digest identically
(let ()
  (define bs (make-bytes 5000 90))
  (define-values (pin pout) (make-pipe))
  (void (thread (lambda ()
                  (for ([i (in-range 0 5000 37)])
                    (write-bytes bs pout i (min 5000 (+ i 37))))
                  (close-output-port pout))))
  (define-values (hex size) (sha256-port-hex pin))
  (check-equal? hex (sha256-hex bs) "dribbled port digests the same")
  (check-equal? size 5000))

;; ---- HMAC-SHA256: RFC 4231 ---------------------------------------------------
(check-equal? (bytes->hex-lower (hmac-sha256 (make-bytes 20 11) #"Hi There"))
              "b0344c61d8db38535ca8afceaf0bf12b881dc200c9833da726e9376c2e32cff7"
              "RFC 4231 case 1")
(check-equal? (bytes->hex-lower (hmac-sha256 #"Jefe" #"what do ya want for nothing?"))
              "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843"
              "RFC 4231 case 2")
(check-equal? (bytes->hex-lower (hmac-sha256 (make-bytes 131 #xaa)
                                             #"Test Using Larger Than Block-Size Key - Hash Key First"))
              "60e431591ee0b67f0d8a26aacbf5b77f8e0bc6213728c5140546040f0ee37f54"
              "RFC 4231 case 6 — key longer than the block size")

;; the vector that catches a key/msg argument swap, which the types alone allow
(check-not-equal? (hmac-sha256 #"key" #"msg") (hmac-sha256 #"msg" #"key"))

(check-equal? (bytes-length (sha256 #"anything")) DIGEST-BYTES)
