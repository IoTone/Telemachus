#lang racket/base

;; test/signin-tests.rkt — the sign-in path (issues #116, #117, #118).
;;
;; Three reports, one code path. What has to hold:
;;   1. a failure for an UNKNOWN account costs what a wrong password costs (#117)
;;   2. attempts are counted, the delay grows, the window forgets, and a hard
;;      lock is OFF unless an operator asks for it (#116)
;;   3. a person can see and end their OWN sessions and nobody else's, and the
;;      per-identity cap evicts the oldest rather than refusing the newest (#118)
;;
;;   raco test test/signin-tests.rkt

(require rackunit racket/list db-kit/portable
         db-kit/migrate
         "../domain/db/migrations.rkt"
         "db-fixture.rkt"
         "../domain/authz/authz.rkt"
         (only-in "../domain/authz/passwords.rkt" verify-absent-password))

(define (fresh) (define c (fresh-db #:migrate? #f)) (migrate! c all-migrations) c)
(define (setup)
  (define c (fresh))
  (define-values (owner team) (bootstrap! c #:username "root" #:password "root-pass-1"))
  (define bob (create-user! c #:username "bob" #:password "bob-pass-1"))
  (add-member! c #:user bob #:team team #:role "member")
  (values c owner team bob))

;; ---- 1. the failure paths cost the same (#117) -------------------------------
;; A timing assertion is flaky by nature, so this is written as a LOWER BOUND on
;; the cheap path measured against the cost of one KDF run in the same process:
;; both are the same operation, so the ratio is stable where an absolute
;; millisecond figure would not be. Against the old code the unknown-username
;; path was a bare `#f` after one indexed SELECT and this fails by a wide margin
;; — which is the only reason the test is worth having.
(define (ms thunk)
  (define t0 (current-inexact-milliseconds))
  (thunk)
  (- (current-inexact-milliseconds) t0))

(test-case "verify-absent-password runs the KDF and always answers #f"
  (check-false (verify-absent-password "anything"))
  (check-false (verify-absent-password #f) "a non-string must not raise on this path")
  ;; warm the promise, then measure
  (void (verify-absent-password "x"))
  (check-true (> (ms (lambda () (verify-absent-password "x"))) 0.2)
              "one dummy verify is not free — if it were, it would equalise nothing"))

(test-case "an unknown username costs what a wrong password costs"
  (define-values (c owner team bob) (setup))
  (void (authenticate c "bob" "wrong-on-purpose"))        ; warm both paths
  (void (authenticate c "nobody-at-all" "wrong-on-purpose"))
  (define wrong-pw (ms (lambda () (authenticate c "bob" "wrong-on-purpose"))))
  (define unknown  (ms (lambda () (authenticate c "nobody-at-all" "wrong-on-purpose"))))
  (check-false (authenticate c "nobody-at-all" "wrong-on-purpose"))
  (check-true (> unknown (* 0.4 wrong-pw))
              (format "unknown-username ~ams vs wrong-password ~ams — the KDF must run on both"
                      unknown wrong-pw))
  (disconnect c))

(test-case "…and so does an account with NO password hash"
  ;; POST /api/orgs without owner_password creates exactly this, so it is not a
  ;; hypothetical row. It used to be the second cheap path.
  (define-values (c owner team bob) (setup))
  (define ghost (create-user! c #:username "ghost" #:password #f))
  (check-true (sql-null? (query-value c "SELECT password_hash FROM users WHERE id = ?" ghost))
              "the fixture really has a NULL hash")
  (void (authenticate c "ghost" "anything"))
  (define null-hash (ms (lambda () (authenticate c "ghost" "anything"))))
  (define wrong-pw  (ms (lambda () (authenticate c "bob" "wrong-on-purpose"))))
  (check-false (authenticate c "ghost" "anything"))
  (check-true (> null-hash (* 0.4 wrong-pw))
              (format "null-hash ~ams vs wrong-password ~ams" null-hash wrong-pw))
  (disconnect c))

;; ---- 2. the attempt throttle (#116) -----------------------------------------
(test-case "the delay is zero while typos are plausible, then grows and is capped"
  (check-equal? (login-delay-for 1) 0)
  (check-equal? (login-delay-for 3) 0 "three is still a typo")
  (check-equal? (login-delay-for 4) 2)
  (check-equal? (login-delay-for 5) 4)
  (check-equal? (login-delay-for 6) 8)
  (check-equal? (login-delay-for 40) 60 "capped, so it never becomes a permanent lock by accident"))

(test-case "a fresh account is not throttled, and failures accumulate"
  (define-values (c owner team bob) (setup))
  (check-false (login-throttle c "bob") "nothing recorded yet")
  (for ([_ (in-range 3)]) (login-failed! c "bob"))
  (check-false (login-throttle c "bob") "the free tries cost nothing")
  (define-values (n locked?) (login-failed! c "bob"))
  (check-equal? n 4)
  (check-false locked? "no hard lock unless the operator asked for one")
  (define hold (login-throttle c "bob"))
  (check-true (pair? hold) "the fourth failure starts costing")
  (check-equal? (car hold) 'wait)
  (check-true (and (> (cdr hold) 0) (<= (cdr hold) 2)))
  (disconnect c))

(test-case "a success forgets the history"
  (define-values (c owner team bob) (setup))
  (for ([_ (in-range 6)]) (login-failed! c "bob"))
  (check-true (pair? (login-throttle c "bob")))
  (login-succeeded! c "bob")
  (check-false (login-throttle c "bob") "the counter is gone, not merely reset to a smaller delay")
  (disconnect c))

(test-case "the window forgets, so a typo last week does not cost anything today"
  (define-values (c owner team bob) (setup))
  (for ([_ (in-range 6)]) (login-failed! c "bob"))
  (check-true (pair? (login-throttle c "bob")))
  ;; age the row past the window rather than sleeping
  (query-exec c "UPDATE login_throttle SET last_failure_epoch = ? WHERE username = ?"
              (- (current-seconds) 100000) "bob")
  (check-false (login-throttle c "bob"))
  ;; …and the COUNT is forgotten too, not just the delay — otherwise a lock would
  ;; eventually trip on failures weeks apart
  (define-values (n _l) (login-failed! c "bob"))
  (check-equal? n 1 "the count restarts with the window")
  (disconnect c))

(test-case "the hard lock is off by default and on when the operator says so"
  (define-values (c owner team bob) (setup))
  (check-false (login-lock-after) "unset means throttle only")
  (for ([_ (in-range 12)]) (login-failed! c "bob"))
  (check-true (pair? (login-throttle c "bob")) "throttled, never locked")
  (disconnect c)
  ;; the env var is process-global, so it is restored in a dynamic-wind — a
  ;; failing check raises, and a leaked lock setting would fail later files
  (define c2 (fresh))
  (define old (getenv "TELEMACHUS_LOGIN_LOCK_FAILURES"))
  (dynamic-wind
   (lambda () (putenv "TELEMACHUS_LOGIN_LOCK_FAILURES" "5"))
   (lambda ()
     (check-equal? (login-lock-after) 5)
     (for ([_ (in-range 4)]) (login-failed! c2 "carol"))
     (check-not-equal? (login-throttle c2 "carol") 'locked "four is not five")
     (define-values (n locked?) (login-failed! c2 "carol"))
     (check-equal? n 5)
     (check-true locked?)
     (check-equal? (login-throttle c2 "carol") 'locked)
     ;; the only way back in, and the reason ep-admin-password-reset calls it
     (login-lock-clear! c2 "carol")
     (check-false (login-throttle c2 "carol")))
   (lambda () (if old (putenv "TELEMACHUS_LOGIN_LOCK_FAILURES" old)
                  (putenv "TELEMACHUS_LOGIN_LOCK_FAILURES" ""))))
  (disconnect c2))

;; ---- 3. a person's own sessions (#118) ---------------------------------------
(test-case "the listing is the caller's own SESSIONS and nothing else"
  (define-values (c owner team bob) (setup))
  (define-values (s1 _1) (issue-token! c #:user bob #:team team #:name "laptop"
                                       #:scopes '("*:*") #:kind SESSION-KIND))
  (define-values (api _2) (issue-token! c #:user bob #:team team #:name "ci" #:scopes '("files:read")))
  (define-values (other _3) (issue-token! c #:user owner #:team team #:name "root's"
                                          #:scopes '("*:*") #:kind SESSION-KIND))
  (define ss (user-sessions c bob))
  (check-equal? (length ss) 1 "the api token is not a session and root's is not bob's")
  (check-equal? (hash-ref (car ss) 'name) "laptop")
  ;; the prefix is enough to tell two apart and useless as a credential
  (check-true (string? (hash-ref (car ss) 'prefix)))
  (check-false (regexp-match? (regexp (regexp-quote (hash-ref (car ss) 'prefix)))
                              (substring s1 11))
               "the listing shows a PREFIX, and the rest of the token is not in it")
  (disconnect c))

(test-case "`current` marks the session the caller is holding"
  (define-values (c owner team bob) (setup))
  (define-values (s1 id1) (issue-token! c #:user bob #:team team #:name "laptop"
                                        #:scopes '("*:*") #:kind SESSION-KIND))
  (define-values (s2 id2) (issue-token! c #:user bob #:team team #:name "phone"
                                        #:scopes '("*:*") #:kind SESSION-KIND))
  ;; `created_epoch` is seconds, so two sign-ins in the same second TIE and the
  ;; order is the engine's. Age the older one rather than assert on luck.
  (query-exec c "UPDATE api_tokens SET created_epoch = ? WHERE id = ?"
              (- (current-seconds) 60) id1)
  (check-equal? (token-id-for-bearer c s2) id2)
  (check-false (token-id-for-bearer c "not-a-token"))
  (define ss (user-sessions c bob #:current id2))
  (check-equal? (for/list ([x (in-list ss)]) (cons (hash-ref x 'name) (hash-ref x 'current)))
                '(("phone" . #t) ("laptop" . #f))
                "newest first, and exactly one of them is current")
  (disconnect c))

(test-case "a member cannot end somebody else's session by guessing its id"
  (define-values (c owner team bob) (setup))
  (define-values (mine id-mine) (issue-token! c #:user bob #:team team #:scopes '("*:*") #:kind SESSION-KIND))
  (define-values (theirs id-theirs) (issue-token! c #:user owner #:team team #:scopes '("*:*") #:kind SESSION-KIND))
  (define-values (api id-api) (issue-token! c #:user bob #:team team #:scopes '("files:read")))
  (check-false (revoke-session! c bob id-theirs) "not bob's row")
  (check-false (revoke-session! c bob id-api) "bob's, but not a SESSION — that is the team's token route")
  (check-false (revoke-session! c bob "no-such-id"))
  (check-true (revoke-session! c bob id-mine))
  (check-true (principal? (resolve-token c theirs)) "…and the other two still work")
  (check-true (principal? (resolve-token c api)))
  (check-false (resolve-token c mine))
  (disconnect c))

(test-case "sign out everywhere else keeps the session you are using"
  (define-values (c owner team bob) (setup))
  (define-values (a ida) (issue-token! c #:user bob #:team team #:scopes '("*:*") #:kind SESSION-KIND))
  (define-values (b idb) (issue-token! c #:user bob #:team team #:scopes '("*:*") #:kind SESSION-KIND))
  (define-values (api idapi) (issue-token! c #:user bob #:team team #:scopes '("files:read")))
  (check-equal? (revoke-other-sessions! c bob idb) 1 "one other session")
  (check-false (resolve-token c a))
  (check-true (principal? (resolve-token c b)) "the caller's own survives")
  (check-true (principal? (resolve-token c api)) "a machine token is not a session")
  (disconnect c))

(test-case "the cap evicts the OLDEST and never refuses a sign-in"
  (define-values (c owner team bob) (setup))
  (define old (getenv "TELEMACHUS_MAX_SESSIONS"))
  (dynamic-wind
   (lambda () (putenv "TELEMACHUS_MAX_SESSIONS" "3"))
   (lambda ()
     (check-equal? (max-sessions) 3)
     (define toks
       (for/list ([i (in-range 5)])
         (define-values (t id) (issue-token! c #:user bob #:team team #:name (format "dev~a" i)
                                             #:scopes '("*:*") #:kind SESSION-KIND))
         ;; created_epoch is seconds, so five in one second would tie — age each
         ;; one so "oldest" is well defined. A test that asserts an order on rows
         ;; written in the same second flaps (the trap doc_trigger_fires named).
         (query-exec c "UPDATE api_tokens SET created_epoch = ? WHERE id = ?"
                     (+ (current-seconds) i) id)
         (define evicted (enforce-session-cap! c bob))
         (cons t evicted)))
     (check-equal? (map (lambda (x) (length (cdr x))) toks) '(0 0 0 1 1)
                   "nothing evicted until the cap is reached, then one per sign-in")
     ;; the newest three live, the oldest two are gone — and the FIFTH, the one
     ;; that would have been refused by a cap that refuses, is among the living
     (check-equal? (for/list ([x (in-list toks)]) (and (resolve-token c (car x)) #t))
                   '(#f #f #t #t #t)))
   (lambda () (if old (putenv "TELEMACHUS_MAX_SESSIONS" old) (putenv "TELEMACHUS_MAX_SESSIONS" ""))))
  (disconnect c))

(test-case "the cap can be turned off, and a nonsense value falls back to the default"
  (define old (getenv "TELEMACHUS_MAX_SESSIONS"))
  (dynamic-wind
   void
   (lambda ()
     (putenv "TELEMACHUS_MAX_SESSIONS" "never") (check-false (max-sessions))
     (putenv "TELEMACHUS_MAX_SESSIONS" "0")     (check-false (max-sessions))
     ;; never to 0 — the platform's rule for every knob
     (putenv "TELEMACHUS_MAX_SESSIONS" "banana") (check-equal? (max-sessions) 10)
     (putenv "TELEMACHUS_MAX_SESSIONS" "-4")     (check-equal? (max-sessions) 10))
   (lambda () (if old (putenv "TELEMACHUS_MAX_SESSIONS" old) (putenv "TELEMACHUS_MAX_SESSIONS" "")))))

;; ---- a monitoring credential (issue #124) -----------------------------------
;; The operational read routes all required `instance:manage`, and a token with
;; that permission can reset any user's password and rewrite instance settings —
;; so a monitoring credential was a full operator credential, which is the one
;; credential a monitoring system should never hold.
;;
;; The fix is a NARROWER PERMISSION, not a new tier: the monitoring credential is
;; an operator-issued token SCOPED to `instance:read`. The scope is what caps it
;; (RBAC-4), and before this there was no scope that let a token read the fleet
;; without also permitting the password reset.
(require (only-in "../domain/authz/permissions.rkt" perm-matches? all-permissions))

(test-case "instance:manage implies instance:read, and NOT the other way"
  ;; the asymmetry IS the feature. TEN-2h had to special-case the opposite
  ;; direction for org:read-data, so an error either way is a silent privilege
  ;; change — hence both halves.
  (check-true  (perm-matches? "instance:manage" "instance:read"))
  (check-false (perm-matches? "instance:read" "instance:manage")
               "a monitoring token must not reach the mutating routes")
  (check-true  (perm-matches? "instance:*" "instance:read"))
  (check-true  (perm-matches? "*:*" "instance:read"))
  ;; it must not leak sideways either
  (check-false (perm-matches? "instance:read" "org:manage"))
  (check-false (perm-matches? "instance:read" "files:read"))
  (check-false (perm-matches? "org:*" "instance:read")))

(test-case "instance:read is in the catalog, so GET /api/roles can describe it"
  ;; a permission a built-in role grants without a description is a LOAD error,
  ;; and #110 r4's reverse gate refuses one that no route enforces
  (check-true (and (member "instance:read" (all-permissions)) #t)))

(test-case "a token scoped to instance:read reads, and cannot administer"
  (define-values (c owner team bob) (setup))
  ;; the operator's own credential, narrowed by its scope list — this is what a
  ;; monitoring system is given
  (define-values (mon _m) (issue-token! c #:user owner #:team team #:name "monitoring"
                                        #:scopes '("instance:read") #:ttl 'never))
  (define p (resolve-token c mon))
  (check-true (principal? p))
  (check-true (can? c p "instance:read") "the operational reads")
  (check-false (can? c p "instance:manage")
               "…and not the password reset, the branding write, or POST /api/orgs")
  (check-false (can? c p "org:manage"))
  ;; the operator's UNSCOPED credential keeps everything, which is the
  ;; compatibility half: no route an operator had is taken away
  (define-values (full _f) (issue-token! c #:user owner #:team team #:scopes '("*:*") #:ttl 'never))
  (define fp (resolve-token c full))
  (check-true (can? c fp "instance:read"))
  (check-true (can? c fp "instance:manage"))
  ;; and a plain member reaches neither, with or without a scope
  (define bp (user-principal c bob team))
  (check-false (can? c bp "instance:read") "the instance tier is the operator's")
  (disconnect c))
