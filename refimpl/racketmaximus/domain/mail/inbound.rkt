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
;; THE CONSUMERS GATE THE DISPATCH, not only the reply address. A mailbox read for
;; bounces must not spend a reply token, and a mailbox read for replies must not
;; suppress a contact from a report nobody asked to be read — a switch an operator
;; turns off that still changes state is worse than no switch.
;;
;; THE MODE IS THE MECHANISM, NOT THE POLICY. `imap` is the shipped one because
;; `curl` in the closure speaks it and the platform already shells out to
;; binaries, so it adds no dependency and no daemon. `maildir` and `webhook` are
;; recorded as the alternatives and are NOT in the vocabulary until they are
;; implemented: a mode an operator can set and nothing reads is the thing a closed
;; vocabulary exists to prevent.
;;
;; THE PASSWORD IS A SEALED COLUMN and is listed in `CREDENTIAL-SECRETS` in the
;; same commit as its table, or `rewrap` cannot rotate it and every poll fails at
;; the first key rotation with an authentication error nobody can explain.
;;
;; THE POSITION IS (UIDVALIDITY, last_uid) AND IT IS WHY THIS CANNOT SKIP MAIL. A
;; poll reads every message newer than the stored UID rather than only the UNSEEN
;; ones, because a person who opens the mailbox in webmail marks mail seen and a
;; consumer that searched UNSEEN would never see it. When UIDVALIDITY changes the
;; UID space was reset, so the stored UID names a different message and the poller
;; re-syncs from the unseen set instead of trusting it. The first poll of a
;; freshly configured mailbox also uses the unseen set, because reading an archive
;; the operator did not mean to hand over is not a thing to do on a guess.

(require db-kit/portable
         racket/string
         json
         "../db/nulls.rkt"
         (only-in "../authz/authz.rkt" audit! principal-user-id hash-token)
         (only-in "../authz/sealed.rkt" define-sealed-column)
         (only-in "../db/id.rkt" new-id)
         (only-in "./dsn.rkt" dsn? dsn-reports dsn-report-recipient dsn-report-permanent?
                  dsn-report-status dsn-report-diagnostic)
         (only-in "./imap.rkt" imap-uidvalidity imap-unseen-uids imap-uids-after
                  imap-fetch imap-mark-seen)
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
         inbound-configured? inbound-consumer-on?
         inbound-record-poll! inbound-classify inbound-poll! inbound-messages
         inbound-delivery-id inbound-reply-token inbound-reply-address
         MAX-MESSAGES-PER-POLL MAX-INBOUND-BODY)

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

;; A TICK IS BOUNDED. The poller runs on the reaper seam, and every message is one
;; `curl` conversation with somebody else's server; without a cap, a mailbox that
;; accumulated a thousand messages would hold the seam for minutes and delay every
;; other sweep behind it. The rest wait for the next tick, which is what a clock is.
(define MAX-MESSAGES-PER-POLL 25)

;; The body the platform keeps. A hostile sender can put a gigabyte in a message
;; and the mailbox is not a document store; the tail is dropped and said so.
(define MAX-INBOUND-BODY 20000)

;; A header value is somebody else's text (SEC-12: bounded, and made printable).
(define MAX-HEADER-FIELD 500)

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

;; A value curl is handed must not carry a newline: its configuration format is
;; one directive per line, so a CR or LF in a field is a second directive. The
;; password is QUOTED AND ESCAPED in `imap.rkt`; this is the ceiling on what may
;; reach it at all.
(define (control-character-problem [label "a value"] [v ""])
  (and (string? v) (regexp-match? #px"[\r\n\0]" v)
       (format "~a must not contain a newline or a NUL" label)))

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
    ;; A MODE THAT READS A MAILBOX NEEDS A HOST, A PORT AND A FOLDER. `none` needs
    ;; none of them, and that is why the check is per mode rather than one shape for
    ;; every mode.
    [(and (equal? (hash-ref doc 'mode "none") "imap")
          (let ([h (hash-ref doc 'host #f)])
            (not (and (string? h) (regexp-match? #px"^[A-Za-z0-9][A-Za-z0-9._-]*$" h)))))
     "host must be a hostname for this mode"]
    [(and (equal? (hash-ref doc 'mode "none") "imap")
          (let ([p (hash-ref doc 'port #f)])
            (not (and (exact-integer? p) (> p 0) (< p 65536)))))
     "port must be 1-65535 for this mode"]
    [(let ([f (hash-ref doc 'folder "INBOX")])
       (and (not (and (string? f) (regexp-match? #px"^[A-Za-z0-9][A-Za-z0-9._/-]*$" f)))
            "folder must be a plain mailbox name (letters, digits, dot, dash, underscore, slash)"))
     => values]
    ;; A MAILBOX WITH NO USERNAME CANNOT AUTHENTICATE, so a mode that reads one
    ;; asks for it here rather than failing at the first poll with a server's own
    ;; words in `last_error`.
    [(and (equal? (hash-ref doc 'mode "none") "imap")
          (let ([u (hash-ref doc 'username #f)])
            (not (and (string? u) (not (string=? (string-trim u) ""))))))
     "username is required for this mode"]
    [(control-character-problem "username" (hash-ref doc 'username "")) => values]
    [(control-character-problem "password" (hash-ref doc 'password "")) => values]
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
;; A BAD DOCUMENT IS A USER ERROR, not a plain one: the dispatcher maps
;; `exn:fail:user?` to a 400 carrying the sentence, and a plain `error` becomes an
;; opaque 500. The route does not validate a second time — one home, so the API and
;; a plugin that requires this module are told the same thing.
(define (inbound-set! conn doc #:by [by #f])
  (define p (inbound-problem doc))
  (when p (raise-user-error 'inbound-mailbox "~a" p))
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

;; A CONSUMER IS ON ONLY WHEN SOMETHING READS THE MAILBOX. `active` plus a switch
;; on a mailbox whose mode is `none` is a consumer nothing polls, and a reply token
;; minted for it would send a supplier's answer to an address nobody opens — the
;; dead end the token was made conditional to avoid.
(define (inbound-consumer-on? conn consumer)
  (define m (inbound-ref conn))
  (and m (hash-ref m 'active)
       (not (equal? (hash-ref m 'mode) "none"))
       (eq? (hash-ref (hash-ref m 'consumers) (string->symbol consumer) #f) #t) #t))

;; THE REPLY ADDRESS IS DECIDED IN `external.rkt`, beside the token it names: the
;; row and the address have to be decided together, or a token is written that
;; nothing redeems. `inbound-consumer-on?` is the question it asks.

;; The poller's own record, so an operator can see that it ran and what it said.
;; `err` carries a problem AND the notes a successful poll wants to leave behind
;; (a message it could not classify, a mailbox it had to re-sync): one field an
;; operator reads beats a second column nothing draws.
(define (inbound-record-poll! conn ok? err)
  (query-exec conn
    (string-append "UPDATE inbound_mailbox SET last_poll_epoch = ?, last_poll_ok = ?, last_error = ? "
                   "WHERE id = ?")
    (now) (if ok? 1 0) (or err sql-null) INBOUND-ID))

;; (UIDVALIDITY, last UID) is the pair the whole thing turns on, so it is written
;; as one statement and cleared as one.
(define (inbound-record-position! conn uid uidvalidity)
  (query-exec conn
    (string-append "UPDATE inbound_mailbox SET last_uid = ?, uidvalidity = ? WHERE id = ?")
    (if (string? uid) uid (number->string uid)) (or uidvalidity sql-null) INBOUND-ID))

(define (inbound-clear-position! conn)
  (query-exec conn "UPDATE inbound_mailbox SET last_uid = NULL, uidvalidity = NULL WHERE id = ?"
              INBOUND-ID))


;; ---- what a message is --------------------------------------------------------
;; THREE ANSWERS, and the order matters: a DSN is checked first because a bounce is
;; the one message whose `To` is our own VERP address and whose body is machine
;; readable. A reply is a message addressed to a reply token. Anything else is
;; `other`: it cannot be attributed to a company, so it is not stored, and the poll
;; counts it and says so rather than passing over it in silence.
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

;; The WHOLE reply address, which is what names the delivery it answers: the row
;; stores the address it put in `Reply-To`, so a lookup by address resolves the
;; message back to the outbound one without a second column.
(define (inbound-reply-address raw)
  (define m (regexp-match #px"(?i:(?m:^To:.*?(reply\\+tk_[0-9a-f]+@[^\\s>,;\"]+)))" raw))
  (and m (regexp-replace #rx">+$" (cadr m) "")))

(define (header-of raw name)
  (define m (regexp-match (regexp (format "(?i:(?m:^~a:[ \\t]*(.*)))" (regexp-quote name))) raw))
  (and m (string-trim (cadr m))))

(define (body-of raw)
  (define m (regexp-match-positions #rx"\r?\n\r?\n" raw))
  (and m (substring raw (cdr (car m)) (string-length raw))))

;; Somebody else's words: bounded, and made printable, before they are stored or
;; shown. The body is CONTENT and stays verbatim apart from the ceiling.
(define (bounded-header raw name)
  (define v (header-of raw name))
  (and v (clip (printable v) MAX-HEADER-FIELD)))

(define (bounded-body raw)
  (define b (or (body-of raw) ""))
  (if (> (string-length b) MAX-INBOUND-BODY)
      (string-append (substring b 0 MAX-INBOUND-BODY)
                     "\n\n[the platform kept the first 20000 characters of this message]")
      b))

(define (raw-sha raw) (bytes->hex-lower (sha256 (string->bytes/utf-8 raw))))

(define (already-stored? conn sha)
  (positive? (query-value conn "SELECT COUNT(*) FROM inbound_messages WHERE raw_sha256 = ?" sha)))


;; ---- the poll ----------------------------------------------------------------
;; -> (hasheq 'seen n 'bounces n 'replies n 'quarantined n 'ignored n 'other n
;;            'failed n 'error <string or #f>).
;;
;; `#:fetch`, `#:mark-seen`, `#:uids` and `#:uidvalidity` are parameters so a test
;; can drive the dispatch without an IMAP server; the shipped path is `imap.rkt`.
(define (empty-result [err #f])
  (hasheq 'seen 0 'bounces 0 'replies 0 'quarantined 0 'ignored 0 'other 0 'failed 0 'error err))

(define (inbound-poll! conn #:fetch [fetch #f] #:mark-seen [mark-seen #f]
                       #:uids [uids #f] #:uidvalidity [uidvalidity #f])
  (define m (inbound-ref conn))
  (cond
    [(not (inbound-configured? conn)) (empty-result)]
    [(not (equal? (hash-ref m 'mode) "imap"))
     (empty-result "this mode has no poller yet")]
    [else
     (define full (hash-set m 'password (inbound-password conn)))
     (define fetch* (or fetch (lambda (uid) (imap-fetch full uid))))
     (define mark* (or mark-seen (lambda (uid) (imap-mark-seen full uid))))
     (define consumers (hash-ref m 'consumers))
     (define bounces-on? (eq? (hash-ref consumers 'bounces #f) #t))
     (define messages-on? (eq? (hash-ref consumers 'messages #f) #t))
     ;; A MUTABLE hash: `hasheq` is immutable and `hash-set!` refuses it.
     (define counts
       (make-hasheq (for/list ([k (in-list '(seen bounces replies quarantined ignored other failed))])
                      (cons k 0))))
     (define (bump! k) (hash-set! counts k (add1 (hash-ref counts k))))
     (define notes (box '()))
     (define (note! s) (set-box! notes (cons s (unbox notes))))
     (with-handlers ([exn:fail?
                      (lambda (e)
                        (define msg (string-append "poll failed: " (exn-message e)))
                        (inbound-record-poll! conn #f msg)
                        (hash-set! counts 'error msg)
                        counts)])
       ;; A TEST NAMES THE MESSAGES, AND MAY NAME THE GENERATION TOO, so the reset
       ;; below is reachable without an IMAP server.
       (define cur-uv (if uids uidvalidity (imap-uidvalidity full)))
       (define stored-uv (hash-ref m 'uidvalidity))
       (define reset? (and cur-uv stored-uv (not (equal? cur-uv stored-uv))))
       (when reset?
         ;; THE UID SPACE WAS RESET, so every stored UID names a different message
         ;; now: forget the position and re-sync rather than skip.
         (inbound-clear-position! conn)
         (note! "the mailbox's UIDVALIDITY changed, so the poller re-synced from the unseen set"))
       (define uids*
         (cond
           [uids uids]
           [else
            (define last (and (not reset?) (hash-ref m 'last_uid)))
            (if last (imap-uids-after full last) (imap-unseen-uids full))]))
       (for ([uid (in-list uids*)]
             #:break (>= (hash-ref counts 'seen) MAX-MESSAGES-PER-POLL))
         ;; A FETCH FAILURE ABORTS THE POLL AND LEAVES THE POSITION ALONE: a
         ;; message nobody read must not be stepped over by the position, so the
         ;; next tick reads it again. A message that PARSED and then failed to
         ;; handle is the other case, handled below: it is marked seen and
         ;; reported, because it would otherwise fail identically for ever and
         ;; block the mailbox behind it.
         (define raw (fetch* uid))
         (define kind (inbound-classify raw))
         (define outcome
           (with-handlers ([exn:fail?
                            (lambda (e)
                              (note! (format "uid ~a: ~a" uid
                                             (clip (printable (exn-message e)) 300)))
                              'failed)])
             (case kind
               [(dsn) (if bounces-on? (begin (inbound-handle-dsn! conn raw) 'dsn) 'ignored)]
               [(reply) (if messages-on? (inbound-handle-reply! conn raw) 'ignored)]
               [else 'other])))
         (bump! 'seen)
         (bump! (case outcome
                  [(dsn) 'bounces]
                  [(stored) 'replies]
                  [(quarantined) 'quarantined]
                  ;; an unknown reply address is a message that arrived and could not
                  ;; be attributed to anybody, which is the `other` count's meaning
                  [(unknown) 'other]
                  [(failed) 'failed]
                  [(ignored replay none) 'ignored]
                  [else 'other]))
         (when (eq? outcome 'unknown)
           (note! "a message addressed to an unknown reply address was not stored"))
         (when (eq? outcome 'other)
           (note! "a message that could not be attributed to a company was not stored"))
         (mark* uid)
         (when cur-uv (inbound-record-position! conn uid cur-uv)))
       (define note (string-join (reverse (unbox notes)) "; "))
       (inbound-record-poll! conn #t (if (string=? note "") #f note))
       (hash-set! counts 'error #f)
       counts)]))

;; A PERMANENT REPORT SUPPRESSES THE CONTACT, and a temporary one does not. The
;; delivery is found through the VERP address, so the report identifies the message
;; without parsing a body; the contact is the delivery's own, so a report about a
;; message this instance did not send is ignored rather than guessed at.
;;
;; THE REPORTED RECIPIENT IS CHECKED against the delivery's, because a DSN may
;; carry a block per recipient and only the address this delivery was sent to
;; identifies this message. A report that names somebody else is not evidence
;; about this contact.
(define (inbound-handle-dsn! conn raw)
  (define did (inbound-delivery-id raw))
  (when did
    (define row (query-maybe-row conn
                  "SELECT contact_id, org_id, team_id, recipient FROM email_deliveries WHERE id = ?" did))
    (when row
      (define contact (let ([v (vector-ref row 0)]) (and (not (sql-null? v)) v)))
      (define org (vector-ref row 1))
      (define team (let ([v (vector-ref row 2)]) (and (not (sql-null? v)) v)))
      (define rcpt (let ([v (vector-ref row 3)]) (and (string? v) (string-downcase v))))
      (for ([r (in-list (dsn-reports raw))])
        (define reported (let ([v (dsn-report-recipient r)])
                           (and (string? v) (string-downcase (string-trim v)))))
        (when (and contact
                   (dsn-report-permanent? r)
                   (or (not reported) (not rcpt) (string=? reported rcpt)))
          (define reason (or (dsn-report-diagnostic r)
                             (format "bounce ~a" (dsn-report-status r))))
          ;; The suppression is written as the SYSTEM: no person pressed anything,
          ;; and attributing it to whoever started the process would be a lie.
          ;; THE TEAM IS PASSED, because `audit-list` filters `WHERE team_id = ?` and
          ;; an entry with no team is invisible in every trail.
          (query-exec conn
            (string-append "UPDATE email_contacts SET status = 'suppressed', suppressed_reason = ?, "
                           "suppressed_epoch = ?, updated_epoch = ? WHERE id = ? AND org_id = ? "
                           "AND status <> 'suppressed'")
            (clip (printable reason) 400) (now) (now) contact org)
          (audit! conn #:action "email.contact.suppressed" #:actor-type "system"
                  #:actor-id "bounce" #:org-id org #:team-id (or team sql-null)
                  #:resource-type "email_contact" #:resource-id contact #:result "ok"
                  #:meta (jsexpr->string (hasheq 'delivery did
                                                 'status (dsn-report-status r)))))))
    'dsn))

;; A REPLY IS STORED, and the token is spent. The platform does not try to
;; understand the prose: it records who it came from and what it said, and the
;; product shows it. Raising an inbox item is the product's job, because the inbox
;; is a plugin and core may not require one.
;;
;; -> 'stored, 'quarantined, 'replay, 'unknown or 'none.
;;
;; THE SPEND IS THE UPDATE. `SELECT then UPDATE` would let two pollers both believe
;; they won, so the claim is `UPDATE ... WHERE used_at IS NULL RETURNING id` and the
;; message is stored only when a row comes back.
;;
;; A LATE REPLY IS KEPT AND MARKED, not dropped: an answer that arrived after the
;; month the token lives for is still an answer a person may be waiting for. It is
;; stored with `state = 'quarantined`, which is what tells the product it may show
;; it and may not act on it.
(define (inbound-handle-reply! conn raw)
  (define raw-token (inbound-reply-token raw))
  (cond
    [(not raw-token) 'none]
    [else
     (define h (hash-token (string-append "reply:" raw-token)))
     (define row (query-maybe-row conn
                   (string-append "SELECT id, contact_id, org_id, expires_at, used_at "
                                  "FROM email_action_tokens WHERE token_hash = ? AND purpose = 'reply'")
                   h))
     (cond
       [(not row) 'unknown]
       [else
        (define token-id (vector-ref row 0))
        (define contact (let ([v (vector-ref row 1)]) (and (not (sql-null? v)) v)))
        (define org (vector-ref row 2))
        (define expires (vector-ref row 3))
        (define used (vector-ref row 4))
        (define sha (raw-sha raw))
        ;; The delivery this reply answers, by the address the token was put in.
        ;; Its team is what makes the audit entry visible in a team's trail.
        (define team
          (let* ([addr (inbound-reply-address raw)]
                 [v (and addr (query-maybe-value conn
                             "SELECT team_id FROM email_deliveries WHERE reply_to = ?" addr))])
            (and v (not (sql-null? v)) v)))
        (define (store! state)
          (query-exec conn
            (string-append "INSERT INTO inbound_messages (id, org_id, contact_id, token_id, message_id, "
                           "from_address, subject, body, raw_sha256, received_epoch, state) "
                           "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)")
            (new-id) org contact token-id
            (or (bounded-header raw "Message-ID") sql-null)
            (or (bounded-header raw "From") sql-null)
            (or (bounded-header raw "Subject") sql-null)
            (bounded-body raw) sha (now) state))
        (cond
          [(already-stored? conn sha) 'replay]
          [(and (sql-null? used) (> expires (now)))
           (define won
             (call-with-transaction
              conn
              (lambda ()
                (and (query-maybe-value conn
                       (string-append "UPDATE email_action_tokens SET used_at = ? "
                                      "WHERE id = ? AND used_at IS NULL RETURNING id")
                       (now) token-id)
                     (begin
                       (store! "stored")
                       (audit! conn #:action "email.inbound.received" #:actor-type "system"
                               #:actor-id "inbound" #:org-id org #:team-id (or team sql-null)
                               #:resource-type "inbound_message" #:resource-id token-id
                               #:result "ok")
                       #t)))))
           (if won 'stored 'replay)]
          [else
           (store! "quarantined")
           'quarantined])])]))

;; The stored replies, newest first, for the product to show. `state` rides along
;; because a quarantined message may be shown and may not be acted on, and a
;; caller that cannot tell them apart will act on the wrong one.
(define (inbound-messages conn org #:limit [limit 100])
  (define lim (number->string (min 500 (max 1 limit))))
  (for/list ([r (in-list (query-rows conn
                          (string-append "SELECT id, contact_id, from_address, subject, body, "
                                         "received_epoch, state FROM inbound_messages WHERE org_id = ? "
                                         "ORDER BY received_epoch DESC, id DESC LIMIT " lim)
                          org))])
    (hasheq 'id (vector-ref r 0) 'contact_id (nz (vector-ref r 1))
            'from_address (nz (vector-ref r 2)) 'subject (nz (vector-ref r 3))
            'body (vector-ref r 4) 'received_epoch (vector-ref r 5)
            'state (vector-ref r 6))))
