#lang racket/base

;; test/email-external-tests.rkt — a message to somebody who is not a user.
;;
;; The subject is the GUARDS, not the send. Each case below is one of the checks
;; `mail-external!` runs, in the order it runs them, because the order is the
;; design: a suppressed contact must cost no quota, a company over its budget must
;; cost no token row, and a duplicate must not become a second message.
;;
;; The last case drives a real SMTP conversation, because the two things that
;; differ on the wire for an external message are exactly the two a scripted test
;; would not see: the `Auto-Submitted` header is gone, and the envelope sender is
;; the VERP address a bounce comes back to.
;;
;;   raco test test/email-external-tests.rkt
;;   DATABASE_URL="postgres://…" raco test test/email-external-tests.rkt

(require rackunit db-kit/portable db-kit/migrate
         racket/string racket/list json racket/file racket/port racket/system net/base64
         "../domain/db/migrations.rkt"
         "db-fixture.rkt"
         "../domain/db/id.rkt"
         "../domain/authz/authz.rkt"
         "../domain/orgs/orgs.rkt"
         "../domain/quota/quota.rkt"
         "../domain/mail/transport.rkt"
         "../domain/mail/mail.rkt"
         "../domain/mail/contacts.rkt"
         "../domain/mail/templates.rkt"
         "../domain/mail/dkim.rkt"
         "../domain/mail/external.rkt"
         "../domain/mail/inbound.rkt"
         "../cli/telemachus-secrets.rkt"
         "mock-smtp.rkt")

(define PORT-EXT 8931)

;; A company with an org_admin (who holds `org:mail`), a plain member (who does
;; not), and a transport pointed at the mock relay.
;;
;; -> (values conn acme), where `acme` carries the org, the team and both
;; principals. Every case below starts here, so a case that needs a different
;; fixture says so rather than rebuilding the world.
(define (instance #:transport? [transport? #t])
  (define conn (fresh-db #:migrate? #f))
  (migrate! conn all-migrations)
  (define-values (root sys-team)
    (bootstrap! conn #:username "root" #:org-name "Instance" #:org-slug "system"
                #:team-name "Instance" #:team-slug "instance"))
  (define o (org-create! conn #f #:name "Acme" #:slug "acme"
                         #:owner-username "owner@acme"
                         #:team-name "Engineering" #:team-slug "engineering"))
  (define oid (hash-ref o 'org_id))
  (define eng (hash-ref o 'team_id))
  (define owner-p (user-principal conn (hash-ref o 'owner_user_id) eng))
  (define admin (hash-ref (org-attach-member! conn owner-p oid #:username "admin@acme"
                                              #:team eng #:role "admin" #:org-role "org_admin")
                          'user_id))
  (define member (hash-ref (org-attach-member! conn owner-p oid #:username "member@acme"
                                               #:team eng #:role "member")
                           'user_id))
  (when transport?
    (transport-set! conn (hasheq 'host "127.0.0.1" 'port PORT-EXT 'security "none"
                                 'from_address "tmach@example.test" 'from_name "TMach"
                                 'base_url "https://acme.test" 'active #t 'verify_tls #f)))
  (values conn
          (hasheq 'org oid 'team eng
                  'admin-p (user-principal conn admin eng)
                  'member-p (user-principal conn member eng))))

(define (send! conn p contact-id #:template [tpl "document_request"]
               #:data [data (hasheq 'what "the label artwork" 'subject_id "obj-1")])
  (mail-external! conn p #:contact contact-id #:template tpl
                  #:data data #:link "https://acme.test/d/abc"))

(define (delivery-count conn)
  (query-value conn "SELECT COUNT(*) FROM email_deliveries"))

(define (token-count conn)
  (query-value conn "SELECT COUNT(*) FROM email_action_tokens"))

;; ---- the happy path ---------------------------------------------------------
(test-case "a send queues one row with the company, the template and a reply address"
  (define-values (conn acme) (instance))
  (define p (hash-ref acme 'admin-p))
  (query-exec conn "UPDATE users SET email = 'admin@acme.test', email_verified_epoch = ? WHERE id = ?"
              (current-seconds) (principal-user-id p))
  (define cid (contact-add! conn p #:address "supplier@example.test" #:name "Sato" #:locale "ja"))
  (define r (send! conn p cid))
  (check-equal? (hash-ref r 'queued) 1)
  (check-equal? (hash-ref r 'reason) 'null)
  (define row (query-row conn
                (string-append "SELECT org_id, template, dedupe_key, reply_to, recipient, category, "
                               "subject, body FROM email_deliveries WHERE id = ?")
                (hash-ref r 'id)))
  (check-equal? (vector-ref row 0) (hash-ref acme 'org))
  (check-equal? (vector-ref row 1) "document_request")
  (check-equal? (vector-ref row 2) (format "~a|document_request|obj-1" cid))
  ;; NO INBOUND MAILBOX IS CONFIGURED, so the reply goes to the person who sent
  ;; the message rather than to a token nothing redeems.
  (check-equal? (vector-ref row 3) "admin@acme.test")
  (check-equal? (vector-ref row 4) "supplier@example.test")
  (check-equal? (vector-ref row 5) "external")
  ;; THE BODY CARRIES THE LINK AND THE SENDER, and it is in the CONTACT's
  ;; language: the composer runs with no request, so the recipient is the only
  ;; place a language can come from.
  (check-true (string-contains? (vector-ref row 7) "https://acme.test/d/abc"))
  ;; the SENDER's name, not the recipient's: the message says who is asking
  (check-true (string-contains? (vector-ref row 7) "admin@acme"))
  (check-true (string-contains? (vector-ref row 7) "Acme"))
  (check-true (string-contains? (vector-ref row 7) "書類") "the ja catalog was used")
  (close-db! conn))

;; ---- the reply address depends on whether anything reads the mailbox ---------
(test-case "with an inbound mailbox the reply address is the token, and without one it is the sender"
  (define-values (conn acme) (instance))
  (define p (hash-ref acme 'admin-p))
  (query-exec conn "UPDATE users SET email = 'admin@acme.test', email_verified_epoch = ? WHERE id = ?"
              (current-seconds) (principal-user-id p))
  (define cid (contact-add! conn p #:address "supplier@example.test" #:locale "en"))
  (define (reply-to-of r)
    (query-value conn "SELECT reply_to FROM email_deliveries WHERE id = ?" (hash-ref r 'id)))
  ;; no mailbox: the person
  (check-equal? (reply-to-of (send! conn p cid)) "admin@acme.test")
  ;; a mailbox with the message consumer on: the token
  (inbound-set! conn (hasheq 'mode "imap" 'host "imap.example.test" 'port 993
                             'security "tls" 'username "bounce@example.test"
                             'password "s3cret" 'folder "INBOX"
                             'consumers (hasheq 'bounces #t 'messages #t) 'active #t))
  (define r2 (send! conn p cid #:data (hasheq 'what "the second thing" 'subject_id "obj-2")))
  (define rt (reply-to-of r2))
  (check-true (string-prefix? rt "reply+tk_"))
  (check-true (string-suffix? rt "@example.test"))
  ;; AND THE RAW TOKEN IS STORED NOWHERE. The address is `reply+<raw>@domain`, so
  ;; the raw value is the local part between the `+` and the `@`; asserting the
  ;; whole address against `token_hash` would pass against code that stored the
  ;; token in the clear, because the two can never be equal.
  ;; `regexp-match`'s first element is the WHOLE match; the capture group is the
  ;; second. Taking the first would compare the address against a hash, which can
  ;; never be equal and would pass against code that stored the token in the clear.
  (define raw (cadr (regexp-match #px"^reply\\+([^@]+)@" rt)))
  (check-true (and raw #t))
  (check-equal? (query-value conn "SELECT COUNT(*) FROM email_action_tokens WHERE token_hash = ?" raw) 0
                "the raw token is not what is stored")
  (check-equal? (query-value conn "SELECT COUNT(*) FROM email_action_tokens WHERE token_hash = ?"
                              (hash-token (string-append "reply:" raw))) 1
                "the hash of the raw token is")
  (close-db! conn))

;; ---- the guards, in order ---------------------------------------------------
(test-case "a suppressed contact refuses before a quota is spent or a row is written"
  (define-values (conn acme) (instance))
  (define p (hash-ref acme 'admin-p))
  (define cid (contact-add! conn p #:address "gone@example.test"))
  (void (contact-suppress! conn p cid "550 5.1.1 user unknown"))
  (define r (send! conn p cid))
  (check-equal? (hash-ref r 'queued) 0)
  (check-equal? (hash-ref r 'reason) 'suppressed)
  (check-equal? (delivery-count conn) 0)
  (check-equal? (token-count conn) 0 "no token is minted for a message that will not be sent")
  (close-db! conn))

(test-case "no transport refuses rather than queueing a row that can only die"
  (define-values (conn acme) (instance #:transport? #f))
  (define p (hash-ref acme 'admin-p))
  (define cid (contact-add! conn p #:address "a@example.test"))
  (define r (send! conn p cid))
  (check-equal? (hash-ref r 'reason) 'no-transport)
  (check-equal? (delivery-count conn) 0)
  (close-db! conn))

(test-case "a second identical send is a duplicate, not a second message"
  (define-values (conn acme) (instance))
  (define p (hash-ref acme 'admin-p))
  (define cid (contact-add! conn p #:address "a@example.test"))
  (define first (send! conn p cid))
  (define second (send! conn p cid))
  (check-equal? (hash-ref first 'queued) 1)
  (check-equal? (hash-ref second 'queued) 0)
  (check-equal? (hash-ref second 'reason) 'duplicate)
  (check-equal? (hash-ref second 'id) (hash-ref first 'id))
  (check-equal? (delivery-count conn) 1)
  (close-db! conn))

(test-case "a team member without org:mail is refused"
  (define-values (conn acme) (instance))
  (define ap (hash-ref acme 'admin-p))
  (define mp (hash-ref acme 'member-p))
  (define cid (contact-add! conn ap #:address "a@example.test"))
  ;; `org:mail` is the company tier, which a team role cannot reach at all
  (check-false (can? conn mp "org:mail"))
  (check-exn exn:fail:forbidden? (lambda () (send! conn mp cid)))
  (check-equal? (delivery-count conn) 0)
  (close-db! conn))

(test-case "a company over its budget refuses with the quota, and writes no token"
  (define-values (conn acme) (instance))
  (define p (hash-ref acme 'admin-p))
  (define cid (contact-add! conn p #:address "a@example.test"))
  (set-limit! conn "org" (hash-ref acme 'org) MAIL-EXTERNAL-DIM 0 #:window "total")
  (define r (send! conn p cid))
  (check-equal? (hash-ref r 'reason) 'quota)
  (check-equal? (delivery-count conn) 0)
  (check-equal? (token-count conn) 0)
  (close-db! conn))

(test-case "an unknown template is refused rather than composed"
  (define-values (conn acme) (instance))
  (define p (hash-ref acme 'admin-p))
  (define cid (contact-add! conn p #:address "a@example.test"))
  (check-exn exn:fail? (lambda () (send! conn p cid #:template "free_text_for_a_stranger")))
  (check-equal? (delivery-count conn) 0)
  (close-db! conn))

(test-case "a template missing a key is refused rather than sent with a placeholder"
  (define-values (conn acme) (instance))
  (define p (hash-ref acme 'admin-p))
  (define cid (contact-add! conn p #:address "a@example.test"))
  (check-exn exn:fail?
             (lambda () (send! conn p cid #:data (hasheq 'subject_id "obj-1")))
             "a message reading 'Document request: {what}' is worse than none")
  (check-equal? (delivery-count conn) 0)
  (close-db! conn))

;; ---- the limiters -----------------------------------------------------------
(test-case "the per-contact limiter refuses the sixth message in the window"
  ;; CONTACT-MAX is 5. The limiter is in memory and per process, which is stated
  ;; rather than discovered: a second replica would double the ceiling.
  (define-values (conn acme) (instance))
  (define p (hash-ref acme 'admin-p))
  (define cid (contact-add! conn p #:address "a@example.test"))
  (for ([i (in-range 5)])
    (check-equal? (hash-ref (send! conn p cid #:data (hasheq 'what "x" 'subject_id (format "s~a" i)))
                            'queued)
                  1))
  (define sixth (send! conn p cid #:data (hasheq 'what "x" 'subject_id "s5")))
  (check-equal? (hash-ref sixth 'queued) 0)
  (check-equal? (hash-ref sixth 'reason) 'rate)
  (close-db! conn))

;; ---- a suppression stops a message that is already queued --------------------
(test-case "a suppression settles a pending row instead of letting it retry"
  ;; The enqueue-time check is not enough: a row retries for up to a day, and a
  ;; bounce that arrives while it is retrying is exactly the case the suppression
  ;; exists for.
  (define-values (conn acme) (instance))
  (define p (hash-ref acme 'admin-p))
  (define cid (contact-add! conn p #:address "gone@example.test" #:locale "en"))
  (define r (send! conn p cid))
  (check-equal? (hash-ref r 'queued) 1)
  (void (contact-suppress! conn p cid "550 5.1.1 user unknown"))
  (mock-clear!)
  (start-mock-smtp! #:port PORT-EXT)
  (check-equal? (mail-deliver-one! conn (hash-ref r 'id)) 'dead)
  (stop-mock-smtp!)
  (check-equal? (mock-message-count) 0 "nothing crossed the wire")
  (check-true (string-contains? (query-value conn "SELECT last_error FROM email_deliveries WHERE id = ?"
                                             (hash-ref r 'id))
                                "suppressed"))
  (close-db! conn))

;; ---- the wire ---------------------------------------------------------------
(test-case "an external message drops Auto-Submitted, carries Reply-To, and sends from the VERP address"
  (define-values (conn acme) (instance))
  (define p (hash-ref acme 'admin-p))
  ;; THE SENDER NEEDS AN ADDRESS FOR A REPLY TO REACH THEM, and with no inbound
  ;; mailbox that address IS the Reply-To: a reply token nothing redeems would send
  ;; a supplier's answer to an address nobody opens.
  (query-exec conn "UPDATE users SET email = 'admin@acme.test', email_verified_epoch = ? WHERE id = ?"
              (current-seconds) (principal-user-id p))
  (define cid (contact-add! conn p #:address "supplier@example.test" #:locale "en"))
  (mock-clear!)
  (start-mock-smtp! #:port PORT-EXT)
  (define r (send! conn p cid))
  (check-equal? (hash-ref r 'queued) 1)
  (define id (hash-ref r 'id))
  (check-equal? (mail-deliver-one! conn id) 'sent)
  (stop-mock-smtp!)
  (define m (mock-last-message))
  (check-true (and m #t) "the relay received the message")
  ;; THE ENVELOPE SENDER IS THE VERP ADDRESS, so a bounce names the delivery.
  (check-true (string-prefix? (mock-msg-from m) "bounce+")
              "the envelope sender is the VERP address")
  (check-true (string-contains? (mock-msg-from m) id))
  (define data (mock-msg-data m))
  (check-false (regexp-match? #px"(?i:Auto-Submitted:)" data)
               "an external message must not tell a filter not to reply")
  (check-true (regexp-match? #px"(?i:Reply-To: admin@acme\\.test)" data)
              "and a reply reaches the person who sent it, because no mailbox is read")
  (check-true (regexp-match? #px"(?i:Message-ID: <)" data))
  (close-db! conn))

(test-case "a configured DKIM key puts a signature on the wire"
  ;; THE DEFECT THIS CATCHES: `dkim-configured?` asked the transport hash for
  ;; `dkim_key`, which `transport-ref` never carries, so signing was inert while
  ;; every test of the signer passed. This drives the real send path.
  (define-values (conn acme) (instance))
  (define p (hash-ref acme 'admin-p))
  (define dir (make-temporary-file "tmach-dkim-e2e-~a" 'directory))
  (define key (build-path dir "k.pem"))
  (define pub (build-path dir "pub.pem"))
  (define-values (proc out in err)
    (subprocess #f #f #f (find-executable-path "openssl") "genrsa" "-out" (path->string key) "2048"))
  (close-output-port in) (void (port->string out)) (void (port->string err)) (subprocess-wait proc)
  (check-equal? (subprocess-status proc) 0)
  (define-values (pproc pout pin perr)
    (subprocess #f #f #f (find-executable-path "openssl") "rsa" "-in" (path->string key)
                "-pubout" "-out" (path->string pub)))
  (close-output-port pin) (void (port->string pout)) (void (port->string perr)) (subprocess-wait pproc)
  (check-equal? (subprocess-status pproc) 0)
  (transport-set! conn (hasheq 'host "127.0.0.1" 'port PORT-EXT 'security "none"
                               'from_address "tmach@example.test" 'from_name "TMach"
                               'base_url "https://acme.test" 'active #t 'verify_tls #f
                               'dkim_selector "tmach" 'dkim_key (file->string key)))
  (define cid (contact-add! conn p #:address "supplier@example.test" #:locale "en"))
  (mock-clear!)
  (start-mock-smtp! #:port PORT-EXT)
  (define r (send! conn p cid))
  (check-equal? (mail-deliver-one! conn (hash-ref r 'id)) 'sent)
  (stop-mock-smtp!)
  (define data (mock-msg-data (mock-last-message)))
  (check-true (regexp-match? #px"(?i:DKIM-Signature: v=1; a=rsa-sha256; c=relaxed/relaxed; d=example\\.test; s=tmach;)"
                              data)
              "the message carries a signature naming the From domain and the selector")
  (check-true (regexp-match? #px"(?i:; bh=[A-Za-z0-9+/=]{20,})" data) "and a body hash")
  (check-true (regexp-match? #px"(?i:; b=[A-Za-z0-9+/=]{40,})" data) "and a signature")
  ;; AND THE SIGNATURE VERIFIES AGAINST THE MESSAGE AS RECEIVED. Reading the header
  ;; for its shape proves only that a string was composed; a signature over a
  ;; header block that differs from the one sent — a Message-ID added after
  ;; signing, a header inserted in between — verifies perfectly in isolation and
  ;; never at a receiver. This is the assertion that would have caught the inert
  ;; signer even if the key had been passed the wrong way.
  (define lines (string-split (string-replace data "\r\n" "\n") "\n"))
  (define blank (for/first ([l (in-list lines)] [i (in-naturals)] #:when (string=? l "")) i))
  (define hdr (string-join (take lines blank) "\r\n"))
  (define body-lines (drop lines (add1 blank)))
  (check-equal? (cadr (regexp-match #px"(?i:bh=([A-Za-z0-9+/=]+))" hdr))
                (dkim-body-hash body-lines)
                "the body hash in the header is the hash of the body that was sent")
  (define-values (input _unsigned) (dkim-signing-input hdr body-lines "example.test" "tmach"))
  (define sig (build-path dir "sig.bin"))
  (define input-file (build-path dir "input.txt"))
  (call-with-output-file sig #:exists 'replace
    (lambda (o) (write-bytes (base64-decode (string->bytes/utf-8 (cadr (regexp-match #px"(?i:; b=([A-Za-z0-9+/=]+))" hdr)))) o)))
  (call-with-output-file input-file #:exists 'replace
    (lambda (o) (write-bytes (string->bytes/utf-8 input) o)))
  (define-values (vproc vout vin verr)
    (subprocess #f #f #f (find-executable-path "openssl") "dgst" "-sha256" "-verify"
                (path->string pub) "-signature" (path->string sig) (path->string input-file)))
  (close-output-port vin)
  (define vres (port->string vout))
  (define verrs (port->string verr))
  (subprocess-wait vproc)
  (check-equal? (subprocess-status vproc) 0 (string-append "openssl refused the wire signature: " verrs))
  (check-true (string-contains? vres "Verified OK"))
  (delete-directory/files dir)
  (close-db! conn))

;; ---- what the deploy publishes ----------------------------------------------
;; THE PRIVATE KEY IS A SEALED COLUMN NOTHING READS BUT THE SIGNER, so the public
;; half is unobtainable by hand: an operator who cannot print the record holds a
;; signature nobody can verify, which is the same as no signature at all.
(test-case "the operator can print the record the signer actually uses"
  (define-values (conn acme) (instance))
  (define dir (make-temporary-file "tmach-dkim-dns-~a" 'directory))
  (define key (build-path dir "k.pem"))
  (define-values (proc out in err)
    (subprocess #f #f #f (find-executable-path "openssl") "genrsa" "-out" (path->string key) "2048"))
  (close-output-port in) (void (port->string out)) (void (port->string err)) (subprocess-wait proc)
  (check-equal? (subprocess-status proc) 0)
  (transport-set! conn (hasheq 'host "127.0.0.1" 'port PORT-EXT 'security "none"
                               'from_address "tmach@example.test" 'from_name "TMach"
                               'base_url "https://acme.test" 'active #t 'verify_tls #f
                               'dkim_selector "tmach" 'dkim_key (file->string key)))
  (define rec (dkim-record conn))
  (check-true (string-prefix? rec "tmach._domainkey.example.test. IN TXT \"v=DKIM1; k=rsa; p=")
              "the record names the selector and the From domain the signer uses")
  (check-false (string-contains? rec "-----") "and carries no PEM armour")
  ;; THE DOMAIN FOLLOWS `dkim_domain` WHEN IT IS SET, because that is what the
  ;; signature's `d=` uses; a record published under a different name verifies
  ;; nothing.
  (void (transport-set! conn (hasheq 'host "127.0.0.1" 'port PORT-EXT 'security "none"
                                    'from_address "tmach@mail.example.test" 'from_name "TMach"
                                    'base_url "https://acme.test" 'active #t 'verify_tls #f
                                    'dkim_selector "tmach" 'dkim_key (file->string key)
                                    'dkim_domain "example.test")))
  (check-true (string-prefix? (dkim-record conn) "tmach._domainkey.example.test. IN TXT "))
  (delete-directory/files dir)
  (close-db! conn))
