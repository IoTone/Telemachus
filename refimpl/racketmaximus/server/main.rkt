#lang racket/base

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
;; Endpoints:
;;   GET  /health
;;   POST /api/bootstrap   {username}                 → operator + token (first run)
;;   GET  /api/whoami                                 → principal + permissions
;;   POST /api/members     {username, role}           → add member (members:manage)
;;   GET  /api/admin/status                           → operator only (instance:manage)

(require racket/path
         (only-in racket/list take)
         racket/string
         racket/file
         racket/system
         racket/port
         db-kit/portable
         web-server/http
         json
         web-kit
         web-kit/http1
         db-kit
         "../config.rkt"
         "../domain/db/migrations.rkt"
         "../domain/authz/authz.rkt"
         "../domain/authz/passwords.rkt"          ; kdf-name
         (only-in "../domain/authz/permissions.rkt" org-role-key?)
         "../domain/notes/notes.rkt"
         "../domain/documents/documents.rkt"      ; documents (paginated ownable resource)
         "../domain/apps/translate.rkt"           ; Translation app
         "../domain/apps/search.rkt"              ; search across notes + translations
         "../domain/features/features.rkt"        ; per-team feature activation
         "../domain/samples/samples.rkt"          ; seed sample content + jobs for testing
         "../domain/orgs/orgs.rkt"                ; multi-tenancy: orgs above teams (slice 45)
         "../domain/samples/tenants.rkt"          ; the two-company demo fixture
         "../domain/beta/beta.rkt"                ; beta onboarding: prospects + judge + provider registry
         "../domain/beta/experience.rkt"          ; admin-editable onboarding experience (DB + ENV defaults)
         "../domain/beta/assets.rkt"              ; locally-hosted brand assets (logo/hero/font)
         "../domain/branding/branding.rkt"        ; instance title / tagline / logo (Admin)
         "../domain/i18n/policy.rkt"              ; instance localization policy (default locale + off switch)
         "../domain/i18n/catalog.rkt"             ; the on-disk catalogs the Manager imports/exports
         "../domain/i18n/manager.rkt"             ; the Localization Manager (Admin > Localization)
         "../domain/beta/template.rkt"            ; Tier-C sandboxed custom HTML templates
         "../domain/beta/antispam.rkt"            ; self-hosted anti-abuse for the public signup
         (only-in net/url url-query)
         "../domain/saas/onboarding.rkt"          ; hosted provisioning: provision!/activate!/suspend!/resume!
         "../domain/quota/quota.rkt"
         "../domain/sched/governor.rkt"
         "../domain/sched/scheduler.rkt"          ; async job queue + worker pool
         "../domain/s3/server.rkt"                ; the S3 protocol front door (slice 52)
         "../domain/s3/sigv4.rkt"                 ; …and presigned links (slice 53)
         "../domain/s3/creds.rkt"                 ; …and its access keys
         "../domain/repo/repo.rkt"                ; the document repository (slices 49-50)
         "../domain/repo/index-tools.rkt"         ; registers the doc-indexing tools (slice 54)
         "../domain/repo/blobs.rkt"               ; …and its content-addressed blob seam
         "../domain/flow/spec.rkt"                ; workflow spec — the public contract (slice 46)
         "../domain/flow/run.rkt"                 ; …and its interpreter; registers the "flow.step" job kind
         "../domain/ai/executor.rkt"
         "../domain/exec/federation.rkt"          ; connect-executors!, list-executors, executor-exists?
         "../domain/agent/run.rkt"
         "../domain/agent/registry.rkt"           ; tool-settings-for, set-tool-enabled!
         "../domain/agent/plugins.rkt"            ; load-plugins!, loaded-plugins
         "../domain/mcp/connect.rkt"              ; connect-mcp-servers!, mcp-servers
         "../domain/oop/host.rkt"                 ; connect-oop-plugins!, loaded-oop-plugins
         "../domain/i18n/i18n.rkt"
         "../surface/messages.rkt")

;; require db-kit/migrate for migrate! (separate module in the db-kit collection)
(require (only-in db-kit/migrate migrate!))

;; ---- database (thread-safe virtual connection over a pool) ------------------
;; Backend-neutral: sqlite:/// or postgres:// — db-kit's connector dispatches.
(define db-url (database-url))
(define db-pool (connection-pool (db-connector db-url #:base-dir impl-root)))
(define db-conn (virtual-connection db-pool))

(define (init-db!)
  (when (string-prefix? db-url "sqlite:")            ; only sqlite needs its dir created
    (define p (sqlite-path db-url #:base-dir impl-root))
    (define dir (let-values ([(base name dir?) (split-path p)]) base))
    (when (path? dir) (make-directory* dir)))
  (migrate! db-conn all-migrations))

;; ---- TLS --------------------------------------------------------------------
(define (env* k) (let ([v (getenv k)]) (and v (not (string=? v "")) v)))
(define (saas-mode?) (equal? (env* "TELEMACHUS_MODE") "saas"))   ; hosted: bootstrap off, provisioning on
(define (home-mode) (or (env* "TELEMACHUS_HOME") "login"))       ; what the root route shows: login | beta
;; multi-tenancy (slice 45): several companies on one instance. OFF is the default
;; and off is byte-for-byte the previous product — the flag switches surface area
;; (the /api/orgs + /api/org management planes), not the authorization semantics.
(define (multitenant?) (and (member (or (env* "TELEMACHUS_MULTITENANT") "") '("1" "true" "yes" "on")) #t))
(define (bind-ip) (or (env* "TELEMACHUS_BIND") "127.0.0.1"))   ; set to a tailnet IP to share privately
;; Largest request body the transport will accept. web-server's own default is 1 MiB
;; and it enforces it by DROPPING the connection — no status, no log line — so a
;; handler's own size check never runs. Deliberate here rather than inherited.
(define (max-upload-bytes)
  (define raw (env* "TELEMACHUS_MAX_UPLOAD"))
  (define n (and raw (string->number raw)))
  (if (and n (exact-positive-integer? n)) n default-max-body-length))
(define default-port 8835)                                     ; "TEL" on a keypad; 8080 is too crowded to squat on
(define (listen-port)   ; TELEMACHUS_PORT wins, then PORT (the common convention), else the default
  (define raw (or (env* "TELEMACHUS_PORT") (env* "PORT")))
  (cond
    [(not raw) default-port]
    [(let ([n (string->number raw)]) (and (exact-integer? n) (<= 1 n 65535) n))]
    [else (error 'telemachus "invalid port ~s — expected an integer in 1–65535" raw)]))
(define (tls-on?) (and (member (or (env* "TELEMACHUS_TLS") "") '("1" "true" "yes" "on")) #t))
(define (tls-cert) (or (env* "TELEMACHUS_TLS_CERT") (path->string (build-path (data-dir) "cert.pem"))))
(define (tls-key)  (or (env* "TELEMACHUS_TLS_KEY")  (path->string (build-path (data-dir) "key.pem"))))
(define (ensure-cert!)
  (unless (and (file-exists? (tls-cert)) (file-exists? (tls-key)))
    (make-directory* (data-dir))
    (define ok (parameterize ([current-output-port (open-output-nowhere)]
                              [current-error-port (open-output-nowhere)])
                 (system* (find-executable-path "openssl")
                          "req" "-x509" "-newkey" "rsa:2048" "-nodes"
                          "-keyout" (tls-key) "-out" (tls-cert)
                          "-days" "365" "-subj" "/CN=localhost")))
    (unless ok (error 'tls "openssl certificate generation failed"))))

;; ---- request helpers --------------------------------------------------------
(define (req-header req name-bytes)
  (define h (headers-assq* name-bytes (request-headers/raw req)))   ; case-insensitive
  (and h (bytes->string/utf-8 (header-value h))))

;; locale: an explicit X-Telemachus-Locale header (the UI sets this — browsers
;; forbid setting Accept-Language from fetch) wins, else Accept-Language.
(define (accept-language req)
  (define h (or (req-header req #"x-telemachus-locale") (req-header req #"accept-language")))
  (and h (let ([tag (string-trim (car (string-split (car (string-split h ",")) ";")))])
           (and (not (string=? tag "")) tag))))

;; Honours TELEMACHUS_LOCALES, as the CLI does. The reason is the test suites:
;; export writes catalogs INTO this directory, and with it hardcoded to the
;; checkout's locales/ a smoke run could clobber a tracked catalog with whatever
;; its throwaway database held. It did once — idempotently, by luck. Suites point
;; this at a temp copy; a deployment leaves it unset.
(define (locales-dir)
  (define e (env* "TELEMACHUS_LOCALES"))
  (if e (anchor-path e) (build-path impl-root "locales")))

;; What this request is actually answered in. The instance policy decides: with
;; negotiation off the header is ignored outright, and an unknown locale lands on
;; the instance default rather than on a hardcoded "en" — which would be the wrong
;; language on an instance whose default is ja.
(define (request-locale req)
  (resolve-locale db-conn (locales-dir) (accept-language req)))

;; `url-query` returns an alist keyed by SYMBOL, so comparing a string key with
;; assq never matches and every caller silently gets its default — a filter that
;; is quietly ignored rather than refused. Normalize the key.
(define (query-param req name [default ""])
  (define k (if (symbol? name) name (string->symbol name)))
  (cond [(assq k (url-query (request-uri req)))
         => (lambda (kv) (if (and (cdr kv) (not (string=? (cdr kv) ""))) (cdr kv) default))]
        [else default]))

(define (read-json-body req)
  (define raw (request-post-data/raw req))
  (if (and raw (> (bytes-length raw) 0))
      (with-handlers ([exn:fail? (lambda (_) (hasheq))]) (bytes->jsexpr raw))
      (hasheq)))

;; Through `locales-dir`, not impl-root directly: the suites point that at a temp
;; copy so the runtime and the Manager see the same catalogs during a test run.
(define (localizer-for locale)
  (with-handlers ([exn:fail? (lambda (_) empty-localizer)])
    (load-localizer (locales-dir) #:locale locale)))

;; PUBLIC — and it has to be. The console's own strings live in the same catalogs
;; as the server's (namespace `ui.`), and the sign-in screen has to render them
;; for someone who has no token yet. Same rationale as /api/config and
;; /api/branding. Nothing in a UI string is a secret.
;;
;; The fallback chain is resolved HERE, once for the whole namespace, so the
;; console makes one fetch per language and never needs the English catalog as
;; a second request: a locale that has 40% of its strings gets the other 60% in
;; English from the same reply. A miss on every catalog is simply absent, and the
;; console shows the key — visibly, not silently.
(define (ep-i18n-catalog req)
  (define want (let ([q (query-param req "locale" "")])
                 (if (string=? q "") (accept-language req) q)))
  (define loc (resolve-locale db-conn (locales-dir) want))
  (define L (localizer-for loc))
  (define msgs
    (for*/fold ([acc (hasheq)])
               ([l (in-list (localizer-fallback L))]
                [(k v) (in-hash (hash-ref (localizer-catalogs L) l (hash)))]
                #:when (and (> (string-length k) 3) (string=? (substring k 0 3) "ui."))
                #:unless (hash-has-key? acc (string->symbol k)))
      (hash-set acc (string->symbol k) v)))
  (json-response (hasheq 'locale loc 'messages msgs)))

;; ---- identity ---------------------------------------------------------------
(define (current-principal req)
  (define auth (req-header req #"authorization"))
  (cond
    [(and auth (string-prefix? auth "Bearer ")) (resolve-token db-conn (substring auth 7))]
    [else
     (define u (req-header req #"x-telemachus-user"))
     (define team (req-header req #"x-telemachus-team"))
     (and u team (principal-for db-conn u team))]))

(define (perms-of p)
  (if (principal-is-operator p) '("*:*")
      (user-permissions db-conn (principal-user-id p) (principal-team-id p))))

;; ---- responses --------------------------------------------------------------
(define (err msg code) (json-response (hasheq 'error msg) #:code code))
(define (unauthorized) (err (msg-unauthorized) 401))

;; CORS for the public beta API: a Tier-C template renders in a SANDBOXED, opaque-
;; origin iframe, so its fetches to these already-public endpoints are cross-origin.
(define cors-headers
  (list (make-header #"Access-Control-Allow-Origin" #"*")
        (make-header #"Access-Control-Allow-Methods" #"GET, POST, OPTIONS")
        (make-header #"Access-Control-Allow-Headers" #"Content-Type")
        (make-header #"Access-Control-Max-Age" #"600")))
(define (cors-json jsx #:code [code 200]) (json-response jsx #:code code #:headers cors-headers))
(define (cors-err msg code) (cors-json (hasheq 'error msg) #:code code))
(define (cors-preflight) (response/output #:code 204 #:headers cors-headers (lambda (out) (void))))

;; the single-page UI (read once at startup)
(define UI-HTML
  (let ([p (build-path impl-root "static" "index.html")])
    (if (file-exists? p) (file->string p) "<!doctype html><h1>Telemachus</h1>")))

;; Escape a branding string for interpolation into HTML. Branding values are
;; admin-set, but the whole point of the read side being public is that anyone
;; can read them -- they must never be able to inject markup through them.
(define (html-escape s)
  (regexp-replace* #rx"[&<>\"]" s
                   (lambda (m)
                     (case (string-ref m 0)
                       [(#\&) "&amp;"] [(#\<) "&lt;"] [(#\>) "&gt;"] [(#\") "&quot;"]))))

;; The static shell ships with the software's default title baked into the HTML
;; source, and the SPA only corrects it after JavaScript runs. Crawlers, link
;; unfurlers and anything else that reads raw HTML never run the SPA, so on a
;; branded instance they read the internal codename instead of the instance's
;; own name (hit live on beta.rcn-t.com 2026-09-04: /api/branding correctly
;; reported the instance's title while every raw-HTML response still said
;; otherwise). Rewritten per request rather than once at startup: UI-HTML is
;; read once, but branding is instance state an operator can change while the
;; server is running. Missing-file fallback UI-HTML has no <title> element;
;; regexp-replace# simply leaves it alone.
(define (ui-html-branded)
  (define title (hash-ref (branding-get db-conn) 'title ""))
  (if (string=? title "")
      UI-HTML
      ;; Procedural replacement, not a string: regexp-replace* expands `&` and
      ;; `\<n>` in a STRING replacement, so a branded title like "A & B" would
      ;; corrupt the markup (caught by the smoke test's escape assertion).
      (regexp-replace* #px"<title>.*?</title>" UI-HTML
                       (lambda _ (string-append "<title>" (html-escape title) "</title>")))))
(define (html-response s)
  (response/output #:mime-type #"text/html; charset=utf-8"
                   (lambda (out) (write-string s out))))

;; ---- static file serving (SDK + Tier-B plugin bundles) ----------------------
(define STATIC-MIME
  (hash "html" #"text/html; charset=utf-8" "js" #"application/javascript" "css" #"text/css"
        "json" #"application/json" "svg" #"image/svg+xml" "png" #"image/png"
        "jpg" #"image/jpeg" "jpeg" #"image/jpeg" "gif" #"image/gif" "webp" #"image/webp"
        "ico" #"image/x-icon" "woff2" #"font/woff2" "woff" #"font/woff" "ttf" #"font/ttf" "otf" #"font/otf"))
(define (ext-of s) (let ([m (regexp-match #rx"\\.([A-Za-z0-9]+)$" s)]) (if m (string-downcase (cadr m)) "")))
(define (mime-of s) (hash-ref STATIC-MIME (ext-of s) #"application/octet-stream"))
(define (serve-file path)
  (if (and (file-exists? path))
      (response/output #:mime-type (mime-of (path->string path))
                       #:headers (list (make-header #"Cache-Control" #"public, max-age=300")
                                       (make-header #"X-Content-Type-Options" #"nosniff"))
                       (lambda (out) (write-bytes (file->bytes path) out)))
      (err "not found" 404)))
;; a path segment safe to interpolate into a filesystem path (no traversal, no slashes)
(define (safe-seg? s) (and (string? s) (regexp-match? #rx"^[A-Za-z0-9._-]+$" s) (not (string=? s "..")) #t))
;; /beta/bundle/<plugin>/<path...> → plugins/<plugin>/landing/<path> (index.html default)
(define (bundle-file-path segs)
  (and (>= (length segs) 3) (equal? (list-ref segs 0) "beta") (equal? (list-ref segs 1) "bundle")
       (let ([plugin (list-ref segs 2)]
             [rest (filter (lambda (s) (not (string=? s ""))) (list-tail segs 3))])   ; tolerate trailing slash
         (and (safe-seg? plugin) (andmap safe-seg? rest)
              (apply build-path (build-path impl-root "plugins" plugin "landing")
                     (if (null? rest) '("index.html") rest))))))

;; Server-Sent Events: proc receives an `emit` that pushes one JSON event.
(define (sse-response proc)
  (response/output
   #:mime-type #"text/event-stream; charset=utf-8"
   #:headers (list (make-header #"Cache-Control" #"no-cache")
                   (make-header #"X-Accel-Buffering" #"no"))
   (lambda (out)
     (define (emit ev) (write-string (string-append "data: " (jsexpr->string ev) "\n\n") out) (flush-output out))
     (with-handlers ([exn:fail? (lambda (e) (emit (hasheq 'error (exn-message e))))])
       (proc emit)))))

;; ---- endpoints --------------------------------------------------------------
(define (ep-health)
  (json-response (hasheq 'ok #t 'service "telemachus" 'version app-version
                         'tls (tls-on?) 'kdf (kdf-name) 'multitenant (multitenant?))))

(define (ep-bootstrap req)
  (define body (read-json-body req))
  (define username (hash-ref body 'username #f))
  (cond
    [(saas-mode?) (err "interactive bootstrap is disabled in hosted mode" 403)]
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
     (define-values (tok _t) (issue-token! db-conn #:user uid #:team tid #:name "bootstrap" #:scopes '("*:*")))
     (json-response (hasheq 'user_id uid 'team_id tid 'token tok 'multitenant mt
                            'org_id (team-org db-conn tid)
                            'message (msg-bootstrap-done username (if mt "Instance" "Default")))
                    #:code 201)]))

;; ---- hosted provisioning (control-plane facing; provision-token auth) --------
(define (require-provision-token req)
  (define want (env* "TELEMACHUS_PROVISION_TOKEN"))
  (define got (req-header req #"x-provision-token"))
  (and want got (string=? want got)))

(define (public-base req)
  (or (env* "TELEMACHUS_PUBLIC_URL")
      (let ([h (req-header req #"host")])
        (string-append (if (tls-on?) "https://" "http://") (or h (bind-ip))))))

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

;; ---- beta onboarding (public signup → LLM judge → owner review) -------------
(define (fmt b k) (format "~a" (hash-ref b k "")))

;; anti-abuse state (in-memory, per-process)
(define beta-secret (or (env* "TELEMACHUS_SECRET") "telemachus-dev-secret"))     ; set in prod
(define pow-bits    (or (string->number (or (env* "TELEMACHUS_POW_BITS") "")) 16))
(define beta-limiter (make-limiter))
(define beta-used    (new-used-set))
(define (client-key req)
  (define xff (req-header req #"x-forwarded-for"))
  (if xff (string-trim (car (string-split xff ","))) "global"))

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

;; ---- instance branding (Admin > Branding) --------------------------------------
;; READ IS PUBLIC, and has to be: the sign-in screen renders the title, tagline and
;; logo for someone who has no token yet. It is the text on the front door.
(define (ep-branding-get req)
  (define b (branding-get db-conn))
  (json-response
   (hash-set b 'logoUrl (let ([id (hash-ref b 'logo "")])
                          (if (string=? id "") "" (string-append "/api/beta/asset/" id))))))

(define (ep-branding-put req)
  (with-auth req (lambda (p)
    (require-perm db-conn p "instance:manage")
    (define b (read-json-body req))
    (json-response (branding-set! db-conn (if (hash? b) b (hasheq)))))))

;; The logo rides the existing asset table and is served by the existing PUBLIC
;; /api/beta/asset/<id> route — one asset mechanism, not two.
;; ---- instance localization (Admin > Localization) ------------------------------
;; Read rides on the PUBLIC /api/config; the write is `instance:manage`, exactly
;; like branding. An unknown locale is a 400 and not a silent substitution: an
;; operator who asks for a language this build cannot render must be told, or the
;; instance claims a locale it will never actually serve.
(define (ep-i18n-put req)
  (with-auth req (lambda (p)
    (require-perm db-conn p "instance:manage")
    (define b (read-json-body req))
    (with-handlers ([exn:fail? (lambda (e) (err (exn-message e) 400))])
      (define v (i18n-policy-set! db-conn (locales-dir)
                                  (hasheq 'default (hash-ref b 'default
                                                             (hash-ref (i18n-policy db-conn (locales-dir)) 'default))
                                          'enabled (hash-ref b 'enabled #t))))
      (audit! db-conn #:action "i18n.set" #:actor-type "user" #:actor-id (principal-user-id p)
              #:resource-type "instance" #:resource-id "i18n")
      (json-response v)))))

;; ---- Localization Manager ------------------------------------------------------
;; The flagship tool. Instance-scoped on purpose: the artifact being translated is
;; the instance's own catalog on disk, so two teams cannot both be right about
;; `ja.json`. Governed by the `localization:*` permissions, which already existed.
;;
;; Read is `localization:read`, writing a string is `:translate`, approving is
;; `:review`, and anything that touches the files on disk is `:manage`.

(define (ep-l10n-coverage req)
  (with-auth req (lambda (p)
    (require-perm db-conn p "localization:read")
    (define loc (query-param req "locale" "ja"))
    (json-response (hash-set (l10n-coverage db-conn loc)
                             'locales (l10n-locales db-conn))))))

(define (ep-l10n-messages req)
  (with-auth req (lambda (p)
    (require-perm db-conn p "localization:read")
    (define (opt k) (let ([v (query-param req k "")]) (and (not (string=? v "")) v)))
    (define limit (let ([n (string->number (query-param req "limit" "50"))])
                    (if (and n (exact-positive-integer? n)) (min n 200) 50)))
    (define offset (let ([n (string->number (query-param req "offset" "0"))])
                     (if (and n (exact-nonnegative-integer? n)) n 0)))
    (json-response
     (l10n-list db-conn (query-param req "locale" "ja")
                #:status (opt "status") #:namespace (opt "namespace") #:q (opt "q")
                #:limit limit #:offset offset)))))

(define (ep-l10n-submit req message-id)
  (with-auth req (lambda (p)
    (require-perm db-conn p "localization:translate")
    (with-handlers ([exn:fail:user? (lambda (e) (err (exn-message e) 400))])
      (define b (read-json-body req))
      (define loc (fmt b 'locale))
      (when (string=? loc "") (raise-user-error 'l10n "locale is required"))
      (define t (l10n-submit! db-conn message-id loc (fmt b 'text) (principal-user-id p)))
      (audit! db-conn #:action "l10n.submit" #:actor-type "user" #:actor-id (principal-user-id p)
              #:resource-type "l10n" #:resource-id message-id)
      (json-response t)))))

(define (ep-l10n-review req translation-id)
  (with-auth req (lambda (p)
    (require-perm db-conn p "localization:review")
    (with-handlers ([exn:fail:user? (lambda (e) (err (exn-message e) 400))])
      (define b (read-json-body req))
      (define d (string->symbol (fmt b 'decision)))
      (define t (l10n-review! db-conn translation-id d (principal-user-id p)))
      (audit! db-conn #:action (format "l10n.~a" d) #:actor-type "user" #:actor-id (principal-user-id p)
              #:resource-type "l10n" #:resource-id translation-id)
      (json-response t)))))

;; Pull locales/*.json into the working tables. Safe to re-run: the database wins
;; for anything already under review.
(define (ep-l10n-import req)
  (with-auth req (lambda (p)
    (require-perm db-conn p "localization:manage")
    (with-handlers ([exn:fail? (lambda (e) (err (exn-message e) 400))])
      (define dir (locales-dir))
      (define base-path (build-path dir "en.json"))
      (unless (catalog-exists? base-path) (raise-user-error 'l10n "no base catalog at locales/en.json"))
      (define base (read-catalog base-path))
      (define targets
        (for/list ([f (in-list (directory-list dir))]
                   #:when (and (path-has-extension? f #".json")
                               (not (equal? (path->string f) "en.json"))))
          (read-catalog (build-path dir f))))
      (define r (l10n-import! db-conn base targets))
      (audit! db-conn #:action "l10n.import" #:actor-type "user" #:actor-id (principal-user-id p)
              #:resource-type "instance" #:resource-id "l10n")
      (json-response r)))))

;; Write approved strings back to locales/<locale>.json — the shipping artifact.
;; This is the ONLY way the manager reaches the product, and it is approved-only.
(define (ep-l10n-export req)
  (with-auth req (lambda (p)
    (require-perm db-conn p "localization:manage")
    (with-handlers ([exn:fail? (lambda (e) (err (exn-message e) 400))])
      (define b (read-json-body req))
      (define loc (fmt b 'locale))
      (when (string=? loc "") (raise-user-error 'l10n "locale is required"))
      (when (string=? loc "en") (raise-user-error 'l10n "en is the source catalog; it is extracted, not exported"))
      (define cat (l10n-export db-conn loc))
      (define n (hash-count (catalog-messages cat)))
      ;; Refuse to write an EMPTY catalog. `available` is derived from the files in
      ;; locales/, precisely so the instance cannot advertise a language it cannot
      ;; render — and a catalog with nothing approved in it renders entirely as
      ;; English fallback. Writing one would put Dutch in the language switcher and
      ;; then show English behind it, which is worse than not offering it at all.
      ;; Translate something first; a PARTIAL catalog is fine, the fallback chain
      ;; covers the gaps.
      (when (zero? n)
        (raise-user-error 'l10n
          (string-append "nothing is approved in " loc " yet — exporting now would "
                         "advertise the language with an empty catalog")))
      (define path (build-path (locales-dir) (string-append loc ".json")))
      (write-catalog path cat)
      (audit! db-conn #:action "l10n.export" #:actor-type "user" #:actor-id (principal-user-id p)
              #:resource-type "instance" #:resource-id loc)
      (json-response (hasheq 'ok #t 'locale loc
                             'written n
                             'path (path->string path)
                             'note "restart to serve the new catalog")))))) 

(define (ep-l10n-discard req)
  (with-auth req (lambda (p)
    (require-perm db-conn p "localization:manage")
    (with-handlers ([exn:fail:user? (lambda (e) (err (exn-message e) 400))])
      (define b (read-json-body req))
      (define loc (fmt b 'locale))
      (when (string=? loc "") (raise-user-error 'l10n "locale is required"))
      (define ns (let ([v (fmt b 'namespace)]) (and (not (string=? v "")) v)))
      (define n (l10n-discard-machine! db-conn loc #:namespace ns))
      (audit! db-conn #:action "l10n.discard" #:actor-type "user" #:actor-id (principal-user-id p)
              #:resource-type "instance" #:resource-id loc)
      (json-response (hasheq 'ok #t 'locale loc 'discarded n))))))

(define l10n-draft-batch 20)

;; Queue AI drafts for the strings that have none. `manage` rather than
;; `translate`: this spends the team's AI budget, so it is an administrative act.
(define (ep-l10n-draft req)
  (with-auth req (lambda (p)
    (require-perm db-conn p "localization:manage")
    (with-handlers ([exn:fail:user? (lambda (e) (err (exn-message e) 400))])
      (define b (read-json-body req))
      (define loc (fmt b 'locale))
      (when (string=? loc "") (raise-user-error 'l10n "locale is required"))
      (when (string=? loc "en") (raise-user-error 'l10n "en is the source; there is nothing to draft"))
      (define ns (let ([v (fmt b 'namespace)]) (and (not (string=? v "")) v)))
      (define cap (let ([v (hash-ref b 'limit 200)]) (if (exact-positive-integer? v) (min v 500) 200)))
      (define missing
        (hash-ref (l10n-list db-conn loc #:status "missing" #:namespace ns #:limit cap) 'items))
      (define ids (map (lambda (h) (hash-ref h 'message_id)) missing))
      (define batches
        (let loop ([xs ids] [acc '()])
          (cond [(null? xs) (reverse acc)]
                [(<= (length xs) l10n-draft-batch) (reverse (cons xs acc))]
                [else (loop (list-tail xs l10n-draft-batch)
                            (cons (take xs l10n-draft-batch) acc))])))
      (define jobs
        (for/list ([batch (in-list batches)])
          (enqueue-job! db-conn #:team (principal-team-id p) #:user (principal-user-id p)
                        #:kind "l10n_draft"
                        #:payload (hasheq 'locale loc 'message_ids batch))))
      (audit! db-conn #:action "l10n.draft" #:actor-type "user" #:actor-id (principal-user-id p)
              #:resource-type "instance" #:resource-id loc)
      ;; Drafts are quota-admitted like every job, so an over-budget team's queue
      ;; simply stops — which looks like a hang. Hand the caller the budget so the
      ;; tab can say so up front. ~120 tokens per string on qwen2.5:7b, measured.
      (define q (quota-check db-conn "team" (principal-team-id p) "ai.tokens.total" 0))
      (json-response (hasheq 'ok #t 'locale loc 'queued (length ids)
                             'batches (length jobs) 'jobs jobs
                             'budget (hasheq 'dimension "ai.tokens.total"
                                             'used (hash-ref q 'used) 'limit (hash-ref q 'limit)
                                             'remaining (hash-ref q 'remaining)
                                             'estimate (* 120 (length ids)))))))))

(define (ep-branding-logo req)
  (with-auth req (lambda (p)
    (require-perm db-conn p "instance:manage")
    (with-handlers ([exn:fail:user? (lambda (e) (err (exn-message e) 400))])
      (define b (read-json-body req))
      (define id (asset-store! db-conn p #:mime (fmt b 'mime) #:filename (fmt b 'filename)
                               #:data-base64 (fmt b 'data)))
      (define cur (branding-get db-conn))
      (json-response (hasheq 'ok #t 'id id 'url (string-append "/api/beta/asset/" id)
                             'branding (branding-set! db-conn (hash-set cur 'logo id)))
                     #:code 201)))))

;; The locale a PUBLIC funnel request asked for. `?lang=` comes first and exists
;; on purpose: the funnel is a page a visitor is linked to, so the switcher has to
;; produce a shareable URL, and there is no signed-in console state to carry a
;; preference. Falls back to the usual header, then to the instance default.
(define (funnel-requested-locale req)
  (let ([q (query-param req 'lang "")])
    (if (string=? q "") (accept-language req) q)))

(define (funnel-default-locale)
  (hash-ref (i18n-policy db-conn (locales-dir)) 'default "en"))

;; If the operator has turned per-request negotiation OFF, the funnel does not get
;; a say either — same rule as every other surface.
;; the funnel locale for a request, against a KNOWN team's experience
(define (funnel-locale-for* req team)
  (if (hash-ref (i18n-policy db-conn (locales-dir)) 'enabled #t)
      (funnel-locale (resolve-experience db-conn team)
                     (funnel-requested-locale req)
                     #:default (funnel-default-locale))
      (funnel-default-locale)))

(define (funnel-locale-for req)
  (if (hash-ref (i18n-policy db-conn (locales-dir)) 'enabled #t)
      (funnel-requested-locale req)
      #f))

(define (ep-beta-config req)     ; public: the effective experience (published DB row, else ENV/provider base)
  (cors-json (resolve-experience-public db-conn (default-team db-conn)
                                        #:locale (funnel-locale-for req)
                                        #:default (funnel-default-locale))))

;; public: the Tier-C custom template, sanitized + wrapped with our submission
;; bootstrap. Served for the sandboxed iframe (see domain/beta/template.rkt).
(define (ep-beta-template req)
  (define team (default-team db-conn))
  (define exp (resolve-experience db-conn team))
  (define tpl (let ([t (hash-ref exp 'template #f)]) (if (and (string? t) (not (string=? t ""))) t DEFAULT-TEMPLATE)))
  ;; the localized slice, so a Tier-C template is translated by the overlay
  ;; without its author writing a line of i18n code
  (define public-cfg
    (resolve-experience-public db-conn team
                               #:locale (funnel-locale-for req)
                               #:default (funnel-default-locale)))
  (html-response (template-page public-cfg tpl)))

;; ---- admin: edit & publish the onboarding experience (settings:manage) -------
(define (ep-beta-experience-get req)
  (define p (current-principal req))
  (cond [(not p) (unauthorized)]
        [else (json-response (experience-draft db-conn p))]))    ; full draft incl. judge prompt

(define (ep-beta-experience-put req)
  (define p (current-principal req))
  (cond [(not p) (unauthorized)]
        [else (experience-save! db-conn p (read-json-body req))
              (json-response (hasheq 'ok #t 'status "draft"))]))

(define (ep-beta-experience-publish req)
  (define p (current-principal req))
  (cond [(not p) (unauthorized)]
        [(experience-publish! db-conn p) (json-response (hasheq 'ok #t 'status "published"))]
        [else (err "nothing to publish — save a draft first" 400)]))

;; ---- brand assets: upload (admin) + serve (public) --------------------------
(define (ep-beta-asset-upload req)
  (with-auth req (lambda (p)
    (with-handlers ([exn:fail:user? (lambda (e) (err (exn-message e) 400))])   ; bad type/size → 400; forbidden → global 403
      (define b (read-json-body req))
      (define id (asset-store! db-conn p #:mime (fmt b 'mime) #:filename (fmt b 'filename) #:data-base64 (fmt b 'data)))
      (json-response (hasheq 'ok #t 'id id 'ref (string-append "asset://" id)
                             'url (string-append "/api/beta/asset/" id)) #:code 201)))))

(define (ep-beta-assets req)
  (with-auth req (lambda (p) (json-response (hasheq 'assets (asset-list db-conn p))))))

(define (ep-beta-asset-delete req id)
  (with-auth req (lambda (p) (asset-delete! db-conn p id) (json-response (hasheq 'ok #t)))))

(define (ep-beta-asset req id)          ; PUBLIC — the landing is public; ids are unguessable UUIDs
  (define-values (mime bytes) (asset-get db-conn id))
  (cond
    [(not mime) (err "not found" 404)]
    [else (response/output
           #:mime-type (string->bytes/utf-8 mime)
           #:headers (list (make-header #"Cache-Control" #"public, max-age=3600")
                           (make-header #"X-Content-Type-Options" #"nosniff"))
           (lambda (out) (write-bytes bytes out)))]))

(define (ep-beta-challenge req)  ; public: issue a signed, single-use PoW challenge
  (define c (issue-challenge #:secret beta-secret #:now (current-seconds) #:difficulty pow-bits))
  (cors-json (hasheq 'challenge (hash-ref c 'challenge) 'difficulty (hash-ref c 'difficulty) 'honeypot "_hp")))

;; add CORS headers to any already-built response (so the sandboxed Tier-C iframe can read it)
(define (with-cors resp) (struct-copy response resp [headers (append cors-headers (response-headers resp))]))
(define (ep-beta-signup req) (with-cors (ep-beta-signup* req)))
(define (ep-beta-signup* req)     ; PUBLIC — layered anti-abuse BEFORE any DB write / LLM spend
  (define b (read-json-body req))
  (define now (current-seconds))
  (define key (client-key req))
  (define team (default-team db-conn))
  (cond
    [(not team) (err (msg-beta-not-ready) 503)]
    [(not (limiter-allow? beta-limiter key now #:max 5 #:window 60))
     (bump-blocked! "rate") (err (msg-beta-rate) 429)]
    [(not (string=? (fmt b '_hp) ""))                    ; honeypot: pretend success, store nothing
     (bump-blocked! "honeypot") (json-response (hasheq 'ok #t 'message (msg-beta-thanks)) #:code 201)]
    [else
     (define tok (fmt b 'challenge))
     (define nonce (let ([ps (string-split tok ".")]) (if (pair? ps) (car ps) "")))
     (define ch (verify-challenge tok #:secret beta-secret #:now now #:used beta-used))
     (cond
       [(not (eq? ch 'ok)) (bump-blocked! (format "challenge-~a" ch)) (err (msg-beta-challenge) 400)]
       [(not (verify-pow nonce (fmt b 'pow) pow-bits)) (bump-blocked! "pow") (err (msg-beta-verify) 400)]
       [(not (valid-email? (fmt b 'email))) (bump-blocked! "email") (err (msg-beta-email) 400)]
       [(disposable-email? (fmt b 'email)) (bump-blocked! "disposable") (err (msg-beta-work-email) 400)]
       ;; Everything else the form asks for is validated from the experience's OWN
       ;; field definitions — so turning a field off actually turns it off, and
       ;; `required` finally means something. Localized FIRST, so the refusal names
       ;; the field as the applicant saw it (「法人番号」, not `corporate_number`).
       [(field-problem
         (hash-ref (experience-localize (resolve-experience db-conn team)
                                        (funnel-locale-for* req team))
                   'fields '())
         (lambda (k) (fmt b (string->symbol k))))
        => (lambda (p)
             (bump-blocked! "field")
             (define label (cadr p))
             (define n (caddr p))
             (err (case (car p)
                    [(required)   (msg-beta-field-required label)]
                    [(digits)     (msg-beta-field-digits label)]
                    [(too-short)  (msg-beta-field-short label n)]
                    [else         (msg-beta-field-long label n)])
                  400))]
       [else
        (define email (fmt b 'email))
        (define domain (or (email-domain email) ""))
        (define since (- now 86400))                        ; 24h velocity window
        (define email-cap  (or (string->number (or (env* "TELEMACHUS_BETA_EMAIL_CAP") "")) 1))
        (define domain-cap (or (string->number (or (env* "TELEMACHUS_BETA_DOMAIN_CAP") "")) 10))
        (define dom-count (count-recent-domain db-conn team domain since))
        (cond
          [(>= (count-recent-email db-conn team email since) email-cap)
           (bump-blocked! "email-cap") (err (msg-beta-duplicate) 429)]
          [(>= dom-count domain-cap)
           (bump-blocked! "domain-cap") (err (msg-beta-domain-cap) 429)]
          [else
           ;; signals the LLM judge weighs (how the signup arrived)
           (define signals (hasheq 'domain_signups_24h dom-count 'free_email (free-email? email)))
           ;; every configured field that ISN'T a reserved/typed column is captured
           ;; generically into the attributes blob — custom fields need no migration
           (define attrs
             (for/fold ([h (hasheq)]) ([f (in-list (hash-ref (resolve-experience db-conn team) 'fields '()))])
               (define k (hash-ref f 'key ""))
               (define v (fmt b (string->symbol k)))
               (if (or (reserved-field? k) (string=? v "")) h (hash-set h (string->symbol k) v))))
           (define pid (prospect-create! db-conn #:team team #:name (fmt b 'name) #:email email
                                         #:company (fmt b 'company) #:job-title (fmt b 'job_title)
                                         #:revenue (fmt b 'revenue) #:use-case (fmt b 'use_case)
                                         #:company-address (fmt b 'company_address) #:phone (fmt b 'phone)
                                         #:attributes attrs
                                         #:created-epoch now #:signals signals))
           (define owner (team-owner-id db-conn team))      ; judge runs as owner (metered to the team)
           (when owner (enqueue-job! db-conn #:team team #:user owner #:kind "beta_judge" #:payload (hasheq 'prospect_id pid)))
           (json-response (hasheq 'ok #t 'id pid 'message "Thanks — your request is in review.") #:code 201)])])]))

(define (ep-beta-prospects req)
  (with-auth req (lambda (p)
    (define blocked (for/hasheq ([(k v) (in-hash (blocked-stats))]) (values (string->symbol k) v)))  ; jsexpr needs symbol keys
    (json-response (hasheq 'prospects (prospect-list db-conn p) 'blocked blocked)))))

(define (ep-beta-decide req id)
  (with-auth req (lambda (p)
    (define d (fmt (read-json-body req) 'decision))
    (cond
      [(not (member d '("qualified" "rejected"))) (err "decision must be 'qualified' or 'rejected'" 400)]
      [(prospect-decide! db-conn p id d)
       (audit! db-conn #:action (string-append "prospect." d) #:actor-type "user" #:actor-id (principal-user-id p)
               #:team-id (principal-team-id p) #:resource-type "prospect" #:resource-id id)
       (json-response (hasheq 'ok #t 'id id 'status d))]
      [else (err "not found" 404)]))))

(define (ep-whoami req)
  (define p (current-principal req))
  (if (not p) (unauthorized)
      (json-response (hasheq 'user_id (principal-user-id p)
                             'team_id (principal-team-id p)
                             'is_operator (principal-is-operator p)
                             'org_id (or (principal-org-id p) 'null)
                             'org_slug (let ([o (principal-org-id p)])
                                         (or (and o (query-maybe-value db-conn
                                               "SELECT slug FROM orgs WHERE id = ?" o)) 'null))
                             'org_role (or (principal-org-role p) 'null)
                             'multitenant (multitenant?)
                             'locale (user-locale db-conn (principal-user-id p))
                             'permissions (perms-of p)
                             'token_scopes (or (principal-token-scopes p) 'null)))))

;; the user's own language — the durable preference a workflow binds to as
;; ${principal.locale}, as opposed to the per-request Accept-Language header
(define (ep-profile req)
  (with-auth req (lambda (p)
    (define b (read-json-body req))
    (define loc (hash-ref b 'locale #f))
    (cond
      [(not (and (string? loc) (regexp-match #px"^[a-zA-Z]{2,3}([-_][A-Za-z0-9]{2,8})*$" loc)))
       (err "locale required, e.g. \"es\" or \"es-419\"" 400)]
      [else
       (set-user-locale! db-conn (principal-user-id p) loc)
       (json-response (hasheq 'ok #t 'locale loc))]))))

(define (ep-members-list req)
  (with-auth req (lambda (p)
    (define rows (query-rows db-conn
      (string-append "SELECT u.id, u.username, m.role_key FROM memberships m "
                     "JOIN users u ON u.id = m.user_id WHERE m.team_id = ? ORDER BY u.username")
      (principal-team-id p)))
    (json-response (hasheq 'members (for/list ([r (in-list rows)])
                                      (hasheq 'user_id (vector-ref r 0)
                                              'username (vector-ref r 1)
                                              'role (vector-ref r 2))))))))

(define (ep-add-member req)
  (define p (current-principal req))
  (cond
    [(not p) (unauthorized)]
    [else
     (require-perm db-conn p "members:manage")           ; → localized 403 on failure
     (define body (read-json-body req))
     (define username (hash-ref body 'username #f))
     (define role (hash-ref body 'role "member"))
     (cond
       [(not username) (err "username required" 400)]
       [else
        (define uid (create-user! db-conn #:username username #:password (hash-ref body 'password #f)))
        (add-member! db-conn #:user uid #:team (principal-team-id p) #:role role)
        (audit! db-conn #:action "member.add" #:actor-type "user" #:actor-id (principal-user-id p)
                #:team-id (principal-team-id p) #:resource-type "user" #:resource-id uid)
        (define-values (tok _t)
          (issue-token! db-conn #:user uid #:team (principal-team-id p) #:scopes '("*:*")))
        (json-response (hasheq 'user_id uid 'role role 'token tok) #:code 201)])]))

(define (ep-admin-status req)
  (define p (current-principal req))
  (cond
    [(not p) (unauthorized)]
    [else
     (require-perm db-conn p "instance:manage")          ; operator-only → localized 403
     (json-response (hasheq 'ok #t
                            'multitenant (multitenant?)
                            'users (query-value db-conn "SELECT COUNT(*) FROM users")
                            'teams (query-value db-conn "SELECT COUNT(*) FROM teams")
                            'orgs (query-value db-conn "SELECT COUNT(*) FROM orgs")))]))

;; ---- multi-tenancy: the two management planes (slice 45) --------------------
;; Superadmin plane (/api/orgs*, instance:manage) runs the INSTANCE; org-admin
;; plane (/api/org*, org:manage) runs ONE company. Both 404 when the flag is off —
;; the surface disappears, the authorization semantics do not change.
;; See docs/design/multi-tenancy.md.

(define (with-mt req proc)          ; flag gate → 404, so the feature is invisible when off
  (if (multitenant?) (proc) (err "multi-tenancy is not enabled on this instance" 404)))

;; the caller's own company, from their home org (never from a request parameter —
;; an org admin must not be able to name someone else's org)
(define (caller-org p) (or (principal-org-id p) (team-org db-conn (principal-team-id p))))

;; ---- superadmin plane -------------------------------------------------------
(define (ep-orgs-list req)
  (with-mt req (lambda ()
    (with-auth req (lambda (p)
      (require-perm db-conn p "instance:manage")
      (json-response (hasheq 'orgs (org-list db-conn))))))))

(define (ep-orgs-create req)
  (with-mt req (lambda ()
    (with-auth req (lambda (p)
      (require-perm db-conn p "instance:manage")
      (define b (read-json-body req))
      (define name (hash-ref b 'name #f))
      (define owner (hash-ref b 'owner_username #f))
      (cond
        [(or (not name) (not owner)) (err "name and owner_username required" 400)]
        [(query-maybe-value db-conn "SELECT id FROM users WHERE username = ?" (format "~a" owner))
         (err "owner_username already exists on this instance" 409)]     ; TEN-2b: usernames are global
        [(and (hash-ref b 'plan #f) (not (org-plan? (format "~a" (hash-ref b 'plan)))))
         (err (format "unknown plan; expected one of ~a"
                      (string-join (sort (hash-keys org-plan-quotas) string<?) ", ")) 400)]
        [else
         (define created
          (org-create! db-conn p
                       #:name (format "~a" name)
                       #:slug (let ([sl (hash-ref b 'slug #f)]) (and sl (format "~a" sl)))
                       #:plan (format "~a" (hash-ref b 'plan "trial"))
                       #:owner-username (format "~a" owner)
                       #:owner-password (let ([pw (hash-ref b 'owner_password #f)]) (and pw (format "~a" pw)))
                       #:owner-name (let ([n (hash-ref b 'owner_name #f)]) (and n (format "~a" n)))
                       #:team-name (format "~a" (hash-ref b 'team_name "Engineering"))
                       #:team-slug (org-slugify (hash-ref b 'team_slug "engineering"))))
         ;; #f means the caller named a slug that is already a company. Refusing is
         ;; the whole point: a pipeline re-run must not mint `acme-1`. 409 + the
         ;; slug tells the caller to GET /api/orgs/<slug> instead.
         (if created
             (json-response created #:code 201)
             (err (format "an organization with slug '~a' already exists"
                          (org-slugify (hash-ref b 'slug "")))
                  409))]))))))

;; Every /api/orgs/<ref> route addresses a company by EITHER its id or its slug.
;; A devops caller holds the slug it declared in source control; it never saw the
;; id the server minted. Resolve once, here, so no endpoint has to remember.
(define (with-org req ref proc)
  (with-mt req (lambda ()
    (with-auth req (lambda (p)
      (require-perm db-conn p "instance:manage")
      (define id (org-resolve db-conn ref))
      (if id (proc p id) (err "not found" 404)))))))

(define (ep-org-get req ref)
  (with-org req ref (lambda (p id) (json-response (org-get db-conn id)))))

(define (ep-org-status req ref status)
  (with-org req ref (lambda (p id)
    (org-set-status! db-conn p id status)
    (json-response (hasheq 'ok #t 'org_id id 'status status)))))

;; PATCH — rename, or move the company onto another plan. Partial: send only the
;; fields you mean. A plan change re-applies that plan's caps (see org-update!).
(define (ep-org-update req ref)
  (with-org req ref (lambda (p id)
    (define b (read-json-body req))
    (define name (let ([n (hash-ref b 'name #f)]) (and n (format "~a" n))))
    (define plan (let ([pl (hash-ref b 'plan #f)]) (and pl (format "~a" pl))))
    (cond
      [(and (not name) (not plan)) (err "name and/or plan required" 400)]
      [(and plan (not (org-plan? plan)))
       (err (format "unknown plan; expected one of ~a"
                    (string-join (sort (hash-keys org-plan-quotas) string<?) ", ")) 400)]
      [else (json-response (org-update! db-conn p id #:name name #:plan plan))]))))

(define (ep-org-quota req ref)
  (with-org req ref (lambda (p id)
    (define b (read-json-body req))
    (define dim (hash-ref b 'dimension #f))
    (define lim (hash-ref b 'limit #f))
    (cond
      [(or (not dim) (not lim)) (err "dimension and limit required" 400)]
      [else
       (set-org-limit! db-conn id (format "~a" dim) lim #:window (format "~a" (hash-ref b 'window "day")))
       (audit! db-conn #:action "org.quota.set" #:actor-type "user" #:actor-id (principal-user-id p)
               #:resource-type "org" #:resource-id id)
       (json-response (hasheq 'ok #t 'org_id id 'dimension dim 'limit lim))]))))

;; demo fixture: two complete companies with known dev logins (see
;; domain/samples/tenants.rkt). Superadmin-only, refuses to run twice.
(define (ep-seed-tenants req)
  (with-mt req (lambda ()
    (with-auth req (lambda (p)
      (require-perm db-conn p "instance:manage")
      (cond
        [(tenants-seeded? db-conn) (err "demo tenants already seeded" 409)]
        [else
         (define seeded (seed-tenants! db-conn p))
         (json-response (hasheq 'ok #t 'tenants seeded
                                'note "DEV FIXTURE — these passwords are public; never seed a production instance")
                        #:code 201)]))))))

;; ---- org-admin plane --------------------------------------------------------
(define (ep-my-org req)
  (with-mt req (lambda ()
    (with-auth req (lambda (p)
      (require-perm db-conn p "org:read")
      (define o (and (caller-org p) (org-get db-conn (caller-org p))))
      (if o (json-response o) (err "no organization for this principal" 404)))))))

(define (ep-my-org-teams req)
  (with-mt req (lambda ()
    (with-auth req (lambda (p)
      (require-perm db-conn p "org:read")
      (json-response (hasheq 'teams (org-teams db-conn (caller-org p)))))))))

(define (ep-my-org-team-create req)
  (with-mt req (lambda ()
    (with-auth req (lambda (p)
      (require-perm db-conn p "org:manage")      ; the tier gate
      (require-perm db-conn p "team:create")
      (define b (read-json-body req))
      (define name (hash-ref b 'name #f))
      (cond
        [(not name) (err "name required" 400)]
        [else
         (define t (org-add-team! db-conn p (caller-org p)
                                  #:name (format "~a" name)
                                  #:slug (let ([sl (hash-ref b 'slug #f)]) (and sl (format "~a" sl)))))
         (if t (json-response t #:code 201)
             (err "a team with that slug already exists in this organization" 409))]))))))

(define (ep-my-org-member-add req)
  (with-mt req (lambda ()
    (with-auth req (lambda (p)
      (require-perm db-conn p "org:manage")      ; the tier gate
      (require-perm db-conn p "members:manage")
      (define b (read-json-body req))
      (define u (hash-ref b 'username #f))
      (define org-role (let ([r (hash-ref b 'org_role #f)]) (and r (format "~a" r))))
      (cond
        [(not u) (err "username required" 400)]
        [(and org-role (not (org-role-key? org-role))) (err "unknown org_role" 400)]
        [(query-maybe-value db-conn "SELECT id FROM users WHERE username = ?" (format "~a" u))
         (err "username already exists on this instance" 409)]
        [else
         (define r (org-attach-member! db-conn p (caller-org p)
                                       #:username (format "~a" u)
                                       #:password (let ([pw (hash-ref b 'password #f)]) (and pw (format "~a" pw)))
                                       #:display-name (let ([d (hash-ref b 'display_name #f)]) (and d (format "~a" d)))
                                       #:team (let ([t (hash-ref b 'team_id #f)]) (and t (format "~a" t)))
                                       #:role (format "~a" (hash-ref b 'role "member"))
                                       #:org-role org-role))
         (if r (json-response r #:code 201)
             (err "no such team in this organization" 400))]))))))

(define (ep-my-org-audit req)
  (with-mt req (lambda ()
    (with-auth req (lambda (p)
      (require-perm db-conn p "org:read")        ; the tier gate
      (require-perm db-conn p "audit:read")
      (define lim (or (string->number (query-param req 'limit "50")) 50))
      (json-response (hasheq 'events (org-audit db-conn (caller-org p) #:limit lim))))))))

(define (ep-login req)
  (define body (read-json-body req))
  (define username (hash-ref body 'username #f))
  (define password (hash-ref body 'password #f))
  (define code (hash-ref body 'code #f))
  (cond
    [(or (not username) (not password)) (err "username and password required" 400)]
    [else
     (define uid (authenticate db-conn username password #:code code))
     (cond
       [(not uid) (unauthorized)]                       ; bad password / missing-or-bad 2FA code
       [else
        (define tid (first-team-for db-conn uid))
        (define-values (tok _t) (issue-token! db-conn #:user uid #:team tid #:name "login" #:scopes '("*:*")))
        (json-response (hasheq 'token tok 'user_id uid 'team_id tid))])]))

(define (ep-password req)
  (with-auth req (lambda (p)
    (define b (read-json-body req))
    (define cur (hash-ref b 'current_password #f))
    (define new (hash-ref b 'new_password #f))
    (cond
      [(or (not cur) (not new)) (err "current_password and new_password required" 400)]
      [(< (string-length new) 6) (err "new password too short (min 6)" 400)]
      [(change-password! db-conn (principal-user-id p) cur new) (json-response (hasheq 'ok #t))]
      [else (err "current password incorrect" 403)]))))

(define (ep-2fa-enable req)
  (define p (current-principal req))
  (cond
    [(not p) (unauthorized)]
    [else
     (define-values (secret uri) (enable-2fa! db-conn (principal-user-id p)))
     (json-response (hasheq 'secret secret 'otpauth_uri uri
                            'note "2FA enabled — future logins for this user require a TOTP code"))]))

;; ---- notes (ownable/shareable resource) -------------------------------------
;; refuse an endpoint whose feature a team has turned off (→ localized 403)
(define (require-feature p name)
  (unless (feature-enabled? db-conn (principal-team-id p) name)
    (raise (exn:fail:forbidden (format "feature ~a is disabled" name) (current-continuation-marks) name))))

(define (with-auth req proc)
  (define p (current-principal req))
  (cond
    [(not p) (unauthorized)]
    ;; ONB-7 read-only, now org-aware: a suspended COMPANY freezes every team in it
    [(and (tenant-read-only? db-conn (principal-team-id p)) (not (GET? (request-method req))))
     (err "tenant suspended — writes are disabled; contact your administrator" 402)]
    [else (proc p)]))

(define (ep-notes-create req)
  (with-auth req (lambda (p)
    (define b (read-json-body req))
    (json-response (notes-create db-conn p #:title (hash-ref b 'title "")
                                 #:body (hash-ref b 'body "") #:visibility (hash-ref b 'visibility "team"))
                   #:code 201))))

(define (ep-notes-list req)
  (with-auth req (lambda (p) (json-response (hasheq 'notes (notes-list db-conn p))))))

;; ---- documents (offset-paginated) -------------------------------------------
(define (ep-documents-create req)
  (with-auth req (lambda (p)
    (define b (read-json-body req))
    (json-response (documents-create db-conn p #:title (hash-ref b 'title "")
                                     #:content (hash-ref b 'content "") #:visibility (hash-ref b 'visibility "team"))
                   #:code 201))))
(define (ep-documents-list req)
  (with-auth req (lambda (p)
    (define off (or (string->number (query-param req 'offset "0")) 0))
    (json-response (documents-list db-conn p #:offset off)))))
(define (ep-documents-get req id)
  (with-auth req (lambda (p)
    (define d (documents-get db-conn p id))
    (if d (json-response d) (err "not found" 404)))))
(define (ep-documents-update req id)
  (with-auth req (lambda (p)
    (define b (read-json-body req))
    (define d (documents-update db-conn p id #:title (hash-ref b 'title #f)
                                #:content (hash-ref b 'content #f) #:visibility (hash-ref b 'visibility #f)))
    (if d (json-response d) (err "not found" 404)))))
(define (ep-documents-delete req id)
  (with-auth req (lambda (p)
    (if (documents-delete db-conn p id) (json-response (hasheq 'ok #t 'id id)) (err "not found" 404)))))

(define (ep-notes-get req id)
  (with-auth req (lambda (p)
    (define n (notes-get db-conn p id))
    (if n (json-response n) (err "not found" 404)))))

(define (ep-notes-update req id)
  (with-auth req (lambda (p)
    (define b (read-json-body req))
    (define n (notes-update db-conn p id #:title (hash-ref b 'title #f)
                            #:body (hash-ref b 'body #f) #:visibility (hash-ref b 'visibility #f)))
    (if n (json-response n) (err "not found" 404)))))

(define (ep-notes-delete req id)
  (with-auth req (lambda (p)
    (if (notes-delete db-conn p id) (json-response (hasheq 'deleted #t)) (err "not found" 404)))))

(define (ep-notes-share req id)
  (with-auth req (lambda (p)
    (define b (read-json-body req))
    (define target (hash-ref b 'user_id #f))
    (cond
      [(not target) (err "user_id required" 400)]
      [(notes-share db-conn p id #:user target #:permission (hash-ref b 'permission "notes:read"))
       (json-response (hasheq 'shared #t))]
      [else (err "not found" 404)]))))

;; ---- AI jobs: RBAC → quota → governor slot → meter --------------------------
(define GOV (make-governor))

(define (quota-429 d dim)
  (json-response (hasheq 'error "quota exceeded" 'dimension dim
                         'subject (hash-ref d 'subject "team")   ; which tier refused: team | org
                         'used (hash-ref d 'used) 'limit (hash-ref d 'limit)
                         'window (hash-ref d 'window))
                 #:code 429))

(define (ep-ai-echo req)
  (with-auth req (lambda (p)
    (require-perm db-conn p "chat:use")
    (define b (read-json-body req))
    (define prompt (hash-ref b 'prompt ""))
    (define est (max 1 (quotient (string-length prompt) 4)))       ; token estimate (chars/4)
    (define sid (principal-team-id p))
    (define rq (tenant-quota-check db-conn p "ai.requests" 1))
    (define tq (tenant-quota-check db-conn p "ai.tokens.total" est))
    (cond
      [(not (hash-ref rq 'allowed)) (quota-429 rq "ai.requests")]
      [(not (hash-ref tq 'allowed)) (quota-429 tq "ai.tokens.total")]
      [else
       (define-values (climit _w) (get-limit db-conn "team" sid "ai.concurrency"))
       (with-slot GOV (string-append "team:" sid) (or climit 2)
         (lambda (inflight)
           (sleep 0.12)                                             ; simulate model latency
           (tenant-quota-record! db-conn p "ai.requests" 1)
           (tenant-quota-record! db-conn p "ai.tokens.total" est)
           (define after (quota-check db-conn "team" sid "ai.tokens.total" 0))
           (json-response (hasheq 'reply (string-upcase prompt)
                                  'tokens_used est
                                  'concurrent inflight
                                  'remaining_tokens (hash-ref after 'remaining)))))]))))

;; federated executor selection: 'executor in the body picks a named backend;
;; #f (absent / "" / "local") means the local node.
(define (pick-executor b)
  (define e (hash-ref b 'executor #f))
  (and e (let ([n (format "~a" e)]) (and (not (member n '("" "local"))) n))))
(define (executor-model ex)
  (if ex (let ([c (executor-config ex)]) (if c (cadr c) ex)) (hash-ref (model-info) 'model)))

(define (ep-executors req)
  (with-auth req (lambda (p)
    (json-response (hasheq 'local (hasheq 'name "local" 'model (hash-ref (model-info) 'model)
                                          'configured (model-configured?) 'remote #f)
                           'executors (list-executors))))))

;; real model call (falls back to simulated when no model is configured)
(define (ep-ai-chat req)
  (with-auth req (lambda (p)
    (require-perm db-conn p "chat:use")
    (require-feature p "chat")
    (define b (read-json-body req))
    (define prompt (hash-ref b 'prompt ""))
    (define ex (pick-executor b))
    (when ex (require-perm db-conn p "instance:manage"))          ; routing to specific compute = operator
    (define est (estimate-tokens prompt))
    (define sid (principal-team-id p))
    (define rq (tenant-quota-check db-conn p "ai.requests" 1))
    (define tq (tenant-quota-check db-conn p "ai.tokens.total" est))
    (cond
      [(and ex (not (executor-exists? ex))) (err "unknown executor" 400)]
      [(not (hash-ref rq 'allowed)) (quota-429 rq "ai.requests")]
      [(not (hash-ref tq 'allowed)) (quota-429 tq "ai.tokens.total")]
      [else
       (define-values (climit _w) (get-limit db-conn "team" sid "ai.concurrency"))
       (with-slot GOV (string-append "team:" sid) (or climit 2)
         (lambda (inflight)
           (define-values (reply tokens) (run-chat prompt #:executor ex))   ; local or federated
           (tenant-quota-record! db-conn p "ai.requests" 1)
           (tenant-quota-record! db-conn p "ai.tokens.total" tokens)
           (define after (quota-check db-conn "team" sid "ai.tokens.total" 0))
           (json-response (hasheq 'reply reply 'tokens_used tokens
                                  'model (executor-model ex)
                                  'executor (or ex "local")
                                  'concurrent inflight
                                  'remaining_tokens (hash-ref after 'remaining)))))]))))

(define (ep-ai-model req)
  (with-auth req (lambda (p) (json-response (model-info)))))

;; streaming chat: same admission path, tokens streamed as SSE, metered at end.
(define (ep-ai-chat-stream req)
  (with-auth req (lambda (p)
    (require-perm db-conn p "chat:use")
    (require-feature p "chat")
    (define b (read-json-body req))
    (define prompt (hash-ref b 'prompt ""))
    (define ex (pick-executor b))
    (when ex (require-perm db-conn p "instance:manage"))
    (define est (estimate-tokens prompt))
    (define sid (principal-team-id p))
    (define rq (tenant-quota-check db-conn p "ai.requests" 1))
    (define tq (tenant-quota-check db-conn p "ai.tokens.total" est))
    (cond
      [(and ex (not (executor-exists? ex))) (err "unknown executor" 400)]
      [(not (hash-ref rq 'allowed)) (quota-429 rq "ai.requests")]
      [(not (hash-ref tq 'allowed)) (quota-429 tq "ai.tokens.total")]
      [else
       (define-values (climit _w) (get-limit db-conn "team" sid "ai.concurrency"))
       (sse-response
        (lambda (emit)
          (with-slot GOV (string-append "team:" sid) (or climit 2)
            (lambda (inflight)
              (define tokens (run-chat-stream prompt (lambda (tok) (emit (hasheq 'token tok))) #:executor ex))
              (tenant-quota-record! db-conn p "ai.requests" 1)
              (tenant-quota-record! db-conn p "ai.tokens.total" tokens)
              (define after (quota-check db-conn "team" sid "ai.tokens.total" 0))
              (emit (hasheq 'done #t 'tokens_used tokens
                            'model (executor-model ex)
                            'executor (or ex "local")
                            'remaining_tokens (hash-ref after 'remaining)))))))]))))

;; agent mode: the model uses tools (RBAC-checked per tool) to operate the platform.
(define (ep-agent req)
  (with-auth req (lambda (p)
    (require-perm db-conn p "chat:use")
    (require-feature p "agent")
    (cond
      [(not (agent-configured?))
       (err "agent mode requires a configured model (set TELEMACHUS_MODEL_URL)" 503)]
      [else
       (define b (read-json-body req))
       (define prompt (hash-ref b 'prompt ""))
       (define sid (principal-team-id p))
       (define rq (tenant-quota-check db-conn p "ai.requests" 1))
       (cond
         [(not (hash-ref rq 'allowed)) (quota-429 rq "ai.requests")]
         [else
          (define-values (climit _w) (get-limit db-conn "team" sid "ai.concurrency"))
          (sse-response
           (lambda (emit)
             (with-slot GOV (string-append "team:" sid) (or climit 2)
               (lambda (inflight)
                 (run-agent-flow db-conn p prompt (lambda (ev) (emit ev)))
                 (tenant-quota-record! db-conn p "ai.requests" 1)
                 (tenant-quota-record! db-conn p "ai.tokens.total" (max (estimate-tokens prompt) 50))))))])]))))

(define (ep-usage req)
  (with-auth req (lambda (p)
    (define sid (principal-team-id p))
    (json-response
     (hasheq 'team_id sid
             'quota (for/list ([dim (in-list '("ai.tokens.total" "ai.requests" "ai.concurrency"))])
                      (define d (quota-check db-conn "team" sid dim 0))
                      (hasheq 'dimension dim 'used (hash-ref d 'used)
                              'limit (hash-ref d 'limit) 'remaining (hash-ref d 'remaining))))))))

;; plugin tool management (per-team activate/deactivate)
(define (ep-tools-list req)
  (with-auth req (lambda (p)
    (json-response (hasheq 'tools (tool-settings-for db-conn (principal-team-id p)))))))

;; ---- Translation app --------------------------------------------------------
(define (ep-translate req)
  (with-auth req (lambda (p)
    (require-perm db-conn p "chat:use")
    (require-feature p "translate")
    (define b (read-json-body req))
    (define text (hash-ref b 'text ""))
    (define tgt (hash-ref b 'target_lang ""))
    (cond
      [(or (string=? text "") (string=? tgt "")) (err "text and target_lang required" 400)]
      [else
       (define sid (principal-team-id p))
       (define est (estimate-tokens text))
       (define rq (tenant-quota-check db-conn p "ai.requests" 1))
       (define tq (tenant-quota-check db-conn p "ai.tokens.total" est))
       (cond
         [(not (hash-ref rq 'allowed)) (quota-429 rq "ai.requests")]
         [(not (hash-ref tq 'allowed)) (quota-429 tq "ai.tokens.total")]
         [else
          (define-values (climit _w) (get-limit db-conn "team" sid "ai.concurrency"))
          (with-slot GOV (string-append "team:" sid) (or climit 2)
            (lambda (inflight)
              (define-values (job tokens)
                (translate! db-conn p #:text text #:target-lang tgt
                            #:source-lang (hash-ref b 'source_lang "auto")
                            #:use-glossary (and (hash-ref b 'use_glossary #t) #t)))
              (tenant-quota-record! db-conn p "ai.requests" 1)
              (tenant-quota-record! db-conn p "ai.tokens.total" tokens)
              (json-response (hash-set (hash-set job 'tokens_used tokens) 'concurrent inflight))))])]))))

(define (ep-translate-list req)
  (with-auth req (lambda (p) (json-response (hasheq 'translations (translate-list db-conn p))))))

(define (ep-translate-catalog req)
  (with-auth req (lambda (p)
    (require-perm db-conn p "chat:use")
    (require-feature p "translate")
    (define b (read-json-body req))
    (define cat (hash-ref b 'catalog (hasheq)))
    (define tgt (hash-ref b 'target_lang ""))
    (cond
      [(or (not (hash? cat)) (string=? tgt "")) (err "catalog (object) and target_lang required" 400)]
      [else
       (define sid (principal-team-id p))
       (define tq (tenant-quota-check db-conn p "ai.tokens.total" (estimate-tokens (format "~a" cat))))
       (cond
         [(not (hash-ref tq 'allowed)) (quota-429 tq "ai.tokens.total")]
         [else
          (define-values (climit _w) (get-limit db-conn "team" sid "ai.concurrency"))
          (with-slot GOV (string-append "team:" sid) (or climit 2)
            (lambda (_inflight)
              (define-values (out tokens) (translate-catalog! db-conn p #:catalog cat #:target-lang tgt))
              (tenant-quota-record! db-conn p "ai.tokens.total" tokens)
              (json-response (hasheq 'catalog out 'target_lang tgt 'tokens_used tokens))))])]))))

(define (ep-glossary-list req)
  (with-auth req (lambda (p) (json-response (hasheq 'glossary (glossary-list db-conn p))))))

(define (ep-glossary-add req)
  (with-auth req (lambda (p)
    (define b (read-json-body req))
    (define term (hash-ref b 'term ""))
    (define tr (hash-ref b 'translation ""))
    (define tgt (hash-ref b 'target_lang ""))
    (cond
      [(or (string=? term "") (string=? tr "") (string=? tgt "")) (err "term, translation, target_lang required" 400)]
      [else (json-response (glossary-add! db-conn p #:term term #:translation tr #:target-lang tgt))]))))

;; ---- API tokens (programmatic access) ---------------------------------------
(define (ep-tokens-create req)
  (with-auth req (lambda (p)
    (require-perm db-conn p "settings:manage")
    (define b (read-json-body req))
    (define scopes (let ([s (hash-ref b 'scopes #f)]) (if (list? s) s '("*:read"))))
    (define name (let ([n (hash-ref b 'name #f)]) (if n (format "~a" n) "api")))
    (define-values (raw tokid)
      (issue-token! db-conn #:user (principal-user-id p) #:team (principal-team-id p) #:name name #:scopes scopes))
    (audit! db-conn #:action "token.issue" #:actor-type "user" #:actor-id (principal-user-id p) #:team-id (principal-team-id p))
    (json-response (hasheq 'id tokid 'token raw 'name name 'scopes scopes) #:code 201))))    ; raw shown once

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

(define (ep-search req)
  (with-auth req (lambda (p)
    (require-feature p "search")
    (define q (string-trim (query-param req 'q)))
    (if (< (string-length q) 2)
        (json-response (hasheq 'query q 'results '()))
        (json-response (hasheq 'query q 'results (search-all db-conn p q)))))))

(define (ep-audit req)
  (with-auth req (lambda (p)
    (require-perm db-conn p "settings:manage")
    (json-response (hasheq 'audit (audit-list db-conn (principal-team-id p) #:limit 100))))))

;; ---- async jobs -------------------------------------------------------------
(define (ep-jobs-create req)
  (with-auth req (lambda (p)
    (require-perm db-conn p "chat:use")
    (define b (read-json-body req))
    (define kind (hash-ref b 'kind #f))
    (cond
      [(not kind) (err "kind required" 400)]
      [else
       (define pr (hash-ref b 'priority 0))
       (define id (enqueue-job! db-conn #:team (principal-team-id p) #:user (principal-user-id p)
                                #:kind (format "~a" kind)
                                #:payload (let ([pl (hash-ref b 'payload (hasheq))]) (if (hash? pl) pl (hasheq)))
                                #:priority (if (number? pr) pr 0)))
       (json-response (hasheq 'id id 'status "queued") #:code 202)]))))

(define (ep-jobs-list req)
  (with-auth req (lambda (p) (json-response (hasheq 'jobs (list-jobs db-conn (principal-team-id p)))))))

(define (ep-job-get req id)
  (with-auth req (lambda (p)
    (define j (get-job db-conn id (principal-team-id p)))
    (if j (json-response j) (err "not found" 404)))))

(define (ep-job-cancel req id)
  (with-auth req (lambda (p)
    (define r (cancel-job! db-conn id (principal-team-id p)))
    (cond
      [(eq? r #t) (json-response (hasheq 'ok #t 'id id 'status "canceled"))]
      [(eq? r 'not-cancelable) (err "job already running or finished — cannot cancel" 409)]
      [else (err "not found" 404)]))))

;; ---- document repository (slices 49-50) --------------------------------------
;; The data plane is deliberately NOT JSON: a document is bytes, and base64 inside a
;; JSON envelope costs a third of the wire and forces the whole file into memory at
;; both ends. Upload is a raw body with the key in the path; download streams back.
;;
;; This is the control plane the S3 front door will NOT replace (DOC-12) — sharing,
;; grants and visibility have no expression in the S3 protocol.

(define (obj-json o)
  (hasheq 'id (hash-ref o 'id) 'key (hash-ref o 'key)
          'visibility (hash-ref o 'visibility) 'owner_user_id (hash-ref o 'owner_user_id)
          'size (hash-ref o 'size) 'content_type (hash-ref o 'content_type)
          'filename (hash-ref o 'filename) 'version (hash-ref o 'version)
          'digest (hash-ref o 'digest)
          'created_at (hash-ref o 'created_at) 'updated_at (hash-ref o 'updated_at)))

;; Uploads land as the raw request body. `request-post-data/raw` buffers it, which is
;; why TELEMACHUS_MAX_UPLOAD exists and why DOC-15's listener is the next slice — the
;; port handed to repo-put! is honest about streaming even though what feeds it today
;; is not.
(define (ep-repo-put req key)
  (with-auth req (lambda (p)
    (with-handlers ([exn:fail:user? (lambda (e) (err (exn-message e) 400))])
      (define raw (or (request-post-data/raw req) #""))
      (define o (repo-put! db-conn p
                           #:key key
                           #:port (open-input-bytes raw)
                           #:content-type (or (req-header req #"content-type") "application/octet-stream")
                           #:filename (query-param req 'filename "")
                           #:visibility (let ([v (query-param req 'visibility "")])
                                          (and (member v VISIBILITIES) v))
                           #:max-bytes (max-upload-bytes)))
      (json-response (obj-json o) #:code 201)))))

(define (ep-repo-list req)
  (with-auth req (lambda (p)
    (define objs (repo-list db-conn p
                            #:prefix (query-param req 'prefix "")
                            #:limit (or (string->number (query-param req 'limit "100")) 100)
                            #:offset (or (string->number (query-param req 'offset "0")) 0)))
    (json-response (hasheq 'objects (map obj-json objs)
                           'usage (repo-usage db-conn p))))))

(define (ep-repo-meta req id)
  (with-auth req (lambda (p)
    (define o (repo-get db-conn p id))
    (if o
        (json-response (hash-set (obj-json o) 'versions (repo-versions db-conn p id)))
        (err "not found" 404)))))

;; DOC-10: every document is served as an attachment with nosniff and a
;; script-denying CSP unless its type is on the short inline allowlist. An SVG
;; rendered inline from this origin is stored XSS with the console behind it, and
;; "any format" was a requirement about what may be STORED, not about what a browser
;; may be talked into executing.
(define (ep-repo-get req id)
  (with-auth req (lambda (p)
    (define-values (o in) (repo-open db-conn p id
                                     #:version (let ([v (query-param req 'version "")])
                                                 (and (not (string=? v "")) v))))
    (cond
      [(not in) (err "not found" 404)]
      [else
       (define ct (hash-ref o 'content_type))
       (define inline? (and (inline-safe? ct) (equal? (query-param req 'disposition "") "inline")))
       (define fname (let ([f (hash-ref o 'filename)])
                       (if (string=? f "") (car (reverse (string-split (hash-ref o 'key) "/"))) f)))
       (define safe-name (regexp-replace* #px"[^A-Za-z0-9._-]" fname "_"))
       (response/output
        #:mime-type (string->bytes/utf-8 (if inline? ct "application/octet-stream"))
        #:headers (list (make-header #"X-Content-Type-Options" #"nosniff")
                        (make-header #"Content-Security-Policy" #"default-src 'none'; sandbox")
                        (make-header #"Cache-Control" #"private, max-age=0, must-revalidate")
                        (make-header #"ETag" (string->bytes/utf-8 (string-append "\"" (hash-ref o 'digest) "\"")))
                        (make-header #"Content-Disposition"
                                     (string->bytes/utf-8
                                      (string-append (if inline? "inline" "attachment")
                                                     "; filename=\"" safe-name "\""))))
        (lambda (out)
          (dynamic-wind void
                        (lambda () (copy-port in out))
                        (lambda () (close-input-port in)))))]))))

(define (ep-repo-visibility req id)
  (with-auth req (lambda (p)
    (with-handlers ([exn:fail:user? (lambda (e) (err (exn-message e) 400))])
      (define v (fmt (read-json-body req) 'visibility))
      (define o (repo-set-visibility! db-conn p id v))
      (if o (json-response (obj-json o)) (err "not found" 404))))))

(define (ep-repo-share req id)
  (with-auth req (lambda (p)
    (define u (fmt (read-json-body req) 'user_id))
    (cond
      [(string=? u "") (err "user_id is required" 400)]
      [(repo-share! db-conn p id #:user u)
       (json-response (hasheq 'ok #t 'grants (repo-grants db-conn p id)))]
      [else (err "not found" 404)]))))

(define (ep-repo-unshare req id)
  (with-auth req (lambda (p)
    (define u (fmt (read-json-body req) 'user_id))
    (if (repo-unshare! db-conn p id #:user u)
        (json-response (hasheq 'ok #t 'grants (repo-grants db-conn p id)))
        (err "not found" 404)))))

(define (ep-repo-grants req id)
  (with-auth req (lambda (p)
    (define g (repo-grants db-conn p id))
    (if g (json-response (hasheq 'grants g)) (err "not found" 404)))))

;; A presigned link: a time-boxed URL a browser can follow with no bearer token, so
;; the console can hand a PDF straight to the viewer. Signed with the CALLER'S OWN
;; newest S3 key, which means the link can never do more than that key can, and
;; revoking the key kills every link made with it.
(define (ep-repo-presign req id)
  (with-auth req (lambda (p)
    (define o (repo-get db-conn p id))
    (define port (s3-port))
    (define cred (and o (s3-cred-newest db-conn p)))
    (cond
      [(not o) (err "not found" 404)]
      [(not port) (err "the S3 endpoint is not enabled on this instance (set TELEMACHUS_S3_PORT)" 409)]
      [(not cred) (err "create an S3 access key first — a link is signed with one" 409)]
      [else
       (define secs (max 1 (min 604800 (or (string->number (query-param req 'expires "900")) 900))))
       (define host (format "~a:~a" (if (equal? (bind-ip) "0.0.0.0") "127.0.0.1" (bind-ip)) port))
       ;; the key is signed in the form it will be sent, so encode once, here
       (define encoded-key
         (string-join (map (lambda (seg) (aws-uri-encode seg))
                           (string-split (hash-ref o 'key) "/")) "/"))
       (define path (string-append "/" (team-slug-of p) "/" encoded-key))
       (define qs (presign-query #:method "GET" #:path path
                                 #:access-key (car cred) #:secret (cdr cred)
                                 #:region (s3-region) #:host host #:expires secs))
       (json-response (hasheq 'url (format "http://~a~a?~a" host path qs)
                              'expires_in secs
                              'key (hash-ref o 'key)))]))))

(define (ep-s3-creds req)
  (with-auth req (lambda (p) (json-response (hasheq 'credentials (s3-cred-list db-conn p)
                                                    'endpoint (s3-endpoint-url)
                                                    'region (s3-region)
                                                    'bucket (team-slug-of p))))))

(define (ep-s3-cred-create req)
  (with-auth req (lambda (p)
    (define b (read-json-body req))
    (define scopes (let ([v (hash-ref b 'scopes #f)])
                     (and (list? v) (andmap string? v) v)))
    ;; the secret is in this response and in no other, ever. With no scopes given the
    ;; issuer's own default applies — repeating a list here would silently shadow it.
    (json-response (if scopes
                       (s3-cred-issue! db-conn p #:name (fmt b 'name) #:scopes scopes)
                       (s3-cred-issue! db-conn p #:name (fmt b 'name)))
                   #:code 201))))

(define (ep-s3-cred-revoke req id)
  (with-auth req (lambda (p) (s3-cred-revoke! db-conn p id) (json-response (hasheq 'ok #t)))))

(define (team-slug-of p)
  (define v (query-maybe-value db-conn "SELECT slug FROM teams WHERE id = ?" (principal-team-id p)))
  (if (string? v) v ""))

;; What a client must be told to reach us: S3 lives on its own port because its
;; transport requirements differ (Expect: 100-continue, unbuffered bodies), and
;; path-style addressing because virtual-host style would need wildcard DNS.
(define (s3-port)
  (define raw (env* "TELEMACHUS_S3_PORT"))
  (define n (and raw (string->number raw)))
  (and n (exact-positive-integer? n) n))

(define (s3-endpoint-url)
  (define p (s3-port))
  (and p (format "http://~a:~a" (if (equal? (bind-ip) "0.0.0.0") "<host>" (bind-ip)) p)))

(define (ep-repo-delete req id)
  (with-auth req (lambda (p)
    (if (repo-delete! db-conn p id) (json-response (hasheq 'ok #t 'id id)) (err "not found" 404)))))

;; ---- workflows (slice 46) ---------------------------------------------------
;; The spec is the contract: `validate-spec` is reached the same way from here as
;; from `define-workflow`, so a JSON document and a Racket-authored one are held to
;; one definition of valid. Every run pins the caller as its principal and each
;; step re-checks it, so a workflow can never do what its starter could not.
(define (ep-workflows-create req)
  (with-auth req (lambda (p)
    (require-feature p "workflows")
    (define d (flow-publish! db-conn p (read-json-body req)))
    (json-response d #:code 201))))

(define (ep-workflows-list req)
  (with-auth req (lambda (p)
    (require-feature p "workflows")
    (json-response (hasheq 'workflows (flow-defs db-conn p))))))

;; contract discovery — deliberately unauthenticated: it describes the format this
;; build accepts, which an editor or a second implementation needs before it holds
;; a token, and it reveals nothing about the instance.
(define (ep-workflow-schema req) (json-response (spec-schema)))

(define (ep-workflow-get req slug)
  (with-auth req (lambda (p)
    (require-feature p "workflows")
    (define d (flow-def-by-slug db-conn p slug))
    (if d (json-response d) (err "not found" 404)))))

(define (ep-workflow-run req slug)
  (with-auth req (lambda (p)
    (require-feature p "workflows")
    (define d (flow-def-by-slug db-conn p slug))
    (cond
      [(not d) (err "not found" 404)]
      [else
       (define b (read-json-body req))
       (define in (let ([i (hash-ref b 'input (hasheq))]) (if (hash? i) i (hasheq))))
       (json-response (flow-run-start! db-conn p d #:input in) #:code 202)]))))

(define (ep-runs-list req)
  (with-auth req (lambda (p)
    (require-feature p "workflows")
    (json-response (hasheq 'runs (flow-runs db-conn p))))))

(define (ep-run-get req id)
  (with-auth req (lambda (p)
    (require-feature p "workflows")
    (define r (flow-run-get db-conn p id))
    (if r (json-response r) (err "not found" 404)))))

(define (ep-run-cancel req id)
  (with-auth req (lambda (p)
    (require-feature p "workflows")
    (define r (flow-run-cancel! db-conn p id))
    (cond
      [(eq? r #t) (json-response (hasheq 'ok #t 'id id 'status "canceled"))]
      [(eq? r 'not-cancelable) (err "run already finished — cannot cancel" 409)]
      [else (err "not found" 404)]))))

(define (ep-admin-seed req)
  (with-auth req (lambda (p)
    (require-perm db-conn p "settings:manage")
    (define counts (seed-samples! db-conn p))
    (audit! db-conn #:action "samples.seed" #:actor-type "user" #:actor-id (principal-user-id p) #:team-id (principal-team-id p))
    (json-response (hash-set counts 'ok #t)))))

(define (ep-metrics req)
  (with-auth req (lambda (p)
    (require-perm db-conn p "instance:manage")
    (define (n q) (query-value db-conn q))
    (json-response (hasheq
      'users (n "SELECT COUNT(*) FROM users")
      'teams (n "SELECT COUNT(*) FROM teams")
      'orgs (n "SELECT COUNT(*) FROM orgs")
      'notes (n "SELECT COUNT(*) FROM notes")
      'translations (n "SELECT COUNT(*) FROM translations")
      'active_tokens (n "SELECT COUNT(*) FROM api_tokens WHERE status = 'active'")
      'audit_events (n "SELECT COUNT(*) FROM audit_log")
      'tenants (n "SELECT COUNT(*) FROM provisioning"))))))

(define (ep-features req)
  (with-auth req (lambda (p) (json-response (hasheq 'features (features-for db-conn (principal-team-id p)))))))

(define (ep-feature-toggle req name)
  (with-auth req (lambda (p)
    (require-perm db-conn p "settings:manage")
    (define on? (and (hash-ref (read-json-body req) 'enabled #t) #t))
    (set-feature-enabled! db-conn (principal-team-id p) name on?)
    (audit! db-conn #:action "feature.toggle" #:actor-type "user" #:actor-id (principal-user-id p)
            #:team-id (principal-team-id p) #:resource-type "feature" #:resource-id name)
    (json-response (hasheq 'ok #t 'feature name 'enabled on?)))))

(define (ep-plugins req)
  (with-auth req (lambda (p) (json-response (hasheq 'plugins (loaded-plugins))))))

(define (ep-mcp req)
  (with-auth req (lambda (p) (json-response (hasheq 'servers (mcp-servers))))))

(define (ep-oop req)
  (with-auth req (lambda (p) (json-response (hasheq 'plugins (loaded-oop-plugins)
                                                    'capabilities (capability-names))))))

(define (ep-tool-toggle req name)
  (with-auth req (lambda (p)
    (require-perm db-conn p "settings:manage")
    (define b (read-json-body req))
    (define on? (and (hash-ref b 'enabled #t) #t))
    (set-tool-enabled! db-conn (principal-team-id p) name on?)
    (json-response (hasheq 'ok #t 'tool name 'enabled on?)))))

(define (ep-quota-set req)
  (with-auth req (lambda (p)
    (require-perm db-conn p "instance:manage")
    (define b (read-json-body req))
    (define dim (hash-ref b 'dimension #f))
    (define limit (hash-ref b 'limit #f))
    (cond
      [(or (not dim) (not limit)) (err "dimension and limit required" 400)]
      [else
       (set-limit! db-conn "team" (principal-team-id p) dim limit #:window (hash-ref b 'window "day"))
       (json-response (hasheq 'ok #t 'dimension dim 'limit limit))]))))

;; ---- routing ----------------------------------------------------------------
(define (GET? m) (bytes=? m #"GET"))
(define (POST? m) (bytes=? m #"POST"))
(define (PUT? m) (bytes=? m #"PUT"))
(define (DELETE? m) (bytes=? m #"DELETE"))
(define (PATCH? m) (bytes=? m #"PATCH"))
(define (OPTIONS? m) (bytes=? m #"OPTIONS"))

;; /api/notes/<id> → id ; /api/notes/<id>/share → id
(define (note-id segs)
  (and (= (length segs) 3) (equal? (car segs) "api") (equal? (cadr segs) "notes") (caddr segs)))
(define (tool-path segs)
  (and (= (length segs) 3) (equal? (car segs) "api") (equal? (cadr segs) "tools") (caddr segs)))
(define (token-path segs)
  (and (= (length segs) 3) (equal? (car segs) "api") (equal? (cadr segs) "tokens") (caddr segs)))
(define (feature-path segs)
  (and (= (length segs) 3) (equal? (car segs) "api") (equal? (cadr segs) "features") (caddr segs)))
(define (doc-id segs)
  (and (= (length segs) 3) (equal? (car segs) "api") (equal? (cadr segs) "documents") (caddr segs)))
(define (job-id segs)
  (and (= (length segs) 3) (equal? (car segs) "api") (equal? (cadr segs) "jobs") (caddr segs)))
(define (job-cancel-path segs)
  (and (= (length segs) 4) (equal? (list-ref segs 0) "api") (equal? (list-ref segs 1) "jobs")
       (equal? (list-ref segs 3) "cancel") (list-ref segs 2)))
(define (l10n-message-path segs)     ; PUT /api/l10n/messages/<message-id>
  (and (= (length segs) 4) (equal? (list-ref segs 0) "api") (equal? (list-ref segs 1) "l10n")
       (equal? (list-ref segs 2) "messages") (list-ref segs 3)))
(define (l10n-review-path segs)      ; POST /api/l10n/review/<translation-id>
  (and (= (length segs) 4) (equal? (list-ref segs 0) "api") (equal? (list-ref segs 1) "l10n")
       (equal? (list-ref segs 2) "review") (list-ref segs 3)))
(define (beta-decide-path segs)
  (and (= (length segs) 5) (equal? (list-ref segs 0) "api") (equal? (list-ref segs 1) "beta")
       (equal? (list-ref segs 2) "prospects") (equal? (list-ref segs 4) "decide") (list-ref segs 3)))
(define (share-id segs)
  (and (= (length segs) 4) (equal? (list-ref segs 0) "api") (equal? (list-ref segs 1) "notes")
       (equal? (list-ref segs 3) "share") (list-ref segs 2)))
;; /api/orgs/<ref> · /api/orgs/<ref>/{suspend,resume,quota} — <ref> is an id OR a slug
;; /api/repo/<key…> — a key contains slashes, so it is the whole tail rather than
;; one segment. Object operations address the object by ID (/api/repo-obj/<id>/…)
;; so a key can never be confused with an action.
(define (repo-key-path segs)
  (and (>= (length segs) 3) (equal? (car segs) "api") (equal? (cadr segs) "repo")
       (string-join (cddr segs) "/")))
(define (repo-obj-path segs)
  (and (= (length segs) 3) (equal? (car segs) "api") (equal? (cadr segs) "repo-obj")
       (caddr segs)))
(define (repo-obj-action segs action)
  (and (= (length segs) 4) (equal? (car segs) "api") (equal? (cadr segs) "repo-obj")
       (equal? (list-ref segs 3) action) (caddr segs)))

(define (workflow-slug segs)
  (and (= (length segs) 3) (equal? (car segs) "api") (equal? (cadr segs) "workflows") (caddr segs)))
(define (workflow-run-path segs)
  (and (= (length segs) 4) (equal? (list-ref segs 0) "api") (equal? (list-ref segs 1) "workflows")
       (equal? (list-ref segs 3) "run") (list-ref segs 2)))
(define (flow-run-id-path segs)
  (and (= (length segs) 3) (equal? (car segs) "api") (equal? (cadr segs) "runs") (caddr segs)))
(define (flow-run-cancel-path segs)
  (and (= (length segs) 4) (equal? (list-ref segs 0) "api") (equal? (list-ref segs 1) "runs")
       (equal? (list-ref segs 3) "cancel") (list-ref segs 2)))
(define (org-id-path segs)
  (and (= (length segs) 3) (equal? (car segs) "api") (equal? (cadr segs) "orgs") (caddr segs)))
(define (org-action-path segs action)
  (and (= (length segs) 4) (equal? (list-ref segs 0) "api") (equal? (list-ref segs 1) "orgs")
       (equal? (list-ref segs 3) action) (list-ref segs 2)))

(define (beta-asset-id segs)
  (and (= (length segs) 4) (equal? (list-ref segs 0) "api") (equal? (list-ref segs 1) "beta")
       (equal? (list-ref segs 2) "asset") (list-ref segs 3)))

(define (route req)
  ;; HEAD must reach every GET route: monitors, link unfurlers and health
  ;; checkers probe with HEAD, and before 2026-09-04 every one of them got a
  ;; JSON 404 from a perfectly healthy server (hit live on beta.rcn-t.com:
  ;; HEAD / returned 404 while GET / returned the app). web-server's response
  ;; layer already suppresses response bodies for HEAD requests
  ;; (web-server/http/response), so matching HEAD as GET is sufficient and no
  ;; route can accidentally emit a body.
  (define m (let ([rm (request-method req)])
              (if (bytes=? rm #"HEAD") #"GET" rm)))
  (define segs (request-path req))
  (cond
    ;; "login" is a real route so the console has a URL that does not depend on the beta
    ;; landing rendering at all — a themeable page must not be the only way in.
    [(and (GET? m)  (or (null? segs) (equal? segs '("")) (equal? segs '("index.html"))
                        (equal? segs '("activate")) (equal? segs '("login"))))
     (html-response (ui-html-branded))]
    [(and (GET? m)  (equal? segs '("health")))              (ep-health)]
    [(and (GET? m)  (equal? segs '("beta-sdk.js")))         (serve-file (build-path impl-root "static" "beta-sdk.js"))]
    [(and (GET? m)  (bundle-file-path segs))                (serve-file (bundle-file-path segs))]
    [(and (GET? m)  (equal? segs '("api" "config")))       (ep-config req)]
    [(and (GET? m)  (equal? segs '("api" "branding")))     (ep-branding-get req)]
    [(and (PUT? m)  (equal? segs '("api" "branding")))     (ep-branding-put req)]
    [(and (POST? m) (equal? segs '("api" "branding" "logo"))) (ep-branding-logo req)]
    [(and (GET? m)  (equal? segs '("api" "i18n" "catalog"))) (ep-i18n-catalog req)]
    [(and (PUT? m)  (equal? segs '("api" "i18n")))         (ep-i18n-put req)]
    [(and (GET? m)  (equal? segs '("api" "l10n" "coverage")))  (ep-l10n-coverage req)]
    [(and (GET? m)  (equal? segs '("api" "l10n" "messages")))  (ep-l10n-messages req)]
    [(and (POST? m) (equal? segs '("api" "l10n" "import")))    (ep-l10n-import req)]
    [(and (POST? m) (equal? segs '("api" "l10n" "export")))    (ep-l10n-export req)]
    [(and (POST? m) (equal? segs '("api" "l10n" "draft")))     (ep-l10n-draft req)]
    [(and (POST? m) (equal? segs '("api" "l10n" "discard")))   (ep-l10n-discard req)]
    [(and (PUT? m)  (l10n-message-path segs))                  (ep-l10n-submit req (l10n-message-path segs))]
    [(and (POST? m) (l10n-review-path segs))                   (ep-l10n-review req (l10n-review-path segs))]
    [(and (GET? m)  (equal? segs '("api" "beta" "config"))) (ep-beta-config req)]
    [(and (GET? m)  (equal? segs '("beta" "template")))     (ep-beta-template req)]
    [(and (OPTIONS? m) (member segs '(("api" "beta" "signup") ("api" "beta" "config") ("api" "beta" "challenge")))) (cors-preflight)]
    [(and (GET? m)  (equal? segs '("api" "beta" "experience"))) (ep-beta-experience-get req)]
    [(and (PUT? m)  (equal? segs '("api" "beta" "experience"))) (ep-beta-experience-put req)]
    [(and (POST? m) (equal? segs '("api" "beta" "experience" "publish"))) (ep-beta-experience-publish req)]
    [(and (POST? m)   (equal? segs '("api" "beta" "assets")))  (ep-beta-asset-upload req)]
    [(and (GET? m)    (equal? segs '("api" "beta" "assets")))  (ep-beta-assets req)]
    [(and (GET? m)    (beta-asset-id segs))                    (ep-beta-asset req (beta-asset-id segs))]
    [(and (DELETE? m) (beta-asset-id segs))                    (ep-beta-asset-delete req (beta-asset-id segs))]
    [(and (GET? m)  (equal? segs '("api" "beta" "challenge"))) (ep-beta-challenge req)]
    [(and (POST? m) (equal? segs '("api" "beta" "signup"))) (ep-beta-signup req)]
    [(and (GET? m)  (equal? segs '("api" "beta" "prospects"))) (ep-beta-prospects req)]
    [(and (POST? m) (beta-decide-path segs))               (ep-beta-decide req (beta-decide-path segs))]
    [(and (POST? m) (equal? segs '("api" "bootstrap")))     (ep-bootstrap req)]
    [(and (POST? m) (equal? segs '("api" "provision")))     (ep-provision req)]
    [(and (POST? m) (equal? segs '("api" "activate")))      (ep-activate req)]
    [(and (POST? m) (equal? segs '("api" "instance" "suspend"))) (ep-tenant req suspend!)]
    [(and (POST? m) (equal? segs '("api" "instance" "resume")))  (ep-tenant req resume!)]
    [(and (POST? m) (equal? segs '("api" "instance" "quota")))   (ep-instance-quota req)]
    [(and (POST? m) (equal? segs '("api" "login")))         (ep-login req)]
    [(and (POST? m) (equal? segs '("api" "2fa" "enable")))  (ep-2fa-enable req)]
    [(and (POST? m) (equal? segs '("api" "password")))      (ep-password req)]
    [(and (GET? m)  (equal? segs '("api" "whoami")))        (ep-whoami req)]
    [(and (POST? m) (equal? segs '("api" "profile")))       (ep-profile req)]
    [(and (POST? m) (equal? segs '("api" "members")))       (ep-add-member req)]
    [(and (GET? m)  (equal? segs '("api" "members")))       (ep-members-list req)]
    [(and (GET? m)  (equal? segs '("api" "admin" "status"))) (ep-admin-status req)]
    ;; multi-tenancy — superadmin plane (instance:manage) then org-admin plane (org:*)
    [(and (POST? m) (equal? segs '("api" "orgs")))          (ep-orgs-create req)]
    [(and (GET? m)  (equal? segs '("api" "orgs")))          (ep-orgs-list req)]
    [(and (POST? m) (org-action-path segs "suspend"))       (ep-org-status req (org-action-path segs "suspend") "suspended")]
    [(and (POST? m) (org-action-path segs "resume"))        (ep-org-status req (org-action-path segs "resume") "active")]
    [(and (POST? m) (org-action-path segs "quota"))         (ep-org-quota req (org-action-path segs "quota"))]
    [(and (GET? m)  (org-id-path segs))                     (ep-org-get req (org-id-path segs))]
    [(and (PATCH? m) (org-id-path segs))                    (ep-org-update req (org-id-path segs))]
    [(and (POST? m) (equal? segs '("api" "admin" "seed-tenants"))) (ep-seed-tenants req)]
    [(and (GET? m)  (equal? segs '("api" "org")))           (ep-my-org req)]
    [(and (GET? m)  (equal? segs '("api" "org" "teams")))   (ep-my-org-teams req)]
    [(and (POST? m) (equal? segs '("api" "org" "teams")))   (ep-my-org-team-create req)]
    [(and (POST? m) (equal? segs '("api" "org" "members"))) (ep-my-org-member-add req)]
    [(and (GET? m)  (equal? segs '("api" "org" "audit")))   (ep-my-org-audit req)]
    [(and (POST? m) (equal? segs '("api" "notes")))        (ep-notes-create req)]
    [(and (GET? m)  (equal? segs '("api" "notes")))        (ep-notes-list req)]
    [(and (POST? m) (equal? segs '("api" "documents")))    (ep-documents-create req)]
    [(and (GET? m)  (equal? segs '("api" "documents")))    (ep-documents-list req)]
    [(and (GET? m)    (doc-id segs))                       (ep-documents-get req (doc-id segs))]
    [(and (PUT? m)    (doc-id segs))                       (ep-documents-update req (doc-id segs))]
    [(and (DELETE? m) (doc-id segs))                       (ep-documents-delete req (doc-id segs))]
    [(and (POST? m) (share-id segs))                       (ep-notes-share req (share-id segs))]
    [(and (GET? m)    (note-id segs))                      (ep-notes-get req (note-id segs))]
    [(and (PUT? m)    (note-id segs))                      (ep-notes-update req (note-id segs))]
    [(and (DELETE? m) (note-id segs))                      (ep-notes-delete req (note-id segs))]
    [(and (POST? m) (equal? segs '("api" "ai" "echo")))    (ep-ai-echo req)]
    [(and (POST? m) (equal? segs '("api" "ai" "chat")))    (ep-ai-chat req)]
    [(and (POST? m) (equal? segs '("api" "ai" "chat" "stream"))) (ep-ai-chat-stream req)]
    [(and (POST? m) (equal? segs '("api" "agent")))        (ep-agent req)]
    [(and (POST? m) (equal? segs '("api" "translate" "catalog"))) (ep-translate-catalog req)]
    [(and (POST? m) (equal? segs '("api" "translate")))    (ep-translate req)]
    [(and (GET? m)  (equal? segs '("api" "translate")))    (ep-translate-list req)]
    [(and (POST? m) (equal? segs '("api" "glossary")))     (ep-glossary-add req)]
    [(and (GET? m)  (equal? segs '("api" "glossary")))     (ep-glossary-list req)]
    [(and (GET? m)  (equal? segs '("api" "ai" "model")))   (ep-ai-model req)]
    [(and (GET? m)  (equal? segs '("api" "executors")))    (ep-executors req)]
    [(and (GET? m)  (equal? segs '("api" "usage")))        (ep-usage req)]
    [(and (POST? m) (equal? segs '("api" "quota")))        (ep-quota-set req)]
    [(and (GET? m)  (equal? segs '("api" "tools")))        (ep-tools-list req)]
    [(and (POST? m)   (equal? segs '("api" "tokens")))     (ep-tokens-create req)]
    [(and (GET? m)    (equal? segs '("api" "tokens")))     (ep-tokens-list req)]
    [(and (DELETE? m) (token-path segs))                   (ep-tokens-revoke req (token-path segs))]
    [(and (GET? m)  (equal? segs '("api" "search")))       (ep-search req)]
    [(and (GET? m)  (equal? segs '("api" "audit")))        (ep-audit req)]
    [(and (POST? m) (equal? segs '("api" "jobs")))         (ep-jobs-create req)]
    [(and (GET? m)  (equal? segs '("api" "jobs")))         (ep-jobs-list req)]
    [(and (POST? m) (job-cancel-path segs))                (ep-job-cancel req (job-cancel-path segs))]
    [(and (GET? m)  (job-id segs))                         (ep-job-get req (job-id segs))]
    ;; document repository (slices 49-50). More specific routes first: the bare
    ;; /api/repo listing, then object actions by id, then the catch-all key path.
    [(and (GET? m)  (equal? segs '("api" "repo")))          (ep-repo-list req)]
    [(and (POST? m) (repo-obj-action segs "share"))         (ep-repo-share req (repo-obj-action segs "share"))]
    [(and (POST? m) (repo-obj-action segs "unshare"))       (ep-repo-unshare req (repo-obj-action segs "unshare"))]
    [(and (GET? m)  (repo-obj-action segs "grants"))        (ep-repo-grants req (repo-obj-action segs "grants"))]
    [(and (POST? m) (repo-obj-action segs "visibility"))    (ep-repo-visibility req (repo-obj-action segs "visibility"))]
    [(and (GET? m)  (repo-obj-action segs "content"))       (ep-repo-get req (repo-obj-action segs "content"))]
    [(and (POST? m) (repo-obj-action segs "presign"))       (ep-repo-presign req (repo-obj-action segs "presign"))]
    [(and (GET? m)  (repo-obj-path segs))                   (ep-repo-meta req (repo-obj-path segs))]
    [(and (DELETE? m) (repo-obj-path segs))                 (ep-repo-delete req (repo-obj-path segs))]
    [(and (PUT? m)  (repo-key-path segs))                   (ep-repo-put req (repo-key-path segs))]
    ;; S3 access keys — managed here, used on the S3 port
    [(and (GET? m)  (equal? segs '("api" "s3" "credentials")))  (ep-s3-creds req)]
    [(and (POST? m) (equal? segs '("api" "s3" "credentials")))  (ep-s3-cred-create req)]
    [(and (DELETE? m) (= (length segs) 4) (equal? (car segs) "api")
          (equal? (cadr segs) "s3") (equal? (caddr segs) "credentials"))
     (ep-s3-cred-revoke req (list-ref segs 3))]
    ;; workflows (slice 46) — /schema is matched before /<slug> on purpose
    [(and (POST? m) (equal? segs '("api" "workflows")))     (ep-workflows-create req)]
    [(and (GET? m)  (equal? segs '("api" "workflows")))     (ep-workflows-list req)]
    [(and (GET? m)  (equal? segs '("api" "workflows" "schema"))) (ep-workflow-schema req)]
    [(and (POST? m) (workflow-run-path segs))               (ep-workflow-run req (workflow-run-path segs))]
    [(and (GET? m)  (workflow-slug segs))                   (ep-workflow-get req (workflow-slug segs))]
    [(and (GET? m)  (equal? segs '("api" "runs")))          (ep-runs-list req)]
    [(and (POST? m) (flow-run-cancel-path segs))            (ep-run-cancel req (flow-run-cancel-path segs))]
    [(and (GET? m)  (flow-run-id-path segs))                (ep-run-get req (flow-run-id-path segs))]
    [(and (POST? m) (equal? segs '("api" "admin" "seed")))  (ep-admin-seed req)]
    [(and (GET? m)  (equal? segs '("api" "metrics")))      (ep-metrics req)]
    [(and (GET? m)  (equal? segs '("api" "features")))     (ep-features req)]
    [(and (POST? m) (feature-path segs))                   (ep-feature-toggle req (feature-path segs))]
    [(and (GET? m)  (equal? segs '("api" "plugins")))      (ep-plugins req)]
    [(and (GET? m)  (equal? segs '("api" "mcp")))          (ep-mcp req)]
    [(and (GET? m)  (equal? segs '("api" "oop")))          (ep-oop req)]
    [(and (POST? m) (tool-path segs))                      (ep-tool-toggle req (tool-path segs))]
    [else (err "not found" 404)]))

(define (handle req)
  (parameterize ([current-localizer (localizer-for (request-locale req))])
    (with-handlers ([exn:fail:forbidden?
                     (lambda (e) (err (msg-forbidden (exn:fail:forbidden-permission e)) 403))]
                    ;; a refused workflow spec is the caller's mistake — and the
                    ;; detail is the whole point of rejecting rather than ignoring
                    [exn:fail:spec? (lambda (e) (err (exn-message e) 400))]
                    [exn:fail? (lambda (e) (err (exn-message e) 500))])
      (route req))))

(module+ main
  (init-db!)
  ;; hosted VM launch: self-seed the owner from env on first boot, emit the
  ;; activation token to stdout (the provisioning sink) for the control plane.
  (when (and (saas-mode?) (env* "TELEMACHUS_SEED_OWNER_EMAIL")
             (not (query-maybe-value db-conn "SELECT id FROM users LIMIT 1")))
    (define-values (tok uid tid _st)
      (provision! db-conn #:provision-id (or (env* "TELEMACHUS_SEED_PROVISION_ID") "seed")
                  #:owner-email (env* "TELEMACHUS_SEED_OWNER_EMAIL")
                  #:owner-name (env* "TELEMACHUS_SEED_OWNER_NAME")
                  #:org (env* "TELEMACHUS_SEED_ORG")
                  #:plan (or (env* "TELEMACHUS_SEED_PLAN") "trial") #:source "vm"))
    (printf "seed: provisioned ~a — activation token: ~a\n" (env* "TELEMACHUS_SEED_OWNER_EMAIL") tok)
    (flush-output))
  (define plugins-dir (let ([e (env* "TELEMACHUS_PLUGINS")]) (if e (string->path e) (build-path impl-root "plugins"))))
  (define plugins (load-plugins! plugins-dir #:log (lambda (s) (printf "  plugin: ~a\n" s))))
  ;; Refuse to serve with a RELATIVE blob root. `serve/servlet` repoints
  ;; `current-directory` at the web server's own web root while it handles a
  ;; request, so a relative root aims writes at whatever that is — for a Nix
  ;; install, the read-only store. That surfaced as a 500 on the first document
  ;; save, with a mkdir EACCES deep inside /nix/store, long after a boot that
  ;; looked completely healthy. Fail here instead, where the message is about the
  ;; configuration and not about a mkdir. Plugins load first because rs3 replaces
  ;; the built-in store and this must check the one that will actually be used.
  (let ([r (blob-root)])
    (unless (absolute-path? r)
      (error 'telemachus
             (string-append "blob store root is relative (~a).\n"
                            "  It would be resolved against the web server's working directory at write\n"
                            "  time, not against the install. Set TELEMACHUS_DATA_DIR (or\n"
                            "  TELEMACHUS_RS3_ROOT) to an absolute path.")
             r)))
  (when (pair? plugins) (printf "loaded ~a plugin(s) from ~a\n" (length plugins) plugins-dir))
  (define mcp-config (let ([e (env* "TELEMACHUS_MCP")]) (if e (string->path e) (build-path impl-root "mcp.json"))))
  (define mcps (connect-mcp-servers! mcp-config #:log (lambda (s) (printf "  mcp: ~a\n" s))))
  (when (pair? mcps) (printf "connected ~a MCP server(s)\n" (length mcps)))
  (define oop-config (let ([e (env* "TELEMACHUS_OOP")]) (if e (string->path e) (build-path impl-root "oop.json"))))
  (define oops (connect-oop-plugins! oop-config #:log (lambda (s) (printf "  oop: ~a\n" s))))
  (when (pair? oops) (printf "connected ~a sandboxed plugin(s)\n" (length oops)))
  (define exec-config (let ([e (env* "TELEMACHUS_EXECUTORS")]) (if e (string->path e) (build-path impl-root "executors.json"))))
  (define fx (connect-executors! exec-config #:log (lambda (s) (printf "  executor: ~a\n" s))))
  (when (pair? fx) (printf "registered ~a federated executor(s)\n" (length fx)))
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
      (run-agent-flow conn p prompt (lambda (ev) (set-box! evs (cons ev (unbox evs)))))
      (define events (reverse (unbox evs)))
      (define done (for/or ([e (in-list events)]) (and (equal? (hash-ref e 'type #f) "done") e)))
      (define tools (for/list ([e (in-list events)] #:when (equal? (hash-ref e 'type #f) "tool")) (hash-ref e 'name "")))
      (define reply (if done (hash-ref done 'reply "") ""))
      (hasheq 'reply reply 'rounds (if done (hash-ref done 'rounds 0) 0)
              'tools tools 'tokens_used (estimate-tokens prompt reply))))
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
          (define-values (reply tokens) (run-chat prompt))
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
         (define verdict
           (or (parse-verdict reply)
               (hasheq 'valid #f 'score 0 'revenue_estimate "unknown" 'reasoning "judge output not parseable")))
         (set-prospect-judge! conn pid verdict)
         (hasheq 'prospect_id pid 'verdict verdict 'tokens_used tokens)])))
  (void (start-scheduler! db-conn #:workers 2
                          #:cap-for (lambda (team)
                                      (define-values (lim _w) (get-limit db-conn "team" team "ai.concurrency"))
                                      (or lim 2))         ; per-team fairness: cap = the team's ai.concurrency
                          #:admit? (lambda (conn team)    ; over-budget teams defer, not bypass
                                     (define org (team-org conn team))
                                     (and (hash-ref (quota-check conn "team" team "ai.requests" 1) 'allowed)
                                          (hash-ref (quota-check conn "team" team "ai.tokens.total" 1) 'allowed)
                                          ;; ...and the COMPANY it belongs to must also be under its cap
                                          (or (not org)
                                              (and (hash-ref (quota-check conn "org" org "ai.requests" 1) 'allowed)
                                                   (hash-ref (quota-check conn "org" org "ai.tokens.total" 1) 'allowed)))))
                          #:record! (lambda (conn team result)   ; bill the run at both tiers
                                      (define toks (let ([t (and (hash? result) (hash-ref result 'tokens_used #f))])
                                                     (if (number? t) t 0)))
                                      (define org (team-org conn team))
                                      (quota-record! conn "team" team "ai.requests" 1)
                                      (quota-record! conn "team" team "ai.tokens.total" toks)
                                      (when org
                                        (quota-record! conn "org" org "ai.requests" 1)
                                        (quota-record! conn "org" org "ai.tokens.total" toks)))))
  (printf "scheduler: 2 worker(s), per-team cap = ai.concurrency, quota-metered\n")
  (define tls? (tls-on?))
  (define ip (bind-ip))
  (define port (listen-port))
  (when tls? (ensure-cert!))
  (printf "telemachus server on ~a://~a:~a  (db: ~a · kdf: ~a · tls: ~a · max upload: ~a MiB)\n"
          (if tls? "https" "http") ip port db-url (kdf-name) (if tls? "on" "off")
          (quotient (max-upload-bytes) (* 1024 1024)))
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
  (if tls?
      (serve handle #:port port #:listen-ip ip #:max-body-length (max-upload-bytes)
             #:ssl-cert (tls-cert) #:ssl-key (tls-key))
      (serve handle #:port port #:listen-ip ip #:max-body-length (max-upload-bytes))))
