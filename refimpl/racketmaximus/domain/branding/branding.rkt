#lang racket/base

;; domain/branding/branding.rkt — instance branding: the title, tagline and logo
;; the console wears.
;;
;; This is INSTANCE-level, not team- or org-level, and it is deliberately a
;; different thing from the beta funnel's theme (domain/beta/experience.rkt). The
;; funnel is a public marketing page an operator skins per campaign; this is the
;; name on the product the whole instance signs into. They share the asset table
;; and nothing else.
;;
;; The read side is PUBLIC. It has to be: the sign-in screen shows the title,
;; tagline and logo to someone who by definition has no token yet. Nothing here is
;; a secret — it is the text on the front door — but that is why the write side is
;; `instance:manage` and why every field is bounded and escaped before it is
;; stored.
;;
;; Settings live in a generic key/value table rather than a `branding` table with
;; a column per field, because the next instance-wide setting should not need a
;; migration. The value is a JSON document under one key.

(require db-kit/portable racket/string json
         "../db/id.rkt")

(provide branding-get branding-set! branding-defaults
         branding-title-max branding-tagline-max)

(define KEY "branding")

(define branding-title-max 48)
(define branding-tagline-max 160)

;; The shipped identity. An instance that has never been touched reads exactly
;; this, so the console has a name before anyone configures one.
(define (branding-defaults)
  (hasheq 'title "Telemachus"
          'tagline ""          ; "" means: use the localized default in the UI
          'logo ""))           ; "" means: use the built-in Mentor mark

(define (clamp s n)
  (define t (string-trim (if (string? s) s "")))
  (if (> (string-length t) n) (substring t 0 n) t))

;; An asset id or nothing. Anything else is dropped rather than stored — this
;; value is interpolated into a URL by the client, so it is a whitelist.
(define (clean-logo v)
  (define s (if (string? v) (string-trim v) ""))
  (if (regexp-match? #px"^[0-9a-fA-F-]{8,64}$" s) s ""))

(define (normalize h)
  (define d (branding-defaults))
  (define (g k) (hash-ref h k (hash-ref d k)))
  (hasheq 'title   (let ([t (clamp (g 'title) branding-title-max)])
                     ;; a blank title would leave the header empty and unclickable
                     (if (string=? t "") (hash-ref d 'title) t))
          'tagline (clamp (g 'tagline) branding-tagline-max)
          'logo    (clean-logo (g 'logo))))

(define (branding-get conn)
  (define row (query-maybe-value conn "SELECT value FROM instance_settings WHERE key = ?" KEY))
  (cond
    [(not row) (branding-defaults)]
    [else
     ;; A hand-edited or truncated row must not take the console down; fall back.
     (with-handlers ([exn:fail? (lambda (_) (branding-defaults))])
       (define v (string->jsexpr (if (string? row) row (format "~a" row))))
       (if (hash? v) (normalize v) (branding-defaults)))]))

(define (branding-set! conn h)
  (define v (normalize (if (hash? h) h (hasheq))))
  (define blob (jsexpr->string v))
  ;; No ON CONFLICT: the dialects spell it differently and this is a single row.
  (define existing (query-maybe-value conn "SELECT key FROM instance_settings WHERE key = ?" KEY))
  (if existing
      (query-exec conn "UPDATE instance_settings SET value = ?, updated_at = ? WHERE key = ?"
                  blob (now-iso) KEY)
      (query-exec conn "INSERT INTO instance_settings (key, value, updated_at) VALUES (?, ?, ?)"
                  KEY blob (now-iso)))
  v)

(define (now-iso)
  (define d (seconds->date (current-seconds) #f))
  (define (p n) (if (< n 10) (format "0~a" n) (number->string n)))
  (format "~a-~a-~a ~a:~a:~a" (date-year d) (p (date-month d)) (p (date-day d))
          (p (date-hour d)) (p (date-minute d)) (p (date-second d))))
