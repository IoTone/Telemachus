#lang racket/base

;; test/auth-tests.rkt — slice 4: password hashing (PBKDF2) + TOTP 2FA.
;;   raco test test/auth-tests.rkt   (with pkgs on PLTCOLLECTS)

(require rackunit
         racket/string racket/list
         db-kit/portable
         db-kit/migrate
         "../domain/db/migrations.rkt"
         "db-fixture.rkt"
         "../domain/authz/crypto.rkt"
         "../domain/authz/passwords.rkt"
         "../domain/authz/authz.rkt")

(define (fresh)
  (define c (fresh-db #:migrate? #f))
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
  (define-values (secret _uri _codes) (enable-2fa! c uid))
  (check-false (authenticate c "alice" "s3cret"))                    ; missing code
  (define code (totp (base32-decode secret) (current-seconds) 30 6))
  (check-equal? (authenticate c "alice" "s3cret" #:code code) uid))

;; ---- recovery codes (issue #26) -----------------------------------------------

(test-case "a recovery code signs in when the authenticator is gone, once"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice" #:password "s3cret"))
  (define-values (secret _uri codes) (enable-2fa! c uid))
  ;; enrolling hands out the way back in at the same time
  (check-equal? (length codes) RECOVERY-CODE-COUNT)
  (check-equal? (recovery-codes-remaining c uid) RECOVERY-CODE-COUNT)
  (check-true (for/and ([x (in-list codes)]) (regexp-match? #px"^[a-z0-9]{5}-[a-z0-9]{5}$" x)))
  (check-equal? (length (remove-duplicates codes)) RECOVERY-CODE-COUNT "…and they are distinct")
  ;; a TOTP code still works, and does not spend anything
  (check-equal? (authenticate c "alice" "s3cret" #:code (totp (base32-decode secret) (current-seconds) 30 6)) uid)
  (check-equal? (recovery-codes-remaining c uid) RECOVERY-CODE-COUNT)
  ;; the authenticator is gone: a recovery code takes its place
  (define one (car codes))
  (check-equal? (authenticate c "alice" "s3cret" #:code one) uid)
  (check-equal? (recovery-codes-remaining c uid) (sub1 RECOVERY-CODE-COUNT) "…and is spent")
  ;; single use: the same code does not work twice
  (check-false (authenticate c "alice" "s3cret" #:code one))
  ;; …while the others still do
  (check-equal? (authenticate c "alice" "s3cret" #:code (cadr codes)) uid)
  ;; a code is typed off paper: case and dashes are forgiven, nothing else is
  (check-equal? (authenticate c "alice" "s3cret" #:code (string-upcase (caddr codes))) uid)
  (check-equal? (authenticate c "alice" "s3cret"
                              #:code (regexp-replace #rx"-" (cadddr codes) "")) uid)
  (check-false (authenticate c "alice" "s3cret" #:code "aaaaa-bbbbb") "a code nobody issued")
  ;; the password is still required — a code is a second factor, not a way past the first
  (check-false (authenticate c "alice" "wrong" #:code (list-ref codes 4)))
  (check-equal? (recovery-codes-remaining c uid) (- RECOVERY-CODE-COUNT 4)
                "…and a failed password spends nothing")
  (disconnect c))

(test-case "re-issuing replaces the outstanding set; a reset takes the codes with it"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice" #:password "s3cret"))
  (define-values (_s _u codes) (enable-2fa! c uid))
  (define fresh-set (issue-recovery-codes! c uid))
  (check-equal? (recovery-codes-remaining c uid) RECOVERY-CODE-COUNT)
  (check-false (authenticate c "alice" "s3cret" #:code (car codes)) "the old set is dead")
  (check-equal? (authenticate c "alice" "s3cret" #:code (car fresh-set)) uid)
  ;; a reset revokes the seed AND the codes — they exist to open that second factor
  (check-true (reset-2fa! c uid))
  (check-equal? (recovery-codes-remaining c uid) 0)
  (check-equal? (authenticate c "alice" "s3cret") uid "2FA is off")
  ;; enrolling again issues a new set, and the old codes stay dead
  (define-values (_s2 _u2 codes2) (enable-2fa! c uid))
  (check-false (authenticate c "alice" "s3cret" #:code (cadr fresh-set)))
  (check-equal? (authenticate c "alice" "s3cret" #:code (car codes2)) uid)
  (disconnect c))

(test-case "codes are stored as hashes, not as codes"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice" #:password "s3cret"))
  (define-values (_s _u codes) (enable-2fa! c uid))
  (define stored (query-list c "SELECT code_hash FROM user_recovery_codes WHERE user_id = ?" uid))
  (check-equal? (length stored) RECOVERY-CODE-COUNT)
  (for ([h (in-list stored)]) (check-true (regexp-match? #rx"^v1:" h)))
  (for ([code (in-list codes)])
    (check-false (for/or ([h (in-list stored)]) (regexp-match? (regexp (regexp-quote code)) h))
                 "the code itself is not in the row"))
  ;; a spent code keeps its row, so "already used" stays distinguishable in an audit
  (authenticate c "alice" "s3cret" #:code (car codes))
  (check-equal? (query-value c "SELECT COUNT(*) FROM user_recovery_codes WHERE user_id = ?" uid)
                RECOVERY-CODE-COUNT)
  (check-equal? (query-value c "SELECT COUNT(*) FROM user_recovery_codes WHERE user_id = ? AND used_at IS NOT NULL" uid) 1)
  (disconnect c))
