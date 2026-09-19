#lang racket/base

;; domain/branding/branding.rkt — instance branding: the title, tagline, logo and
;; THEME the console wears.
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
;;
;; THE THEME (integrator theming): the same token vocabulary the beta funnel's
;; experience document already uses — brand, brandInk, bg, surface, ink, muted,
;; radius, mode, fontBody — so an operator who has skinned the funnel knows this
;; one, and so a customer's palette is written once. The console maps them onto
;; its own CSS custom properties; the funnel maps them onto `--bx-*`. Nothing here
;; ships CSS: a token is a value, never a declaration, which is why every one is
;; validated against a narrow pattern rather than escaped.
;;
;; CONTRAST IS ENFORCED, not advised. The funnel's editor warns while an operator
;; types; here the server refuses, because this is the screen people sign in on
;; and a white-labelled instance that themed its own sign-in link into invisibility
;; has no way back in through the UI. WCAG AA: 4.5:1 for text, 3:1 for the brand
;; against its ground.

(require db-kit/portable racket/string
         "../db/id.rkt"
         "../settings/settings.rkt")   ; the generic instance_settings accessor

(provide branding-get branding-set! branding-defaults
         org-branding-get org-branding-set! org-branding-clear! branding-for
         branding-title-max branding-tagline-max
         theme-defaults theme-problem theme-tokens contrast-ratio)

(define KEY "branding")

(define branding-title-max 48)
(define branding-tagline-max 160)

;; The shipped identity. An instance that has never been touched reads exactly
;; this, so the console has a name before anyone configures one.
;; The shipped Mentor palette, token by token. A theme that sets nothing reads
;; exactly this, so "unthemed" and "themed back to default" are the same document.
(define (theme-defaults)
  (hasheq 'bg "#0b1a2b" 'surface "#12253a" 'ink "#f2ede1" 'muted "#93a4b8"
          'brand "#6fa0d1" 'brandInk "#ffffff" 'radius "8px" 'mode "dark"
          'fontBody "System"))

(define theme-tokens (sort (map symbol->string (hash-keys (theme-defaults))) string<?))

(define (branding-defaults)
  (hasheq 'title "Telemachus"
          'tagline ""          ; "" means: use the localized default in the UI
          'logo ""             ; "" means: use the built-in Mentor mark
          'theme (theme-defaults)))

(define (clamp s n)
  (define t (string-trim (if (string? s) s "")))
  (if (> (string-length t) n) (substring t 0 n) t))

;; An asset id or nothing. Anything else is dropped rather than stored — this
;; value is interpolated into a URL by the client, so it is a whitelist.
(define (clean-logo v)
  (define s (if (string? v) (string-trim v) ""))
  (if (regexp-match? #px"^[0-9a-fA-F-]{8,64}$" s) s ""))

;; ---- the theme ---------------------------------------------------------------

(define (hex-color? v) (and (string? v) (regexp-match? #px"^#([0-9a-fA-F]{3}|[0-9a-fA-F]{6})$" (string-trim v))))
(define (radius? v) (and (string? v) (regexp-match? #px"^[0-9]{1,2}px$" (string-trim v))))
(define FONTS '("System" "Serif" "Mono" "Rounded"))       ; the console's own stacks, not a web font
(define MODES '("dark" "light"))

;; WCAG 2.x relative luminance and contrast ratio — the same arithmetic the
;; funnel's editor does in the browser, here so the refusal is the server's.
(define (luminance hex)
  (define h (string-downcase (substring (string-trim hex) 1)))
  (define full (if (= (string-length h) 3)
                   (apply string-append (for/list ([c (in-string h)]) (string c c)))
                   h))
  (define chans
    (for/list ([i (in-list '(0 2 4))])
      (define c (/ (string->number (substring full i (+ i 2)) 16) 255.0))
      (if (<= c 0.03928) (/ c 12.92) (expt (/ (+ c 0.055) 1.055) 2.4))))
  (+ (* 0.2126 (car chans)) (* 0.7152 (cadr chans)) (* 0.0722 (caddr chans))))

;; The console does not paint a button with `brand` — it paints it with a ground
;; mixed from brand toward the DARK side of the theme, the same `color-mix` the
;; client applies (BUTTON-MIX must equal --accent2's percentage in
;; static/index.html). Which side is dark is MEASURED, not declared: mixing toward
;; the background deepens a brand on a dark theme and washes it out on a light
;; one, and an operator who sets light colours while `mode` still says "dark"
;; should still get a legible button rather than a refusal about a token they did
;; not think they were setting. Checking the label against `brand` itself would
;; fail themes that render perfectly well and pass ones that do not.
(define BUTTON-MIX 0.50)
(define (hex->rgb hex)
  (define h (string-downcase (substring (string-trim hex) 1)))
  (define full (if (= (string-length h) 3)
                   (apply string-append (for/list ([c (in-string h)]) (string c c)))
                   h))
  (for/list ([i (in-list '(0 2 4))]) (string->number (substring full i (+ i 2)) 16)))
(define (mix-hex a b p)          ; p of a, (1-p) of b, in sRGB like color-mix
  (apply string-append "#"
         (for/list ([x (in-list (hex->rgb a))] [y (in-list (hex->rgb b))])
           (define v (inexact->exact (round (+ (* p x) (* (- 1 p) y)))))
           (define h (number->string (max 0 (min 255 v)) 16))
           (if (= (string-length h) 1) (string-append "0" h) h))))

;; whichever of two colours is the dark one — the theme's "shadow" direction
(define (darker a b) (if (< (luminance a) (luminance b)) a b))

(define (contrast-ratio a b)
  (define la (luminance a)) (define lb (luminance b))
  (/ (+ (max la lb) 0.05) (+ (min la lb) 0.05)))

;; A theme this instance will wear, or a string naming what is wrong with it.
;; Unknown keys are refused rather than ignored: a token that silently does
;; nothing is how a customer concludes the theming does not work.
(define (theme-problem h)
  (define d (theme-defaults))
  (define (val k) (let ([v (hash-ref h k (hash-ref d k))]) (if (string? v) (string-trim v) v)))
  (cond
    [(not (hash? h)) "theme must be an object"]
    [(for/first ([k (in-list (hash-keys h))] #:unless (hash-has-key? d k)) k)
     => (lambda (k) (format "unknown theme token ~s (known: ~a)" (symbol->string k) (string-join theme-tokens ", ")))]
    [(for/first ([k (in-list '(bg surface ink muted brand brandInk))] #:unless (hex-color? (val k))) k)
     => (lambda (k) (format "theme.~a must be a hex colour like #1a2b3c" k))]
    [(not (radius? (val 'radius))) "theme.radius must be a pixel length like 8px"]
    [(not (member (val 'mode) MODES)) (format "theme.mode must be one of ~a" (string-join MODES ", "))]
    [(not (member (val 'fontBody) FONTS)) (format "theme.fontBody must be one of ~a" (string-join FONTS ", "))]
    [else
     ;; the legibility floor. `muted` is checked too — it carries timestamps,
     ;; quota numbers and every "no results" line in the console.
     (define checks
       (list (list "text on the background"     (val 'ink)      (val 'bg)    4.5)
             (list "muted text on the background" (val 'muted)  (val 'bg)    4.5)
             (list "text on a panel"            (val 'ink)      (val 'surface) 4.5)
             (list "a button label on its button" (val 'brandInk)
                   (mix-hex (val 'brand) (darker (val 'ink) (val 'bg)) BUTTON-MIX) 4.5)
             (list "the brand colour on the background" (val 'brand) (val 'bg)  3.0)))
     (for/first ([c (in-list checks)] #:when (< (contrast-ratio (cadr c) (caddr c)) (cadddr c)))
       (format "~a is ~a:1 — the minimum is ~a:1, or people will not be able to read it"
               (car c)
               (real->decimal-string (contrast-ratio (cadr c) (caddr c)) 2)
               (real->decimal-string (cadddr c) 1)))]))

;; Read-side normalization is forgiving where the write side refuses: a token that
;; is somehow invalid in a stored row falls back to the shipped one, so a mangled
;; document renders the default palette instead of 500-ing the PUBLIC sign-in screen.
(define (normalize-theme v)
  (define d (theme-defaults))
  (define h (if (hash? v) v (hasheq)))
  (define (ok? k val)
    (case k
      [(radius) (radius? val)]
      [(mode) (member val MODES)]
      [(fontBody) (member val FONTS)]
      [else (hex-color? val)]))
  (for/fold ([out (hasheq)]) ([k (in-list (hash-keys d))])
    (define v* (let ([x (hash-ref h k #f)]) (and (string? x) (string-trim x))))
    (hash-set out k (if (and v* (ok? k v*)) v* (hash-ref d k)))))

(define (normalize h)
  (define d (branding-defaults))
  (define (g k) (hash-ref h k (hash-ref d k)))
  (hasheq 'title   (let ([t (clamp (g 'title) branding-title-max)])
                     ;; a blank title would leave the header empty and unclickable
                     (if (string=? t "") (hash-ref d 'title) t))
          'tagline (clamp (g 'tagline) branding-tagline-max)
          'logo    (clean-logo (g 'logo))
          'theme   (normalize-theme (g 'theme))))

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
