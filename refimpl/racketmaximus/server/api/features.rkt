#lang racket/base

;; server/api/features.rkt — the feature switches, team / company / instance
;; (#63)
;;
;; Split out of main.rkt by #110 r3. The shared surface every handler here
;; needs — the pool, the request accessors, with-auth/with-mt, the response
;; constructors — is server/kit.rkt.

(provide ep-features ep-feature-toggle ep-instance-features
         ep-instance-features-put ep-org-features ep-org-features-put)

(require json
         web-kit
         (only-in "../../domain/authz/authz.rkt" audit! principal-org-id principal-team-id principal-user-id require-perm)
         "../../domain/features/features.rkt"
         "../kit.rkt")

(define (ep-features req)
  (with-auth req (lambda (p) (json-response (hasheq 'features (features-for db-conn (principal-team-id p)))))))

(define (ep-feature-toggle req name)
  (with-auth req (lambda (p)
    (require-perm db-conn p "settings:manage")
    (define on? (and (hash-ref (read-json-body req) 'enabled #t) #t))
    (cond
      [(not (member name known-features)) (err (format "unknown feature '~a'" name) 400)]
      ;; #63: a team may TIGHTEN and may never LOOSEN. Turning a feature on that
      ;; a layer above disabled is refused BY NAME rather than stored and
      ;; ignored — a row saying `enabled = 1` under an instance that says no
      ;; would be a setting that lies to the next person who reads it. Turning
      ;; it OFF is always allowed, including when a layer above already has:
      ;; that is a team recording its own intention, which survives the
      ;; instance's switch being flipped back.
      [(and on? (let ([by (feature-scope db-conn (principal-team-id p) name)])
                  (and by (not (equal? by "team")))))
       => (lambda (_)
            (err (format (string-append "'~a' is disabled for the whole ~a — a team cannot"
                                        " turn it back on. Ask an administrator.")
                         name (feature-scope db-conn (principal-team-id p) name))
                 409))]
      [else
       (set-feature-enabled! db-conn (principal-team-id p) name on?)
       (audit! db-conn #:action "feature.toggle" #:actor-type "user" #:actor-id (principal-user-id p)
               #:team-id (principal-team-id p) #:resource-type "feature" #:resource-id name
               #:meta (jsexpr->string (hasheq 'enabled on?)))
       (json-response (hasheq 'ok #t 'feature name 'enabled on?
                              'effective (feature-enabled? db-conn (principal-team-id p) name)))]))))

;; ---- the instance and org switches (#63) ------------------------------------
;; The gap `docs/integrators-guide.md` stated: flags were per TEAM only, so an
;; operator could not turn a feature off instance-wide and, on a multi-tenant
;; box, could not turn one off for one company.
(define (ep-instance-features req)
  (with-auth req (lambda (p)
    (require-perm db-conn p "instance:manage")
    (json-response (hasheq 'features (instance-features db-conn)
                           'known known-features)))))

(define (ep-instance-features-put req)
  (with-auth req (lambda (p)
    (require-perm db-conn p "instance:manage")
    (define b (read-json-body req))
    (define doc (let ([d (hash-ref b 'features b)]) (if (hash? d) d (hasheq))))
    (define prob (feature-problem doc))
    (cond
      [prob (err prob 400)]
      [else
       (instance-features-set! db-conn doc)
       (audit! db-conn #:action "features.instance.set" #:actor-type "user"
               #:actor-id (principal-user-id p) #:team-id (principal-team-id p)
               #:meta (jsexpr->string doc))
       (json-response (hasheq 'features doc 'known known-features))]))))

(define (ep-org-features req)
  (with-mt req (lambda ()
    (with-auth req (lambda (p)
      (require-perm db-conn p "org:read")
      (define oid (principal-org-id p))
      (if oid
          (json-response (hasheq 'features (org-features db-conn oid) 'known known-features
                                 'org_id oid))
          (err "the caller belongs to no org" 409)))))))

(define (ep-org-features-put req)
  (with-mt req (lambda ()
    (with-auth req (lambda (p)
      (require-perm db-conn p "org:manage")
      (define oid (principal-org-id p))
      (define b (read-json-body req))
      (define doc (let ([d (hash-ref b 'features b)]) (if (hash? d) d (hasheq))))
      (define prob (feature-problem doc))
      (cond
        [(not oid) (err "the caller belongs to no org" 409)]
        [prob (err prob 400)]
        [else
         (org-features-set! db-conn oid doc)
         (audit! db-conn #:action "features.org.set" #:actor-type "user"
                 #:actor-id (principal-user-id p) #:team-id (principal-team-id p)
                 #:org-id oid #:meta (jsexpr->string doc))
         (json-response (hasheq 'features doc 'known known-features 'org_id oid))]))))))

;; `sandboxed` lists the out-of-process plugins WITH THE SCOPES THEY DECLARED.
;; They were absent entirely, so after granting one repository access there was no
;; way to see which plugins hold it — and the declared scope is half of the double
;; gate. Kept as its own key: `loaded-plugins` is what docs/reference is generated
;; from, and an in-process plugin and a subprocess are not the same kind of thing.
