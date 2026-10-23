#lang racket/base

;; test/signing-tests.rkt — Ed25519, pinned to RFC 8032's own test vectors
;; (issue #66, ANCHOR-4).
;;
;; WHY THE VECTORS ARE HERE AT ALL, when we are not implementing the algorithm:
;; an FFI signature mistake produces a plausible wrong answer, and this is the
;; seam that decides whether an anchor receipt can be trusted by somebody who is
;; not the operator. sigv4.rkt and sha2-kit are pinned for the same reason.
;;
;; THESE LITERALS WERE TAKEN FROM AN ORACLE, NOT FROM MEMORY, and the reason is
;; a mistake made while writing this module: a first probe agreed with a recalled
;; "test 1" signature for its first 53 bytes and diverged after. That cannot
;; happen for a deterministic signature over the same key and message — so the
;; FFI was right and the RECOLLECTION was wrong. These two are RFC 8032 tests 2
;; and 3, reproduced with the `openssl` CLI in this same closure:
;;
;;   printf '302e020100300506032b657004220420<seed>' | xxd -r -p > k.der
;;   openssl pkey -inform DER -in k.der -out k.pem
;;   openssl pkey -in k.pem -pubout -outform DER | tail -c 32 | xxd -p
;;   printf '<msg>' | xxd -r -p > m; openssl pkeyutl -sign -inkey k.pem -rawin -in m | xxd -p
;;
;; RFC 8032's test 1 signs the EMPTY message and is deliberately not pinned:
;; `openssl pkeyutl` refuses a zero-length input buffer, so there is no oracle
;; for it here, and a literal nobody can reproduce is the thing this comment
;; exists to warn about. The empty message is covered by a round-trip property
;; instead.

(require rackunit racket/string
         (only-in "../domain/authz/signing.rkt"
                  ed25519-public-key ed25519-sign ed25519-verify?
                  ed25519-generate-seed bytes->hex hex->bytes
                  anchor-key-seed anchor-signing-enabled?
                  SEED-BYTES PUBLIC-KEY-BYTES SIGNATURE-BYTES))

(define (H s) (hex->bytes s))

;; ---- 1. RFC 8032 test 2 ------------------------------------------------------
(define sk2 "4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb")
(define pk2 "3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c")
(define msg2 (bytes #x72))
(define sig2 (string-append "92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da"
                            "085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00"))

(check-equal? (bytes->hex (ed25519-public-key (H sk2))) pk2
              "the public key is DERIVED from the seed, and matches RFC 8032 test 2")
(check-equal? (bytes->hex (ed25519-sign (H sk2) msg2)) sig2
              "RFC 8032 test 2's signature, byte for byte")

;; ---- 2. RFC 8032 test 3 ------------------------------------------------------
;; A second vector, because one can agree by luck in its early bytes — which is
;; exactly how the recollection above failed.
(define sk3 "c5aa8df43f9f837bedb7442f31dcb7b166d38535076f094b85ce3a2e0b4458f7")
(define pk3 "fc51cd8e6218a1a38da47ed00230f0580816ed13ba3303ac5deb911548908025")
(define msg3 (bytes #xaf #x82))
(define sig3 (string-append "6291d657deec24024827e69c3abe01a30ce548a284743a445e3680d7db5ac3ac"
                            "18ff9b538d16f290ae67f760984dc6594a7c15e9716ed28dc027beceea1ec40a"))

(check-equal? (bytes->hex (ed25519-public-key (H sk3))) pk3)
(check-equal? (bytes->hex (ed25519-sign (H sk3) msg3)) sig3)

;; ---- 3. verification, and what a tampered message does ------------------------
(check-true  (ed25519-verify? (H pk2) msg2 (H sig2)))
(check-true  (ed25519-verify? (H pk3) msg3 (H sig3)))
(check-false (ed25519-verify? (H pk2) (bytes #x73) (H sig2))
             "one bit of the message and the signature no longer checks")
(check-false (ed25519-verify? (H pk3) msg2 (H sig2))
             "a signature does not check against another key")
;; the signature itself flipped in its LAST byte — the half that a truncated or
;; mis-marshalled buffer would corrupt, which is the failure the vectors caught
(check-false (ed25519-verify? (H pk2) msg2
                              (H (string-append (substring sig2 0 126) "ff"))))

;; ---- 4. malformed input ANSWERS, it does not raise ----------------------------
;; `ed25519-verify?` is called on data from outside — a file somebody hands us —
;; so a wrong-length key or signature is an answer, not a crash.
(check-false (ed25519-verify? #"short" msg2 (H sig2)))
(check-false (ed25519-verify? (H pk2) msg2 #"short"))
(check-false (ed25519-verify? "not bytes" msg2 (H sig2)))
(check-false (ed25519-verify? (H pk2) msg2 'nonsense))

;; ---- 5. the empty message round-trips ----------------------------------------
;; Not pinned to a literal (see the header): proved as a property instead.
(let* ([seed (H sk2)] [sig (ed25519-sign seed #"")])
  (check-equal? (bytes-length sig) SIGNATURE-BYTES)
  (check-true (ed25519-verify? (ed25519-public-key seed) #"" sig))
  (check-false (ed25519-verify? (ed25519-public-key seed) #"x" sig)))

;; ---- 6. generated keys, and the shapes ---------------------------------------
(let* ([a (ed25519-generate-seed)] [b (ed25519-generate-seed)])
  (check-equal? (bytes-length a) SEED-BYTES)
  (check-false (equal? a b) "two generated seeds differ")
  (check-equal? (bytes-length (ed25519-public-key a)) PUBLIC-KEY-BYTES)
  ;; signing is DETERMINISTIC — the same key and message give the same bytes.
  ;; An anchor receipt's signature is stored, so a nondeterministic scheme would
  ;; make a stored signature unreproducible from the payload.
  (check-equal? (ed25519-sign a #"anchor") (ed25519-sign a #"anchor")))

;; ---- 7. the configured key: hex only, and a passphrase is REFUSED -------------
;; Unlike TELEMACHUS_SECRET_KEY, which accepts a phrase and stretches it. A
;; signing key is machine-generated once; stretching a phrase into an Ed25519
;; seed would make the instance's published identity guessable at whatever rate
;; the phrase allows, and a forged receipt cannot be undone by rotating after.
(define (with-env var val thunk)
  (define old (getenv var))
  (dynamic-wind (lambda () (if val (putenv var val) (putenv var "")))
                thunk
                (lambda () (putenv var (or old "")))))

(with-env "TELEMACHUS_ANCHOR_KEY" #f
  (lambda ()
    (check-false (anchor-key-seed) "unset means no anchoring")
    (check-false (anchor-signing-enabled?))))

(with-env "TELEMACHUS_ANCHOR_KEY" sk2
  (lambda ()
    (check-equal? (anchor-key-seed) (H sk2))
    (check-true (anchor-signing-enabled?))))

(with-env "TELEMACHUS_ANCHOR_KEY" "correct horse battery staple"
  (lambda ()
    (check-exn #px"64 hex" (lambda () (anchor-key-seed))
               "a passphrase is refused, and the message names the generator")))

(with-env "TELEMACHUS_ANCHOR_KEY" (substring sk2 0 62)
  (lambda ()
    (check-exn #px"64 hex" (lambda () (anchor-key-seed))
               "a key of the wrong length is refused rather than padded")))

;; the memo is keyed by the RAW VALUE, not by the variable name — secretbox's
;; rule. A cache that remembered only "this was read" would pin whatever was set
;; first, so a rotated environment in one process would keep the old key.
(with-env "TELEMACHUS_ANCHOR_KEY" sk3
  (lambda () (check-equal? (anchor-key-seed) (H sk3) "a changed key is re-read")))

(printf "signing tests: ok\n")
