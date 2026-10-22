#lang racket/base

;; domain/time/tz-policy.rkt — WHOSE clock applies (issue #137).
;;
;; zones.rkt knows what a zone's offset is; this knows which zone to ask about.
;; The layering is the locale policy's, deliberately, because the question is the
;; same shape: a person has a preference, their company may have a default, the
;; instance has one, and something has to answer when none of them do.
;;
;;   the user's own zone → their org's default → the instance default → UTC
;;
;; THE LAYERS DO NOT TIGHTEN, unlike a session policy or a feature switch. A
;; timezone is not a control — nobody is protected by forcing somebody into the
;; wrong one — so a user's choice wins over their company's, which is branding's
;; rule (TEN-2d) rather than SESS-4's. The instance default is a FALLBACK, never
;; a floor.
;;
;; UTC is the last resort and is stated rather than implied: every stored
;; timestamp in this platform is already UTC, so a box with no timezone data
;; behaves exactly as it did before this module existed.

(require db-kit/portable
         (only-in "../settings/settings.rkt" setting-ref setting-set! setting-clear!)
         (only-in "../authz/authz.rkt" team-org)
         (only-in "zones.rkt" available-zones zone-exists? zone-abbrev zone-offset local-fields))

(provide DEFAULT-TIMEZONE timezone-problem
         user-timezone set-user-timezone!
         instance-timezone set-instance-timezone!
         org-timezone set-org-timezone! clear-org-timezone!
         timezone-for timezone-for-team timezone-report format-local)

(define DEFAULT-TIMEZONE "UTC")
(define INSTANCE-KEY "timezone")
(define (org-key org-id) (format "timezone:~a" org-id))

;; A zone is validated against WHAT IS ON DISK, never a list in the source — the
;; rule `available` locales live by, and the reason a tzdata upgrade needs no
;; code change. An unknown zone is REFUSED rather than silently substituted: a
;; person who typed `Europe/Berlín` and was quietly given UTC would find out
;; from a report that arrived at the wrong hour.
(define (timezone-problem z)
  (cond
    [(not (and (string? z) (not (string=? z "")))) "a timezone is required, e.g. \"Europe/London\""]
    [(not (zone-exists? z))
     (format "~a is not a timezone this instance has data for" z)]
    [else #f]))

;; ---- the three layers ----------------------------------------------------------
(define (user-timezone conn user-id)
  (define v (and user-id (query-maybe-value conn "SELECT timezone FROM users WHERE id = ?" user-id)))
  (and v (not (sql-null? v)) (not (equal? v "")) v))

(define (set-user-timezone! conn user-id z)
  (query-exec conn "UPDATE users SET timezone = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ?" z user-id)
  z)

(define (instance-timezone conn)
  (define doc (setting-ref conn INSTANCE-KEY (hasheq)))
  (define v (hash-ref doc 'timezone #f))
  (and (string? v) (not (string=? v "")) v))

(define (set-instance-timezone! conn z)
  (setting-set! conn INSTANCE-KEY (hasheq 'timezone z))
  z)

(define (org-timezone conn org-id)
  (and org-id
       (let* ([doc (setting-ref conn (org-key org-id) (hasheq))]
              [v (hash-ref doc 'timezone #f)])
         (and (string? v) (not (string=? v "")) v))))

(define (set-org-timezone! conn org-id z)
  (setting-set! conn (org-key org-id) (hasheq 'timezone z))
  z)

(define (clear-org-timezone! conn org-id) (setting-clear! conn (org-key org-id)))

;; ---- resolution ----------------------------------------------------------------
;; The effective zone for one person. `org-id` is passed rather than looked up
;; because the request path already has it on the principal; `timezone-for-team`
;; is for a caller that holds a team instead (the scheduler's tick).
(define (timezone-for conn #:user [user-id #f] #:org [org-id #f])
  (or (user-timezone conn user-id)
      (org-timezone conn org-id)
      (instance-timezone conn)
      DEFAULT-TIMEZONE))

(define (timezone-for-team conn team-id #:user [user-id #f])
  (timezone-for conn #:user user-id #:org (and team-id (team-org conn team-id))))

;; What the console and `GET /api/whoami` report: the zone AND which layer
;; answered, because "why is this showing me Tokyo" should not need three
;; documents diffed by hand — `disabled_by`'s rule in the feature switch.
(define (timezone-report conn #:user [user-id #f] #:org [org-id #f])
  (define u (user-timezone conn user-id))
  (define o (org-timezone conn org-id))
  (define i (instance-timezone conn))
  (define z (or u o i DEFAULT-TIMEZONE))
  (define now (current-seconds))
  (hasheq 'timezone z
          'source (cond [u "user"] [o "org"] [i "instance"] [else "default"])
          'utc_offset_seconds (zone-offset z now)
          'abbreviation (zone-abbrev z now)
          'available (length (available-zones))))

;; An ISO-8601 local timestamp with its offset, for a report a person reads.
;; Stored timestamps stay UTC — this is presentation, which is where a timezone
;; belongs (ONB-8's line, applied to time).
(define (format-local z secs)
  (define-values (y m d hh mm ss _dow) (local-fields z secs))
  (define off (zone-offset z secs))
  (define sign (if (< off 0) "-" "+"))
  (define a (abs off))
  (define (p2 n) (if (< n 10) (format "0~a" n) (number->string n)))
  (format "~a-~a-~aT~a:~a:~a~a~a:~a"
          y (p2 m) (p2 d) (p2 hh) (p2 mm) (p2 ss)
          sign (p2 (quotient a 3600)) (p2 (quotient (modulo a 3600) 60))))
