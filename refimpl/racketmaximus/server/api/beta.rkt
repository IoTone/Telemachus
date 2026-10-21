#lang racket/base

;; server/api/beta.rkt — the public beta funnel: anti-abuse, signup, the
;; judge, brand assets
;;
;; Split out of main.rkt by #110 r3. The shared surface every handler here
;; needs — the pool, the request accessors, with-auth/with-mt, the response
;; constructors — is server/kit.rkt.

(provide ep-beta-config ep-beta-template ep-beta-experience-get
         ep-beta-experience-put ep-beta-experience-publish
         ep-beta-asset-upload ep-beta-assets ep-beta-asset-delete
         ep-beta-asset ep-beta-challenge ep-beta-signup ep-beta-prospects
         ep-beta-decide)

(require racket/string
         web-server/http
         web-kit
         (only-in "../../domain/authz/authz.rkt" audit! principal-team-id principal-user-id)
         "../../domain/beta/beta.rkt"
         (only-in "../../domain/beta/experience.rkt" experience-draft experience-localize experience-publish! experience-save! funnel-locale resolve-experience resolve-experience-public)
         (only-in "../../domain/beta/assets.rkt" asset-delete! asset-get asset-list asset-store!)
         (only-in "../../domain/i18n/policy.rkt" i18n-policy)
         (only-in "../../domain/beta/template.rkt" DEFAULT-TEMPLATE template-page)
         "../../domain/beta/antispam.rkt"
         (only-in "../../domain/sched/scheduler.rkt" enqueue-job!)
         (only-in "../../domain/i18n/i18n.rkt" t)
         "../../surface/messages.rkt"
         "../kit.rkt")

;; ---- beta onboarding (public signup → LLM judge → owner review) -------------

;; anti-abuse state (in-memory, per-process)
(define beta-secret (or (env* "TELEMACHUS_SECRET") "telemachus-dev-secret"))     ; set in prod

(define pow-bits    (or (string->number (or (env* "TELEMACHUS_POW_BITS") "")) 16))
(define beta-limiter (make-limiter))
(define beta-used    (new-used-set))
(define (client-key req)
  (define xff (req-header req #"x-forwarded-for"))
  (if xff (string-trim (car (string-split xff ","))) "global"))

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
