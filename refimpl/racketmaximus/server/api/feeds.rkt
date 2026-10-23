#lang racket/base

;; server/api/feeds.rkt — external feed configuration (#114, FEED-2/-5/-6).

(provide ep-feeds-list ep-feeds-create ep-feed-get ep-feed-patch ep-feed-delete ep-feed-probe)

(require db-kit/portable
         web-kit
         json
         (only-in "../../domain/authz/authz.rkt" audit! principal-team-id principal-user-id require-perm)
         (only-in "../../domain/net/fetch.rkt" safe-url)
         (only-in "../../domain/feeds/feeds.rkt"
                  FEED-KINDS FEED-AUTHS feed-create! feed-delete! feed-get feed-list
                  feed-problem feed-update! probe-feed!)
         "../kit.rkt")

(define (str b k [d #f])
  (let ([v (hash-ref b k 'missing)])
    (cond [(eq? v 'missing) d]
          [(eq? v 'null) #f]
          [(not v) #f]
          [else (format "~a" v)])))

;; 'same when the key is absent, so a PATCH touches only what it names.
(define (patch-str b k)
  (let ([v (hash-ref b k 'missing)])
    (cond [(eq? v 'missing) 'same]
          [(eq? v 'null) #f]
          [(not v) #f]
          [else (format "~a" v)])))

;; The audit meta carries `safe-url`, NEVER the configured URL. The audit log is
;; hash-chained, exported off the box and deliberately kept through an erasure
;; (DEL-7), so it outlives every other copy — and an operator who pasted a token
;; into the URL would otherwise have put it in the one table nothing clears.
(define (feed-meta f extra)
  (jsexpr->string (for/fold ([h (hasheq 'slug (hash-ref f 'slug)
                                        'kind (hash-ref f 'kind)
                                        'url (safe-url (hash-ref f 'url))
                                        'auth (hash-ref f 'auth)
                                        'user_id (hash-ref f 'user_id))])
                            ([(k v) (in-hash extra)])
                    (hash-set h k v))))

(define (ep-feeds-list req)
  (with-auth req (lambda (p)
    (require-perm db-conn p "feeds:manage")
    (json-response (hasheq 'feeds (feed-list db-conn (principal-team-id p))
                           'kinds FEED-KINDS
                           'auth_modes FEED-AUTHS)))))

(define (ep-feeds-create req)
  (with-auth req (lambda (p)
    (require-perm db-conn p "feeds:manage")
    (define b (read-json-body req))
    (define slug (or (str b 'slug) ""))
    (define kind (or (str b 'kind) ""))
    (define url (or (str b 'url) ""))
    (define auth (or (str b 'auth) "none"))
    (define auth-name (str b 'auth_name))
    (define secret (str b 'secret))
    ;; The user a pull acts as defaults to the caller — the ordinary case, and
    ;; the one DWF-2 already decided for an upload.
    (define user (or (str b 'user_id) (principal-user-id p)))
    (define problem (feed-problem #:slug slug #:kind kind #:url url #:auth auth
                                  #:auth-name auth-name #:secret secret))
    (cond
      [problem (err problem 400)]
      [else
       (define r (feed-create! db-conn #:team (principal-team-id p) #:user user #:slug slug
                               #:name (str b 'name) #:kind kind #:url url #:auth auth
                               #:auth-name auth-name #:secret secret
                               #:created-by (principal-user-id p)))
       (cond
         [(eq? r 'no-such-user)
          (err "`user_id` must be an active member of this team — a feed cannot act as somebody outside it" 400)]
         [(eq? r 'duplicate-slug)
          ;; 409, and deliberately not a converging create: the slug is the key
          ;; prefix pulled items land under, so adopting an existing feed would
          ;; silently take over its URL and its credential.
          (err "a feed with that slug already exists in this team" 409)]
         [else
          (define f (feed-get db-conn r (principal-team-id p)))
          (audit! db-conn #:action "feed.create" #:actor-type "user" #:actor-id (principal-user-id p)
                  #:team-id (principal-team-id p) #:resource-type "feed" #:resource-id r
                  #:meta (feed-meta f (hasheq 'has_secret (hash-ref f 'has_secret))))
          (json-response (hasheq 'feed f) #:code 201)])]))))

(define (ep-feed-get req id)
  (with-auth req (lambda (p)
    (require-perm db-conn p "feeds:manage")
    (define f (feed-get db-conn id (principal-team-id p)))
    (if f (json-response (hasheq 'feed f)) (err "no such feed" 404)))))

(define (ep-feed-patch req id)
  (with-auth req (lambda (p)
    (require-perm db-conn p "feeds:manage")
    (define b (read-json-body req))
    (define cur (feed-get db-conn id (principal-team-id p)))
    (define slug (patch-str b 'slug))
    (define kind (patch-str b 'kind))
    (define url (patch-str b 'url))
    (define auth (patch-str b 'auth))
    (define auth-name (patch-str b 'auth_name))
    (define secret (patch-str b 'secret))
    ;; Validated AS THE FEED WOULD BE, so a patch cannot reach a state a create
    ;; could not — switching to `bearer` in the same request that supplies the
    ;; secret is fine, switching without one is refused. The schedule routes'
    ;; rule (#140), and the reason the credential and the auth mode are checked
    ;; together rather than one at a time.
    (define (eff v k) (if (eq? v 'same) (hash-ref cur k) v))
    (define problem
      (and cur (feed-problem #:slug (or (eff slug 'slug) "")
                             #:kind (or (eff kind 'kind) "")
                             #:url (or (eff url 'url) "")
                             #:auth (or (eff auth 'auth) "none")
                             #:auth-name (eff auth-name 'auth_name)
                             #:secret (if (eq? secret 'same)
                                          ;; keeping the stored one: what matters
                                          ;; to validation is that there IS one
                                          (and (hash-ref cur 'has_secret) "stored")
                                          secret))))
    (cond
      [(not cur) (err "no such feed" 404)]
      [problem (err problem 400)]
      [else
       (define r (feed-update! db-conn id (principal-team-id p)
                               #:user (patch-str b 'user_id) #:slug slug #:name (patch-str b 'name)
                               #:kind kind #:url url #:auth auth #:auth-name auth-name
                               #:secret secret
                               #:active? (let ([v (hash-ref b 'active 'same)])
                                           (if (boolean? v) v 'same))))
       (cond
         [(eq? r 'no-such-user)
          (err "`user_id` must be an active member of this team — a feed cannot act as somebody outside it" 400)]
         [(eq? r 'duplicate-slug) (err "a feed with that slug already exists in this team" 409)]
         [(not r) (err "no such feed" 404)]
         [else
          (audit! db-conn #:action "feed.update" #:actor-type "user" #:actor-id (principal-user-id p)
                  #:team-id (principal-team-id p) #:resource-type "feed" #:resource-id id
                  #:meta (feed-meta r (hasheq 'secret_changed (not (eq? secret 'same)))))
          (json-response (hasheq 'feed r))])]))))

(define (ep-feed-delete req id)
  (with-auth req (lambda (p)
    (require-perm db-conn p "feeds:manage")
    (define f (feed-get db-conn id (principal-team-id p)))
    (cond
      [(and f (feed-delete! db-conn id (principal-team-id p)))
       (audit! db-conn #:action "feed.delete" #:actor-type "user" #:actor-id (principal-user-id p)
               #:team-id (principal-team-id p) #:resource-type "feed" #:resource-id id
               #:meta (feed-meta f (hasheq)))
       (json-response (hasheq 'ok #t))]
      [else (err "no such feed" 404)]))))

;; A feed nobody can test is a feed nobody trusts — #85's ping, for the same
;; reason and with the same synchronous shape: the caller is waiting and wants
;; the answer. It fetches once and stores the OUTCOME only; landing items is
;; slice 4's job, so a probe cannot create, version or bill for a document.
(define (ep-feed-probe req id)
  (with-auth req (lambda (p)
    (require-perm db-conn p "feeds:manage")
    (define f (feed-get db-conn id (principal-team-id p)))
    (cond
      [(not f) (err "no such feed" 404)]
      [else
       (define outcome (probe-feed! db-conn f))
       (audit! db-conn #:action "feed.probe" #:actor-type "user" #:actor-id (principal-user-id p)
               #:team-id (principal-team-id p) #:resource-type "feed" #:resource-id id
               #:meta (feed-meta f (hasheq 'ok (hash-ref outcome 'ok #f)
                                           'status (hash-ref outcome 'status 'null))))
       ;; 200 whatever the source said: the probe RAN. Whether the source
       ;; answered is in the body, and a 502 here would be this instance
       ;; claiming somebody else's failure as its own.
       (json-response (hasheq 'probe outcome
                              'feed (feed-get db-conn id (principal-team-id p))))]))))
