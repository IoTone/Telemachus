#lang racket/base

;; domain/hooks/webhooks.rkt — outbound webhooks (#85).
;;
;; A subscription, a signed POST, and a delivery record with backoff. The
;; interesting decisions are all about what this is NOT allowed to do:
;;
;;   • THE PAYLOAD CARRIES NO CONTENT. Ids, status, timestamps and a link to
;;     fetch the rest (#85 r2). It crosses the network to somebody else's
;;     server, and a document's text arriving there is a disclosure nobody
;;     audited — the receiver fetches under its own credentials, where `can?`
;;     answers for them. This is also why `webhook_deliveries.payload` needs no
;;     sealing while `jobs.payload` does.
;;   • THE REQUEST GOES THROUGH #142's FETCHER, which refuses private address
;;     space unless the OPERATOR allowed that network. #85's requirement 5 asked
;;     for exactly that and EGR-1…3 had already answered it, so there is no
;;     second SSRF rule here — and no second HTTP client.
;;   • A FAILED DELIVERY NEVER TOUCHES THE WORK. The emitter is told nothing
;;     (events.rkt swallows), and a dead delivery is a row somebody can look at,
;;     not a failed run.

(require db-kit/portable
         json
         racket/string
         racket/list
         racket/format
         racket/random
         sha2-kit                              ; hmac-sha256 over libcrypto
         (only-in file/sha1 bytes->hex-string)
         "../db/id.rkt"
         (only-in "../authz/sealed.rkt" define-sealed-column)
         (only-in "../authz/authz.rkt" audit!)
         (only-in "../events/events.rkt" EVENTS event?)
         (only-in "../net/fetch.rkt" fetch exn:fail:egress? exn:fail:egress-reason)
         "../db/nulls.rkt")

(provide SIGNATURE-VERSION MAX-ATTEMPTS DELIVERY-TIMEOUT
         webhook-create! webhook-list webhook-get webhook-update! webhook-delete!
         webhook-problem webhook-secret-of
         deliveries-list delivery-get redeliver! enqueue-event! deliver-due! deliver-one!
         sign-payload backoff-seconds)

;; #19's seam. A webhook secret is a CREDENTIAL — an HMAC key a receiver
;; verifies with — so it is in `CREDENTIAL-SECRETS` and `rewrap` rotates it
;; unconditionally, unlike the content columns, which only move when the
;; operator has turned content encryption on.
(define-sealed-column "webhooks.secret" (seal-secret unseal-secret) (id) #:credential)

(define SIGNATURE-VERSION "v1")
;; Ten attempts with a 24h ceiling (#85 r3). 60 * 2^(n-1) reaches about 8.5 hours
;; at the tenth, so the cap is not what stops it — it is there because a longer
;; base would make the FIRST retry late, and the first retry is the one that
;; recovers an ordinary restart.
(define MAX-ATTEMPTS 10)
(define BACKOFF-CAP 86400)
(define DELIVERY-TIMEOUT 10)
(define DELIVERY-BATCH 50)
;; The receiver is somebody else's server: its ANSWER is of no interest beyond
;; the status code, and storing a body would put content we never sent back into
;; our own database.
(define MAX-RESPONSE-BYTES 4096)

(define (now) (current-seconds))

(define (backoff-seconds attempt)
  (min BACKOFF-CAP (* 60 (expt 2 (max 0 (- attempt 1))))))

;; ---- subscriptions ---------------------------------------------------------------
(define (webhook-problem #:url url #:events events)
  (cond
    [(not (and (string? url) (regexp-match? #px"^https?://" url)))
     "url must be an http(s) URL"]
    ;; An event name nothing emits is a subscription that silently never fires,
    ;; so an unknown one is refused rather than stored (the closed-vocabulary
    ;; rule, and #113's shape).
    [(not (events-ok? events))
     (format "events must be \"*\" or a comma-separated subset of: ~a" (string-join EVENTS ", "))]
    [else #f]))

(define (events-ok? events)
  (or (not events) (equal? events "*")
      (and (string? events)
           (let ([parts (map string-trim (string-split events ","))])
             (and (pair? parts) (andmap event? parts))))))

(define (matches-event? subscribed event)
  (or (equal? subscribed "*")
      (and (member event (map string-trim (string-split subscribed ","))) #t)))

(define COLS (string-append "id, team_id, url, secret, events, description, active, "
                            "created_by, created_epoch"))

;; THE SECRET IS NEVER IN A LISTING. It is shown once, by the create and by a
;; rotate, and after that nobody can read it back — #19's rule for a token, and
;; the reason the console says so rather than implying a recovery that does not
;; exist.
(define (row->webhook r)
  (hasheq 'id (vector-ref r 0)
          'team_id (vector-ref r 1)
          'url (vector-ref r 2)
          'events (vector-ref r 4)
          'description (nz (vector-ref r 5))
          'active (= 1 (vector-ref r 6))
          'created_by (nz (vector-ref r 7))
          'created_epoch (vector-ref r 8)))

(define (webhook-create! conn #:team team #:url url #:events [events "*"]
                         #:description [desc #f] #:created-by [by #f] #:secret [secret #f])
  (define id (new-id))
  (define s (or secret (new-secret)))
  (query-exec conn
    (string-append "INSERT INTO webhooks (id, team_id, url, secret, events, description, active, "
                   "created_by, created_epoch) VALUES (?, ?, ?, ?, ?, ?, 1, ?, ?)")
    id team url (seal-secret id s) (or events "*") (or desc sql-null) (or by sql-null) (now))
  (values id s))

(define (new-secret) (bytes->hex-string (crypto-random-bytes 32)))

(define (webhook-list conn team)
  (for/list ([r (in-list (query-rows conn (string-append "SELECT " COLS " FROM webhooks WHERE team_id = ? "
                                                         "ORDER BY created_epoch DESC, id DESC") team))])
    (row->webhook r)))

;; Team-scoped IN THE STATEMENT, so another team's id is a miss and not a
;; refusal — the rule the session and schedule routes follow.
(define (webhook-get conn id team)
  (define r (query-maybe-row conn (string-append "SELECT " COLS " FROM webhooks WHERE id = ? AND team_id = ?")
                             id team))
  (and r (row->webhook r)))

(define (webhook-secret-of conn id team)
  (define r (query-maybe-row conn "SELECT secret FROM webhooks WHERE id = ? AND team_id = ?" id team))
  (and r (unseal-secret id (vector-ref r 0))))

;; -> (values webhook new-secret-or-#f), the second only when it was rotated.
(define (webhook-update! conn id team #:url [url 'same] #:events [events 'same]
                         #:active? [active? 'same] #:description [desc 'same]
                         #:rotate? [rotate? #f])
  (define cur (webhook-get conn id team))
  (cond
    [(not cur) (values #f #f)]
    [else
     (when (string? url)
       (query-exec conn "UPDATE webhooks SET url = ? WHERE id = ? AND team_id = ?" url id team))
     (when (string? events)
       (query-exec conn "UPDATE webhooks SET events = ? WHERE id = ? AND team_id = ?" events id team))
     (when (boolean? active?)
       (query-exec conn "UPDATE webhooks SET active = ? WHERE id = ? AND team_id = ?"
                   (if active? 1 0) id team))
     (when (string? desc)
       (query-exec conn "UPDATE webhooks SET description = ? WHERE id = ? AND team_id = ?" desc id team))
     (define fresh
       (and rotate?
            (let ([s (new-secret)])
              (query-exec conn "UPDATE webhooks SET secret = ? WHERE id = ? AND team_id = ?"
                          (seal-secret id s) id team)
              s)))
     (values (webhook-get conn id team) fresh)]))

(define (webhook-delete! conn id team)
  ;; The deliveries go with it: they are the history of THIS subscription, and a
  ;; dead-letter row pointing at a webhook nobody can look up is a row nobody can
  ;; act on. The audit entry is what survives.
  (query-exec conn "DELETE FROM webhook_deliveries WHERE webhook_id = ? AND team_id = ?" id team)
  (and (query-maybe-row conn "DELETE FROM webhooks WHERE id = ? AND team_id = ? RETURNING id" id team) #t))

;; ---- the event -> deliveries fan-out --------------------------------------------
;; Installed as the event sink by main.rkt. One row per matching subscription,
;; due immediately.
(define (enqueue-event! conn event team data)
  (define subs
    (query-rows conn (string-append "SELECT " COLS " FROM webhooks WHERE team_id = ? AND active = 1") team))
  (for/list ([r (in-list subs)]
             #:when (matches-event? (vector-ref r 4) event))
    (define id (new-id))
    ;; The DELIVERY id is the idempotency key the receiver dedupes on (#85 r3),
    ;; which is why it is minted here and not derived from the event: a
    ;; redelivery of the same event is the SAME key, so a receiver that already
    ;; applied it can say so.
    (query-exec conn
      (string-append "INSERT INTO webhook_deliveries (id, webhook_id, team_id, event, payload, "
                     "status, attempts, next_attempt_epoch, created_epoch) "
                     "VALUES (?, ?, ?, ?, ?, 'pending', 0, ?, ?)")
      id (vector-ref r 0) team event
      (jsexpr->string (hasheq 'event event 'delivery_id id 'team_id team
                              'at (now) 'data data))
      (now) (now))
    id))

;; ---- signing ----------------------------------------------------------------------
;; `v1=<hex>` over "<timestamp>.<body>" — the timestamp is INSIDE the signed
;; material, so a captured body cannot be replayed under a fresh header. The
;; five-minute window (#85 r2) is the RECEIVER's check: only they know their own
;; clock skew, and a server-side window would reject nothing they would not.
(define (sign-payload secret timestamp body)
  (string-append SIGNATURE-VERSION "="
                 (bytes->hex-string
                  (hmac-sha256 (string->bytes/utf-8 secret)
                               (string->bytes/utf-8 (format "~a.~a" timestamp body))))))

;; ---- delivery -----------------------------------------------------------------------
;; -> 'delivered | 'retry | 'dead | 'gone
(define (deliver-one! conn delivery-id)
  (define r (query-maybe-row conn
              (string-append "SELECT d.id, d.webhook_id, d.team_id, d.event, d.payload, d.attempts, "
                             "w.url, w.secret, w.active FROM webhook_deliveries d "
                             "JOIN webhooks w ON w.id = d.webhook_id "
                             "WHERE d.id = ? AND d.status = 'pending'")
              delivery-id))
  (cond
    [(not r) 'gone]
    [(not (= 1 (vector-ref r 8)))
     ;; A subscription turned off mid-flight: the delivery stops, and it stops as
     ;; `dead` rather than vanishing, so somebody can see what was not sent.
     (fail-delivery! conn delivery-id 'dead #f "the subscription is inactive" 0
                     (vector-ref r 5))
     'dead]
    [else
     (define url (vector-ref r 6))
     (define secret (unseal-secret (vector-ref r 1) (vector-ref r 7)))
     (define body (vector-ref r 4))
     (define attempts (add1 (vector-ref r 5)))
     (define ts (now))
     (define t0 (current-inexact-milliseconds))
     ;; A POLICY refusal is PERMANENT, and distinguishing it is the whole reason
     ;; #142's fetcher raises a typed exception. "This URL is in private address
     ;; space" will be just as true in eight hours, so retrying it ten times is
     ;; ten identical refusals and a dead letter that took a day to admit it. A
     ;; timeout or a DNS failure is the opposite — those are exactly what a retry
     ;; is for. Same split llm.rkt makes for a model call, and PULL-14's lesson
     ;; about not sending a genuinely bad request round the fleet.
     (define-values (code err permanent?)
       (with-handlers ([exn:fail:egress?
                        (lambda (e)
                          (values #f (format "~a: ~a" (exn:fail:egress-reason e) (exn-message e))
                                  (and (member (exn:fail:egress-reason e)
                                               '(refused-address refused-peer bad-url too-many-redirects))
                                       #t)))]
                       [(lambda (_) #t) (lambda (e) (values #f (if (exn? e) (exn-message e) (format "~a" e)) #f))])
         (define-values (status _hs _bs)
           (fetch url
                  ;; #142's `'trusted` — public, PLUS whatever private networks
                  ;; the OPERATOR allowed. A team may point a webhook at its own
                  ;; receiver inside the operator's network and at nothing else,
                  ;; which is the same answer feeds get and for the same reason.
                  #:policy 'trusted
                  #:method "POST"
                  #:timeout DELIVERY-TIMEOUT
                  #:max-bytes MAX-RESPONSE-BYTES
                  #:body (string->bytes/utf-8 body)
                  #:headers (list (cons "content-type" "application/json")
                                  (cons "x-telemachus-event" (vector-ref r 3))
                                  (cons "x-telemachus-delivery" delivery-id)
                                  (cons "x-telemachus-timestamp" (number->string ts))
                                  (cons "x-telemachus-signature" (sign-payload secret ts body)))))
         (values status #f #f)))
     (define ms (inexact->exact (round (- (current-inexact-milliseconds) t0))))
     (cond
       [(and code (>= code 200) (< code 300))
        (query-exec conn (string-append "UPDATE webhook_deliveries SET status = 'delivered', attempts = ?, "
                                        "last_status_code = ?, last_error = NULL, last_latency_ms = ?, "
                                        "next_attempt_epoch = NULL, delivered_epoch = ? WHERE id = ?")
                    attempts code ms (now) delivery-id)
        'delivered]
       ;; A 4xx that is not 408 or 429 is the RECEIVER rejecting this event, and
       ;; retrying it nine more times would be nine more rejections. 5xx, a
       ;; timeout, a refusal and a connection failure are all worth another go —
       ;; the same split llm.rkt makes, and PULL-14's lesson about not sending a
       ;; genuinely bad request round the fleet.
       [(and code (>= code 400) (< code 500) (not (member code '(408 429))))
        (fail-delivery! conn delivery-id 'dead code #f ms attempts)
        'dead]
       [permanent?
        (fail-delivery! conn delivery-id 'dead #f err ms attempts)
        'dead]
       [(>= attempts MAX-ATTEMPTS)
        (fail-delivery! conn delivery-id 'dead code err ms attempts)
        'dead]
       [else
        (query-exec conn (string-append "UPDATE webhook_deliveries SET attempts = ?, last_status_code = ?, "
                                        "last_error = ?, last_latency_ms = ?, next_attempt_epoch = ? WHERE id = ?")
                    attempts (or code sql-null) (or err sql-null) ms
                    (+ (now) (backoff-seconds attempts)) delivery-id)
        'retry])]))

;; `attempts` is written HERE as well as on the retry path, and the first version
;; left it out: a dead letter then reported one fewer attempt than it had made,
;; so a row that had exhausted ten said nine and an operator reading it could not
;; tell the ceiling had been reached. Found by the test that drives the ceiling.
(define (fail-delivery! conn id why code err ms attempts)
  (query-exec conn (string-append "UPDATE webhook_deliveries SET status = ?, attempts = ?, "
                                  "last_status_code = ?, last_error = ?, last_latency_ms = ?, "
                                  "next_attempt_epoch = NULL WHERE id = ?")
              (symbol->string why) attempts (or code sql-null) (or err sql-null) ms id))

;; The sweep, on the pool's reaper seam. -> (values delivered retried dead)
(define (deliver-due! conn)
  (define due (query-list conn (string-append "SELECT id FROM webhook_deliveries WHERE status = 'pending' "
                                              "AND next_attempt_epoch <= ? ORDER BY next_attempt_epoch ASC "
                                              "LIMIT " (number->string DELIVERY-BATCH))
                          (now)))
  (for/fold ([d 0] [r 0] [x 0]) ([id (in-list due)])
    (case (with-handlers ([(lambda (_) #t) (lambda (_) 'retry)]) (deliver-one! conn id))
      [(delivered) (values (add1 d) r x)]
      [(dead) (values d r (add1 x))]
      [else (values d (add1 r) x)])))

;; ---- reading the record --------------------------------------------------------------
(define (deliveries-list conn team #:webhook [wh #f] #:status [status #f] #:limit [limit 50])
  (define-values (clause args)
    (cond
      [(and wh status) (values " AND webhook_id = ? AND status = ?" (list wh status))]
      [wh (values " AND webhook_id = ?" (list wh))]
      [status (values " AND status = ?" (list status))]
      [else (values "" '())]))
  ;; Two statements rather than one with an interpolated clause would be safer
  ;; still, but the argument list is BUILT WITH the clause here — the mistake
  ;; this codebase has made four times is a fixed argument list beside a
  ;; conditional clause, which is not what this is.
  (for/list ([r (in-list (apply query-rows conn
                                (string-append "SELECT id, webhook_id, event, status, attempts, "
                                               "last_status_code, last_error, last_latency_ms, "
                                               "created_epoch, delivered_epoch, next_attempt_epoch "
                                               "FROM webhook_deliveries WHERE team_id = ?" clause
                                               " ORDER BY created_epoch DESC, id DESC LIMIT "
                                               (number->string (min 200 (max 1 limit))))
                                team args))])
    (hasheq 'id (vector-ref r 0) 'webhook_id (vector-ref r 1) 'event (vector-ref r 2)
            'status (vector-ref r 3) 'attempts (vector-ref r 4)
            'last_status_code (nz (vector-ref r 5)) 'last_error (nz (vector-ref r 6))
            'last_latency_ms (nz (vector-ref r 7)) 'created_epoch (vector-ref r 8)
            'delivered_epoch (nz (vector-ref r 9)) 'next_attempt_epoch (nz (vector-ref r 10)))))

(define (delivery-get conn id team)
  (define rows (deliveries-list conn team #:limit 200))
  (findf (lambda (d) (equal? (hash-ref d 'id) id)) rows))

;; A dead delivery goes back to pending, due now, with its attempt count RESET —
;; an operator redelivering has made a decision, and giving them one attempt out
;; of ten already spent would make the button useless. The delivery id does not
;; change, so a receiver that already applied it still recognises it.
(define (redeliver! conn id team)
  (and (query-maybe-row conn
         (string-append "UPDATE webhook_deliveries SET status = 'pending', attempts = 0, "
                        "next_attempt_epoch = ?, last_error = NULL WHERE id = ? AND team_id = ? "
                        "AND status <> 'pending' RETURNING id")
         (now) id team)
       #t))
