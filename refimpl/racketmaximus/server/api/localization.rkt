#lang racket/base

;; server/api/localization.rkt — the public UI catalog, the instance locale
;; policy, the Localization Manager
;;
;; Split out of main.rkt by #110 r3. The shared surface every handler here
;; needs — the pool, the request accessors, with-auth/with-mt, the response
;; constructors — is server/kit.rkt.

(provide ep-i18n-catalog ep-i18n-put ep-l10n-coverage ep-l10n-messages
         ep-l10n-submit ep-l10n-review ep-l10n-import ep-l10n-export
         ep-l10n-discard ep-l10n-draft)

(require (only-in racket/path path-has-extension?)
         racket/list
         web-kit
         (only-in "../../domain/authz/authz.rkt" audit! principal-team-id principal-user-id require-perm)
         (only-in "../../domain/i18n/policy.rkt" i18n-policy i18n-policy-set! resolve-locale)
         (only-in "../../domain/i18n/catalog.rkt" catalog-exists? catalog-messages read-catalog write-catalog)
         (only-in "../../domain/i18n/manager.rkt" l10n-coverage l10n-discard-machine! l10n-export l10n-import! l10n-list l10n-locales l10n-review! l10n-submit!)
         (only-in "../../domain/quota/quota.rkt" quota-check)
         (only-in "../../domain/sched/scheduler.rkt" enqueue-job!)
         (only-in "../../domain/i18n/i18n.rkt" localizer-catalogs localizer-fallback t)
         "../kit.rkt")

;; PUBLIC — and it has to be. The console's own strings live in the same catalogs
;; as the server's (namespace `ui.`), and the sign-in screen has to render them
;; for someone who has no token yet. Same rationale as /api/config and
;; /api/branding. Nothing in a UI string is a secret.
;;
;; The fallback chain is resolved HERE, once for the whole namespace, so the
;; console makes one fetch per language and never needs the English catalog as
;; a second request: a locale that has 40% of its strings gets the other 60% in
;; English from the same reply. A miss on every catalog is simply absent, and the
;; console shows the key — visibly, not silently.
(define (ep-i18n-catalog req)
  (define want (let ([q (query-param req "locale" "")])
                 (if (string=? q "") (accept-language req) q)))
  (define loc (resolve-locale db-conn (locales-dir) want))
  (define L (localizer-for loc))
  (define msgs
    (for*/fold ([acc (hasheq)])
               ([l (in-list (localizer-fallback L))]
                [(k v) (in-hash (hash-ref (localizer-catalogs L) l (hash)))]
                #:when (and (> (string-length k) 3) (string=? (substring k 0 3) "ui."))
                #:unless (hash-has-key? acc (string->symbol k)))
      (hash-set acc (string->symbol k) v)))
  (json-response (hasheq 'locale loc 'messages msgs)))

;; ---- instance localization (Admin > Localization) ------------------------------
;; Read rides on the PUBLIC /api/config; the write is `instance:manage`, exactly
;; like branding. An unknown locale is a 400 and not a silent substitution: an
;; operator who asks for a language this build cannot render must be told, or the
;; instance claims a locale it will never actually serve.
(define (ep-i18n-put req)
  (with-auth req (lambda (p)
    (require-perm db-conn p "instance:manage")
    (define b (read-json-body req))
    (with-handlers ([exn:fail? (lambda (e) (err (exn-message e) 400))])
      (define v (i18n-policy-set! db-conn (locales-dir)
                                  (hasheq 'default (hash-ref b 'default
                                                             (hash-ref (i18n-policy db-conn (locales-dir)) 'default))
                                          'enabled (hash-ref b 'enabled #t))))
      (audit! db-conn #:action "i18n.set" #:actor-type "user" #:actor-id (principal-user-id p)
              #:resource-type "instance" #:resource-id "i18n")
      (json-response v)))))

;; ---- Localization Manager ------------------------------------------------------
;; The flagship tool. Instance-scoped on purpose: the artifact being translated is
;; the instance's own catalog on disk, so two teams cannot both be right about
;; `ja.json`. Governed by the `localization:*` permissions, which already existed.
;;
;; Read is `localization:read`, writing a string is `:translate`, approving is
;; `:review`, and anything that touches the files on disk is `:manage`.

(define (ep-l10n-coverage req)
  (with-auth req (lambda (p)
    (require-perm db-conn p "localization:read")
    (define loc (query-param req "locale" "ja"))
    (json-response (hash-set (l10n-coverage db-conn loc)
                             'locales (l10n-locales db-conn))))))

(define (ep-l10n-messages req)
  (with-auth req (lambda (p)
    (require-perm db-conn p "localization:read")
    (define (opt k) (let ([v (query-param req k "")]) (and (not (string=? v "")) v)))
    (define limit (let ([n (string->number (query-param req "limit" "50"))])
                    (if (and n (exact-positive-integer? n)) (min n 200) 50)))
    (define offset (let ([n (string->number (query-param req "offset" "0"))])
                     (if (and n (exact-nonnegative-integer? n)) n 0)))
    (json-response
     (l10n-list db-conn (query-param req "locale" "ja")
                #:status (opt "status") #:namespace (opt "namespace") #:q (opt "q")
                #:limit limit #:offset offset)))))

(define (ep-l10n-submit req message-id)
  (with-auth req (lambda (p)
    (require-perm db-conn p "localization:translate")
    (with-handlers ([exn:fail:user? (lambda (e) (err (exn-message e) 400))])
      (define b (read-json-body req))
      (define loc (fmt b 'locale))
      (when (string=? loc "") (raise-user-error 'l10n "locale is required"))
      (define t (l10n-submit! db-conn message-id loc (fmt b 'text) (principal-user-id p)))
      (audit! db-conn #:action "l10n.submit" #:actor-type "user" #:actor-id (principal-user-id p)
              #:resource-type "l10n" #:resource-id message-id)
      (json-response t)))))

(define (ep-l10n-review req translation-id)
  (with-auth req (lambda (p)
    (require-perm db-conn p "localization:review")
    (with-handlers ([exn:fail:user? (lambda (e) (err (exn-message e) 400))])
      (define b (read-json-body req))
      (define d (string->symbol (fmt b 'decision)))
      (define t (l10n-review! db-conn translation-id d (principal-user-id p)))
      (audit! db-conn #:action (format "l10n.~a" d) #:actor-type "user" #:actor-id (principal-user-id p)
              #:resource-type "l10n" #:resource-id translation-id)
      (json-response t)))))

;; Pull locales/*.json into the working tables. Safe to re-run: the database wins
;; for anything already under review.
(define (ep-l10n-import req)
  (with-auth req (lambda (p)
    (require-perm db-conn p "localization:manage")
    (with-handlers ([exn:fail? (lambda (e) (err (exn-message e) 400))])
      (define dir (locales-dir))
      (define base-path (build-path dir "en.json"))
      (unless (catalog-exists? base-path) (raise-user-error 'l10n "no base catalog at locales/en.json"))
      (define base (read-catalog base-path))
      (define targets
         (for/list ([f (in-list (directory-list dir))]
                   #:when (and (path-has-extension? f #".json")
                               (not (equal? (path->string f) "en.json"))))
          (read-catalog (build-path dir f))))
      (define r (l10n-import! db-conn base targets))
      (audit! db-conn #:action "l10n.import" #:actor-type "user" #:actor-id (principal-user-id p)
              #:resource-type "instance" #:resource-id "l10n")
      (json-response r)))))

;; Write approved strings back to locales/<locale>.json — the shipping artifact.
;; This is the ONLY way the manager reaches the product, and it is approved-only.
(define (ep-l10n-export req)
  (with-auth req (lambda (p)
    (require-perm db-conn p "localization:manage")
    (with-handlers ([exn:fail? (lambda (e) (err (exn-message e) 400))])
      (define b (read-json-body req))
      (define loc (fmt b 'locale))
      (when (string=? loc "") (raise-user-error 'l10n "locale is required"))
      (when (string=? loc "en") (raise-user-error 'l10n "en is the source catalog; it is extracted, not exported"))
      (define cat (l10n-export db-conn loc))
      (define n (hash-count (catalog-messages cat)))
      ;; Refuse to write an EMPTY catalog. `available` is derived from the files in
      ;; locales/, precisely so the instance cannot advertise a language it cannot
      ;; render — and a catalog with nothing approved in it renders entirely as
      ;; English fallback. Writing one would put Dutch in the language switcher and
      ;; then show English behind it, which is worse than not offering it at all.
      ;; Translate something first; a PARTIAL catalog is fine, the fallback chain
      ;; covers the gaps.
      (when (zero? n)
         (raise-user-error 'l10n
          (string-append "nothing is approved in " loc " yet — exporting now would "
                         "advertise the language with an empty catalog")))
      (define path (build-path (locales-dir) (string-append loc ".json")))
      (write-catalog path cat)
      (audit! db-conn #:action "l10n.export" #:actor-type "user" #:actor-id (principal-user-id p)
              #:resource-type "instance" #:resource-id loc)
      (json-response (hasheq 'ok #t 'locale loc
                             'written n
                             'path (path->string path)
                             'note "restart to serve the new catalog")))))) 

(define (ep-l10n-discard req)
  (with-auth req (lambda (p)
    (require-perm db-conn p "localization:manage")
    (with-handlers ([exn:fail:user? (lambda (e) (err (exn-message e) 400))])
      (define b (read-json-body req))
      (define loc (fmt b 'locale))
      (when (string=? loc "") (raise-user-error 'l10n "locale is required"))
      (define ns (let ([v (fmt b 'namespace)]) (and (not (string=? v "")) v)))
      (define n (l10n-discard-machine! db-conn loc #:namespace ns))
      (audit! db-conn #:action "l10n.discard" #:actor-type "user" #:actor-id (principal-user-id p)
              #:resource-type "instance" #:resource-id loc)
      (json-response (hasheq 'ok #t 'locale loc 'discarded n))))))

(define l10n-draft-batch 20)

;; Queue AI drafts for the strings that have none. `manage` rather than
;; `translate`: this spends the team's AI budget, so it is an administrative act.
(define (ep-l10n-draft req)
  (with-auth req (lambda (p)
    (require-perm db-conn p "localization:manage")
    (with-handlers ([exn:fail:user? (lambda (e) (err (exn-message e) 400))])
      (define b (read-json-body req))
      (define loc (fmt b 'locale))
      (when (string=? loc "") (raise-user-error 'l10n "locale is required"))
      (when (string=? loc "en") (raise-user-error 'l10n "en is the source; there is nothing to draft"))
      (define ns (let ([v (fmt b 'namespace)]) (and (not (string=? v "")) v)))
      (define cap (let ([v (hash-ref b 'limit 200)]) (if (exact-positive-integer? v) (min v 500) 200)))
      (define missing
         (hash-ref (l10n-list db-conn loc #:status "missing" #:namespace ns #:limit cap) 'items))
      (define ids (map (lambda (h) (hash-ref h 'message_id)) missing))
      (define batches
         (let loop ([xs ids] [acc '()])
          (cond [(null? xs) (reverse acc)]
                [(<= (length xs) l10n-draft-batch) (reverse (cons xs acc))]
                [else (loop (list-tail xs l10n-draft-batch)
                            (cons (take xs l10n-draft-batch) acc))])))
      (define jobs
         (for/list ([batch (in-list batches)])
          (enqueue-job! db-conn #:team (principal-team-id p) #:user (principal-user-id p)
                        #:kind "l10n_draft"
                        #:payload (hasheq 'locale loc 'message_ids batch))))
      (audit! db-conn #:action "l10n.draft" #:actor-type "user" #:actor-id (principal-user-id p)
              #:resource-type "instance" #:resource-id loc)
      ;; Drafts are quota-admitted like every job, so an over-budget team's queue
      ;; simply stops — which looks like a hang. Hand the caller the budget so the
      ;; tab can say so up front. ~120 tokens per string on qwen2.5:7b, measured.
      (define q (quota-check db-conn "team" (principal-team-id p) "ai.tokens.total" 0))
      (json-response (hasheq 'ok #t 'locale loc 'queued (length ids)
                             'batches (length jobs) 'jobs jobs
                             'budget (hasheq 'dimension "ai.tokens.total"
                                             'used (hash-ref q 'used) 'limit (hash-ref q 'limit)
                                             'remaining (hash-ref q 'remaining)
                                             'estimate (* 120 (length ids)))))))))
