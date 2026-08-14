#lang racket/base
;; fixture: a clean surface module — every literal is t or no-i18n.
(require "../../domain/i18n/i18n.rkt")
(provide ok1 ok2)
(define (ok1 n) (t "fix.hello" #:default "Hi {n}" #:args (hasheq 'n n)))
(define (ok2) (no-i18n "SELECT 1"))     ; exempted, not user-facing
