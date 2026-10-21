#lang racket/base

;; server/api/tokens.rkt — API tokens: issue, list, revoke
;;
;; Split out of main.rkt by #110 r3. The shared surface every handler here
;; needs — the pool, the request accessors, with-auth/with-mt, the response
;; constructors — is server/kit.rkt.

(provide ep-tokens-create ep-tokens-list ep-tokens-revoke)

(require json
         web-kit
         (only-in "../../domain/authz/authz.rkt" API-TOKEN-TTL audit! issue-token! list-tokens principal-team-id principal-user-id require-perm revoke-token!)
         (only-in "../../domain/i18n/i18n.rkt" t)
         "../kit.rkt")

;; ---- API tokens (programmatic access) ---------------------------------------
(define (ep-tokens-create req)
  (with-auth req (lambda (p)
    (require-perm db-conn p "settings:manage")
    (define b (read-json-body req))
    (define scopes (let ([s (hash-ref b 'scopes #f)]) (if (list? s) s '("*:read"))))
    (define name (let ([n (hash-ref b 'name #f)]) (if n (format "~a" n) "api")))
    ;; issue #13: `ttl` in seconds, "never" for a deliberately long-lived machine
    ;; token, or absent for the 90-day default. Anything else is a 400.
    (define ttl
      (let ([v (hash-ref b 'ttl #f)])
         (cond [(or (not v) (eq? v 'null)) API-TOKEN-TTL]
              [(equal? v "never") 'never]
              [(and (real? v) (positive? v)) v]
              [(and (string? v) (string->number v) (positive? (string->number v))) (string->number v)]
              [else 'bad])))
    (cond
      [(eq? ttl 'bad) (err "ttl must be a positive number of seconds, or \"never\"" 400)]
      [else
       (define-values (raw tokid)
         (issue-token! db-conn #:user (principal-user-id p) #:team (principal-team-id p) #:name name #:scopes scopes #:ttl ttl))
       (audit! db-conn #:action "token.issue" #:actor-type "user" #:actor-id (principal-user-id p) #:team-id (principal-team-id p)
               #:meta (jsexpr->string (hasheq 'ttl (if (eq? ttl 'never) "never" ttl))))
       (define listed (for/first ([t (in-list (list-tokens db-conn (principal-team-id p)))] #:when (equal? (hash-ref t 'id) tokid)) t))
       (json-response (hasheq 'id tokid 'token raw 'name name 'scopes scopes
                              'expires_at (if listed (hash-ref listed 'expires_at) 'null))
                      #:code 201)]))))    ; raw shown once

(define (ep-tokens-list req)
  (with-auth req (lambda (p)
    (require-perm db-conn p "settings:manage")
    (json-response (hasheq 'tokens (list-tokens db-conn (principal-team-id p)))))))

(define (ep-tokens-revoke req id)
  (with-auth req (lambda (p)
    (require-perm db-conn p "settings:manage")
    (if (revoke-token! db-conn id (principal-team-id p))
         (begin (audit! db-conn #:action "token.revoke" #:actor-type "user" #:actor-id (principal-user-id p) #:team-id (principal-team-id p))
               (json-response (hasheq 'ok #t 'id id)))
         (err "token not found" 404)))))
