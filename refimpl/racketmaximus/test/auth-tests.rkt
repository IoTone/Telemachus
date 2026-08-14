#lang racket/base

;; test/auth-tests.rkt — slice 4: password hashing (PBKDF2) + TOTP 2FA.
;;   raco test test/auth-tests.rkt   (with pkgs on PLTCOLLECTS)

(require rackunit
         racket/string
         db
         db-kit/migrate
         "../domain/db/migrations.rkt"
         "../domain/authz/crypto.rkt"
         "../domain/authz/passwords.rkt"
         "../domain/authz/authz.rkt")

(define (fresh)
  (define c (sqlite3-connect #:database 'memory))
  (migrate! c all-migrations)
  c)

(test-case "crypto: RFC vectors (HMAC-SHA1, PBKDF2, TOTP, base32)"
  (check-equal? (bytes->hex (hmac-sha1 (make-bytes 20 11) #"Hi There"))
                "b617318655057264e28bc0b6fb378c8ef146be00")                 ; RFC 2202
  (check-equal? (bytes->hex (pbkdf2-hmac-sha1 #"password" #"salt" 1 20))
                "0c60c80f961f0e71f3a9b524af6012062fe037a6")                 ; RFC 6070
  (check-equal? (bytes->hex (pbkdf2-hmac-sha1 #"password" #"salt" 2 20))
                "ea6c014dc72d6f8ccd1ed92ace1d41f0d8de8957")
  (check-equal? (totp #"12345678901234567890" 59 30 8) "94287082")          ; RFC 6238
  (check-equal? (base32-decode "GEZDGNBVGY3TQOJQGEZDGNBVGY3TQOJQ") #"12345678901234567890"))

(test-case "passwords: hash / verify"
  (define h (hash-password "correct horse" #:iters 10000))
  (check-true (string-prefix? h "pbkdf2_sha1$"))
  (check-true (verify-password "correct horse" h))
  (check-false (verify-password "wrong" h)))

(test-case "base32: encode/decode round-trip"
  (check-equal? (base32-decode (base32-encode #"telemachus")) #"telemachus"))

(test-case "authenticate: password, then 2FA required"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice" #:password "s3cret"))
  (check-equal? (authenticate c "alice" "s3cret") uid)
  (check-false (authenticate c "alice" "nope"))
  (check-false (authenticate c "ghost" "x"))
  (check-equal? (first-team-for c uid) tid)
  ;; enable 2FA: password alone is no longer enough; a valid TOTP code is
  (define-values (secret _uri) (enable-2fa! c uid))
  (check-false (authenticate c "alice" "s3cret"))                    ; missing code
  (define code (totp (base32-decode secret) (current-seconds) 30 6))
  (check-equal? (authenticate c "alice" "s3cret" #:code code) uid))
