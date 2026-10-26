#lang racket/base

;; server/api/webhooks.rkt — outbound webhook subscriptions and their deliveries (#85).

(provide ep-webhooks-list ep-webhooks-create ep-webhook-get ep-webhook-patch
         ep-webhook-delete ep-webhook-ping ep-webhook-deliveries ep-delivery-redeliver)

(require db-kit/portable
         web-kit
         json
         racket/string
         (only-in "../../domain/authz/authz.rkt" audit! principal-team-id principal-user-id require-perm)
         (only-in "../../domain/hooks/webhooks.rkt" MAX-ATTEMPTS deliveries-list delivery-get
                  enqueue-event! redeliver! webhook-create! webhook-delete! webhook-get
                  webhook-list webhook-problem webhook-update! deliver-one!)
         (only-in "../../domain/events/events.rkt" EVENTS)
         "../kit.rkt")

(define (ep-webhooks-list req)
  (with-auth req (lambda (p)
    (require-perm db-conn p "webhooks:manage")
    (json-response (hasheq 'webhooks (webhook-list db-conn (principal-team-id p))
                           'events EVENTS
                           'max_attempts MAX-ATTEMPTS)))))

(define (ep-webhooks-create req)
  (with-auth req (lambda (p)
    (require-perm db-conn p "webhooks:manage")
    (define b (read-json-body req))
    (define url (let ([v (hash-ref b 'url #f)]) (and v (format "~a" v))))
    (define events (let ([v (hash-ref b 'events "*")]) (format "~a" v)))
    (define problem (webhook-problem #:url (or url "") #:events events))
    (cond
      [problem (err problem 400)]
      [else
       (define-values (id secret)
         (webhook-create! db-conn #:team (principal-team-id p) #:url url #:events events
                          #:description (let ([d (hash-ref b 'description #f)]) (and d (format "~a" d)))
                          #:created-by (principal-user-id p)))
       (audit! db-conn #:action "webhook.create" #:actor-type "user" #:actor-id (principal-user-id p)
               #:team-id (principal-team-id p) #:resource-type "webhook" #:resource-id id
               ;; the URL is the configuration, not a secret; the SECRET never
               ;; appears in an audit entry
               #:meta (jsexpr->string (hasheq 'url url 'events events)))
       ;; THE SECRET IS SHOWN ONCE and is unreadable afterwards — #19's rule for
       ;; a token, and the copy says so rather than implying a recovery that does
       ;; not exist. `rotate` is how a lost one is replaced.
       (json-response (hasheq 'webhook (webhook-get db-conn id (principal-team-id p))
                              'secret secret
                              'secret_note "Shown once. Store it now; rotate to replace it.")
                      #:code 201)]))))

(define (ep-webhook-get req id)
  (with-auth req (lambda (p)
    (require-perm db-conn p "webhooks:manage")
    (define w (webhook-get db-conn id (principal-team-id p)))
    (if w (json-response w) (err "no such webhook" 404)))))

(define (ep-webhook-patch req id)
  (with-auth req (lambda (p)
    (require-perm db-conn p "webhooks:manage")
    (define b (read-json-body req))
    (define url (let ([v (hash-ref b 'url 'same)]) (if (eq? v 'same) 'same (format "~a" v))))
    (define events (let ([v (hash-ref b 'events 'same)]) (if (eq? v 'same) 'same (format "~a" v))))
    ;; Validated AS IT WOULD BE, so a patch cannot reach a state a create could
    ;; not — the rule the schedule routes follow.
    (define cur (webhook-get db-conn id (principal-team-id p)))
    (define problem
      (and cur (webhook-problem #:url (if (string? url) url (hash-ref cur 'url))
                                #:events (if (string? events) events (hash-ref cur 'events)))))
    (cond
      [(not cur) (err "no such webhook" 404)]
      [problem (err problem 400)]
      [else
       (define-values (w fresh)
         (webhook-update! db-conn id (principal-team-id p)
                          #:url url #:events events
                          #:active? (let ([v (hash-ref b 'active 'same)]) (if (boolean? v) v 'same))
                          #:description (let ([v (hash-ref b 'description 'same)])
                                          (if (eq? v 'same) 'same (format "~a" v)))
                          #:rotate? (eq? #t (hash-ref b 'rotate #f))))
       (audit! db-conn #:action (if fresh "webhook.rotate" "webhook.update")
               #:actor-type "user" #:actor-id (principal-user-id p)
               #:team-id (principal-team-id p) #:resource-type "webhook" #:resource-id id)
       (json-response (if fresh
                          (hasheq 'webhook w 'secret fresh
                                  'secret_note "Shown once. The previous secret no longer signs anything.")
                          (hasheq 'webhook w)))]))))

(define (ep-webhook-delete req id)
  (with-auth req (lambda (p)
    (require-perm db-conn p "webhooks:manage")
    (cond
      [(webhook-delete! db-conn id (principal-team-id p))
       (audit! db-conn #:action "webhook.delete" #:actor-type "user" #:actor-id (principal-user-id p)
               #:team-id (principal-team-id p) #:resource-type "webhook" #:resource-id id)
       (json-response (hasheq 'ok #t))]
      [else (err "no such webhook" 404)]))))

;; #85 r6. A subscription nobody can test is a subscription nobody trusts, and
;; this is also how an integrator checks their signature verification before a
;; real event depends on it. It is delivered SYNCHRONOUSLY — the caller is
;; waiting and wants the answer, where an ordinary event is a background concern.
(define (ep-webhook-ping req id)
  (with-auth req (lambda (p)
    (require-perm db-conn p "webhooks:manage")
    (define w (webhook-get db-conn id (principal-team-id p)))
    (cond
      [(not w) (err "no such webhook" 404)]
      [else
       ;; `#:claim id` makes THIS subscription's row born owned (WHK-3). The
       ;; delivery sweep rides the reaper seam every second, so between the
       ;; insert and the POST below it could otherwise take the row and send it
       ;; — leaving the caller who asked "does my webhook work" to be told that
       ;; somebody else was finding out. Every other subscription's row is born
       ;; due, as before, and the sweep delivers those.
       (define ids (enqueue-event! db-conn "ping" (principal-team-id p)
                                   (hasheq 'webhook_id id 'note "a test delivery")
                                   #:claim id))
       (define mine (filter (lambda (d)
                              (equal? (hash-ref (or (delivery-get db-conn d (principal-team-id p)) (hasheq))
                                                'webhook_id #f) id))
                            ids))
       (cond
         [(null? mine)
          ;; the subscription is inactive, or does not subscribe to `ping`
          (err "this webhook would not receive a ping — check `active` and `events`" 409)]
         [else
          (define outcome (deliver-one! db-conn (car mine) #:claimed? #t))
          (json-response (hasheq 'delivery_id (car mine)
                                 'outcome (format "~a" outcome)
                                 'delivery (delivery-get db-conn (car mine) (principal-team-id p))))])]))))

(define (ep-webhook-deliveries req id)
  (with-auth req (lambda (p)
    (require-perm db-conn p "webhooks:manage")
    (cond
      [(not (webhook-get db-conn id (principal-team-id p))) (err "no such webhook" 404)]
      [else
       (define status (let ([v (query-param req 'status)]) (and (string? v) (not (string=? v "")) v)))
       (json-response (hasheq 'deliveries (deliveries-list db-conn (principal-team-id p)
                                                           #:webhook id #:status status)))]))))

;; The dead-letter lever (#85 r3). Scoped by team in the statement, so another
;; team's delivery id is a miss.
(define (ep-delivery-redeliver req id)
  (with-auth req (lambda (p)
    (require-perm db-conn p "webhooks:manage")
    (cond
      [(redeliver! db-conn id (principal-team-id p))
       (audit! db-conn #:action "webhook.redeliver" #:actor-type "user" #:actor-id (principal-user-id p)
               #:team-id (principal-team-id p) #:resource-type "webhook_delivery" #:resource-id id)
       (json-response (hasheq 'ok #t 'delivery (delivery-get db-conn id (principal-team-id p))))]
      [else (err "no such delivery, or it is already pending" 404)]))))
