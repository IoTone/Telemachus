#lang racket/base

;; domain/feeds/adapter-kuma.rkt — `kuma.status` (#193, decisions FEED‑27…29).
;;
;; #114's third named source: Uptime Kuma. The endpoint is a **status page's
;; heartbeat JSON** — `/api/status-page/heartbeat/<slug>` — which is the one
;; documented, unauthenticated, pollable JSON Kuma serves. Its socket API is a
;; push protocol and is no more an adapter than Matrix was.
;;
;; FEED‑27 — AN ITEM IS A STATUS TRANSITION, NOT A HEARTBEAT. #193 says "an
;; alert is an event rather than a document that evolves", and the first reading
;; of that — one item per heartbeat — is unaffordable: Kuma beats every 60
;; seconds per monitor, so a ten-monitor status page would write 14,400
;; documents a day and charge the team's storage for every one. What anybody
;; actually wants is "when did it go down, and when did it come back", which is
;; the heartbeats where the status DIFFERS from the one before it.
;;
;; The transition is computed from the list this response carried, not read off
;; a flag. Kuma's own database has an `important` column that means exactly this,
;; and the status-page projection is not documented to include it — so relying
;; on it would make the adapter silently emit nothing on a version that trims it,
;; which is the worst failure available here. `status` and `time` are certainly
;; present, and a transition is derivable from them.
;;
;; FEED‑28 — THE IDENTITY CARRIES THE INSTANT, which is #193's own observation:
;; two "down" events an hour apart are two items, not one. So the external id is
;; `<monitor>-<instant>`, where GitHub's is `<owner>-<repo>-<number>` and NVD's
;; is a CVE id. The consequence is worth stating: a pulled transition is
;; immutable, so it is created once and never updated, and `feed_items` grows
;; with the number of OUTAGES rather than with time.
;;
;; THE SHAPE IS FROM KUMA'S STATUS-PAGE RESPONSE AND IS NOT VERIFIED AGAINST A
;; LIVE INSTANCE in this build. Every read is defensive; an unreadable response
;; is a named refusal.

(require json racket/string racket/list
         "adapters.rkt")

(provide kuma-status-adapter install-kuma-adapter! kuma-transitions KUMA-STATUS-NAMES)

(define KUMA-FIELDS
  (list (hasheq 'key "feed_monitor" 'label "Monitor")
        (hasheq 'key "feed_status"  'label "Status")
        (hasheq 'key "feed_message" 'label "Message")))

;; Kuma's own numbering. A name rather than the integer, because `?attr=` is an
;; equality filter a person types (CLS‑8), and `feed_status=0` is not something
;; anybody will guess. An unknown code keeps its number rather than being called
;; something it is not.
(define KUMA-STATUS-NAMES (hasheq 0 "down" 1 "up" 2 "pending" 3 "maintenance"))

(define HEADERS (list (cons "accept" "application/json")
                      (cons "user-agent" "Telemachus-feeds")))

;; NO CURSOR GOES TO THE SOURCE, because the endpoint has no window: it answers
;; the most recent N beats per monitor and nothing narrows that. So the cursor is
;; applied in `parse` instead — INCLUSIVELY (FEED‑19), so the boundary beat comes
;; back and dedup absorbs it rather than a gap opening at the seam.
;;
;; What that costs is real and bounded: a feed polled less often than Kuma's
;; retention window loses the transitions that fell off the list. Kuma keeps
;; enough beats for a status page to draw its bar, so a poll cadence of an hour
;; is comfortable and a daily one is not. The poll's own `poll_seconds` is where
;; an operator sets that, and `polling` reports it.
(define (kuma-prepare feed cursor)
  (values (hash-ref feed 'url) HEADERS))

(define (cursor->epoch cursor)
  (define n (and cursor (string->number (format "~a" cursor))))
  (and (real? n) (inexact->exact (floor n))))

;; A monitor's beats, oldest first, with each beat's status compared against the
;; one before it. The FIRST beat in a list is never a transition: nothing
;; precedes it, so calling it one would emit a spurious event for every monitor
;; on the first poll and again whenever the window slid.
;;
;; A BEAT WITH NO READABLE `time` IS DROPPED, and that has to happen HERE rather
;; than at the item, which is what a test found. Such a beat cannot be ORDERED,
;; so it cannot take part in a comparison that is entirely about order — and
;; giving it epoch 0 to keep the sort total silently makes it the first beat of
;; every list, where the rule above then discards it for the wrong reason. The
;; cost is stated: if the middle beat of three is unreadable, the outer two are
;; compared directly, which is the best available answer and not a complete one.
;;
;; Answers `(cons epoch beat)` pairs, so the instant is computed ONCE — the
;; identity, the title and the cursor all need it, and parsing it twice is two
;; chances to disagree about which second a transition happened in.
;;
;; Exported for the test, which is the only way to reach the rule without a
;; response (#110 r4's stated exception).
(define (kuma-transitions beats)
  (define dated
    (sort (for*/list ([b (in-list beats)] #:when (hash? b)
                      [e (in-value (iso8601->epoch (format "~a" (hash-ref b 'time ""))))]
                      #:when e)
            (cons e b))
          < #:key car))
  (let loop ([bs dated] [prev #f] [out '()])
    (cond
      [(null? bs) (reverse out)]
      [else
       (define b (cdr (car bs)))
       (define st (hash-ref b 'status #f))
       (define keep? (and prev (real? st) (not (equal? st (hash-ref prev 'status #f)))))
       (loop (cdr bs) b (if keep? (cons (car bs) out) out))])))

(define (status-name st)
  (if (real? st)
      (hash-ref KUMA-STATUS-NAMES (inexact->exact (floor st)) (format "~a" (inexact->exact (floor st))))
      ""))

(define (kuma-parse body headers request-url)
  (define parsed
    (with-handlers ([exn:fail? (lambda (_)
                                 (raise-user-error
                                  'feed "kuma.status: the response did not parse as JSON"))])
      (bytes->jsexpr body)))
  (define hb (and (hash? parsed) (hash-ref parsed 'heartbeatList #f)))
  (unless (hash? hb)
    (raise-user-error
     'feed (string-append "kuma.status: expected an object with a `heartbeatList` — the URL "
                          "should be a status page's heartbeat endpoint, "
                          "/api/status-page/heartbeat/<slug>")))
  (values
   (for*/list ([(mon beats) (in-hash hb)]
               #:when (list? beats)
               [pair (in-list (kuma-transitions beats))])
     (define epoch (car pair))
     (define b (cdr pair))
     (define time (format "~a" (hash-ref b 'time "")))
     (define st (hash-ref b 'status #f))
     (define name (status-name st))
     (define monitor (format "~a" mon))
     (feed-item
      (format "~a-~a" (safe-id-part monitor) epoch)
      (format "monitor ~a ~a at ~a" monitor (if (string=? name "") "changed" name) (epoch->iso8601 epoch))
      ;; The monitor id rides INSIDE the payload as well as in the id, because
      ;; the response keys the list by it and the item alone does not say which
      ;; monitor it belongs to — a stored document that cannot name its own
      ;; subject is one nobody can read.
      (hasheq 'monitor monitor 'heartbeat b)
      epoch
      (hasheq 'feed_item_id (format "~a-~a" monitor epoch)
              ;; The status page a person would go and look at, which is the
              ;; configured URL with the API path removed. Left EMPTY when it
              ;; cannot be derived rather than guessed at.
              'feed_url (status-page-url request-url)
              'feed_updated time
              'feed_monitor monitor
              'feed_status name
              'feed_message (let ([m (hash-ref b 'msg #f)]) (if (string? m) m "")))))
   ;; One response is the whole window; there is nothing to page through.
   #f))

;; `…/api/status-page/heartbeat/acme` → `…/status/acme`, which is where a person
;; reads it. Derived rather than configured, so the operator sets one URL — and
;; #f rather than a guess when the path is not the documented one.
(define (status-page-url u)
  (define m (regexp-match #px"^(https?://[^/]+)(?:/.*)?/api/status-page/heartbeat/([^/?#]+)" u))
  (if m (format "~a/status/~a" (cadr m) (caddr m)) ""))

(define kuma-status-adapter
  (feed-adapter "kuma.status" "Uptime Kuma status" kuma-prepare kuma-parse KUMA-FIELDS))

(define (install-kuma-adapter!) (register-feed-adapter! kuma-status-adapter))
