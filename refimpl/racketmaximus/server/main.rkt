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
         "../domain/quota/quota.rkt"
         "../domain/sched/governor.rkt"
         "../domain/ai/executor.rkt"
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
    [(not username) (err "username required" 400)]
    [(query-maybe-value db-conn "SELECT id FROM users LIMIT 1") (err (msg-already-init) 409)]
    [else
     (define-values (uid tid) (bootstrap! db-conn #:username username #:password (hash-ref body 'password #f)))
     (default-policy! db-conn tid)                       ; starter AI quota for the team
     (define-values (tok _t) (issue-token! db-conn #:user uid #:team tid #:name "bootstrap" #:scopes '("*:*")))
     (json-response (hasheq 'user_id uid 'team_id tid 'token tok
                            'message (msg-bootstrap-done username "Default"))
                    #:code 201)]))

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

(define (ep-2fa-enable req)
  (define p (current-principal req))
  (cond
    [(not p) (unauthorized)]
    [else
     (define-values (secret uri) (enable-2fa! db-conn (principal-user-id p)))
     (json-response (hasheq 'secret secret 'otpauth_uri uri
                            'note "2FA enabled — future logins for this user require a TOTP code"))]))

;; ---- notes (ownable/shareable resource) -------------------------------------
(define (with-auth req proc)
  (define p (current-principal req))
  (if (not p) (unauthorized) (proc p)))

(define (ep-notes-create req)
  (with-auth req (lambda (p)
    (define b (read-json-body req))
    (json-response (notes-create db-conn p #:title (hash-ref b 'title "")
                                 #:body (hash-ref b 'body "") #:visibility (hash-ref b 'visibility "team"))
                   #:code 201))))

(define (ep-notes-list req)
  (with-auth req (lambda (p) (json-response (hasheq 'notes (notes-list db-conn p))))))

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

;; real model call (falls back to simulated when no model is configured)
(define (ep-ai-chat req)
  (with-auth req (lambda (p)
    (require-perm db-conn p "chat:use")
    (define b (read-json-body req))
    (define prompt (hash-ref b 'prompt ""))
    (define est (estimate-tokens prompt))
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
           (define-values (reply tokens) (run-chat prompt))          ; real model or fallback
           (quota-record! db-conn "team" sid "ai.requests" 1)
           (quota-record! db-conn "team" sid "ai.tokens.total" tokens)
           (define after (quota-check db-conn "team" sid "ai.tokens.total" 0))
           (json-response (hasheq 'reply reply 'tokens_used tokens
                                  'model (hash-ref (model-info) 'model)
                                  'concurrent inflight
                                  'remaining_tokens (hash-ref after 'remaining)))))]))))

(define (ep-ai-model req)
  (with-auth req (lambda (p) (json-response (model-info)))))

;; streaming chat: same admission path, tokens streamed as SSE, metered at end.
(define (ep-ai-chat-stream req)
  (with-auth req (lambda (p)
    (require-perm db-conn p "chat:use")
    (define b (read-json-body req))
    (define prompt (hash-ref b 'prompt ""))
    (define est (estimate-tokens prompt))
    (define sid (principal-team-id p))
    (define rq (quota-check db-conn "team" sid "ai.requests" 1))
    (define tq (quota-check db-conn "team" sid "ai.tokens.total" est))
    (cond
      [(not (hash-ref rq 'allowed)) (quota-429 rq "ai.requests")]
      [(not (hash-ref tq 'allowed)) (quota-429 tq "ai.tokens.total")]
      [else
       (define-values (climit _w) (get-limit db-conn "team" sid "ai.concurrency"))
       (sse-response
        (lambda (emit)
          (with-slot GOV (string-append "team:" sid) (or climit 2)
            (lambda (inflight)
              (define tokens (run-chat-stream prompt (lambda (tok) (emit (hasheq 'token tok)))))
              (quota-record! db-conn "team" sid "ai.requests" 1)
              (quota-record! db-conn "team" sid "ai.tokens.total" tokens)
              (define after (quota-check db-conn "team" sid "ai.tokens.total" 0))
              (emit (hasheq 'done #t 'tokens_used tokens
                            'model (hash-ref (model-info) 'model)
                            'remaining_tokens (hash-ref after 'remaining)))))))]))))

(define (ep-usage req)
  (with-auth req (lambda (p)
    (define sid (principal-team-id p))
    (json-response
     (hasheq 'team_id sid
             'quota (for/list ([dim (in-list '("ai.tokens.total" "ai.requests" "ai.concurrency"))])
                      (define d (quota-check db-conn "team" sid dim 0))
                      (hasheq 'dimension dim 'used (hash-ref d 'used)
                              'limit (hash-ref d 'limit) 'remaining (hash-ref d 'remaining))))))))

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
(define (share-id segs)
  (and (= (length segs) 4) (equal? (list-ref segs 0) "api") (equal? (list-ref segs 1) "notes")
       (equal? (list-ref segs 3) "share") (list-ref segs 2)))

(define (route req)
  (define m (request-method req))
  (define segs (request-path req))
  (cond
    [(and (GET? m)  (or (null? segs) (equal? segs '("")) (equal? segs '("index.html"))))
     (html-response UI-HTML)]
    [(and (GET? m)  (equal? segs '("health")))              (ep-health)]
    [(and (POST? m) (equal? segs '("api" "bootstrap")))     (ep-bootstrap req)]
    [(and (POST? m) (equal? segs '("api" "login")))         (ep-login req)]
    [(and (POST? m) (equal? segs '("api" "2fa" "enable")))  (ep-2fa-enable req)]
    [(and (GET? m)  (equal? segs '("api" "whoami")))        (ep-whoami req)]
    [(and (POST? m) (equal? segs '("api" "members")))       (ep-add-member req)]
    [(and (GET? m)  (equal? segs '("api" "members")))       (ep-members-list req)]
    [(and (GET? m)  (equal? segs '("api" "admin" "status"))) (ep-admin-status req)]
    [(and (POST? m) (equal? segs '("api" "notes")))        (ep-notes-create req)]
    [(and (GET? m)  (equal? segs '("api" "notes")))        (ep-notes-list req)]
    [(and (POST? m) (share-id segs))                       (ep-notes-share req (share-id segs))]
    [(and (GET? m)    (note-id segs))                      (ep-notes-get req (note-id segs))]
    [(and (PUT? m)    (note-id segs))                      (ep-notes-update req (note-id segs))]
    [(and (DELETE? m) (note-id segs))                      (ep-notes-delete req (note-id segs))]
    [(and (POST? m) (equal? segs '("api" "ai" "echo")))    (ep-ai-echo req)]
    [(and (POST? m) (equal? segs '("api" "ai" "chat")))    (ep-ai-chat req)]
    [(and (POST? m) (equal? segs '("api" "ai" "chat" "stream"))) (ep-ai-chat-stream req)]
    [(and (GET? m)  (equal? segs '("api" "ai" "model")))   (ep-ai-model req)]
    [(and (GET? m)  (equal? segs '("api" "usage")))        (ep-usage req)]
    [(and (POST? m) (equal? segs '("api" "quota")))        (ep-quota-set req)]
    [else (err "not found" 404)]))

(define (handle req)
  (parameterize ([current-localizer (localizer-for (accept-language req))])
    (with-handlers ([exn:fail:forbidden?
                     (lambda (e) (err (msg-forbidden (exn:fail:forbidden-permission e)) 403))]
                    [exn:fail? (lambda (e) (err (exn-message e) 500))])
      (route req))))

(module+ main
  (init-db!)
  (define tls? (tls-on?))
  (when tls? (ensure-cert!))
  (printf "telemachus server on ~a://127.0.0.1:8080  (db: ~a · kdf: ~a · tls: ~a)\n"
          (if tls? "https" "http") db-path (kdf-name) (if tls? "on" "off"))
  (flush-output)
  (if tls?
      (serve handle #:port 8080 #:ssl-cert (tls-cert) #:ssl-key (tls-key))
      (serve handle #:port 8080)))
