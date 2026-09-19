#lang racket/base

;; test/roles-tests.rkt — slice 67: model roles (KG-7 / LOC-5).
;;   raco test test/roles-tests.rkt
;; A role resolves team setting → environment default → #f (the local model), and
;; the document/knowledge tools route their model call through it.

(require rackunit db-kit/portable json
         db-kit/migrate
         "../domain/db/migrations.rkt"
         "db-fixture.rkt"
         "../domain/authz/authz.rkt"
         "../domain/ai/roles.rkt"
         "../domain/ai/executor.rkt"
         "../domain/repo/doc-tools.rkt")

(define (fresh) (define c (fresh-db #:migrate? #f)) (migrate! c all-migrations) c)

(test-case "resolution: team setting, then the environment, then the local model"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "root"))
  (putenv "TELEMACHUS_MODEL_UTILITY" "")
  (check-false (model-role-executor c tid "utility") "nothing set: the local model")
  (check-equal? (hash-ref (hash-ref (model-roles-get c tid) 'roles) 'utility) 'null)
  (putenv "TELEMACHUS_MODEL_UTILITY" "env-box")
  (check-equal? (model-role-executor c tid "utility") "env-box" "the instance default from the environment")
  (check-equal? (hash-ref (hash-ref (model-roles-get c tid) 'defaults) 'utility) "env-box")
  (model-roles-set! c tid (hasheq 'utility "team-box"))
  (check-equal? (model-role-executor c tid "utility") "team-box" "the team's own choice wins")
  (model-roles-set! c tid (hasheq 'utility 'null))
  (check-equal? (model-role-executor c tid "utility") "env-box" "null clears the team's choice")
  (putenv "TELEMACHUS_MODEL_UTILITY" "")
  (check-exn #rx"unknown role" (lambda () (model-roles-set! c tid (hasheq 'fancy "x"))))
  (disconnect c))

(test-case "the document tools' model seam routes utility work to the role's executor"
  ;; a pull executor answers through the router box; no server, no model URL
  (define seen (box #f))
  ;; the router takes the response format too (issue #18); this call asks for none
  (set-box! pull-router (lambda (name msgs temp rf) (set-box! seen name) (cons "{\"title\":\"t\"}" 4)))
  (define-values (fields tokens)
    (parameterize ([current-utility-executor "util-box"])
      (extract-fields "some text" (hasheq 'type "object" 'properties (hasheq 'title (hasheq 'type "string"))))))
  (check-equal? (unbox seen) "util-box" "the call went to the utility executor, not the local model")
  (check-equal? (hash-ref fields 'title) "t")
  (check-equal? tokens 4)
  ;; without a role and without a local model, the seam still refuses loudly
  (set-box! pull-router (lambda (name msgs temp rf) #f))
  (check-exn #rx"no model configured" (lambda () (extract-fields "text" (hasheq 'type "object")))))
