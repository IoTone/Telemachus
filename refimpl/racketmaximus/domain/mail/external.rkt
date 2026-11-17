#lang racket/base

;; domain/mail/external.rkt — a message to somebody who is not a user.
;;
;; THE PRIMITIVE, AND EVERY GUARD ON IT IS HERE RATHER THAN IN A ROUTE. A plugin
;; may require a core module, so a route-level check would be a check a plugin
;; never meets. The order below is the order the guards have to run in, and each
;; one is before the thing it protects:
;;
;;   1. the permission (`org:mail`, the company tier, because the From identity is
;;      the instance's and the thing being spent is the company's standing);
;;   2. the contact, scoped to the caller's company;
;;   3. the suppression, BEFORE a quota is spent and before a row is written;
;;   4. the transport, because a row queued on an instance that cannot send is a
;;      pending delivery that will be retried ten times and die;
;;   5. the template, which is a closed registry — a caller names one, never text;
;;   6. the quota, at both tiers, and the two limiters;
;;   7. the dedupe key, so a double-click or a retry cannot queue the same message
;;      twice. The claim already prevents a double SEND of one row; this prevents
;;      a second ROW.
;;
;; WHAT IT DOES NOT DO: compose free text, name a recipient, or reach the
;; transport. The words come from `templates.rkt`, the recipient from the contact
;; row, and the sending from the queue that already exists.
;;
;; THE REPLY ADDRESS IS MINTED HERE, not by the caller, because it is the one
;; thing that makes an inbound reply resolvable without trusting a `From` header.
;; It is `reply+<token>@<the From domain>`, the token is 24 random bytes hashed at
;; rest, and the raw value exists only in the header of the message that carries
;; it. A reply to that address names the contact and the subject by lookup.

(require db-kit/portable
         racket/string
         json
         "../db/id.rkt"
         "../db/nulls.rkt"
         "../authz/authz.rkt"
         "../orgs/orgs.rkt"
         "../beta/antispam.rkt"
         "./transport.rkt"
         "./mail.rkt"
         "./contacts.rkt"
         "./templates.rkt"
         "./inbound.rkt")

(provide MAIL-EXTERNAL-DIM EXTERNAL-CATEGORY REPLY-TTL
         mail-external! external-reply-address)

;; Its own dimension, because a message is not a token and the abuse is not the
;; same: `mail.notifications` bounds a fan-out to a team's own people, and this
;; bounds a company's correspondence with the outside world.
(define MAIL-EXTERNAL-DIM "mail.external")

;; The category on the delivery row. A closed vocabulary of one, for now, and the
;; reason it is not `external:<template>` is that the template is its own column.
(define EXTERNAL-CATEGORY "external")

;; A month. Long enough for a supplier who reads their mail weekly, short enough
;; that a link in a forwarded message has expired by the time it is interesting to
;; somebody else.
(define REPLY-TTL (* 30 24 3600))

;; TWO LIMITERS AND NEITHER IS THE RESET'S. The resource here is a company's
;; standing with the relays, so the per-company budget is the one that matters and
;; the per-contact one stops a single address being hammered. In memory, per
;; process: a second replica would double the ceiling, which is stated rather than
;; discovered.
(define org-limiter (make-limiter))
(define contact-limiter (make-limiter))
(define ORG-MAX 60)
(define CONTACT-MAX 5)
(define LIMIT-WINDOW 3600)

(define (now) (current-seconds))

(define (org-name conn org-id)
  (let ([v (query-maybe-value conn "SELECT name FROM orgs WHERE id = ?" org-id)])
    (and v (not (sql-null? v)) v)))

(define (user-display conn user-id)
  (define r (query-maybe-row conn "SELECT display_name, username FROM users WHERE id = ?" user-id))
  (and r
       (let ([d (vector-ref r 0)] [u (vector-ref r 1)])
         (if (and d (not (sql-null? d)) (not (string=? d ""))) d u))))

;; The domain the instance speaks for, taken from the transport's From address —
;; the same rule `compose-message` uses for the Message-ID, and the only domain it
;; may honestly claim.
(define (from-domain t)
  (define from (hash-ref t 'from_address))
  (define m (regexp-match #px"@(.+)$" from))
  (if m (cadr m) "localhost"))

;; -> the address a reply should go to, for a token that was just minted.
(define (external-reply-address t raw-token)
  (format "reply+~a@~a" raw-token (from-domain t)))

;; -> (hasheq 'queued 0|1 'reason <symbol> 'id <id or 'null>)
;;
;; A REFUSAL IS A VALUE, NOT AN EXCEPTION, for the three states that are ordinary:
;; a suppressed contact, no transport, and a duplicate. A caller that has to catch
;; an exception to learn "this address is blocked" will report it as a bug.
(define (mail-external! conn p #:contact contact-id #:template template-id
                        #:data data #:link link)
  (require-perm conn p "org:mail")
  (define org (or (principal-org-id p)
                  (error 'mail-external "a company is required to send outside it")))
  (define team (principal-team-id p))
  (define c (contact-get conn p contact-id))
  (unless c (error 'mail-external "no such contact"))
  (define (refuse reason [id 'null]) (hasheq 'queued 0 'reason reason 'id id))
  (cond
    [(contact-suppressed? c) (refuse 'suppressed)]
    [else
     (define t (transport-ref conn))
     (cond
       [(not (and t (hash-ref t 'active))) (refuse 'no-transport)]
       [(not (template? template-id)) (error 'mail-external "unknown template: ~a" template-id)]
       [else
        ;; THE QUOTA IS ASKED BEFORE ANYTHING IS COMPOSED, so a company that has
        ;; spent its budget costs neither a render nor a token row.
        (define q (tenant-quota-check/team conn team MAIL-EXTERNAL-DIM 1))
        (cond
          [(not (hash-ref q 'allowed)) (refuse 'quota)]
          [(not (limiter-allow? org-limiter org (now) #:max ORG-MAX #:window LIMIT-WINDOW))
           (refuse 'rate)]
          [(not (limiter-allow? contact-limiter contact-id (now) #:max CONTACT-MAX #:window LIMIT-WINDOW))
           (refuse 'rate)]
          [else
           (define subject-id (let ([v (hash-ref data 'subject_id #f)]) (and (string? v) v)))
           (define dedupe (format "~a|~a|~a" contact-id template-id (or subject-id "")))
           (define existing (query-maybe-value conn
                              (string-append "SELECT id FROM email_deliveries WHERE dedupe_key = ? "
                                             "AND status = 'pending'")
                              dedupe))
           (cond
             [existing (refuse 'duplicate existing)]
             [else
              ;; THE TOKEN IS MINTED BEFORE THE RENDER, because the render needs
              ;; the address it goes in. A render that then fails leaves an unused
              ;; token row, which expires; the alternative is composing a message
              ;; with no way to answer it.
              (define raw (random-token))
              (define token-id (new-id))
              (query-exec conn
                (string-append "INSERT INTO email_action_tokens (id, contact_id, org_id, purpose, "
                               "token_hash, subject_id, expires_at, created_epoch) "
                               "VALUES (?, ?, ?, 'reply', ?, ?, ?, ?)")
                token-id contact-id org (hash-token (string-append "reply:" raw))
                (or subject-id sql-null) (+ (now) REPLY-TTL) (now))
              ;; THE REPLY ADDRESS DEPENDS ON WHETHER ANYTHING READS THE MAILBOX.
              ;; A token nothing redeems sends a supplier's answer to an address
              ;; nobody opens, which is worse than no token at all, so with no
              ;; inbound mailbox the reply goes to the person who sent the message.
              (define sender-address
                (let ([v (query-maybe-value conn "SELECT email FROM users WHERE id = ?"
                                            (principal-user-id p))])
                  (and v (not (sql-null? v)) v)))
              (define reply-to
                (inbound-reply-address conn (from-domain t) raw sender-address))
              (define from-name (or (user-display conn (principal-user-id p)) "A colleague"))
              (define org-name* (or (org-name conn org) "your company"))
              (define full-data
                (hash-set* (if (hash? data) data (hasheq))
                           'link link 'from_name from-name 'org_name org-name*))
              (define-values (subject body)
                (with-locale (contact-locale c)
                  (lambda () (template-render template-id full-data))))
              (define id
                (mail-enqueue! conn
                               #:recipient (contact-address c)
                               #:category EXTERNAL-CATEGORY
                               #:subject subject #:body body
                               #:team team #:org org #:template template-id
                               #:dedupe dedupe #:contact contact-id #:reply-to reply-to))
              (cond
                [(not id) (refuse 'no-transport)]
                [else
                 (tenant-quota-record!/team conn team MAIL-EXTERNAL-DIM 1)
                 ;; THE ADDRESS IS NOT IN THE META. The log is chained, exported
                 ;; and kept through an erasure, and a list of the outside parties
                 ;; a company corresponds with is what an erasure is for.
                 (audit! conn #:action "email.external.queued" #:actor-type "user"
                         #:actor-id (principal-user-id p) #:team-id team #:org-id org
                         #:resource-type "email_delivery" #:resource-id id #:result "ok"
                         #:meta (jsexpr->string (hasheq 'template template-id
                                                        'contact contact-id)))
                 (hasheq 'queued 1 'reason 'null 'id id)])])])])]))
