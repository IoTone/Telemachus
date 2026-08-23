#lang racket/base

;; domain/features/features.rkt — per-team feature activation (slice 24).
;; Absence of a row means enabled (default on). A team manager can turn a whole
;; feature off; the endpoints refuse it and the UI hides its tab.

(require db-kit/portable "../db/id.rkt")

(provide known-features feature-enabled? set-feature-enabled! features-for)

(define known-features '("chat" "agent" "translate" "search" "workflows"))

(define (feature-enabled? conn team-id feature)
  (define v (query-maybe-value conn
    "SELECT enabled FROM feature_settings WHERE team_id = ? AND feature = ?" team-id feature))
  (cond [(or (not v) (sql-null? v)) #t]          ; no row → enabled
        [else (not (zero? v))]))

(define (set-feature-enabled! conn team-id feature on?)
  (query-exec conn
    (string-append "INSERT INTO feature_settings (id, team_id, feature, enabled) VALUES (?, ?, ?, ?) "
                   "ON CONFLICT(team_id, feature) DO UPDATE SET enabled = excluded.enabled, updated_at = CURRENT_TIMESTAMP")
    (new-id) team-id feature (if on? 1 0)))

(define (features-for conn team-id)
  (for/list ([f (in-list known-features)])
    (hasheq 'feature f 'enabled (feature-enabled? conn team-id f))))
