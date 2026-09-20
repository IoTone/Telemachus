#lang racket/base

;; test/branding-tests.rkt — the branding document's THEME tokens (integrator
;; theming). The point of the theme is that a customer's palette is written once
;; and worn by the console and the funnel alike, so what is pinned here is the
;; vocabulary, the refusals, and the contrast floor that keeps a white-labelled
;; instance signable-into.
;;   raco test test/branding-tests.rkt

(require rackunit racket/string db-kit/portable db-kit/migrate
         "../domain/db/migrations.rkt"
         "db-fixture.rkt"
         "../domain/branding/branding.rkt")

(define (fresh) (define c (fresh-db #:migrate? #f)) (migrate! c all-migrations) c)
(define (theme-with . kvs)
  (for/fold ([h (theme-defaults)]) ([kv (in-list kvs)]) (hash-set h (car kv) (cdr kv))))

(test-case "the shipped theme is the console's own palette, and it passes its own gate"
  (check-false (theme-problem (theme-defaults)))
  (check-equal? (hash-ref (theme-defaults) 'bg) "#0b1a2b")
  ;; the defaults are what an untouched instance reads
  (define c (fresh))
  (check-equal? (hash-ref (branding-get c) 'theme) (theme-defaults))
  (disconnect c))

(test-case "tokens are validated by shape, and an unknown one is refused by name"
  ;; 3-digit hex is accepted; the rest of the palette has to come with it, because
  ;; flipping the ground alone leaves `muted` unreadable on it — as the gate says
  (check-false (theme-problem (theme-with '(bg . "#fff") '(surface . "#f4f6f8") '(ink . "#000000")
                                          '(muted . "#5b6b7c") '(brand . "#1f5c99") '(brandInk . "#ffffff"))))
  (check-regexp-match #rx"theme.bg must be a hex" (theme-problem (theme-with '(bg . "white"))))
  (check-regexp-match #rx"theme.bg must be a hex" (theme-problem (theme-with '(bg . "#12345"))))
  (check-regexp-match #rx"theme.brand must be a hex"
                      (theme-problem (theme-with '(brand . "url(javascript:alert(1))"))))
  (check-regexp-match #rx"radius" (theme-problem (theme-with '(radius . "2em"))))
  (check-regexp-match #rx"mode" (theme-problem (theme-with '(mode . "neon"))))
  (check-regexp-match #rx"fontBody" (theme-problem (theme-with '(fontBody . "Comic Sans"))))
  ;; a token that silently did nothing is how a customer concludes theming is broken
  (check-regexp-match #rx"unknown theme token \"accent\""
                      (theme-problem (hash-set (theme-defaults) 'accent "#ffffff"))))

(test-case "the contrast floor is enforced, and the refusal says which pair and by how much"
  ;; white on white: text on the background
  (define p (theme-problem (theme-with '(bg . "#ffffff") '(ink . "#fdfdfd") '(muted . "#111111")
                                       '(brand . "#222222") '(brandInk . "#ffffff"))))
  (check-regexp-match #rx"text on the background" p)
  (check-regexp-match #rx"1[.:]" p "the measured ratio is named")
  (check-regexp-match #rx"4.5:1" p "…and so is the minimum")
  ;; muted is checked too — it carries every timestamp and "no results" line
  (check-regexp-match #rx"muted text"
                      (theme-problem (theme-with '(muted . "#12253a"))))          ; muted == panel, on the dark bg
  ;; a button label that vanishes into its own button. The ground is MIXED from
  ;; brand and bg (what the console actually paints), so this is checked against
  ;; that mix, not against `brand`.
  (check-regexp-match #rx"button label"
                      (theme-problem (theme-with '(brand . "#6fa0d1") '(brandInk . "#4a6f92"))))
  (check-false (theme-problem (theme-with '(brand . "#6fa0d1") '(brandInk . "#ffffff")))
               "white on the shipped brand's button ground is fine")
  ;; a brand that disappears into the ground: 3:1, not 4.5 — it is UI, not body text
  (check-regexp-match #rx"brand colour on the background"
                      (theme-problem (theme-with '(brand . "#12253a"))))
  ;; a legitimate light theme passes
  (check-false (theme-problem (theme-with '(mode . "light") '(bg . "#ffffff") '(surface . "#f4f6f8")
                                          '(ink . "#16202b") '(muted . "#5b6b7c")
                                          '(brand . "#1f5c99") '(brandInk . "#ffffff")))))

(test-case "contrast-ratio is the WCAG number"
  (check-= (contrast-ratio "#ffffff" "#000000") 21.0 0.01)
  (check-= (contrast-ratio "#ffffff" "#ffffff") 1.0 0.001)
  (check-= (contrast-ratio "#fff" "#000") 21.0 0.01)          ; short form, same colour
  (check-true (> (contrast-ratio "#f2ede1" "#0b1a2b") 4.5) "the shipped ink on the shipped ground"))

(test-case "a stored theme survives a round trip; a mangled one reads as the default"
  (define c (fresh))
  (define custom (theme-with '(brand . "#c9a227") '(brandInk . "#132c46") '(radius . "12px")))
  (branding-set! c (hasheq 'title "Acme" 'theme custom))
  (check-equal? (hash-ref (branding-get c) 'theme) custom)
  (check-equal? (hash-ref (branding-get c) 'title) "Acme")
  ;; the READ side is forgiving where the write side refuses: the public sign-in
  ;; screen must render a default palette, never a 500
  (branding-set! c (hasheq 'title "Acme" 'theme (hasheq 'bg "not-a-colour" 'brand "#c9a227")))
  (define back (hash-ref (branding-get c) 'theme))
  (check-equal? (hash-ref back 'bg) (hash-ref (theme-defaults) 'bg) "an invalid token falls back")
  (check-equal? (hash-ref back 'brand) "#c9a227" "…and a valid one beside it is kept")
  (disconnect c))

(test-case "a company's theme is its own, and an unset one is the instance's WHOLE branding"
  (define c (fresh))
  (branding-set! c (hasheq 'title "Instance" 'theme (theme-with '(brand . "#6fa0d1"))))
  (define acme (theme-with '(brand . "#c9a227") '(brandInk . "#132c46")))
  (org-branding-set! c "org-1" (hasheq 'title "Acme" 'theme acme))
  (check-equal? (hash-ref (branding-for c "org-1") 'theme) acme)
  (check-equal? (hash-ref (branding-for c "org-2") 'title) "Instance" "no document = the instance's")
  (check-equal? (hash-ref (branding-for c "org-2") 'theme) (theme-with '(brand . "#6fa0d1")))
  (org-branding-clear! c "org-1")
  (check-equal? (hash-ref (branding-for c "org-1") 'title) "Instance")
  (disconnect c))
