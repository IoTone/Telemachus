#lang racket/base

;; test/email-inbound-tests.rkt — the one optional mailbox, and the two consumers
;; that may read it.
;;
;; The subject is the CONFIGURATION, not the poller: an instance may run neither
;; consumer, one, or both, and the shipped state is `none` because an upgrade must
;; not start reading a mailbox. The cases below are the ones that make that safe —
;; a mode that needs a host and has none, a consumer nothing implements, a
;; password that must not be readable, and the only way back to the shipped state.
;;
;;   raco test test/email-inbound-tests.rkt
;;   DATABASE_URL="postgres://…" raco test test/email-inbound-tests.rkt

(require rackunit db-kit/portable db-kit/migrate
         racket/string json racket/runtime-path racket/file
         "../domain/db/migrations.rkt"
         "db-fixture.rkt"
         "../domain/authz/authz.rkt"
         "../domain/orgs/orgs.rkt"
         "../domain/db/id.rkt"
         "../domain/mail/contacts.rkt"
         "../domain/mail/inbound.rkt")

;; Anchored at the MODULE, not at the working directory: `nix build` runs the
;; suite from somewhere else, and the registry case below reads a source file.
(define-runtime-path here ".")
(define ROOT (simplify-path (build-path here 'up)))

(define (fresh)
  (define conn (fresh-db #:migrate? #f))
  (migrate! conn all-migrations)
  conn)

(define (imap-doc #:consumers [consumers (hasheq 'bounces #t 'messages #f)] #:active [active #t])
  (hasheq 'mode "imap" 'host "imap.example.test" 'port 993 'security "tls"
          'username "bounce@example.test" 'password "s3cret" 'folder "INBOX"
          'consumers consumers 'active active))

;; ---- the shipped state ------------------------------------------------------
(test-case "an instance ships with no mailbox, and nothing is read"
  (define c (fresh))
  (check-false (inbound-ref c))
  (check-false (inbound-configured? c))
  (check-false (inbound-consumer-on? c "bounces"))
  (check-false (inbound-consumer-on? c "messages"))
  (close-db! c))

;; ---- the modes --------------------------------------------------------------
(test-case "a mode that reads a mailbox needs a host, a port and a username"
  (define c (fresh))
  (check-exn exn:fail? (lambda () (inbound-set! c (hasheq 'mode "imap" 'port 993))))
  (check-exn exn:fail? (lambda () (inbound-set! c (hasheq 'mode "imap" 'host "h.test"))))
  (check-exn exn:fail? (lambda () (inbound-set! c (hasheq 'mode "imap" 'host "h.test" 'port 993))))
  (check-exn exn:fail? (lambda () (inbound-set! c (hasheq 'mode "imap" 'host "h.test" 'port 993
                                                          'username "  "))))
  ;; `none` needs neither, and it is a mode rather than an absent row so the
  ;; console has one thing to draw
  (check-true (and (inbound-set! c (hasheq 'mode "none")) #t))
  (check-false (inbound-configured? c))
  (close-db! c))

(test-case "an unknown field and an unknown consumer are refused, not dropped"
  (define c (fresh))
  ;; A BAD DOCUMENT IS A USER ERROR, because that is the exception the dispatcher
  ;; answers 400 with; a plain `error` would be an opaque 500 on the route an
  ;; operator configures the mailbox from.
  (check-exn exn:fail:user? (lambda () (inbound-set! c (hasheq 'mode "none" 'imap_host "h"))))
  (check-exn exn:fail:user? (lambda () (inbound-set! c (hasheq 'mode "imap" 'host "h.test" 'port 993
                                                          'folder "bad folder"))))
  (check-exn exn:fail?
             (lambda () (inbound-set! c (imap-doc #:consumers (hasheq 'bounces #t 'invoices #t)))))
  (check-false (inbound-ref c) "a refused write leaves no row")
  (close-db! c))

;; ---- the credential ---------------------------------------------------------
(test-case "the password is sealed at rest and never in a read"
  (define c (fresh))
  (define m (inbound-set! c (imap-doc)))
  (check-true (hash-ref m 'has_password))
  (check-false (hash-has-key? m 'password) "the read carries no password")
  (check-equal? (inbound-password c) "s3cret")
  ;; THE SEALING ITSELF IS `sealed-column-tests.rkt`'s SUBJECT, and with no
  ;; `TMACH_SECRET_KEY` the documented behaviour is to store the value in the
  ;; clear — which the transport's own test records. What matters here is the
  ;; REGISTRY: a sealed column outside `CREDENTIAL-SECRETS` is skipped by `rewrap`,
  ;; so a key rotation leaves it unopenable and nothing at runtime notices. A
  ;; static check, in the shape `feed-tests.rkt` uses for the same reason.
  (define src (file->string (build-path ROOT "cli" "telemachus-secrets.rkt")))
  (check-true (regexp-match? (regexp "\"inbound_mailbox\" +\"password\"") src)
              "inbound_mailbox.password must be in CREDENTIAL-SECRETS")
  ;; AN ABSENT PASSWORD LEAVES THE STORED ONE ALONE, so an edit to the folder
  ;; cannot silently clear the credential
  (void (inbound-set! c (hasheq 'mode "imap" 'host "imap.example.test" 'port 993
                                'security "tls" 'username "bounce@example.test"
                                'folder "Processed" 'consumers (hasheq 'bounces #t) 'active #t)))
  (check-equal? (inbound-password c) "s3cret")
  (check-equal? (hash-ref (inbound-ref c) 'folder) "Processed")
  (close-db! c))

;; ---- the consumers ----------------------------------------------------------
(test-case "the consumers are a closed vocabulary and both default to off"
  (define c (fresh))
  (define m (inbound-set! c (imap-doc #:consumers (hasheq))))
  (check-false (hash-ref (hash-ref m 'consumers) 'bounces))
  (check-false (hash-ref (hash-ref m 'consumers) 'messages))
  (check-false (inbound-consumer-on? c "bounces"))
  (void (inbound-set! c (imap-doc #:consumers (hasheq 'bounces #t))))
  (check-true (inbound-consumer-on? c "bounces"))
  (check-false (inbound-consumer-on? c "messages"))
  (close-db! c))

;; A SWITCH ON A MAILBOX NOTHING POLLS IS OFF, because the reply address it would
;; turn on is an address nobody opens.
(test-case "a consumer cannot be on when the mode reads no mailbox"
  (define c (fresh))
  (void (inbound-set! c (hasheq 'mode "none" 'active #t
                                'consumers (hasheq 'bounces #t 'messages #t))))
  (check-false (inbound-consumer-on? c "messages"))
  (check-false (inbound-consumer-on? c "bounces"))
  (close-db! c))

(test-case "active: false is still configured, and nothing is read"
  (define c (fresh))
  (void (inbound-set! c (imap-doc #:active #f)))
  (check-true (and (inbound-ref c) #t) "the configuration is kept")
  (check-false (inbound-configured? c) "but the poller does not run")
  (check-false (inbound-consumer-on? c "bounces"))
  (close-db! c))

;; AN ABSENT `active` IS NOT "OFF". The route is a whole-document write, so an API
;; client that sends the fields it changed and omits this one would otherwise stop
;; the poller in silence — and mail arriving while nothing reads it is the one
;; failure an operator cannot see. Explicit `false` is the way to stop it.
(test-case "an absent active leaves the stored switch alone"
  (define c (fresh))
  (void (inbound-set! c (imap-doc)))
  (check-true (inbound-configured? c))
  (void (inbound-set! c (hasheq 'mode "imap" 'host "imap.example.test" 'port 993
                                'username "bounce@example.test"
                                'consumers (hasheq 'bounces #t))))
  (check-true (hash-ref (inbound-ref c) 'active) "a document without the field kept it on")
  (check-true (inbound-configured? c) "so the poller still runs")
  (check-true (inbound-consumer-on? c "bounces"))
  ;; and the explicit value is what turns it off
  (void (inbound-set! c (imap-doc #:active #f)))
  (check-false (inbound-configured? c))
  (close-db! c))

;; ---- the way back -----------------------------------------------------------
(test-case "delete is the only way back to the shipped state"
  (define c (fresh))
  (void (inbound-set! c (imap-doc)))
  (check-true (inbound-configured? c))
  (inbound-clear! c)
  (check-false (inbound-ref c))
  (check-false (inbound-configured? c))
  (close-db! c))

;; ---- what a message is ------------------------------------------------------
(define (dsn-raw #:to [to "bounce+00000000-0000-4000-8000-000000000000@example.test"])
  (string-append
   "From: MAILER-DAEMON@example.test\r\n"
   (format "To: ~a\r\n" to)
   "Subject: Undelivered Mail Returned to Sender\r\n"
   "Content-Type: multipart/report; report-type=delivery-status; boundary=\"B\"\r\n\r\n"
   "--B\r\nContent-Type: text/plain\r\n\r\nfailed\r\n"
   "--B\r\nContent-Type: message/delivery-status\r\n\r\n"
   "Reporting-MTA: dns; mx.example.test\r\n\r\n"
   "Final-Recipient: rfc822; gone@example.test\r\nAction: failed\r\nStatus: 5.1.1\r\n"
   "Diagnostic-Code: smtp; 550 user unknown\r\n\r\n--B--\r\n"))

(define (reply-raw #:to [to "reply+tk_abc@example.test"])
  (string-append
   "From: supplier@example.test\r\n"
   (format "To: ~a\r\n" to)
   "Subject: Re: Document request\r\n"
   "Message-ID: <r1@example.test>\r\n\r\n"
   "Here is the label artwork.\r\n"))

(test-case "a DSN, a reply and anything else are told apart"
  (check-equal? (inbound-classify (dsn-raw)) 'dsn)
  (check-equal? (inbound-classify (reply-raw)) 'reply)
  (check-equal? (inbound-classify "From: a@b.test\r\nTo: c@d.test\r\n\r\nhello\r\n") 'other))

(test-case "the delivery id and the reply token come out of the address"
  (check-equal? (inbound-delivery-id (dsn-raw)) "00000000-0000-4000-8000-000000000000")
  (check-equal? (inbound-reply-token (reply-raw)) "tk_abc")
  (check-false (inbound-delivery-id (reply-raw)))
  (check-false (inbound-reply-token (dsn-raw))))

;; ---- the poll, with the fetch injected --------------------------------------
;; A company with a contact, a delivery sent to them and the reply token that
;; delivery carries — the state the send path leaves behind. Every poll case below
;; starts here.
(define (mailbox-fixture #:consumers [consumers (hasheq 'bounces #t 'messages #t)])
  (define c (fresh))
  (define-values (root sys) (bootstrap! c #:username "root" #:org-name "I" #:org-slug "s"
                                        #:team-name "I" #:team-slug "i"))
  (define o (org-create! c #f #:name "Acme" #:slug "acme" #:owner-username "owner@acme"
                         #:team-name "E" #:team-slug "e"))
  (define oid (hash-ref o 'org_id))
  (define eng (hash-ref o 'team_id))
  (define admin (hash-ref (org-attach-member! c (user-principal c (hash-ref o 'owner_user_id) eng)
                                              oid #:username "admin@acme" #:team eng
                                              #:role "admin" #:org-role "org_admin")
                          'user_id))
  (define p (user-principal c admin eng))
  (void (inbound-set! c (imap-doc #:consumers consumers)))
  (define cid (contact-add! c p #:address "gone@example.test"))
  (define did "00000000-0000-4000-8000-000000000000")
  (query-exec c
    (string-append "INSERT INTO email_deliveries (id, team_id, user_id, contact_id, org_id, recipient, "
                   "category, subject, body, status, attempts, created_epoch, reply_to) "
                   "VALUES (?, ?, NULL, ?, ?, 'gone@example.test', 'external', 's', 'b', 'sent', 1, ?, ?)")
    did eng cid oid (current-seconds) (format "reply+tk_abc@example.test"))
  (define raw-token "tk_abc")
  (query-exec c
    (string-append "INSERT INTO email_action_tokens (id, contact_id, org_id, purpose, token_hash, "
                   "expires_at, created_epoch) VALUES (?, ?, ?, 'reply', ?, ?, ?)")
    (new-id) cid oid (hash-token (string-append "reply:" raw-token))
    (+ (current-seconds) 3600) (current-seconds))
  (values c oid p cid did))

(test-case "a poll dispatches each message and marks it seen"
  (define-values (c oid p cid did) (mailbox-fixture))
  (define seen '())
  (define r (inbound-poll! c
                           #:uids '("1" "2" "3")
                           #:fetch (lambda (uid) (case (string->number uid)
                                                   [(1) (dsn-raw)]
                                                   [(2) (reply-raw)]
                                                   [else "From: a@b.test\r\nTo: c@d.test\r\n\r\nx\r\n"]))
                           #:mark-seen (lambda (uid) (set! seen (cons uid seen)))))
  (check-false (hash-ref r 'error) (format "poll error: ~a" (hash-ref r 'error)))
  (check-equal? (hash-ref r 'seen) 3)
  (check-equal? (hash-ref r 'bounces) 1)
  (check-equal? (hash-ref r 'replies) 1)
  (check-equal? (hash-ref r 'other) 1)
  (check-equal? (hash-ref r 'failed) 0)
  (check-equal? (sort seen string<?) '("1" "2" "3"))
  ;; the bounce suppressed the contact
  (check-equal? (hash-ref (contact-get c p cid) 'status) "suppressed")
  ;; the reply was stored, and the token spent
  (define msgs (inbound-messages c oid))
  (check-equal? (length msgs) 1)
  (check-equal? (hash-ref (car msgs) 'from_address) "supplier@example.test")
  (check-equal? (hash-ref (car msgs) 'state) "stored")
  (check-true (string-contains? (hash-ref (car msgs) 'body) "label artwork"))
  (check-true (exact-integer? (query-value c "SELECT used_at FROM email_action_tokens WHERE purpose = 'reply'")))
  ;; A REPLAY OF THE SAME MESSAGE IS NOT STORED AGAIN, and it is counted as
  ;; ignored rather than as a second reply.
  (define r2 (inbound-poll! c #:uids '("2") #:fetch (lambda (uid) (reply-raw)) #:mark-seen void))
  (check-equal? (hash-ref r2 'replies) 0)
  (check-equal? (hash-ref r2 'ignored) 1)
  (check-equal? (length (inbound-messages c oid)) 1 "a replayed reply is not stored twice")
  (close-db! c))

;; THE AUDIT ENTRY NAMES THE MESSAGE. `resource-type "inbound_message"` with a
;; token id is a record an operator cannot follow to what arrived.
(test-case "the audit entry for a stored reply names the message, not the credential"
  (define-values (c oid p cid did) (mailbox-fixture))
  (void (inbound-poll! c #:uids '("1") #:fetch (lambda (uid) (reply-raw)) #:mark-seen void))
  (define stored (car (inbound-messages c oid)))
  (define ids (for/list ([r (in-list (query-rows c
                                        "SELECT resource_id FROM audit_log WHERE action = ?"
                                        "email.inbound.received"))])
                (vector-ref r 0)))
  (check-equal? ids (list (hash-ref stored 'id)))
  (close-db! c))

(test-case "a poll with no mailbox does nothing, and says so"
  (define c (fresh))
  (define r (inbound-poll! c))
  (check-equal? (hash-ref r 'seen) 0)
  (check-false (hash-ref r 'error))
  (close-db! c))

;; ---- the two switches actually switch ---------------------------------------
;; A switch an operator turns off that still changes state is worse than no
;; switch, so each consumer gates its own half of the dispatch.
(test-case "bounces off means a report suppresses nobody, and messages off means a reply is not stored"
  (define-values (c oid p cid did) (mailbox-fixture #:consumers (hasheq 'bounces #f 'messages #t)))
  (define r (inbound-poll! c #:uids '("1" "2")
                           #:fetch (lambda (uid) (if (equal? uid "1") (dsn-raw) (reply-raw)))
                           #:mark-seen void))
  (check-equal? (hash-ref r 'bounces) 0)
  (check-equal? (hash-ref r 'ignored) 1)
  (check-equal? (hash-ref r 'replies) 1)
  (check-equal? (hash-ref (contact-get c p cid) 'status) "active"
                "a report nobody asked to be read must not suppress anybody")
  (close-db! c)

  (define-values (c2 oid2 p2 cid2 did2) (mailbox-fixture #:consumers (hasheq 'bounces #t 'messages #f)))
  (define r2 (inbound-poll! c2 #:uids '("1" "2")
                            #:fetch (lambda (uid) (if (equal? uid "1") (dsn-raw) (reply-raw)))
                            #:mark-seen void))
  (check-equal? (hash-ref r2 'bounces) 1)
  (check-equal? (hash-ref r2 'replies) 0)
  (check-equal? (hash-ref r2 'ignored) 1)
  (check-equal? (length (inbound-messages c2 oid2)) 0 "messages off means nothing is stored")
  (check-true (sql-null? (query-value c2 "SELECT used_at FROM email_action_tokens WHERE purpose = 'reply'"))
              "and the token is not spent by a consumer that is off")
  (close-db! c2))

;; ---- a late reply is kept, an unknown address is not -------------------------
(test-case "a reply that arrives after the token expired is quarantined, not dropped"
  (define-values (c oid p cid did) (mailbox-fixture))
  (query-exec c "UPDATE email_action_tokens SET expires_at = ? WHERE purpose = 'reply'"
              (- (current-seconds) 60))
  (define r (inbound-poll! c #:uids '("1") #:fetch (lambda (uid) (reply-raw)) #:mark-seen void))
  (check-equal? (hash-ref r 'quarantined) 1)
  (check-equal? (hash-ref r 'replies) 0)
  (define msgs (inbound-messages c oid))
  (check-equal? (length msgs) 1 "the answer is kept: a person may be waiting for it")
  (check-equal? (hash-ref (car msgs) 'state) "quarantined")
  (check-true (sql-null? (query-value c "SELECT used_at FROM email_action_tokens WHERE purpose = 'reply'"))
              "and a quarantined reply does not spend the token")
  (close-db! c))

(test-case "a message to a reply address nobody minted is counted, and the poll says so"
  (define-values (c oid p cid did) (mailbox-fixture))
  (define unknown (string-replace (reply-raw) "tk_abc" "tk_ffff"))
  (define r (inbound-poll! c #:uids '("1") #:fetch (lambda (uid) unknown) #:mark-seen void))
  (check-equal? (hash-ref r 'other) 1)
  (check-equal? (length (inbound-messages c oid)) 0)
  (check-true (string-contains? (or (hash-ref (inbound-ref c) 'last_error) "")
                                "unknown reply address")
              "an operator has to be able to see that something arrived and was not kept")
  (close-db! c))

;; ---- the position, and the two ways it could skip mail ----------------------
(test-case "the position is recorded, and a changed UIDVALIDITY re-syncs"
  (define-values (c oid p cid did) (mailbox-fixture))
  (void (inbound-poll! c #:uids '("4" "5") #:uidvalidity "100"
                       #:fetch (lambda (uid) (dsn-raw)) #:mark-seen void))
  (define m (inbound-ref c))
  (check-equal? (hash-ref m 'last_uid) "5")
  (check-equal? (hash-ref m 'uidvalidity) "100")
  ;; THE UID SPACE WAS RESET: every stored UID names a different message now, so the
  ;; position must not be trusted. The poller re-syncs from the unseen set, which is
  ;; what an injected empty `uids` stands for here — the assertion is that the pair
  ;; moved to the new generation rather than being carried over.
  (void (inbound-poll! c #:uids '("2") #:uidvalidity "200"
                       #:fetch (lambda (uid) (dsn-raw)) #:mark-seen void))
  (define m2 (inbound-ref c))
  (check-equal? (hash-ref m2 'uidvalidity) "200")
  (check-equal? (hash-ref m2 'last_uid) "2")
  (close-db! c))

(test-case "a message that cannot be fetched stops the poll without stepping over it"
  (define-values (c oid p cid did) (mailbox-fixture))
  (define marked '())
  (define r (with-handlers ([exn:fail? (lambda (e) #f)])
              (inbound-poll! c #:uids '("7" "8")
                             #:fetch (lambda (uid) (error 'imap "the server hung up"))
                             #:mark-seen (lambda (uid) (set! marked (cons uid marked))))))
  (check-true (and r #t) "the poll answers rather than raising at the sweep")
  (check-true (string-contains? (or (hash-ref r 'error) "") "the server hung up"))
  (check-equal? marked '() "nothing is marked seen, so the next tick reads it again")
  (check-equal? (hash-ref (inbound-ref c) 'last_uid) 'null
                "and the position is not advanced past it")
  (close-db! c))

(test-case "one tick is bounded, so a full mailbox cannot hold the reaper seam"
  (define-values (c oid p cid did) (mailbox-fixture))
  (define uids (for/list ([i (in-range 40)]) (number->string (add1 i))))
  (define r (inbound-poll! c #:uids uids
                           #:fetch (lambda (uid) "From: a@b.test\r\nTo: c@d.test\r\n\r\nx\r\n")
                           #:mark-seen void))
  (check-equal? (hash-ref r 'seen) MAX-MESSAGES-PER-POLL)
  (close-db! c))
