#lang racket/base

;; domain/quota/quota.rkt — per-subject quota limits + usage metering.
;; Dimensions (v1): ai.tokens.total & ai.requests (windowed budgets), ai.concurrency
;; (a limit the governor reads). check() is called at admission with an estimate;
;; record() logs actual usage after the call. Subjects are "team" or "user".

(require db-kit/portable "../db/id.rkt")

(provide set-limit! get-limit quota-used quota-check quota-record! default-policy!
         window-bounds window-resets-at)

(define (set-limit! conn subject-type subject-id dimension limit #:window [window "day"])
  (query-exec conn
    (string-append "INSERT INTO quota_limits (id, subject_type, subject_id, dimension, limit_value, \"window\") "
                   "VALUES (?, ?, ?, ?, ?, ?) "
                   "ON CONFLICT(subject_type, subject_id, dimension) "
                   "DO UPDATE SET limit_value = excluded.limit_value, \"window\" = excluded.\"window\"")
    (new-id) subject-type subject-id dimension limit window))

;; → (values limit window) or (values #f #f)
(define (get-limit conn subject-type subject-id dimension)
  (define row (query-maybe-row conn
    "SELECT limit_value, \"window\" FROM quota_limits WHERE subject_type = ? AND subject_id = ? AND dimension = ?"
    subject-type subject-id dimension))
  (if row (values (vector-ref row 0) (vector-ref row 1)) (values #f #f)))

;; `at` is a TEXT timestamp on both backends (we declare the column TEXT). The
;; window predicate is the one spot that needs dialect-specific date functions.
(define (window-clause dialect window)
  (cond
    [(string=? window "day")
     (if (eq? dialect 'postgresql) "at::date = CURRENT_DATE" "date(at) = date('now')")]
    [(string=? window "minute")
     (if (eq? dialect 'postgresql) "at::timestamptz >= NOW() - interval '60 seconds'"
         "at >= datetime('now','-60 seconds')")]
    [else "1 = 1"]))

;; When the current window started, and when it next starts over, as epoch seconds
;; — (values #f #f) when the window is not a calendar one (issue #55, part 4: a
;; client cannot say "work resumes at…" without this).
;;
;; Asked of the DATABASE, in the same terms `window-clause` filters by, because
;; the two must never disagree: SQLite's `date('now')` is UTC while PostgreSQL's
;; CURRENT_DATE follows the server's own timezone, so a boundary computed in
;; Racket would be right on one dialect and hours out on the other.
;;
;; "minute" deliberately answers nothing. It is a SLIDING window — the oldest
;; second of usage falls out of it every second — so there is no instant at which
;; the budget resets, and naming one would be a worse answer than naming none.
;; "total" never resets.
(define (window-bounds conn window)
  (cond
    [(equal? window "day")
     (define-values (q0 q1)
       (if (eq? (db-dialect conn) 'postgresql)
           ;; CURRENT_DATE is a date; the ::timestamptz cast reads it in the
           ;; session's timezone, which is the same calendar day `at::date =
           ;; CURRENT_DATE` compares against.
           (values "SELECT EXTRACT(EPOCH FROM CURRENT_DATE::timestamptz)"
                   "SELECT EXTRACT(EPOCH FROM (CURRENT_DATE + interval '1 day')::timestamptz)")
           (values "SELECT CAST(strftime('%s', date('now')) AS INTEGER)"
                   "SELECT CAST(strftime('%s', date('now','+1 day')) AS INTEGER)")))
     (values (epoch-of conn q0) (epoch-of conn q1))]
    [else (values #f #f)]))

(define (epoch-of conn q) (inexact->exact (floor (query-value conn q))))

;; just the far edge, which is the one a client shows
(define (window-resets-at conn window)
  (define-values (_start end) (window-bounds conn window))
  end)

(define (quota-used conn subject-type subject-id dimension window)
  (query-value conn
    (string-append "SELECT COALESCE(SUM(amount), 0) FROM usage_ledger "
                   "WHERE subject_type = ? AND subject_id = ? AND dimension = ? AND "
                   (window-clause (db-dialect conn) window))
    subject-type subject-id dimension))

;; admission decision for `amount` more of `dimension`
(define (quota-check conn subject-type subject-id dimension amount)
  (define-values (limit window) (get-limit conn subject-type subject-id dimension))
  (cond
    [(not limit) (hasheq 'allowed #t 'limit 'null 'used 0 'remaining 'null 'window 'null)]
    [else
     (define used (quota-used conn subject-type subject-id dimension window))
     (hasheq 'allowed (<= (+ used amount) limit)
             'limit limit 'used used 'remaining (max 0 (- limit used)) 'window window)]))

(define (quota-record! conn subject-type subject-id dimension amount)
  (query-exec conn
    "INSERT INTO usage_ledger (id, subject_type, subject_id, dimension, amount) VALUES (?, ?, ?, ?, ?)"
    (new-id) subject-type subject-id dimension amount))

;; conservative starter policy for a team
(define (default-policy! conn team-id
                         #:tokens-per-day [tokens 2000]
                         #:requests-per-day [requests 200]
                         #:concurrency [concurrency 2])
  (set-limit! conn "team" team-id "ai.tokens.total" tokens #:window "day")
  (set-limit! conn "team" team-id "ai.requests"     requests #:window "day")
  (set-limit! conn "team" team-id "ai.concurrency"  concurrency #:window "instant"))
