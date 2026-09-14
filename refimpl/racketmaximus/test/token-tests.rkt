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
