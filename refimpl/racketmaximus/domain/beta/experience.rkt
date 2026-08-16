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

(require db
         json
         "../db/id.rkt"
         "../authz/authz.rkt"
         "beta.rkt")   ; active-onboarding (provider registry), judge-system-prompt fallback

(provide experience-file-config base-experience experience-active-key
         resolve-experience resolve-experience-public experience-judge-system
         experience-draft experience-save! experience-publish! experience-list)

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

;; the public slice the SPA renders from — never leak the judge prompt
(define (public-slice cfg) (hash-remove cfg 'judge-system))
(define (resolve-experience-public conn team) (public-slice (resolve-experience conn team)))

;; the judge prompt for a team's active experience (falls back to the built-in)
(define (experience-judge-system conn team)
  (hash-ref (resolve-experience conn team) 'judge-system (judge-system-prompt)))

;; ---- admin (settings:manage) ------------------------------------------------
;; the editor's starting point: an existing draft, else the current effective config
(define (experience-draft conn p)
  (require-perm conn p "settings:manage")
  (define team (principal-team-id p))
  (define d (row-config conn team (experience-active-key) "draft"))
  (or (and d (parse-config d)) (resolve-experience conn team)))

(define (experience-save! conn p config)
  (require-perm conn p "settings:manage")
  (unless (hash? config) (error 'experience-save! "config must be an object"))
  (define team (principal-team-id p))
  (define key (let ([n (hash-ref config 'name #f)]) (if (and (string? n) (not (string=? n ""))) n (experience-active-key))))
  (upsert! conn team key "draft" config (principal-user-id p))
  #t)

;; promote the current draft to published (no draft → nothing to publish)
(define (experience-publish! conn p)
  (require-perm conn p "settings:manage")
  (define team (principal-team-id p))
  (define key (experience-active-key))
  (define d (row-config conn team key "draft"))
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
