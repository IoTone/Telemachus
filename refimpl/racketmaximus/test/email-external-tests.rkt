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
         racket/string json
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
         "../domain/mail/external.rkt"
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
  (check-true (string-prefix? (vector-ref row 3) "reply+tk_"))
  (check-true (string-suffix? (vector-ref row 3) "@example.test"))
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

;; ---- the wire ---------------------------------------------------------------
(test-case "an external message drops Auto-Submitted, carries Reply-To, and sends from the VERP address"
  (define-values (conn acme) (instance))
  (define p (hash-ref acme 'admin-p))
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
  (check-true (regexp-match? #px"(?i:Reply-To: reply\\+tk_)" data)
              "and it carries the address a reply should reach")
  (check-true (regexp-match? #px"(?i:Message-ID: <)" data))
  (close-db! conn))
