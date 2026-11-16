#lang racket/base

;; server/api/tokens.rkt — API tokens: issue, list, revoke
;;
;; Split out of main.rkt by #110 r3. The shared surface every handler here
;; needs — the pool, the request accessors, with-auth/with-mt, the response
;; constructors — is server/kit.rkt.

(provide ep-tokens-create ep-tokens-list ep-tokens-revoke ep-admin-user-token)

(require json
         db-kit/portable
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

;; ---- a machine token for a service account ----------------------------------
;; A monitoring probe, a harvest, a backup: an account that exists to be called by a
;; program and never signs in. `POST /api/tokens` cannot serve it, because it mints for
;; the CALLER, so the only way such an account could get a long-lived token was to hold
;; `settings:manage` itself and sign in. That is a widening nobody wants: the probe on
;; dev1 was a `member`, could not mint a `never` token, and was handed a SESSION token
;; instead, which the policy's eight-hour absolute clock kills twice a day. Monitoring
;; then degraded silently until somebody looked.
;;
;; So an operator issues it, and the audit names both sides: the operator who acted and
;; the account the token speaks for. The scopes are the operator's choice, which is the
;; same power `instance:manage` already carries (it can reset that account's password and
;; sign in as it), and they are recorded so the choice is visible afterwards.
;;
;; AN OPERATOR ACCOUNT IS REFUSED. This route exists for a service account, and minting a
;; token for an operator through it would be a way to clone operator credentials into a
;; place the operator list does not show. An operator who needs a token signs in and uses
;; `POST /api/tokens`, which is the path that already exists.
(define (ep-admin-user-token req uid)
  (with-auth req (lambda (p)
    (require-perm db-conn p "instance:manage")
    (define row (query-maybe-row db-conn "SELECT username, is_operator FROM users WHERE id = ?" uid))
    (cond
      [(not row) (err "no such user" 404)]
      [(and (number? (vector-ref row 1)) (not (zero? (vector-ref row 1))))
       (err "this route issues tokens for a service account, not for an operator: an operator signs in and uses POST /api/tokens" 400)]
      [else
       (define b (read-json-body req))
       (define scopes (let ([s (hash-ref b 'scopes #f)]) (if (list? s) s '("*:read"))))
       (define name (let ([n (hash-ref b 'name #f)]) (if n (format "~a" n) "service")))
       (define ttl
         (let ([v (hash-ref b 'ttl #f)])
           (cond [(or (not v) (eq? v 'null)) API-TOKEN-TTL]
                 [(equal? v "never") 'never]
                 [(and (real? v) (positive? v)) v]
                 [(and (string? v) (string->number v) (positive? (string->number v))) (string->number v)]
                 [else 'bad])))
       ;; the account's own team, because a token with no team cannot do team-scoped
       ;; work and the caller would have no way to tell that from the answer
       (define team-id (query-maybe-value db-conn
                         "SELECT team_id FROM memberships WHERE user_id = ? AND status = 'active' ORDER BY created_at LIMIT 1"
                         uid))
       (cond
         [(eq? ttl 'bad) (err "ttl must be a positive number of seconds, or \"never\"" 400)]
         [(not team-id) (err "that account belongs to no team, so a token for it could do nothing" 400)]
         [else
          (define-values (raw tokid)
            (issue-token! db-conn #:user uid #:team team-id #:name name #:scopes scopes #:ttl ttl))
          (audit! db-conn #:action "token.issue" #:actor-type "user" #:actor-id (principal-user-id p)
                  #:team-id (principal-team-id p)
                  #:resource-type "user" #:resource-id uid
                  #:meta (jsexpr->string (hasheq 'ttl (if (eq? ttl 'never) "never" ttl)
                                                 'scopes scopes
                                                 'subject (vector-ref row 0)
                                                 'issued_by_operator #t)))
          (define listed (for/first ([t (in-list (list-tokens db-conn team-id))] #:when (equal? (hash-ref t 'id) tokid)) t))
          (json-response (hasheq 'id tokid 'token raw 'name name 'scopes scopes 'user_id uid
                                 'expires_at (if listed (hash-ref listed 'expires_at) 'null))
                         #:code 201)])]))))

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
