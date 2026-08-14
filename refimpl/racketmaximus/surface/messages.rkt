#lang racket/base

;; surface/messages.rkt — user-facing strings, localized. A "surface" module:
;; every user-facing literal is wrapped in `t` (or `no-i18n`), so the linter and
;; `telemachus-localize extract` can see them.

(require "../domain/i18n/i18n.rkt")

(provide msg-forbidden msg-bootstrap-done msg-note-saved
         msg-unauthorized msg-already-init)

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
