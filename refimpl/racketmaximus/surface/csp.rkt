#lang racket/base

;; surface/csp.rkt — the Content-Security-Policy strings, and the closed
;; vocabulary that decides which one a plugin's bundle page is served under
;; (0.13.0).
;;
;; WHY IT IS A `surface` MODULE AND NOT IN server/: the manifest validator that
;; has to judge `"csp": "relaxed"` lives in domain/agent/plugins.rkt, and the two
;; routes that build the header live in server/main.rkt. A policy declared in
;; either one and asked about by the other makes a cycle out of a two-string
;; decision. `surface/` is the leaf both directions already share
;; (domain/authz/authz.rkt requires surface/messages.rkt for the same reason), so
;; it is the one place the vocabulary and the strings can live together — which
;; matters, because a mode added to the vocabulary without a policy behind it is
;; a plugin declaring something nothing implements.
;;
;; TWO POLICIES, AND THE STRICT ONE IS THE DEFAULT.
;;
;;   `STRICT-BUNDLE-CSP` — the console's own posture, applied to a plugin bundle
;;   page unless the plugin asks for otherwise: no inline script, no inline event
;;   handler, no `javascript:` URL, no CDN origin. Everything the page needs ships
;;   in the bundle. A plugin screen is runtime code the console LINKS to, so it is
;;   held to the same rule the console holds itself to; before this, the only
;;   policy a bundle got was the baseline, which permits inline script and is the
;;   looser half of a policy that exists to stop injected script.
;;
;;   `CONSOLE-CSP` — the baseline every other response carries, and the one a
;;   plugin receives when its manifest says `"csp": "relaxed"`. That is today's
;;   behaviour, kept reachable on purpose: a plugin written before this landed, or
;;   one whose author legitimately needs an inline block, declares the escape hatch
;;   rather than being broken by an upgrade. The declaration is per PLUGIN, not per
;;   page, and it is recorded on `GET /api/plugins` so an operator can see which
;;   installed plugins chose it.
;;
;; style-src keeps `'unsafe-inline'` in BOTH, deliberately: the console still
;; carries ~250 style attributes (a theme is written as inline custom properties,
;; and the party that would inject CSS has already had to inject HTML first),
;; and injected CSS is a far smaller prize than injected script. That is a
;; separate tranche, and it is the same call in both policies so a bundle does not
;; have to be re-styled to leave the relaxed mode.
;;
;; NO DATABASE, NO CONNECTION POOL, AND NO server/ REQUIRE, deliberately: a unit
;; test must not require server/kit.rkt — it instantiates the pool at module
;; instantiation, which reads DATABASE_URL there and fails in CI's sqlite leg where
;; that variable is the empty string (#123's rule). errors.rkt, peer.rkt and
;; startup.rkt are the modules that set this precedent.

(require web-server/http)

(provide PLUGIN-CSP-MODES plugin-csp-mode? PLUGIN-CSP-DEFAULT
         console-csp CONSOLE-CSP STRICT-BUNDLE-CSP bundle-csp
         csp-header bundle-csp-header)

;; A CLOSED VOCABULARY, checked in both directions by `test/plugin-csp-tests.rkt`:
;; `bundle-csp` refuses a mode it has no policy for, so a third mode invented in a
;; manifest fails the plugin's LOAD rather than silently receiving the strict
;; policy (or, worse, the relaxed one).
;;
;; `"strict"` is not spelled in a manifest: absence means strict, so the ordinary
;; plugin declares nothing. `"relaxed"` is the one value worth writing down.
(define PLUGIN-CSP-MODES '(strict relaxed))
(define PLUGIN-CSP-DEFAULT 'strict)

(define (plugin-csp-mode? v)
  (and (memq v PLUGIN-CSP-MODES) #t))

;; The console's own policy, and the baseline every other response carries. The
;; `inline?` argument is what distinguishes them: the console has no inline script
;; at all, so `script-src` is plain `'self'` there; every other response keeps
;; `'unsafe-inline'` because a plugin's page (or a beta funnel bundle) may
;; legitimately ship some.
;;
;; THE CONSOLE'S HISTORY IS WORTH KEEPING, because each step depended on the one
;; before it: the policy could not drop `'unsafe-inline'` while 141 inline event
;; handlers existed (an attribute cannot be nonced), so #27 moved them to
;; delegated listeners and the policy became a per-request NONCE over one inline
;; block; #110 r6 moved that block into static/console/*.js, which `'self'`
;; already permitted. A nonce only ever authorized OUR OWN inline script — it
;; protects nothing on its own — so with none left it authorizes nothing and is
;; gone.
(define (console-csp [inline? #f])
  (string-append "default-src 'self'; "
                 "script-src 'self'" (if inline? " 'unsafe-inline'" "") "; "
                 "style-src 'self' 'unsafe-inline'; "
                 "img-src 'self' data: blob:; font-src 'self' data:; connect-src 'self'; "
                 "frame-src 'self' blob: data:; frame-ancestors 'self'; form-action 'self'; "
                 "base-uri 'self'; object-src 'none'"))
(define CONSOLE-CSP (console-csp #t))

;; A plugin bundle page is served under this unless its manifest says `relaxed`.
;; Narrower than the baseline in the two ways that matter for somebody else's
;; code: `script-src` has no `'unsafe-inline'` and no nonce, so an inline block or
;; an `on*` attribute cannot run; and script, connections and frames reach this
;; origin only, so a CDN is not a way around it. `style-src` and `img-src` keep
;; the inline/data allowances the tree needs (a theme is written as inline custom
;; properties; a plugin logo may be a data URI). What is deliberately NOT here —
;; `font-src`, `frame-src`, `form-action` — falls back to `default-src 'self'`,
;; which is the same answer the baseline spells out.
(define STRICT-BUNDLE-CSP
  (string-append "default-src 'self'; "
                 "script-src 'self'; "
                 "style-src 'self' 'unsafe-inline'; "
                 "img-src 'self' data: blob:; "
                 "connect-src 'self'; "
                 "frame-ancestors 'self'; "
                 "base-uri 'self'; object-src 'none'"))

;; mode -> policy. An unknown mode RAISES rather than falling back: the fallback
;; would be the strict policy for a plugin that asked for something else, and the
;; failure would appear as a page that does not work with nothing naming why.
(define (bundle-csp mode)
  (case mode
    [(strict) STRICT-BUNDLE-CSP]
    [(relaxed) CONSOLE-CSP]
    [else (error 'bundle-csp "no Content-Security-Policy for mode ~s (one of ~a)"
                 mode PLUGIN-CSP-MODES)]))

(define (csp-header policy)
  (make-header #"Content-Security-Policy" (string->bytes/utf-8 policy)))

(define (bundle-csp-header mode)
  (csp-header (bundle-csp mode)))
