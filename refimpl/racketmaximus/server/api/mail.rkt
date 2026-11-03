#lang racket/base

;; server/api/mail.rkt — the email transport, the notification layers, and a
;; person's own address.
;;
;; THREE AUDIENCES AND THREE PERMISSIONS, which is the whole of the routing
;; decision here:
;;
;;   • the OPERATOR configures the transport and reads every delivery
;;     (`instance:manage`, `instance:read` for the reads — #124's split, so a
;;     monitoring credential can watch the dead-letter count without being able
;;     to rewrite the relay's password);
;;   • an ORG ADMIN may turn a category off for their own company (`org:manage`);
;;   • a PERSON owns their address and their own opt-outs, with NO permission at
;;     all — they are their own rows, which is the rule `GET /api/sessions` and
;;     `POST /api/profile` already follow.

(provide ep-email-transport-get ep-email-transport-put ep-email-transport-delete
         ep-email-transport-test
         ep-email-notify-get ep-email-notify-put
         ep-org-email-notify-get ep-org-email-notify-put
         ep-email-prefs-get ep-email-prefs-put
         ep-email-address-put ep-email-address-delete ep-email-address-verify
         ep-email-deliveries ep-email-delivery-get ep-email-delivery-redeliver
         ep-admin-email-deliveries ep-admin-email-delivery-get
         ep-admin-email-delivery-redeliver)

(require db-kit/portable
         web-kit
         json
         racket/string
         (only-in "../../domain/authz/authz.rkt" audit! principal-team-id principal-user-id
                  principal-org-id require-perm)
         (only-in "../../domain/mail/transport.rkt"
                  SECURITY-MODES transport-ref transport-set! transport-clear! transport-problem
                  mail-address-problem printable)
         (only-in "../../domain/mail/mail.rkt"
                  MAIL-CATEGORIES CATEGORY-EVENTS MAX-ATTEMPTS
                  instance-categories instance-categories-set!
                  org-categories org-categories-set!
                  user-pref-set! categories-for prefs-problem
                  mail-deliveries mail-delivery-get mail-redeliver! mail-send-test!
                  mail-enqueue-verification!)
         (only-in "../../domain/mail/addresses.rkt"
                  user-address-state address-claim! address-verify! address-clear!)
         "../kit.rkt")

;; ---- the transport ------------------------------------------------------------
;; The read carries the VOCABULARY beside the row — the security modes and the
;; categories — so a console card does not hold a second copy of a closed list
;; that core owns. `webhook-list`'s own shape, which answers `events` and
;; `max_attempts`.
(define (ep-email-transport-get req)
  (with-auth req (lambda (p)
    (require-perm db-conn p "instance:read")
    (define t (transport-ref db-conn))
    (json-response (hasheq 'transport (or t 'null)
                           'security_modes SECURITY-MODES
                           'categories MAIL-CATEGORIES
                           'max_attempts MAX-ATTEMPTS)))))

(define (ep-email-transport-put req)
  (with-auth req (lambda (p)
    (require-perm db-conn p "instance:manage")
    (define b (read-json-body req))
    (define problem (transport-problem b))
    (cond
      [problem (err problem 400)]
      [else
       (define t (transport-set! db-conn b #:by (principal-user-id p)))
       ;; THE PASSWORD IS NOT IN THE AUDIT ENTRY and neither is whether one was
       ;; sent: the log is chained, exported off the box and deliberately kept
       ;; through an erasure (DEL-7), so it outlives every other copy. The host,
       ;; the port and the From address are the configuration, which is what an
       ;; operator reading the trail came for.
       (audit! db-conn #:action "instance.email.configured" #:actor-type "user"
               #:actor-id (principal-user-id p) #:team-id (principal-team-id p)
               #:resource-type "email_transport" #:resource-id "default" #:result "ok"
               #:meta (jsexpr->string (hasheq 'host (hash-ref t 'host)
                                              'port (hash-ref t 'port)
                                              'security (hash-ref t 'security)
                                              'from_address (hash-ref t 'from_address)
                                              'active (hash-ref t 'active))))
       (json-response (hasheq 'transport t))]))))

;; The only way OFF at the instance tier, and RED-34 is why it exists: a `PUT`
;; with `active: false` is still a CONFIGURED transport, so without this there
;; would be no way back to the state the instance shipped in — and a smoke
;; fixture that left one behind would change what every later block was testing.
(define (ep-email-transport-delete req)
  (with-auth req (lambda (p)
    (require-perm db-conn p "instance:manage")
    (transport-clear! db-conn)
    (audit! db-conn #:action "instance.email.cleared" #:actor-type "user"
            #:actor-id (principal-user-id p) #:team-id (principal-team-id p)
            #:resource-type "email_transport" #:resource-id "default" #:result "ok")
    (json-response (hasheq 'ok #t)))))

;; #85's ping, for #85's reason: a transport nobody can test is a transport
;; nobody trusts, and an operator who has just typed a password needs to know
;; before anybody's notification depends on it.
;;
;; IT ANSWERS 200 EVEN WHEN THE RELAY REFUSED. The test ran; whether the relay
;; answered is in the body. A 502 here would be this instance claiming somebody
;; else's failure as its own — FEED-12's rule for the feed probe, and the reason
;; `ok` is a field rather than a status code.
(define (ep-email-transport-test req)
  (with-auth req (lambda (p)
    (require-perm db-conn p "instance:manage")
    (define b (read-json-body req))
    (define to (let ([v (hash-ref b 'to #f)]) (and (string? v) (string-trim v))))
    (cond
      [(not to) (err "send `to`: an address to send the test message to" 400)]
      [(mail-address-problem to) => (lambda (m) (err m 400))]
      [else
       (define-values (ok? e) (mail-send-test! db-conn to))
       (audit! db-conn #:action "instance.email.tested" #:actor-type "user"
               #:actor-id (principal-user-id p) #:team-id (principal-team-id p)
               #:resource-type "email_transport" #:resource-id "default"
               #:result (if ok? "ok" "error"))
       (json-response (hasheq 'ok ok? 'error (or e 'null)))]))))

;; ---- the instance and org layers ----------------------------------------------
;; `categories` is the stored document; `effective` is what it RESOLVES to for
;; the caller, which is the answer an admin reading this card actually wants —
;; and it carries `disabled_by`, so "why is this off" does not need three
;; documents diffed by hand (`features-for`'s rule).
(define (ep-email-notify-get req)
  (with-auth req (lambda (p)
    (require-perm db-conn p "instance:read")
    (json-response (hasheq 'categories (instance-categories db-conn)
                           'known MAIL-CATEGORIES
                           'events (for/hasheq ([kv (in-list CATEGORY-EVENTS)])
                                     (values (string->symbol (car kv)) (cdr kv)))
                           'effective (categories-for db-conn
                                                      #:user (principal-user-id p)
                                                      #:team (principal-team-id p)))))))

;; A WHOLE-DOCUMENT PUT, like the instance feature card's: there is no per-category
;; route at this tier, so a caller that sent only the switch that moved would wipe
;; every other category the operator had set, silently and with nothing failing
;; (FEAT-7's recorded trap). The console sends the whole object.
(define (ep-email-notify-put req)
  (with-auth req (lambda (p)
    (require-perm db-conn p "instance:manage")
    (define b (read-json-body req))
    (define doc (let ([v (hash-ref b 'categories b)]) v))
    (define problem (prefs-problem doc))
    (cond
      [problem (err problem 400)]
      [else
       (instance-categories-set! db-conn doc)
       (audit! db-conn #:action "instance.email.notify" #:actor-type "user"
               #:actor-id (principal-user-id p) #:team-id (principal-team-id p)
               #:resource-type "instance" #:resource-id "default" #:result "ok"
               #:meta (jsexpr->string doc))
       (json-response (hasheq 'categories (instance-categories db-conn)))]))))

(define (ep-org-email-notify-get req)
  (with-mt req (lambda ()
    (with-auth req (lambda (p)
      (require-perm db-conn p "org:read")
      (define org (principal-org-id p))
      (cond
        [(not org) (err "the caller belongs to no org" 409)]
        [else
         ;; `instance` rides along READ-ONLY, because an org admin cannot turn on
         ;; what the instance has not enabled and a card that offered it would be
         ;; a control whose only outcome is a refusal (FEAT-8's locked row).
         (json-response (hasheq 'categories (org-categories db-conn org)
                                'known MAIL-CATEGORIES
                                'instance (instance-categories db-conn)))]))))))

(define (ep-org-email-notify-put req)
  (with-mt req (lambda ()
    (with-auth req (lambda (p)
      (require-perm db-conn p "org:manage")
      (define b (read-json-body req))
      (define doc (let ([v (hash-ref b 'categories b)]) v))
      (define problem (prefs-problem doc))
      (define org (principal-org-id p))
      (cond
        [(not org) (err "the caller belongs to no org" 409)]
        [problem (err problem 400)]
        [else
         (org-categories-set! db-conn org doc)
         (audit! db-conn #:action "org.email.notify" #:actor-type "user"
                 #:actor-id (principal-user-id p) #:team-id (principal-team-id p)
                 #:org-id org #:resource-type "org" #:resource-id org #:result "ok"
                 #:meta (jsexpr->string doc))
         (json-response (hasheq 'categories (org-categories db-conn org)))])))))) 

;; ---- a person's own ------------------------------------------------------------
;; NO PERMISSION. These are the caller's own rows — the rule `GET /api/sessions`
;; and `POST /api/profile` already follow, and the reason both are `#:perm #f` in
;; the route table.
(define (ep-email-prefs-get req)
  (with-auth req (lambda (p)
    (json-response (hasheq 'address (user-address-state db-conn (principal-user-id p))
                           'categories (categories-for db-conn
                                                       #:user (principal-user-id p)
                                                       #:team (principal-team-id p)))))))

;; ONE CATEGORY AT A TIME, which is the opposite of the instance card's
;; whole-document PUT and is right for the opposite reason: a person toggles one
;; checkbox, there is no document to clobber, and `user-pref-set!` REMOVES the row
;; for an "on" rather than storing a positive — absence already means "I have not
;; objected", and writing the positive would make one state two rows.
(define (ep-email-prefs-put req)
  (with-auth req (lambda (p)
    (define b (read-json-body req))
    (define cat (let ([v (hash-ref b 'category #f)]) (and (string? v) v)))
    (define on? (hash-ref b 'enabled 'missing))
    (cond
      [(not (member cat MAIL-CATEGORIES))
       (err (format "category must be one of: ~a" (string-join MAIL-CATEGORIES ", ")) 400)]
      [(not (boolean? on?)) (err "send `enabled`: true or false" 400)]
      [else
       (user-pref-set! db-conn (principal-user-id p) cat on?)
       (json-response (hasheq 'categories (categories-for db-conn
                                                          #:user (principal-user-id p)
                                                          #:team (principal-team-id p))))]))))

;; CLAIMING AN ADDRESS SENDS THE ONE MESSAGE THIS PLATFORM SENDS TO AN UNVERIFIED
;; ONE (MAIL-5), and the two halves are separate functions on purpose:
;; `address-claim!` mints and stores the hash, this enqueues. So the domain module
;; never composes a message and the queue never mints a credential.
;;
;; THE TOKEN IS NOT IN THE RESPONSE. It goes to the address, which is the whole
;; point of the exercise — returning it would let anyone who can set an address
;; verify it without holding the mailbox.
(define (ep-email-address-put req)
  (with-auth req (lambda (p)
    (define b (read-json-body req))
    (define addr (let ([v (hash-ref b 'address #f)]) (and (string? v) (string-trim v))))
    (cond
      [(not addr) (err "send `address`" 400)]
      [(mail-address-problem addr) => (lambda (m) (err m 400))]
      [else
       (define-values (tok a) (address-claim! db-conn (principal-user-id p) addr))
       (define id (mail-enqueue-verification! db-conn #:user (principal-user-id p)
                                              #:address a #:token tok))
       (audit! db-conn #:action "user.email.claimed" #:actor-type "user"
               #:actor-id (principal-user-id p)
               #:resource-type "user" #:resource-id (principal-user-id p) #:result "ok")
       ;; `queued` is false when there is no transport, and the message says so
       ;; rather than reporting success: an operator who has not configured one
       ;; would otherwise watch somebody wait for a message nothing will send.
       (json-response (hasheq 'address (user-address-state db-conn (principal-user-id p))
                              'queued (and id #t)
                              'note (if id
                                        "A confirmation message is on its way. Nothing is sent to an address until it is confirmed."
                                        "This instance has no email transport configured, so no confirmation could be sent. Ask an operator.")))]))))

(define (ep-email-address-delete req)
  (with-auth req (lambda (p)
    (address-clear! db-conn (principal-user-id p))
    (audit! db-conn #:action "user.email.cleared" #:actor-type "user"
            #:actor-id (principal-user-id p)
            #:resource-type "user" #:resource-id (principal-user-id p) #:result "ok")
    (json-response (hasheq 'address (user-address-state db-conn (principal-user-id p)))))))

;; AUTHENTICATED, DELIBERATELY, AND THAT IS A DECISION WORTH READING. The obvious
;; shape is an unauthenticated GET on a link — which is what every other product
;; does — and it is wrong here twice: this platform has kept a no-cookie JSON API
;; precisely so that no GET mutates anything (#27's CSRF argument), and a token in
;; a URL is logged by proxies and kept in browser history, which is why
;; `/activate` strips its own from the address bar.
;;
;; So the link opens the console, the console reads `?token=` and POSTs it with
;; the caller's bearer. The cost is real and stated: somebody must be signed in to
;; confirm, which for a person reading mail on a phone is a sign-in first. What it
;; buys is that holding the token alone is not enough — it has to be the account
;; that asked.
(define (ep-email-address-verify req)
  (with-auth req (lambda (p)
    (define b (read-json-body req))
    (define tok (let ([v (hash-ref b 'token #f)]) (and (string? v) (string-trim v))))
    (define a (and tok (address-verify! db-conn tok)))
    (cond
      ;; A BAD TOKEN AND AN EXPIRED ONE ARE ONE ANSWER: whether a given token was
      ;; ever real is not a question to answer to somebody holding a guess, and
      ;; the remedy for both is the same.
      [(not a) (err "that confirmation link is not valid, or has expired — ask for another" 400)]
      [else
       (json-response (hasheq 'address (user-address-state db-conn (principal-user-id p))
                              'verified a))]))))

;; ---- the record ----------------------------------------------------------------
;; TWO SETS OF ROUTES, NOT ONE WITH A `?scope=`, and that is forced rather than
;; stylistic. The dispatcher pre-checks the permission a route DECLARES when it
;; is role-scoped (#110 r2), so a single route declaring `webhooks:manage` is
;; refused for a token scoped to `instance:read` BEFORE the handler can look at a
;; query parameter — which makes the operator's view unreachable for exactly the
;; monitoring credential #124 split that permission out for. A human operator
;; would never have noticed: `can?` lets an operator past every team-tier
;; permission, so the only caller it locks out is the narrow token.
;;
;; It is also FLEET-2's own argument arriving from the other side: a team-tier
;; route widened to cross teams answers past the org gate, which is step 0 of
;; `can?`. `/api/jobs` and `/api/admin/queue` are two routes for this reason.
;;
;; A LISTING CARRIES NO BODY. It is composed, not content (MAIL-9), so there is
;; no disclosure in it — but a dead-letter list is read to answer "what is
;; failing and why", and a page of message bodies is not that. The single read
;; carries it, which is the "show me exactly what went out" case.
;;
;; `webhooks:manage` RATHER THAN A PERMISSION OF ITS OWN, which is MTX-9's call
;; for the Matrix notifier: this is the same kind of thing — a team's record of
;; what its subscriptions sent — and it is a steward's to read rather than a
;; member's, because the listing carries colleagues' ADDRESSES and is therefore
;; information about people (#84's rule, where who-read sits behind
;; `files:manage` for the same reason).
(define (deliveries-limit req)
  (or (string->number (or (query-param req 'limit) "")) 50))
(define (deliveries-status req)
  (let ([s (query-param req 'status)]) (and (member s '("pending" "sent" "dead")) s)))

(define (ep-email-deliveries req)
  (with-auth req (lambda (p)
    (require-perm db-conn p "webhooks:manage")
    (json-response
     (hasheq 'deliveries (mail-deliveries db-conn #:team (principal-team-id p)
                                          #:status (deliveries-status req)
                                          #:limit (deliveries-limit req))
             'max_attempts MAX-ATTEMPTS)))))

(define (ep-email-delivery-get req id)
  (with-auth req (lambda (p)
    (require-perm db-conn p "webhooks:manage")
    (define d (mail-delivery-get db-conn id #:team (principal-team-id p)))
    (if d (json-response d) (err "no such delivery" 404)))))

(define (ep-email-delivery-redeliver req id)
  (with-auth req (lambda (p)
    (require-perm db-conn p "webhooks:manage")
    (redeliver req p id #:team (principal-team-id p)))))

;; The operator's view. It includes the two transactional categories — a
;; confirmation and a transport test — which belong to NO team and are therefore
;; invisible to every team listing by construction.
(define (ep-admin-email-deliveries req)
  (with-auth req (lambda (p)
    (require-perm db-conn p "instance:read")
    (json-response
     (hasheq 'deliveries (mail-deliveries db-conn #:status (deliveries-status req)
                                          #:limit (deliveries-limit req))
             'max_attempts MAX-ATTEMPTS)))))

(define (ep-admin-email-delivery-get req id)
  (with-auth req (lambda (p)
    (require-perm db-conn p "instance:read")
    (define d (mail-delivery-get db-conn id))
    (if d (json-response d) (err "no such delivery" 404)))))

;; `instance:manage`, not `:read` — this one WRITES. #124's split is about a
;; monitoring credential watching the dead-letter count without being able to act.
(define (ep-admin-email-delivery-redeliver req id)
  (with-auth req (lambda (p)
    (require-perm db-conn p "instance:manage")
    (redeliver req p id #:team #f))))

(define (redeliver req p id #:team team)
  (cond
    [(mail-redeliver! db-conn id #:team team)
     (audit! db-conn #:action "email.redeliver" #:actor-type "user" #:actor-id (principal-user-id p)
             #:team-id (principal-team-id p) #:resource-type "email_delivery" #:resource-id id
             #:result "ok")
     (json-response (hasheq 'ok #t))]
    [else (err "no such delivery, or it is already pending" 404)]))
