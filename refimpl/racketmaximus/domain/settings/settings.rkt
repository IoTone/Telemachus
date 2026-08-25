#lang racket/base

;; domain/settings/settings.rkt — the generic accessor over `instance_settings`.
;;
;; Migration 0023 added a key/value table precisely so that the next instance-wide
;; setting would need code and not a migration (see domain/branding/branding.rkt,
;; which was the first one). This module is that code: one JSON document per key,
;; read and written the same way by every setting that follows.
;;
;; Two properties every caller inherits:
;;
;;   • A corrupt or hand-edited row NEVER takes the console down. Anything that
;;     does not parse as a JSON object reads as the caller's defaults. An operator
;;     who mangles a row gets the shipped behaviour back, not a 500 on the sign-in
;;     screen — and these rows are read by PUBLIC endpoints.
;;   • Writes are read-modify-write of a whole document, not a merge. A setting is
;;     one document; its owning module normalizes it before it is stored, so what
;;     is on disk is always already valid.
;;
;; Deliberately NOT cached. Locale resolution reads a setting on every request,
;; which sounds like it wants a cache until you price it: one indexed lookup on a
;; single-row key, next to the token resolution and permission queries the same
;; request already runs. A cache here would buy nothing measurable and would have
;; to be keyed by connection to stay correct under the test fixtures, which give
;; each test its own database.

(require db-kit/portable racket/string json)

(provide setting-ref setting-set! setting-clear!)

;; key -> jsexpr hash, or `default` if absent/corrupt/not-an-object.
(define (setting-ref conn key default)
  (define row (query-maybe-value conn "SELECT value FROM instance_settings WHERE key = ?" key))
  (cond
    [(or (not row) (sql-null? row)) default]
    [else
     (with-handlers ([exn:fail? (lambda (_) default)])
       (define v (string->jsexpr (if (string? row) row (format "~a" row))))
       (if (hash? v) v default))]))

;; Store one document. Returns what was stored.
(define (setting-set! conn key doc)
  (define blob (jsexpr->string doc))
  ;; No ON CONFLICT: the dialects spell upsert differently and this is one row.
  (define existing (query-maybe-value conn "SELECT key FROM instance_settings WHERE key = ?" key))
  (if existing
      (query-exec conn "UPDATE instance_settings SET value = ?, updated_at = ? WHERE key = ?"
                  blob (now-iso) key)
      (query-exec conn "INSERT INTO instance_settings (key, value, updated_at) VALUES (?, ?, ?)"
                  key blob (now-iso)))
  doc)

(define (setting-clear! conn key)
  (query-exec conn "DELETE FROM instance_settings WHERE key = ?" key))

;; Dialect-neutral timestamp: SQLite has no native one and PostgreSQL would
;; accept its own, so the column is TEXT and we write the same shape to both.
(define (now-iso)
  (define d (seconds->date (current-seconds) #f))
  (define (p n) (if (< n 10) (format "0~a" n) (number->string n)))
  (format "~a-~a-~a ~a:~a:~a" (date-year d) (p (date-month d)) (p (date-day d))
          (p (date-hour d)) (p (date-minute d)) (p (date-second d))))
