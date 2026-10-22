#lang racket/base

;; test/webhook-tests.rkt — outbound webhooks (#85).
;;
;; Delivery runs against a REAL receiver on a real socket, because every
;; interesting property is at the wire: which headers arrived, whether the
;; signature verifies, what a 500 does versus a 404, and what the row says
;; afterwards. The receiver verifies the signature the way an integrator's would,
;; so the test is also the worked example.
;;
;;   raco test test/webhook-tests.rkt

(require rackunit db-kit/portable db-kit/migrate
         racket/tcp racket/string racket/list racket/port json
         (only-in file/sha1 bytes->hex-string)
         sha2-kit
         "../domain/db/migrations.rkt"
         "db-fixture.rkt"
         "../domain/authz/authz.rkt"
         "../domain/events/events.rkt"
         "../domain/hooks/webhooks.rkt")

(define (fresh) (define c (fresh-db #:migrate? #f)) (migrate! c all-migrations) c)

;; ---- signing ---------------------------------------------------------------------
(test-case "the signature is HMAC-SHA256 over <timestamp>.<body>, pinned"
  ;; The expected value came from Python's `hmac` over the same inputs — an
  ;; independent implementation, which is the only way this assertion means
  ;; anything. An integrator computing it the documented way must get this.
  (check-equal? (sign-payload "topsecret" 1700000000 "{\"event\":\"ping\"}")
                "v1=49dbf5542544194f41a09374d23028d79a5a64b07761bf746c46154c7c5f264a")
  ;; THE TIMESTAMP IS INSIDE THE SIGNED MATERIAL, so a captured body cannot be
  ;; replayed under a fresh header — which is what makes the receiver's five
  ;; minute window enforceable at all.
  (check-not-equal? (sign-payload "topsecret" 1700000001 "{\"event\":\"ping\"}")
                    (sign-payload "topsecret" 1700000000 "{\"event\":\"ping\"}"))
  (check-not-equal? (sign-payload "other" 1700000000 "{\"event\":\"ping\"}")
                    (sign-payload "topsecret" 1700000000 "{\"event\":\"ping\"}")))

(test-case "the backoff is bounded and starts a minute out"
  (check-equal? (backoff-seconds 1) 60)
  (check-equal? (backoff-seconds 2) 120)
  (check-equal? (backoff-seconds 5) 960)
  ;; …and the ceiling holds however many attempts are asked about
  (check-true (<= (backoff-seconds 10) 86400))
  (check-equal? (backoff-seconds 50) 86400))

;; ---- subscriptions ----------------------------------------------------------------
(test-case "an unknown event name is refused rather than stored"
  (check-false (webhook-problem #:url "https://example.com/hook" #:events "*"))
  (check-false (webhook-problem #:url "https://example.com/hook" #:events "run.completed,job.completed"))
  ;; A subscription filtering on a name nothing emits silently never fires, which
  ;; is #113's shape — so it is refused where somebody is reading the answer.
  (check-true (string? (webhook-problem #:url "https://example.com/hook" #:events "run.finished")))
  (check-true (string? (webhook-problem #:url "ftp://example.com/hook" #:events "*")))
  (check-true (string? (webhook-problem #:url "not a url" #:events "*"))))

(test-case "the secret is shown once and is never in a listing"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice"))
  (define-values (id secret) (webhook-create! c #:team tid #:url "https://example.com/h"))
  (check-true (string? secret))
  (check-true (> (string-length secret) 32))
  (define listed (car (webhook-list c tid)))
  (check-false (hash-has-key? listed 'secret))
  (check-false (hash-has-key? (webhook-get c id tid) 'secret))
  ;; it is readable only through the one accessor delivery uses
  (check-equal? (webhook-secret-of c id tid) secret)
  ;; another team's id is a MISS, not a refusal
  (define tid2 (create-team! c #:slug "ops" #:name "Ops"))
  (check-false (webhook-get c id tid2))
  (check-false (webhook-secret-of c id tid2))
  ;; a rotate replaces it, and the old one signs nothing afterwards
  (define-values (_w2 fresh2) (webhook-update! c id tid #:rotate? #t))
  (check-true (string? fresh2))
  (check-not-equal? fresh2 secret)
  (check-equal? (webhook-secret-of c id tid) fresh2))

(test-case "the fan-out respects the filter and the off switch"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice"))
  (define-values (all _s1) (webhook-create! c #:team tid #:url "https://a.example/h" #:events "*"))
  (define-values (runs _s2) (webhook-create! c #:team tid #:url "https://b.example/h"
                                             #:events "run.completed,run.failed"))
  (define-values (off _s3) (webhook-create! c #:team tid #:url "https://c.example/h" #:events "*"))
  (let-values ([(_w _f) (webhook-update! c off tid #:active? #f)]) (void))
  ;; one row per MATCHING, ACTIVE subscription
  (check-equal? (length (enqueue-event! c "run.completed" tid (hasheq 'run_id "r1"))) 2)
  (check-equal? (length (enqueue-event! c "object.created" tid (hasheq 'object_id "o1"))) 1)
  ;; another team's subscriptions never see it
  (define tid2 (create-team! c #:slug "ops" #:name "Ops"))
  (check-equal? (length (enqueue-event! c "run.completed" tid2 (hasheq 'run_id "r2"))) 0))

(test-case "THE PAYLOAD CARRIES IDS AND STATUS, NEVER CONTENT"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice"))
  (define-values (id _s) (webhook-create! c #:team tid #:url "https://a.example/h"))
  (define d (car (enqueue-event! c "run.completed" tid
                                 (hasheq 'run_id "r1" 'status "done" 'url "/api/runs/r1"))))
  (define raw (query-value c "SELECT payload FROM webhook_deliveries WHERE id = ?" d))
  (define body (string->jsexpr raw))
  (check-equal? (hash-ref body 'event) "run.completed")
  (check-equal? (hash-ref body 'delivery_id) d)
  (check-equal? (hash-ref (hash-ref body 'data) 'run_id) "r1")
  ;; The envelope is ids, status, a timestamp and a link. This is asserted on the
  ;; STORED bytes because they are what crosses the network to somebody else's
  ;; server — the emitters are what must not put a document's words in here, and
  ;; the receiver fetches the rest under its own credentials.
  (check-equal? (sort (map symbol->string (hash-keys body)) string<?)
                '("at" "data" "delivery_id" "event" "team_id")))

;; ---- delivery, over a real socket --------------------------------------------------
;; The receiver records what arrived and VERIFIES THE SIGNATURE the way an
;; integrator's would, so this is the worked example as well as the test.
(define (with-receiver reply proc)
  (define L (tcp-listen 0 8 #t "127.0.0.1"))
  (define-values (_h p _rh _rp) (tcp-addresses L #t))
  (define seen (box '()))
  (define t
    (thread (lambda ()
              (with-handlers ([(lambda (_) #t) void])
                (let loop ()
                  (define-values (i o) (tcp-accept L))
                  (thread
                   (lambda ()
                     (with-handlers ([(lambda (_) #t) void])
                       ;; request line + headers
                       (define hs
                         (let rl ([acc '()])
                           (define l (read-line i 'return-linefeed))
                           (cond [(or (eof-object? l) (string=? l "")) (reverse acc)]
                                 [else (rl (cons l acc))])))
                       (define (hdr name)
                         (for/first ([h (in-list hs)]
                                     #:when (string-prefix? (string-downcase h)
                                                            (string-append name ":")))
                           (string-trim (substring h (add1 (string-length name))))))
                       (define len (let ([v (hdr "content-length")]) (if v (string->number v) 0)))
                       (define body (bytes->string/utf-8 (read-bytes len i)))
                       (set-box! seen (cons (list (hdr "x-telemachus-event")
                                                  (hdr "x-telemachus-delivery")
                                                  (hdr "x-telemachus-timestamp")
                                                  (hdr "x-telemachus-signature")
                                                  body)
                                            (unbox seen)))
                       (reply o)
                       (with-handlers ([(lambda (_) #t) void]) (close-output-port o))
                       (with-handlers ([(lambda (_) #t) void]) (close-input-port i)))))
                  (loop))))))
  (define was (getenv "TELEMACHUS_EGRESS_ALLOW"))
  ;; the receiver is on loopback, which #142 refuses unless the OPERATOR allowed
  ;; that network — so the test says so, and puts it back afterwards
  (putenv "TELEMACHUS_EGRESS_ALLOW" "127.0.0.0/8")
  (dynamic-wind
   void
   (lambda () (proc (format "http://127.0.0.1:~a/hook" p) seen))
   (lambda ()
     (putenv "TELEMACHUS_EGRESS_ALLOW" (or was ""))
     (kill-thread t)
     (tcp-close L))))

(define (respond code [body #"ok"])
  (lambda (o)
    (fprintf o "HTTP/1.1 ~a X\r\ncontent-length: ~a\r\nconnection: close\r\n\r\n" code (bytes-length body))
    (write-bytes body o) (flush-output o)))

(test-case "a 2xx delivers, and the signature verifies against the stored secret"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice"))
  (with-receiver (respond 200)
    (lambda (url seen)
      (define-values (id secret) (webhook-create! c #:team tid #:url url))
      (define d (car (enqueue-event! c "ping" tid (hasheq 'note "hello"))))
      (check-equal? (deliver-one! c d) 'delivered)
      (define got (car (unbox seen)))
      (check-equal? (first got) "ping")
      (check-equal? (second got) d)                      ; the idempotency key
      ;; A RECEIVER'S OWN VERIFICATION, done here the documented way: HMAC-SHA256
      ;; over "<timestamp>.<body>" with the shared secret.
      (define ts (third got))
      (define expect
        (string-append "v1=" (bytes->hex-string
                              (hmac-sha256 (string->bytes/utf-8 secret)
                                           (string->bytes/utf-8 (format "~a.~a" ts (fifth got)))))))
      (check-equal? (fourth got) expect)
      ;; and the row says what happened
      (define row (delivery-get c d tid))
      (check-equal? (hash-ref row 'status) "delivered")
      (check-equal? (hash-ref row 'attempts) 1)
      (check-equal? (hash-ref row 'last_status_code) 200)
      (check-true (number? (hash-ref row 'last_latency_ms)))
      (check-true (number? (hash-ref row 'delivered_epoch))))))

(test-case "a 500 is retried with backoff; a 404 is dead at once"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice"))
  (with-receiver (respond 500)
    (lambda (url _seen)
      (define-values (id _s) (webhook-create! c #:team tid #:url url))
      (define d (car (enqueue-event! c "ping" tid (hasheq))))
      (check-equal? (deliver-one! c d) 'retry)
      (define row (delivery-get c d tid))
      (check-equal? (hash-ref row 'status) "pending")
      (check-equal? (hash-ref row 'attempts) 1)
      (check-equal? (hash-ref row 'last_status_code) 500)
      ;; due a minute out, not immediately
      (check-true (>= (- (hash-ref row 'next_attempt_epoch) (current-seconds)) 50))))
  ;; A 4xx that is not 408/429 is the receiver REJECTING this event, and nine
  ;; more attempts are nine more rejections.
  ;;
  ;; ITS OWN DATABASE, deliberately: `enqueue-event!` fans out to EVERY matching
  ;; subscription, so reusing the one above would deliver this event to the 500
  ;; receiver as well — and `created_epoch` is seconds, so the two rows tie and
  ;; `deliveries-list` returns them in the engine's order. The first version of
  ;; this case asserted on `(car …)` and read the wrong row, which is the trap
  ;; the grants listing documents: find a row by its id, never by position.
  (define c2 (fresh))
  (define-values (uid2 tid-b) (bootstrap! c2 #:username "bob"))
  (with-receiver (respond 404)
    (lambda (url _seen)
      (define-values (id _s) (webhook-create! c2 #:team tid-b #:url url))
      (define d (car (enqueue-event! c2 "ping" tid-b (hasheq))))
      (check-equal? (deliver-one! c2 d) 'dead)
      (check-equal? (hash-ref (delivery-get c2 d tid-b) 'attempts) 1))))

(test-case "the attempt ceiling dead-letters, and a redelivery resets it"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice"))
  (with-receiver (respond 503)
    (lambda (url _seen)
      (define-values (id _s) (webhook-create! c #:team tid #:url url))
      (define d (car (enqueue-event! c "ping" tid (hasheq))))
      ;; drive it to the ceiling, making each attempt due as we go
      (for ([_ (in-range (- MAX-ATTEMPTS 1))])
        (check-equal? (deliver-one! c d) 'retry)
        (query-exec c "UPDATE webhook_deliveries SET next_attempt_epoch = ? WHERE id = ?"
                    (- (current-seconds) 1) d))
      (check-equal? (deliver-one! c d) 'dead)
      (define dead (delivery-get c d tid))
      (check-equal? (hash-ref dead 'status) "dead")
      ;; the ceiling row reports the attempts it actually made — the first
      ;; version of `fail-delivery!` did not write the column and this said 9
      (check-equal? (hash-ref dead 'attempts) MAX-ATTEMPTS)
      ;; A redelivery RESETS the count: an operator who pressed the lever has
      ;; made a decision, and one attempt out of ten already spent would make it
      ;; useless. The delivery id does not change, so a receiver that already
      ;; applied it recognises the key.
      (check-true (redeliver! c d tid))
      (define again (delivery-get c d tid))
      (check-equal? (hash-ref again 'id) d)
      (check-equal? (hash-ref again 'status) "pending")
      (check-equal? (hash-ref again 'attempts) 0)
      ;; a pending delivery is not redeliverable — there is nothing to re-send
      (check-false (redeliver! c d tid))
      ;; nor is another team's
      (define tid2 (create-team! c #:slug "ops" #:name "Ops"))
      (check-false (redeliver! c d tid2)))))

(test-case "A POLICY REFUSAL IS PERMANENT, not retried ten times"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice"))
  ;; The metadata endpoint. "This is private address space" will be just as true
  ;; in eight hours, so retrying is ten identical refusals and a dead letter that
  ;; took a day to admit it. A timeout is the opposite and IS retried — that
  ;; split is the whole reason #142's fetcher raises a typed exception.
  (define-values (id _s) (webhook-create! c #:team tid #:url "http://169.254.169.254/hook"))
  (define d (car (enqueue-event! c "ping" tid (hasheq))))
  (check-equal? (deliver-one! c d) 'dead)
  (define row (delivery-get c d tid))
  (check-equal? (hash-ref row 'attempts) 1)
  (check-true (string-contains? (hash-ref row 'last_error) "refused-address")))

(test-case "an inactive subscription stops a delivery already queued, visibly"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice"))
  (with-receiver (respond 200)
    (lambda (url seen)
      (define-values (id _s) (webhook-create! c #:team tid #:url url))
      (define d (car (enqueue-event! c "ping" tid (hasheq))))
      (let-values ([(_w _f) (webhook-update! c id tid #:active? #f)]) (void))
      ;; `dead` rather than vanishing: somebody should be able to see what was
      ;; not sent.
      (check-equal? (deliver-one! c d) 'dead)
      (check-equal? (length (unbox seen)) 0)
      (check-true (string-contains? (hash-ref (delivery-get c d tid) 'last_error) "inactive")))))

(test-case "the sweep delivers what is due and leaves what is not"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice"))
  (with-receiver (respond 200)
    (lambda (url _seen)
      (define-values (id _s) (webhook-create! c #:team tid #:url url))
      (void (enqueue-event! c "ping" tid (hasheq 'n 1)))
      (void (enqueue-event! c "ping" tid (hasheq 'n 2)))
      ;; one of them is not due yet
      (define ds (map (lambda (d) (hash-ref d 'id)) (deliveries-list c tid)))
      (query-exec c "UPDATE webhook_deliveries SET next_attempt_epoch = ? WHERE id = ?"
                  (+ (current-seconds) 3600) (car ds))
      (define-values (sent retried dead) (deliver-due! c))
      (check-equal? (list sent dead) (list 1 0))
      (check-equal? (length (deliveries-list c tid #:status "pending")) 1)
      (check-equal? (length (deliveries-list c tid #:status "delivered")) 1))))

(test-case "deleting a subscription takes its history with it"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice"))
  (define-values (id _s) (webhook-create! c #:team tid #:url "https://a.example/h"))
  (void (enqueue-event! c "ping" tid (hasheq)))
  (check-equal? (length (deliveries-list c tid)) 1)
  (check-true (webhook-delete! c id tid))
  ;; a dead-letter row pointing at a subscription nobody can look up is a row
  ;; nobody can act on; the audit entries are what survive
  (check-equal? (length (deliveries-list c tid)) 0)
  (check-false (webhook-delete! c id tid)))

(test-case "the event vocabulary is closed, and the sink is what carries it"
  (check-true (event? "run.completed"))
  (check-true (event? "ping"))
  (check-false (event? "run.finished"))
  (check-equal? (length EVENTS) 7)
  ;; `emit!` with no sink installed is a no-op rather than an error: the sink is
  ;; installed by main.rkt, and a unit test that exercises a run must not need a
  ;; webhook subsystem.
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice"))
  (set-event-sink! #f)
  (check-not-exn (lambda () (emit! c "run.completed" tid (hasheq 'run_id "r"))))
  ;; AND A SINK THAT RAISES MUST NOT REACH ITS EMITTER — a run must not fail
  ;; because a subscriber's table is missing. This is the rule `fire-triggers!`
  ;; already lives by at the end of repo-put!.
  (dynamic-wind
   (lambda () (set-event-sink! (lambda (conn e team data) (error 'sink "boom"))))
   (lambda () (check-not-exn (lambda () (emit! c "run.completed" tid (hasheq 'run_id "r")))))
   (lambda () (set-event-sink! #f))))
