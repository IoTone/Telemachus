#lang racket/base

;; server/main.rkt — the HTTP surface (slice 3). Wires web-kit + AuthzService +
;; the Localizer:
;;   • identity from `Authorization: Bearer <token>` (issuer-perms ∩ scopes) or a
;;     trusted `X-Telemachus-User` + `X-Telemachus-Team` (dev / trusted proxy);
;;   • per-request locale from `Accept-Language` → responses (incl. 401/403) are
;;     localized;
;;   • RBAC enforced with `require-perm` (raises → localized 403).
;;
;;   racket server/main.rkt            # serves on http://127.0.0.1:8080
;;
;; Endpoints:
;;   GET  /health
;;   POST /api/bootstrap   {username}                 → operator + token (first run)
;;   GET  /api/whoami                                 → principal + permissions
;;   POST /api/members     {username, role}           → add member (members:manage)
;;   GET  /api/admin/status                           → operator only (instance:manage)

(require racket/string
         racket/file
         racket/system
         racket/port
         db
         web-server/http
         json
         web-kit
         db-kit
         "../config.rkt"
         "../domain/db/migrations.rkt"
         "../domain/authz/authz.rkt"
         "../domain/authz/passwords.rkt"          ; kdf-name
         "../domain/notes/notes.rkt"
         "../domain/documents/documents.rkt"      ; documents (paginated ownable resource)
         "../domain/apps/translate.rkt"           ; Translation app
         "../domain/apps/search.rkt"              ; search across notes + translations
         "../domain/features/features.rkt"        ; per-team feature activation
         (only-in net/url url-query)
         "../domain/saas/onboarding.rkt"          ; hosted provisioning: provision!/activate!/suspend!/resume!
         "../domain/quota/quota.rkt"
         "../domain/sched/governor.rkt"
         "../domain/sched/scheduler.rkt"          ; async job queue + worker pool
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
(define db-path (sqlite-path (database-url) #:base-dir impl-root))
(define db-pool (connection-pool (lambda () (sqlite3-connect #:database db-path #:mode 'create))))
(define db-conn (virtual-connection db-pool))

(define (init-db!)
  (define dir (let-values ([(base name dir?) (split-path db-path)]) base))
  (when (path? dir) (make-directory* dir))
  (migrate! db-conn all-migrations))

;; ---- TLS --------------------------------------------------------------------
(define (env* k) (let ([v (getenv k)]) (and v (not (string=? v "")) v)))
(define (saas-mode?) (equal? (env* "TELEMACHUS_MODE") "saas"))   ; hosted: bootstrap off, provisioning on
(define (bind-ip) (or (env* "TELEMACHUS_BIND") "127.0.0.1"))   ; set to a tailnet IP to share privately
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
  (if (not h) "en"
      (let ([tag (string-trim (car (string-split (car (string-split h ",")) ";")))])
        (if (string=? tag "") "en" tag))))

(define (query-param req name [default ""])
  (cond [(assq name (url-query (request-uri req))) => (lambda (kv) (or (cdr kv) default))]
        [else default]))

(define (read-json-body req)
  (define raw (request-post-data/raw req))
  (if (and raw (> (bytes-length raw) 0))
      (with-handlers ([exn:fail? (lambda (_) (hasheq))]) (bytes->jsexpr raw))
      (hasheq)))

(define (localizer-for locale)
  (with-handlers ([exn:fail? (lambda (_) empty-localizer)])
    (load-localizer (build-path impl-root "locales") #:locale locale)))

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

;; the single-page UI (read once at startup)
(define UI-HTML
  (let ([p (build-path impl-root "static" "index.html")])
    (if (file-exists? p) (file->string p) "<!doctype html><h1>Telemachus</h1>")))
(define (html-response s)
  (response/output #:mime-type #"text/html; charset=utf-8"
                   (lambda (out) (write-string s out))))

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
                         'tls (tls-on?) 'kdf (kdf-name))))

(define (ep-bootstrap req)
  (define body (read-json-body req))
  (define username (hash-ref body 'username #f))
  (cond
    [(saas-mode?) (err "interactive bootstrap is disabled in hosted mode" 403)]
    [(not username) (err "username required" 400)]
    [(query-maybe-value db-conn "SELECT id FROM users LIMIT 1") (err (msg-already-init) 409)]
    [else
     (define-values (uid tid) (bootstrap! db-conn #:username username #:password (hash-ref body 'password #f)))
     (default-policy! db-conn tid)                       ; starter AI quota for the team
     (define-values (tok _t) (issue-token! db-conn #:user uid #:team tid #:name "bootstrap" #:scopes '("*:*")))
     (json-response (hasheq 'user_id uid 'team_id tid 'token tok
                            'message (msg-bootstrap-done username "Default"))
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

(define (ep-whoami req)
  (define p (current-principal req))
  (if (not p) (unauthorized)
      (json-response (hasheq 'user_id (principal-user-id p)
                             'team_id (principal-team-id p)
                             'is_operator (principal-is-operator p)
                             'permissions (perms-of p)
                             'token_scopes (or (principal-token-scopes p) 'null)))))

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
                            'users (query-value db-conn "SELECT COUNT(*) FROM users")
                            'teams (query-value db-conn "SELECT COUNT(*) FROM teams")))]))

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
    [(and (team-suspended? db-conn (principal-team-id p)) (not (GET? (request-method req))))
     (err "tenant suspended — writes are disabled; contact your administrator" 402)]   ; ONB-7: read-only
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
    (define rq (quota-check db-conn "team" sid "ai.requests" 1))
    (define tq (quota-check db-conn "team" sid "ai.tokens.total" est))
    (cond
      [(not (hash-ref rq 'allowed)) (quota-429 rq "ai.requests")]
      [(not (hash-ref tq 'allowed)) (quota-429 tq "ai.tokens.total")]
      [else
       (define-values (climit _w) (get-limit db-conn "team" sid "ai.concurrency"))
       (with-slot GOV (string-append "team:" sid) (or climit 2)
         (lambda (inflight)
           (sleep 0.12)                                             ; simulate model latency
           (quota-record! db-conn "team" sid "ai.requests" 1)
           (quota-record! db-conn "team" sid "ai.tokens.total" est)
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
    (define rq (quota-check db-conn "team" sid "ai.requests" 1))
    (define tq (quota-check db-conn "team" sid "ai.tokens.total" est))
    (cond
      [(and ex (not (executor-exists? ex))) (err "unknown executor" 400)]
      [(not (hash-ref rq 'allowed)) (quota-429 rq "ai.requests")]
      [(not (hash-ref tq 'allowed)) (quota-429 tq "ai.tokens.total")]
      [else
       (define-values (climit _w) (get-limit db-conn "team" sid "ai.concurrency"))
       (with-slot GOV (string-append "team:" sid) (or climit 2)
         (lambda (inflight)
           (define-values (reply tokens) (run-chat prompt #:executor ex))   ; local or federated
           (quota-record! db-conn "team" sid "ai.requests" 1)
           (quota-record! db-conn "team" sid "ai.tokens.total" tokens)
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
    (define rq (quota-check db-conn "team" sid "ai.requests" 1))
    (define tq (quota-check db-conn "team" sid "ai.tokens.total" est))
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
              (quota-record! db-conn "team" sid "ai.requests" 1)
              (quota-record! db-conn "team" sid "ai.tokens.total" tokens)
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
       (define rq (quota-check db-conn "team" sid "ai.requests" 1))
       (cond
         [(not (hash-ref rq 'allowed)) (quota-429 rq "ai.requests")]
         [else
          (define-values (climit _w) (get-limit db-conn "team" sid "ai.concurrency"))
          (sse-response
           (lambda (emit)
             (with-slot GOV (string-append "team:" sid) (or climit 2)
               (lambda (inflight)
                 (run-agent-flow db-conn p prompt (lambda (ev) (emit ev)))
                 (quota-record! db-conn "team" sid "ai.requests" 1)
                 (quota-record! db-conn "team" sid "ai.tokens.total" (max (estimate-tokens prompt) 50))))))])]))))

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
       (define rq (quota-check db-conn "team" sid "ai.requests" 1))
       (define tq (quota-check db-conn "team" sid "ai.tokens.total" est))
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
              (quota-record! db-conn "team" sid "ai.requests" 1)
              (quota-record! db-conn "team" sid "ai.tokens.total" tokens)
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
       (define tq (quota-check db-conn "team" sid "ai.tokens.total" (estimate-tokens (format "~a" cat))))
       (cond
         [(not (hash-ref tq 'allowed)) (quota-429 tq "ai.tokens.total")]
         [else
          (define-values (climit _w) (get-limit db-conn "team" sid "ai.concurrency"))
          (with-slot GOV (string-append "team:" sid) (or climit 2)
            (lambda (_inflight)
              (define-values (out tokens) (translate-catalog! db-conn p #:catalog cat #:target-lang tgt))
              (quota-record! db-conn "team" sid "ai.tokens.total" tokens)
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

(define (ep-metrics req)
  (with-auth req (lambda (p)
    (require-perm db-conn p "instance:manage")
    (define (n q) (query-value db-conn q))
    (json-response (hasheq
      'users (n "SELECT COUNT(*) FROM users")
      'teams (n "SELECT COUNT(*) FROM teams")
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
(define (share-id segs)
  (and (= (length segs) 4) (equal? (list-ref segs 0) "api") (equal? (list-ref segs 1) "notes")
       (equal? (list-ref segs 3) "share") (list-ref segs 2)))

(define (route req)
  (define m (request-method req))
  (define segs (request-path req))
  (cond
    [(and (GET? m)  (or (null? segs) (equal? segs '("")) (equal? segs '("index.html")) (equal? segs '("activate"))))
     (html-response UI-HTML)]
    [(and (GET? m)  (equal? segs '("health")))              (ep-health)]
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
    [(and (POST? m) (equal? segs '("api" "members")))       (ep-add-member req)]
    [(and (GET? m)  (equal? segs '("api" "members")))       (ep-members-list req)]
    [(and (GET? m)  (equal? segs '("api" "admin" "status"))) (ep-admin-status req)]
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
    [(and (GET? m)  (equal? segs '("api" "metrics")))      (ep-metrics req)]
    [(and (GET? m)  (equal? segs '("api" "features")))     (ep-features req)]
    [(and (POST? m) (feature-path segs))                   (ep-feature-toggle req (feature-path segs))]
    [(and (GET? m)  (equal? segs '("api" "plugins")))      (ep-plugins req)]
    [(and (GET? m)  (equal? segs '("api" "mcp")))          (ep-mcp req)]
    [(and (GET? m)  (equal? segs '("api" "oop")))          (ep-oop req)]
    [(and (POST? m) (tool-path segs))                      (ep-tool-toggle req (tool-path segs))]
    [else (err "not found" 404)]))

(define (handle req)
  (parameterize ([current-localizer (localizer-for (accept-language req))])
    (with-handlers ([exn:fail:forbidden?
                     (lambda (e) (err (msg-forbidden (exn:fail:forbidden-permission e)) 403))]
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
  (void (start-scheduler! db-conn #:workers 2
                          #:cap-for (lambda (team)
                                      (define-values (lim _w) (get-limit db-conn "team" team "ai.concurrency"))
                                      (or lim 2))         ; per-team fairness: cap = the team's ai.concurrency
                          #:admit? (lambda (conn team)    ; over-budget teams defer, not bypass
                                     (and (hash-ref (quota-check conn "team" team "ai.requests" 1) 'allowed)
                                          (hash-ref (quota-check conn "team" team "ai.tokens.total" 1) 'allowed)))
                          #:record! (lambda (conn team result)   ; bill the run
                                      (define toks (let ([t (and (hash? result) (hash-ref result 'tokens_used #f))])
                                                     (if (number? t) t 0)))
                                      (quota-record! conn "team" team "ai.requests" 1)
                                      (quota-record! conn "team" team "ai.tokens.total" toks))))
  (printf "scheduler: 2 worker(s), per-team cap = ai.concurrency, quota-metered\n")
  (define tls? (tls-on?))
  (define ip (bind-ip))
  (when tls? (ensure-cert!))
  (printf "telemachus server on ~a://~a:8080  (db: ~a · kdf: ~a · tls: ~a)\n"
          (if tls? "https" "http") ip db-path (kdf-name) (if tls? "on" "off"))
  (flush-output)
  (if tls?
      (serve handle #:port 8080 #:listen-ip ip #:ssl-cert (tls-cert) #:ssl-key (tls-key))
      (serve handle #:port 8080 #:listen-ip ip)))
