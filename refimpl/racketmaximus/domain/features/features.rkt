#lang racket/base

;; domain/features/features.rkt — feature activation at three layers (issue #63).
;;
;; This started as per-TEAM only (slice 24), and `docs/integrators-guide.md`
;; stated the gap rather than papering over it: an operator could not turn a
;; feature off for the whole instance, and on a multi-tenant box could not turn
;; one off for a company. Every new feature therefore shipped either on for
;; everyone or off until each team opted in.
;;
;; THE RESOLUTION ORDER IS SESS-4's, NOT BRANDING's, and the difference is the
;; one decision in this module. A feature switch is a CONTROL: the instance owns
;; the floor, an org may tighten it for its own teams, a team may tighten
;; further — and nobody may LOOSEN what a layer above them disabled. A team
;; cannot turn on what the instance turned off, which is the whole point of
;; having an instance switch at all.
;;
;; That is deliberately asymmetric with branding, where the org's document wins
;; WHOLE: branding is cosmetic and a company's own look should replace the
;; instance's, while this governs whether an endpoint answers. The same call
;; session policy made, for the same reason, and the two now read alike.
;;
;; ABSENCE MEANS ENABLED AT EVERY LAYER, so an instance that has configured
;; nothing behaves exactly as it did before this existed. Nothing is backfilled
;; and there is no migration: the instance and org documents live in
;; `instance_settings`, beside branding, localization policy, session policy,
;; model roles, repo fields and retention.

(require db-kit/portable racket/string "../db/id.rkt"
         (only-in "../settings/settings.rkt" setting-ref setting-set!)
         (only-in "../authz/authz.rkt" team-org))

(provide known-features feature-enabled? set-feature-enabled! features-for
         feature-scope
         instance-features instance-features-set!
         org-features org-features-set!
         feature-problem)

(define known-features '("chat" "agent" "translate" "search" "workflows"))

(define INSTANCE-FEATURES-KEY "features:instance")
(define (org-features-key org-id) (string-append "features:org:" org-id))

;; ---- the two upper layers ----------------------------------------------------
;; A document of `{"<feature>": false}`. Only `false` means anything: a key that
;; is absent, or true, is "this layer does not object". Storing the positives
;; would make "I have not decided" and "I have decided yes" the same row, which
;; is the distinction session policy spells out with an explicit null.
;; `hash-ref`'s default is #f and a stored `false` is ALSO #f, so the two cannot
;; be told apart that way: the key's presence is asked first.
(define (blocks? doc feature)
  (define k (string->symbol feature))
  (and (hash-has-key? doc k) (eq? (hash-ref doc k) #f)))

(define (instance-features conn) (setting-ref conn INSTANCE-FEATURES-KEY (hasheq)))
(define (org-features conn org-id)
  (if org-id (setting-ref conn (org-features-key org-id) (hasheq)) (hasheq)))

;; An UNKNOWN feature is refused, not stored. A flag that silently does nothing is
;; how an operator concludes the switch is broken — the call an unknown theme
;; token and an unknown retention field both make.
(define (feature-problem doc)
  (cond
    [(not (hash? doc)) "a features document must be an object"]
    [else
     (for/or ([(k v) (in-hash doc)])
       (cond
         [(not (member (symbol->string k) known-features))
          (format "unknown feature '~a' — known features are: ~a"
                  k (string-join known-features ", "))]
         [(not (boolean? v))
          (format "feature '~a' must be true or false" k)]
         [else #f]))]))

(define (instance-features-set! conn doc)
  (define p (feature-problem doc))
  (when p (error 'features "~a" p))
  (setting-set! conn INSTANCE-FEATURES-KEY doc)
  doc)

(define (org-features-set! conn org-id doc)
  (define p (feature-problem doc))
  (when p (error 'features "~a" p))
  (setting-set! conn (org-features-key org-id) doc)
  doc)

;; ---- the team layer, unchanged -------------------------------------------------
(define (team-blocks? conn team-id feature)
  (define v (query-maybe-value conn
    "SELECT enabled FROM feature_settings WHERE team_id = ? AND feature = ?" team-id feature))
  (and v (not (sql-null? v)) (zero? v)))

(define (set-feature-enabled! conn team-id feature on?)
  (query-exec conn
    (string-append "INSERT INTO feature_settings (id, team_id, feature, enabled) VALUES (?, ?, ?, ?) "
                   "ON CONFLICT(team_id, feature) DO UPDATE SET enabled = excluded.enabled, updated_at = CURRENT_TIMESTAMP")
    (new-id) team-id feature (if on? 1 0)))

;; ---- the effective answer ------------------------------------------------------
;; ALL THREE must allow. The order of the checks is the order an operator would
;; want named: the layer furthest from them first, because it is the one they
;; cannot change from where they are standing.
(define (feature-scope conn team-id feature)
  (cond
    [(blocks? (instance-features conn) feature) "instance"]
    [(blocks? (org-features conn (team-org conn team-id)) feature) "org"]
    [(team-blocks? conn team-id feature) "team"]
    [else #f]))

(define (feature-enabled? conn team-id feature)
  (not (feature-scope conn team-id feature)))

;; `disabled_by` is WHICH layer said no — absent when the feature is on. The
;; question an operator asks is "why is this tab missing", and three documents to
;; diff by hand is a poor answer (retention-sources' rule, and branding's
;; `scope`). A team admin seeing "instance" knows not to look in their own
;; settings, which is the whole value of the field.
(define (features-for conn team-id)
  (for/list ([f (in-list known-features)])
    (define by (feature-scope conn team-id f))
    (define base (hasheq 'feature f 'enabled (not by)))
    (if by (hash-set base 'disabled_by by) base)))
