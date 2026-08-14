#lang racket/base

;; surface/greetings.rkt — more localized surface strings, incl. an ICU plural.

(require "../domain/i18n/i18n.rkt")

(provide greet inbox-summary)

(define (greet name)
  (t "greeting.hello" #:default "Hello, {name}!" #:args (hasheq 'name name)))

(define (inbox-summary count)
  (t "inbox.summary"
     #:default "You have {count, plural, one {# new message} other {# new messages}}."
     #:args (hasheq 'count count)))
