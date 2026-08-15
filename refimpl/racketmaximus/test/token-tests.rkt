#lang racket/base

;; test/token-tests.rkt — API token management: issue / list / resolve / revoke.
;; raco test test/token-tests.rkt

(require rackunit
         db
         db-kit/migrate
         "../domain/db/migrations.rkt"
         "../domain/authz/authz.rkt")

(define (fresh) (define c (sqlite3-connect #:database 'memory)) (migrate! c all-migrations) c)

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
