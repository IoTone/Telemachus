#lang racket/base

;; test/experience-tests.rkt — admin-editable onboarding experience (slice 40):
;; storage + draft/publish precedence, RBAC, judge-prompt stripping, and the ENV
;; launch-defaults path (TELEMACHUS_ONBOARDING_FILE). raco test test/experience-tests.rkt

(require rackunit db-kit/portable json racket/file
         db-kit/migrate
         "../domain/db/migrations.rkt"
         "db-fixture.rkt"
         "../domain/authz/authz.rkt"
         "../domain/beta/beta.rkt"
         "../domain/beta/experience.rkt")

(define (fresh) (define c (fresh-db #:migrate? #f)) (migrate! c all-migrations) c)

(test-case "resolve falls back to the base experience; public slice hides the judge prompt"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice"))
  ;; no DB row yet → base (registered provider) is served
  (define eff (resolve-experience c tid))
  (check-equal? (hash-ref eff 'name) "beta")
  (check-true (pair? (hash-ref eff 'fields)))
  (check-true (string? (hash-ref eff 'judge-system)))            ; base carries the prompt
  ;; the public slice never leaks it
  (define pub (resolve-experience-public c tid))
  (check-false (hash-has-key? pub 'judge-system))
  (check-true (pair? (hash-ref pub 'fields))))

(test-case "draft → publish: DB wins over base only once published"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice"))
  (define alice (user-principal c uid tid))
  (define base-title (hash-ref (resolve-experience c tid) 'title))

  ;; save a draft with a changed title
  (check-true (experience-save! c alice (hasheq 'name "beta" 'title "Our Private Beta"
                                                'subtitle "hi" 'judge-system "j"
                                                'fields (list (hasheq 'key "email" 'label "Email" 'type "email" 'required #t)))))
  ;; serving is unchanged until publish
  (check-equal? (hash-ref (resolve-experience c tid) 'title) base-title)
  ;; but the editor sees the draft
  (check-equal? (hash-ref (experience-draft c alice) 'title) "Our Private Beta")

  ;; publish → serving now reflects the DB row
  (check-true (experience-publish! c alice))
  (check-equal? (hash-ref (resolve-experience c tid) 'title) "Our Private Beta")
  (check-false (hash-has-key? (resolve-experience-public c tid) 'judge-system))
  ;; the experience list shows both rows
  (check-equal? (length (experience-list c alice)) 2))

(test-case "branding (theme + details) survives publish into the public slice"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice"))
  (define alice (user-principal c uid tid))
  (check-true (experience-save! c alice
    (hasheq 'name "beta" 'title "Skinned" 'logo "ACME"
            'theme (hasheq 'brand "#ffb200" 'bg "#0a0a0b" 'mode "dark")
            'details (list (hasheq 'heading "Why" 'body "because"))
            'fields (list (hasheq 'key "email" 'label "Email" 'type "email" 'required #t))
            'judge-system "vet acme")))
  (check-true (experience-publish! c alice))
  (define pub (resolve-experience-public c tid))
  (check-equal? (hash-ref pub 'logo) "ACME")
  (check-equal? (hash-ref (hash-ref pub 'theme) 'brand) "#ffb200")
  (check-equal? (hash-ref (car (hash-ref pub 'details)) 'heading) "Why")
  (check-false (hash-has-key? pub 'judge-system)))       ; still stripped

(test-case "landing resolver: shell default, bundle when configured (Tier B)"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice"))
  (define alice (user-principal c uid tid))
  ;; default: built-in shell
  (check-equal? (hash-ref (experience-landing c tid) 'type) "shell")
  ;; publish an experience that selects a plugin bundle
  (check-true (experience-save! c alice (hasheq 'name "beta" 'title "x" 'fields '()
                                                'landing (hasheq 'type "bundle" 'plugin "beta-onboarding"))))
  (check-true (experience-publish! c alice))
  (define l (experience-landing c tid))
  (check-equal? (hash-ref l 'type) "bundle")
  (check-equal? (hash-ref l 'plugin) "beta-onboarding")
  (check-equal? (hash-ref l 'url) "/beta/bundle/beta-onboarding/")
  ;; a bundle entry missing a plugin name falls back to the shell
  (check-true (experience-save! c alice (hasheq 'name "beta" 'fields '() 'landing (hasheq 'type "bundle"))))
  (check-true (experience-publish! c alice))
  (check-equal? (hash-ref (experience-landing c tid) 'type) "shell")
  ;; Tier-C template
  (check-true (experience-save! c alice (hasheq 'name "beta" 'fields '() 'landing (hasheq 'type "template"))))
  (check-true (experience-publish! c alice))
  (define lt (experience-landing c tid))
  (check-equal? (hash-ref lt 'type) "template")
  (check-equal? (hash-ref lt 'url) "/beta/template"))

(test-case "publish with no draft is a no-op"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice"))
  (define alice (user-principal c uid tid))
  (check-false (experience-publish! c alice)))

(test-case "RBAC: a viewer cannot read or edit the experience"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice"))
  (define bob (create-user! c #:username "bob"))
  (add-member! c #:user bob #:team tid #:role "viewer")
  (define v (user-principal c bob tid))
  (check-exn exn:fail:forbidden? (lambda () (experience-draft c v)))
  (check-exn exn:fail:forbidden? (lambda () (experience-save! c v (hasheq 'name "beta"))))
  (check-exn exn:fail:forbidden? (lambda () (experience-publish! c v))))

(test-case "ENV launch defaults: TELEMACHUS_ONBOARDING_FILE seeds the base (judge_system normalized)"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice"))
  (define f (make-temporary-file "tmx-onb-~a.json"))
  (dynamic-wind
    (lambda ()
      (call-with-output-file f #:exists 'replace
        (lambda (o) (write-json (hasheq 'name "beta" 'title "ENV Beta" 'subtitle "from env"
                                        'fields (list (hasheq 'key "email" 'label "Email" 'type "email" 'required #t))
                                        'judge_system "env judge prompt") o)))
      (putenv "TELEMACHUS_ONBOARDING_FILE" (path->string f)))
    (lambda ()
      ;; base picks up ENV overrides; judge_system is normalized to 'judge-system
      (check-equal? (hash-ref (base-experience) 'title) "ENV Beta")
      (check-equal? (hash-ref (base-experience) 'judge-system) "env judge prompt")
      ;; served on first boot with no DB row
      (check-equal? (hash-ref (resolve-experience c tid) 'title) "ENV Beta")
      (check-equal? (experience-judge-system c tid) "env judge prompt")
      (check-false (hash-has-key? (resolve-experience-public c tid) 'judge-system)))
    (lambda ()
      (putenv "TELEMACHUS_ONBOARDING_FILE" "")
      (delete-file f))))

;; Regression (see issue: renamed experience silently lost). The console's
;; onboarding editor lets an admin change `name`. experience-save! used to key
;; the row on that value while experience-draft and experience-publish! read it
;; back under experience-active-key, so a rename wrote an orphan row: the editor
;; reloaded the old config and Publish answered "nothing to publish".
(test-case "a renamed experience still round-trips through draft and publish"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice"))
  (define alice (user-principal c uid tid))
  (define renamed (hasheq 'name "rcnt-private-beta" 'title "RCNT Private Beta"
                          'subtitle "s" 'judge-system "j"
                          'fields (list (hasheq 'key "email" 'label "Email" 'type "email" 'required #t))))

  (check-true (experience-save! c alice renamed))
  ;; exactly one draft row, and it is the one the editor reads back
  (check-equal? (length (experience-list c alice)) 1)
  (check-equal? (hash-ref (experience-draft c alice) 'title) "RCNT Private Beta")
  (check-equal? (hash-ref (experience-draft c alice) 'name) "rcnt-private-beta")

  ;; and Publish finds it
  (check-true (experience-publish! c alice))
  (check-equal? (hash-ref (resolve-experience c tid) 'title) "RCNT Private Beta"))

;; ---- localization: a per-locale overlay on one experience document -----------
;; The funnel's copy is operator-authored, so it cannot live in locales/*.json.
;; It is an `i18n` overlay on the same document; the base config stays the
;; DEFAULT-locale copy, so an experience with no overlay behaves exactly as before.

(define (localized-exp)
  (hasheq 'name "beta"
          'title "Join the beta" 'subtitle "Tell us about your team."
          'eyebrow "Private beta" 'cta "Request access" 'footer "(c) Telemachus"
          'details (list (hasheq 'heading "What you get" 'body "Early access."))
          'fields (list (hasheq 'key "email" 'label "Work email" 'type "email" 'required #t)
                        (hasheq 'key "size"  'label "Team size"  'type "select"
                                'options (list "1-10" "11-50") 'required #f))
          'judge-system "j"
          'i18n (hasheq 'ja (hasheq 'title "ベータに参加"
                                    'cta "アクセスを申請"
                                    'details (list (hasheq 'heading "提供内容" 'body "早期アクセス。"))
                                    'fields (hasheq 'email (hasheq 'label "勤務先メール")
                                                    'size  (hasheq 'label "チーム規模"
                                                                   'options (list "1〜10" "11〜50")))))))

(test-case "an overlay localizes copy, labels and select options"
  (define cfg (localized-exp))
  (check-equal? (experience-locales cfg #:default "en") '("en" "ja"))

  (define ja (experience-localize cfg "ja"))
  (check-equal? (hash-ref ja 'title) "ベータに参加")
  (check-equal? (hash-ref ja 'cta) "アクセスを申請")
  (check-equal? (hash-ref (car (hash-ref ja 'details)) 'heading) "提供内容")
  (define f (hash-ref ja 'fields))
  (check-equal? (hash-ref (car f) 'label) "勤務先メール")
  (check-equal? (hash-ref (cadr f) 'options) '("1〜10" "11〜50"))
  ;; anything the overlay did not translate keeps the base copy — a partial
  ;; overlay degrades to mixed language, never to a blank
  (check-equal? (hash-ref ja 'subtitle) "Tell us about your team.")
  (check-equal? (hash-ref ja 'eyebrow) "Private beta"))

(test-case "translation is PRESENTATION ONLY — it can never move the data contract"
  ;; A hostile or careless overlay tries to rename a field key, flip `required`,
  ;; change a type, and replace the judge prompt. None of it may take effect: the
  ;; submitted body and the anti-abuse config must be identical in every language.
  (define cfg (hash-set (localized-exp) 'i18n
                        (hasheq 'ja (hasheq 'fields (hasheq 'email (hasheq 'label "メール"
                                                                           'key "eviltwin"
                                                                           'type "text"
                                                                           'required #f))
                                            'judge-system "OVERRIDDEN"
                                            'name "not-the-key"))))
  (define ja (experience-localize cfg "ja"))
  (define email (car (hash-ref ja 'fields)))
  (check-equal? (hash-ref email 'label) "メール")          ; the label DID localize
  (check-equal? (hash-ref email 'key) "email")             ; the key did NOT move
  (check-equal? (hash-ref email 'type) "email")
  (check-true   (hash-ref email 'required))
  (check-equal? (hash-ref ja 'judge-system) "j")
  (check-equal? (hash-ref ja 'name) "beta"))

(test-case "funnel-locale never serves a half-translated page"
  (define cfg (localized-exp))
  (check-equal? (funnel-locale cfg "ja" #:default "en") "ja")
  (check-equal? (funnel-locale cfg "ja-JP" #:default "en") "ja")   ; region tag → base
  (check-equal? (funnel-locale cfg "fr" #:default "en") "en")      ; no overlay → default
  (check-equal? (funnel-locale cfg #f #:default "en") "en")
  ;; on a ja-DEFAULT instance an unknown locale lands on ja, not on English
  (check-equal? (funnel-locale cfg "fr" #:default "ja") "ja"))

(test-case "the public slice ships one language, and never the overlay table"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice"))
  (define alice (user-principal c uid tid))
  (check-true (experience-save! c alice (localized-exp)))
  (check-true (experience-publish! c alice))

  (define pub (resolve-experience-public c tid #:locale "ja" #:default "en"))
  (check-equal? (hash-ref pub 'title) "ベータに参加")
  (check-equal? (hash-ref pub 'locale) "ja")
  (check-equal? (hash-ref pub 'locales) '("en" "ja"))
  ;; a visitor is never shipped the other languages' copy, nor the judge prompt
  (check-false (hash-has-key? pub 'i18n))
  (check-false (hash-has-key? pub 'judge-system))

  ;; and the default locale is the untouched base copy
  (define en (resolve-experience-public c tid #:locale "en" #:default "en"))
  (check-equal? (hash-ref en 'title) "Join the beta"))

(test-case "an experience with no overlay is byte-for-byte what it was before"
  (define cfg (hash-remove (localized-exp) 'i18n))
  (check-equal? (experience-locales cfg #:default "en") '("en"))
  (check-equal? (experience-localize cfg "ja") cfg)
  (check-equal? (funnel-locale cfg "ja" #:default "en") "en"))

;; ---- review follow-ups (i18n review, findings 1, 3, 4) ----------------------

;; The base document's locale is a property of the EXPERIENCE, not of the
;; instance. Conflating them made the English base unreachable on a ja-default
;; instance and collapsed `locales` to one entry, which hides the switcher.
(test-case "the instance default never masquerades as the base document's locale"
  (define cfg (localized-exp))                       ; English base + ja overlay
  ;; an operator sets the instance default to ja — a supported action
  (check-equal? (experience-locales cfg #:default "ja") '("en" "ja"))
  (check-equal? (funnel-locale cfg "en" #:default "ja") "en")   ; base still reachable
  (check-equal? (funnel-locale cfg "ja" #:default "ja") "ja")
  ;; nothing requested → the instance default, because this experience HAS ja copy
  (check-equal? (funnel-locale cfg #f #:default "ja") "ja")
  ;; two entries, so the switcher renders
  (check-true (>= (length (experience-locales cfg #:default "ja")) 2)))

(test-case "an experience authored in another language declares its own base-locale"
  (define cfg (hash-set (localized-exp) 'base-locale "ja"))
  (check-equal? (car (experience-locales cfg #:default "en")) "ja")
  ;; the ja key is the base now, so it is not also listed as an overlay
  (check-equal? (length (experience-locales cfg #:default "en")) 1))

(test-case "an instance default this experience has no copy for falls back to the base"
  (define cfg (hasheq 'name "beta" 'title "Only English" 'fields '()))
  (check-equal? (experience-locales cfg #:default "fr") '("en"))
  (check-equal? (funnel-locale cfg #f #:default "fr") "en"))

;; Locale keys reach the public funnel's switcher markup, so their shape is
;; validated server-side rather than trusted to the admin who authored them.
(test-case "malformed locale keys are refused, not rendered"
  (check-true  (locale-key? "en"))
  (check-true  (locale-key? "ja"))
  (check-true  (locale-key? "pt-BR"))
  (check-false (locale-key? "x');alert(1);('"))
  (check-false (locale-key? "en'"))
  (check-false (locale-key? ""))
  (define cfg (hasheq 'name "beta" 'title "t" 'fields '()
                      'i18n (hasheq '|x');alert(1);('| (hasheq 'title "pwned")
                                    'ja (hasheq 'title "日本語"))))
  (check-equal? (experience-locales cfg #:default "en") '("en" "ja")))

;; `email` identifies, dedups and rate-limits a prospect; field-problem refuses
;; every submission without one, so a funnel missing the field is unusable.
(test-case "publishing a config with no email field is refused"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice"))
  (define alice (user-principal c uid tid))
  (define no-email (hasheq 'name "beta" 'title "t" 'subtitle "s"
                           'fields (list (hasheq 'key "name" 'label "Name" 'type "text" 'required #t))))
  (check-exn exn:fail:user? (lambda () (experience-save! c alice no-email)))
  ;; nothing was written
  (check-equal? (length (experience-list c alice)) 0)
  ;; an empty field list is not yet a decision, so a DRAFT may hold one...
  (check-true (experience-save! c alice (hasheq 'name "beta" 'title "t" 'fields '())))
  ;; ...but publishing it would put an unusable form on a public page
  (check-exn exn:fail:user? (lambda () (experience-publish! c alice)))
  ;; a Tier-B bundle brings its own form, so the shell's field list is not the
  ;; thing an applicant sees and an empty one is publishable
  (check-true (experience-save! c alice (hasheq 'name "beta" 'fields '()
                                                'landing (hasheq 'type "bundle" 'plugin "beta-onboarding"))))
  (check-true (experience-publish! c alice))
  ;; the same config WITH email saves
  (define ok (hash-set no-email 'fields
                       (list (hasheq 'key "name"  'label "Name"  'type "text"  'required #t)
                             (hasheq 'key "email" 'label "Email" 'type "email" 'required #t))))
  (check-true (experience-save! c alice ok)))
