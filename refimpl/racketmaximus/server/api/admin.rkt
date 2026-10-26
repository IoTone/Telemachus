#lang racket/base

;; server/api/admin.rkt — the audit listing, the sample seed, instance
;; metrics and the plugin surfaces
;;
;; Split out of main.rkt by #110 r3. The shared surface every handler here
;; needs — the pool, the request accessors, with-auth/with-mt, the response
;; constructors — is server/kit.rkt.

(provide ep-audit ep-model-requests ep-admin-seed ep-metrics ep-plugins ep-mcp ep-oop
         ep-tool-toggle ep-anchor-status ep-anchor-emit ep-anchor-receipts
         ep-anchor-export)

(require db-kit/portable
         web-kit
         web-server/http
         (only-in "../../domain/authz/authz.rkt" audit! audit-list principal-team-id principal-user-id require-perm)
         (only-in "../../domain/samples/samples.rkt" seed-samples!)
         (only-in "../../domain/agent/registry.rkt" set-tool-enabled!)
         (only-in "../../domain/agent/plugins.rkt" loaded-plugins plugin-failures)
         (only-in "../../domain/mcp/connect.rkt" mcp-servers)
         (only-in "../../domain/oop/host.rkt" capability-names loaded-oop-plugins)
         (only-in "../../domain/ai/requestlog.rkt" model-requests-for)
         (only-in "../../domain/audit/anchor.rkt"
                  anchor-emit! anchor-status anchor-receipts anchor-export-jsonl)
         "../kit.rkt")

(define (ep-audit req)
  (with-auth req (lambda (p)
    (require-perm db-conn p "settings:manage")
    (json-response (hasheq 'audit (audit-list db-conn (principal-team-id p) #:limit 100))))))

;; issue #91 requirement 3 (RED-22). The team's own trail of its own model
;; requests: what went where, how big it was, what it cost, and whether it was
;; refused — never the prompt. `audit:read`, because it is an audit question and
;; the digest is information about CONTENT, which is why a plain member does not
;; hold it (#84's rule, where who-read a document is behind `files:manage`
;; because it is information about people).
(define (ep-model-requests req)
  (with-auth req (lambda (p)
    (define (num k d) (let ([v (query-param req k)])
                        (or (and (string? v) (string->number v)) d)))
    (json-response
     (hasheq 'requests (model-requests-for db-conn p
                                           #:limit (num 'limit 100)
                                           #:offset (num 'offset 0)
                                           #:executor (let ([e (query-param req 'executor)])
                                                        (and (string? e) (not (string=? e "")) e))))))))

(define (ep-admin-seed req)
  (with-auth req (lambda (p)
    (require-perm db-conn p "settings:manage")
    (define counts (seed-samples! db-conn p))
    (audit! db-conn #:action "samples.seed" #:actor-type "user" #:actor-id (principal-user-id p) #:team-id (principal-team-id p))
    (json-response (hash-set counts 'ok #t)))))

(define (ep-metrics req)
  (with-auth req (lambda (p)
    ;; #124: `instance:read`, not `instance:manage` — the dispatcher gates this
    ;; route on the read permission now, and a handler still demanding `manage`
    ;; would refuse exactly the monitoring token the permission exists for.
    (require-perm db-conn p "instance:read")
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

;; ---- the external anchor (#66, ANCHOR-1…10) ----------------------------------
;; The receipt series that makes a rewrite of either hash chain detectable from
;; OUTSIDE the box. These four routes are the box's side of it; the half that
;; matters is `cli/telemachus-anchor.rkt verify`, which runs against a retained
;; file with no server and no database — an anchor is worth something precisely
;; when the instance is the suspect.
;;
;; THE READS ARE `instance:read`, NOT `instance:manage` (#124's split). A receipt
;; carries chain head hashes, counts and a signature — 64 hex characters that say
;; nothing about what any team decided or who read what — so a monitoring or
;; retention credential may pull them, and pulling them is the normal way a
;; series gets retained. That is the opposite call from `GET /api/admin/audit/export`,
;; which stays `instance:manage` because it hands over the log ITSELF.
;; Emitting is a write, so it is `instance:manage`.

(define (ep-anchor-status req)
  (with-auth req (lambda (p)
    (require-perm db-conn p "instance:read")
    (json-response (anchor-status db-conn)))))

(define (ep-anchor-emit req)
  (with-auth req (lambda (p)
    (require-perm db-conn p "instance:manage")
    ;; `anchor-emit!` raises a user error when no key is configured, which the
    ;; dispatcher turns into a 400 naming the generator (#123) — the caller's
    ;; configuration is the caller's to read, and it is not a server fault.
    ;; The team is the acting operator's: `audit-list` filters `WHERE team_id = ?`,
    ;; so an instance-tier entry without one is invisible to everybody. SEVENTH
    ;; appearance of that shape in this tree.
    (json-response (anchor-emit! db-conn
                                 #:actor-id (principal-user-id p)
                                 #:team-id (principal-team-id p))))))

(define (ep-anchor-receipts req)
  (with-auth req (lambda (p)
    (require-perm db-conn p "instance:read")
    (define lim (max 1 (min 1000 (or (string->number (query-param req 'limit "100")) 100))))
    (define since (string->number (query-param req 'since_seq "")))
    (json-response
     (hasheq 'receipts (anchor-receipts db-conn #:limit lim #:since-seq since)
             'status (anchor-status db-conn))))))

(define (ep-anchor-export req)
  (with-auth req (lambda (p)
    (require-perm db-conn p "instance:read")
    (define lim (max 1 (min 100000 (or (string->number (query-param req 'limit "10000")) 10000))))
    (define since (string->number (query-param req 'since_seq "")))
    ;; Streamed as JSONL, oldest first, so a retention system APPENDS what it does
    ;; not yet hold — `?since_seq=` is how it asks for only that. The same shape
    ;; the audit export chose, for the same reason.
    (response/output
     #:mime-type #"application/x-ndjson"
     #:headers (list (make-header #"X-Content-Type-Options" #"nosniff")
                     (make-header #"Content-Disposition"
                                  #"attachment; filename=\"anchor-receipts.jsonl\""))
     (lambda (out)
       (void (anchor-export-jsonl db-conn out #:since-seq since #:limit lim)))))))
