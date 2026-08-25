#lang racket/base

;; surface/messages.rkt — user-facing strings, localized. A "surface" module:
;; every user-facing literal is wrapped in `t` (or `no-i18n`), so the linter and
;; `telemachus-localize extract` can see them.

(require "../domain/i18n/i18n.rkt")

(provide msg-forbidden msg-bootstrap-done msg-note-saved
         msg-unauthorized msg-already-init
         msg-beta-not-ready msg-beta-rate msg-beta-challenge msg-beta-verify
         msg-beta-email msg-beta-work-email msg-beta-name
         msg-beta-duplicate msg-beta-domain-cap msg-beta-thanks)

(define (msg-forbidden perm)
  (t "authz.forbidden" #:default "Forbidden: {perm}" #:args (hasheq 'perm perm)))

(define (msg-bootstrap-done user team)
  (t "authz.bootstrap_done"
     #:default "Created operator {user} and team {team}."
     #:args (hasheq 'user user 'team team)))

(define (msg-note-saved)
  (t "notes.saved" #:default "Note saved."))

(define (msg-unauthorized)
  (t "http.unauthorized" #:default "Authentication required."))

(define (msg-already-init)
  (t "http.already_initialized" #:default "Already initialized."))

;; ---- beta funnel (slice 40+) -------------------------------------------------
;; The public sign-up page is the one surface where a visitor may read ONLY the
;; localized copy and never see the console. Its refusals were bare English
;; literals, so a Japanese applicant who mistyped an email got an English error on
;; an otherwise Japanese page — the most likely message on the page, untranslated.
;; These are shipped product strings (unlike the funnel's operator-authored copy,
;; which is an `i18n` overlay on the experience document), so they belong here.

(define (msg-beta-not-ready)
  (t "beta.not_ready" #:default "instance not initialized"))

(define (msg-beta-rate)
  (t "beta.rate_limited" #:default "too many requests — please slow down"))

(define (msg-beta-challenge)
  (t "beta.challenge_expired" #:default "invalid or expired challenge — reload the page"))

(define (msg-beta-verify)
  (t "beta.verify_failed" #:default "verification failed — reload the page"))

(define (msg-beta-email)
  (t "beta.email_invalid" #:default "a valid email is required"))

(define (msg-beta-work-email)
  (t "beta.email_disposable" #:default "please use a work email address"))

(define (msg-beta-name)
  (t "beta.name_required" #:default "name is required"))

(define (msg-beta-duplicate)
  (t "beta.duplicate" #:default "we already have your request — we'll be in touch"))

(define (msg-beta-domain-cap)
  (t "beta.domain_cap" #:default "too many requests from your organization — please reach out directly"))

;; Also the honeypot's fake success: it must be indistinguishable from the real
;; one, which means it has to be localized in exactly the same way.
(define (msg-beta-thanks)
  (t "beta.thanks" #:default "Thanks — your request is in review."))
