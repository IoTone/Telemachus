#lang racket/base

;; domain/research/refetch.rkt — bookmarks re-fetched on a timer (issue #191,
;; RG-12, decisions RG-28…RG-34).
;;
;; RG-12 drew the line this module sits on: a person bookmarking a page they are
;; reading is not a crawler, and a timer re-reading it every night is. So the
;; courtesy lives HERE and nowhere on the person-initiated path:
;;
;;   • OFF UNLESS A TEAM TURNS IT ON. There is no default interval and no
;;     environment variable, so an upgrade starts no instance crawling the web.
;;   • A FLOOR OF ONE HOUR on the interval, because the interval is also how
;;     often any one page is asked for.
;;   • A DELAY BETWEEN TWO REQUESTS TO ONE HOST, and a cap on how many one run
;;     sends to one host, so a team with two hundred bookmarks on one site does
;;     not send it two hundred requests in a minute.
;;   • A CONDITIONAL REQUEST, and no new version for unchanged bytes — both in
;;     `research-fetch!`, which is told `#:scheduled? #t`.
;;
;; What it is NOT is a second fetch path. Every request goes through
;; `research-fetch!`, so the egress policy (RG-3, `'untrusted`, no way to ask
;; otherwise) and the budget (RG-17, charged per request and before it) are the
;; ones a person's fetch gets.
;;
;; THE CONFIGURATION IS A SETTINGS DOCUMENT AND THE TIMER IS A `job_schedules`
;; ROW THIS MODULE OWNS — FEED-21's shape. The kind and the payload are
;; platform-set, so this plane cannot schedule anything but this. `enabled` is
;; DERIVED from the schedule row really being there and not paused, so deleting
;; the schedule from the schedules plane turns the report off rather than
;; leaving a document that says "on" with nothing firing.

(require db-kit/portable
         json
         net/url
         racket/list
         (only-in "../authz/authz.rkt" audit! user-principal)
         (only-in "../settings/settings.rkt" setting-ref setting-set! setting-clear!)
         (only-in "../sched/schedules.rkt" schedule-create! schedule-get schedule-update!
                  schedule-delete!)
         (only-in "research.rkt" research-by-id research-fetch! research-member?))

(provide REFETCH-KIND REFETCH-MIN-INTERVAL REFETCH-MAX-INTERVAL REFETCH-BATCH
         REFETCH-HOST-DELAY REFETCH-HOST-MAX
         refetch-problem refetch-config refetch-set! refetch-due refetch-run!)

(define REFETCH-KIND "research.refetch")

;; One hour. The schedule plane's own floor is a minute, which is right for a
;; job and far too eager for somebody else's web server.
(define REFETCH-MIN-INTERVAL 3600)
;; A year. Past that the setting is a way of saying "off" that reads as "on".
(define REFETCH-MAX-INTERVAL (* 366 86400))
;; How many bookmarks one run may fetch. A run is one scheduler job, and each
;; fetch may take the fetcher's whole timeout, so this is also what keeps a run
;; inside the job ceiling (SCHED-9). The rest are still the stalest next tick.
(define REFETCH-BATCH 20)
;; Seconds between two requests to one host within a run.
(define REFETCH-HOST-DELAY 5)
;; Requests to one host within a run.
(define REFETCH-HOST-MAX 5)

(define (setting-key team) (format "research-refetch:~a" team))

(define (now) (current-seconds))

;; -> #f or a message. `every` is seconds, or #f / 'null to turn it off.
(define (refetch-problem every)
  (cond
    [(or (not every) (eq? every 'null)) #f]
    [(not (exact-integer? every)) "`every_seconds` must be a whole number of seconds, or null to turn re-fetching off"]
    [(< every REFETCH-MIN-INTERVAL)
     (format "`every_seconds` must be at least ~a (one hour): the interval is also how often any one page is requested" REFETCH-MIN-INTERVAL)]
    [(> every REFETCH-MAX-INTERVAL)
     (format "`every_seconds` must be at most ~a; use null to turn re-fetching off" REFETCH-MAX-INTERVAL)]
    [else #f]))

(define (stored conn team)
  (define doc (setting-ref conn (setting-key team) #f))
  (and (hash? doc) (exact-integer? (hash-ref doc 'every_seconds #f)) doc))

;; What a reader is told. `enabled` is derived (see the header); the bounds are
;; reported so a client does not have to learn them from a refusal.
(define (refetch-config conn team)
  (define doc (stored conn team))
  (define sid (and doc (hash-ref doc 'schedule_id #f)))
  (define sched (and (string? sid) (schedule-get conn sid team)))
  (define live? (and sched (not (hash-ref sched 'paused #f))))
  (define base (hasheq 'enabled (and live? #t)
                       'min_seconds REFETCH-MIN-INTERVAL
                       'batch REFETCH-BATCH
                       'host_delay_seconds REFETCH-HOST-DELAY
                       'host_max REFETCH-HOST-MAX))
  (if live?
      (hash-set* base
                 'every_seconds (hash-ref doc 'every_seconds)
                 'next_run_epoch (hash-ref sched 'next_run_epoch)
                 'last_run_epoch (hash-ref sched 'last_run_epoch 'null))
      base))

;; `every` #f turns it off and removes the schedule. `user` is who the timer
;; runs as in the schedule plane; each FETCH still acts as its bookmark's own
;; user (RG-31), so this decides whose name is on the schedule and nothing about
;; what may be written.
(define (refetch-set! conn team user every)
  (define doc (stored conn team))
  (define sid (and doc (hash-ref doc 'schedule_id #f)))
  (define live (and (string? sid) (schedule-get conn sid team)))
  (cond
    [(or (not every) (eq? every 'null))
     (when live (schedule-delete! conn sid team))
     (setting-clear! conn (setting-key team))]
    [else
     (define new-sid
       (cond
         [live (schedule-update! conn sid team #:interval every #:paused? #f) sid]
         [else (schedule-create! conn #:team team #:user user #:kind REFETCH-KIND
                                 #:interval every #:payload (hasheq)
                                 #:name "research: re-fetch bookmarks" #:created-by user)]))
     (setting-set! conn (setting-key team)
                   (hasheq 'every_seconds every 'schedule_id new-sid))])
  (refetch-config conn team))

;; The bookmarks whose last fetch is at least one interval old, stalest first,
;; never-fetched before everything. A bound in SQL, so a team with ten thousand
;; bookmarks costs a run one indexed page rather than the table.
(define (refetch-due conn team every #:limit [limit (* 4 REFETCH-BATCH)])
  (map (lambda (r) (vector-ref r 0))
       (query-rows conn
                   (string-append "SELECT id FROM research_sources WHERE team_id = ? AND active = 1 "
                                  "AND (fetched_epoch IS NULL OR fetched_epoch <= ?) "
                                  "ORDER BY COALESCE(fetched_epoch, 0), id LIMIT ?")
                   team (- (now) every) limit)))

(define (host-of url)
  (define u (with-handlers ([exn:fail? (lambda (_) #f)]) (string->url url)))
  (string-downcase (or (and u (url-host u)) "")))

;; One run. Reports and never raises for a page that would not fetch: a site
;; being down is the ordinary case this feature exists for, and failing the job
;; would put a red row in the team's history for the web being the web.
;;
;; `#:fetch` is `research-fetch!`'s seam, `#:sleep` and `#:clock` are the delay's,
;; so a test can watch the courtesy without waiting for it.
(define (refetch-run! conn team
                      #:fetch [do-fetch #f]
                      #:sleep [do-sleep sleep]
                      #:clock [clock current-inexact-milliseconds])
  (define doc (stored conn team))
  (cond
    [(not doc) (hasheq 'skipped "scheduled re-fetching is not configured for this team")]
    [else
     (define every (hash-ref doc 'every_seconds))
     (define due (refetch-due conn team every))
     (define last-at (make-hash))     ; host -> ms of its last request this run
     (define per-host (make-hash))    ; host -> requests this run
     (define stats (make-hasheq))
     (define left (box 0))            ; due and not reached when the run ended
     (define (bump! k) (hash-update! stats k add1 0))
     (define stopped
       (let loop ([ids due] [sent 0])
         (cond
           [(null? ids) #f]
           [(>= sent REFETCH-BATCH) (set-box! left (length ids)) #f]
           [else
            (define row (research-by-id conn (car ids)))
            (define user (and row (hash-ref row 'user_id #f)))
            (define host (if row (host-of (hash-ref row 'url)) ""))
            (cond
              ;; deleted between the listing and now
              [(not row) (loop (cdr ids) sent)]
              ;; RG-31: nobody to act as. Not re-homed to whoever turned the
              ;; timer on — the archive is this person's document.
              [(not (research-member? conn team user))
               (bump! 'no_user)
               (loop (cdr ids) sent)]
              [(>= (hash-ref per-host host 0) REFETCH-HOST-MAX)
               (bump! 'deferred)
               (loop (cdr ids) sent)]
              [else
               (define prev (hash-ref last-at host #f))
               (when prev
                 (define wait (- REFETCH-HOST-DELAY (/ (- (clock) prev) 1000.0)))
                 (when (positive? wait) (do-sleep wait)))
               (define out
                 (research-fetch! conn (user-principal conn user team) row
                                  #:fetch do-fetch #:scheduled? #t))
               (cond
                 ;; The budget is the team's, so the next bookmark would be
                 ;; refused too. Stop, and say why; nothing was sent for this one.
                 [(equal? (hash-ref out 'reason #f) "quota")
                  (set-box! left (length ids))
                  "quota"]
                 [else
                  (hash-set! last-at host (clock))
                  (hash-update! per-host host add1 0)
                  (bump! (cond [(not (hash-ref out 'ok #f)) 'failed]
                               [(hash-ref out 'unchanged #f) 'unchanged]
                               [else 'changed]))
                  (loop (cdr ids) (add1 sent))])])])))
     (define (n k) (hash-ref stats k 0))
     (define report
       (hasheq 'due (length due)
               'changed (n 'changed)
               'unchanged (n 'unchanged)
               'failed (n 'failed)
               'no_user (n 'no_user)
               'deferred (n 'deferred)
               'stopped (or stopped 'null)
               ;; Every way a due bookmark can be left for the next run: the
               ;; listing was full, the run ended early, or a host was at its cap.
               'truncated (or (>= (length due) (* 4 REFETCH-BATCH))
                              (positive? (unbox left))
                              (positive? (n 'deferred)))))
     ;; One entry per run, with counts and no URL: the per-bookmark detail is on
     ;; the rows, and a list of what a team reads is not something to copy into a
     ;; log that is chained, exported and kept through an erasure.
     (when (positive? (length due))
       (audit! conn #:action "research.refetched" #:result (if stopped "refused" "ok")
               #:actor-type "system"
               #:team-id team
               #:resource-type "research"
               #:meta (jsexpr->string report)))
     report]))
