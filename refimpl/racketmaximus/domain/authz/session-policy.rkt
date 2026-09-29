#lang racket/base

;; domain/authz/session-policy.rkt — how long a signed-in session may live.
;;
;; Issue #38, following the OWASP Session Management Cheat Sheet, which asks for
;; TWO clocks and not one:
;;
;;   idle      how long a session may sit unused. OWASP: "2-5 minutes for
;;             high-value applications and 15-30 minutes for low risk ones."
;;   absolute  how long a session may live at all, however busy. OWASP: "if the
;;             application is intended to be used by an office worker for a full
;;             day, an appropriate absolute timeout range could be between 4 and
;;             8 hours."
;;
;; They answer different attacks. Idle limits the window on an unattended desk;
;; absolute limits the window on a token that was copied and is being kept warm.
;; A stolen token that is USED every minute never idles out, which is exactly why
;; the absolute cap is not redundant.
;;
;; Two layers, as the issue asks: an instance default and an org policy. Both are
;; documents in the same `instance_settings` table branding and localization use,
;; so the org layer needs no migration — `session-policy` and
;; `session-policy:<org-id>`, the same shape TEN-2d gave branding.
;;
;; **AN ORG MAY TIGHTEN THE INSTANCE POLICY AND MAY NEVER LOOSEN IT.** This is the
;; one real policy decision in the file. The instance operator owns the compliance
;; posture of the box; if an org admin could raise their own idle timeout, the
;; instance's floor would be advisory and a single compromised org admin could
;; remove it. So the effective value is the STRICTER of the two, per field, and an
;; org that asks for eight hours against an instance default of thirty minutes
;; gets thirty minutes rather than an error. Note it is a deliberate asymmetry
;; with branding, where the org's document wins whole: branding is cosmetic and
;; this is a control.
;;
;; Enforcement is in `resolve-token` and nowhere else, because that is the one
;; place a bearer becomes a principal. OWASP is explicit that server-side
;; invalidation is "the most relevant and mandatory"; a client-side timer is a
;; courtesy on top, never the mechanism.

(require db-kit/portable racket/string json "../settings/settings.rkt")

(provide shipped-session-policy
         session-policy-get session-policy-set!
         org-session-policy-get org-session-policy-set! org-session-policy-clear!
         session-policy-for
         session-timeout-reason
         policy-problem
         SESSION-KIND API-KIND WORKER-KIND
         IDLE-MIN IDLE-MAX ABSOLUTE-MIN ABSOLUTE-MAX WARN-MAX)

(define KEY "session-policy")
(define (org-key org-id) (string-append KEY ":" org-id))

(define SESSION-KIND "session")
(define API-KIND     "api")
(define WORKER-KIND  "worker")

;; Bounds, so a typo cannot lock an instance out of itself or disable the control
;; by setting it to a year. A 5-second idle timeout is not a security posture, it
;; is an outage.
(define IDLE-MIN 60)                  ; 1 minute
(define IDLE-MAX (* 30 24 3600))      ; 30 days
(define ABSOLUTE-MIN 300)             ; 5 minutes
(define ABSOLUTE-MAX (* 90 24 3600))  ; 90 days
(define WARN-MAX 900)                 ; 15 minutes of forewarning is plenty

;; The shipped posture sits at the LEAST disruptive end of each OWASP band: 30
;; minutes idle is the top of their 15-30 low-risk range, and 8 hours absolute the
;; top of their 4-8 office-worker range. An operator who needs the high-value
;; numbers sets them; one who needs the old forever-sessions sets both to null and
;; is warned in the docs that they have opted out of the control.
(define (shipped-session-policy)
  (hasheq 'idle_seconds 1800
          'absolute_seconds 28800
          'warn_seconds 60))

;; ---- validation ---------------------------------------------------------------

;; A field is either a positive integer inside its bounds, or JSON null meaning
;; "no limit on this axis". Null is spelled explicitly rather than by omission,
;; because "I did not set this" and "I turned this off" must not look the same in
;; a security control.
(define (limit-problem label v lo hi)
  (cond
    [(or (eq? v 'null) (not v)) #f]
    [(not (and (real? v) (integer? v))) (format "~a must be a whole number of seconds or null" label)]
    [(< v lo) (format "~a must be at least ~a seconds (got ~a)" label lo v)]
    [(> v hi) (format "~a must be at most ~a seconds (got ~a)" label hi v)]
    [else #f]))

;; -> a problem string, or #f when the document is acceptable
(define (policy-problem h)
  (cond
    [(not (hash? h)) "the policy must be a JSON object"]
    [else
     (define unknown (for/first ([k (in-hash-keys h)]
                                 #:unless (memq k '(idle_seconds absolute_seconds warn_seconds)))
                       k))
     (define idle (hash-ref h 'idle_seconds 'null))
     (define abs* (hash-ref h 'absolute_seconds 'null))
     (define warn (hash-ref h 'warn_seconds 60))
     (or
      ;; an unknown field is a 400, never a silent drop: a setting that does
      ;; nothing is how an operator concludes the timeout is broken
      (and unknown (format "unknown field ~a; expected idle_seconds, absolute_seconds, warn_seconds" unknown))
      (limit-problem "idle_seconds" idle IDLE-MIN IDLE-MAX)
      (limit-problem "absolute_seconds" abs* ABSOLUTE-MIN ABSOLUTE-MAX)
      (limit-problem "warn_seconds" warn 0 WARN-MAX)
      ;; warning after the fact is worse than no warning
      (and (num? idle) (num? warn) (>= warn idle)
           (format "warn_seconds (~a) must be less than idle_seconds (~a)" warn idle))
      ;; an absolute cap under the idle window can never be reached by idling, so
      ;; one of the two numbers is not what the operator meant
      (and (num? idle) (num? abs*) (< abs* idle)
           (format "absolute_seconds (~a) must not be less than idle_seconds (~a)" abs* idle)))]))

(define (num? v) (and (real? v) (integer? v)))
(define (clean v) (if (num? v) (inexact->exact v) 'null))

(define (normalize h)
  (define d (shipped-session-policy))
  (define (g k) (hash-ref h k (hash-ref d k)))
  (hasheq 'idle_seconds (clean (g 'idle_seconds))
          'absolute_seconds (clean (g 'absolute_seconds))
          'warn_seconds (let ([w (clean (g 'warn_seconds))]) (if (eq? w 'null) 0 w))))

;; ---- storage ------------------------------------------------------------------
;; `setting-ref` already turns an absent or corrupt row into the fallback, so a
;; hand-mangled document reads as the shipped posture rather than as "no limits" —
;; a control must fail CLOSED.

(define (session-policy-get conn)
  (define v (setting-ref conn KEY #f))
  (if (hash? v) (normalize v) (shipped-session-policy)))

(define (session-policy-set! conn h)
  (setting-set! conn KEY (normalize (if (hash? h) h (hasheq)))))

;; #f when this org has set nothing of its own
(define (org-session-policy-get conn org-id)
  (define v (and org-id (setting-ref conn (org-key org-id) #f)))
  (and (hash? v) (normalize v)))

(define (org-session-policy-set! conn org-id h)
  (setting-set! conn (org-key org-id) (normalize (if (hash? h) h (hasheq)))))

(define (org-session-policy-clear! conn org-id)
  (setting-clear! conn (org-key org-id)))

;; ---- the effective policy -----------------------------------------------------

;; The stricter of two limits, where 'null means "no limit" and therefore loses to
;; any real number.
(define (stricter a b)
  (cond [(and (num? a) (num? b)) (min a b)]
        [(num? a) a]
        [(num? b) b]
        [else 'null]))

;; What actually applies to a caller in this org. The org may tighten each axis
;; and may not loosen it; see the note at the top of the file.
(define (session-policy-for conn org-id)
  (define inst (session-policy-get conn))
  (define org (and org-id (org-session-policy-get conn org-id)))
  (cond
    [(not org) inst]
    [else
     (define idle (stricter (hash-ref inst 'idle_seconds) (hash-ref org 'idle_seconds)))
     (define abs* (stricter (hash-ref inst 'absolute_seconds) (hash-ref org 'absolute_seconds)))
     (hasheq 'idle_seconds idle
             'absolute_seconds abs*
             ;; the org's own forewarning, but never longer than the window it
             ;; warns about
             'warn_seconds (let ([w (hash-ref org 'warn_seconds)])
                             (if (and (num? idle) (num? w) (>= w idle)) (max 0 (sub1 idle)) w)))]))

;; ---- the rule ------------------------------------------------------------------

;; 'idle | 'absolute | #f. Only an interactive session has these clocks: an API or
;; worker token is idle by design and is governed by its own expires_at.
;; A NULL clock (a row written before migration 0032) is not enforced, which is
;; what keeps the upgrade from signing anybody out.
(define (session-timeout-reason policy kind created-epoch last-used-epoch
                               #:now [now (current-seconds)])
  (and (equal? kind SESSION-KIND)
       (let ([idle (hash-ref policy 'idle_seconds 'null)]
             [abs* (hash-ref policy 'absolute_seconds 'null)])
         (cond
           [(and (num? idle) (num? last-used-epoch) (> (- now last-used-epoch) idle)) 'idle]
           [(and (num? abs*) (num? created-epoch) (> (- now created-epoch) abs*)) 'absolute]
           [else #f]))))
