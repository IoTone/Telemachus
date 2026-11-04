#lang racket/base

;; domain/authz/mailed-tokens.rkt — a token this instance MAILS to somebody, and
;; what redeeming one proves (RESET-1…4).
;;
;; `activation_tokens` has been the invitation table since 0006 and is now the
;; home of two credential families that differ only in `purpose`: an invitation,
;; for a person who has never had a password, and a password reset, for somebody
;; who cannot sign in. The TABLE's rules live here — minting, the single
;; outstanding slot, validation and spending — because getting any of them
;; slightly different in two places is `executor-can-run?`'s drift in a
;; credential path, which is the worst place available for it.
;;
;; WHAT IT DELIBERATELY DOES NOT DO: it writes no password, touches no
;; `users.status`, revokes no session and sends no mail. Those differ per flow
;; and they are the whole of the difference, so they belong to the two askers
;; (`activate!` in saas/onboarding.rkt and `reset-password!` in
;; accounts/reset.rkt) rather than to a shared function with a flag. Keeping mail
;; out is also what keeps this module requirable from `authz`: the composer lives
;; in domain/mail, which requires authz, so a mail dependency here would close a
;; cycle.
;;
;; ---- how a mailed token is stored (#186, SEC-3) -----------------------------
;;
;; THIS KEPT THE PRE-#13 PROTOTYPE SCHEME AND ITS OWN COMMENT SAID SO: bare SHA-1
;; over a COMPILED-IN salt, which is public — this is clean MIT on GitHub. #13
;; replaced exactly that for `api_tokens` with a peppered HMAC-SHA-256 under
;; `TMACH_TOKEN_PEPPER`, and this one credential family was left behind, so the
;; tree had two token-hashing rules and the weaker one was the one nobody looked
;; at. `hash-token` is the only rule now.
;;
;; WHAT THAT WAS AND WAS NOT, stated precisely, because overclaiming a security
;; finding is its own failure: a `random-token` is 24 bytes of
;; `crypto-random-bytes`, so 192 bits — guessing one over the network was never
;; feasible and neither was recovering one from a leaked hash, whatever the
;; digest. What the pepper buys is that **rotating `TMACH_TOKEN_PEPPER` retires
;; every outstanding mailed link**, which a compiled-in salt cannot do. Defence
;; in depth and a one-home rule, not a hole that was being walked through.
;;
;; THE LEGACY READ IS #13's, FOR #13's REASON: an unclaimed invitation in
;; somebody's inbox must keep working across the upgrade. The lookup tries the
;; current scheme, then the old 40-hex one, and REWRITES the row on a hit — so a
;; link is migrated the moment it is used and the legacy path drains by itself.
;; Only `activate` can have a legacy row, because the reset purpose is newer than
;; the hashing change, but the read does not special-case that: a purpose filter
;; on the rewrite would be a second rule about the same rows.

(require db-kit/portable
         file/sha1
         "../db/id.rkt"
         "authz.rkt")               ; hash-token

(provide MAILED-TOKEN-PURPOSES mailed-token-purpose?
         mint-mailed-token! claim-mailed-token! mailed-token-outstanding?)

;; A CLOSED vocabulary, checked in both directions by the test: a purpose
;; invented in passing would arrive as a token nothing can redeem, and the two
;; redemptions are different writes (see migration 0070).
(define MAILED-TOKEN-PURPOSES '("activate" "reset"))
(define (mailed-token-purpose? p) (and (member p MAILED-TOKEN-PURPOSES) #t))

(define LEGACY-ACTIVATION-SALT "telemachus-activation-v0")
(define (legacy-hash-tok t) (sha1 (open-input-string (string-append LEGACY-ACTIVATION-SALT t))))
(define (hash-tok t) (hash-token t))

;; Mint one, retiring this user's prior unused token OF THE SAME PURPOSE.
;; `ttl-hours` is the caller's because the two families want very different
;; horizons: an invitation may legitimately sit in an inbox for days, while a
;; reset link is a credential somebody asked for a moment ago and should stop
;; working long before they next read that mailbox on a shared machine.
(define (mint-mailed-token! conn uid ttl-hours #:purpose [purpose "activate"])
  (unless (mailed-token-purpose? purpose)
    (error 'mint-mailed-token! "unknown purpose: ~a" purpose))
  (query-exec conn
    (string-append "UPDATE activation_tokens SET used_at = CURRENT_TIMESTAMP "
                   "WHERE user_id = ? AND used_at IS NULL AND purpose = ?")
    uid purpose)
  (define raw (random-token))
  ;; Expiry is an epoch-seconds STRING: portable across sqlite and postgres with
  ;; no dialect-specific datetime arithmetic, which is the trap every other
  ;; time column in this schema records.
  (define expires (+ (current-seconds) (* ttl-hours 3600)))
  (query-exec conn
    (string-append "INSERT INTO activation_tokens (id, user_id, token_hash, prefix, expires_at, purpose) "
                   "VALUES (?, ?, ?, ?, ?, ?)")
    (new-id) uid (hash-tok raw) (substring raw 0 (min 11 (string-length raw)))
    (number->string expires) purpose)
  raw)

(define (mailed-token-outstanding? conn uid purpose)
  (and (query-maybe-value conn
         (string-append "SELECT id FROM activation_tokens WHERE user_id = ? AND purpose = ? "
                        "AND used_at IS NULL")
         uid purpose)
       #t))

(define SELECT-BY-HASH
  (string-append "SELECT id, user_id, used_at, expires_at, purpose "
                 "FROM activation_tokens WHERE token_hash = ?"))

(define (token-row conn raw)
  (define h (hash-tok raw))
  (or (query-maybe-row conn SELECT-BY-HASH h)
      (let* ([lh (legacy-hash-tok raw)]
             [r (query-maybe-row conn SELECT-BY-HASH lh)])
        (and r
             (begin (query-exec conn "UPDATE activation_tokens SET token_hash = ? WHERE token_hash = ?" h lh)
                    r)))))

(define (expired? e)
  (and (not (sql-null? e))
       (let ([n (string->number (format "~a" e))])
         (and n (> (current-seconds) n)))))

;; Validate a raw token for ONE purpose and SPEND it, atomically. Answers the
;; user id, or #f.
;;
;; THE SPEND IS A GUARDED `UPDATE … RETURNING`, believed only when a row comes
;; back — #17's rule, which this platform applies to every claim it makes. A
;; select-then-update would let two redemptions of one link both win, and for a
;; reset that means two people setting a password from one mailbox.
;;
;; THE PURPOSE IS IN THE `WHERE`, not checked afterwards, so a reset token
;; presented to the activation endpoint matches no row at all — and therefore
;; cannot be told from an unknown token, which is the answer a caller should get.
(define (claim-mailed-token! conn raw #:purpose purpose)
  (unless (mailed-token-purpose? purpose)
    (error 'claim-mailed-token! "unknown purpose: ~a" purpose))
  (define row (token-row conn raw))
  (cond
    [(not row) #f]
    [(not (sql-null? (vector-ref row 2))) #f]                  ; already spent
    [(expired? (vector-ref row 3)) #f]
    [(not (equal? (format "~a" (vector-ref row 4)) purpose)) #f]
    [else
     (define spent
       (query-maybe-value conn
         (string-append "UPDATE activation_tokens SET used_at = CURRENT_TIMESTAMP "
                        "WHERE id = ? AND used_at IS NULL AND purpose = ? RETURNING user_id")
         (vector-ref row 0) purpose))
     (and spent (not (sql-null? spent)) (format "~a" spent))]))
