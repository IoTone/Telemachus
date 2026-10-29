#lang racket/base

;; #128 job 2: operator-facing variables are read through ONE accessor,
;; which tries TMACH_<name> and falls back to TELEMACHUS_<name>.
(require (only-in "../config.rkt" tmach-env))

;; test/secretbox-tests.rkt — secrets at rest (issue #19).
;;
;; Two layers. The PRIMITIVE is pinned to NIST's GCM vectors, for the same reason
;; sha2-tests pins its digests: we are not implementing AES, we are getting an FFI
;; signature right, and a vector catches that immediately. The STORED FORM is
;; checked for the properties the platform actually leans on — plaintext rows keep
;; working, a ciphertext cannot be moved between rows, a wrong key is loud rather
;; than empty, and a rotation can read both keys.
;;   raco test test/secretbox-tests.rkt

(require rackunit racket/string db-kit/portable db-kit/migrate
         (only-in file/sha1 hex-string->bytes bytes->hex-string)
         "../domain/db/migrations.rkt"
         "db-fixture.rkt"
         "../domain/authz/secretbox.rkt"
         "../domain/authz/authz.rkt"
         (only-in "../domain/authz/crypto.rkt" totp base32-decode)   ; to prove a sealed seed still signs in
         "../domain/s3/creds.rkt"
         ;; the first caller the bytes path was built for (issue #189 step 1)
         (only-in "../domain/ai/vectors.rkt" vec-pack vec-unpack vec-normalize vec-unit? vec-dot)
         (only-in racket/flonum for/flvector))

(define (fresh) (define c (fresh-db #:migrate? #f)) (migrate! c all-migrations) c)
(define (hx s) (hex-string->bytes s))

;; A key is set for the whole file; the "no key configured" case is covered by
;; every OTHER test file, which runs with none.
(define KEY-HEX "2b7e151628aed2a6abf7158809cf4f3c762e7160f38b4da56a784d9045190cfe")
(define KEY-HEX-2 "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff")

;; ---- the primitive, against NIST's vectors ----------------------------------

(test-case "AES-256-GCM matches the NIST vectors"
  ;; gcmEncryptExtIV256, key/IV with an empty plaintext and empty AAD: the output
  ;; is the tag alone
  (check-equal? (bytes->hex-string
                 (aes-256-gcm-encrypt (hx "b52c505a37d78eda5dd34f20c22540ea1b58963cf8e5bf8ffa85f9f2492505b4")
                                      (hx "516c33929df5a3284ff463d7") #"" #""))
                "bdc1ac884d332457a1d2664f168c76f0")
  ;; a 128-bit plaintext, no AAD: ciphertext || tag
  (check-equal? (bytes->hex-string
                 (aes-256-gcm-encrypt (hx "31bdadd96698c204aa9ce1448ea94ae1fb4a9a0b3c9d773b51bb1822666b8f22")
                                      (hx "0d18e06c7c725ac9e362e1ce")
                                      #""
                                      (hx "2db5168e932556f8089a0622981d017d")))
                "fa4362189661d163fcd6a56d8bf0405ad636ac1bbedd5cc3ee727dc2ab4a9489")
  ;; with AAD: the tag covers it
  (check-equal? (bytes->hex-string
                 (aes-256-gcm-encrypt (hx "92e11dcdaa866f5ce790fd24501f92509aacf4cb8b1339d50c9c1240935dd08b")
                                      (hx "ac93a1a6145299bde902f21a")
                                      (hx "1e0889016f67601c8ebea4943bc23ad6")
                                      (hx "2d71bcfa914e4ac045b2aa60955fad24")))
                "8995ae2e6df3dbf96fac7b7137bae67feca5aa77d51d4a0a14d9c51e1da474ab"))

(test-case "decrypt returns the plaintext, and #f for anything that does not authenticate"
  (define key (hx KEY-HEX))
  (define nonce (make-bytes NONCE-BYTES 7))
  (define ct (aes-256-gcm-encrypt key nonce #"context" #"a stored secret"))
  (check-equal? (aes-256-gcm-decrypt key nonce #"context" ct) #"a stored secret")
  (check-false (aes-256-gcm-decrypt key nonce #"OTHER context" ct) "the AAD is authenticated")
  (check-false (aes-256-gcm-decrypt (hx KEY-HEX-2) nonce #"context" ct) "a wrong key")
  (check-false (aes-256-gcm-decrypt key (make-bytes NONCE-BYTES 8) #"context" ct) "a wrong nonce")
  ;; one flipped bit anywhere in the ciphertext or the tag
  (define tampered (bytes-copy ct))
  (bytes-set! tampered 0 (bitwise-xor (bytes-ref tampered 0) 1))
  (check-false (aes-256-gcm-decrypt key nonce #"context" tampered))
  (define tag-flipped (bytes-copy ct))
  (bytes-set! tag-flipped (sub1 (bytes-length ct)) (bitwise-xor (bytes-ref tag-flipped (sub1 (bytes-length ct))) 1))
  (check-false (aes-256-gcm-decrypt key nonce #"context" tag-flipped))
  (check-false (aes-256-gcm-decrypt key nonce #"context" #"short") "a truncated value"))

(test-case "a key is 64 hex characters, or a passphrase that gets stretched"
  (check-equal? (parse-secret-key KEY-HEX) (hx KEY-HEX))
  (check-false (parse-secret-key #f))
  (check-false (parse-secret-key "   "))
  (define stretched (parse-secret-key "a passphrase an operator would actually type"))
  (check-equal? (bytes-length stretched) KEY-BYTES)
  (check-equal? stretched (parse-secret-key "a passphrase an operator would actually type") "deterministic")
  (check-not-equal? stretched (parse-secret-key "a different passphrase")))

;; ---- the stored form ---------------------------------------------------------

(define (with-key key thunk)                  ; the key is read from the environment
  (define old (tmach-env "SECRET_KEY"))
  (putenv "TMACH_SECRET_KEY" key)
  (dynamic-wind void thunk (lambda () (putenv "TMACH_SECRET_KEY" (or old "")))))

(test-case "with no key, wrapping is the identity — the 'trusted database' position"
  (check-false (secrets-enabled?))
  (check-equal? (secret-wrap "users.totp_secret:u1" "JBSWY3DPEHPK3PXP") "JBSWY3DPEHPK3PXP")
  (check-false (wrapped-secret? "JBSWY3DPEHPK3PXP"))
  ;; and a value sealed by an instance that HAS a key is still readable by one
  ;; that has it configured — the format carries which key sealed it
  (check-equal? (secret-unwrap "users.totp_secret:u1" "JBSWY3DPEHPK3PXP") "JBSWY3DPEHPK3PXP"))

(test-case "a wrapped secret round-trips, is bound to its row, and is loud when it cannot open"
  (with-key KEY-HEX
    (lambda ()
      (check-true (secrets-enabled?))
      (define stored (secret-wrap "users.totp_secret:u1" "JBSWY3DPEHPK3PXP"))
      (check-true (wrapped-secret? stored))
      (check-true (string-prefix? stored (string-append "enc:v1:" (secret-key-id) ":")))
      (check-false (regexp-match? #rx"JBSWY3DPEHPK3PXP" stored) "the plaintext is not in the stored value")
      (check-equal? (secret-unwrap "users.totp_secret:u1" stored) "JBSWY3DPEHPK3PXP")
      ;; the same plaintext seals differently every time (a fresh nonce), so equal
      ;; secrets are not equal ciphertexts in a dump
      (check-not-equal? stored (secret-wrap "users.totp_secret:u1" "JBSWY3DPEHPK3PXP"))
      ;; moved to another row, it does not open — this is what the AAD buys
      (check-exn #rx"did not authenticate"
                 (lambda () (secret-unwrap "users.totp_secret:SOMEONE-ELSE" stored)))
      ;; nor into another column
      (check-exn #rx"did not authenticate"
                 (lambda () (secret-unwrap "repo_credentials.secret_key:u1" stored)))
      ;; a plaintext row written before the key existed still reads
      (check-equal? (secret-unwrap "users.totp_secret:u1" "legacy-plaintext") "legacy-plaintext")))
  ;; a sealed value with NO key configured is an error, never a silently empty
  ;; secret — an empty TOTP seed would quietly disable someone's second factor
  (define sealed (with-key KEY-HEX (lambda () (secret-wrap "users.totp_secret:u1" "S"))))
  (check-exn #rx"no configured key" (lambda () (secret-unwrap "users.totp_secret:u1" sealed))))

(test-case "a rotation reads the old key and writes the new one"
  (define old-sealed (with-key KEY-HEX (lambda () (secret-wrap "users.totp_secret:u1" "SEED"))))
  (define old (tmach-env "SECRET_KEY_OLD"))
  (putenv "TMACH_SECRET_KEY_OLD" KEY-HEX)
  (with-key KEY-HEX-2
    (lambda ()
      ;; the new key alone cannot open it…
      (check-regexp-match #rx"^enc:v1:" old-sealed)
      ;; …but with the previous one configured, it opens and re-seals under the new
      (define plain (secret-unwrap "users.totp_secret:u1" old-sealed))
      (check-equal? plain "SEED")
      (define new-sealed (secret-wrap "users.totp_secret:u1" plain))
      (check-true (string-prefix? new-sealed (string-append "enc:v1:" (secret-key-id) ":")))
      (check-false (equal? (substring old-sealed 0 15) (substring new-sealed 0 15)) "a different key id")))
  (void (putenv "TMACH_SECRET_KEY_OLD" (or old ""))))

;; ---- the three seams, through the database ----------------------------------

(test-case "the TOTP seed is sealed in the row and still authenticates"
  (with-key KEY-HEX
    (lambda ()
      (define c (fresh))
      (define-values (uid tid) (bootstrap! c #:username "alice"))
      (set-password! c uid "pw-pw-pw1")
      (define-values (seed uri codes) (enable-2fa! c uid))
      ;; what a dump would show
      (define stored (query-value c "SELECT totp_secret FROM users WHERE id = ?" uid))
      (check-true (wrapped-secret? stored) "the column holds a sealed value")
      (check-false (regexp-match? (regexp (regexp-quote seed)) stored) "…not the seed")
      ;; and sign-in still works, which is the whole point of doing it at the seam
      (check-equal? (authenticate c "alice" "pw-pw-pw1" #:code (totp (base32-decode seed) (current-seconds))) uid)
      (check-false (authenticate c "alice" "pw-pw-pw1" #:code "000000"))
      (check-false (authenticate c "alice" "pw-pw-pw1") "2FA is still required")
      ;; reset: the seed is revoked, so a dump of it is no longer replayable
      (check-true (reset-2fa! c uid))
      (check-true (sql-null? (query-value c "SELECT totp_secret FROM users WHERE id = ?" uid)))
      (check-equal? (authenticate c "alice" "pw-pw-pw1") uid "…and 2FA is off")
      (check-false (reset-2fa! c uid) "resetting again says there was nothing to reset")
      (disconnect c))))

(test-case "an S3 credential's secret is sealed in the row and still resolves"
  (with-key KEY-HEX
    (lambda ()
      (define c (fresh))
      (define-values (uid tid) (bootstrap! c #:username "alice"))
      (define p (user-principal c uid tid))
      (define cred (s3-cred-issue! c p #:name "laptop"))
      (define ak (hash-ref cred 'access_key_id))
      (define secret (hash-ref cred 'secret_access_key))
      (define stored (query-value c "SELECT secret_key FROM repo_credentials WHERE access_key_id = ?" ak))
      (check-true (wrapped-secret? stored))
      (check-false (regexp-match? (regexp (regexp-quote secret)) stored))
      ;; SigV4 needs the secret itself, and gets it
      (define-values (resolved row) (s3-cred-resolve c ak))
      (check-equal? resolved secret)
      ;; …including the presign path, which signs with the caller's newest key
      (check-equal? (cdr (s3-cred-newest c p)) secret)
      (disconnect c))))

;; ---- the bytes stored form (issue #189 step 2) -------------------------------
;;
;; A second stored form exists because `secret-wrap` is a STRING API and #189
;; measured what that costs on 29.3 MiB of packed float32: 2,240 ms and 52.1 MiB
;; through base64+UTF-8, against 44 ms and 29.3 MiB on the raw bytes. These cases
;; are about the properties, not the speed — the same key, the same cipher, the
;; same AAD, and a sniff that has to work on bytes that may contain anything.

(test-case "bytes seal and open, byte-identically, with nothing converted"
  (with-key KEY-HEX
    (lambda ()
      ;; deliberately not UTF-8: a packed float32 vector is not text, and the
      ;; string path would have mangled or refused exactly this
      (define plain (bytes 0 1 255 128 0 0 #x80 #x3f 254))
      (define stored (secret-wrap/bytes "repo_vectors.v:c1" plain))
      (check-true (wrapped-bytes? stored))
      (check-false (regexp-match? (regexp-quote plain) stored) "the plaintext is not in the row")
      (check-equal? (secret-unwrap/bytes "repo_vectors.v:c1" stored) plain)
      ;; and the stored size is the plaintext plus one fixed header, not 4/3 of it
      (check-equal? (bytes-length stored) (+ (bytes-length plain) 8 8 NONCE-BYTES 16)))))

(test-case "the bytes AAD is the row, so a ciphertext cannot be moved"
  (with-key KEY-HEX
    (lambda ()
      (define stored (secret-wrap/bytes "repo_vectors.v:c1" #"\0\1\2\3"))
      (check-exn exn:fail? (lambda () (secret-unwrap/bytes "repo_vectors.v:c2" stored))
                 "another row's context must not open it")
      ;; a flipped bit anywhere is a refusal, not a silently different vector
      (define tampered (bytes-copy stored))
      (bytes-set! tampered (- (bytes-length tampered) 1)
                  (bitwise-xor (bytes-ref tampered (- (bytes-length tampered) 1)) 1))
      (check-exn exn:fail? (lambda () (secret-unwrap/bytes "repo_vectors.v:c1" tampered))))))

(test-case "a refusal names neither the plaintext nor the key"
  (define stored (with-key KEY-HEX (lambda () (secret-wrap/bytes "repo_vectors.v:c1" #"SENSITIVE"))))
  (with-key KEY-HEX-2
    (lambda ()
      (define msg
        (with-handlers ([exn:fail? exn-message])
          (secret-unwrap/bytes "repo_vectors.v:c1" stored)
          "it opened, which it must not have"))
      (check-true (string? msg))
      (check-false (regexp-match? #rx"SENSITIVE" msg))
      (check-false (regexp-match? (regexp (substring KEY-HEX 0 32)) msg))
      (check-false (regexp-match? (regexp (substring KEY-HEX-2 0 32)) msg)))))

(test-case "with no key configured the bytes path is the identity"
  ;; the supported plaintext-at-rest posture, and the reason the unseal must be
  ;; unconditional: a value sealed yesterday still opens today
  (with-key ""
    (lambda ()
      (define plain (bytes 9 8 7))
      (check-equal? (secret-wrap/bytes "repo_vectors.v:c1" plain) plain)
      (check-false (wrapped-bytes? plain))
      (check-equal? (secret-unwrap/bytes "repo_vectors.v:c1" plain) plain))))

(test-case "the bytes path is total, like the string one"
  (with-key KEY-HEX
    (lambda ()
      ;; a non-bytes value passes through, so a guard at the call site would be
      ;; the redundancy sealed.rkt dropped
      (check-equal? (secret-wrap/bytes "repo_vectors.v:c1" 'null) 'null)
      (check-equal? (secret-unwrap/bytes "repo_vectors.v:c1" sql-null) sql-null)
      (check-equal? (secret-wrap/bytes "repo_vectors.v:c1" "a string") "a string"))))

(test-case "the sniff is the prefix AND the shape"
  ;; a plaintext blob may contain any byte, so a prefix alone cannot answer
  ;; "is this row sealed" — the magic, eight hex bytes of key id, and room for a
  ;; GCM tag all have to hold
  (check-false (wrapped-bytes? (bytes)))
  (check-false (wrapped-bytes? #"tmbenc01"))                      ; magic, nothing else
  (check-false (wrapped-bytes? (bytes-append #"tmbenc01" (make-bytes 40 0))))  ; kid not hex
  (check-false (wrapped-bytes? (bytes-append #"TMBENC01" (make-bytes 40 97)))) ; wrong case
  (check-false (wrapped-bytes? (bytes-append #"tmbenc01" (make-bytes 8 97) (make-bytes 4 0))))
  (check-true  (wrapped-bytes? (bytes-append #"tmbenc01" (make-bytes 8 97) (make-bytes 40 0))))
  ;; and a real sealed value, at the shortest it can be
  (with-key KEY-HEX
    (lambda () (check-true (wrapped-bytes? (secret-wrap/bytes "repo_vectors.v:c1" #""))))))

(test-case "a rotation reads the previous key and writes the current one"
  (define old (with-key KEY-HEX (lambda () (secret-wrap/bytes "repo_vectors.v:c1" #"\1\2\3"))))
  (define saved (tmach-env "SECRET_KEY_OLD"))
  (putenv "TMACH_SECRET_KEY_OLD" KEY-HEX)
  (dynamic-wind
   void
   (lambda ()
     (with-key KEY-HEX-2
       (lambda ()
         (check-equal? (secret-unwrap/bytes "repo_vectors.v:c1" old) #"\1\2\3")
         ;; re-sealed under the current key, which is what `rewrap` does
         (define new (secret-wrap/bytes "repo_vectors.v:c1" #"\1\2\3"))
         (check-false (equal? new old))
         (check-equal? (secret-unwrap/bytes "repo_vectors.v:c1" new) #"\1\2\3"))))
   (lambda () (putenv "TMACH_SECRET_KEY_OLD" (or saved "")))))

(test-case "a vector survives the seal exactly, which is the caller that asked"
  (with-key KEY-HEX
    (lambda ()
      (define v (vec-normalize (for/flvector ([i (in-range 16)]) (- (* 0.1 i) 0.7))))
      (define stored (secret-wrap/bytes "repo_vectors.v:c1" (vec-pack v)))
      (define back (vec-unpack (secret-unwrap/bytes "repo_vectors.v:c1" stored)))
      (check-true (vec-unit? back))
      (check-true (< (abs (- (vec-dot back back) 1.0)) 1e-6)))))
