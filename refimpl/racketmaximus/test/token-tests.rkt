#lang racket/base

;; test/token-tests.rkt — API token management: issue / list / resolve / revoke.
;; raco test test/token-tests.rkt

(require rackunit db-kit/portable
         db-kit/migrate
         "../domain/db/migrations.rkt"
         "db-fixture.rkt"
         "../domain/authz/authz.rkt")

(define (fresh) (define c (fresh-db #:migrate? #f)) (migrate! c all-migrations) c)

(test-case "issue / list (prefix only) / resolve / revoke"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice"))
  (define-values (raw _tokid) (issue-token! c #:user uid #:team tid #:name "ci" #:scopes '("*:read")))
  (define lst (list-tokens c tid))
  (check-equal? (length lst) 1)
  (check-equal? (hash-ref (car lst) 'name) "ci")
  (check-equal? (hash-ref (car lst) 'status) "active")
  (check-true (string? (hash-ref (car lst) 'prefix)))
  (check-false (hash-has-key? (car lst) 'token_hash))       ; never leaks the hash/raw
  ;; the raw token resolves to a working principal
  (check-true (and (resolve-token c raw) #t))
  ;; revoke → resolve fails, status flips
  (check-true (revoke-token! c (hash-ref (car lst) 'id) tid))
  (check-false (resolve-token c raw))
  (check-equal? (hash-ref (car (list-tokens c tid)) 'status) "revoked")
  ;; unknown id → #f
  (check-false (revoke-token! c "nope" tid)))

;; issue #13: expires_at is enforced at resolve time, and set at issue time
(test-case "a token expires; 'never means never; the listing says which"
  (define c (fresh-db))
  (define-values (uid tid) (bootstrap! c #:username "root"))
  (define-values (short short-id) (issue-token! c #:user uid #:team tid #:name "short" #:scopes '("*:read") #:ttl 1))
  (define-values (long _l) (issue-token! c #:user uid #:team tid #:name "long" #:scopes '("*:read") #:ttl 'never))
  (define-values (dflt _d) (issue-token! c #:user uid #:team tid #:name "default" #:scopes '("*:read")))
  (check-true (and (resolve-token c short) #t) "fresh, it resolves")
  (check-true (and (resolve-token c long) #t))
  (check-true (and (resolve-token c dflt) #t))
  (define (listed name) (for/first ([t (in-list (list-tokens c tid))] #:when (equal? (hash-ref t 'name) name)) t))
  (check-equal? (hash-ref (listed "long") 'expires_at) 'null "'never is listed as no expiry")
  (check-true (regexp-match? #px"^\\d{4}-\\d{2}-\\d{2}T" (hash-ref (listed "default") 'expires_at)) "the default is a date")
  ;; push the short one into the past directly — the test must not sleep
  (query-exec c "UPDATE api_tokens SET expires_at = ? WHERE id = ?" (number->string (- (current-seconds) 5)) short-id)
  (check-false (resolve-token c short) "an expired token resolves to nothing")
  (check-equal? (hash-ref (listed "short") 'status) "expired" "…and the listing says so, though the row is still 'active'")
  (check-true (and (resolve-token c long) #t) "the never-expiring one still works")
  ;; a row with no expiry at all (pre-#13 data) keeps working — nobody is locked out by the upgrade
  (query-exec c "UPDATE api_tokens SET expires_at = NULL WHERE id = ?" short-id)
  (check-true (and (resolve-token c short) #t) "NULL expiry = never, so tokens issued before #13 survive"))

;; the hash: peppered HMAC-SHA-256, versioned; a prototype-era SHA-1 row still
;; resolves and is rehashed on first use
(test-case "token hash is v1 HMAC; legacy sha1 rows resolve once and are upgraded"
  (define c (fresh-db))
  (define-values (uid tid) (bootstrap! c #:username "root"))
  (define-values (raw tokid) (issue-token! c #:user uid #:team tid #:name "x" #:scopes '("*:read") #:ttl 'never))
  (define stored (query-value c "SELECT token_hash FROM api_tokens WHERE id = ?" tokid))
  (check-true (regexp-match? #px"^v1:[0-9a-f]{64}$" stored) "stored as v1:<hmac-sha256 hex>")
  (check-equal? stored (hash-token raw))
  ;; the legacy scheme: 40 hex chars of salted sha1 — rewrite the row as the old code would have
  (define legacy (legacy-hash-token raw))
  (check-true (regexp-match? #px"^[0-9a-f]{40}$" legacy))
  (query-exec c "UPDATE api_tokens SET token_hash = ? WHERE id = ?" legacy tokid)
  (check-true (and (resolve-token c raw) #t) "a pre-upgrade row still resolves")
  (check-equal? (query-value c "SELECT token_hash FROM api_tokens WHERE id = ?" tokid) stored
                "…and was rehashed to v1 on that first use")
  (check-true (and (resolve-token c raw) #t) "…and keeps resolving")
  ;; a different pepper invalidates every token
  (putenv "TELEMACHUS_TOKEN_PEPPER" "rotated-pepper")
  (check-false (resolve-token c raw) "rotating the pepper invalidates issued tokens")
  (putenv "TELEMACHUS_TOKEN_PEPPER" "")
  (check-true (and (resolve-token c raw) #t))
  ;; garbage never resolves, whatever its shape
  (check-false (resolve-token c "tk_notatoken"))
  (check-false (resolve-token c "")))
