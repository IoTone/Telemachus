#lang racket/base

;; domain/beta/experience.rkt — the beta onboarding EXPERIENCE as admin-editable data
;; (slice 40). Resolution layers, most-authoritative first:
;;
;;   1. a PUBLISHED experience row in the DB (admin-authored at runtime) — wins.
;;   2. the BASE experience = the registered provider (code/plugin/TELEMACHUS_ONBOARDING)
;;      merged with an optional TELEMACHUS_ONBOARDING_FILE JSON of ENV launch defaults.
;;   3. (the provider registry already falls back to a built-in default.)
;;
;; So on FIRST BOOT the funnel is live with ENV-set defaults and no DB row; once an
;; admin publishes, the DB is authoritative and a redeploy will not clobber their
;; edits. See docs/design/beta-onboarding-experience.md §2 (+ "ENV launch defaults").

(require db-kit/portable   ; NOT `db` — it rewrites ? -> $n on PostgreSQL
         json
         "../db/id.rkt"
         "../authz/authz.rkt"
         "beta.rkt")   ; active-onboarding (provider registry), judge-system-prompt fallback

(provide experience-file-config base-experience experience-active-key
         resolve-experience resolve-experience-public experience-judge-system
         experience-draft experience-save! experience-publish! experience-list
         experience-landing
         experience-locales experience-localize funnel-locale
         experience-base-locale locale-key? check-structural-fields! check-publishable!)

;; ---- ENV launch defaults ----------------------------------------------------
;; A deployer can point TELEMACHUS_ONBOARDING_FILE at a JSON file describing the
;; experience (title, subtitle, fields, judge prompt, and — later — theme/hero/
;; header/footer). Its keys override the registered provider's. Human-authored JSON
;; may use "judge_system"; we normalize it to the internal 'judge-system key.
(define (normalize cfg)
  (define j (hash-ref cfg 'judge_system #f))
  (if j (hash-set (hash-remove cfg 'judge_system) 'judge-system j) cfg))

(define (experience-file-config)
  (define path (let ([v (getenv "TELEMACHUS_ONBOARDING_FILE")]) (and v (not (string=? v "")) v)))
  (and path
       (with-handlers ([exn:fail? (lambda (_) #f)])
         (define j (call-with-input-file path read-json))
         (and (hash? j) (normalize j)))))

(define (merge-config base over)
  (for/fold ([h base]) ([(k v) (in-hash over)]) (hash-set h k v)))

;; the launch default: registered provider, with ENV-file overrides on top
(define (base-experience)
  (define prov (active-onboarding))
  (define f (experience-file-config))
  (if f (merge-config prov f) prov))

(define (experience-active-key) (hash-ref (base-experience) 'name "beta"))

;; ---- storage ----------------------------------------------------------------
(define (row-config conn team key status)
  (and team
       (query-maybe-value conn
        "SELECT config FROM onboarding_experiences WHERE team_id = ? AND key = ? AND status = ? ORDER BY updated_at DESC LIMIT 1"
        team key status)))

(define (parse-config s)
  (with-handlers ([exn:fail? (lambda (_) #f)])
    (let ([v (string->jsexpr s)]) (and (hash? v) v))))

;; one row per (team, key, status): replace-in-place
(define (upsert! conn team key status config user)
  (query-exec conn "DELETE FROM onboarding_experiences WHERE team_id = ? AND key = ? AND status = ?" team key status)
  (query-exec conn
    (string-append "INSERT INTO onboarding_experiences (id, team_id, key, status, config, updated_by, updated_at) "
                   "VALUES (?, ?, ?, ?, ?, ?, CURRENT_TIMESTAMP)")
    (new-id) team key status (jsexpr->string config) (or user sql-null)))

;; ---- resolution (public / serving — no principal) ---------------------------
;; the effective experience for a team: published DB row, else the ENV/provider base
(define (resolve-experience conn team)
  (define pub (row-config conn team (experience-active-key) "published"))
  (or (and pub (parse-config pub)) (base-experience)))

;; ---- localization: a per-locale OVERLAY on one experience document ----------
;; The funnel's copy is operator-authored marketing text, not a shipped product
;; string, so it cannot live in locales/*.json. It lives here instead, as an
;; overlay on the same document:
;;
;;   { "title": "Join the beta", "cta": "Request access",
;;     "fields": [{"key":"email","label":"Work email"}],
;;     "i18n": { "ja": { "title": "…", "cta": "…",
;;                       "fields": { "email": {"label":"勤務先メール"} } } } }
;;
;; The base document stays exactly what it is today — the DEFAULT-locale copy —
;; so an experience with no `i18n` key behaves byte for byte as before. That is
;; what makes this safe to ship over live funnels.
;;
;; TRANSLATION IS PRESENTATION ONLY. An overlay may replace visible strings and
;; nothing else: `fields` are matched BY KEY and only their `label`/`options` are
;; taken, so a translation can never rename a field key, change its type, make a
;; required field optional, or touch `judge-system`, `theme`, `landing` or
;; `template`. The form's data contract and the anti-abuse configuration are the
;; same in every language, by construction rather than by review.

;; keys an overlay is allowed to replace wholesale
(define OVERLAY-STRINGS '(title subtitle eyebrow cta footer logo))
(define OVERLAY-LISTS   '(nav details))     ; replaced as a whole list, not merged

;; fields: matched by `key`; only label/options are localizable.
(define (localize-fields fields over)
  (cond
    [(not (hash? over)) fields]
    [else
     (for/list ([f (in-list fields)])
       (define k (and (hash? f) (hash-ref f 'key #f)))
       (define o (and k (hash-ref over (string->symbol (format "~a" k)) #f)))
       (cond
         [(not (hash? o)) f]
         [else
          (let* ([lab (hash-ref o 'label #f)]
                 [opts (hash-ref o 'options #f)]
                 [f (if (string? lab) (hash-set f 'label lab) f)])
            (if (list? opts) (hash-set f 'options opts) f))]))]))

;; every locale this experience can actually render: the default copy, plus each
;; overlay that carries something. Derived from the document, never stored
;; separately, so the switcher cannot offer a language with no content behind it.
;; A locale KEY is rendered into the public funnel's language switcher, so its
;; shape is validated here rather than trusted. The `i18n` object is authored by
;; a settings:manage admin or by TELEMACHUS_ONBOARDING_FILE — neither is the same
;; trust level as an anonymous visitor of the page it ends up on.
(define LOCALE-KEY-RX #px"^[a-z]{2,3}(-[A-Za-z0-9]{2,8})*$")
(define (locale-key? s) (and (string? s) (regexp-match? LOCALE-KEY-RX s) #t))

;; The locale the BASE document is written in. This is a property of the
;; experience, NOT of the instance: an operator who sets the instance default to
;; `ja` has not thereby translated an English funnel. Conflating the two made the
;; base copy unreachable (`?lang=en` served the ja overlay) and collapsed
;; `locales` to one entry, which hides the switcher.
(define (experience-base-locale cfg)
  (define b (and (hash? cfg) (hash-ref cfg 'base-locale #f)))
  (if (locale-key? b) b "en"))

(define (experience-locales cfg #:default [dflt "en"])
  (define base (experience-base-locale cfg))
  (define i18n (hash-ref cfg 'i18n #f))
  (define extra
    (if (hash? i18n)
        (sort (for/list ([(k v) (in-hash i18n)]
                         #:when (and (hash? v) (positive? (hash-count v))
                                     (locale-key? (symbol->string k))))
                (symbol->string k))
              string<?)
        '()))
  (cons base (filter (lambda (l) (not (string=? l base))) extra)))

;; Apply one overlay. An unknown locale, or the default, returns the base config.
(define (experience-localize cfg locale)
  (define i18n (hash-ref cfg 'i18n #f))
  (define over (and (hash? i18n) locale (hash-ref i18n (string->symbol locale) #f)))
  (cond
    [(not (hash? over)) cfg]
    [else
     (define with-strings
       (for/fold ([h cfg]) ([k (in-list OVERLAY-STRINGS)])
         (let ([v (hash-ref over k #f)]) (if (string? v) (hash-set h k v) h))))
     (define with-lists
       (for/fold ([h with-strings]) ([k (in-list OVERLAY-LISTS)])
         (let ([v (hash-ref over k #f)]) (if (list? v) (hash-set h k v) h))))
     (hash-set with-lists 'fields
               (localize-fields (hash-ref with-lists 'fields '()) (hash-ref over 'fields #f)))]))

;; Which locale a PUBLIC funnel request is answered in. `requested` is the
;; ?lang= query value or the X-Telemachus-Locale header, or #f. It only wins if
;; the experience actually has copy for it — otherwise the instance default,
;; never a half-translated page.
(define (funnel-locale cfg requested #:default [dflt "en"])
  (define avail (experience-locales cfg #:default dflt))
  ;; Nothing matched: prefer the INSTANCE default, but only if this experience
  ;; actually has copy for it. Otherwise serve the base document rather than a
  ;; locale we would have to render from missing strings.
  (define fallback (if (member dflt avail) dflt (experience-base-locale cfg)))
  (cond
    [(and requested (member requested avail)) requested]
    ;; ja-JP should reach a `ja` overlay. `regexp-split` keeps empty pieces, so
    ;; a degenerate tag yields "" here and simply fails to match — no `car` trap.
    [(and requested
          (let ([base (car (regexp-split #rx"-" requested))])
            (and (member base avail) base)))
     => values]
    [else fallback]))

;; the public slice the SPA renders from — never leak the judge prompt, and never
;; ship the other languages' copy to a visitor who asked for one of them. The
;; overlay table is replaced by the resolved `locale` plus the `locales` a
;; switcher may offer.
(define (public-slice cfg #:locale [locale #f] #:locales [locales #f])
  (define base (hash-remove (hash-remove cfg 'judge-system) 'i18n))
  (let* ([h (if locale (hash-set base 'locale locale) base)]
         [h (if locales (hash-set h 'locales locales) h)])
    h))

(define (resolve-experience-public conn team #:locale [requested #f] #:default [dflt "en"])
  (define cfg (resolve-experience conn team))
  (define avail (experience-locales cfg #:default dflt))
  (define loc (funnel-locale cfg requested #:default dflt))
  (public-slice (experience-localize cfg loc) #:locale loc #:locales avail))

;; the judge prompt for a team's active experience (falls back to the built-in)
(define (experience-judge-system conn team)
  (hash-ref (resolve-experience conn team) 'judge-system (judge-system-prompt)))

;; how the root landing is rendered: the built-in Tier-A shell, or a Tier-B plugin
;; bundle. Config carries {landing:{type:"bundle", plugin:"<name>"}}; we add the URL.
(define (experience-landing conn team)
  (define l (hash-ref (resolve-experience conn team) 'landing #f))
  (cond
    [(and (hash? l) (equal? (hash-ref l 'type #f) "bundle")
          (string? (hash-ref l 'plugin #f)) (not (string=? (hash-ref l 'plugin "") "")))
     (define plugin (hash-ref l 'plugin))
     (hasheq 'type "bundle" 'plugin plugin 'url (string-append "/beta/bundle/" plugin "/"))]
    [(and (hash? l) (equal? (hash-ref l 'type #f) "template"))
     (hasheq 'type "template" 'url "/beta/template")]
    [else (hasheq 'type "shell")]))

;; ---- admin (settings:manage) ------------------------------------------------
;; the editor's starting point: an existing draft, else the current effective config
(define (experience-draft conn p)
  (require-perm conn p "settings:manage")
  (define team (principal-team-id p))
  (define d (row-config conn team (experience-active-key) "draft"))
  (or (and d (parse-config d)) (resolve-experience conn team)))

;; A config that drops a structural field is refused at the door. `email` is how a
;; prospect is identified, deduped and rate-limited, and `field-problem` rejects
;; every submission without one — so a funnel missing the field shows an applicant
;; "a valid email is required" beside no field that could satisfy it. This was
;; documented as an invariant when the field model landed (`structural-field?`,
;; beta.rkt) but nothing enforced it; the only callers were tests.
;; Drafts stay permissive and publishing is strict: an editor mid-edit may hold a
;; config with no field list yet, but the page the public sees must be usable.
(define (has-structural-field? fields)
  (and (list? fields)
       (for/or ([f (in-list fields)] #:when (hash? f))
         (structural-field? (format "~a" (hash-ref f 'key ""))))))

(define STRUCTURAL-MSG
  "the email field cannot be removed - it identifies, dedups and rate-limits a prospect")

;; save: refuse a field list that HAS fields but dropped email — the actual
;; "admin deleted the email row" case. An absent or empty list is not yet a
;; decision, so it passes here and is caught at publish.
(define (check-structural-fields! config)
  (define fields (hash-ref config 'fields #f))
  (when (and (list? fields) (pair? fields) (not (has-structural-field? fields)))
    (raise-user-error 'experience-save! STRUCTURAL-MSG)))

;; publish: the config is about to become the public page, so the field list must
;; exist, be non-empty, and carry email — but only for the built-in Tier-A shell,
;; which is the tier that renders `fields`. A Tier-B bundle and a Tier-C template
;; ship their own markup and their own form, so the shell's field list is not what
;; an applicant sees there and an empty one is not a broken page.
(define (shell-landing? config)
  (define l (hash-ref config 'landing #f))
  (not (and (hash? l) (member (hash-ref l 'type #f) '("bundle" "template")) #t)))

(define (check-publishable! config)
  (when (shell-landing? config)
    (unless (has-structural-field? (hash-ref config 'fields #f))
      (raise-user-error 'experience-publish! STRUCTURAL-MSG))))

(define (experience-save! conn p config)
  (require-perm conn p "settings:manage")
  (unless (hash? config) (error 'experience-save! "config must be an object"))
  (check-structural-fields! config)
  (define team (principal-team-id p))
  ;; Key on the ACTIVE experience, never on a caller-supplied config.name. The
  ;; draft must land where experience-draft and experience-publish! read it back
  ;; from, and both resolve the key through experience-active-key. Keying on
  ;; config.name meant an admin who edited the name in the console wrote an
  ;; orphan row: the editor reloaded the old config and Publish answered
  ;; "nothing to publish — save a draft first". The name is still preserved
  ;; inside the config; it just no longer decides where the row lives.
  (upsert! conn team (experience-active-key) "draft" config (principal-user-id p))
  #t)

;; promote the current draft to published (no draft → nothing to publish)
(define (experience-publish! conn p)
  (require-perm conn p "settings:manage")
  (define team (principal-team-id p))
  (define key (experience-active-key))
  (define d (row-config conn team key "draft"))
  (when d (let ([cfg (parse-config d)]) (when cfg (check-publishable! cfg))))
  (and d
       (let ([cfg (parse-config d)])
         (and cfg (begin (upsert! conn team key "published" cfg (principal-user-id p)) #t)))))

(define (experience-list conn p)
  (require-perm conn p "settings:manage")
  (define team (principal-team-id p))
  (for/list ([r (in-list (query-rows conn
                          "SELECT key, status, updated_at FROM onboarding_experiences WHERE team_id = ? ORDER BY updated_at DESC"
                          team))])
    (hasheq 'key (vector-ref r 0) 'status (vector-ref r 1) 'updated_at (vector-ref r 2))))
