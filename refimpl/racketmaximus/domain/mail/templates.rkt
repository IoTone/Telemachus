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

(provide EXTERNAL-TEMPLATES template? template-render with-locale
         notification-subject notification-body
         verification-subject verification-body
         reset-subject reset-body
         invitation-subject invitation-body)

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

;; -> (values subject body). Refuses an unknown id and a missing key, because both
;; are caller errors rather than conditions a recipient should ever see.
;;
;; A USER ERROR, not a plain one: the dispatcher maps `exn:fail:user?` to a 400
;; carrying the sentence, and a bare `error` becomes an opaque 500. A caller that
;; forgot one id in `data` is told which one; it is not told the server broke. The
;; same call `inbound-set!` and `contact-add!` make, for the same reason.
(define (template-render id data)
  (define e (assoc id EXTERNAL-TEMPLATES))
  (unless e
    (raise-user-error 'template-render (no-i18n "unknown external template: ~a") id))
  (define required (cadr e))
  (for ([k (in-list required)])
    (define v (hash-ref data k #f))
    (unless (and (string? v) (not (string=? (string-trim v) (no-i18n ""))))
      (raise-user-error 'template-render (no-i18n "template ~a needs a non-empty ~a") id k)))
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

;; ---- the three transactional messages --------------------------------------
;; THE MESSAGES A NEW PERSON MEETS FIRST, and until this they were the last
;; English literals in the subsystem. They live here rather than in `mail.rkt` for
;; the reason the notification wrapper above does: THIS module is a surface the
;; localization gate scans, so every string in a mail is visible to the Localization
;; Manager. `mail.rkt` is mostly SQL and stays out of the list.
;;
;; THE LANGUAGE IS THE READER'S. Verification and reset go to an address on a user
;; row, so `users.locale` answers and `mail.rkt` passes it. An invitation goes to
;; somebody who has no account yet and therefore no locale at all, so it is read in
;; the INVITER's language: the sender is the person the platform knows, and the team
;; being described is theirs.

;; Paragraphs, blank-line separated. One logical line per paragraph rather than a
;; hand-wrapped one, because the body is base64 in transit (`encode-body` wraps the
;; transfer encoding, not this text) and a catalog value cannot hold a wrap that
;; survives a different language anyway.
(define (paragraphs ps) (string-join ps (no-i18n "\n\n")))

;; The signature every message in this subsystem ends with, and the SAME key the
;; notification uses: it is the same line, translated once.
(define (signature) (t "mail.notification.signature" #:default "— TMach"))

;; THE TOKEN IS THE ONLY ACTIONABLE THING when no base URL is configured, which is
;; why the code branch is here and not in `mail.rkt`: the sentence that carries the
;; token is copy like every other sentence.
(define (verification-subject)
  (t "mail.verify.subject" #:default "Confirm your TMach notification address"))

(define (verification-body #:link [link #f] #:token token)
  (paragraphs
   (append
    (list (t "mail.verify.intro"
             #:default "Somebody — probably you — asked for this address to receive TMach notifications. Confirm it to turn them on."))
    (if link
        (list link)
        (list (t "mail.verify.code" #:default "Confirm it with this code: {token}"
                 #:args (hasheq 'token token))))
    (list (t "mail.verify.ignore"
             #:default "If you did not ask for this, ignore this message — nothing is sent to an address that has not been confirmed.")
          (signature)))))

;; The expiry is a KEY PER FORM rather than a plural inside one sentence. English
;; needs "an hour" and "3 hours", Japanese needs neither, and a catalog cannot hold
;; a rule.
(define (reset-ttl ttl-hours)
  (if (= ttl-hours 1)
      (t "mail.reset.ttl_one" #:default "an hour")
      (t "mail.reset.ttl_many" #:default "{n} hours"
         #:args (hasheq 'n (number->string ttl-hours)))))

(define (reset-subject)
  (t "mail.reset.subject" #:default "Reset your TMach password"))

(define (reset-body #:link [link #f] #:token token #:ttl-hours [ttl-hours 1])
  (paragraphs
   (append
    (list (t "mail.reset.intro"
             #:default "Somebody asked to reset the TMach password for this address. This link works once, and stops working in {ttl}."
             #:args (hasheq 'ttl (reset-ttl ttl-hours))))
    (if link
        (list link)
        (list (t "mail.reset.code" #:default "Use this code to set a new password: {token}"
                 #:args (hasheq 'token token))))
    (list (t "mail.reset.ignore"
             #:default "If it was not you, ignore this message. Nothing has changed and nothing will: your current password still works, and this link does nothing until somebody uses it.")
          (signature)))))

(define (invitation-ttl ttl-hours)
  (define days (max 1 (quotient ttl-hours 24)))
  (if (= days 1)
      (t "mail.invite.ttl_one" #:default "a day")
      (t "mail.invite.ttl_many" #:default "{n} days"
         #:args (hasheq 'n (number->string days)))))

(define (invitation-subject #:inviter inviter #:team team)
  (t "mail.invite.subject" #:default "{inviter} invited you to join {team} on TMach"
     #:args (hasheq 'inviter inviter 'team team)))

(define (invitation-body #:inviter inviter #:team team #:link [link #f] #:token token
                         #:ttl-hours [ttl-hours 72])
  (paragraphs
   (append
    (list (t "mail.invite.intro"
             #:default "{inviter} has invited you to join {team} on TMach. Follow this link to choose a password and sign in. It works once, and stops working in {expiry}."
             #:args (hasheq 'inviter inviter 'team team
                            'expiry (invitation-ttl ttl-hours))))
    (if link
        (list link)
        (list (t "mail.invite.code" #:default "Use this code on the sign-in screen: {token}"
                 #:args (hasheq 'token token))))
    (list (t "mail.invite.ignore"
             #:default "If you were not expecting this, ignore this message. No account is created for you until you follow the link.")
          (signature)))))

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
