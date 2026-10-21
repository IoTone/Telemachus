#lang racket/base

;; server/api/branding.rkt — instance branding, its logo, and a company's own
;; branding (TEN-2d)
;;
;; Split out of main.rkt by #110 r3. The shared surface every handler here
;; needs — the pool, the request accessors, with-auth/with-mt, the response
;; constructors — is server/kit.rkt.

(provide ep-branding-get ep-branding-put ep-branding-logo
         ep-my-org-branding-get ep-my-org-branding-put
         ep-my-org-branding-clear ep-my-org-branding-logo)

(require web-kit
         (only-in "../../domain/authz/authz.rkt" audit! principal-user-id require-perm)
         (only-in "../../domain/beta/assets.rkt" asset-store!)
         (only-in "../../domain/branding/branding.rkt" branding-get branding-set! org-branding-clear! org-branding-get org-branding-set! theme-problem)
         "../kit.rkt")

;; ---- instance branding (Admin > Branding) --------------------------------------
;; READ IS PUBLIC, and has to be: the sign-in screen renders the title, tagline and
;; logo for someone who has no token yet. It is the text on the front door.
(define (with-logo-url b)
  (hash-set b 'logoUrl (let ([id (hash-ref b 'logo "")])
                         (if (string=? id "") "" (string-append "/api/beta/asset/" id)))))

(define (ep-branding-get req)
  ;; TEN-2d: on a company's hostname, or for a company's signed-in user, the
  ;; company's own branding when it has one; the instance's otherwise
  (define org (request-org req))
  (define own (and org (org-branding-get db-conn org)))
  (json-response (hash-set (with-logo-url (or own (branding-get db-conn)))
                           'scope (if own "org" "instance"))))

;; A theme is refused, not clamped: an unknown token or an unreadable colour pair
;; comes back as a 400 naming it. Clamping would leave the operator looking at a
;; palette they did not ask for, wondering which half of it took.
(define (branding-theme-problem b)
  (let ([th (hash-ref b 'theme #f)])
    (and th (not (eq? th 'null)) (theme-problem th))))

(define (ep-branding-put req)
  (with-auth req (lambda (p)
    (require-perm db-conn p "instance:manage")
    (define b (let ([x (read-json-body req)]) (if (hash? x) x (hasheq))))
    (cond
      [(branding-theme-problem b) => (lambda (bad) (err bad 400))]
      [else (json-response (branding-set! db-conn b))]))))

;; The logo rides the existing asset table and is served by the existing PUBLIC
;; /api/beta/asset/<id> route — one asset mechanism, not two.

(define (ep-branding-logo req)
  (with-auth req (lambda (p)
    (require-perm db-conn p "instance:manage")
    (with-handlers ([exn:fail:user? (lambda (e) (err (exn-message e) 400))])
      (define b (read-json-body req))
      (define id (asset-store! db-conn p #:mime (fmt b 'mime) #:filename (fmt b 'filename)
                               #:data-base64 (fmt b 'data)))
      (define cur (branding-get db-conn))
      (json-response (hasheq 'ok #t 'id id 'url (string-append "/api/beta/asset/" id)
                             'branding (branding-set! db-conn (hash-set cur 'logo id)))
                     #:code 201)))))

;; ---- TEN-2d: a company's own branding -------------------------------------------
;; What the console wears on the company's hostname and for its signed-in users.
;; `own: false` says the company has set nothing and is wearing the instance's.
(define (ep-my-org-branding-get req)
  (with-mt req (lambda ()
    (with-auth req (lambda (p)
      (require-perm db-conn p "org:read")
      (define own (org-branding-get db-conn (caller-org p)))
      (json-response (hash-set (with-logo-url (or own (branding-get db-conn))) 'own (and own #t))))))))

(define (ep-my-org-branding-put req)
  (with-mt req (lambda ()
    (with-auth req (lambda (p)
      (require-perm db-conn p "org:manage")
      (define b (read-json-body req))
      (audit! db-conn #:action "org.branding" #:actor-type "user" #:actor-id (principal-user-id p)
              #:resource-type "org" #:resource-id (caller-org p))
      (cond
        [(branding-theme-problem (if (hash? b) b (hasheq))) => (lambda (bad) (err bad 400))]
        [else (json-response (hash-set (with-logo-url (org-branding-set! db-conn (caller-org p) (if (hash? b) b (hasheq)))) 'own #t))]))))))

(define (ep-my-org-branding-clear req)
  (with-mt req (lambda ()
    (with-auth req (lambda (p)
      (require-perm db-conn p "org:manage")
      (org-branding-clear! db-conn (caller-org p))
      (audit! db-conn #:action "org.branding.clear" #:actor-type "user" #:actor-id (principal-user-id p)
              #:resource-type "org" #:resource-id (caller-org p))
      (json-response (hash-set (with-logo-url (branding-get db-conn)) 'own #f)))))))

(define (ep-my-org-branding-logo req)
  (with-mt req (lambda ()
    (with-auth req (lambda (p)
      (require-perm db-conn p "org:manage")
      (with-handlers ([exn:fail:user? (lambda (e) (err (exn-message e) 400))])
         (define b (read-json-body req))
         (define id (asset-store! db-conn p #:mime (fmt b 'mime) #:filename (fmt b 'filename)
                                 #:data-base64 (fmt b 'data)))
         (define cur (or (org-branding-get db-conn (caller-org p)) (branding-get db-conn)))
         (json-response (hasheq 'ok #t 'id id 'url (string-append "/api/beta/asset/" id)
                               'branding (hash-set (org-branding-set! db-conn (caller-org p) (hash-set cur 'logo id)) 'own #t))
                       #:code 201)))))))
