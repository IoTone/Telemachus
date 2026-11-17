#lang racket/base

;; domain/mail/inbound.rkt — the one optional mailbox, and the two consumers that
;; may read it.
;;
;; A BOUNCE REPORT AND A REPLY ARE BOTH "MAIL THAT COMES BACK", so they share one
;; mailbox, one credential and one poller. Two mailboxes would mean two
;; credentials, two pollers, two failure modes and two places a message can be
;; lost; the split belongs at the first parse, not at the mailbox.
;;
;; AN INSTANCE MAY RUN NEITHER, ONE, OR BOTH. The shipped state is `none`, for the
;; reason the transport's is: an upgrade must not start reading a mailbox. The
;; consumers are a closed vocabulary, and the writer normalizes them, so a stored
;; document cannot name a consumer nothing implements.
;;
;; THE MODE IS THE MECHANISM, NOT THE POLICY. `imap` is the shipped one because
;; `curl` in the closure speaks it and the platform already shells out to
;; binaries, so it adds no dependency and no daemon. `maildir` is for an operator
;; who already runs a local delivery agent. `webhook` is for a relay that reports,
;; and it is the only one that adds a public route.
;;
;; THE PASSWORD IS A SEALED COLUMN and is listed in `CREDENTIAL-SECRETS` in the
;; same commit as its table, or `rewrap` cannot rotate it and every poll fails at
;; the first key rotation with an authentication error nobody can explain.

(require db-kit/portable
         racket/string
         json
         "../db/nulls.rkt"
         (only-in "../authz/authz.rkt" audit! principal-user-id)
         (only-in "../authz/sealed.rkt" define-sealed-column))

;; THE PASSWORD IS A SEALED COLUMN, and it is listed in `CREDENTIAL-SECRETS` in the
;; same commit as its table — a sealed column `rewrap` does not walk is silently
;; unrotatable, and here that means every poll fails at the first key rotation with
;; an authentication error nobody can explain.
(define-sealed-column "inbound_mailbox.password" (seal-password unseal-password) (id) #:credential)

(provide INBOUND-MODES inbound-mode? INBOUND-CONSUMERS inbound-consumer?
         inbound-ref inbound-set! inbound-clear! inbound-problem inbound-password
         inbound-configured? inbound-consumer-on? inbound-reply-address
         inbound-record-poll!)

;; `none` is a mode rather than an absent row, so "configured but off" and "never
;; configured" are one state and the console has one thing to draw.
(define INBOUND-MODES '("none" "imap" "maildir" "webhook"))
(define (inbound-mode? m) (and (member m INBOUND-MODES) #t))

;; The two consumers. `bounces` writes a suppression from a DSN; `messages` stores
;; a reply and raises an inbox item.
(define INBOUND-CONSUMERS '("bounces" "messages"))
(define (inbound-consumer? c) (and (member c INBOUND-CONSUMERS) #t))

(define INBOUND-ID "default")
(define COLS (string-append "id, mode, host, port, security, username, password, folder, consumers, "
                            "last_uid, uidvalidity, active, last_poll_epoch, last_poll_ok, last_error, "
                            "updated_by, updated_epoch"))

(define (now) (current-seconds))

;; The consumers document, normalized: only known names, only `true`.
;; SYMBOL KEYS, because `jsexpr->string` refuses a string key and the stored
;; document is JSON. The API's own vocabulary stays strings, so the conversion is
;; here and nowhere else.
(define (normalize-consumers doc)
  (for/hasheq ([c (in-list INBOUND-CONSUMERS)])
    (values (string->symbol c) (and (hash? doc) (eq? (hash-ref doc (string->symbol c) #f) #t)))))

(define (row->inbound r)
  (hasheq 'mode (vector-ref r 1)
          'host (nz (vector-ref r 2))
          'port (nz (vector-ref r 3))
          'security (vector-ref r 4)
          'username (nz (vector-ref r 5))
          'has_password (not (sql-null? (vector-ref r 6)))
          'folder (vector-ref r 7)
          'consumers (let ([v (vector-ref r 8)])
                       (if (string? v)
                           (with-handlers ([exn:fail? (lambda (_) (normalize-consumers #f))])
                             (normalize-consumers (string->jsexpr v)))
                           (normalize-consumers #f)))
          'last_uid (nz (vector-ref r 9))
          'uidvalidity (nz (vector-ref r 10))
          'active (= 1 (vector-ref r 11))
          'last_poll_epoch (nz (vector-ref r 12))
          'last_poll_ok (let ([v (vector-ref r 13)]) (if (sql-null? v) 'null (= 1 v)))
          'last_error (nz (vector-ref r 14))
          'updated_by (nz (vector-ref r 15))
          'updated_epoch (nz (vector-ref r 16))))

;; -> the row, or #f when nothing is configured. The PASSWORD IS NEVER IN A READ,
;; the rule `transport-ref` follows: it is its own accessor, and only the poller
;; may have it.
(define (inbound-ref conn)
  (define r (query-maybe-row conn (string-append "SELECT " COLS " FROM inbound_mailbox WHERE id = ?")
                             INBOUND-ID))
  (and r (row->inbound r)))

(define (inbound-password conn)
  (define r (query-maybe-value conn "SELECT password FROM inbound_mailbox WHERE id = ?" INBOUND-ID))
  (and r (not (sql-null? r)) (unseal-password INBOUND-ID r)))

;; -> #f, or a sentence naming the problem. An unknown field is refused rather
;; than dropped, the call `transport-problem` makes and for the same reason: a
;; setting that does nothing is how an operator concludes the feature is broken.
(define KNOWN-FIELDS '(mode host port security username password folder consumers active))
(define (inbound-problem doc)
  (cond
    [(not (hash? doc)) "an inbound mailbox must be an object"]
    [(for/or ([(k _) (in-hash doc)]) (and (not (memq k KNOWN-FIELDS)) k))
     => (lambda (k) (format "unknown field '~a' — known fields are: ~a" k
                            (string-join (map symbol->string KNOWN-FIELDS) ", ")))]
    [(let ([m (hash-ref doc 'mode "none")]) (and (not (inbound-mode? m))
                                                 (format "mode must be one of: ~a"
                                                         (string-join INBOUND-MODES ", "))))
     => values]
    ;; A MODE THAT READS A MAILBOX NEEDS A HOST AND A FOLDER. `none` needs
    ;; neither, and `maildir` needs a path rather than a host — which is why the
    ;; check is per mode rather than one shape for all four.
    [(and (member (hash-ref doc 'mode "none") '("imap" "webhook"))
          (let ([h (hash-ref doc 'host #f)])
            (not (and (string? h) (regexp-match? #px"^[A-Za-z0-9][A-Za-z0-9._-]*$" h)))))
     "host must be a hostname for this mode"]
    [(and (member (hash-ref doc 'mode "none") '("imap" "webhook"))
          (let ([p (hash-ref doc 'port #f)])
            (not (and (exact-integer? p) (> p 0) (< p 65536)))))
     "port must be 1-65535 for this mode"]
    [(let ([s (hash-ref doc 'security "tls")]) (and (not (member s '("tls" "starttls" "none")))
                                                    "security must be tls, starttls or none"))
     => values]
    [(let ([c (hash-ref doc 'consumers #f)])
       (and c (not (hash? c))))
     "consumers must be an object"]
    [(let ([c (hash-ref doc 'consumers #f)])
       (and (hash? c)
            (for/or ([(k _) (in-hash c)]) (and (not (inbound-consumer? (symbol->string k))) k))))
     => (lambda (k) (format "unknown consumer '~a' — known consumers are: ~a" k
                            (string-join INBOUND-CONSUMERS ", ")))]
    [(let ([v (hash-ref doc 'active #f)]) (and v (not (boolean? v)) "active must be true or false")) => values]
    [else #f]))

;; Read-modify-write of the whole row, with an ABSENT password leaving the stored
;; one alone — the rule `transport-set!` follows, and for the same reason: an edit
;; to the folder must not silently clear the credential.
(define (inbound-set! conn doc #:by [by #f])
  (define p (inbound-problem doc))
  (when p (error 'inbound-mailbox "~a" p))
  (define cur (query-maybe-row conn (string-append "SELECT " COLS " FROM inbound_mailbox WHERE id = ?")
                               INBOUND-ID))
  (define (f k [d sql-null])
    (let ([v (hash-ref doc k 'absent)])
      (cond [(eq? v 'absent) d] [(eq? v 'null) sql-null] [else v])))
  (define pw
    (let ([v (hash-ref doc 'password 'absent)])
      (cond
        [(eq? v 'absent) (if cur (vector-ref cur 6) sql-null)]
        [(or (eq? v 'null) (and (string? v) (string=? v ""))) sql-null]
        [else (seal-password INBOUND-ID v)])))
  (define consumers (jsexpr->string (normalize-consumers (hash-ref doc 'consumers #f))))
  (define args
    (list (hash-ref doc 'mode "none") (f 'host) (f 'port) (hash-ref doc 'security "tls")
          (f 'username) pw (hash-ref doc 'folder "INBOX") consumers
          (if (hash-ref doc 'active #f) 1 0) (or by sql-null) (now)))
  (if cur
      (apply query-exec conn
             (string-append "UPDATE inbound_mailbox SET mode = ?, host = ?, port = ?, security = ?, "
                            "username = ?, password = ?, folder = ?, consumers = ?, active = ?, "
                            "updated_by = ?, updated_epoch = ? WHERE id = '" INBOUND-ID "'")
             args)
      (apply query-exec conn
             (string-append "INSERT INTO inbound_mailbox (mode, host, port, security, username, "
                            "password, folder, consumers, active, updated_by, updated_epoch, id) "
                            "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, '" INBOUND-ID "')")
             args))
  (audit! conn #:action "instance.inbound.configured" #:actor-type "user"
          #:actor-id (or by sql-null) #:resource-type "inbound_mailbox" #:resource-id INBOUND-ID
          #:result "ok"
          #:meta (jsexpr->string (hasheq 'mode (hash-ref doc 'mode "none")
                                         'consumers (normalize-consumers (hash-ref doc 'consumers #f))
                                         'active (and (hash-ref doc 'active #f) #t))))
  (inbound-ref conn))

;; The only way back to the shipped state, the reason `transport-clear!` exists.
(define (inbound-clear! conn)
  (query-exec conn "DELETE FROM inbound_mailbox WHERE id = ?" INBOUND-ID))

;; "Is there a mailbox this instance actually reads?" — ACTIVE as well as present,
;; so an operator can stop the poller with one field without destroying the
;; configuration they would have to retype.
(define (inbound-configured? conn)
  (define m (inbound-ref conn))
  (and m (hash-ref m 'active) (not (equal? (hash-ref m 'mode) "none")) #t))

(define (inbound-consumer-on? conn consumer)
  (define m (inbound-ref conn))
  (and m (hash-ref m 'active)
       (eq? (hash-ref (hash-ref m 'consumers) (string->symbol consumer) #f) #t) #t))

;; THE REPLY ADDRESS, AND WHY IT DEPENDS ON THE MAILBOX. A reply token is only
;; worth minting when something reads the mailbox it points at: a token nothing
;; redeems sends a supplier's answer to an address nobody opens, which is worse
;; than no token at all. So with no inbound mailbox the reply goes to the person
;; who sent the message, and with one it goes to `reply+<token>@<domain>`.
(define (inbound-reply-address conn from-domain raw-token sender-address)
  (if (inbound-consumer-on? conn "messages")
      (format "reply+~a@~a" raw-token from-domain)
      sender-address))

;; The poller's own record, so an operator can see that it ran and what it said.
(define (inbound-record-poll! conn ok? err)
  (query-exec conn
    (string-append "UPDATE inbound_mailbox SET last_poll_epoch = ?, last_poll_ok = ?, last_error = ? "
                   "WHERE id = ?")
    (now) (if ok? 1 0) (or err sql-null) INBOUND-ID))
