#lang racket/base

;; #128 job 2: operator-facing variables are read through ONE accessor,
;; which tries TMACH_<name> and falls back to TELEMACHUS_<name>.
(require (only-in "../../config.rkt" tmach-env))

;; server/api/instance.rkt — health, bootstrap, hosted provisioning and the
;; public /api/config
;;
;; Split out of main.rkt by #110 r3. The shared surface every handler here
;; needs — the pool, the request accessors, with-auth/with-mt, the response
;; constructors — is server/kit.rkt.

(provide ep-health ep-bootstrap ep-provision ep-activate ep-tenant
         ep-instance-quota ep-config)

(require db-kit/portable
         web-kit
         (only-in "../../domain/authz/authz.rkt" SESSION-KIND bootstrap! issue-token! team-org)
         (only-in "../../domain/beta/beta.rkt" default-team)
         (only-in "../../domain/beta/experience.rkt" experience-landing resolve-experience)
         (only-in "../../domain/i18n/policy.rkt" i18n-policy)
         (only-in "../../domain/saas/onboarding.rkt" activate! provision! set-tenant-quota!)
         (only-in "../../domain/quota/quota.rkt" default-policy!)
         (only-in "../../domain/authz/crypto.rkt" constant-time=?)
         (only-in "../../surface/messages.rkt" msg-already-init msg-bootstrap-done)
         "../kit.rkt")

;; ---- endpoints --------------------------------------------------------------
;; issue #11: the public liveness probe says the instance is up and nothing else.
;; The KDF, the version, the TLS flag and the codename used to ride here; they are
;; an operator's business and live on GET /api/admin/status now (instance:manage).
;; `multitenant` stays: it is a public product fact the console and the tenancy
;; demo read before signing in, and it says nothing about this instance's build.
(define (ep-health)
  (json-response (hasheq 'ok #t 'multitenant (multitenant?))))

;; issue #41: an un-bootstrapped instance belongs to whoever calls this first, and
;; on a network address that is a stranger. Bootstrap is an OPERATOR act, so it is
;; allowed from the box itself; an operator who genuinely cannot reach loopback
;; sets TELEMACHUS_BOOTSTRAP_SECRET and presents it. The refusal names both paths,
;; because "403" alone on a fresh instance reads as a broken build.
(define (bootstrap-allowed? req body)
  (or (header-identity-allowed? req)
      (let ([want (tmach-env "BOOTSTRAP_SECRET")]
            [got (or (let ([h (req-header req #"x-telemachus-bootstrap")]) (and (string? h) h))
                     (let ([v (hash-ref body 'secret #f)]) (and (string? v) v)))])
         (and want got (constant-time=? want got)))))

(define (ep-bootstrap req)
  (define body (read-json-body req))
  (define username (hash-ref body 'username #f))
  (cond
    [(saas-mode?) (err "interactive bootstrap is disabled in hosted mode" 403)]
    [(not (bootstrap-allowed? req body))
     (err (string-append "bootstrap is allowed from this host only. Run it on the server, "
                         "or set TMACH_BOOTSTRAP_SECRET and send it as X-Telemachus-Bootstrap.")
          403)]
    [(not username) (err "username required" 400)]
    [(query-maybe-value db-conn "SELECT id FROM users LIMIT 1") (err (msg-already-init) 409)]
    [else
     (define mt (multitenant?))
     (define-values (uid tid)
       (bootstrap! db-conn #:username username #:password (hash-ref body 'password #f)
                   ;; multitenant: the superadmin runs the INSTANCE and belongs to no
                   ;; customer company — it gets the `system` org. Single-tenant: the
                   ;; one implicit org, exactly as before (RBAC-5).
                   #:org-name (if mt "Instance Operations" "Default Organization")
                   #:org-slug (if mt "system" "default")
                   #:team-name (if mt "Instance" "Default")
                   #:team-slug (if mt "instance" "default")))
     (default-policy! db-conn tid)                       ; starter AI quota for the team
     (define-values (tok _t) (issue-token! db-conn #:user uid #:team tid #:name "bootstrap" #:scopes '("*:*") #:kind SESSION-KIND))
     (json-response (hasheq 'user_id uid 'team_id tid 'token tok 'multitenant mt
                            'org_id (team-org db-conn tid)
                            'message (msg-bootstrap-done username (if mt "Instance" "Default")))
                    #:code 201)]))

;; ---- hosted provisioning (control-plane facing; provision-token auth) --------
(define (require-provision-token req)
  (define want (tmach-env "PROVISION_TOKEN"))
  (define got (req-header req #"x-provision-token"))
  (and want got (string=? want got)))

(define (ep-provision req)
  (cond
    [(not (saas-mode?)) (err "not in hosted mode" 404)]
    [(not (require-provision-token req)) (err "invalid provision token" 403)]
    [else
     (define b (read-json-body req))
     (define email (hash-ref b 'owner_email #f))
     (define pid (hash-ref b 'provision_id #f))
     (cond
       [(or (not email) (not pid)) (err "owner_email and provision_id required" 400)]
       [else
         (define-values (tok uid tid state)
          (provision! db-conn #:provision-id (format "~a" pid) #:owner-email (format "~a" email)
                      #:owner-name (hash-ref b 'owner_name #f) #:org (hash-ref b 'org #f)
                      #:plan (format "~a" (hash-ref b 'plan "trial"))
                      #:source (format "~a" (hash-ref b 'source "signup"))))
         (json-response (hasheq 'provision_id pid 'owner_user_id uid 'team_id tid
                               'state (symbol->string state)
                               'activation_url (and tok (string-append (public-base req) "/activate?token=" tok))))])]))

(define (ep-activate req)
  (define b (read-json-body req))
  (define tok (hash-ref b 'token #f))
  (define pw (hash-ref b 'password #f))
  (cond
    [(or (not tok) (not pw)) (err "token and password required" 400)]
    [(< (string-length (format "~a" pw)) 8) (err "password must be at least 8 characters" 400)]
    [else
     (define res (call-with-values
                  (lambda () (activate! db-conn #:token (format "~a" tok) #:password (format "~a" pw))) list))
     (if (equal? res '(#f))
         (err "invalid or expired activation link" 400)
         (json-response (hasheq 'token (caddr res) 'user_id (car res) 'team_id (cadr res))))]))

(define (ep-tenant req action)
  (cond
    [(not (saas-mode?)) (err "not in hosted mode" 404)]
    [(not (require-provision-token req)) (err "invalid provision token" 403)]
    [else
     (define pid (hash-ref (read-json-body req) 'provision_id #f))
     (cond
       [(not pid) (err "provision_id required" 400)]
       [(action db-conn #:provision-id (format "~a" pid)) (json-response (hasheq 'ok #t 'provision_id pid))]
       [else (err "unknown provision_id" 404)])]))

;; billing-lifecycle quota change by provision_id (provider auth)
(define (ep-instance-quota req)
  (cond
    [(not (saas-mode?)) (err "not in hosted mode" 404)]
    [(not (require-provision-token req)) (err "invalid provision token" 403)]
    [else
     (define b (read-json-body req))
     (define pid (hash-ref b 'provision_id #f))
     (define dim (hash-ref b 'dimension #f))
     (define lim (hash-ref b 'limit #f))
     (cond
       [(or (not pid) (not dim) (not lim)) (err "provision_id, dimension, limit required" 400)]
       [(set-tenant-quota! db-conn #:provision-id (format "~a" pid) #:dimension (format "~a" dim)
                           #:limit lim #:window (format "~a" (hash-ref b 'window "day")))
         (json-response (hasheq 'ok #t 'provision_id pid 'dimension dim 'limit lim))]
       [else (err "unknown provision_id" 404)])]))

(define (ep-config req)          ; public: tells the SPA what the root route should render
  (define team (default-team db-conn))
  (json-response (hasheq 'home (home-mode) 'service "telemachus"
                         'multitenant (multitenant?)
                         ;; PUBLIC, and it has to be: the sign-in screen must know
                         ;; which language to render in before anyone has a token,
                         ;; and whether to offer the switcher at all.
                         'localization (i18n-policy db-conn (locales-dir))
                         'onboarding (hash-ref (resolve-experience db-conn team) 'name "beta")
                         'landing (experience-landing db-conn team))))
