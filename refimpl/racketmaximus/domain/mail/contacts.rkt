#lang racket/base

;; domain/mail/contacts.rkt — an external party, and the one thing that stops us
;; mailing them again.
;;
;; A CONTACT IS NOT A USER, and the difference is the whole reason this module
;; exists. `users` is somebody who can sign in; a broker, a supplier and a customer
;; cannot, and giving them a user row to hold an address would hand them a
;; credential they must never have. So a contact is its own row, scoped to a
;; company, and it never becomes a user implicitly.
;;
;; THE ADDRESS IS THE ERASURE SUBJECT. It lives here and on the delivery row and
;; nowhere else, and `contact-delete!` removes both. The audit log is chained,
;; exported and kept through an erasure (DEL-7), so no entry about a contact
;; carries the address — only the contact id, which is what the deletion removes.
;; That is the same rule the reset route states for an address a stranger typed
;; (`server/api/accounts.rkt`), applied to an address the company deliberately
;; recorded.
;;
;; SUPPRESSION IS A STATUS, NOT A SECOND TABLE. A suppression is a fact about this
;; contact, and a separate list would need its own erasure path and its own join.
;; It is written by a permanent refusal, a bounce report, a complaint, an operator,
;; or the recipient's own link, and it refuses at enqueue time — before a quota is
;; spent and before a row is written.
;;
;; THE LOCALE IS ON THE CONTACT because the composer runs in the delivery sweep
;; with no request, so the recipient is the only place a language can come from.
;; `users.locale` is the same idea for a person (migration 0018).

(require db-kit/portable
         racket/string
         json
         "../db/id.rkt"
         "../db/nulls.rkt"
         (only-in "../authz/authz.rkt" audit! principal-org-id principal-user-id principal-team-id)
         (only-in "./transport.rkt" mail-address-problem))

(provide CONTACT-STATUSES contact-status?
         contact-add! contact-get contact-list contact-by-address
         contact-suppress! contact-unsuppress! contact-delete!
         contact-address contact-locale contact-suppressed?)

;; A CLOSED VOCABULARY, checked by the writer. `suppressed` is the only state that
;; refuses a send; `active` is the ordinary one.
(define CONTACT-STATUSES '("active" "suppressed"))
(define (contact-status? s) (and (member s CONTACT-STATUSES) #t))

(define (now) (current-seconds))

(define COLS "id, org_id, address, name, org_name, locale, status, suppressed_reason, suppressed_epoch, created_by, created_epoch, updated_epoch")

(define (row->contact r)
  (hasheq 'id (vector-ref r 0)
          'org_id (vector-ref r 1)
          'address (vector-ref r 2)
          'name (nz (vector-ref r 3))
          'org_name (nz (vector-ref r 4))
          'locale (vector-ref r 5)
          'status (vector-ref r 6)
          'suppressed_reason (nz (vector-ref r 7))
          'suppressed_epoch (nz (vector-ref r 8))
          'created_by (nz (vector-ref r 9))
          'created_epoch (vector-ref r 10)
          'updated_epoch (vector-ref r 11)))

;; The caller's company, or an error. A contact belongs to a company rather than a
;; team, because the thing a company is protecting with an external send is its own
;; domain's reputation, which is one resource however many teams spend it.
(define (caller-org p)
  (or (principal-org-id p)
      (raise-user-error 'email-contacts "a contact belongs to a company, and this caller has none")))

;; -> the new contact's id. Refuses a bad address, an unknown locale shape, and a
;; duplicate within the company.
;;
;; THE DUPLICATE IS A REFUSAL RATHER THAN AN UPSERT, because the two cases are
;; different: adding a supplier twice is a mistake, and silently merging it would
;; hide the fact that somebody typed a different name for the same address.
(define (contact-add! conn p #:address address
                      #:name [name #f] #:org-name [org-name #f]
                      #:locale [locale "en"])
  (define org (caller-org p))
  ;; A USER ERROR, not a bare `error`: the dispatcher maps `exn:fail:user?` to a
  ;; 400 with the message and everything else to an opaque 500. A catch-all handler
  ;; in the route would turn a driver failure into a 400 carrying the database's own
  ;; words, which is #123's closed defect.
  (define problem (mail-address-problem address))
  (when problem (raise-user-error 'email-contacts "~a" problem))
  (when (and locale (not (regexp-match? #px"^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$" locale)))
    (raise-user-error 'email-contacts "locale must look like en, ja or es-419"))
  (define existing (query-maybe-value conn
                     "SELECT id FROM email_contacts WHERE org_id = ? AND lower(address) = lower(?)"
                     org address))
  (when existing
    (raise-user-error 'email-contacts "this company already has a contact at that address"))
  (define id (new-id))
  (define t (now))
  (query-exec conn
    (string-append "INSERT INTO email_contacts (id, org_id, address, name, org_name, locale, status, "
                   "created_by, created_epoch, updated_epoch) VALUES (?, ?, ?, ?, ?, ?, 'active', ?, ?, ?)")
    id org address (or name sql-null) (or org-name sql-null) locale
    (or (principal-user-id p) sql-null) t t)
  ;; THE ADDRESS IS NOT IN THE META. The log outlives an erasure, and a list of the
  ;; outside parties a company corresponds with is exactly what an erasure is for.
  ;; THE TEAM IS PASSED, because `audit-list` filters `WHERE team_id = ?` and an
  ;; entry with no team is invisible in every trail — the shape this tree has
  ;; recorded eight times.
  (audit! conn #:action "email.contact.added" #:actor-type "user"
          #:actor-id (principal-user-id p) #:org-id org #:team-id (principal-team-id p)
          #:resource-type "email_contact" #:resource-id id #:result "ok")
  id)

;; -> the contact, or #f. Scoped in the STATEMENT, so another company's id is a
;; miss rather than a refusal — the same shape `mail-deliveries` uses.
(define (contact-get conn p id)
  (define org (caller-org p))
  (define r (query-maybe-row conn
              (string-append "SELECT " COLS " FROM email_contacts WHERE id = ? AND org_id = ?")
              id org))
  (and r (row->contact r)))

(define (contact-by-address conn p address)
  (define org (caller-org p))
  (define r (query-maybe-row conn
              (string-append "SELECT " COLS " FROM email_contacts "
                             "WHERE org_id = ? AND lower(address) = lower(?)")
              org address))
  (and r (row->contact r)))

;; -> a list, newest first. `#:status` narrows to one state; absent means both.
(define (contact-list conn p #:status [status #f] #:limit [limit 200])
  (define org (caller-org p))
  (define lim (number->string (min 500 (max 1 limit))))
  (define-values (clause args)
    (if status
        (values " AND status = ?" (list org status))
        (values "" (list org))))
  (for/list ([r (in-list (apply query-rows conn
                                (string-append "SELECT " COLS " FROM email_contacts WHERE org_id = ?"
                                               clause " ORDER BY created_epoch DESC, id DESC LIMIT " lim)
                                args))])
    (row->contact r)))

;; Suppress, with the reason kept. A reason is required: "why is this address
;; blocked" is the question an operator asks, and a bare flag cannot answer it.
(define (contact-suppress! conn p id reason)
  (define org (caller-org p))
  (define t (now))
  (and (query-maybe-row conn
         (string-append "UPDATE email_contacts SET status = 'suppressed', suppressed_reason = ?, "
                        "suppressed_epoch = ?, updated_epoch = ? WHERE id = ? AND org_id = ? "
                        "AND status <> 'suppressed' RETURNING id")
         (or reason "suppressed by an operator") t t id org)
       (begin
         (audit! conn #:action "email.contact.suppressed" #:actor-type "user"
                 #:actor-id (principal-user-id p) #:org-id org #:team-id (principal-team-id p)
                 #:resource-type "email_contact" #:resource-id id #:result "ok")
         #t)))

;; A SUPPRESSION IS REVERSIBLE, and that is not a convenience. RFC 3464 records the
;; SMTP race that can produce a failure DSN for a message that was delivered, so a
;; single report is evidence of an attempt rather than proof of non-delivery.
(define (contact-unsuppress! conn p id)
  (define org (caller-org p))
  (and (query-maybe-row conn
         (string-append "UPDATE email_contacts SET status = 'active', suppressed_reason = NULL, "
                        "suppressed_epoch = NULL, updated_epoch = ? WHERE id = ? AND org_id = ? "
                        "AND status = 'suppressed' RETURNING id")
         (now) id org)
       (begin
         (audit! conn #:action "email.contact.unsuppressed" #:actor-type "user"
                 #:actor-id (principal-user-id p) #:org-id org #:team-id (principal-team-id p)
                 #:resource-type "email_contact" #:resource-id id #:result "ok")
         #t)))

;; THE ERASURE PATH. The contact, its tokens and its delivery rows go together,
;; because each of them carries the address or a credential that names the person.
;; The audit log keeps the fact that sends happened, without the address, which is
;; the one record that outlives the erasure by design.
;;
;; -> (hasheq 'tokens n 'deliveries n), or #f when the contact is not this
;; company's.
(define (contact-delete! conn p id)
  (define org (caller-org p))
  (define exists (query-maybe-value conn
                   "SELECT id FROM email_contacts WHERE id = ? AND org_id = ?" id org))
  (and exists
       (let* ([tokens (query-maybe-value conn
                        "SELECT COUNT(*) FROM email_action_tokens WHERE contact_id = ?" id)]
              [deliveries (query-maybe-value conn
                            "SELECT COUNT(*) FROM email_deliveries WHERE contact_id = ?" id)])
         ;; ONE TRANSACTION, because a failure between the three deletes leaves
         ;; half an erasure: the contact gone and its address still on a delivery
         ;; row, which is the one outcome an erasure must not produce.
         (call-with-transaction
          conn
          (lambda ()
            (query-exec conn "DELETE FROM email_action_tokens WHERE contact_id = ?" id)
            (query-exec conn "DELETE FROM email_deliveries WHERE contact_id = ?" id)
            (query-exec conn "DELETE FROM email_contacts WHERE id = ? AND org_id = ?" id org)
            (audit! conn #:action "email.contact.deleted" #:actor-type "user"
                    #:actor-id (principal-user-id p) #:org-id org #:team-id (principal-team-id p)
                    #:resource-type "email_contact" #:resource-id id #:result "ok"
                    #:meta (jsexpr->string (hasheq 'tokens (or tokens 0)
                                                   'deliveries (or deliveries 0))))))
         (hasheq 'tokens (or tokens 0) 'deliveries (or deliveries 0)))))

;; The two reads a sender needs, so a caller does not reach into the hash and
;; invent a default for a missing key.
(define (contact-address c) (hash-ref c 'address))
(define (contact-locale c) (hash-ref c 'locale "en"))
(define (contact-suppressed? c) (equal? (hash-ref c 'status "active") "suppressed"))
