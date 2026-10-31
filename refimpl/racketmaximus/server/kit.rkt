#lang racket/base

;; #128 job 2: operator-facing variables are read through ONE accessor,
;; which tries TMACH_<name> and falls back to TELEMACHUS_<name>.
(require (only-in "../config.rkt" tmach-env))

;; server/kit.rkt — what every HTTP handler in this server needs (#110 r3).
;;
;; r3 splits main.rkt's 40-odd feature areas into `server/api/*.rkt`, and this is
;; the module that makes that possible: the pool, the request accessors, the
;; identity wrappers and the response constructors were all defined in main.rkt
;; and closed over by 456 handler bodies. Hoisting them FIRST is what lets a
;; handler move without being rewritten — a split that threaded `db-conn` through
;; every signature instead would be a behaviour-changing refactor dressed as a
;; mechanical one.
;;
;; `db-conn` lives here deliberately. It is the one piece of state the whole
;; surface shares, and a parameter or an argument would have to be plumbed
;; through every one of those call sites to say the same thing. The pool is lazy,
;; so requiring this module costs nothing until a query runs.

(provide (all-defined-out)
         ;; re-exported so every handler keeps reaching them through kit
         (all-from-out "errors.rkt"))

(require racket/string
         racket/file
         racket/system
         racket/port
         (only-in net/url url-query)
         db-kit
         db-kit/portable
         (only-in db-kit/migrate migrate!)
         web-server/http
         web-kit
         json
         "../config.rkt"
         "../domain/db/migrations.rkt"
         "../domain/authz/authz.rkt"
         "../domain/authz/peer.rkt"                       ; who may assert identity (issue #40)
         "../domain/i18n/i18n.rkt"
         "../domain/i18n/policy.rkt"
         "../domain/branding/branding.rkt"
         "../domain/orgs/orgs.rkt"
         "../domain/features/features.rkt"
         "../domain/audit/reads.rkt"                      ; the read context a request carries (#84)
         "../domain/agent/plugins.rkt"                    ; plugin-dir — where a plugin's pages live
         (only-in "../domain/db/id.rkt" new-id random-token)
         "errors.rkt"
         "../surface/messages.rkt")

;; ---- HTTP methods -----------------------------------------------------------
(define (GET? m) (bytes=? m #"GET"))
(define (POST? m) (bytes=? m #"POST"))
(define (PUT? m) (bytes=? m #"PUT"))
(define (DELETE? m) (bytes=? m #"DELETE"))
(define (PATCH? m) (bytes=? m #"PATCH"))

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
(define (saas-mode?) (equal? (tmach-env "MODE") "saas"))   ; hosted: bootstrap off, provisioning on
(define (home-mode) (or (tmach-env "HOME") "login"))       ; what the root route shows: login | beta
;; multi-tenancy (slice 45): several companies on one instance. OFF is the default
;; and off is byte-for-byte the previous product — the flag switches surface area
;; (the /api/orgs + /api/org management planes), not the authorization semantics.
(define (multitenant?) (and (member (or (tmach-env "MULTITENANT") "") '("1" "true" "yes" "on")) #t))
(define (bind-ip) (or (tmach-env "BIND") "127.0.0.1"))   ; set to a tailnet IP to share privately
;; max-upload-bytes now lives in config.rkt (shared with domain/s3/server.rkt,
;; which needs the same ceiling and can't require this module back).
(define default-port 8835)                                     ; "TEL" on a keypad; 8080 is too crowded to squat on
(define (listen-port)   ; TMACH_PORT wins, then PORT (the common convention), else the default
  (define raw (or (tmach-env "PORT") (env* "PORT")))
  (cond
    [(not raw) default-port]
    [(let ([n (string->number raw)]) (and (exact-integer? n) (<= 1 n 65535) n))]
    [else (error 'telemachus "invalid port ~s — expected an integer in 1–65535" raw)]))
(define (tls-on?) (and (member (or (tmach-env "TLS") "") '("1" "true" "yes" "on")) #t))
(define (tls-cert) (or (tmach-env "TLS_CERT") (path->string (build-path (data-dir) "cert.pem"))))
(define (tls-key)  (or (tmach-env "TLS_KEY")  (path->string (build-path (data-dir) "key.pem"))))
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
  (define e (tmach-env "LOCALES"))
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

;; Every value for a repeated key. `query-param` answers with the FIRST, which is
;; right for a scalar and wrong for a filter you are meant to stack —
;; ?attr=a:1&attr=b:2 is two conditions, not a last-one-wins.
(define (query-params req name)
  (define k (if (symbol? name) name (string->symbol name)))
  (for/list ([kv (in-list (url-query (request-uri req)))]
             #:when (and (eq? (car kv) k) (cdr kv) (not (string=? (cdr kv) ""))))
    (cdr kv)))

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

;; ---- identity ---------------------------------------------------------------
;; issue #40: the identity headers are honoured only from a peer we trust — see
;; domain/authz/peer.rkt for what that means and why. A deployment behind a
;; trusted reverse proxy names it in TELEMACHUS_TRUSTED_HEADER_PEERS.
(define (header-identity-allowed? req)
  (define ip (with-handlers ([exn:fail? (lambda (_) #f)]) (request-client-ip req)))
  (peer-trusted? ip (parse-peer-allowlist (tmach-env "TRUSTED_HEADER_PEERS"))))

(define (current-principal req)
  (define auth (req-header req #"authorization"))
  (cond
    [(and auth (string-prefix? auth "Bearer ")) (resolve-token db-conn (substring auth 7))]
    [(not (header-identity-allowed? req)) #f]        ; a remote caller needs a token
    [else
     (define u (req-header req #"x-telemachus-user"))
     (define team (req-header req #"x-telemachus-team"))
     (and u team (principal-for db-conn u team))]))

(define (perms-of p)
  (if (principal-is-operator p) '("*:*")
      (user-permissions db-conn (principal-user-id p) (principal-team-id p))))

;; ---- responses --------------------------------------------------------------
(define (err msg code) (json-response (hasheq 'error msg) #:code code))

;; #123's error rule, the request id and `req-header` live in server/errors.rkt
;; — a module with NO DATABASE in it, so a unit test can require them. Putting
;; them here was wrong for a reason worth keeping: requiring THIS module
;; instantiates the pool, and CI's SQLite leg sets DATABASE_URL to the empty
;; string, so the test failed there and nowhere else.
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
;; The shell's <title>, meta description and Open Graph tags come from instance
;; branding (issues #10 and #12): crawlers, unfurlers and link previews never run
;; the SPA, so the raw HTML has to carry them. The description is the tagline when
;; the operator set one, else the product's own default line — the copy is the
;; operator's, which is why the tagline field is where it comes from. Procedural
;; replacement throughout: regexp-replace* expands `&` and `\<n>` in a STRING
;; replacement, so a branded title like "A & B" would corrupt the markup.
(define DEFAULT-DESCRIPTION "A self-hosted, privacy-first platform for a team's AI tools and documents.")
(define (ui-html-branded [req #f])
  (define b (branding-for db-conn (request-org req)))
  (define title (let ([t (hash-ref b 'title "")]) (if (string=? t "") "Telemachus" t)))
  (define tagline (string-normalize-spaces (hash-ref b 'tagline "")))
  (define description (if (string=? tagline "") DEFAULT-DESCRIPTION tagline))
  ;; og:image must be an absolute URL — unfurlers do not resolve relative ones
  (define logo (let ([l (hash-ref b 'logo 'null)])
                 (and req (string? l) (not (string=? l ""))
                      (string-append (public-base req) "/api/beta/asset/" l))))
  (define meta
    (string-append
     "<meta name=\"description\" content=\"" (html-escape description) "\">"
     "<meta property=\"og:type\" content=\"website\">"
     "<meta property=\"og:site_name\" content=\"" (html-escape title) "\">"
     "<meta property=\"og:title\" content=\"" (html-escape title) "\">"
     "<meta property=\"og:description\" content=\"" (html-escape description) "\">"
     (if logo (string-append "<meta property=\"og:image\" content=\"" (html-escape logo) "\">") "")
     "<meta name=\"twitter:card\" content=\"summary\">"))
  (define with-title
    (regexp-replace* #px"<title>.*?</title>" UI-HTML
                     (lambda _ (string-append "<title>" (html-escape title) "</title>" meta))))
  ;; #110 r6 removed a second rewrite here, which stamped a per-request nonce
  ;; onto the one inline <script>. The console's script is static/console/*.js
  ;; now, loaded with `src`, which `script-src 'self'` already permitted — so
  ;; there is no inline block to authorize and no nonce to stamp.
  with-title)
(define (html-response s)
  (response/output #:mime-type #"text/html; charset=utf-8"
                   (lambda (out) (write-string s out))))

;; ---- static file serving (SDK + Tier-B plugin bundles) ----------------------
(define STATIC-MIME
  (hash "html" #"text/html; charset=utf-8" "js" #"application/javascript" "css" #"text/css"
        "json" #"application/json" "svg" #"image/svg+xml" "png" #"image/png"
        "jpg" #"image/jpeg" "jpeg" #"image/jpeg" "gif" #"image/gif" "webp" #"image/webp"
        "ico" #"image/x-icon" "woff2" #"font/woff2" "woff" #"font/woff" "ttf" #"font/ttf" "otf" #"font/otf"
        ;; issue #54: an unknown extension becomes application/octet-stream, and every
        ;; response carries nosniff — so a Tier-B bundle shipping ES modules, a source
        ;; map or wasm was REFUSED by the browser rather than mistyped. These three are
        ;; what a modern bundle actually ships.
        "mjs" #"text/javascript" "map" #"application/json" "wasm" #"application/wasm"
        "txt" #"text/plain; charset=utf-8" "webmanifest" #"application/manifest+json"))
(define (ext-of s) (let ([m (regexp-match #rx"\\.([A-Za-z0-9]+)$" s)]) (if m (string-downcase (cadr m)) "")))
(define (mime-of s) (hash-ref STATIC-MIME (ext-of s) #"application/octet-stream"))
(define (serve-file path #:cache [cache #"public, max-age=300"] #:headers [extra '()])
  (if (and (file-exists? path))
      (response/output #:mime-type (mime-of (path->string path))
                       #:headers (append (list (make-header #"Cache-Control" cache)
                                               (make-header #"X-Content-Type-Options" #"nosniff"))
                                         extra)
                       (lambda (out) (write-bytes (file->bytes path) out)))
      (err "not found" 404)))
;; a path segment safe to interpolate into a filesystem path (no traversal, no slashes)
(define (safe-seg? s) (and (string? s) (regexp-match? #rx"^[A-Za-z0-9._-]+$" s) (not (string=? s "..")) #t))
;; /beta/bundle/<plugin>/<path...> → plugins/<plugin>/landing/<path> (index.html default)
;; issue #44: the loader honours TELEMACHUS_PLUGINS and these helpers did not —
;; they rebuilt a path from impl-root, so a plugin loaded from elsewhere served
;; every one of its pages as a 404 while its tools and routes worked. Ask the
;; loader where the plugin actually came from.
(define (plugin-root plugin kind)
  (define d (and (safe-seg? plugin) (plugin-dir plugin)))
  (and d (build-path d kind)))

(define (bundle-file-path segs)
  (and (>= (length segs) 3) (equal? (list-ref segs 0) "beta") (equal? (list-ref segs 1) "bundle")
       (let* ([plugin (list-ref segs 2)]
              [rest (filter (lambda (s) (not (string=? s ""))) (list-tail segs 3))]   ; tolerate trailing slash
              [root (plugin-root plugin "landing")])
         (and root (andmap safe-seg? rest)
              (apply build-path root (if (null? rest) '("index.html") rest))))))

;; issue #20: /api/x/<plugin>/bundle/<path...> → plugins/<plugin>/bundle/<path>,
;; the AUTHENTICATED counterpart of the funnel's public landing bundle. Two rules
;; keep customer screens off a public path: the plugin must be LOADED (so the
;; route can only ever reach a directory the operator installed, never an
;; arbitrary one), and every segment is a plain name — `..` and slashes are not
;; names, so the path cannot climb out of the bundle directory into the plugin's
;; source. The caller's principal and org are the plugin's API's business
;; (/api/x/<id>/… routes see both); the bundle itself is code, one copy for
;; everyone, which is why it does not vary by org.
;; ---- bundle tickets (issue #43) ---------------------------------------------
;; An authenticated plugin page could not be OPENED. The token lives in
;; localStorage and there is no cookie, so a browser navigation to
;; /api/x/<id>/bundle/ sent no credentials and got a 401 — the smoke passed
;; because curl sends the header a navigation never will.
;;
;; The console mints a short-lived TICKET with its bearer and opens the page with
;; it; the first response sets that ticket as a cookie scoped to this plugin's
;; bundle path, so the page's own stylesheet, script and images load without the
;; query string trailing through them. Deliberately NOT a session cookie issued
;; at sign-in: nothing ambient rides on the JSON API, so the API keeps its
;; no-cookie, no-CSRF-surface property; this one is HttpOnly, SameSite=Strict and
;; reaches exactly one plugin's static files.
(define BUNDLE-TICKET-SECONDS (* 30 60))
(define bundle-tickets (make-hash))          ; token -> (list plugin user team expiry)
(define (bundle-ticket-sweep!)
  (define now (current-seconds))
  (for ([(k v) (in-hash (hash-copy bundle-tickets))])
    (when (< (list-ref v 3) now) (hash-remove! bundle-tickets k))))
(define (bundle-ticket-mint! plugin p)
  (bundle-ticket-sweep!)
  (define t (random-token 24))
  (hash-set! bundle-tickets t (list plugin (principal-user-id p) (principal-team-id p)
                                    (+ (current-seconds) BUNDLE-TICKET-SECONDS)))
  t)
(define (bundle-ticket-valid? t plugin)
  (define v (and (string? t) (hash-ref bundle-tickets t #f)))
  (and v (equal? (car v) plugin) (>= (list-ref v 3) (current-seconds)) v))
;; the cookie the first bundle response sets, so sub-resources carry it
(define (bundle-cookie-of req)
  (define h (req-header req #"cookie"))
  (define m (and (string? h) (regexp-match #px"(?:^|;\\s*)tmx_bundle=([A-Za-z0-9_-]+)" h)))
  (and m (cadr m)))

(define (plugin-bundle-file-path plugin rest-path)
  (define rest (filter (lambda (s) (not (string=? s "")))
                       (string-split (or rest-path "") "/")))
  (define root (plugin-root plugin "bundle"))          ; #f unless the plugin LOADED
  (and root (andmap safe-seg? rest)
       (apply build-path root (if (null? rest) '("index.html") rest))))

;; Server-Sent Events: proc receives an `emit` that pushes one JSON event.
;;
;; #187: THE BODY RUNS AFTER THE HANDLER HAS RETURNED, so it is outside
;; `with-auth`'s parameterize extent and everything inside it that reads the
;; request principal from the dynamic context sees #f. Three things do, and all
;; three are in the model path a streaming endpoint exists for: the
;; model-request logger (which wrote every streamed chat with a NULL team, so
;; `GET /api/model-requests` — the one route that reads the log, and which
;; filters `WHERE team_id = ?` — could never show it), the egress policy's
;; request context, and the pull router's team/user.
;;
;; The principal is captured HERE, while the handler's extent still holds, and
;; rebound around the body. It is a captured VALUE, not a second read, so it
;; cannot go stale and does not care which thread the body is written on —
;; which is the half that makes this different from the bug. Fixing it in the
;; two call sites instead would leave the next SSE endpoint to rediscover it;
;; both of today's are model calls, and both were wrong.
(define (sse-response proc)
  ;; AN SSE BODY RUNS AFTER ITS HANDLER HAS RETURNED, so it is outside the
  ;; parameterize extent `handle` and `with-auth` set up — and everything inside
  ;; it that reads a request-scoped fact from the DYNAMIC CONTEXT sees `#f`.
  ;; #187 found three such readers, all in the model path a streaming endpoint
  ;; exists for, and fixed them by carrying the PRINCIPAL. Two more facts cross
  ;; the same boundary and were not carried (#186):
  ;;
  ;;   • the REQUEST ID, which is what joins a logged diagnostic to the answer a
  ;;     caller was given;
  ;;   • the LOCALIZER, so a refusal inside a stream is in the caller's language
  ;;     rather than the instance default.
  ;;
  ;; They are captured as VALUES while the handler's extent still holds, not
  ;; re-read later, so they cannot go stale and it does not matter which thread
  ;; writes the body — #187's rule: where a value can be passed, pass it.
  (define p (current-request-principal))
  (define rid (or (current-request-id) (new-id)))
  (define loc (current-localizer))
  (response/output
   #:mime-type #"text/event-stream; charset=utf-8"
   #:headers (list (make-header #"Cache-Control" #"no-cache")
                   (make-header #"X-Accel-Buffering" #"no"))
   (lambda (out)
     (define (emit ev) (write-string (string-append "data: " (jsexpr->string ev) "\n\n") out) (flush-output out))
     (parameterize ([current-request-principal p]
                    [current-request-id rid]
                    [current-localizer loc])
       ;; #123 CLOSED THE 500-BODY LEAK AND THIS PATH KEPT IT. `handle` answers
       ;; `{error: "internal error", request_id}` and sends the message to the
       ;; log; this emitted `(exn-message e)` verbatim, to the client, for every
       ;; failure — and the headers have already gone, so there is no status code
       ;; to carry the distinction. #83 r4 sealed four stored `error` columns
       ;; because this platform's own code quotes what it choked on; the same
       ;; reasoning applies to an SSE event, and the wire had not been looked at.
       ;;
       ;; The classification mirrors `handle`'s, including its ORDER:
       ;; `exn:fail:user` is a subtype of `exn:fail` and the first matching
       ;; clause wins (PULL-14's lesson). A deliberate refusal keeps its message
       ;; — that detail is the point of refusing rather than ignoring — and
       ;; everything else does not.
       ;; `sse-error-event` lives in server/errors.rkt beside `handle`'s own
       ;; rule, and is unit-tested there: requiring kit instantiates the
       ;; connection pool, so a test of this classification in kit could not run
       ;; on CI's SQLite leg at all (#123's recorded trap).
       (with-handlers ([exn:fail? (lambda (e)
                                    (define-values (ev log) (sse-error-event e rid))
                                    (when log (eprintf "ERROR [~a] ~a\n" rid log))
                                    (emit ev))])
         (proc emit))))))

;; ---- the company a request is for, and this instance's public base ---------
;; TEN-2d: the company a request is FOR — the Host header first (a company's own
;; hostname wears its branding before anyone has signed in), else the caller's own
;; company when the request carries a valid token. Only with multi-tenancy on: a
;; single-tenant instance has one implicit org and exactly one branding.
(define (request-org req)
  (and req (multitenant?)
       (or (org-by-domain db-conn (req-header req #"host"))
           (let ([p (current-principal req)]) (and p (caller-org p))))))

(define (public-base req)
  (or (tmach-env "PUBLIC_URL")
      (let ([h (req-header req #"host")])
        (string-append (if (tls-on?) "https://" "http://") (or h (bind-ip))))))

(define (with-mt req proc)          ; flag gate → 404, so the feature is invisible when off
  (if (multitenant?) (proc) (err "multi-tenancy is not enabled on this instance" 404)))

;; the caller's own company, from their home org (never from a request parameter —
;; an org admin must not be able to name someone else's org)
(define (caller-org p) (or (principal-org-id p) (team-org db-conn (principal-team-id p))))

;; ---- authentication and the feature gate ------------------------------------
;; refuse an endpoint whose feature a team has turned off (→ localized 403)
(define (require-feature p name)
  (unless (feature-enabled? db-conn (principal-team-id p) name)
    (raise (exn:fail:forbidden (format "feature ~a is disabled" name) (current-continuation-marks) name))))

(define current-request-principal (make-parameter #f))
;; IDEMPOTENT since #110 r2. The DISPATCHER now authenticates every non-public
;; route before the handler runs, and 127 handlers also call `with-auth`
;; themselves — so without this the token would be resolved twice per request:
;; two indexed lookups and two `last_used_epoch` writes, on every call. An
;; already-resolved principal is reused, which also means the handler-side calls
;; can be removed gradually rather than in one 187-file commit.
;;
;; Reusing it is correct and not merely cheap: `current-request-principal` is set
;; by this function and by nothing else, so a value in it was resolved from THIS
;; request's own bearer a few frames up.
(define (with-auth req proc)
  (define already (current-request-principal))
  (define p (or already (current-principal req)))
  (cond
    [(not p) (unauthorized)]
    ;; the suspended-tenant and context work was done by the outer call
    [already (proc p)]
    ;; ONB-7 read-only, now org-aware: a suspended COMPANY freezes every team in it
    [(and (tenant-read-only? db-conn (principal-team-id p)) (not (GET? (request-method req))))
     (err "tenant suspended — writes are disabled; contact your administrator" 402)]
    [else
     ;; issue #84: every API request carries the client's address and agent, and a
     ;; request id, into whatever reads it performs. Set HERE rather than in each
     ;; handler for the reason the audit itself sits at one seam — a handler added
     ;; later inherits it instead of forgetting it. An inbound `X-Request-Id` is
     ;; honoured so a proxy's correlation id is the one in the record.
     (parameterize ([current-request-principal p]
                    [current-read-context
                     (read-context "api"
                                   (with-handlers ([exn:fail? (lambda (_) #f)])
                                     (request-client-ip req))
                                   (req-header req #"user-agent")
                                   (request-id-of req)
                                   (req-header req #"range")
                                   #f #f)])
       (proc p))]))

(define (scope-of req) (if (equal? (query-param req 'scope "") "org") 'org 'team))

;; ---- odds and ends every surface uses ---------------------------------------
;; A JSON field as a string, whatever arrived. 44 call sites across the surface
;; before #110 r3 split them into eight modules, which is why it lives here.
(define (fmt b k) (format "~a" (hash-ref b k "")))

;; the token pepper shares the fallback chain (TELEMACHUS_TOKEN_PEPPER → TELEMACHUS_SECRET);
;; running on the dev default is loud at boot, not silent
(define (warn-dev-pepper!)
  (when (token-pepper-is-default?)
    (printf "WARNING: TMACH_SECRET / TMACH_TOKEN_PEPPER not set — tokens are hashed with the dev pepper; set one in production\n")))
