#lang racket/base

;; server/api/admin.rkt — the audit listing, the sample seed, instance
;; metrics and the plugin surfaces
;;
;; Split out of main.rkt by #110 r3. The shared surface every handler here
;; needs — the pool, the request accessors, with-auth/with-mt, the response
;; constructors — is server/kit.rkt.

(provide ep-audit ep-admin-seed ep-metrics ep-plugins ep-mcp ep-oop
         ep-tool-toggle)

(require db-kit/portable
         web-kit
         (only-in "../../domain/authz/authz.rkt" audit! audit-list principal-team-id principal-user-id require-perm)
         (only-in "../../domain/samples/samples.rkt" seed-samples!)
         (only-in "../../domain/agent/registry.rkt" set-tool-enabled!)
         (only-in "../../domain/agent/plugins.rkt" loaded-plugins plugin-failures)
         (only-in "../../domain/mcp/connect.rkt" mcp-servers)
         (only-in "../../domain/oop/host.rkt" capability-names loaded-oop-plugins)
         "../kit.rkt")

(define (ep-audit req)
  (with-auth req (lambda (p)
    (require-perm db-conn p "settings:manage")
    (json-response (hasheq 'audit (audit-list db-conn (principal-team-id p) #:limit 100))))))

(define (ep-admin-seed req)
  (with-auth req (lambda (p)
    (require-perm db-conn p "settings:manage")
    (define counts (seed-samples! db-conn p))
    (audit! db-conn #:action "samples.seed" #:actor-type "user" #:actor-id (principal-user-id p) #:team-id (principal-team-id p))
    (json-response (hash-set counts 'ok #t)))))

(define (ep-metrics req)
  (with-auth req (lambda (p)
    (require-perm db-conn p "instance:manage")
    (define (n q) (query-value db-conn q))
    (json-response (hasheq
      'users (n "SELECT COUNT(*) FROM users")
      'teams (n "SELECT COUNT(*) FROM teams")
      'orgs (n "SELECT COUNT(*) FROM orgs")
      'notes (n "SELECT COUNT(*) FROM notes")
      'translations (n "SELECT COUNT(*) FROM translations")
      'active_tokens (n "SELECT COUNT(*) FROM api_tokens WHERE status = 'active'")
      'audit_events (n "SELECT COUNT(*) FROM audit_log")
      'tenants (n "SELECT COUNT(*) FROM provisioning"))))))

(define (ep-plugins req)
  (with-auth req (lambda (p) (json-response (hasheq 'sandboxed (loaded-oop-plugins)
                                                    'plugins (loaded-plugins)
                                                    ;; issue #48: what did NOT load
                                                    'failed (plugin-failures))))))

(define (ep-mcp req)
  (with-auth req (lambda (p) (json-response (hasheq 'servers (mcp-servers))))))

(define (ep-oop req)
  (with-auth req (lambda (p) (json-response (hasheq 'plugins (loaded-oop-plugins)
                                                    'capabilities (capability-names))))))

(define (ep-tool-toggle req name)
  (with-auth req (lambda (p)
    (require-perm db-conn p "settings:manage")
    (define b (read-json-body req))
    (define on? (and (hash-ref b 'enabled #t) #t))
    (set-tool-enabled! db-conn (principal-team-id p) name on?)
    (json-response (hasheq 'ok #t 'tool name 'enabled on?)))))
