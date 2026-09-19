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

(require db-kit/portable racket/string
         "../db/id.rkt"
         "../settings/settings.rkt")   ; the generic instance_settings accessor

(provide branding-get branding-set! branding-defaults
         org-branding-get org-branding-set! org-branding-clear! branding-for
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
  ;; `setting-ref` already turns an absent or corrupt row into the fallback, so a
  ;; mangled row reads as the shipped identity rather than 500-ing the PUBLIC
  ;; sign-in screen. `normalize` then clamps whatever survived.
  (define v (setting-ref conn KEY #f))
  (if v (normalize v) (branding-defaults)))

(define (branding-set! conn h)
  (setting-set! conn KEY (normalize (if (hash? h) h (hasheq)))))

;; ---- TEN-2d: a company's own branding -----------------------------------------
;; One more document under the same table, keyed `branding:<org-id>`. A company
;; that has set nothing wears the instance's branding, field for field — there is
;; no per-field merge, because a half-branded console (their title, our logo) is
;; the confusing outcome, and "unset" should look exactly like today.
(define (org-key org-id) (string-append KEY ":" org-id))

;; the company's own document, normalized, or #f when it has never set one
(define (org-branding-get conn org-id)
  (define v (and org-id (setting-ref conn (org-key org-id) #f)))
  (and v (normalize v)))

(define (org-branding-set! conn org-id h)
  (setting-set! conn (org-key org-id) (normalize (if (hash? h) h (hasheq)))))

(define (org-branding-clear! conn org-id)
  (setting-clear! conn (org-key org-id)))

;; what a request should wear: the company's if it has one, else the instance's
(define (branding-for conn org-id)
  (or (and org-id (org-branding-get conn org-id)) (branding-get conn)))
