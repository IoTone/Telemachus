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
(test-case "a mode that reads a mailbox needs a host and a port"
  (define c (fresh))
  (check-exn exn:fail? (lambda () (inbound-set! c (hasheq 'mode "imap" 'port 993))))
  (check-exn exn:fail? (lambda () (inbound-set! c (hasheq 'mode "imap" 'host "h.test"))))
  ;; `none` needs neither, and it is a mode rather than an absent row so the
  ;; console has one thing to draw
  (check-true (and (inbound-set! c (hasheq 'mode "none")) #t))
  (check-false (inbound-configured? c))
  (close-db! c))

(test-case "an unknown field and an unknown consumer are refused, not dropped"
  (define c (fresh))
  (check-exn exn:fail? (lambda () (inbound-set! c (hasheq 'mode "none" 'imap_host "h"))))
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

(test-case "active: false is still configured, and nothing is read"
  (define c (fresh))
  (void (inbound-set! c (imap-doc #:active #f)))
  (check-true (and (inbound-ref c) #t) "the configuration is kept")
  (check-false (inbound-configured? c) "but the poller does not run")
  (check-false (inbound-consumer-on? c "bounces"))
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

;; ---- the reply address ------------------------------------------------------
(test-case "the reply address is the token only when something reads the mailbox"
  (define c (fresh))
  ;; no mailbox: the person
  (check-equal? (inbound-reply-address c "example.test" "tk_abc" "person@example.test")
                "person@example.test")
  ;; a mailbox with the message consumer on: the token
  (void (inbound-set! c (imap-doc #:consumers (hasheq 'bounces #t 'messages #t))))
  (check-equal? (inbound-reply-address c "example.test" "tk_abc" "person@example.test")
                "reply+tk_abc@example.test")
  ;; the bounce consumer alone does not read replies, so the token would be a
  ;; dead end and the person's address is still the answer
  (void (inbound-set! c (imap-doc #:consumers (hasheq 'bounces #t 'messages #f))))
  (check-equal? (inbound-reply-address c "example.test" "tk_abc" "person@example.test")
                "person@example.test")
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
(test-case "a poll dispatches each message and marks it seen"
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
  (void (inbound-set! c (imap-doc #:consumers (hasheq 'bounces #t 'messages #t))))
  ;; a contact, a delivery and a reply token, as the send path would leave them
  (define cid (contact-add! c p #:address "gone@example.test"))
  (define did "00000000-0000-4000-8000-000000000000")
  (query-exec c
    (string-append "INSERT INTO email_deliveries (id, team_id, user_id, contact_id, org_id, recipient, "
                   "category, subject, body, status, attempts, created_epoch) "
                   "VALUES (?, ?, NULL, ?, ?, 'gone@example.test', 'external', 's', 'b', 'sent', 1, ?)")
    did eng cid oid (current-seconds))
  (define raw-token "tk_abc")
  (query-exec c
    (string-append "INSERT INTO email_action_tokens (id, contact_id, org_id, purpose, token_hash, "
                   "expires_at, created_epoch) VALUES (?, ?, ?, 'reply', ?, ?, ?)")
    (new-id) cid oid (hash-token (string-append "reply:" raw-token))
    (+ (current-seconds) 3600) (current-seconds))
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
  (check-equal? (sort seen string<?) '("1" "2" "3"))
  ;; the bounce suppressed the contact
  (check-equal? (hash-ref (contact-get c p cid) 'status) "suppressed")
  ;; the reply was stored, and the token spent
  (define msgs (inbound-messages c oid))
  (check-equal? (length msgs) 1)
  (check-equal? (hash-ref (car msgs) 'from_address) "supplier@example.test")
  (check-true (string-contains? (hash-ref (car msgs) 'body) "label artwork"))
  (check-true (exact-integer? (query-value c "SELECT used_at FROM email_action_tokens WHERE purpose = 'reply'")))
  ;; a second poll of the same message is refused by the spent token, and the
  ;; unique index on the raw hash is the second guard
  (define r2 (inbound-poll! c #:uids '("2") #:fetch (lambda (uid) (reply-raw)) #:mark-seen void))
  (check-equal? (hash-ref r2 'replies) 1)
  (check-equal? (length (inbound-messages c oid)) 1 "a replayed reply is not stored twice")
  (close-db! c))

(test-case "a poll with no mailbox does nothing, and says so"
  (define c (fresh))
  (define r (inbound-poll! c))
  (check-equal? (hash-ref r 'seen) 0)
  (check-false (hash-ref r 'error))
  (close-db! c))
