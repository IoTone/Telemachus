#lang racket/base

;; server/api/contacts.rkt — the company plane's external parties, and the one
;; route that sends to one.
;;
;; THE PERMISSIONS ARE THE DESIGN. Reading the company's contacts is `org:read`;
;; adding, suppressing and deleting one is `org:manage`; SENDING is `org:mail`,
;; which is its own permission because it is the one that spends the company's
;; standing with the relays. `org_owner` holds it through `org:*`, `org_admin`
;; holds it by name, and `org_reader` does not hold it at all.
;;
;; THE SEND ROUTE TAKES A TEMPLATE AND IDS, NEVER TEXT. That is the whole safety
;; argument, and it is enforced in `domain/mail/external.rkt` rather than here, so
;; a plugin that requires the core module meets the same guard.
;;
;; EACH HANDLER IS TWO LAYERS: the route's own gate, then a plain function that
;; does the work. The nesting is what makes a Racket handler unreadable, and the
;; split is also what lets a test call the work without a request.

(provide ep-my-org-contacts ep-my-org-contact-add ep-my-org-contact
         ep-my-org-contact-update ep-my-org-contact-delete ep-my-org-mail)

(require racket/string
         db-kit/portable
         web-server/http
         json
         web-kit
         (only-in "../../domain/authz/authz.rkt" require-perm principal-org-id
                  exn:fail:forbidden?)
         "../../domain/orgs/orgs.rkt"
         "../../domain/mail/contacts.rkt"
         "../../domain/mail/templates.rkt"
         "../../domain/mail/external.rkt"
         "../kit.rkt")

;; The caller's company, or a 400. A contact belongs to a company, and an operator
;; with no company has no company plane to act in.
(define (caller-org p)
  (or (principal-org-id p)
      (err "this route is the company plane, and the caller belongs to no company" 400)))

(define (status-problem s)
  (and (not (and s (contact-status? s)))
       (format "status must be one of: ~a" (string-join CONTACT-STATUSES ", "))))

;; ---- the work, without a request -------------------------------------------
(define (list-contacts p status)
  (define problem (and status (status-problem status)))
  (when problem (err problem 400))
  (hasheq 'contacts (contact-list db-conn p #:status status)))

(define (add-contact p b)
  (define address (hash-ref b 'address #f))
  (cond
    [(not address) (err "address required" 400)]
    [else
     (with-handlers ([exn:fail? (lambda (e) (err (exn-message e) 400))])
       (define id (contact-add! db-conn p #:address address
                                #:name (hash-ref b 'name #f)
                                #:org-name (hash-ref b 'org_name #f)
                                #:locale (or (hash-ref b 'locale #f) "en")))
       (hasheq 'contact (contact-get db-conn p id)))]))

(define (one-contact p id)
  (define c (contact-get db-conn p id))
  (cond [(not c) (err "not found" 404)]
        [else (hasheq 'contact c)]))

;; Suppress or unsuppress. A suppression needs a reason, because "why is this
;; address blocked" is the question an operator asks and a bare flag cannot answer
;; it.
(define (set-contact-status p id b)
  (define status (hash-ref b 'status #f))
  (define problem (status-problem status))
  (cond
    [problem (err problem 400)]
    [(not (contact-get db-conn p id)) (err "not found" 404)]
    [(equal? status "suppressed")
     (void (contact-suppress! db-conn p id (hash-ref b 'reason #f)))
     (hasheq 'contact (contact-get db-conn p id))]
    [else
     (void (contact-unsuppress! db-conn p id))
     (hasheq 'contact (contact-get db-conn p id))]))

;; THE ERASURE. The contact, its tokens and its delivery rows go together, and the
;; reply says how many of each so an operator can see what was removed.
(define (erase-contact p id)
  (define r (contact-delete! db-conn p id))
  (cond [(not r) (err "not found" 404)]
        [else (hasheq 'ok #t 'erased r)]))

;; THE SEND. `{contact, template, data, link}` — and `data` is ids, never prose.
(define (send-external p b)
  (define contact (hash-ref b 'contact #f))
  (define template (hash-ref b 'template #f))
  (define link (hash-ref b 'link #f))
  (define data (let ([d (hash-ref b 'data #f)]) (if (hash? d) d (hasheq))))
  (cond
    [(not contact) (err "contact required" 400)]
    [(not template) (err "template required" 400)]
    [(not (and link (string? link))) (err "link required" 400)]
    [else
     (with-handlers ([exn:fail:forbidden? raise]
                     [exn:fail? (lambda (e) (err (exn-message e) 400))])
       (mail-external! db-conn p #:contact contact #:template template
                       #:data data #:link link))]))

;; ---- the routes -------------------------------------------------------------
(define (ep-my-org-contacts req)
  (with-mt req (lambda ()
    (with-auth req (lambda (p)
      (require-perm db-conn p "org:read")
      (json-response (list-contacts p (query-param req 'status #f))))))))

(define (ep-my-org-contact-add req)
  (with-mt req (lambda ()
    (with-auth req (lambda (p)
      (require-perm db-conn p "org:manage")
      (json-response (add-contact p (read-json-body req))))))))

(define (ep-my-org-contact req id)
  (with-mt req (lambda ()
    (with-auth req (lambda (p)
      (require-perm db-conn p "org:read")
      (json-response (one-contact p id)))))))

(define (ep-my-org-contact-update req id)
  (with-mt req (lambda ()
    (with-auth req (lambda (p)
      (require-perm db-conn p "org:manage")
      (json-response (set-contact-status p id (read-json-body req))))))))

(define (ep-my-org-contact-delete req id)
  (with-mt req (lambda ()
    (with-auth req (lambda (p)
      (require-perm db-conn p "org:manage")
      (json-response (erase-contact p id)))))))

(define (ep-my-org-mail req)
  (with-mt req (lambda ()
    (with-auth req (lambda (p)
      (require-perm db-conn p "org:mail")
      (json-response (send-external p (read-json-body req))))))))
