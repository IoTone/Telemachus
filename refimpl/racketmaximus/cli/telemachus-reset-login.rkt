#lang racket/base

;; telemachus-reset-login.rkt — the way back in when the operator credential is
;; gone (issue #54's route, run locally).
;;
;; `POST /api/admin/users/:id/password` is the documented recovery path and it
;; needs `instance:manage` — i.e. the very credential that has been lost, so on
;; an instance whose only operator token is gone the HTTP route cannot be
;; reached. `POST /api/bootstrap` is first-run-only, so it cannot re-mint one
;; either. What is left is an operator with shell access to the box, which is a
;; stronger position than any token, so this is not a privilege escalation —
;; it is the same write the handler makes, made from the same authority.
;;
;; It mirrors `ep-admin-password-reset` (server/api/accounts.rkt) deliberately:
;; set the password, CLEAR the login-attempt lock (#116 — without that a locked
;; account has no recovery path, because the lock refuses the sign-in that would
;; otherwise clear it), revoke every session (#54 — a reset that leaves old
;; bearers alive has not reset anything), and AUDIT it. The audit entry is the
;; point: a reset that leaves no record is a back door, and the log is chained
;; and exported (#84), so this one is as visible as any the console makes.
;;
;; Run it from the REPO ROOT, which is where PLTCOLLECTS is anchored:
;;   nix develop --command bash -c 'cd refimpl/racketmaximus && \
;;     racket cli/telemachus-reset-login.rkt list'
;;   nix develop --command bash -c 'cd refimpl/racketmaximus && \
;;     racket cli/telemachus-reset-login.rkt reset <username> [password]'

(require racket/string racket/list racket/random
         db-kit db-kit/portable
         "../config.rkt"
         (only-in "../domain/authz/authz.rkt"
                  set-password! revoke-user-sessions! login-lock-clear! first-team-for
                  ;; audit! lives in authz.rkt, not under domain/audit/ — that
                  ;; directory holds the READ side (the chain, the anchor, reads).
                  audit!))

(define (die fmt . args)
  (eprintf "telemachus-reset-login: ~a\n" (apply format fmt args))
  (exit 1))

(define (open-db) ((db-connector (database-url) #:base-dir impl-root)))

(define (with-db proc)
  (define conn
    (with-handlers ([exn:fail?
                     (lambda (e)
                       ;; REDACTED: a DATABASE_URL carries its password in the
                       ;; clear and this prints to a terminal (#186, SEC-6).
                       (die "cannot open the database.\n  DATABASE_URL=~a\n  ~a"
                            (redact-db-url (database-url)) (exn-message e)))])
      (open-db)))
  (with-handlers ([exn:fail?
                   (lambda (e)
                     (if (regexp-match? #px"(no such table|does not exist|relation .* does not)"
                                        (exn-message e))
                         (die (string-append
                               "this database has not been migrated by this build.\n"
                               "  DATABASE_URL=~a\n"
                               "Start the server once against it, or point DATABASE_URL at the "
                               "instance's own database.")
                              (redact-db-url (database-url)))
                         (raise e)))])
    (proc conn)))

;; ---- list: who exists, and which accounts can even be signed in to ----------
;;
;; No secrets: a password is a PBKDF2 hash and a TOTP seed is sealed, so what is
;; printed is whether each is PRESENT. An account with no password cannot be
;; signed in to at all (`authenticate` refuses a NULL hash forever), which is the
;; normal state of a bootstrap operator — its only credential was a token.
(define (cmd-list)
  (with-db
    (lambda (conn)
      (define rows
        (query-rows conn
          (string-append
           "SELECT id, username, is_operator, "
           "       CASE WHEN password_hash IS NULL THEN 'no' ELSE 'yes' END, "
           "       CASE WHEN totp_secret IS NULL THEN 'no' ELSE 'yes' END, "
           "       COALESCE(status, 'active') "
           "FROM users ORDER BY is_operator DESC, username")))
      (printf "~a accounts  (DATABASE_URL=~a)\n\n" (length rows) (redact-db-url (database-url)))
      (printf "~a  ~a  ~a  ~a  ~a\n" (~w "username" 28) (~w "operator" 9)
              (~w "password" 9) (~w "2fa" 4) "status")
      (for ([r (in-list rows)])
        (printf "~a  ~a  ~a  ~a  ~a\n"
                (~w (format "~a" (vector-ref r 1)) 28)
                (~w (if (equal? 1 (vector-ref r 2)) "yes" "-") 9)
                (~w (format "~a" (vector-ref r 3)) 9)
                (~w (format "~a" (vector-ref r 4)) 4)
                (vector-ref r 5)))
      (printf "\nA `password: no` account has never had one — reset it to sign in.\n"))))

(define (~w s n)
  (define str (format "~a" s))
  (if (>= (string-length str) n) str (string-append str (make-string (- n (string-length str)) #\space))))

;; 12 bytes of crypto-random, hex: 24 characters, well past the handler's
;; six-character floor, and typable off a terminal.
(define (fresh-password)
  (apply string-append
         (for/list ([b (in-bytes (crypto-random-bytes 12))])
           (define s (number->string b 16))
           (if (= 1 (string-length s)) (string-append "0" s) s))))

(define (cmd-reset username [pw #f])
  (define new (or pw (fresh-password)))
  (when (< (string-length new) 6) (die "a password must be at least 6 characters"))
  (with-db
    (lambda (conn)
      (define uid (query-maybe-value conn "SELECT id FROM users WHERE username = ?" username))
      (unless (string? uid)
        (die "no account called ~a — run `list` to see what exists" username))
      (set-password! conn uid new)
      (login-lock-clear! conn username)
      (define n (revoke-user-sessions! conn uid))
      ;; The entry names the TARGET's own team, because `audit-list` filters
      ;; `WHERE team_id = ?` and an entry with no team is invisible to everyone
      ;; whose account it concerns. Tenth appearance of that shape in this tree.
      ;; actor-type is `system`: there is no acting principal, which is the whole
      ;; reason this tool exists, and claiming one would name the wrong person.
      (define tid (first-team-for conn uid))
      (audit! conn #:action "user.password.reset" #:actor-type "system"
              #:team-id (or tid sql-null)
              #:resource-type "user" #:resource-id uid
              #:meta (format "{\"sessions_revoked\":~a,\"via\":\"telemachus-reset-login\"}" n))
      (printf "\n  username  ~a\n  password  ~a\n\n" username new)
      (printf "~a session(s) revoked. The reset is in the audit log as `user.password.reset`.\n" n)
      (when (not pw)
        (printf "This password is shown ONCE — it is a PBKDF2 hash in the database.\n")))))

(module+ main
  (define args (vector->list (current-command-line-arguments)))
  (cond
    [(or (null? args) (member (car args) '("-h" "--help" "help")))
     (printf (string-append
              "telemachus-reset-login — recover a sign-in when the operator token is gone\n\n"
              "  list                              who exists, and who HAS a password\n"
              "  reset <username> [password]       set it, clear the lock, revoke sessions, audit\n\n"
              "Run from the repo root inside `nix develop`; it reads DATABASE_URL.\n"))]
    [(string=? (car args) "list") (cmd-list)]
    [(string=? (car args) "reset")
     (when (null? (cdr args)) (die "reset needs a username — run `list` first"))
     (cmd-reset (cadr args) (and (pair? (cddr args)) (caddr args)))]
    [else (die "unknown command ~a — try --help" (car args))]))
