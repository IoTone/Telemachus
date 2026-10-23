#lang racket/base

;; server/api/usage.rkt — what a team has spent, what it may spend, and the
;; tool listing
;;
;; Split out of main.rkt by #110 r3. The shared surface every handler here
;; needs — the pool, the request accessors, with-auth/with-mt, the response
;; constructors — is server/kit.rkt.

(provide ep-usage ep-tools-list ep-quota-set)

(require web-kit
         (only-in "../../domain/authz/authz.rkt" principal-team-id require-perm)
         (only-in "../../domain/quota/quota.rkt" quota-check set-limit! window-resets-at)
         (only-in "../../domain/agent/registry.rkt" tool-settings-for)
         "../kit.rkt"
         "../admission.rkt")

(define (ep-usage req)
  (with-auth req (lambda (p)
    (define sid (principal-team-id p))
    (json-response
     (hasheq 'team_id sid
             ;; `held` is the same answer `GET /api/jobs` puts on a queued job, so
             ;; the Usage tab can say why work has stopped without reading the
             ;; queue — and `resets_at` is when it starts again (issue #55).
             'held (or (quota-hold-reason db-conn sid) 'null)
             'quota (for/list ([dim (in-list '("ai.tokens.total" "ai.requests" "ai.judgments.total" "ai.concurrency" "feed.fetches"))])
                      (define d (quota-check db-conn "team" sid dim 0))
                      (hasheq 'dimension dim 'used (hash-ref d 'used)
                              'limit (hash-ref d 'limit) 'remaining (hash-ref d 'remaining)
                              'window (hash-ref d 'window)
                              'resets_at (or (window-resets-at db-conn (hash-ref d 'window)) 'null))))))))

;; plugin tool management (per-team activate/deactivate)
(define (ep-tools-list req)
  (with-auth req (lambda (p)
    (json-response (hasheq 'tools (tool-settings-for db-conn (principal-team-id p)))))))

(define (ep-quota-set req)
  (with-auth req (lambda (p)
    ;; issue #113: `quota:manage`, not `instance:manage`. The catalog has always
    ;; granted it to the team steward and to the company admins, and no route
    ;; read it — so a team that hit its 2,000-token daily default could only be
    ;; unblocked by the INSTANCE operator. The company's own limit still caps
    ;; whatever a team asks for: `tenant-quota-check` takes the org decision
    ;; first and lets it refuse, so this cannot widen a tenant's actual budget.
    (require-perm db-conn p "quota:manage")
    (define b (read-json-body req))
    (define dim (hash-ref b 'dimension #f))
    (define limit (hash-ref b 'limit #f))
    (cond
      [(or (not dim) (not limit)) (err "dimension and limit required" 400)]
      [else
       (set-limit! db-conn "team" (principal-team-id p) dim limit #:window (hash-ref b 'window "day"))
       (json-response (hasheq 'ok #t 'dimension dim 'limit limit))]))))
