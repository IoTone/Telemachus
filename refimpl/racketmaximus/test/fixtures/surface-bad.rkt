#lang racket/base
;; fixture: a dirty surface module — one bare user-facing literal.
(require "../../domain/i18n/i18n.rkt")
(provide bad1)
(define (bad1) (string-append "Unlocalized!" (t "fix.ok" #:default "ok")))
