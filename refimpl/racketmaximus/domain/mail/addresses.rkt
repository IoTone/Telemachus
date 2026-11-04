#lang racket/base

;; domain/mail/addresses.rkt — an address somebody can actually be reached at.
;;
;; `users.email` HAS EXISTED SINCE MIGRATION 0001 AND NOTHING IN THE TREE HAS
;; EVER WRITTEN TO IT (MAIL-4). `create-user!` does not take an address,
;; `POST /api/profile` took `locale` and `timezone`, `POST /api/members` takes a
;; username, and `provision!` uses the address as the USERNAME and leaves the
;; column NULL — so it is NULL on every row of every instance. #113's shape: a
;; field declared, published in the generated schema, and filled by nothing.
;;
;; That is why this module exists before the notifier does. A notification
;; subsystem keyed on that column would have sent nothing to nobody for ever, and
;; the only symptom would have been silence.
;;
;; AN ADDRESS IS NOT USED UNTIL IT HAS ANSWERED (MAIL-5). The failure this
;; prevents is specific and silent: one transposed character and a colleague's
;; notifications — a document id, a team's name, a workflow slug — go to a
;; stranger's inbox indefinitely, and the person who typed it concludes
;; notifications are broken while the person receiving them has no idea who to
;; tell. So `users.email` holds a VERIFIED address and nothing else, and a pending
;; one lives in `email_verifications` until it has been confirmed.
;;
;; THE TOKEN GOES THROUGH `hash-token`, THE ONE TOKEN-HASHING RULE. SEC-3 found
;; `activation_tokens` still on the pre-#13 scheme — bare SHA-1 over a
;; compiled-in salt, in a clean-MIT tree published on GitHub — and the finding was
;; not the digest's strength, since `random-token` is 24 bytes of
;; `crypto-random-bytes` either way. It was that there were TWO token-hashing
;; rules and the weaker one was the one nobody looked at. What the pepper buys
;; here is the same thing it buys there: rotating `TMACH_TOKEN_PEPPER` retires
;; every outstanding verification link.

(require db-kit/portable
         racket/string
         "../db/id.rkt"
         "../db/nulls.rkt"
         (only-in "../authz/authz.rkt" hash-token audit!)
         (only-in "./transport.rkt" mail-address-problem printable))

(provide VERIFY-TTL
         user-address user-address-state user-by-verified-address
         address-claim! address-verify! address-clear! address-pending)

;; A day. Long enough for somebody who asked at the end of the afternoon, short
;; enough that a link in an inbox somebody else later reads has expired — and the
;; row is REPLACED on a re-request, so asking again is always available and the
;; previous link stops working, which is what "send it again" means to the person
;; who pressed it.
(define VERIFY-TTL (* 24 3600))

(define (now) (current-seconds))

(define (hash-verify-token tok) (hash-token (string-append "emailverify:" tok)))

;; -> the VERIFIED address, or #f. The one function anything that wants to send to
;; a person should ask.
(define (user-address conn user-id)
  (define r (query-maybe-row conn
              "SELECT email, email_verified_epoch FROM users WHERE id = ?" user-id))
  (and r
       (not (sql-null? (vector-ref r 0)))
       (not (sql-null? (vector-ref r 1)))
       (vector-ref r 0)))

;; The reverse lookup, for a caller holding an address and no user: a password
;; reset, where the address IS the identifier somebody typed.
;;
;; IT MATCHES ONLY A VERIFIED ADDRESS AND ONLY AN ACTIVE ACCOUNT, and both halves
;; are the rule rather than caution. MAIL-5 is that nothing is sent to an address
;; that has not answered, so an unverified one is not a place this instance will
;; mail a credential; and `authenticate` admits `status = 'active'` alone, so
;; offering a reset to a SUSPENDED account would mail a link that sets a password
;; nobody can then use — and would tell whoever holds that mailbox that the
;; account exists and was suspended.
;;
;; The comparison is case-folded on the way in, because an address typed into a
;; sign-in screen is typed by a person. The domain is case-insensitive by RFC and
;; the local part is not, in theory — in practice no mail system anybody deploys
;; distinguishes them, and treating `Alice@` as a different person from `alice@`
;; would make the reset silently find nothing for the commonest possible typo.
(define (user-by-verified-address conn address)
  (define a (string-downcase (string-trim (format "~a" address))))
  (and (not (string=? a ""))
       (let ([v (query-maybe-value conn
                  (string-append "SELECT id FROM users WHERE LOWER(email) = ? "
                                 "AND email_verified_epoch IS NOT NULL AND status = 'active'")
                  a)])
         (and v (not (sql-null? v)) (format "~a" v)))))

;; What a profile card renders: the verified address if there is one, the pending
;; one if a verification is outstanding, and when each happened. The TOKEN is
;; never in it — #19's rule for anything shown once.
(define (user-address-state conn user-id)
  (define r (query-maybe-row conn
              "SELECT email, email_verified_epoch FROM users WHERE id = ?" user-id))
  (define p (address-pending conn user-id))
  (hasheq 'address (if (and r (not (sql-null? (vector-ref r 0)))) (vector-ref r 0) 'null)
          'verified_epoch (if (and r (not (sql-null? (vector-ref r 1)))) (vector-ref r 1) 'null)
          'pending (if p (hash-ref p 'address) 'null)
          'pending_expires_epoch (if p (hash-ref p 'expires_epoch) 'null)))

(define (address-pending conn user-id)
  (define r (query-maybe-row conn
              "SELECT address, expires_epoch FROM email_verifications WHERE user_id = ?" user-id))
  (and r (> (vector-ref r 1) (now))
       (hasheq 'address (vector-ref r 0) 'expires_epoch (vector-ref r 1))))

;; -> (values token address), or raises. The TOKEN IS RETURNED AND NOT STORED:
;; only its hash is, so this is the one moment it exists and the caller's one
;; chance to put it in a message.
;;
;; CLAIMING AN ADDRESS DOES NOT TOUCH `users.email`, so a person with a working
;; verified address who mistypes a new one keeps receiving mail at the old one
;; until the new one answers. That is the opposite of clearing it and then
;; verifying, which would silence somebody for a typo.
(define (address-claim! conn user-id address)
  (define a (and (string? address) (string-trim address)))
  (define p (mail-address-problem a))
  (when p (raise-user-error 'email (format "~a: ~a" (printable address) p)))
  (define tok (random-token))
  ;; One outstanding verification per user, so a re-request REPLACES — an older
  ;; link stops working, which is what the person who pressed "send it again"
  ;; expects. No ON CONFLICT: the dialects spell upsert differently and this is
  ;; one row (settings.rkt's reason).
  (query-exec conn "DELETE FROM email_verifications WHERE user_id = ?" user-id)
  (query-exec conn
    (string-append "INSERT INTO email_verifications (user_id, address, token_hash, "
                   "expires_epoch, created_epoch) VALUES (?, ?, ?, ?, ?)")
    user-id a (hash-verify-token tok) (+ (now) VERIFY-TTL) (now))
  (values tok a))

;; -> the address on success, #f on a miss. A BAD TOKEN AND AN EXPIRED ONE ARE ONE
;; ANSWER: whether a given token was ever real is not a question this should
;; answer to somebody holding a guess, and the remedy for both is the same — ask
;; again. The console says so.
;;
;; The row is consumed in the SAME STATEMENT that matches it (`DELETE … RETURNING`),
;; so two clicks on one link cannot both verify — #17's rule, and here it is what
;; stops a replay rather than a duplicate.
(define (address-verify! conn token)
  (define r (and (string? token)
                 (query-maybe-row conn
                   (string-append "DELETE FROM email_verifications WHERE token_hash = ? "
                                  "AND expires_epoch > ? RETURNING user_id, address")
                   (hash-verify-token token) (now))))
  (cond
    [(not r) #f]
    [else
     (define uid (vector-ref r 0))
     (define addr (vector-ref r 1))
     (query-exec conn
       (string-append "UPDATE users SET email = ?, email_verified_epoch = ?, "
                      "updated_at = CURRENT_TIMESTAMP WHERE id = ?")
       addr (now) uid)
     ;; Audited, because this is the moment an address starts receiving a team's
     ;; ids and status. `#:team-id` is deliberately ABSENT: a verification belongs
     ;; to a PERSON and not to any one of their teams, and guessing one would put
     ;; the entry in a trail where it does not belong. The consequence is stated
     ;; rather than discovered — `audit-list` filters by team, so this entry is
     ;; visible to the instance's own trail and not to a team's, which is the
     ;; shape `user.2fa.reset` has and the one QUOTA-3 named seven times.
     (audit! conn #:action "user.email.verified" #:actor-type "user" #:actor-id uid
             #:resource-type "user" #:resource-id uid #:result "ok")
     addr]))

;; Removing an address stops mail at once and withdraws any pending claim. There
;; is no "disable notifications but keep the address" here — that is what the
;; per-category preferences are for, and two ways to say one thing is how they
;; come to disagree.
(define (address-clear! conn user-id)
  (query-exec conn "DELETE FROM email_verifications WHERE user_id = ?" user-id)
  (query-exec conn
    (string-append "UPDATE users SET email = NULL, email_verified_epoch = NULL, "
                   "updated_at = CURRENT_TIMESTAMP WHERE id = ?")
    user-id))
