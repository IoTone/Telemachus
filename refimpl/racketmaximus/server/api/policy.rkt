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
         ep-my-org-session-policy-clear
         ;; #91 req 4: where a labelled document's text may go
         ep-executor-policy-get ep-executor-policy-put ep-executor-policy-clear
         ep-my-org-executor-policy-get ep-my-org-executor-policy-put
         ep-my-org-executor-policy-clear
         ;; #137: the timezone layers
         ep-timezone-get ep-timezone-put
         ep-my-org-timezone-get ep-my-org-timezone-put ep-my-org-timezone-clear)

(require db-kit/portable
         json racket/list racket/string
         (only-in "../../domain/time/tz-policy.rkt" DEFAULT-TIMEZONE clear-org-timezone! instance-timezone
                  org-timezone set-instance-timezone! set-org-timezone! timezone-for timezone-problem)
         (only-in "../../domain/time/zones.rkt" available-zones)
         web-kit
         "../../domain/authz/authz.rkt"
         (only-in "../../domain/repo/repo.rkt" repo-legal-hold!)
         (only-in "../../domain/ai/sensitivity.rkt" SENSITIVITY-KEY MAX-POLICY-LABELS
                  executor-policy-clear! executor-policy-effective executor-policy-problem
                  executor-policy-ref executor-policy-set! executor-policy-sources)
         (only-in "../../domain/exec/federation.rkt" executor-exists?)
         (only-in "../../domain/retention/retention.rkt" DEFAULT-PAYLOAD-DAYS effective-retention legal-hold-of retention-plan retention-ref retention-set! retention-sources)
         "../kit.rkt")

;; ---- the executor policy (#91 req 4) ---------------------------------------------
;; Two tiers, instance and org, and they TIGHTEN where both speak — see the
;; header of domain/ai/sensitivity.rkt. Reading it is an OPERATOR's business
;; (`instance:manage`, `org:read`), as the session policy's is and unlike
;; retention's: it is a list of this instance's own backends, and the only thing
;; a team member needs from it is what a refused request already tells them.
;;
;; An executor name the policy lists that NO executor answers to is reported
;; rather than refused on the write. A typo here fails CLOSED — the name is
;; simply never matched, so the label's text goes nowhere — which is the
;; opposite of `PUT /api/model-roles`, where a typo silently sent every
;; extraction to the local model and so had to be refused. And refusing it would
;; make a policy unwritable before the backend it names exists, which is the
;; ordinary order in which an operator sets one up.
(define (unknown-executors doc)
  (define names
    (remove-duplicates
     (append* (for/list ([(_l e) (in-hash (hash-ref doc 'labels (hasheq)))])
                (hash-ref e 'executors '())))))
  (for/list ([n (in-list names)]
             #:unless (or (executor-exists? n)
                          (let ([r (query-maybe-value db-conn
                                     "SELECT id FROM executors WHERE name = ? AND status <> 'retired'" n)])
                            (and r (not (sql-null? r))))))
    n))

(define (policy-body doc #:org-own [own 'none] #:effective [eff #f] #:sources [src #f])
  (define base
    (hasheq 'policy (or doc 'null)
            'configured (and doc #t)
            'attribute SENSITIVITY-KEY
            'max_labels MAX-POLICY-LABELS
            'unknown_executors (if doc (unknown-executors doc) '())))
  (let* ([b (if (eq? own 'none) base (hash-set base 'own own))]
         [b (if eff (hash-set b 'effective eff) b)])
    (if src (hash-set b 'sources src) b)))

(define (ep-executor-policy-get req)
  (with-auth req (lambda (p)
    (require-perm db-conn p "instance:manage")
    (json-response (policy-body (executor-policy-ref db-conn 'instance))))))

(define (ep-executor-policy-put req)
  (with-auth req (lambda (p)
    (require-perm db-conn p "instance:manage")
    (define b (read-json-body req))
    (define doc (if (hash? b) b (hasheq)))
    (define problem (executor-policy-problem doc))
    (cond
      [problem (err problem 400)]
      [else
       (define saved (executor-policy-set! db-conn 'instance "" doc))
       (audit! db-conn #:action "instance.executor_policy" #:actor-type "user"
               #:actor-id (principal-user-id p)
               ;; the ACTING operator's team: `audit-list` filters on it, and an
               ;; instance-tier entry written without one is invisible to
               ;; everybody (the `#:team-id` shape, which this file's own
               ;; `session.policy` entry two definitions above still has)
               #:team-id (principal-team-id p)
               #:resource-type "instance" #:resource-id "instance"
               #:meta (jsexpr->string
                       (hasheq 'labels (sort (map symbol->string
                                                  (hash-keys (hash-ref saved 'labels (hasheq))))
                                             string<?))))
       (json-response (policy-body saved))]))))

;; RED-34: THE INSTANCE TIER NEEDS A WAY OFF, and `PUT {"labels": {}}` is not
;; one — an empty labels object is an operator saying "govern nothing", which
;; still makes the policy CONFIGURED, and a configured policy refuses every
;; label it does not mention (RED-25). So without this an operator who turned
;; the feature on could never turn it off, and every labelled document in the
;; instance would be refused for ever. Found by a fixture: a smoke block left a
;; labelled document and an empty policy behind, and a section 150 lines later
;; stopped being able to read it.
(define (ep-executor-policy-clear req)
  (with-auth req (lambda (p)
    (require-perm db-conn p "instance:manage")
    (executor-policy-clear! db-conn 'instance "")
    (audit! db-conn #:action "instance.executor_policy.cleared" #:actor-type "user"
            #:actor-id (principal-user-id p) #:team-id (principal-team-id p)
            #:resource-type "instance" #:resource-id "instance")
    (json-response (policy-body #f)))))

(define (ep-my-org-executor-policy-get req)
  (with-mt req (lambda ()
    (with-auth req (lambda (p)
      (require-perm db-conn p "org:read")
      (define own (executor-policy-ref db-conn 'org (caller-org p)))
      (json-response
       (hash-set (policy-body own #:org-own (and own #t)
                             #:effective (executor-policy-effective db-conn (caller-org p))
                             #:sources (executor-policy-sources db-conn (caller-org p)))
                 'instance (or (executor-policy-ref db-conn 'instance) 'null))))))))

(define (ep-my-org-executor-policy-put req)
  (with-mt req (lambda ()
    (with-auth req (lambda (p)
      (require-perm db-conn p "org:manage")
      (define b (read-json-body req))
      (define doc (if (hash? b) b (hasheq)))
      (define problem (executor-policy-problem doc))
      (cond
        [problem (err problem 400)]
        [else
         (define saved (executor-policy-set! db-conn 'org (caller-org p) doc))
         (audit! db-conn #:action "org.executor_policy" #:actor-type "user"
                 #:actor-id (principal-user-id p) #:team-id (principal-team-id p)
                 #:org-id (caller-org p)
                 #:resource-type "org" #:resource-id (caller-org p))
         ;; the EFFECTIVE policy as well as what was stored, for the session
         ;; policy's reason: a company that listed an executor the instance does
         ;; not allow for that label gets the intersection, and finding that out
         ;; here beats discovering it when a document is refused
         (json-response
          (policy-body saved #:org-own #t
                       #:effective (executor-policy-effective db-conn (caller-org p))
                       #:sources (executor-policy-sources db-conn (caller-org p))))]))))))

(define (ep-my-org-executor-policy-clear req)
  (with-mt req (lambda ()
    (with-auth req (lambda (p)
      (require-perm db-conn p "org:manage")
      (executor-policy-clear! db-conn 'org (caller-org p))
      (audit! db-conn #:action "org.executor_policy.cleared" #:actor-type "user"
              #:actor-id (principal-user-id p) #:team-id (principal-team-id p)
              #:org-id (caller-org p)
              #:resource-type "org" #:resource-id (caller-org p))
      (json-response (policy-body #f #:org-own #f
                                  #:effective (executor-policy-effective db-conn (caller-org p)))))))))

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

;; ---- the timezone layers (#137) ----------------------------------------------
;; The instance default and the company's, over the same `instance_settings`
;; table session policy and branding already share. THE LAYERS DO NOT TIGHTEN,
;; unlike session policy two screens up: a timezone is not a control, so a
;; person's own choice wins over their company's and the company's over the
;; instance's. That is branding's rule (TEN-2d), and getting it backwards would
;; force somebody into the wrong clock to no one's benefit.
(define (ep-timezone-get req)
  (with-auth req (lambda (p)
    (require-perm db-conn p "instance:read")
    (json-response (hasheq 'timezone (or (instance-timezone db-conn) 'null)
                           'default DEFAULT-TIMEZONE
                           'available (length (available-zones)))))))

(define (ep-timezone-put req)
  (with-auth req (lambda (p)
    (require-perm db-conn p "instance:manage")
    (define b (read-json-body req))
    (define z (let ([v (hash-ref b 'timezone #f)]) (and v (format "~a" v))))
    (define problem (timezone-problem (or z "")))
    (cond
      [problem (err problem 400)]
      [else
       (set-instance-timezone! db-conn z)
;; `#:team-id` is the ACTING operator's team, which is #54's rule for an
       ;; instance-tier act: `audit-list` filters on it, so an entry without one
       ;; is invisible to every trail there is. The smoke caught exactly that —
       ;; the fourth appearance of this shape, and `session.policy` two screens
       ;; up still has it.
       (audit! db-conn #:action "instance.timezone" #:actor-type "user" #:actor-id (principal-user-id p)
               #:team-id (principal-team-id p)
               #:resource-type "instance" #:resource-id "instance" #:meta (jsexpr->string (hasheq 'timezone z)))
       (json-response (hasheq 'ok #t 'timezone z))]))))

(define (ep-my-org-timezone-get req)
  (with-mt req (lambda ()
    (with-auth req (lambda (p)
      (require-perm db-conn p "org:read")
      (define own (org-timezone db-conn (caller-org p)))
      (json-response (hasheq 'timezone (or own 'null)
                             'own (and own #t)
                             'instance (or (instance-timezone db-conn) 'null)
                             ;; what a member of this company gets with no zone
                             ;; of their own
                             'effective (timezone-for db-conn #:org (caller-org p)))))))))

(define (ep-my-org-timezone-put req)
  (with-mt req (lambda ()
    (with-auth req (lambda (p)
      (require-perm db-conn p "org:manage")
      (define b (read-json-body req))
      (define z (let ([v (hash-ref b 'timezone #f)]) (and v (format "~a" v))))
      (define problem (timezone-problem (or z "")))
      (cond
        [problem (err problem 400)]
        [else
         (set-org-timezone! db-conn (caller-org p) z)
         ;; `org-audit` INNER JOINs teams on team_id, so an org entry without
         ;; one is written and then invisible in the company's own trail.
         (audit! db-conn #:action "org.timezone" #:actor-type "user" #:actor-id (principal-user-id p)
                 #:team-id (principal-team-id p)
                 #:resource-type "org" #:resource-id (caller-org p)
                 #:meta (jsexpr->string (hasheq 'timezone z)))
         (json-response (hasheq 'ok #t 'timezone z))])))))) 

(define (ep-my-org-timezone-clear req)
  (with-mt req (lambda ()
    (with-auth req (lambda (p)
      (require-perm db-conn p "org:manage")
      (clear-org-timezone! db-conn (caller-org p))
      (audit! db-conn #:action "org.timezone.clear" #:actor-type "user" #:actor-id (principal-user-id p)
              #:team-id (principal-team-id p)
              #:resource-type "org" #:resource-id (caller-org p))
      (json-response (hasheq 'ok #t 'effective (timezone-for db-conn #:org (caller-org p)))))))))
