#lang racket/base

;; test/email-contacts-tests.rkt — an external party, and the erasure that goes
;; with it.
;;
;; The subject here is not "can we store an address". It is the three properties
;; that make an external recipient safe to hold at all:
;;
;;   • a contact belongs to ONE company, and another company's id is a miss;
;;   • a suppression refuses a send, and it is reversible because a single failure
;;     report is evidence of an attempt rather than proof of non-delivery;
;;   • deleting a contact takes the address with it — the contact row, its tokens
;;     and its delivery rows — while the audit log keeps the fact that sends
;;     happened and never the address.
;;
;;   raco test test/email-contacts-tests.rkt
;;   DATABASE_URL="postgres://…" raco test test/email-contacts-tests.rkt

(require rackunit db-kit/portable db-kit/migrate
         racket/string json racket/vector
         "../domain/db/migrations.rkt"
         "db-fixture.rkt"
         "../domain/db/id.rkt"
         "../domain/authz/authz.rkt"
         "../domain/orgs/orgs.rkt"
         "../domain/mail/contacts.rkt")

(define (fresh)
  (define conn (fresh-db #:migrate? #f))
  (migrate! conn all-migrations)
  conn)

;; Two companies, each with an org_admin, so "another company's contact" is a real
;; case rather than a hypothetical one.
(define (instance)
  (define conn (fresh))
  (define-values (root sys-team)
    (bootstrap! conn #:username "root" #:org-name "Instance" #:org-slug "system"
                #:team-name "Instance" #:team-slug "instance"))
  (define (company name slug)
    (define o (org-create! conn #f #:name name #:slug slug
                           #:owner-username (string-append "owner@" slug)
                           #:team-name "Engineering" #:team-slug "engineering"))
    (define oid (hash-ref o 'org_id))
    (define eng (hash-ref o 'team_id))
    (define admin (hash-ref (org-attach-member! conn (user-principal conn (hash-ref o 'owner_user_id) eng)
                                                oid #:username (string-append "admin@" slug)
                                                #:team eng #:role "admin" #:org-role "org_admin")
                            'user_id))
    (hasheq 'org oid 'team eng 'admin-p (user-principal conn admin eng)))
  (values conn (user-principal conn root sys-team) (company "Acme" "acme") (company "Globex" "globex")))

;; EVERY TABLE, EVERY COLUMN, as text. The erasure's property is that the address
;; is GONE, and a test that names the three tables it knows about cannot catch a
;; column added later — which is exactly what `test/dump-leak-tests.rkt` exists for.
(define (tables conn)
  (if (postgres-fixture?)
      (query-list conn "SELECT table_name FROM information_schema.tables WHERE table_schema = current_schema()")
      (query-list conn "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'")))

(define (address-anywhere? conn address)
  (for/or ([t (in-list (tables conn))])
    (for/or ([r (in-list (query-rows conn (format "SELECT * FROM \"~a\"" t)))])
      (for/or ([v (in-vector r)])
        (and (string? v) (string-contains? v address))))))

(define (audit-meta conn action)
  (for/list ([r (in-list (query-rows conn
                          "SELECT meta FROM audit_log WHERE action = ? ORDER BY at_us" action))])
    (and (not (sql-null? (vector-ref r 0))) (vector-ref r 0))))

;; ---- the row ----------------------------------------------------------------
(test-case "a contact is added, read back and listed"
  (define-values (conn root acme globex) (instance))
  (define p (hash-ref acme 'admin-p))
  (define id (contact-add! conn p #:address "supplier@example.test"
                           #:name "Sato" #:org-name "Sato Seisakusho" #:locale "ja"))
  (define c (contact-get conn p id))
  (check-true (and c #t))
  (check-equal? (contact-address c) "supplier@example.test")
  (check-equal? (contact-locale c) "ja")
  (check-equal? (hash-ref c 'org_id) (hash-ref acme 'org))
  (check-equal? (hash-ref c 'status) "active")
  (check-false (contact-suppressed? c))
  (check-equal? (map (lambda (x) (hash-ref x 'id)) (contact-list conn p)) (list id))
  (close-db! conn))

(test-case "the same address twice in one company is refused, and case does not matter"
  (define-values (conn root acme globex) (instance))
  (define p (hash-ref acme 'admin-p))
  (void (contact-add! conn p #:address "Broker@Example.test"))
  (check-exn exn:fail?
             (lambda () (contact-add! conn p #:address "broker@example.test"))
             "a duplicate is a mistake, not an upsert")
  ;; the same address in ANOTHER company is a different contact
  (define g (hash-ref globex 'admin-p))
  (check-true (and (contact-add! conn g #:address "broker@example.test") #t))
  (close-db! conn))

(test-case "a bad address and a bad locale are refused before a row is written"
  (define-values (conn root acme globex) (instance))
  (define p (hash-ref acme 'admin-p))
  (check-exn exn:fail? (lambda () (contact-add! conn p #:address "not an address")))
  (check-exn exn:fail? (lambda () (contact-add! conn p #:address "a@b.test" #:locale "english please")))
  (check-equal? (length (contact-list conn p)) 0)
  (close-db! conn))

;; ---- the company boundary ---------------------------------------------------
(test-case "another company's contact is a miss, not a refusal"
  (define-values (conn root acme globex) (instance))
  (define gid (contact-add! conn (hash-ref globex 'admin-p) #:address "g@example.test"))
  (check-false (contact-get conn (hash-ref acme 'admin-p) gid))
  (check-false (contact-delete! conn (hash-ref acme 'admin-p) gid)
               "and it cannot be deleted from the wrong company")
  (check-true (and (contact-get conn (hash-ref globex 'admin-p) gid) #t))
  ;; and the two writes are scoped in their own statements, not only the read
  (check-false (contact-suppress! conn (hash-ref acme 'admin-p) gid "not mine"))
  (check-equal? (hash-ref (contact-get conn (hash-ref globex 'admin-p) gid) 'status) "active")
  (check-true (contact-suppress! conn (hash-ref globex 'admin-p) gid "mine"))
  (check-false (contact-unsuppress! conn (hash-ref acme 'admin-p) gid))
  (check-equal? (hash-ref (contact-get conn (hash-ref globex 'admin-p) gid) 'status) "suppressed")
  (close-db! conn))

;; ---- suppression ------------------------------------------------------------
(test-case "a suppression carries its reason and is reversible"
  (define-values (conn root acme globex) (instance))
  (define p (hash-ref acme 'admin-p))
  (define id (contact-add! conn p #:address "gone@example.test"))
  (check-true (contact-suppress! conn p id "550 5.1.1 user unknown"))
  (define c (contact-get conn p id))
  (check-equal? (hash-ref c 'status) "suppressed")
  (check-equal? (hash-ref c 'suppressed_reason) "550 5.1.1 user unknown")
  (check-true (contact-suppressed? c))
  ;; a second suppression is a no-op rather than an error, so a bounce report that
  ;; arrives twice does not fail
  (check-false (contact-suppress! conn p id "again"))
  (check-true (contact-unsuppress! conn p id))
  (check-false (contact-suppressed? (contact-get conn p id)))
  (check-equal? (hash-ref (contact-get conn p id) 'suppressed_reason) 'null)
  (close-db! conn))

(test-case "the list narrows by status"
  (define-values (conn root acme globex) (instance))
  (define p (hash-ref acme 'admin-p))
  (define a (contact-add! conn p #:address "a@example.test"))
  (define b (contact-add! conn p #:address "b@example.test"))
  (void (contact-suppress! conn p b "hard bounce"))
  (check-equal? (map (lambda (x) (hash-ref x 'id)) (contact-list conn p #:status "active")) (list a))
  (check-equal? (map (lambda (x) (hash-ref x 'id)) (contact-list conn p #:status "suppressed")) (list b))
  (check-equal? (length (contact-list conn p)) 2)
  (close-db! conn))

;; ---- erasure ----------------------------------------------------------------
(test-case "deleting a contact takes its tokens and its deliveries, and the audit keeps no address"
  (define-values (conn root acme globex) (instance))
  (define p (hash-ref acme 'admin-p))
  (define id (contact-add! conn p #:address "erase@example.test"))
  ;; a token and a delivery, as the send path would leave them
  (query-exec conn
    (string-append "INSERT INTO email_action_tokens (id, contact_id, org_id, purpose, token_hash, "
                   "expires_at, created_epoch) VALUES (?, ?, ?, 'reply', ?, ?, ?)")
    (new-id) id (hash-ref acme 'org) "hash-1" (+ (current-seconds) 3600) (current-seconds))
  (query-exec conn
    (string-append "INSERT INTO email_deliveries (id, team_id, user_id, contact_id, recipient, category, "
                   "subject, body, status, attempts, created_epoch) "
                   "VALUES (?, ?, NULL, ?, ?, 'external', 's', 'b', 'sent', 1, ?)")
    (new-id) (hash-ref acme 'team) id "erase@example.test" (current-seconds))
  (define r (contact-delete! conn p id))
  (check-equal? (hash-ref r 'tokens) 1)
  (check-equal? (hash-ref r 'deliveries) 1)
  (check-false (contact-get conn p id))
  (check-equal? (query-value conn "SELECT COUNT(*) FROM email_action_tokens WHERE contact_id = ?" id) 0)
  (check-equal? (query-value conn "SELECT COUNT(*) FROM email_deliveries WHERE contact_id = ?" id) 0)
  ;; THE LOG OUTLIVES THE ERASURE, so it must not hold the address. Every entry
  ;; this module wrote is checked, not just the deletion.
  ;; THE PROPERTY, not the mechanism: after the erasure the address appears in NO
  ;; table, in NO column. The three counts above prove the deletes ran; this proves
  ;; nothing was left behind.
  (check-false (address-anywhere? conn "erase@example.test")
               "the address must be gone from every table, not just the three we know about")
  (for ([action (in-list '("email.contact.added" "email.contact.deleted"))])
    (for ([m (in-list (audit-meta conn action))])
      (when m
        (check-false (regexp-match? #px"erase@example\\.test" m)
                     (format "~a must not carry the address" action)))))
  (close-db! conn))

(test-case "a caller with no company cannot hold a contact"
  (define-values (conn root acme globex) (instance))
  ;; `bootstrap!` puts the operator in an instance org, so the case is a user
  ;; created with no org at all — which is what `create-user!` does by default.
  (define loner (create-user! conn #:username "loner" #:password "correct horse battery staple"))
  (define lp (user-principal conn loner (hash-ref acme 'team)))
  (check-false (principal-org-id lp))
  (check-exn exn:fail?
             (lambda () (contact-add! conn lp #:address "x@example.test"))
             "a contact belongs to a company, and this caller has none")
  (close-db! conn))
