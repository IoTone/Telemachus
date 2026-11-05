#lang racket/base

;; server/admission.rkt — the gates a request passes before it costs
;; anything: the governor slot, the quota refusal and its hold reason, and
;; the idempotency key
;;
;; Split out of main.rkt by #110 r3. The shared surface every handler here
;; needs — the pool, the request accessors, with-auth/with-mt, the response
;; constructors — is server/kit.rkt.

(provide GOV quota-429 quota-hold-reason note-deferred! idem-key-of
         with-idem
         ;; SEC-13, plus the constants FOR test/token-redeem-tests.rkt
         redeem-throttled? REDEEM-IP-MAX REDEEM-WINDOW)

(require db-kit/portable
         json
         web-kit
         (only-in "../domain/authz/authz.rkt" audit! principal-team-id team-org)
         (only-in "../domain/quota/quota.rkt" quota-check window-bounds window-resets-at)
         (only-in "../domain/sched/governor.rkt" make-governor)
         (only-in "../domain/idem/idem.rkt" idem-fingerprint idem-lookup idem-store!)
         (only-in "../domain/beta/antispam.rkt" make-limiter limiter-allow?)
         "kit.rkt")

;; ---- SEC-13: redeeming a mailed token costs work, and it was free ---------------
;; `POST /api/activate` and `POST /api/password-reset/confirm` are PUBLIC and each
;; does a peppered HMAC and an indexed SELECT per call. The first security pass
;; recorded the first of them as unthrottled and called it defence in depth at
;; 192 bits of `crypto-random-bytes`, which is right about GUESSING — and the
;; third pass measured that the SECOND one arrived afterwards, in the same class,
;; with nothing re-running the survey. So this is not really about guessing a
;; token; it is that an unauthenticated caller could make this instance do
;; unbounded keyed-hash and database work, which is the same shape as the
;; `GET /api/i18n/catalog` amplification the same pass left open.
;;
;; ONE LIMITER FOR BOTH, because the resource is one: the cost of a redemption
;; attempt. Two budgets would be two halves of one thing and would double what
;; an attacker can spend — LIVE-IN's argument, in a throttle.
;;
;; KEYED ON THE ADDRESS, because there is nothing else: the token IS the only
;; other identifier, and keying on it is exactly what an attacker varies. In
;; memory and per process for the reason `client-ip-of`'s own note gives — an
;; address is a THROTTLE, so a restart clearing it costs nothing and an attacker
;; changing address defeats it anyway, while an account LOCK is a control and
;; needs a row.
;;
;; GENEROUS ON PURPOSE, AND THE COST IS STATED. A shared NAT means one bad actor
;; can spend an office's allowance, so an onboarding day of twenty people behind
;; one address must not be locked out of activating — which is why it is 30 in
;; fifteen minutes rather than the login's 20 a minute, a trade this platform
;; already accepts one route along and tighter. The window self-clears, so unlike
;; #116's account lock there is no state only an operator can clear: the way back
;; in cannot be closed by this.
(define REDEEM-IP-MAX 30)
(define REDEEM-WINDOW 900)
(define redeem-ip-limiter (make-limiter))

(define (redeem-throttled? ip)
  (not (limiter-allow? redeem-ip-limiter ip (current-seconds)
                       #:max REDEEM-IP-MAX #:window REDEEM-WINDOW)))

;; ---- AI jobs: RBAC → quota → governor slot → meter --------------------------
(define GOV (make-governor))

(define (quota-429 d dim)
  (json-response (hasheq 'error "quota exceeded" 'dimension dim
                         'subject (hash-ref d 'subject "team")   ; which tier refused: team | org
                         'used (hash-ref d 'used) 'limit (hash-ref d 'limit)
                         'window (hash-ref d 'window)
                         ;; "come back then" rather than "come back later" (issue #55)
                         'resets_at (or (window-resets-at db-conn (hash-ref d 'window)) 'null))
                 #:code 429))

;; ---- issue #55: a deferred job says which limit holds it --------------------
;; An over-budget team's jobs stay `queued` — the right behaviour, and until now
;; an invisible one. A queue that stops with nothing running, nothing in the
;; audit log and no reason on the job is indistinguishable from a hang, and the
;; operating notes' warning that "a batch extraction stops after the first jobs
;; and looks like a hang" was being read as a bug report rather than as a budget.
;;
;; WHICH limit, in the order the admission check applies them: the team's own
;; dimensions first, then the company's, and the first that refuses is the
;; answer, because that is the one somebody has to raise. `amount 1` is the
;; probe the admission itself makes — is there room for one more unit at all.
;; `feed.fetches` is here for FEED-9's reason, which is not the same as the AI
;; dimensions': it protects the SOURCE's rate limit as much as this instance. A
;; team over its fetch budget must have its feeds STOP rather than keep hammering
;; somebody else's API — and because a poll is an ordinary job, holding the queue
;; is all that takes.
(define QUOTA-HOLD-DIMS '("ai.requests" "ai.tokens.total" "ai.judgments.total"
                          ;; #163 (EMB-6). Here for JUDGE-10's reason: where an
                          ;; operator HAS set a limit, reaching it should hold
                          ;; the team's queue rather than fail the jobs — an
                          ;; embedding is spent inside a scheduler job like every
                          ;; other model call. There is no default limit, so on
                          ;; an instance nobody configured this holds nothing.
                          "ai.embeddings.total"
                          ;; #183 (HELP‑21). Same reason again: no default limit,
                          ;; so on an instance nobody configured this holds
                          ;; nothing — but where an operator HAS bounded help,
                          ;; reaching the bound should hold the queue rather than
                          ;; fail work, because the dimension is also spent by
                          ;; anything that answers a question inside a job.
                          "ai.help.total"
                          ;; #192 (VOICE-11). Same reason a third time: no default
                          ;; limit, so an instance nobody configured holds
                          ;; nothing — and where an operator HAS bounded
                          ;; transcription, reaching the bound holds the queue
                          ;; rather than failing a transcription pass halfway
                          ;; through a batch of recordings.
                          "ai.transcriptions.total"
                          "feed.fetches"
                          ;; #191 (RG-12's half of it). FEED-9's argument, for
                          ;; the same kind of resource: the dimension protects
                          ;; somebody ELSE's site as much as this instance, so a
                          ;; team over its fetch budget must have its re-fetches
                          ;; STOP rather than keep asking. There is no default
                          ;; limit, so on an instance nobody configured this
                          ;; holds nothing.
                          "research.fetches"))

;; PURE, deliberately: the job listing calls this on every read (`team-hold` in
;; scheduler.rkt). The audit entry is `note-deferred!`'s business, and fires only
;; where a claim was really deferred.
(define (quota-hold-reason conn team)
  (define org (team-org conn team))
  (or (quota-hold-at conn "team" team)
      (and org (quota-hold-at conn "org" org))))

(define (quota-hold-at conn scope subject)
  (for/or ([dim (in-list QUOTA-HOLD-DIMS)])
    (define d (quota-check conn scope subject dim 1))
    (and (not (hash-ref d 'allowed))
         (hasheq 'reason "quota" 'scope scope 'dimension dim
                 'used (hash-ref d 'used) 'limit (hash-ref d 'limit)
                 'window (hash-ref d 'window)
                 ;; when work resumes, which is the whole question a held team has
                 'resets_at (or (window-resets-at conn (hash-ref d 'window)) 'null)))))

;; ONE audit entry per window per (scope, subject, dimension) — not one per
;; deferred claim. Every pool tick re-tries every queued job, so a team that is
;; over budget for an hour would otherwise write thousands of identical rows and
;; bury the one entry that matters.
;;
;; The dedup asks the AUDIT LOG, not a table of its own and not an in-memory set:
;; the log is already the record, a second store is a second thing that can
;; disagree with it, and an in-memory one would forget on restart and re-announce
;; what the operator has already read. `at_us` is epoch microseconds (issue #47),
;; so "within this window" is one indexed comparison.
;;
;; A sliding or unbounded window ("minute", "total") has no start, so there is
;; nothing to be once-per; those are floored at one entry an hour instead, which
;; keeps the log readable without inventing a boundary that does not exist.
(define NOTE-FLOOR-SECONDS 3600)

;; `team-id` is the DEFERRED job's team even when the ORG's budget is what holds
;; it, because `audit-list` filters by team: an entry carrying the org instead
;; would be invisible to exactly the people whose work stopped.
(define (note-deferred! conn team job-id reason)
  (when (equal? (hash-ref reason 'reason #f) "quota")
    (define rid (format "~a:~a:~a" (hash-ref reason 'scope) team (hash-ref reason 'dimension)))
    (define-values (start _end) (window-bounds conn (hash-ref reason 'window)))
    (define horizon (* 1000000 (or start (- (current-seconds) NOTE-FLOOR-SECONDS))))
    (define seen (query-value conn
      "SELECT COUNT(*) FROM audit_log WHERE action = ? AND resource_id = ? AND at_us >= ?"
      "quota.exhausted" rid horizon))
    (when (zero? seen)
      (audit! conn #:action "quota.exhausted" #:actor-type "system"
              #:team-id team #:resource-type "quota" #:resource-id rid
              #:result "deferred"
              #:meta (jsexpr->string (hash-set reason 'job_id job-id))))))

;; ---- idempotency keys (issue #90) -------------------------------------------
;; A client names its retry with `Idempotency-Key` (or `idempotency_key` in the
;; body, for a caller that cannot set headers — a webhook-style integration
;; often cannot). The thunk returns `(values jsexpr code)` rather than a
;; response, because the STORED thing has to be the answer's content and its
;; code: a `response` object's body is an output procedure and cannot be read
;; back, and rebuilding it later from the handler would not be the first call's
;; answer, which is the whole point.
(define (idem-key-of req b)
  (define h (req-header req #"idempotency-key"))
  (define bk (and (hash? b) (let ([v (hash-ref b 'idempotency_key #f)])
                              (and (string? v) (not (string=? v "")) v))))
  (or (and h (not (string=? h "")) h) bk))

;; `#:key` overrides what the request carries, for r2's DERIVED key. Passing it
;; in beats synthesising a fake request with an extra header: a request object is
;; the listener's, and faking one to carry a value we already have in hand is the
;; kind of indirection that makes the next reader hunt for a header nobody sent.
(define (with-idem req p b #:endpoint endpoint #:payload payload #:key [key* #f] proc)
  (define key (or key* (idem-key-of req b)))
  (cond
    ;; no key: exactly the behaviour every caller had before this existed
    [(not key) (let-values ([(jsx code) (proc)]) (json-response jsx #:code code))]
    [else
     (define team (principal-team-id p))
     (define fp (idem-fingerprint endpoint payload))
     (define seen (idem-lookup db-conn team key endpoint fp))
     (cond
       ;; the ORIGINAL answer and the ORIGINAL code, which is what a client that
       ;; never saw the first response needs. `idempotent_replay` is added so a
       ;; caller can TELL — a silent replay and a fresh success are
       ;; indistinguishable otherwise, and an integrator debugging a double-send
       ;; needs to know which happened.
       [(hash? seen)
         (json-response (if (hash? (hash-ref seen 'hit))
                           (hash-set (hash-ref seen 'hit) 'idempotent_replay #t)
                           (hash-ref seen 'hit))
                       #:code (hash-ref seen 'code))]
       ;; same key, different request: answering either one would be wrong —
       ;; replaying the first hides the second, performing the second breaks the
       ;; promise the key made.
       [(eq? seen 'conflict)
         (err (string-append "this Idempotency-Key was already used for a different request"
                            " — use a new key, or resend the original request unchanged")
             409)]
       [else
         (define-values (jsx code) (proc))
        ;; stored only on SUCCESS. A failure is not an outcome worth replaying:
        ;; the retry that follows a 500 is the retry this feature is for, and
        ;; freezing the 500 would make the key a way to guarantee failure.
         (when (and (>= code 200) (< code 300))
          (idem-store! db-conn team key endpoint fp jsx code))
         (json-response jsx #:code code)])]))
