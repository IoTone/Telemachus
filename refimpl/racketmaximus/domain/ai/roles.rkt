#lang racket/base

;; domain/ai/roles.rkt — model ROLES (slice 67, KG-7 / LOC-5): which executor a
;; kind of work goes to. The chat a person is having wants the best model; bulk
;; extraction for the knowledge graph, field extraction in the pipeline and
;; translation drafts are cheap-model-shaped and can go to a smaller or
;; differently-placed one — a pull host on a GPU box, say — without any tool
;; knowing. One role ships, `utility`; a role resolves to an executor NAME.
;;
;; Resolution: the team's own setting (instance_settings key model-roles:<team>,
;; set through PUT /api/model-roles) → the instance default from the
;; environment (TELEMACHUS_MODEL_UTILITY) → #f, meaning "the local model, as
;; before". Opt-in per team, exactly the precedent the Localization Manager set.

(require racket/string
         "../settings/settings.rkt")

(provide ROLES model-role-executor model-roles-get model-roles-set! current-utility-executor)

(define ROLES '("utility"))

(define (role-key team) (string-append "model-roles:" team))
(define (env-default role)
  (define v (getenv (string-append "TELEMACHUS_MODEL_" (string-upcase role))))
  (and v (not (string=? v "")) v))

;; -> an executor name, or #f for the local model
(define (model-role-executor conn team role)
  (define doc (setting-ref conn (role-key team) (hasheq)))
  (define v (hash-ref doc (string->symbol role) #f))
  (or (and (string? v) (not (string=? v "")) v)
      (env-default role)))

;; {roles: {utility: name|null}, defaults: {utility: env|null}} — what the team set,
;; and what applies when it set nothing
(define (model-roles-get conn team)
  (define doc (setting-ref conn (role-key team) (hasheq)))
  (hasheq 'roles (for/hasheq ([r (in-list ROLES)])
                   (values (string->symbol r) (let ([v (hash-ref doc (string->symbol r) #f)]) (if (string? v) v 'null))))
          'defaults (for/hasheq ([r (in-list ROLES)])
                      (values (string->symbol r) (or (env-default r) 'null)))))

;; `roles` is {role: name | null}; a null clears the team's choice. Unknown roles
;; are refused; whether the executor exists is the caller's check (it has the
;; registry, this module does not).
(define (model-roles-set! conn team roles)
  (for ([(k v) (in-hash roles)])
    (unless (member (symbol->string k) ROLES)
      (raise-user-error 'model-roles "unknown role ~a; roles are ~a" k (string-join ROLES ", "))))
  (define doc (setting-ref conn (role-key team) (hasheq)))
  (define next
    (for/fold ([d doc]) ([(k v) (in-hash roles)])
      (if (or (eq? v 'null) (not v) (equal? v "")) (hash-remove d k) (hash-set d k (format "~a" v)))))
  (setting-set! conn (role-key team) next)
  (model-roles-get conn team))

;; the executor the current unit of work should use for utility calls; the
;; tools set it around their model call, the model seam reads it
(define current-utility-executor (make-parameter #f))
