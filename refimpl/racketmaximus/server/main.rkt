#lang racket/base

;; #128 job 2: operator-facing variables are read through ONE accessor,
;; which tries TMACH_<name> and falls back to TELEMACHUS_<name>.
(require (only-in "../config.rkt" tmach-env legacy-env-warning))

;; server/main.rkt — the HTTP surface (slice 3). Wires web-kit + AuthzService +
;; the Localizer:
;;   • identity from `Authorization: Bearer <token>` (issuer-perms ∩ scopes) or a
;;     trusted `X-Telemachus-User` + `X-Telemachus-Team` (dev / trusted proxy);
;;   • per-request locale from `Accept-Language` → responses (incl. 401/403) are
;;     localized;
;;   • RBAC enforced with `require-perm` (raises → localized 403).
;;
;;   racket server/main.rkt            # serves on http://127.0.0.1:8835 (PORT to override)
;;
;; WHAT IS LEFT IN HERE, since #110 r3 split it: the HANDLERS table, the
;; dispatcher that enforces what server/routes.rkt declares, the plugin-route
;; mount, the security headers and the boot sequence. The handlers themselves are
;; server/api/*.rkt; what they share is server/kit.rkt and server/admission.rkt.
;; The declared surface — every route, its permission and one line of doc — is
;; server/routes.rkt, and docs/reference/api.md is generated from it.

(require racket/list
         racket/string
         db-kit/portable
         web-server/http
         json
         web-kit
         (only-in web-kit/http1 http1-listen)
         db-kit
         (only-in "../config.rkt" impl-root max-upload-bytes)
         (only-in "../domain/db/migrations.rkt" all-migrations)
         (only-in "../domain/authz/authz.rkt" exn:fail:forbidden-permission exn:fail:forbidden? principal-org-id principal-team-id principal-user-id require-perm team-org)
         (only-in "../domain/authz/passwords.rkt" kdf-name)
         (only-in "../domain/apps/translate.rkt" translate!)
         (only-in "../domain/beta/beta.rkt" parse-verdict prospect-field prospect-get set-prospect-judge!)
         (only-in "../domain/beta/experience.rkt" experience-judge-system resolve-experience)
         (only-in "../domain/i18n/manager.rkt" draft-acceptable? l10n-message-ref l10n-submit!)
         (only-in net/url url-query)
         (only-in "plugin-route.rkt" headers->hash plugin-route-response)
         (only-in "../domain/saas/onboarding.rkt" provision! resume! suspend!)
         (only-in "../domain/quota/quota.rkt" get-limit quota-record!)
         (only-in "../domain/sched/scheduler.rkt" current-job drain-scheduler! drain-seconds register-job-kind! set-reaper! start-scheduler!)
         (only-in "../domain/sched/schedules.rkt" fire-due-schedules!)
         ;; #85: the event sink and the delivery sweep
         (only-in "../domain/hooks/webhooks.rkt" deliver-due! enqueue-event!)
         (only-in "../domain/events/events.rkt" add-event-sink!)
         (only-in "../domain/s3/server.rkt" make-s3-handler reap-uploads! s3-region)
         (only-in "../domain/audit/chain.rkt" audit-chain-seal!)
         ;; #114 slice 4: the feed poller, its first adapter, and the job kind a
         ;; feed's schedule fires
         (only-in "../domain/feeds/poll.rkt" poll-feed!)
         (only-in "../domain/feeds/adapter-github.rkt" install-github-adapter!)
         (only-in "../domain/feeds/feeds.rkt" POLL-KIND feed-by-id)
         ;; #66: the external anchor, emitted on the reaper seam
         (only-in "../domain/audit/anchor.rkt" anchor-emit!)
         (only-in "../domain/authz/signing.rkt" anchor-signing-enabled?)
         (only-in "../domain/idem/idem.rkt" idem-reap!)
         (only-in "../domain/retention/retention.rkt" retention-sweep!)
         "routes.rkt"                             ; the declared HTTP surface (slice 60)
         (only-in "../domain/repo/blobs.rkt" blob-root blob-store-names blob-store-probe
                  active-blob-store-name)
         (only-in "../domain/repo/repo.rkt" reap-staged-blobs!)
         (only-in "../domain/flow/spec.rkt" exn:fail:spec?)
         (only-in "../domain/ai/executor.rkt" estimate-tokens model-configured? model-request-logger
                  egress-policy pull-router run-chat)
         (only-in "../domain/ai/content.rkt" content->text)
         (only-in "../domain/authz/secretbox.rkt" secret-key-id secrets-enabled?)
         (only-in "../domain/exec/federation.rkt" connect-executors!)
         (only-in "../domain/exec/pull.rkt" executor-by-name load-push-executors! pull-dispatch! reap-leases!
                  ;; #173: the "any host" sentinel
                  fleet-request?)
         ;; RED-17: the model-request log's writer (issue #91 requirement 3)
         (only-in "../domain/ai/requestlog.rkt" model-request-record!)
         ;; #91 req 4: where a labelled document's text may go, and the host of
         ;; the backend it was about to go to (never the key, never the query)
         (only-in "../domain/ai/sensitivity.rkt" make-egress-policy)
         (only-in "../domain/judge/judge.rkt" judgments-in-result register-judge-kind!)
         (only-in "../domain/ai/roles.rkt" model-role-executor)
         (only-in "../domain/agent/run.rkt" agent-configured? run-agent-flow)
         (only-in "../domain/agent/plugins.rkt" load-plugins! plugin-failures plugin-routes
                  plugin-migrations)
         ;; #121: a plugin's tables go through the platform's own runner
         (only-in db-kit/migrate migrate!)
         (only-in "../domain/mcp/connect.rkt" connect-mcp-servers!)
         (only-in "../domain/oop/host.rkt" connect-oop-plugins!)
         (only-in "../domain/i18n/i18n.rkt" current-localizer t)
         (only-in "../surface/messages.rkt" msg-forbidden)
         ;; REQUIRED FOR THEIR SIDE EFFECT: each registers tools when it is
         ;; instantiated and exports nothing anybody imports, so #110 r3's
         ;; computed import list dropped all three. Keep them. The three shipped
         ;; plugins that own the matching workflows require them too, so the
         ;; registry is populated either way on a default install — but an
         ;; operator may legitimately not load those plugins (TELEMACHUS_PLUGINS),
         ;; and these lines are what keeps `doc_text` and its siblings available
         ;; to the agent when they are absent. Positive-controlled: dropping one
         ;; here leaves the tool registered BY THE PLUGIN, which is why the
         ;; control had to be run with the plugin out as well.
         (only-in "../domain/repo/index-tools.rkt")      ; slice 54
         (only-in "../domain/repo/embed-tools.rkt")      ; #189 step 4
         (only-in "../domain/repo/doc-tools.rkt")        ; slice 57
         (only-in "../domain/kg/kg-tools.rkt")           ; slice 61
         ;; issue #89: the checks an instance runs before it serves. Their own
         ;; module so they are unit-testable without a live server.
         (only-in "startup.rkt" report-startup-problems! startup-problems))

;; #110 r3: the pool, the request accessors, the identity wrappers and the
;; response constructors every handler shares, plus the admission gates a
;; metered endpoint passes. See server/kit.rkt for why `db-conn` lives there
;; rather than here.
(require "kit.rkt" "admission.rkt")

;; #110 r3: the handlers themselves, one module per area. main.rkt keeps the
;; route table, the dispatcher and the boot sequence.
(require "api/accounts.rkt"
         "api/admin.rkt"
         "api/ai.rkt"
         "api/beta.rkt"
         "api/branding.rkt"
         "api/content.rkt"
         "api/features.rkt"
         "api/flow.rkt"
         "api/instance.rkt"
         "api/jobs.rkt"
         "api/webhooks.rkt"
         "api/feeds.rkt"
         "api/annotations.rkt"
         "api/localization.rkt"
         "api/orgs.rkt"
         "api/policy.rkt"
         "api/repo.rkt"
         "api/reviews.rkt"
         "api/tokens.rkt"
         "api/translate.rkt"
         "api/usage.rkt")

;; ---- routing ----------------------------------------------------------------
;; The surface is DECLARED in server/routes.rkt (method, path, handler key,
;; permission, auth, feature, doc) and rendered into docs/reference/api.md from
;; there. This table binds each key to a procedure of (req . path-params); the
;; boot check below refuses to serve if the two disagree in either direction, so
;; an endpoint cannot exist without a documented entry, or an entry without code.
(define HANDLERS
  (hasheq
   'ui (lambda (req)
         ;; the console's own policy, stricter than the baseline: no inline script
         ;; at all since #110 r6, so no 'unsafe-inline' and no nonce either
         (response/output #:mime-type #"text/html; charset=utf-8"
                          #:headers (list (make-header #"Content-Security-Policy"
                                                       (string->bytes/utf-8 (console-csp))))
                          (lambda (out) (write-string (ui-html-branded req) out))))
   'health (lambda (req) (ep-health))
   'beta-sdk (lambda (req) (serve-file (build-path impl-root "static" "beta-sdk.js")))
   ;; #110 r6: the console's own script, one file per area. `safe-seg?` on every
   ;; segment is what keeps this from climbing out of static/console — `..` and a
   ;; slash are not names — and the directory holds nothing but the console's
   ;; scripts, so there is nothing else under it to reach.
   'console-file (lambda (req path)
                   (define segs (filter (lambda (s) (not (string=? s "")))
                                        (string-split (or path "") "/")))
                   (if (and (pair? segs) (andmap safe-seg? segs))
                       ;; `no-store`, not serve-file's 5-minute default. These
                       ;; files used to be INLINE in a document nothing caches, so
                       ;; a browser re-fetched them on every navigation anyway and
                       ;; this is not a regression — but a cached script WOULD be:
                       ;; the shell is uncached, so after a deploy a returning
                       ;; visitor could run a new shell against a stale script for
                       ;; five minutes, and the two disagreeing about a DOM id is
                       ;; a console that half works. Content-hashed names are the
                       ;; other answer and they need the build step #110 r6 exists
                       ;; to avoid.
                       (serve-file (apply build-path impl-root "static" "console" segs)
                                   #:cache #"no-store")
                       (err "not found" 404)))
   'bundle-file (lambda (req plugin path)
                  (define f (bundle-file-path (request-path req)))
                  (if f (serve-file f) (err "not found" 404)))
   ;; issue #20: authenticated, and never publicly cached. `Vary: Authorization`
   ;; so no intermediary can hand one principal's request to another.
   'plugin-bundle (lambda (req plugin path)
                    ;; a bearer (the console's own fetches, curl, the smoke) OR a
                    ;; ticket — in the query for the first navigation, in the
                    ;; cookie for everything the page then loads (issue #43)
                    ;; query-param's default is "" and an empty string is TRUE in
                    ;; Racket, so `or` alone would take it and never look at the
                    ;; cookie — which is how every sub-resource 401'd the first
                    ;; time this ran.
                    (define ticket (let ([q (query-param req 'ticket #f)])
                                     (or (and (string? q) (not (string=? q "")) q)
                                         (bundle-cookie-of req))))
                    (define via-ticket (and ticket (bundle-ticket-valid? ticket plugin)))
                    (define (serve-it set-cookie?)
                      (define f (plugin-bundle-file-path plugin path))
                      (if f
                          (serve-file f #:cache #"private, no-store"
                                      #:headers (append
                                                 (list (make-header #"Vary" #"Authorization, Cookie"))
                                                 (if set-cookie?
                                                     (list (make-header
                                                            #"Set-Cookie"
                                                            (string->bytes/utf-8
                                                             (format "tmx_bundle=~a; Path=/api/x/~a/bundle/; Max-Age=~a; HttpOnly; SameSite=Strict~a"
                                                                     ticket plugin BUNDLE-TICKET-SECONDS
                                                                     (if (tls-on?) "; Secure" "")))))
                                                     '())))
                          (err "not found" 404)))
                    (cond
                      [via-ticket (serve-it (and (query-param req 'ticket) #t))]
                      [else (with-auth req (lambda (p) (serve-it #f)))]))
   'plugin-bundle-ticket (lambda (req plugin)
                           (with-auth req
                             (lambda (p)
                               (cond
                                 [(not (plugin-root plugin "bundle"))
                                  (err "no such plugin bundle" 404)]
                                 [else
                                  (define t (bundle-ticket-mint! plugin p))
                                  (json-response
                                   (hasheq 'ticket t 'expires_in BUNDLE-TICKET-SECONDS
                                           'url (format "/api/x/~a/bundle/?ticket=~a" plugin t)))]))))
   'beta-template ep-beta-template
   'config ep-config
   'branding-get ep-branding-get 'branding-put ep-branding-put 'branding-logo ep-branding-logo
   'i18n-catalog ep-i18n-catalog 'i18n-put ep-i18n-put
   'l10n-coverage ep-l10n-coverage 'l10n-messages ep-l10n-messages 'l10n-import ep-l10n-import
   'l10n-export ep-l10n-export 'l10n-draft ep-l10n-draft 'l10n-discard ep-l10n-discard
   'l10n-submit ep-l10n-submit 'l10n-review ep-l10n-review
   'beta-config ep-beta-config 'cors-preflight (lambda (req) (cors-preflight))
   'beta-experience-get ep-beta-experience-get 'beta-experience-put ep-beta-experience-put
   'beta-experience-publish ep-beta-experience-publish
   'beta-asset-upload ep-beta-asset-upload 'beta-assets ep-beta-assets
   'beta-asset ep-beta-asset 'beta-asset-delete ep-beta-asset-delete
   'beta-challenge ep-beta-challenge 'beta-signup ep-beta-signup
   'beta-prospects ep-beta-prospects 'beta-decide ep-beta-decide
   'bootstrap ep-bootstrap 'provision ep-provision 'activate ep-activate
   'tenant-suspend (lambda (req) (ep-tenant req suspend!))
   'tenant-resume (lambda (req) (ep-tenant req resume!))
   'instance-quota ep-instance-quota
   'login ep-login '2fa-enable ep-2fa-enable '2fa-reset ep-2fa-reset
   'sessions-list ep-sessions-list 'logout ep-logout
   'sessions-revoke-others ep-sessions-revoke-others 'session-revoke ep-session-revoke
   '2fa-codes-new ep-2fa-codes-new '2fa-codes-get ep-2fa-codes-get
   'admin-2fa-reset ep-admin-2fa-reset 'password ep-password
   'whoami ep-whoami 'profile ep-profile 'add-member ep-add-member 'members-list ep-members-list
   'admin-status ep-admin-status
   'orgs-create ep-orgs-create 'orgs-list ep-orgs-list
   'org-suspend (lambda (req ref) (ep-org-status req ref "suspended"))
   'org-resume (lambda (req ref) (ep-org-status req ref "active"))
   'org-quota ep-org-quota 'org-get ep-org-get 'org-update ep-org-update
   'seed-tenants ep-seed-tenants
   'my-org ep-my-org 'my-org-teams ep-my-org-teams 'my-org-team-create ep-my-org-team-create
   'my-org-team-quota ep-my-org-team-quota
   'my-org-member-add ep-my-org-member-add 'my-org-member-role ep-my-org-member-role 'my-org-audit ep-my-org-audit
   'session-policy-get ep-session-policy-get 'session-policy-put ep-session-policy-put
   'executor-policy-get ep-executor-policy-get 'executor-policy-put ep-executor-policy-put
   'executor-policy-clear ep-executor-policy-clear
   'my-org-executor-policy-get ep-my-org-executor-policy-get
   'my-org-executor-policy-put ep-my-org-executor-policy-put
   'my-org-executor-policy-clear ep-my-org-executor-policy-clear
   'timezones ep-timezones
   'timezone-get ep-timezone-get 'timezone-put ep-timezone-put
   'my-org-timezone-get ep-my-org-timezone-get 'my-org-timezone-put ep-my-org-timezone-put
   'my-org-timezone-clear ep-my-org-timezone-clear
   'my-org-session-policy-get ep-my-org-session-policy-get
   'my-org-session-policy-put ep-my-org-session-policy-put
   'my-org-session-policy-clear ep-my-org-session-policy-clear
   'my-org-branding-get ep-my-org-branding-get 'my-org-branding-put ep-my-org-branding-put
   'my-org-branding-clear ep-my-org-branding-clear 'my-org-branding-logo ep-my-org-branding-logo
   'notes-create ep-notes-create 'notes-list ep-notes-list
   'documents-create ep-documents-create 'documents-list ep-documents-list
   'documents-get ep-documents-get 'documents-update ep-documents-update 'documents-delete ep-documents-delete
   'notes-share ep-notes-share 'notes-get ep-notes-get 'notes-update ep-notes-update 'notes-delete ep-notes-delete
   'ai-echo ep-ai-echo 'ai-chat ep-ai-chat 'ai-chat-stream ep-ai-chat-stream 'agent ep-agent
   'translate-catalog ep-translate-catalog 'translate ep-translate 'translate-list ep-translate-list
   'glossary-add ep-glossary-add 'glossary-list ep-glossary-list
   'ai-model ep-ai-model 'executors ep-executors 'admin-workers ep-admin-workers
   'executor-create ep-executor-create 'executor-retire ep-executor-retire 'org-executor-create ep-org-executor-create
   'executor-drain ep-executor-drain 'executor-resume ep-executor-resume
   'executor-rotate-token ep-executor-rotate-token
   'worker-token-get ep-worker-token-get 'worker-token-rotate ep-worker-token-rotate 'admin-queue ep-admin-queue
   'repo-fields-get ep-repo-fields-get 'repo-fields-put ep-repo-fields-put
   'repo-attributes ep-repo-attributes 'repo-spans ep-repo-spans
   'member-role ep-member-role 'member-remove ep-member-remove
   'admin-password-reset ep-admin-password-reset
   'reviews-list ep-reviews-list 'review-get ep-review-get 'review-decide ep-review-decide
   'review-stats ep-review-stats 'review-verify ep-review-verify
   'model-roles-get ep-model-roles-get 'model-roles-put ep-model-roles-put
   'worker-claim ep-worker-claim 'worker-state ep-worker-state 'worker-heartbeat ep-worker-heartbeat 'worker-complete ep-worker-complete 'worker-fail ep-worker-fail 'worker-release ep-worker-release
   'usage ep-usage 'quota-set ep-quota-set 'tools-list ep-tools-list
   'tokens-create ep-tokens-create 'tokens-list ep-tokens-list 'tokens-revoke ep-tokens-revoke
   'search ep-search 'audit ep-audit 'model-requests ep-model-requests
   'webhooks-list ep-webhooks-list 'webhooks-create ep-webhooks-create
   'webhook-get ep-webhook-get 'webhook-patch ep-webhook-patch 'webhook-delete ep-webhook-delete
   'webhook-ping ep-webhook-ping 'webhook-deliveries ep-webhook-deliveries
   'delivery-redeliver ep-delivery-redeliver
   ;; #114: external feed configuration. Nothing polls one yet — slice 4 is the
   ;; adapter — so the probe is what answers "is this configured right".
   'feeds-list ep-feeds-list 'feeds-create ep-feeds-create 'feed-get ep-feed-get
   'feed-patch ep-feed-patch 'feed-delete ep-feed-delete 'feed-probe ep-feed-probe
   'feed-poll ep-feed-poll
   ;; #65: a region a person marked. LAY-5's spans are where a machine says it
   ;; read something; these are what somebody said about a place.
   'repo-form-fields ep-repo-form-fields
   'annotations-list ep-annotations-list 'annotations-create ep-annotations-create
   'annotation-get ep-annotation-get 'annotation-patch ep-annotation-patch
   'annotation-delete ep-annotation-delete
   'jobs-create ep-jobs-create 'jobs-list ep-jobs-list 'job-cancel ep-job-cancel 'job-get ep-job-get
   'job-purge ep-job-purge
   ;; #135: the clock. The firing itself is on the reaper seam below.
   'schedules-list ep-schedules-list 'schedules-create ep-schedules-create
   'schedule-get ep-schedule-get 'schedule-patch ep-schedule-patch 'schedule-delete ep-schedule-delete
   'worker-document ep-worker-document
   'worker-derive ep-worker-derive
   'repo-list ep-repo-list 'repo-share ep-repo-share 'repo-unshare ep-repo-unshare 'repo-grants ep-repo-grants
   'repo-derivations ep-repo-derivations 'repo-processing ep-repo-processing 'share-targets ep-share-targets
   'repo-visibility ep-repo-visibility 'repo-get ep-repo-get 'repo-presign ep-repo-presign
   'repo-reads ep-repo-reads
   'instance-features ep-instance-features 'instance-features-put ep-instance-features-put
   'org-features ep-org-features 'org-features-put ep-org-features-put
   'audit-verify ep-audit-verify 'audit-export ep-audit-export
   ;; #66: the external anchor for both hash chains
   'anchor-status ep-anchor-status 'anchor-emit ep-anchor-emit
   'anchor-receipts ep-anchor-receipts 'anchor-export ep-anchor-export
   'repo-meta ep-repo-meta 'repo-delete ep-repo-delete 'repo-put ep-repo-put
   'repo-traces ep-repo-traces 'repo-delete-prefix ep-repo-delete-prefix
   'retention-get ep-retention-get 'retention-put ep-retention-put
   'retention-plan-get ep-retention-plan-get 'legal-hold-put ep-legal-hold-put
   'my-org-retention-get ep-my-org-retention-get 'my-org-retention-put ep-my-org-retention-put
   's3-creds ep-s3-creds 's3-cred-create ep-s3-cred-create 's3-cred-revoke ep-s3-cred-revoke
   'workflows-create ep-workflows-create 'workflows-list ep-workflows-list 'workflow-schema ep-workflow-schema
   'workflow-run ep-workflow-run
   'doc-triggers-list ep-doc-triggers-list 'doc-triggers-create ep-doc-triggers-create
   'doc-trigger-get ep-doc-trigger-get 'doc-trigger-update ep-doc-trigger-update 'doc-trigger-delete ep-doc-trigger-delete
   'workflow-get ep-workflow-get 'runs-list ep-runs-list 'run-cancel ep-run-cancel 'run-get ep-run-get
   'kg-entities ep-kg-entities 'kg-entity ep-kg-entity 'kg-extract ep-kg-extract
   'admin-seed ep-admin-seed 'metrics ep-metrics 'features ep-features 'feature-toggle ep-feature-toggle
   'plugins ep-plugins 'mcp ep-mcp 'oop ep-oop 'tool-toggle ep-tool-toggle))

;; every declared route has a handler, and every handler is declared
(let ([declared (remove-duplicates (map rt-handler ROUTES))])
  (for ([k (in-list declared)])
    (unless (hash-has-key? HANDLERS k)
      (error 'routes "server/routes.rkt declares handler '~a' which server/main.rkt does not define" k)))
  (for ([k (in-hash-keys HANDLERS)])
    (unless (memq k declared)
      (error 'routes "server/main.rkt has handler '~a' which server/routes.rkt does not declare" k))))

;; ---- plugin routes (slice 63) -----------------------------------------------------
;; Built once from the loader's registry, AFTER plugins load (see main). Every one
;; is authenticated — with-auth, then the route's permission — and its handler is
;; the plugin's (conn principal args) -> jsexpr, where args carries the path
;; params, the query, the JSON body and the request headers (read only). A user
;; error is the caller's 400. A handler that returns a response keeps control of
;; the status, the headers and the media type (server/plugin-route.rkt).
(define PLUGIN-ROUTES (box '()))          ; (listof (cons rt handler-proc))
(define (install-plugin-routes!)
  (set-box! PLUGIN-ROUTES
    (for/list ([r (in-list (plugin-routes))])
      ;; Built through `R` rather than the `rt` constructor POSITIONALLY. It was
      ;; positional, and adding #110 r2's `scope` field broke plugin routes at
      ;; BOOT with an arity mismatch — which the full suite had already passed
      ;; before that field existed, and only the control that strips a handler's
      ;; own permission check caught. `R` carries the defaults, so the next field
      ;; added to the struct cannot do this again.
      (define entry (R (hash-ref r 'method)
                       (plugin-route-path (hash-ref r 'plugin) (hash-ref r 'path))
                       (string->symbol (string-append "plugin:" (hash-ref r 'plugin)))
                       #:perm (hash-ref r 'perm)
                       #:doc (hash-ref r 'doc)))
      (define perm (hash-ref r 'perm))
      (define handler (hash-ref r 'handler))
      (define names (route-params entry))
      (cons entry
            (lambda (req . vals)
              (with-auth req (lambda (p)
                (when perm (require-perm db-conn p perm))
                (with-handlers ([exn:fail:user? (lambda (e) (err (exn-message e) 400))])
                  (define args
                    (hasheq 'params (for/hasheq ([n (in-list names)] [v (in-list vals)]) (values (string->symbol n) v))
                            'query (for/hasheq ([kv (in-list (url-query (request-uri req)))] #:when (cdr kv))
                                     (values (car kv) (cdr kv)))
                            'body (read-json-body req)
                            'headers (headers->hash (request-headers/raw req))))
                  (plugin-route-response (handler db-conn p args))))))))))

;; ---- the route table ENFORCES what it declares (#110 r2) -----------------------
;; `rt-auth`, `rt-perm` and `rt-feature` were documentation: `route` read
;; `rt-handler` and nothing else, and all 187 handlers did auth, permission and
;; feature by hand. `GET /api/retention` is what forgetting looked like — it
;; declared `files:read` and enforced nothing, and any authenticated caller could
;; read the instance's retention policy (#109).
;;
;; THE ORDER IS LOAD-BEARING, and it is the reason this is a `cond` and not three
;; independent checks:
;;
;;   1. `with-mt` FIRST for the two multi-tenancy planes, because the flag gate
;;      answers 404 — "this feature is invisible when off" — and a permission
;;      check answers 403. Reversed, a single-tenant instance would tell an
;;      anonymous caller that `/api/org/features` exists and they may not have it.
;;      Both smokes pin the 404.
;;   2. then authentication, so an unauthenticated caller gets 401 and never a
;;      message about a permission.
;;   3. then the FEATURE flag, which is team-scoped and says "not on this
;;      instance/org/team" rather than "not you".
;;   4. then the permission — and only a ROLE-scoped one.
;;
;; WHY NOT EVERY PERMISSION — and why `scope` is per ROUTE. Pre-checking a
;; permission by ROLE where the handler weighs it against a RESOURCE would be
;; strictly tighter than `can?`, which also admits the owner and anyone holding a
;; matching grant. It would refuse exactly the cases sharing exists for: the
;; viewer handed `edit`, the owner of a private document whose role grants
;; nothing. DSH-1 made a grant confer the permission on one resource and this must
;; not take that back, so the 30 routes that name a resource declare
;; `#:scope 'resource` and the dispatcher leaves them alone.
;;
;; THE FIRST VERSION DERIVED THIS FROM THE PERMISSION and was wrong. `files:read`
;; on /api/repo-obj/:id/content has a resource to weigh; on /api/retention there
;; is none. Treating the permission as resource-scoped everywhere left
;; /api/retention unchecked by the dispatcher while looking covered — found by
;; stripping that handler's own `require-perm` and watching the request succeed.
;; A create or a list is role-scoped: `repo-list`, `kg-find` and `flow-runs` each
;; require their permission up front before any per-row filtering, so moving that
;; check earlier is equivalent and not stricter — which was verified one function
;; at a time rather than assumed.
;;
;; The handlers still carry their own checks. That is deliberate for now: this
;; change is about making the declaration authoritative, and removing 93
;; now-redundant lines is a separate step with its own verification — doing both
;; at once would leave no way to tell which half broke something.
(define (dispatch entry params req)
  (define h (hash-ref HANDLERS (rt-handler entry)))
  (define (run) (apply h req params))
  (define (authed)
    (with-auth req (lambda (p)
      (define f (rt-feature entry))
      (when f (require-feature p f))
      (define perm (rt-perm entry))
      (when (and perm (eq? (rt-scope entry) 'role)) (require-perm db-conn p perm))
      (run))))
  (case (rt-auth entry)
    [(public) (run)]
    ;; 'provision is the control plane's own token, resolved by its handlers
    ;; against TELEMACHUS_PROVISION_TOKEN and not by `with-auth` at all
    [(provision) (run)]
    ;; 'handler: a bearer OR a ticket, and only the handler can tell (issue #43)
    [(handler) (run)]
    [(superadmin org-admin) (with-mt req authed)]
    [else (authed)]))

(define (route req)
  ;; HEAD must reach every GET route: monitors, link unfurlers and health
  ;; checkers probe with HEAD, and before 2026-09-04 every one of them got a
  ;; JSON 404 from a perfectly healthy server (hit live on beta.rcn-t.com:
  ;; HEAD / returned 404 while GET / returned the app). web-server's response
  ;; layer already suppresses response bodies for HEAD requests
  ;; (web-server/http/response), so matching HEAD as GET is sufficient and no
  ;; route can accidentally emit a body.
  (define m (let ([rm (request-method req)])
              (bytes->string/utf-8 (if (bytes=? rm #"HEAD") #"GET" rm))))
  (define-values (entry params) (match-route m (request-path req)))
  (cond
    [entry (dispatch entry params req)]
    [else
     ;; then the plugins' — under /api/x/<id>/ only, so nothing here can have
     ;; shadowed a core route above
     (define-values (pentry pparams) (match-routes (map car (unbox PLUGIN-ROUTES)) m (request-path req)))
     (cond
       [pentry (apply (cdr (assq pentry (unbox PLUGIN-ROUTES))) req pparams)]
       [else (err "not found" 404)])]))

;; issue #11: baseline security headers on EVERY response, added at the one seam
;; every response passes through. Zero-risk set: nosniff (a JSON body is never
;; sniffed into a script), a referrer policy (the console's URLs carry object ids
;; and tokens never, but the origin is enough for anyone), frame denial (the
;; console is not meant to be framed — the Tier-C funnel template is served
;; INTO an iframe by the console itself, same origin, which SAMEORIGIN allows),
;; and HSTS only when the instance says it is behind TLS. A Content-Security-Policy
;; for the console is a separate audit (it has inline scripts); the download path
;; already sends a denying one per object. A route that sets one of these itself
;; wins — headers already present are left alone.
;; The console's Content-Security-Policy (issue #11 part 2, #27, and #110 r6).
;;
;; What it buys: no script, style, image, font, frame or connection from any
;; origin but our own, no plugins, no <base> hijack, no form posting elsewhere,
;; no framing by other origins — so an injected payload can neither load remote
;; code nor beacon data out. Downloads keep their own, stricter, per-object CSP
;; (a header already present wins).
;;
;; THE CONSOLE NOW HAS NO INLINE SCRIPT AT ALL, so `script-src` is plain
;; `'self'`. The history is worth keeping because each step depended on the one
;; before it: the policy could not drop `'unsafe-inline'` while 141 inline event
;; handlers existed (an attribute cannot be nonced), so #27 moved them to
;; delegated listeners and the policy became a per-request NONCE over one inline
;; block; #110 r6 moved that block into static/console/*.js, which `'self'`
;; already permitted. A nonce only ever authorized OUR OWN inline script — it
;; protects nothing on its own — so with none left it authorizes nothing and is
;; gone. An injected inline script was blocked by the absence of
;; `'unsafe-inline'` before and is blocked by it now.
;;
;; `inline?` is for the BASELINE policy every OTHER response carries, which keeps
;; `'unsafe-inline'`: a plugin's own bundle page may legitimately ship inline
;; script, and that page is not the console.
;;
;; style-src keeps `'unsafe-inline'` either way, deliberately: there are still
;; ~250 style attributes in the console, and injected CSS is a far smaller prize
;; than injected script. That is a separate tranche.
(define (console-csp [inline? #f])
  (string-append "default-src 'self'; "
                 "script-src 'self'" (if inline? " 'unsafe-inline'" "") "; "
                 "style-src 'self' 'unsafe-inline'; "
                 "img-src 'self' data: blob:; font-src 'self' data:; connect-src 'self'; "
                 "frame-src 'self' blob: data:; frame-ancestors 'self'; form-action 'self'; "
                 "base-uri 'self'; object-src 'none'"))
(define CONSOLE-CSP (console-csp #t))
(define BASE-SECURITY-HEADERS
  (list (make-header #"X-Content-Type-Options" #"nosniff")
        (make-header #"Referrer-Policy" #"strict-origin-when-cross-origin")
        (make-header #"X-Frame-Options" #"SAMEORIGIN")
        (make-header #"Content-Security-Policy" (string->bytes/utf-8 CONSOLE-CSP))))
(define HSTS-HEADER (make-header #"Strict-Transport-Security" #"max-age=31536000; includeSubDomains"))
(define (with-security-headers resp)
  (define have (map header-field (response-headers resp)))
  (define (missing h) (not (member (header-field h) have)))
  (define add (append (filter missing BASE-SECURITY-HEADERS)
                      (if (and (tls-on?) (missing HSTS-HEADER)) (list HSTS-HEADER) '())))
  (if (null? add) resp (struct-copy response resp [headers (append (response-headers resp) add)])))

(define (handle req)
  ;; one id for this request, honouring an inbound X-Request-Id, bound before
  ;; anything can raise so a 500 and the audit entries agree about which request
  ;; they belong to
  ;; `request-id-of` is kit's, so the precedence (inbound header, else fresh) is
  ;; stated once rather than here and in `with-auth`
  (define rid (request-id-of req))
  (parameterize ([current-localizer (localizer-for (request-locale req))]
                 [current-request-id rid])
    (with-security-headers
     (with-handlers ([exn:fail:forbidden?
                      (lambda (e) (err (msg-forbidden (exn:fail:forbidden-permission e)) 403))]
                     ;; a refused workflow spec is the caller's mistake — and the
                     ;; detail is the whole point of rejecting rather than ignoring
                     [exn:fail:spec? (lambda (e) (err (exn-message e) 400))]
                     ;; …and so is any `raise-user-error`, which several handlers
                     ;; already caught one at a time. Catching it HERE is what
                     ;; makes the rule true everywhere rather than wherever
                     ;; somebody remembered to wrap: two deliberate refusals ("no
                     ;; model configured", "input 'x' is required") were reaching
                     ;; the caller only because the 500 below leaked
                     ;; `exn-message`, and both are a 400. It must precede the
                     ;; `exn:fail?` clause — exn:fail:user is a subtype, and the
                     ;; first matching clause wins (PULL-14's ordering lesson).
                     [exn:fail:user? (lambda (e) (err (exn-message e) 400))]
                     ;; #123: NOT the exception's message. See server-error-response.
                     [exn:fail? (lambda (e) (server-error-response e rid))])
       (route req)))))

(module+ main
  (init-db!)
  (warn-dev-pepper!)
  ;; hosted VM launch: self-seed the owner from env on first boot, emit the
  ;; activation token to stdout (the provisioning sink) for the control plane.
  (when (and (saas-mode?) (tmach-env "SEED_OWNER_EMAIL")
             (not (query-maybe-value db-conn "SELECT id FROM users LIMIT 1")))
    (define-values (tok uid tid _st)
      (provision! db-conn #:provision-id (or (tmach-env "SEED_PROVISION_ID") "seed")
                  #:owner-email (tmach-env "SEED_OWNER_EMAIL")
                  #:owner-name (tmach-env "SEED_OWNER_NAME")
                  #:org (tmach-env "SEED_ORG")
                  #:plan (or (tmach-env "SEED_PLAN") "trial") #:source "vm"))
    (printf "seed: provisioned ~a — activation token: ~a\n" (tmach-env "SEED_OWNER_EMAIL") tok)
    (flush-output))
  ;; issue #45: TELEMACHUS_PLUGINS is a LIST, searched after the built-in
  ;; directory — `:`-separated, like a path variable. It used to name the one
  ;; directory to load, so pointing it at a plugin of your own silently removed
  ;; doc-pipeline and every other shipped plugin. A literal `-` entry drops the
  ;; built-ins, for a deployment that means to ship only its own.
  (define plugins-dirs
    (let* ([entries (let ([e (tmach-env "PLUGINS")])
                      (if e (filter (lambda (x) (not (string=? x ""))) (string-split e ":")) '()))]
           [builtin? (not (member "-" entries))]
           [extra (map string->path (filter (lambda (x) (not (string=? x "-"))) entries))])
      (append (if builtin? (list (build-path impl-root "plugins")) '()) extra)))
  ;; A SYMLINKED plugin directory is opt-in (TELEMACHUS_PLUGINS_LINKS=1). Symlinking
  ;; a downstream plugin into `plugins/` is the normal way to develop one — and the
  ;; only way for a plugin that requires Telemachus modules by relative path
  ;; (`../../domain/...`) to resolve them. But `plugins/` is inside the checkout, so
  ;; without this every test harness boots with that plugin too: `server-smoke.sh`
  ;; asserts no plugin failed, the harnesses reset `PLTCOLLECTS` (so a downstream
  ;; plugin's own collections are gone and it DOES fail), and a customer's routes
  ;; and tools would otherwise show up in the suite's assertions. Opt-in means a
  ;; local link can never change a test, a generated document or a CI result.
  (define include-links? (and (tmach-env "PLUGINS_LINKS") #t))
  (define plugins (load-plugins! plugins-dirs
                                 #:skip-links? (not include-links?)
                                 #:log (lambda (s) (printf "  plugin: ~a\n" s))))
  (install-plugin-routes!)
  ;; #121: a plugin's own tables, applied through the platform's own runner —
  ;; ordered, recorded in `schema_migrations` under `x.<plugin-id>.<name>`, each
  ;; in a transaction, run once. AFTER every plugin has loaded and BEFORE the
  ;; startup checks, so a plugin's first request never finds a missing table and
  ;; never has to race to create one. The loader has already refused any
  ;; migration that names a table outside the plugin's own `x_<id>_` prefix.
  ;;
  ;; Two replicas starting together can still collide here — one wins the
  ;; `schema_migrations` insert and the other's transaction rolls back, taking its
  ;; DDL with it. That is exactly the property the PLATFORM's own migrations have
  ;; had all along, so it is stated rather than papered over: a plugin's are not a
  ;; new race class, and the remedy is the same one (start one replica first).
  (let ([pm (plugin-migrations)])
    (unless (null? pm)
      (migrate! db-conn pm #:log (lambda (id) (printf "  plugin migration: ~a\n" id)))))
  ;; Refuse to serve with a RELATIVE blob root. `serve/servlet` repoints
  ;; `current-directory` at the web server's own web root while it handles a
  ;; request, so a relative root aims writes at whatever that is — for a Nix
  ;; install, the read-only store. That surfaced as a 500 on the first document
  ;; save, with a mkdir EACCES deep inside /nix/store, long after a boot that
  ;; looked completely healthy. Fail here instead, where the message is about the
  ;; configuration and not about a mkdir. Plugins load first because rs3 replaces
  ;; the built-in store and this must check the one that will actually be used.
  ;; Refuse to serve with a blob store that was ASKED FOR and is not there.
  ;; `active-blob-store-name` falls back want -> rs3 -> builtin, so a typo in
  ;; TELEMACHUS_BLOB_STORE quietly wrote every document to local disk while the
  ;; instance reported healthy — the same shape as the relative root below, and
  ;; the same answer: fail where the message is about the configuration.
  (let ([want (tmach-env "BLOB_STORE")])
    (when (and want (not (string=? want "")) (not (member want (blob-store-names))))
      (error 'telemachus
             (string-append "TMACH_BLOB_STORE names a store that is not registered: ~a\n"
                            "  registered: ~a\n"
                            "  Documents would silently go to the local store instead.")
             want (string-join (blob-store-names) ", "))))
  (let ([r (blob-root)])
    (unless (absolute-path? r)
      (error 'telemachus
             (string-append "blob store root is relative (~a).\n"
                            "  It would be resolved against the web server's working directory at write\n"
                            "  time, not against the install. Set TMACH_DATA_DIR (or\n"
                            "  TMACH_RS3_ROOT) to an absolute path.")
             r)))
  ;; issue #89: everything else an unattended deployment gets wrong silently.
  ;; AFTER plugins, because the store that will be used is the one a plugin
  ;; registered — the same reason the two refusals above wait for them.
  ;;
  ;; #119: `#:blob-probe` is the probe the documentation has described since the
  ;; s3blobs slice and which did not exist. `#:blob-root` only ever wrote a file
  ;; under the LOCAL root, whatever TELEMACHUS_BLOB_STORE said, so a bucket store
  ;; with a wrong endpoint started healthy and failed on the first upload. Both
  ;; run: the path check gives the better message for a missing data directory,
  ;; and the probe is the one that actually exercises the store.
  (unless (report-startup-problems!
           (startup-problems #:bind-ip (bind-ip)
                             #:tls? (tls-on?)
                             #:secrets? (secrets-enabled?)
                             #:blob-root (blob-root)
                             #:blob-probe blob-store-probe
                             #:blob-store-name (active-blob-store-name)
                             #:conn db-conn
                             #:migrations all-migrations))
    (exit 1))
  (when (pair? plugins)
    (printf "loaded ~a plugin(s) from ~a\n" (length plugins)
            (string-join (map path->string plugins-dirs) ", ")))
  ;; issue #48: a plugin that did not load is not a line that scrolls past. The
  ;; server still starts — one bad plugin must not take the instance down — but
  ;; an operator running with TELEMACHUS_PLUGINS_STRICT=1 has said they would
  ;; rather not start than start without their plugins.
  (let ([bad (plugin-failures)])
    (when (pair? bad)
      (printf "WARNING: ~a plugin(s) FAILED to load — their tools, workflows, routes and job kinds are MISSING:\n"
              (length bad))
      (for ([f (in-list bad)]) (printf "  ~a: ~a\n" (hash-ref f 'plugin) (hash-ref f 'error)))
      (when (tmach-env "PLUGINS_STRICT")
        (eprintf "TMACH_PLUGINS_STRICT is set — refusing to start.\n")
        (exit 1))))
  (define mcp-config (let ([e (tmach-env "MCP")]) (if e (string->path e) (build-path impl-root "mcp.json"))))
  (define mcps (connect-mcp-servers! mcp-config #:log (lambda (s) (printf "  mcp: ~a\n" s))))
  (when (pair? mcps) (printf "connected ~a MCP server(s)\n" (length mcps)))
  (define oop-config (let ([e (tmach-env "OOP")]) (if e (string->path e) (build-path impl-root "oop.json"))))
  (define oops (connect-oop-plugins! oop-config #:log (lambda (s) (printf "  oop: ~a\n" s))))
  (when (pair? oops) (printf "connected ~a sandboxed plugin(s)\n" (length oops)))
  (define exec-config (let ([e (tmach-env "EXECUTORS")]) (if e (string->path e) (build-path impl-root "executors.json"))))
  (define fx (connect-executors! exec-config #:log (lambda (s) (printf "  executor: ~a\n" s))))
  (when (pair? fx) (printf "registered ~a federated executor(s)\n" (length fx)))
  ;; The executors table's PUSH rows belong in the same registry. They were only
  ;; registered at create time, so a restart silently turned a working backend
  ;; into a name that resolved nowhere. executors.json is loaded first and keeps
  ;; its names; a clash is reported, never silently overridden.
  (define-values (dbx dbx-skipped)
    (load-push-executors! db-conn #:log (lambda (s) (printf "  executor: ~a\n" s))))
  (when (pair? dbx) (printf "registered ~a push executor(s) from the database\n" (length dbx)))
  (when (> dbx-skipped 0)
    (printf "WARNING: ~a push executor(s) in the database were SKIPPED (see above)\n" dbx-skipped))
  ;; slice 66: the first REMOTE kind — the wire run-chat speaks, run by a pull
  ;; worker; a result must carry a reply and a numeric token count
  ;; A worker answers with `reply` (a string) or with `content` — the same parts
  ;; shape a provider may send (issue #18) — so a remote executor can return what
  ;; a local call can. Parts are normalized to text on the way out of the wire.
  (register-job-kind! "infer.chat" #f #:remote? #t
    #:validate (lambda (r)
                 (cond [(not (hash? r)) "result must be an object"]
                       [(and (not (hash-has-key? r 'reply)) (not (hash-has-key? r 'content)))
                        "result needs a reply (a string) or a content (a list of parts)"]
                       [(and (hash-has-key? r 'reply) (not (string? (hash-ref r 'reply))))
                        "result.reply must be a string"]
                       [(and (not (hash-has-key? r 'reply))
                             (let-values ([(_t p) (content->text (hash-ref r 'content))]) p))
                        => (lambda (p) (string-append "result.content: " p))]
                       [(not (number? (hash-ref r 'tokens_used #f))) "result.tokens_used must be a number"]
                       [else #f])))
  ;; JUDGE-8 (issue #57): the typed-judgment kind. The request and the verdict
  ;; both cross as composed/received BYTES; the full request-vs-verdict check
  ;; is the seam's, at the read — see domain/judge/judge.rkt.
  (register-judge-kind!)
  ;; The pool's per-tick maintenance. `set-reaper!` is ONE seam and stays one:
  ;; the lease reaper every tick (an expired lease must be noticed promptly), and
  ;; the abandoned-upload reaper on a long interval beside it (issue #54), since
  ;; a seven-day horizon does not need a scan five times a second. Keeping it
  ;; here rather than inside the S3 listener matters: the listener is OFF by
  ;; default, and an instance that staged parts and then turned it off would
  ;; otherwise hold those bytes for ever.
  (define last-upload-sweep (box 0))
  (define UPLOAD-SWEEP-EVERY 600)
  ;; The retention sweep (#86 r3) rides the SAME seam, on its own long interval.
  ;; An hour, not ten minutes: these rules are expressed in DAYS, so a sweep that
  ;; ran more often would only re-scan the same teams to decide the same nothing.
  ;; An instance with no policy configured does not scan at all — `retention-sweep!`
  ;; finds its teams from the policy documents that exist.
  (define last-retention-sweep (box 0))
  (define RETENTION-SWEEP-EVERY 3600)
  ;; The audit chain's seal (#84 r3) rides the same seam again, on the SHORTEST of
  ;; the three intervals. The gap between a seal and the next one is the window in
  ;; which an entry is written and not yet protected, so this one wants to be
  ;; frequent — and it is cheap: one indexed query that usually finds nothing, and
  ;; an UPDATE per entry it does find. The alternative, linking at insert time,
  ;; costs a SELECT on the path of every audited read AND forks the chain under
  ;; two concurrent writers.
  (define last-audit-seal (box 0))
  (define AUDIT-SEAL-EVERY 60)
  (define last-idem-reap (box 0))
  (define IDEM-REAP-EVERY 600)
  ;; The staged-blob sweep (#122) is the FIFTH thing on this seam. Ten minutes,
  ;; like the upload reaper it is a sibling of: the age floor is an hour by
  ;; default, so a sweep that ran more often would re-ask the same question about
  ;; the same rows. It rides here rather than in the S3 listener for the same
  ;; reason the upload reaper does — the listener is off by default, and these
  ;; bytes come from the ordinary front door, not from it.
  (define last-blob-sweep (box 0))
  (define BLOB-SWEEP-EVERY 600)
  ;; The schedule tick (#135) is the SIXTH thing on this seam, and the shortest
  ;; interval after the audit seal. A schedule's floor is 60 seconds, so the tick
  ;; has to be finer than that or every minute-ly schedule is systematically
  ;; late; 30 seconds bounds the drift at half a cadence. It is cheap — one
  ;; indexed query that usually finds nothing. It rides here rather than in a
  ;; thread of its own for the reason every other sweep does: `set-reaper!` is
  ;; ONE seam, and a second timer would be a second thing to drain on shutdown.
  (define last-schedule-tick (box 0))
  (define SCHEDULE-TICK-EVERY 30)
  ;; Webhook deliveries (#85) are the SEVENTH thing on this seam, and the
  ;; shortest interval of the lot after the audit seal: the first retry is a
  ;; minute away, so a sweep slower than that would make the backoff a lie. A
  ;; FIRST attempt does not wait for it — `enqueue-event!` makes the row due
  ;; immediately and the next tick is at most this far off, which is what #85's
  ;; "within 2 seconds" acceptance needs.
  (define last-webhook-sweep (box 0))
  (define WEBHOOK-SWEEP-EVERY 1)
  ;; The anchor receipt (#66) is the EIGHTH thing on this seam, and the longest
  ;; interval of the lot. It is OFF unless `TELEMACHUS_ANCHOR_KEY` is configured
  ;; (ANCHOR-7): a real default would start emitting a receipt series on every
  ;; instance that nobody retains, which reads as a working feature and is worse
  ;; than none. A day is the default cadence because the anchor's RESOLUTION IS
  ;; ITS CADENCE — a rewrite inside the window since the last receipt is not
  ;; detectable — so the knob is the operator's to shorten. `never` emits only
  ;; when asked over HTTP or by the CLI; an unparseable or non-positive value
  ;; falls back to the default, never to 0, which would emit on every tick and
  ;; bury the series it is meant to protect.
  (define ANCHOR-EVERY
    (let ([raw (string-downcase (string-trim (or (tmach-env "ANCHOR_EVERY") "")))])
      (cond
        [(string=? raw "") 86400]
        [(string=? raw "never") #f]
        [else (let ([n (string->number raw)]) (if (and n (exact-integer? n) (> n 0)) n 86400))])))
  ;; Seeded to NOW rather than 0, so a restart does not emit a receipt on its
  ;; first tick: a box that restarts hourly would otherwise produce an hourly
  ;; series and the cadence would be a lie.
  (define last-anchor (box (current-seconds)))
  ;; #85: ONE sink for every emitter — a run settling, a job finishing, an object
  ;; arriving or going, a review decided. Installed here rather than inside
  ;; webhooks.rkt so the domain module stays something a test can drive directly.
  ;; NAMED, because there may be several (#133): a plugin adds its own in
  ;; `init!` and the two are wrapped separately, so a broken transport on one
  ;; cannot cost the other its delivery.
  (add-event-sink! "webhooks" (lambda (conn event team data) (void (enqueue-event! conn event team data))))
  (set-reaper!
   (lambda (conn)
     (define n (reap-leases! conn))
     (when (> (- (current-seconds) (unbox last-upload-sweep)) UPLOAD-SWEEP-EVERY)
       (set-box! last-upload-sweep (current-seconds))
       (with-handlers ([exn:fail? (lambda (e)
                                    (eprintf "upload reaper: ~a\n" (exn-message e)))])
         (define dropped (reap-uploads! conn))
         (when (> dropped 0)
           (printf "reaped ~a abandoned multipart upload(s)\n" dropped))))
     (when (> (- (current-seconds) (unbox last-retention-sweep)) RETENTION-SWEEP-EVERY)
       (set-box! last-retention-sweep (current-seconds))
       ;; Its own handler, like the upload sweep's: one team's unreachable object
       ;; must not take the lease reaper down with it, and the lease reaper is the
       ;; one thing on this tick that must never be skipped.
       (with-handlers ([exn:fail? (lambda (e)
                                    (eprintf "retention sweep: ~a\n" (exn-message e)))])
         (define-values (deleted purged) (retention-sweep! conn))
         (when (or (> deleted 0) (> purged 0))
           (printf "retention: deleted ~a object tree(s), purged ~a job payload(s)\n"
                   deleted purged))))
     ;; Idempotency keys past their 24h window, on the upload sweep's cadence —
;;        they are dead weight that can never be replayed, and the stored response
;;        may name a document (#90 r4).
     (when (> (- (current-seconds) (unbox last-idem-reap)) IDEM-REAP-EVERY)
       (set-box! last-idem-reap (current-seconds))
       (with-handlers ([exn:fail? (lambda (e)
                                    (eprintf "idempotency reaper: ~a\n" (exn-message e)))])
         (define gone (idem-reap! conn))
         (when (> gone 0) (printf "reaped ~a expired idempotency key(s)\n" gone))))
     (when (> (- (current-seconds) (unbox last-blob-sweep)) BLOB-SWEEP-EVERY)
       (set-box! last-blob-sweep (current-seconds))
       (with-handlers ([exn:fail? (lambda (e)
                                    (eprintf "blob sweep: ~a\n" (exn-message e)))])
         (define-values (collected _kept) (reap-staged-blobs! conn))
         (when (> collected 0)
           (printf "collected ~a orphaned blob(s)\n" collected))))
     (when (> (- (current-seconds) (unbox last-schedule-tick)) SCHEDULE-TICK-EVERY)
       (set-box! last-schedule-tick (current-seconds))
       (with-handlers ([exn:fail? (lambda (e)
                                    (eprintf "schedule tick: ~a\n" (exn-message e)))])
         (define-values (fired skipped) (fire-due-schedules! conn))
         (when (or (> fired 0) (> skipped 0))
           (printf "schedules: fired ~a, skipped ~a\n" fired skipped))))
     (when (> (- (current-seconds) (unbox last-webhook-sweep)) WEBHOOK-SWEEP-EVERY)
       (set-box! last-webhook-sweep (current-seconds))
       (with-handlers ([exn:fail? (lambda (e)
                                    (eprintf "webhook sweep: ~a\n" (exn-message e)))])
         (define-values (sent _retried dead) (deliver-due! conn))
         (when (> dead 0) (printf "webhooks: ~a delivered, ~a dead-lettered\n" sent dead))))
     (when (> (- (current-seconds) (unbox last-audit-seal)) AUDIT-SEAL-EVERY)
       (set-box! last-audit-seal (current-seconds))
       ;; its own handler too, for the reason the other two have one
       (with-handlers ([exn:fail? (lambda (e)
                                    (eprintf "audit chain: ~a\n" (exn-message e)))])
         (void (audit-chain-seal! conn))))
     ;; #66: a signed measurement of both chains, on the longest interval here.
     ;; `anchor-signing-enabled?` is asked every tick rather than once at boot so
     ;; a key added to the environment takes effect on a restart only — which it
     ;; does — without this branch having to know that. It emits as the SYSTEM:
     ;; no operator pressed anything, and `anchor-emit!` records that rather than
     ;; attributing a sweep to whoever happened to start the process.
     (when (and ANCHOR-EVERY
                (anchor-signing-enabled?)
                (> (- (current-seconds) (unbox last-anchor)) ANCHOR-EVERY))
       (set-box! last-anchor (current-seconds))
       (with-handlers ([exn:fail? (lambda (e)
                                    (eprintf "anchor receipt: ~a\n" (exn-message e)))])
         (define r (anchor-emit! conn))
         (printf "anchor: receipt ~a emitted (~a chain(s)), hash ~a\n"
                 (hash-ref r 'seq) (hash-ref r 'chains)
                 (substring (hash-ref r 'hash) 0 16))))
     n))
  ;; RED-17: the model-request log (issue #91 requirement 3). executor.rkt holds
  ;; the box and writes no rows; this is the writer that knows the connection and
  ;; the principal. The team and user come from `current-job` inside a scheduler
  ;; job and from `current-request-principal` on the request path — the same two
  ;; sources `pull-router` below reads, for the same reason.
  ;;
  ;; A call with NO team context is still logged, with a NULL team: it happened,
  ;; and dropping it would make the log quietly incomplete for exactly the
  ;; platform-internal calls nobody can attribute.
  (set-box! model-request-logger
    (lambda (#:executor executor #:transport transport #:model model #:endpoint endpoint
             #:messages msgs #:tokens tokens #:status status #:error-kind error-kind
             #:http-status http-status #:operation operation #:ms ms)
      (define job (current-job))
      (define p (current-request-principal))
      (model-request-record! db-conn
        #:team (cond [job (hash-ref job 'team #f)] [p (principal-team-id p)] [else #f])
        #:user (cond [job (hash-ref job 'user #f)] [p (principal-user-id p)] [else #f])
        #:org  (and p (principal-org-id p))
        #:executor executor #:transport transport #:model model #:endpoint endpoint
        #:messages msgs #:tokens tokens #:status status #:error-kind error-kind
        #:http-status http-status #:operation operation #:ms ms)
      (void)))
  ;; RED-26: the per-org executor policy (issue #91 requirement 4). The gate is
  ;; `egress-refusal` in executor.rkt, at the three places a request leaves the
  ;; process; the DECISION is `make-egress-policy`, in the domain beside the
  ;; policy it reads, so the acceptance test installs the same one this does.
  ;; What this supplies is the request context the domain cannot see — the
  ;; principal lives in a `server/kit.rkt` parameter.
  (set-box! egress-policy
    (make-egress-policy
     db-conn
     #:context (lambda ()
                 (define job (current-job))
                 (define p (current-request-principal))
                 (hasheq 'org (and p (principal-org-id p))
                         'team (cond [job (hash-ref job 'team #f)]
                                     [p (principal-team-id p)]
                                     [else #f])
                         'user (cond [job (hash-ref job 'user #f)]
                                     [p (principal-user-id p)]
                                     [else #f])))))
  ;; run-chat #:executor <pull executor>: enqueue an infer.chat sub-job of the
  ;; current job (or a top-level one on the request path) and wait for a worker
  (set-box! pull-router
    (lambda (name msgs temp rf)
      ;; #173: `@fleet` is not a row. It means "any host that can run this", so
      ;; there is nothing to look up and nothing to check the mode of — the
      ;; dispatch writes no executor requirement and the claim decides.
      (define ex (and (not (fleet-request? name)) (executor-by-name db-conn name)))
      (and (or (fleet-request? name) (and ex (equal? (hash-ref ex 'mode) "pull")))
           (let* ([job (current-job)]
                  [p (current-request-principal)]
                  [team (cond [job (hash-ref job 'team)] [p (principal-team-id p)] [else #f])]
                  [user (cond [job (hash-ref job 'user)] [p (principal-user-id p)] [else #f])])
             (unless team (error 'run-chat "no team context for executor ~a" name))
             (define-values (reply tokens)
               (pull-dispatch! db-conn #:team team #:user user #:executor name #:messages msgs
                               #:temperature temp #:parent (and job (hash-ref job 'id))
                               #:response-format rf))
             (cons reply tokens)))))
  ;; async job kinds + the worker pool
  (register-job-kind! "translate"
    (lambda (conn p payload)
      (define-values (job tokens)
        (translate! conn p #:text (format "~a" (hash-ref payload 'text ""))
                    #:target-lang (format "~a" (hash-ref payload 'target_lang "en"))))
      (hash-set job 'tokens_used tokens)))
  (register-job-kind! "chat"
    (lambda (conn p payload)
      (define-values (reply tokens) (run-chat (format "~a" (hash-ref payload 'prompt ""))))
      (hasheq 'reply reply 'tokens_used tokens)))
  (register-job-kind! "agent"       ; full tool-loop agent flow, run to completion
    (lambda (conn p payload)
      (unless (agent-configured?) (error "agent requires a configured model"))
      (define prompt (format "~a" (hash-ref payload 'prompt "")))
      (define evs (box '()))
      (define-values (_result tokens)
        (run-agent-flow conn p prompt (lambda (ev) (set-box! evs (cons ev (unbox evs))))))
      (define events (reverse (unbox evs)))
      (define done (for/or ([e (in-list events)]) (and (equal? (hash-ref e 'type #f) "done") e)))
      (define tools (for/list ([e (in-list events)] #:when (equal? (hash-ref e 'type #f) "tool")) (hash-ref e 'name "")))
      (define reply (if done (hash-ref done 'reply "") ""))
      (hasheq 'reply reply 'rounds (if done (hash-ref done 'rounds 0) 0)
              'tools tools
              ;; real counts from the loop, with the old estimate as a floor
              'tokens_used (if (> tokens 0) tokens (estimate-tokens prompt reply)))))
;; One scheduler job per BATCH of missing strings, so a five-thousand-string draft
;; is a queue of small jobs rather than one that runs for an hour and cannot be
;; cancelled. Inside a batch the calls are sequential; the governor's concurrency
;; cap is what stops a bulk draft from flattening the local model.
;;
;; Output lands as `machine`, never `approved`. A human still reviews it — that is
;; the whole bargain: the tool drafts, people complete and approve.
  (register-job-kind! "l10n_draft"
    (lambda (conn p payload)
      (define loc (format "~a" (hash-ref payload 'locale "")))
      (define ids (let ([v (hash-ref payload 'message_ids '())]) (if (list? v) v '())))
      (define total-tokens (box 0))
      (define drafted (box 0))
      (for ([mid (in-list ids)])
        (define m (l10n-message-ref conn (format "~a" mid)))
        (when m
          (define src (hash-ref m 'source_text))
          ;; Placeholders are the thing a model will happily "improve". They are
          ;; ICU arguments — {user}, {team} — and a translation that renames one
          ;; renders the literal braces to an end user.
          ;; JSON in, JSON out. The first prompt ended its rules with a colon-
          ;; terminated heading ("Rules, all mandatory:") and a 7B model, given a
          ;; four-character string to translate, translated the HEADING and
          ;; appended it — "Chats, alle verplicht:" — dozens of times. Nothing in
          ;; this prompt ends in a colon, the payload is the last thing the model
          ;; sees, and the reply has a shape to parse rather than a line to trust.
          (define prompt
            (string-append
             "You are translating one user-interface string into the locale \"" loc "\".\n"
             "Reply with a JSON object containing a single field, translation, and nothing else.\n"
             "Keep every placeholder in curly braces exactly as written. Keep it as short as the\n"
             "original; this is UI text. Do not add quotes, notes, or alternatives.\n"
             (jsexpr->string (hasheq 'text src 'locale loc))))
          (define-values (reply tokens)
            (run-chat prompt #:executor (model-role-executor conn (principal-team-id p) "utility")))   ; KG-7 / LOC-5
          (set-box! total-tokens (+ (unbox total-tokens) tokens))
          (define raw (format "~a" reply))
          ;; The outermost {…} is the object even when the string itself has {user}
          ;; in it; fall back to the bare reply if the model ignored the shape.
          (define text
            (string-trim
             (or (let ([a (for/first ([i (in-naturals)] [c (in-string raw)] #:when (char=? c #\{)) i)]
                       [b (for/last  ([i (in-naturals)] [c (in-string raw)] #:when (char=? c #\})) i)])
                   (and a b (> b a)
                        (with-handlers ([exn:fail? (lambda (_) #f)])
                          (define j (string->jsexpr (substring raw a (add1 b))))
                          (and (hash? j) (let ([v (hash-ref j 'translation #f)]) (and (string? v) v))))))
                 raw)))
          (when (draft-acceptable? src text #:locale loc)
            (l10n-submit! conn (hash-ref m 'id) loc text "" #:status "machine")
            (set-box! drafted (add1 (unbox drafted))))))
      (hasheq 'locale loc 'requested (length ids) 'drafted (unbox drafted)
              'tokens_used (unbox total-tokens))))
  ;; #114 slice 4: the first adapter, and the kind a feed's own schedule fires.
  ;;
  ;; The adapter is installed BEFORE the job kind for a reason that is not
  ;; ordering fussiness: `FEED-KINDS` is derived from the registry, so a feed of
  ;; kind `github.issues` cannot be configured — or re-read — until this line has
  ;; run. It is a platform adapter, so it registers with no `current-plugin` and
  ;; owns an unprefixed name; a plugin's would be `x.<id>.<name>`.
  (install-github-adapter!)
  (register-job-kind! POLL-KIND
    (lambda (conn p payload)
      ;; The job carries the feed id and nothing else: the ROW is what says which
      ;; URL, which credential and whose authority, and copying any of that into
      ;; a payload would let an edited feed keep being polled as it used to be.
      ;; A feed deleted since the tick is not an error — the schedule goes with
      ;; the feed, so this is the race between the two, and failing the job would
      ;; put a red row in the team's history for housekeeping working correctly.
      (define fid (format "~a" (hash-ref payload 'feed_id "")))
      (cond
        [(not (feed-by-id conn fid)) (hasheq 'skipped "the feed was deleted")]
        [else (poll-feed! conn fid)])))
  (register-job-kind! "beta_judge"    ; vet a beta prospect with the LLM, store the verdict
    (lambda (conn p payload)
      (define pid (format "~a" (hash-ref payload 'prospect_id "")))
      (define pr (prospect-get conn p pid))
      (cond
        [(not pr) (hasheq 'skipped "prospect gone")]
        [else
         (define sig (let ([s (hash-ref pr 'signals 'null)]) (if (hash? s) (jsexpr->string s) "none")))
         ;; resolve the prospect's team experience: field defs (for the prompt) + judge prompt
         (define exp-fields (hash-ref (resolve-experience conn (principal-team-id p)) 'fields '()))
         (define lines
           (for/list ([f (in-list exp-fields)])
             (format "~a: ~a" (hash-ref f 'label (hash-ref f 'key "")) (prospect-field pr (hash-ref f 'key "")))))
         (define detail (string-append (string-join lines "\n") "\n\nAnti-abuse signals: " sig))
         (define-values (reply tokens) (run-chat detail #:system (experience-judge-system conn (principal-team-id p))))
         ;; JUDGE-6: the verdict is validated, and the refusal says WHY. A flat
         ;; "not parseable" read the same whether the model answered prose or
         ;; answered `"score": "high"` — and the second is an operator's judge
         ;; prompt to fix, not a model to replace. `parse-verdict` answers with
         ;; the verdict, a list of problems, or #f for no object at all.
         (define parsed (parse-verdict reply))
         (define verdict
           (cond
             [(hash? parsed) parsed]
             [(list? parsed)
              (hasheq 'valid #f 'score 0 'revenue_estimate "unknown"
                      'reasoning (string-append "judge output did not match the expected shape: "
                                                (string-join parsed "; ")))]
             [else (hasheq 'valid #f 'score 0 'revenue_estimate "unknown"
                           'reasoning "judge output was not a JSON object")]))
         (set-prospect-judge! conn pid verdict)
         (hasheq 'prospect_id pid 'verdict verdict 'tokens_used tokens)])))
  (define stop-scheduler (start-scheduler! db-conn #:workers 2
                          #:cap-for (lambda (team)
                                      (define-values (lim _w) (get-limit db-conn "team" team "ai.concurrency"))
                                      (or lim 2))         ; per-team fairness: cap = the team's ai.concurrency
                          ;; over-budget teams defer, not bypass — and the
                          ;; deferral names the limit that holds them (issue #55)
                          #:hold-reason quota-hold-reason
                          #:on-hold note-deferred!
                          #:record! (lambda (conn team result)   ; bill the run at both tiers
                                      (define toks (let ([t (and (hash? result) (hash-ref result 'tokens_used #f))])
                                                     (if (number? t) t 0)))
                                      (define org (team-org conn team))
                                      ;; JUDGE-10: a judgment bills its own dimension, one per
                                      ;; question answered — output_tokens is 0 on that wire, so
                                      ;; the token meter cannot see it
                                      (define judgments (judgments-in-result result))
                                      (quota-record! conn "team" team "ai.requests" 1)
                                      (quota-record! conn "team" team "ai.tokens.total" toks)
                                      (when judgments
                                        (quota-record! conn "team" team "ai.judgments.total" judgments))
                                      (when org
                                        (quota-record! conn "org" org "ai.requests" 1)
                                        (quota-record! conn "org" org "ai.tokens.total" toks)
                                        (when judgments
                                          (quota-record! conn "org" org "ai.judgments.total" judgments))))))
  (printf "scheduler: 2 worker(s), per-team cap = ai.concurrency, quota-metered\n")
  (define tls? (tls-on?))
  (define ip (bind-ip))
  (define port (listen-port))
  (when tls? (ensure-cert!))
  (printf "telemachus server on ~a://~a:~a  (db: ~a · kdf: ~a · tls: ~a · secrets: ~a · max upload: ~a MiB)\n"
          (if tls? "https" "http") ip port (redact-db-url db-url) (kdf-name) (if tls? "on" "off")
          ;; issue #19: say plainly whether a dump of this database is replayable
          (if (secrets-enabled?) (format "sealed (key ~a)" (secret-key-id)) "plaintext")
          (quotient (max-upload-bytes) (* 1024 1024)))
  ;; issue #64: the operator who most needs to know that no model is configured
  ;; is the one standing in front of a fresh instance wondering why every AI
  ;; answer looks like its own prompt shouted back. Said once, at boot, in the
  ;; shape the plugin failures already use.
  (unless (model-configured?)
    (printf "\nWARNING: no model is configured (TMACH_MODEL_URL is unset).\n")
    (printf "  /api/ai/chat answers with a SIMULATED upper-cased echo, flagged `simulated` in\n")
    (printf "  the response; the document tools, the knowledge graph and the agent refuse\n")
    (printf "  outright. Set TMACH_MODEL_URL to an OpenAI-compatible endpoint.\n\n"))
  ;; #128 job 2: the instance says which variables it is still reading under
  ;; their OLD names, once, in the shape the plugin failures already use. An
  ;; operator migrating a compose file needs the list; one who has already
  ;; migrated sees nothing. It is a NOTE rather than a WARNING because nothing is
  ;; wrong — the old names are supported, and shouting about a supported
  ;; configuration is how an operator learns to ignore the boot output.
  (let ([note (legacy-env-warning)])
    (when note (printf "\n~a\n\n" note)))
  ;; The S3 front door is a SEPARATE listener on a separate port: it runs on
  ;; web-kit/http1 because it must answer `Expect: 100-continue` and stream bodies
  ;; the servlet would buffer. Off unless TELEMACHUS_S3_PORT is set — an S3 endpoint
  ;; is surface area, and surface area should be asked for.
  (when (s3-port)
    (http1-listen (make-s3-handler db-conn)
                  #:port (s3-port) #:listen-ip ip
                  #:on-error (lambda (e) (printf "s3: ~a\n" (exn-message e)) (flush-output)))
    (printf "s3 endpoint on http://~a:~a  (path-style · region ~a · bucket = team slug)\n"
            ip (s3-port) (s3-region)))
  (flush-output)
  ;; ---- graceful shutdown (issue #89) ----------------------------------------
  ;;
  ;; Racket delivers BOTH SIGTERM and SIGINT as exn:break (measured, not assumed:
  ;; `docker stop`, `systemctl --user stop` and Ctrl-C all arrive here), so the
  ;; drain needs no FFI signal handler and no STOPSIGNAL override in the image.
  ;;
  ;; What the drain buys: without it, every job this process was running stays
  ;; `running` with a live lease until the reaper notices, and `reap-leases!`
  ;; requeues it with attempt+1 — so a rolling restart spent an attempt per
  ;; in-flight job and a job could reach `error` after three ordinary deploys.
  ;; Draining hands them back un-charged instead, and immediately, so the next
  ;; replica picks them up now rather than after the 120s lease.
  ;; Run at most once, however the process leaves: a plumber flush AND the break
  ;; handler below can both fire, and the second call would print a confusing
  ;; second report of zero.
  (define drained? (box #f))
  (define (drain! why)
    (unless (unbox drained?)
      (set-box! drained? #t)
      (printf "\n~a — draining (TMACH_DRAIN_SECONDS=~a)\n" why (drain-seconds))
      (flush-output)
      (define-values (finished requeued)
        (with-handlers ([exn:fail? (lambda (e)
                                     (eprintf "drain: ~a\n" (exn-message e))
                                     (values 0 0))])
          (drain-scheduler! db-conn #:stop stop-scheduler
                            #:log (lambda (m) (printf "  ~a\n" m) (flush-output)))))
      (printf "drained: ~a job(s) finished, ~a handed back to the queue\n" finished requeued)
      (flush-output)))

  ;; The drain hangs off a PLUMBER FLUSH, not off a break handler alone.
  ;;
  ;; Measured: `serve/servlet #:command-line? #t` installs its own break handler
  ;; and exits cleanly, so the signal never reaches a `with-handlers` wrapped
  ;; around `serve` — a container stopped with `docker stop` exited 0 having
  ;; drained nothing, which looks exactly like a successful shutdown. A plumber
  ;; flush runs on SIGTERM, on SIGINT and on a normal exit, which is the same
  ;; seam cli/telemachus-worker.rkt already uses to hand its job back on the way
  ;; out. The break handler is kept as well, for the case where the break does
  ;; arrive here first; `drained?` makes the pair idempotent.
  ;;
  ;; Safe on the refusal paths above: those `exit` before the scheduler starts,
  ;; so the in-flight register is empty and this is a no-op.
  (void (plumber-add-flush! (current-plumber) (lambda (_) (drain! "shutting down"))))
  (with-handlers ([exn:break? (lambda (_) (drain! "shutdown signal") (exit 0))])
    (if tls?
        (serve handle #:port port #:listen-ip ip #:max-body-length (max-upload-bytes)
               #:ssl-cert (tls-cert) #:ssl-key (tls-key))
        (serve handle #:port port #:listen-ip ip #:max-body-length (max-upload-bytes)))))
