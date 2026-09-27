#lang racket/base

;; test/session-policy-tests.rkt — issue #38, the session timeouts.
;;
;; Three things are worth pinning here and only one of them is arithmetic:
;;   1. the policy DOCUMENT is validated, so a typo cannot disable the control;
;;   2. an org may TIGHTEN the instance policy and may never loosen it;
;;   3. the rule reaches `resolve-token`, applies to sessions, and leaves machine
;;      tokens alone — a weekly batch job is idle by design.
;;   raco test test/session-policy-tests.rkt

(require rackunit db-kit/portable db-kit/migrate
         "../domain/db/migrations.rkt"
         "db-fixture.rkt"
         "../domain/authz/authz.rkt"
         "../domain/authz/session-policy.rkt"
         "../domain/settings/settings.rkt")

(define (fresh)
  (define conn (fresh-db #:migrate? #f))
  (migrate! conn all-migrations)
  conn)

;; ---- the shipped posture ------------------------------------------------------

(test-case "the defaults sit inside the bands OWASP actually recommends"
  (define d (shipped-session-policy))
  ;; "15-30 minutes for low risk applications"
  (check-equal? (hash-ref d 'idle_seconds) 1800)
  (check-true (<= (* 15 60) (hash-ref d 'idle_seconds) (* 30 60)))
  ;; "between 4 and 8 hours" for a full-day office worker
  (check-true (<= (* 4 3600) (hash-ref d 'absolute_seconds) (* 8 3600)))
  ;; and the user is warned before it happens, which OWASP asks for
  (check-true (> (hash-ref d 'warn_seconds) 0))
  (check-true (< (hash-ref d 'warn_seconds) (hash-ref d 'idle_seconds))))

;; ---- validation ---------------------------------------------------------------

(test-case "a policy document is validated, because a control that silently does nothing is worse than none"
  (check-false (policy-problem (hasheq 'idle_seconds 900 'absolute_seconds 14400 'warn_seconds 60)))
  ;; null means "no limit on this axis", and is spelled explicitly
  (check-false (policy-problem (hasheq 'idle_seconds 'null 'absolute_seconds 'null)))
  (check-regexp-match #px"unknown field" (policy-problem (hasheq 'idle_minutes 30)))
  (check-regexp-match #px"at least 60 seconds" (policy-problem (hasheq 'idle_seconds 5)))
  (check-regexp-match #px"at most" (policy-problem (hasheq 'idle_seconds (* 400 24 3600))))
  (check-regexp-match #px"at least 300 seconds" (policy-problem (hasheq 'absolute_seconds 10)))
  (check-regexp-match #px"whole number" (policy-problem (hasheq 'idle_seconds "thirty")))
  (check-regexp-match #px"must be a JSON object" (policy-problem '()))
  ;; a warning that fires after the session is already gone is not a warning
  (check-regexp-match #px"must be less than idle_seconds"
                      (policy-problem (hasheq 'idle_seconds 300 'warn_seconds 300)))
  ;; an absolute cap below the idle window can never be reached by idling, so one
  ;; of the two numbers is not what the operator meant
  (check-regexp-match #px"must not be less than idle_seconds"
                      (policy-problem (hasheq 'idle_seconds 3600 'absolute_seconds 600))))

(test-case "a corrupt stored document reads as the shipped posture: the control fails CLOSED"
  (define conn (fresh))
  (setting-set! conn "session-policy" (hasheq 'nonsense #t))
  ;; normalize fills every field from the defaults, so nothing reads as "no limit"
  (check-equal? (hash-ref (session-policy-get conn) 'idle_seconds)
                (hash-ref (shipped-session-policy) 'idle_seconds)))

(test-case "the instance policy round-trips"
  (define conn (fresh))
  (session-policy-set! conn (hasheq 'idle_seconds 600 'absolute_seconds 7200 'warn_seconds 30))
  (define p (session-policy-get conn))
  (check-equal? (hash-ref p 'idle_seconds) 600)
  (check-equal? (hash-ref p 'absolute_seconds) 7200)
  (check-equal? (hash-ref p 'warn_seconds) 30))

;; ---- the two layers ----------------------------------------------------------

(test-case "an org may TIGHTEN the instance policy"
  (define conn (fresh))
  (session-policy-set! conn (hasheq 'idle_seconds 1800 'absolute_seconds 28800))
  (org-session-policy-set! conn "org-1" (hasheq 'idle_seconds 300 'absolute_seconds 3600))
  (define eff (session-policy-for conn "org-1"))
  (check-equal? (hash-ref eff 'idle_seconds) 300)
  (check-equal? (hash-ref eff 'absolute_seconds) 3600))

(test-case "an org may NOT loosen it — the instance owns the floor"
  (define conn (fresh))
  (session-policy-set! conn (hasheq 'idle_seconds 1800 'absolute_seconds 28800))
  ;; a company asking for a week of idle time gets the instance's thirty minutes.
  ;; This is the asymmetry with branding, where the org's document wins whole:
  ;; branding is cosmetic, this is a control, and an org admin must not be able to
  ;; remove the instance operator's security floor.
  (org-session-policy-set! conn "org-2" (hasheq 'idle_seconds (* 7 24 3600)
                                                'absolute_seconds (* 30 24 3600)))
  (define eff (session-policy-for conn "org-2"))
  (check-equal? (hash-ref eff 'idle_seconds) 1800)
  (check-equal? (hash-ref eff 'absolute_seconds) 28800))

(test-case "null on an org axis does not remove the instance limit on that axis"
  (define conn (fresh))
  (session-policy-set! conn (hasheq 'idle_seconds 1800 'absolute_seconds 28800))
  (org-session-policy-set! conn "org-3" (hasheq 'idle_seconds 'null 'absolute_seconds 600))
  (define eff (session-policy-for conn "org-3"))
  (check-equal? (hash-ref eff 'idle_seconds) 1800 "the instance's idle limit still applies")
  (check-equal? (hash-ref eff 'absolute_seconds) 600 "and the org tightened the other axis"))

(test-case "an instance that opts out lets an org set its own limits"
  (define conn (fresh))
  (session-policy-set! conn (hasheq 'idle_seconds 'null 'absolute_seconds 'null))
  (check-equal? (hash-ref (session-policy-for conn #f) 'idle_seconds) 'null)
  (org-session-policy-set! conn "org-4" (hasheq 'idle_seconds 900 'absolute_seconds 3600))
  (check-equal? (hash-ref (session-policy-for conn "org-4") 'idle_seconds) 900))

(test-case "an org with no policy of its own simply inherits, and clearing restores that"
  (define conn (fresh))
  (session-policy-set! conn (hasheq 'idle_seconds 1200 'absolute_seconds 7200))
  (check-false (org-session-policy-get conn "org-5"))
  (check-equal? (hash-ref (session-policy-for conn "org-5") 'idle_seconds) 1200)
  (org-session-policy-set! conn "org-5" (hasheq 'idle_seconds 120 'absolute_seconds 600))
  (check-equal? (hash-ref (session-policy-for conn "org-5") 'idle_seconds) 120)
  (org-session-policy-clear! conn "org-5")
  (check-false (org-session-policy-get conn "org-5"))
  (check-equal? (hash-ref (session-policy-for conn "org-5") 'idle_seconds) 1200))

;; ---- the rule ----------------------------------------------------------------

(define POLICY (hasheq 'idle_seconds 1800 'absolute_seconds 28800 'warn_seconds 60))
(define NOW 1000000)

(test-case "idle and absolute are separate clocks, and both bite"
  ;; fresh session: neither
  (check-false (session-timeout-reason POLICY SESSION-KIND NOW NOW #:now NOW))
  ;; unused for longer than the idle window
  (check-equal? (session-timeout-reason POLICY SESSION-KIND NOW (- NOW 1801) #:now NOW) 'idle)
  (check-false  (session-timeout-reason POLICY SESSION-KIND NOW (- NOW 1799) #:now NOW))
  ;; busy all day, but older than the absolute cap. THIS is the case the idle
  ;; clock cannot catch: a stolen token kept warm never idles out.
  (check-equal? (session-timeout-reason POLICY SESSION-KIND (- NOW 28801) NOW #:now NOW) 'absolute)
  (check-false  (session-timeout-reason POLICY SESSION-KIND (- NOW 28799) NOW #:now NOW))
  ;; idle is reported first when both have lapsed — it is the more specific reason
  (check-equal? (session-timeout-reason POLICY SESSION-KIND (- NOW 99999) (- NOW 99999) #:now NOW) 'idle))

(test-case "a machine token is never idled out: being idle is its job"
  (for ([kind (in-list (list API-KIND WORKER-KIND))])
    (check-false (session-timeout-reason POLICY kind (- NOW 99999) (- NOW 99999) #:now NOW)
                 (format "~a must be exempt" kind))))

(test-case "a policy with no limits expires nothing"
  (define off (hasheq 'idle_seconds 'null 'absolute_seconds 'null 'warn_seconds 0))
  (check-false (session-timeout-reason off SESSION-KIND (- NOW 99999) (- NOW 99999) #:now NOW)))

(test-case "a pre-migration row has NULL clocks and is left alone"
  ;; this is the upgrade path: nobody is signed out by deploying the feature
  (check-false (session-timeout-reason POLICY SESSION-KIND #f #f #:now NOW))
  ;; the two clocks are judged INDEPENDENTLY: whichever one the row carries is
  ;; enforced, and the missing one simply cannot fire
  (check-equal? (session-timeout-reason POLICY SESSION-KIND #f (- NOW 99999) #:now NOW) 'idle
                "a known last-use still idles out even with no creation time")
  (check-equal? (session-timeout-reason POLICY SESSION-KIND (- NOW 99999) #f #:now NOW) 'absolute
                "and a known creation time still caps it with no last-use"))

;; ---- end to end through resolve-token ----------------------------------------

(define (backdate! conn raw #:used [used #f] #:created [created #f])
  ;; reach past the API on purpose: the point is to age a row without sleeping
  (define h (query-value conn "SELECT token_hash FROM api_tokens WHERE prefix = ?"
                         (substring raw 0 11)))
  (when used    (query-exec conn "UPDATE api_tokens SET last_used_epoch = ? WHERE token_hash = ?" used h))
  (when created (query-exec conn "UPDATE api_tokens SET created_epoch = ? WHERE token_hash = ?" created h))
  h)

(test-case "a session that has gone idle stops resolving, and says why in its status"
  (define conn (fresh))
  (define-values (uid tid) (bootstrap! conn #:username "alice"))
  (session-policy-set! conn (hasheq 'idle_seconds 60 'absolute_seconds 3600 'warn_seconds 10))
  (define-values (raw _t) (issue-token! conn #:user uid #:team tid #:scopes '("*:*") #:kind SESSION-KIND))
  ;; it works now
  (check-true (and (resolve-token conn raw) #t))
  ;; ...and not after sitting for longer than the idle window
  (define h (backdate! conn raw #:used (- (current-seconds) 61)))
  (check-false (resolve-token conn raw))
  (check-equal? (query-value conn "SELECT status FROM api_tokens WHERE token_hash = ?" h)
                "expired-idle"
                "revoked server-side, which OWASP calls the mandatory half")
  ;; and it stays dead even if the clock is touched afterwards
  (backdate! conn raw #:used (current-seconds))
  (check-false (resolve-token conn raw) "a lapsed session cannot be revived by using it"))

(test-case "a session older than the absolute cap stops resolving however active it was"
  (define conn (fresh))
  (define-values (uid tid) (bootstrap! conn #:username "bob"))
  (session-policy-set! conn (hasheq 'idle_seconds 1800 'absolute_seconds 3600))
  (define-values (raw _t) (issue-token! conn #:user uid #:team tid #:scopes '("*:*") #:kind SESSION-KIND))
  (define h (backdate! conn raw #:created (- (current-seconds) 3601) #:used (current-seconds)))
  (check-false (resolve-token conn raw))
  (check-equal? (query-value conn "SELECT status FROM api_tokens WHERE token_hash = ?" h)
                "expired-absolute"))

(test-case "an API token with the same age keeps working"
  (define conn (fresh))
  (define-values (uid tid) (bootstrap! conn #:username "carol"))
  (session-policy-set! conn (hasheq 'idle_seconds 60 'absolute_seconds 300))
  ;; the default kind is the exempt one, so a caller that forgets #:kind cannot
  ;; accidentally mint a credential that idles out
  (define-values (raw _t) (issue-token! conn #:user uid #:team tid #:scopes '("*:*")))
  (backdate! conn raw #:created (- (current-seconds) 99999) #:used (- (current-seconds) 99999))
  (check-true (and (resolve-token conn raw) #t) "a machine token is not a session"))

(test-case "using a session keeps it alive, and the idle clock is what moves"
  (define conn (fresh))
  (define-values (uid tid) (bootstrap! conn #:username "dave"))
  (session-policy-set! conn (hasheq 'idle_seconds 600 'absolute_seconds 3600))
  (define-values (raw _t) (issue-token! conn #:user uid #:team tid #:scopes '("*:*") #:kind SESSION-KIND))
  (define h (backdate! conn raw #:used (- (current-seconds) 599)))   ; nearly, but not quite
  (check-true (and (resolve-token conn raw) #t))
  (define after (query-value conn "SELECT last_used_epoch FROM api_tokens WHERE token_hash = ?" h))
  (check-true (>= (if (number? after) after (string->number (format "~a" after)))
                  (- (current-seconds) 5))
              "resolving a token refreshes its idle clock"))

(test-case "the org's tighter policy reaches resolve-token for a user in that org"
  (define conn (fresh))
  (define-values (uid tid) (bootstrap! conn #:username "erin"))
  (define org (query-value conn "SELECT org_id FROM teams WHERE id = ?" tid))
  (session-policy-set! conn (hasheq 'idle_seconds 1800 'absolute_seconds 28800))
  (org-session-policy-set! conn org (hasheq 'idle_seconds 60 'absolute_seconds 600))
  (define-values (raw _t) (issue-token! conn #:user uid #:team tid #:scopes '("*:*") #:kind SESSION-KIND))
  (backdate! conn raw #:used (- (current-seconds) 61))
  ;; the instance would still allow this; the org's own policy is what ends it
  (check-false (resolve-token conn raw)))

(test-case "the listing tells an operator which credential is a browser session"
  (define conn (fresh))
  (define-values (uid tid) (bootstrap! conn #:username "frank"))
  (define-values (_s _st) (issue-token! conn #:user uid #:team tid #:name "login" #:scopes '("*:*") #:kind SESSION-KIND))
  (define-values (_a _at) (issue-token! conn #:user uid #:team tid #:name "ci" #:scopes '("files:read")))
  (define kinds (for/list ([t (in-list (list-tokens conn tid))]) (hash-ref t 'kind)))
  (check-not-false (member SESSION-KIND kinds) "a session is labelled")
  (check-not-false (member API-KIND kinds) "and so is a machine token"))
