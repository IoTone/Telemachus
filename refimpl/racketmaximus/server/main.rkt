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
         db
         web-server/http
         json
         web-kit
         db-kit
         "../config.rkt"
         "../domain/db/migrations.rkt"
         "../domain/authz/authz.rkt"
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

;; ---- request helpers --------------------------------------------------------
(define (req-header req name-bytes)
  (define h (headers-assq* name-bytes (request-headers/raw req)))   ; case-insensitive
  (and h (bytes->string/utf-8 (header-value h))))

(define (accept-language req)
  (define h (req-header req #"accept-language"))
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

;; ---- endpoints --------------------------------------------------------------
(define (ep-health)
  (json-response (hasheq 'ok #t 'service "telemachus" 'version app-version)))

(define (ep-bootstrap req)
  (define body (read-json-body req))
  (define username (hash-ref body 'username #f))
  (cond
    [(not username) (err "username required" 400)]
    [(query-maybe-value db-conn "SELECT id FROM users LIMIT 1") (err (msg-already-init) 409)]
    [else
     (define-values (uid tid) (bootstrap! db-conn #:username username #:password (hash-ref body 'password #f)))
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

;; ---- routing ----------------------------------------------------------------
(define (GET? m) (bytes=? m #"GET"))
(define (POST? m) (bytes=? m #"POST"))

(define (route req)
  (define m (request-method req))
  (define segs (request-path req))
  (cond
    [(and (GET? m)  (equal? segs '("health")))              (ep-health)]
    [(and (POST? m) (equal? segs '("api" "bootstrap")))     (ep-bootstrap req)]
    [(and (POST? m) (equal? segs '("api" "login")))         (ep-login req)]
    [(and (POST? m) (equal? segs '("api" "2fa" "enable")))  (ep-2fa-enable req)]
    [(and (GET? m)  (equal? segs '("api" "whoami")))        (ep-whoami req)]
    [(and (POST? m) (equal? segs '("api" "members")))       (ep-add-member req)]
    [(and (GET? m)  (equal? segs '("api" "admin" "status"))) (ep-admin-status req)]
    [else (err "not found" 404)]))

(define (handle req)
  (parameterize ([current-localizer (localizer-for (accept-language req))])
    (with-handlers ([exn:fail:forbidden?
                     (lambda (e) (err (msg-forbidden (exn:fail:forbidden-permission e)) 403))]
                    [exn:fail? (lambda (e) (err (exn-message e) 500))])
      (route req))))

(module+ main
  (init-db!)
  (printf "telemachus server on http://127.0.0.1:8080  (db: ~a)\n" db-path)
  (flush-output)
  (serve handle #:port 8080))
