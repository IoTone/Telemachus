#lang racket/base

;; domain/mail/templates.rkt — the closed set of messages this platform may send
;; to somebody who is not a user.
;;
;; WHY A REGISTRY AND NOT A SUBJECT AND A BODY. An email API a plugin can hand
;; arbitrary text and an arbitrary recipient is a spam cannon with the instance's
;; own From identity behind it, and the From address is the one thing every
;; deployment shares. So a caller names a TEMPLATE and hands over ids, and the
;; words are here. That is the same rule `mail-notify!` follows for a
;; notification, applied to a recipient who has no account.
;;
;; A TEMPLATE IS LOCALIZED, AND THE LOCALE COMES FROM THE RECIPIENT. The composer
;; runs in the delivery path with no request, so there is no `Accept-Language` to
;; read: `with-locale` loads the catalog for the contact's own language and
;; parameterizes `current-localizer` around the render. `t` is the one lookup, so
;; a missing translation falls back through the chain to English and then to the
;; inline default, exactly as every other string in the tree does.
;;
;; A MISSING DATA KEY IS A REFUSAL, NOT A `{what}` IN SOMEBODY'S INBOX. Each
;; template declares the keys it needs, and `template-render` checks them before
;; it composes. A message that reads "Document request: {what}" is worse than one
;; that was never sent, because the sender believes it went.
;;
;; THE LINK IS THE ACTION. Every template takes a `link`, and the message says
;; what it is for. That is what removes the need for attachments and for inbound
;; reply parsing: the recipient acts in a browser, and the platform records the
;; action.

(require racket/string
         json
         "../i18n/i18n.rkt"
         "../../config.rkt")

(provide EXTERNAL-TEMPLATES template? template-keys template-render with-locale
         notification-subject notification-body)

;; id -> (list required-keys builder), where builder : (hashof symbol string) -> (values subject body).
;;
;; A CLOSED VOCABULARY, checked in both directions by the test: every id here is
;; reachable, and an id that is not here is refused rather than composed.
(define EXTERNAL-TEMPLATES
  (list
   (cons (no-i18n "document_request")
         (list '(what from_name org_name link)
               (lambda (d)
                 (define args (hasheq 'what (hash-ref d 'what)
                                      'from_name (hash-ref d 'from_name)
                                      'org_name (hash-ref d 'org_name)
                                      'link (hash-ref d 'link)))
                 (values
                  (t "mail.document_request.subject"
                     #:default "Document request: {what}"
                     #:args args)
                  (string-join
                   (list
                    (t "mail.document_request.body"
                       #:default "{from_name} at {org_name} has asked for a document."
                       #:args args)
                    (no-i18n "")
                    (t "mail.document_request.what"
                       #:default "Requested: {what}"
                       #:args args)
                    (no-i18n "")
                    (t "mail.document_request.link"
                       #:default "Open this link to send it: {link}"
                       #:args args)
                    (no-i18n "")
                    (t "mail.document_request.reply"
                       #:default "Reply to this message to reach {from_name} directly."
                       #:args args)
                    (t "mail.document_request.footer"
                       #:default "Sent on behalf of {org_name}."
                       #:args args))
                   (no-i18n "\n"))))))))

(define (template? id)
  (and (string? id) (assoc id EXTERNAL-TEMPLATES) #t))

(define (template-keys id)
  (define e (assoc id EXTERNAL-TEMPLATES))
  (and e (cadr e)))

;; -> (values subject body). Refuses an unknown id and a missing key, because both
;; are programming errors rather than conditions a recipient should ever see.
(define (template-render id data)
  (define e (assoc id EXTERNAL-TEMPLATES))
  (unless e (error 'template-render (no-i18n "unknown external template: ~a") id))
  (define required (cadr e))
  (for ([k (in-list required)])
    (define v (hash-ref data k #f))
    (unless (and (string? v) (not (string=? (string-trim v) (no-i18n ""))))
      (error 'template-render (no-i18n "template ~a needs a non-empty ~a") id k)))
  ((caddr e) data))

;; ---- the notification's wrapper words ----------------------------------------
;; The SENTENCE comes from `describe.rkt` and is already localized there; these are
;; the words around it. They live here rather than in `mail.rkt` because this
;; module is a surface the localization gate scans and `mail.rkt` is mostly SQL.
(define (notification-subject sentence team-name)
  (if team-name
      (t "mail.notification.subject_team" #:default "[{team}] {sentence}"
         #:args (hasheq 'team team-name 'sentence sentence))
      sentence))

(define (notification-body sentence link)
  (string-join
   (append
    (list sentence (no-i18n ""))
    (if link
        (list link (no-i18n ""))
        (list (t "mail.notification.nolink"
                 #:default "This instance has no base URL configured, so there is no link to follow — an operator can set one in Admin > Email.")
              (no-i18n "")))
    (list (t "mail.notification.signature" #:default "— TMach")
          (t "mail.notification.why"
             #:default "You are receiving this because notifications are on for your account.")
          (t "mail.notification.off"
             #:default "Turn them off under your own profile in the console.")))
   (no-i18n "\n")))

;; Run `thunk` with the catalog for `locale` as the current localizer. A locale
;; that has no catalog falls back to the empty localizer, which resolves every key
;; to its inline English default — the same degradation `localizer-for` gives a
;; request, and the reason a template is written with `#:default` rather than
;; relying on the catalog.
(define (with-locale locale thunk)
  (define L
    (with-handlers ([exn:fail? (lambda (_) empty-localizer)])
      (load-localizer (locales-root) #:locale (if (and (string? locale) (not (string=? locale (no-i18n ""))))
                                                  locale
                                                  (no-i18n "en")))))
  (parameterize ([current-localizer L]) (thunk)))
