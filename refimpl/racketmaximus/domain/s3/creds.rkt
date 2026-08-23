#lang racket/base

;; domain/s3/creds.rkt — S3 access keys (DOC-3).
;;
;; A distinct credential kind from `api_tokens`, and it has to be: SigV4 is an HMAC
;; keyed by the secret, so verifying a signature means holding the secret. There is
;; no way to check an HMAC against a hash, which is what api_tokens stores.
;;
;; SECRETS ARE STORED IN THE CLEAR, and that is a deliberate, stated position rather
;; than an oversight. The alternative on offer — encrypting with a key that lives in
;; the environment of the same process, on the same host, reading the same database —
;; moves the secret from one file an attacker already has to another. `users.totp_secret`
;; is recoverable in this database for exactly the same reason. What actually bounds
;; the damage is the scope list: a leaked access key can do what its scopes allow and
;; no more, never what its issuer could do. Treat the database as the trust boundary
;; it already is, and if that is not enough for a deployment, encrypt the volume.
;;
;; A credential resolves to a principal, and from there every request is
;; indistinguishable from one that arrived with a bearer token (DOC-1).

(require db-kit/portable racket/string racket/list racket/random json
         "../db/id.rkt"
         "../authz/authz.rkt")

(provide s3-cred-issue! s3-cred-list s3-cred-revoke! s3-cred-resolve
         s3-cred-principal access-key-id? s3-cred-newest)

;; Shaped like an AWS key so a client that validates the format is happy: 20
;; characters, uppercase alphanumeric, conventional prefix.
(define ALPHABET "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567")
(define (random-access-key)
  (string-append "TMX"
                 (list->string
                  (for/list ([b (in-bytes (crypto-random-bytes 17))])
                    (string-ref ALPHABET (modulo b (string-length ALPHABET)))))))

(define (access-key-id? s) (and (string? s) (regexp-match? #px"^[A-Z0-9]{8,64}$" s) #t))

;; Issuing a credential hands out rights, so it needs the same permission as issuing
;; an API token. Scopes cap it exactly as RBAC-4 caps a token.
;; The default covers what an S3 client actually does: `aws s3 sync --delete` and
;; `aws s3 rm` need files:delete, and a credential that cannot delete makes the
;; endpoint look broken rather than restricted. Narrow it at issue time if you want
;; a read-only key — scopes still cap the credential below its issuer either way.
(define (s3-cred-issue! conn p #:name [name ""]
                        #:scopes [scopes '("files:read" "files:write" "files:delete")])
  (require-perm conn p "tokens:manage")
  (define id (new-id))
  (define ak (random-access-key))
  (define secret (random-token 32))
  (query-exec conn
    (string-append "INSERT INTO repo_credentials (id, user_id, team_id, name, access_key_id, secret_key, scopes) "
                   "VALUES (?, ?, ?, ?, ?, ?, ?)")
    id (principal-user-id p) (principal-team-id p) name ak secret (jsexpr->string scopes))
  (audit! conn #:action "s3.credential.create" #:actor-type "user" #:actor-id (principal-user-id p)
          #:team-id (principal-team-id p) #:resource-type "repo_credentials" #:resource-id id
          #:meta (format "{\"access_key_id\":~s}" ak))
  ;; the secret is returned once, here, and never again
  (hasheq 'id id 'access_key_id ak 'secret_access_key secret 'name name 'scopes scopes))

(define (s3-cred-list conn p)
  (require-perm conn p "tokens:manage")
  (for/list ([r (in-list (query-rows conn
       (string-append "SELECT id, name, access_key_id, scopes, status, last_used_at, created_at "
                      "FROM repo_credentials WHERE team_id = ? ORDER BY created_at DESC")
       (principal-team-id p)))])
    (hasheq 'id (vector-ref r 0)
            'name (let ([n (vector-ref r 1)]) (if (sql-null? n) "" n))
            'access_key_id (vector-ref r 2)
            'scopes (with-handlers ([exn:fail? (lambda (_) '())]) (string->jsexpr (vector-ref r 3)))
            'status (vector-ref r 4)
            'last_used_at (let ([v (vector-ref r 5)]) (if (sql-null? v) 'null v))
            'created_at (vector-ref r 6))))

(define (s3-cred-revoke! conn p id)
  (require-perm conn p "tokens:manage")
  (define n (query-exec conn
    "UPDATE repo_credentials SET status = 'revoked' WHERE id = ? AND team_id = ?"
    id (principal-team-id p)))
  (audit! conn #:action "s3.credential.revoke" #:actor-type "user" #:actor-id (principal-user-id p)
          #:team-id (principal-team-id p) #:resource-type "repo_credentials" #:resource-id id)
  #t)

;; access key -> (values secret row) or (values #f #f). Unauthenticated input, so it
;; must not raise on anything.
(define (s3-cred-resolve conn access-key)
  (cond
    [(not (access-key-id? access-key)) (values #f #f)]
    [else
     (define r (query-maybe-row conn
       (string-append "SELECT id, user_id, team_id, secret_key, scopes, status "
                      "FROM repo_credentials WHERE access_key_id = ?") access-key))
     (cond
       [(or (not r) (not (equal? (vector-ref r 5) "active"))) (values #f #f)]
       [else (values (vector-ref r 3)
                     (hasheq 'id (vector-ref r 0) 'user_id (vector-ref r 1)
                             'team_id (vector-ref r 2)
                             'scopes (with-handlers ([exn:fail? (lambda (_) '())])
                                       (string->jsexpr (vector-ref r 4)))))])]))

;; The credential row becomes an ordinary principal, scopes and all. Everything after
;; this point is `can?` doing what it always does — built the same way resolve-token
;; builds one for a bearer token, because they are the same thing arriving by a
;; different door (DOC-1).
(define (s3-cred-principal conn row)
  (define user-id (hash-ref row 'user_id))
  (define urow (query-maybe-row conn
    "SELECT is_operator, org_id, org_role_key FROM users WHERE id = ?" user-id))
  (define op (and urow (vector-ref urow 0)))
  (query-exec conn "UPDATE repo_credentials SET last_used_at = CURRENT_TIMESTAMP WHERE id = ?"
              (hash-ref row 'id))
  (principal user-id
             (and (number? op) (not (zero? op)))
             (hash-ref row 'team_id)
             (hash-ref row 'scopes '())
             (and urow (let ([v (vector-ref urow 1)]) (and (not (sql-null? v)) v)))
             (and urow (let ([v (vector-ref urow 2)]) (and (not (sql-null? v)) v)))))

;; The caller's newest active credential, for signing a presigned URL on their behalf.
;; A link therefore carries exactly that key's scopes and dies with it when revoked —
;; the alternative, minting a hidden credential per link, would create rights nobody
;; can see or take away.
(define (s3-cred-newest conn p)
  (define r (query-maybe-row conn
    (string-append "SELECT access_key_id, secret_key FROM repo_credentials "
                   "WHERE user_id = ? AND team_id = ? AND status = 'active' "
                   "ORDER BY created_at DESC LIMIT 1")
    (principal-user-id p) (principal-team-id p)))
  (and r (values->cons (vector-ref r 0) (vector-ref r 1))))

(define (values->cons a b) (cons a b))
