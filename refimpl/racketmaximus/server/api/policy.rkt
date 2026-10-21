#lang racket/base

;; server/api/policy.rkt — session timeouts (issue #38) and retention rules
;; (#86 r3), both planes
;;
;; Split out of main.rkt by #110 r3. The shared surface every handler here
;; needs — the pool, the request accessors, with-auth/with-mt, the response
;; constructors — is server/kit.rkt.

(provide ep-session-policy-get ep-retention-get ep-retention-put
         ep-retention-plan-get ep-legal-hold-put ep-my-org-retention-get
         ep-my-org-retention-put ep-session-policy-put
         ep-my-org-session-policy-get ep-my-org-session-policy-put
         ep-my-org-session-policy-clear)

(require db-kit/portable
         web-kit
         "../../domain/authz/authz.rkt"
         (only-in "../../domain/repo/repo.rkt" repo-legal-hold!)
         (only-in "../../domain/retention/retention.rkt" DEFAULT-PAYLOAD-DAYS effective-retention legal-hold-of retention-plan retention-ref retention-set! retention-sources)
         "../kit.rkt")

;; ---- session policy (issue #38, OWASP) ------------------------------------------
;; Two layers: the instance default here, and an org's own policy below. An org may
;; only TIGHTEN — see the note at the top of domain/authz/session-policy.rkt.
(define (ep-session-policy-get req)
  (with-auth req (lambda (p)
    (require-perm db-conn p "instance:manage")
    (json-response (hasheq 'policy (session-policy-get db-conn)
                           'shipped (shipped-session-policy)
                           'bounds (hasheq 'idle_min IDLE-MIN 'idle_max IDLE-MAX
                                           'absolute_min ABSOLUTE-MIN 'absolute_max ABSOLUTE-MAX
                                           'warn_max WARN-MAX))))))

;; ---- retention rules (#86 r3) ----------------------------------------------------
;; The team's own org, needed for the effective policy. `caller-org` is the
;; multi-tenant accessor; single-tenant instances have none and the org layer is
;; simply absent, which `effective-retention` already handles.
(define (team-org-of p)
  (define o (query-maybe-value db-conn "SELECT org_id FROM teams WHERE id = ?" (principal-team-id p)))
  (and o (not (sql-null? o)) o))

(define (ep-retention-get req)
  (with-auth req (lambda (p)
    ;; `files:read`, as `routes.rkt` declares and as `ep-retention-plan-get` two
    ;; definitions below already enforced. THIS LINE WAS MISSING: the route table
    ;; said the handler enforced a permission and the handler did not, so any
    ;; authenticated member could read the team's, the company's and the
    ;; INSTANCE's retention policy. Found by asking the question mechanically —
    ;; every route's declared `#:perm` against the body of the handler it names —
    ;; and `test/routes-tests.rkt` now asks it on every build, because a
    ;; declaration nothing checks is a comment.
    (require-perm db-conn p "files:read")
    (define team (principal-team-id p))
    (define org (team-org-of p))
    (json-response
     (hasheq 'policy (effective-retention db-conn team org)
             ;; which LAYER set each value. Three documents an operator has to
             ;; diff by hand is a poor answer to "why is my data going".
             'sources (retention-sources db-conn team org)
             'team (retention-ref db-conn 'team team)
             'org (if org (retention-ref db-conn 'org org) 'null)
             'instance (retention-ref db-conn 'instance)
             'recommended_payload_days DEFAULT-PAYLOAD-DAYS)))))

(define (ep-retention-put req)
  (with-auth req (lambda (p)
    (require-perm db-conn p "settings:manage")
    (define b (read-json-body req))
    (with-handlers ([exn:fail:user? (lambda (e) (err (exn-message e) 400))])
      (retention-set! db-conn 'team (principal-team-id p) (if (hash? b) b (hasheq)))
      (audit! db-conn #:action "retention.policy" #:actor-type "user"
              #:actor-id (principal-user-id p) #:team-id (principal-team-id p)
              #:resource-type "team" #:resource-id (principal-team-id p))
      (json-response (hasheq 'ok #t
                             'policy (effective-retention db-conn (principal-team-id p)
                                                          (team-org-of p))))))))

(define (ep-retention-plan-get req)
  (with-auth req (lambda (p)
    (require-perm db-conn p "files:read")
    (json-response
     (hash-set (retention-plan db-conn (principal-team-id p) (team-org-of p)) 'ok #t)))))

(define (ep-legal-hold-put req id)
  (with-auth req (lambda (p)
    ;; The check and the audit live in `repo-legal-hold!`, beside the object
    ;; rows — `obj->resource` is internal to repo.rkt, and a second copy of the
    ;; stewardship rule here would be a second thing to keep in step.
    (define b (read-json-body req))
    (define on? (and (hash? b) (eq? (hash-ref b 'hold #t) #t)))
    (if (repo-legal-hold! db-conn p id on?)
         (json-response (hasheq 'ok #t 'id id 'legal_hold (or (legal-hold-of db-conn id) 'null)))
         (err "not found" 404)))))

(define (ep-my-org-retention-get req)
  (with-mt req (lambda ()
    (with-auth req (lambda (p)
      (require-perm db-conn p "org:read")
      (json-response (hasheq 'policy (retention-ref db-conn 'org (caller-org p)))))))))

(define (ep-my-org-retention-put req)
  (with-mt req (lambda ()
    (with-auth req (lambda (p)
      (require-perm db-conn p "org:manage")
      (define b (read-json-body req))
      (with-handlers ([exn:fail:user? (lambda (e) (err (exn-message e) 400))])
         (retention-set! db-conn 'org (caller-org p) (if (hash? b) b (hasheq)))
         (json-response (hasheq 'ok #t 'policy (retention-ref db-conn 'org (caller-org p))))))))))

(define (ep-session-policy-put req)
  (with-auth req (lambda (p)
    (require-perm db-conn p "instance:manage")
    (define b (read-json-body req))
    (define problem (policy-problem (if (hash? b) b (hasheq))))
    (cond
      [problem (err problem 400)]
      [else
       (define saved (session-policy-set! db-conn b))
       (audit! db-conn #:action "session.policy" #:actor-type "user" #:actor-id (principal-user-id p)
               #:resource-type "instance" #:resource-id "instance")
       (json-response (hasheq 'policy saved))]))))

(define (ep-my-org-session-policy-get req)
  (with-mt req (lambda ()
    (with-auth req (lambda (p)
      (require-perm db-conn p "org:read")
      (define own (org-session-policy-get db-conn (caller-org p)))
      (json-response (hasheq 'policy (or own 'null)
                             'own (and own #t)
                             ;; what actually applies, after the instance floor
                             'effective (session-policy-for db-conn (caller-org p))
                             'instance (session-policy-get db-conn))))))))

(define (ep-my-org-session-policy-put req)
  (with-mt req (lambda ()
    (with-auth req (lambda (p)
      (require-perm db-conn p "org:manage")
      (define b (read-json-body req))
      (define problem (policy-problem (if (hash? b) b (hasheq))))
      (cond
        [problem (err problem 400)]
        [else
         (org-session-policy-set! db-conn (caller-org p) b)
         (audit! db-conn #:action "org.session.policy" #:actor-type "user" #:actor-id (principal-user-id p)
                 #:resource-type "org" #:resource-id (caller-org p))
         ;; report the EFFECTIVE policy, not the document we stored: an org that
         ;; asked to loosen the instance floor gets the floor, and finding that
         ;; out here beats discovering it when nobody gets signed out
         (json-response (hasheq 'policy (org-session-policy-get db-conn (caller-org p))
                                'own #t
                                'effective (session-policy-for db-conn (caller-org p))))]))))))

(define (ep-my-org-session-policy-clear req)
  (with-mt req (lambda ()
    (with-auth req (lambda (p)
      (require-perm db-conn p "org:manage")
      (org-session-policy-clear! db-conn (caller-org p))
      (audit! db-conn #:action "org.session.policy.clear" #:actor-type "user"
              #:actor-id (principal-user-id p) #:resource-type "org" #:resource-id (caller-org p))
      (json-response (hasheq 'policy 'null 'own #f
                             'effective (session-policy-for db-conn (caller-org p)))))))))
