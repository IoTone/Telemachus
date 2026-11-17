#lang racket/base

;; test/email-inbound-tests.rkt — the one optional mailbox, and the two consumers
;; that may read it.
;;
;; The subject is the CONFIGURATION, not the poller: an instance may run neither
;; consumer, one, or both, and the shipped state is `none` because an upgrade must
;; not start reading a mailbox. The cases below are the ones that make that safe —
;; a mode that needs a host and has none, a consumer nothing implements, a
;; password that must not be readable, and the only way back to the shipped state.
;;
;;   raco test test/email-inbound-tests.rkt
;;   DATABASE_URL="postgres://…" raco test test/email-inbound-tests.rkt

(require rackunit db-kit/portable db-kit/migrate
         racket/string json racket/runtime-path racket/file
         "../domain/db/migrations.rkt"
         "db-fixture.rkt"
         "../domain/authz/authz.rkt"
         "../domain/mail/inbound.rkt")

;; Anchored at the MODULE, not at the working directory: `nix build` runs the
;; suite from somewhere else, and the registry case below reads a source file.
(define-runtime-path here ".")
(define ROOT (simplify-path (build-path here 'up)))

(define (fresh)
  (define conn (fresh-db #:migrate? #f))
  (migrate! conn all-migrations)
  conn)

(define (imap-doc #:consumers [consumers (hasheq 'bounces #t 'messages #f)] #:active [active #t])
  (hasheq 'mode "imap" 'host "imap.example.test" 'port 993 'security "tls"
          'username "bounce@example.test" 'password "s3cret" 'folder "INBOX"
          'consumers consumers 'active active))

;; ---- the shipped state ------------------------------------------------------
(test-case "an instance ships with no mailbox, and nothing is read"
  (define c (fresh))
  (check-false (inbound-ref c))
  (check-false (inbound-configured? c))
  (check-false (inbound-consumer-on? c "bounces"))
  (check-false (inbound-consumer-on? c "messages"))
  (close-db! c))

;; ---- the modes --------------------------------------------------------------
(test-case "a mode that reads a mailbox needs a host and a port"
  (define c (fresh))
  (check-exn exn:fail? (lambda () (inbound-set! c (hasheq 'mode "imap" 'port 993))))
  (check-exn exn:fail? (lambda () (inbound-set! c (hasheq 'mode "imap" 'host "h.test"))))
  ;; `none` needs neither, and it is a mode rather than an absent row so the
  ;; console has one thing to draw
  (check-true (and (inbound-set! c (hasheq 'mode "none")) #t))
  (check-false (inbound-configured? c))
  (close-db! c))

(test-case "an unknown field and an unknown consumer are refused, not dropped"
  (define c (fresh))
  (check-exn exn:fail? (lambda () (inbound-set! c (hasheq 'mode "none" 'imap_host "h"))))
  (check-exn exn:fail?
             (lambda () (inbound-set! c (imap-doc #:consumers (hasheq 'bounces #t 'invoices #t)))))
  (check-false (inbound-ref c) "a refused write leaves no row")
  (close-db! c))

;; ---- the credential ---------------------------------------------------------
(test-case "the password is sealed at rest and never in a read"
  (define c (fresh))
  (define m (inbound-set! c (imap-doc)))
  (check-true (hash-ref m 'has_password))
  (check-false (hash-has-key? m 'password) "the read carries no password")
  (check-equal? (inbound-password c) "s3cret")
  ;; THE SEALING ITSELF IS `sealed-column-tests.rkt`'s SUBJECT, and with no
  ;; `TMACH_SECRET_KEY` the documented behaviour is to store the value in the
  ;; clear — which the transport's own test records. What matters here is the
  ;; REGISTRY: a sealed column outside `CREDENTIAL-SECRETS` is skipped by `rewrap`,
  ;; so a key rotation leaves it unopenable and nothing at runtime notices. A
  ;; static check, in the shape `feed-tests.rkt` uses for the same reason.
  (define src (file->string (build-path ROOT "cli" "telemachus-secrets.rkt")))
  (check-true (regexp-match? (regexp "\"inbound_mailbox\" +\"password\"") src)
              "inbound_mailbox.password must be in CREDENTIAL-SECRETS")
  ;; AN ABSENT PASSWORD LEAVES THE STORED ONE ALONE, so an edit to the folder
  ;; cannot silently clear the credential
  (void (inbound-set! c (hasheq 'mode "imap" 'host "imap.example.test" 'port 993
                                'security "tls" 'username "bounce@example.test"
                                'folder "Processed" 'consumers (hasheq 'bounces #t) 'active #t)))
  (check-equal? (inbound-password c) "s3cret")
  (check-equal? (hash-ref (inbound-ref c) 'folder) "Processed")
  (close-db! c))

;; ---- the consumers ----------------------------------------------------------
(test-case "the consumers are a closed vocabulary and both default to off"
  (define c (fresh))
  (define m (inbound-set! c (imap-doc #:consumers (hasheq))))
  (check-false (hash-ref (hash-ref m 'consumers) 'bounces))
  (check-false (hash-ref (hash-ref m 'consumers) 'messages))
  (check-false (inbound-consumer-on? c "bounces"))
  (void (inbound-set! c (imap-doc #:consumers (hasheq 'bounces #t))))
  (check-true (inbound-consumer-on? c "bounces"))
  (check-false (inbound-consumer-on? c "messages"))
  (close-db! c))

(test-case "active: false is still configured, and nothing is read"
  (define c (fresh))
  (void (inbound-set! c (imap-doc #:active #f)))
  (check-true (and (inbound-ref c) #t) "the configuration is kept")
  (check-false (inbound-configured? c) "but the poller does not run")
  (check-false (inbound-consumer-on? c "bounces"))
  (close-db! c))

;; ---- the way back -----------------------------------------------------------
(test-case "delete is the only way back to the shipped state"
  (define c (fresh))
  (void (inbound-set! c (imap-doc)))
  (check-true (inbound-configured? c))
  (inbound-clear! c)
  (check-false (inbound-ref c))
  (check-false (inbound-configured? c))
  (close-db! c))

;; ---- the reply address ------------------------------------------------------
(test-case "the reply address is the token only when something reads the mailbox"
  (define c (fresh))
  ;; no mailbox: the person
  (check-equal? (inbound-reply-address c "example.test" "tk_abc" "person@example.test")
                "person@example.test")
  ;; a mailbox with the message consumer on: the token
  (void (inbound-set! c (imap-doc #:consumers (hasheq 'bounces #t 'messages #t))))
  (check-equal? (inbound-reply-address c "example.test" "tk_abc" "person@example.test")
                "reply+tk_abc@example.test")
  ;; the bounce consumer alone does not read replies, so the token would be a
  ;; dead end and the person's address is still the answer
  (void (inbound-set! c (imap-doc #:consumers (hasheq 'bounces #t 'messages #f))))
  (check-equal? (inbound-reply-address c "example.test" "tk_abc" "person@example.test")
                "person@example.test")
  (close-db! c))
