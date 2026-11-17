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
         (only-in "../authz/sealed.rkt" define-sealed-column)
         (only-in "../authz/authz.rkt" hash-token)
         (only-in "../db/id.rkt" new-id)
         (only-in "./dsn.rkt" dsn? dsn-reports dsn-report-recipient dsn-report-permanent?
                  dsn-report-status dsn-report-diagnostic)
         (only-in "./imap.rkt" imap-available? imap-uidvalidity imap-unseen-uids imap-fetch
                  imap-mark-seen)
         (only-in "./contacts.rkt" contact-suppress!)
         (only-in "./transport.rkt" clip printable)
         sha2-kit)

;; THE PASSWORD IS A SEALED COLUMN, and it is listed in `CREDENTIAL-SECRETS` in the
;; same commit as its table — a sealed column `rewrap` does not walk is silently
;; unrotatable, and here that means every poll fails at the first key rotation with
;; an authentication error nobody can explain.
(define-sealed-column "inbound_mailbox.password" (seal-password unseal-password) (id) #:credential)

(provide INBOUND-MODES inbound-mode? INBOUND-CONSUMERS inbound-consumer?
         inbound-ref inbound-set! inbound-clear! inbound-problem inbound-password
         inbound-configured? inbound-consumer-on? inbound-reply-address
         inbound-record-poll! inbound-classify inbound-poll! inbound-messages
         inbound-delivery-id inbound-reply-token)

;; `none` is a mode rather than an absent row, so "configured but off" and "never
;; configured" are one state and the console has one thing to draw.
;; ONLY THE MODES THAT EXIST. `maildir` and `webhook` are the two the design
;; records as the alternatives, and offering them before they are implemented is
;; the thing a closed vocabulary is supposed to prevent: an operator would set one
;; and nothing would read the mailbox.
(define INBOUND-MODES '("none" "imap"))
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
    [(and (equal? (hash-ref doc 'mode "none") "imap")
          (let ([h (hash-ref doc 'host #f)])
            (not (and (string? h) (regexp-match? #px"^[A-Za-z0-9][A-Za-z0-9._-]*$" h)))))
     "host must be a hostname for this mode"]
    [(and (equal? (hash-ref doc 'mode "none") "imap")
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
(define (inbound-clear! conn #:by [by #f])
  (query-exec conn "DELETE FROM inbound_mailbox WHERE id = ?" INBOUND-ID)
  ;; THE AUDIT IS HERE, not only in the route: a plugin may require this module,
  ;; and a delete that leaves no record is the one an operator is asked about.
  (audit! conn #:action "instance.inbound.cleared" #:actor-type "user"
          #:actor-id (or by sql-null) #:resource-type "inbound_mailbox"
          #:resource-id INBOUND-ID #:result "ok"))

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


;; ---- what a message is --------------------------------------------------------
;; THREE ANSWERS, and the order matters: a DSN is checked first because a bounce is
;; the one message whose `To` is our own VERP address and whose body is machine
;; readable. A reply is a message addressed to a reply token. Anything else is
;; `other`, and it is stored rather than dropped — an operator who points the
;; mailbox at the wrong folder should be able to see that.
(define (inbound-classify raw)
  (cond
    [(dsn? raw) 'dsn]
    [(inbound-reply-token raw) 'reply]
    [else 'other]))

;; The delivery id out of the VERP address the report was sent to. `bounce+<id>@`
;; is the envelope sender of the original message, so the report's `To` names it.
(define (inbound-delivery-id raw)
  (define m (regexp-match #px"(?i:(?m:^To:.*?bounce\\+([0-9a-f-]{36})@))" raw))
  (and m (cadr m)))

;; The raw reply token out of `reply+<token>@`. The token is what authorizes the
;; message, so the `From` header is only ever informational.
(define (inbound-reply-token raw)
  (define m (regexp-match #px"(?i:(?m:^To:.*?reply\\+(tk_[0-9a-f]+)@))" raw))
  (and m (cadr m)))

(define (header-of raw name)
  (define m (regexp-match (regexp (format "(?i:(?m:^~a:[ \\t]*(.*)))" (regexp-quote name))) raw))
  (and m (string-trim (cadr m))))

(define (body-of raw)
  (define m (regexp-match-positions #rx"\r?\n\r?\n" raw))
  (and m (substring raw (cdr (car m)) (string-length raw))))

(define MAX-INBOUND-BODY 20000)

;; ---- the poll ----------------------------------------------------------------
;; -> (hasheq 'seen n 'bounces n 'replies n 'other n 'error <string or #f>).
;;
;; `#:fetch` and `#:mark-seen` are parameters so a test can drive the dispatch
;; without an IMAP server; the shipped path is `imap.rkt`.
(define (inbound-poll! conn #:fetch [fetch #f] #:mark-seen [mark-seen #f] #:uids [uids #f])
  (define m (inbound-ref conn))
  (cond
    [(not (inbound-configured? conn)) (hasheq 'seen 0 'bounces 0 'replies 0 'other 0 'error #f)]
    [(not (equal? (hash-ref m 'mode) "imap"))
     (hasheq 'seen 0 'bounces 0 'replies 0 'other 0 'error "this mode has no poller yet")]
    [else
     (define full (hash-set m 'password (inbound-password conn)))
     (define fetch* (or fetch (lambda (uid) (imap-fetch full uid))))
     (define mark* (or mark-seen (lambda (uid) (imap-mark-seen full uid))))
     (with-handlers ([exn:fail?
                      (lambda (e)
                        (define msg (string-append "poll failed: " (exn-message e)))
                        (inbound-record-poll! conn #f msg)
                        (hasheq 'seen 0 'bounces 0 'replies 0 'other 0 'error msg))])
       (define uids* (or uids (imap-unseen-uids full)))
       ;; A MUTABLE hash: `hasheq` is immutable and `hash-set!` refuses it.
       (define counts (make-hasheq (list (cons 'seen 0) (cons 'bounces 0)
                                         (cons 'replies 0) (cons 'other 0))))
       (for ([uid (in-list uids*)])
         (define raw (fetch* uid))
         (define kind (inbound-classify raw))
         (case kind
           [(dsn) (inbound-handle-dsn! conn raw)]
           [(reply) (inbound-handle-reply! conn raw)]
           [else (void)])
         (hash-set! counts 'seen (add1 (hash-ref counts 'seen)))
         (hash-set! counts (case kind [(dsn) 'bounces] [(reply) 'replies] [else 'other])
                    (add1 (hash-ref counts (case kind [(dsn) 'bounces] [(reply) 'replies] [else 'other]))))
         (mark* uid))
       (inbound-record-poll! conn #t #f)
       (hash-set! counts 'error #f)
       counts)]))

;; A PERMANENT REPORT SUPPRESSES THE CONTACT, and a temporary one does not. The
;; delivery is found through the VERP address, so the report identifies the message
;; without parsing a body; the contact is the delivery's own, so a report about a
;; message this instance did not send is ignored rather than guessed at.
(define (inbound-handle-dsn! conn raw)
  (define did (inbound-delivery-id raw))
  (when did
    (define row (query-maybe-row conn
                  "SELECT contact_id, org_id FROM email_deliveries WHERE id = ?" did))
    (when row
      (define contact (vector-ref row 0))
      (define org (vector-ref row 1))
      (for ([r (in-list (dsn-reports raw))])
        (when (and contact (dsn-report-permanent? r))
          (define reason (or (dsn-report-diagnostic r)
                             (format "bounce ~a" (dsn-report-status r))))
          ;; The suppression is written as the SYSTEM: no person pressed anything,
          ;; and attributing it to whoever started the process would be a lie.
          (query-exec conn
            (string-append "UPDATE email_contacts SET status = 'suppressed', suppressed_reason = ?, "
                           "suppressed_epoch = ?, updated_epoch = ? WHERE id = ? AND org_id = ? "
                           "AND status <> 'suppressed'")
            (clip (printable reason) 400) (now) (now) contact org)
          (audit! conn #:action "email.contact.suppressed" #:actor-type "system"
                  #:actor-id "bounce" #:org-id org
                  #:resource-type "email_contact" #:resource-id contact #:result "ok"
                  #:meta (jsexpr->string (hasheq 'delivery did
                                                 'status (dsn-report-status r)))))))))

;; A REPLY IS STORED, and the token is spent. The platform does not try to
;; understand the prose: it records who it came from and what it said, and the
;; product shows it. Raising an inbox item is the product's job, because the inbox
;; is a plugin and core may not require one.
(define (inbound-handle-reply! conn raw)
  (define raw-token (inbound-reply-token raw))
  (when raw-token
    (define h (hash-token (string-append "reply:" raw-token)))
    (define row (query-maybe-row conn
                  (string-append "SELECT id, contact_id, org_id, expires_at, used_at "
                                 "FROM email_action_tokens WHERE token_hash = ? AND purpose = 'reply'")
                  h))
    (when row
      (define token-id (vector-ref row 0))
      (define contact (vector-ref row 1))
      (define org (vector-ref row 2))
      (define expires (vector-ref row 3))
      (define used (vector-ref row 4))
      ;; A SPENT OR EXPIRED TOKEN IS REFUSED, and the message is not stored: the
      ;; token is the authorization, so a second message to the same address is a
      ;; replay rather than a reply.
      (when (and (sql-null? used) (> expires (now)))
        (define sha (bytes->hex-lower (sha256 (string->bytes/utf-8 raw))))
        (define body (let ([b (or (body-of raw) "")])
                       (if (> (string-length b) MAX-INBOUND-BODY)
                           (substring b 0 MAX-INBOUND-BODY)
                           b)))
        ;; THE TOKEN IS SPENT AND THE MESSAGE STORED IN ONE TRANSACTION, so a
        ;; failure cannot leave a spent token with no message or a message with a
        ;; token that can be spent again.
        (call-with-transaction
         conn
         (lambda ()
           (query-exec conn "UPDATE email_action_tokens SET used_at = ? WHERE id = ?" (now) token-id)
           (query-exec conn
             (string-append "INSERT INTO inbound_messages (id, org_id, contact_id, token_id, message_id, "
                            "from_address, subject, body, raw_sha256, received_epoch, state) "
                            "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, 'stored')")
             (new-id) org contact token-id (or (header-of raw "Message-ID") sql-null)
             (or (header-of raw "From") sql-null) (or (header-of raw "Subject") sql-null)
             body sha (now))
           (audit! conn #:action "email.inbound.received" #:actor-type "system"
                   #:actor-id "inbound" #:org-id org
                   #:resource-type "inbound_message" #:resource-id token-id #:result "ok")))))))

;; The stored replies, newest first, for the product to show.
(define (inbound-messages conn org #:limit [limit 100])
  (define lim (number->string (min 500 (max 1 limit))))
  (for/list ([r (in-list (query-rows conn
                          (string-append "SELECT id, contact_id, from_address, subject, body, "
                                         "received_epoch FROM inbound_messages WHERE org_id = ? "
                                         "ORDER BY received_epoch DESC, id DESC LIMIT " lim)
                          org))])
    (hasheq 'id (vector-ref r 0) 'contact_id (nz (vector-ref r 1))
            'from_address (nz (vector-ref r 2)) 'subject (nz (vector-ref r 3))
            'body (vector-ref r 4) 'received_epoch (vector-ref r 5))))
