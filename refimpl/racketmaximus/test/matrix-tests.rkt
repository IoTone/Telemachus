#lang racket/base

;; test/matrix-tests.rkt — the Matrix notification plugin (issue #133).
;;
;;   raco test test/matrix-tests.rkt
;;
;; Three things carry the slice, and each is written so the obvious wrong
;; implementation fails:
;;
;;   1. A ROOM IS TOLD IDS, STATUS AND A LINK — NEVER CONTENT (MTX-8). The
;;      fixture event carries a document title and a note body, and the
;;      assertion is that neither reaches the line. A room is read by people who
;;      may hold no `can?` on the subject, and a bridged room is read by people
;;      this instance has never heard of.
;;   2. THE SINK ONLY ENQUEUES (MTX-5). Asserted by emitting with NO homeserver
;;      reachable at all and checking a job row appeared: a sink that posted
;;      would hold the emitter's thread open on a dead socket.
;;   3. THE TRANSACTION ID IS THE JOB'S (MTX-6), so a re-claimed attempt cannot
;;      post the same line twice. Asserted at the WIRE, over the paths the
;;      homeserver actually saw.
;;
;; Plus the platform half of the slice: the event sink is a registry now, and one
;; subscriber raising must not cost another its delivery.

(require rackunit db-kit/portable db-kit/migrate
         racket/tcp racket/string racket/list racket/port json
         "../domain/db/migrations.rkt"
         "db-fixture.rkt"
         "../domain/authz/authz.rkt"
         (only-in "../domain/agent/plugins.rkt" check-migrations!)
         (only-in "../domain/events/events.rkt"
                  emit! add-event-sink! remove-event-sink! event-sinks EVENTS)
         (only-in "../domain/sched/scheduler.rkt" current-job register-job-kind! registered-job-kinds)
         "../plugins/matrix/main.rkt")

;; The plugin's table is applied through the platform's own runner, exactly as
;; the loader does it — so the test cannot pass against SQL the loader would
;; refuse (`check-migrations!` is what enforces the `x_matrix_` prefix).
(define (fresh)
  (define c (fresh-db #:migrate? #f))
  (migrate! c all-migrations)
  (migrate! c (check-migrations! "matrix" migrations))
  c)

(define (owner c)
  (define-values (u t) (bootstrap! c #:username "alice" #:org-name "Acme" #:org-slug "acme"
                                   #:team-name "Eng" #:team-slug "eng"))
  (values u t))

(define (with-env name value thunk)
  (define saved (getenv name))
  (dynamic-wind (lambda () (putenv name (or value ""))) thunk
                (lambda () (putenv name (or saved "")))))

(define ROOM "!abcdef:example.internal")

;; ---- 1. what a room is told (MTX-8) ----------------------------------------------------
(test-case "a notification carries ids, status and a link — never content"
  ;; An emitter is not supposed to put content in `data` (events.rkt says so),
  ;; and this is what keeps that true if one ever forgets: the composer reads the
  ;; fields it knows and nothing else.
  (define data (hasheq 'run_id "3f2a91bc-1111-2222-3333-444455556666"
                       'workflow "process-upload"
                       'url "/api/runs/3f2a91bc"
                       'title "Patient discharge summary — J. Smith"
                       'body "the claimant states that on 14 March"
                       'prompt "summarise the attached letter"))
  (define line (event-line "run.failed" data))
  (check-true (string-contains? line "run.failed"))
  (check-true (string-contains? line "3f2a91bc"))
  (check-true (string-contains? line "process-upload") "a workflow slug is the team's own word, not content")
  (check-true (string-contains? line "FAILED"))
  (check-true (string-contains? line "/api/runs/3f2a91bc") "a link, so somebody can go and look under their own can?")
  ;; THE ASSERTIONS THAT MATTER
  (check-false (string-contains? line "J. Smith") "a document title must never reach a room")
  (check-false (string-contains? line "claimant") "a note body must never reach a room")
  (check-false (string-contains? line "summarise") "a prompt must never reach a room")
  ;; the id is shortened, because a room is read by people
  (check-false (string-contains? line "444455556666"))
  ;; every event in the closed vocabulary composes to something a person can read
  (for ([e (in-list EVENTS)])
    (define l (event-line e (hasheq 'object_id "abcd1234-0000" 'url "/x")))
    (check-true (string-prefix? l e) (format "~a: ~a" e l))
    (check-true (> (string-length l) (+ 2 (string-length e))) (format "~a says nothing: ~a" e l))))

;; ---- the room subscription --------------------------------------------------------------
(test-case "an alias is refused, because an alias can be repointed at another room"
  (check-false (room-problem #:room-id ROOM #:events "*"))
  (check-false (room-problem #:room-id ROOM #:events "run.failed,review.decided"))
  (check-true (string? (room-problem #:room-id "#ops:example.internal" #:events "*")))
  (check-true (string? (room-problem #:room-id "example.internal" #:events "*")))
  (check-true (string? (room-problem #:room-id "!noserver" #:events "*")))
  ;; a slash would be rebuilt as a path separator by the fetcher and address a
  ;; different endpoint — see `room-id-ok?`
  (check-true (string? (room-problem #:room-id "!ab/cd:example.internal" #:events "*")))
  ;; an event invented in passing is a filter that silently matches nothing
  (define p (room-problem #:room-id ROOM #:events "run.exploded"))
  (check-true (string? p))
  (check-true (string-contains? p "run.completed") "the refusal names the vocabulary"))

(test-case "a subscription names an active member, and a room is subscribed once"
  (define c (fresh))
  (define-values (uid tid) (owner c))
  (define id (room-create! c #:team tid #:user uid #:room-id ROOM #:label "ops" #:created-by uid))
  (check-true (string? id))
  ;; FEED-2's rule: a notification acting as somebody outside the team would be a
  ;; standing grant nobody could see in the membership list
  (check-equal? (room-create! c #:team tid #:user "u-nobody" #:room-id "!other:example.internal")
                'no-such-user)
  ;; two subscriptions to one room would post every line twice
  (check-equal? (room-create! c #:team tid #:user uid #:room-id ROOM) 'duplicate-room)
  (check-equal? (length (room-list c tid)) 1)
  ;; another team's id is a MISS, not a refusal
  (check-false (room-get c id "t-other"))
  (check-true (hash-ref (room-get c id tid) 'active))
  (void (room-update! c id tid #:active? #f #:events "run.failed"))
  (check-false (hash-ref (room-get c id tid) 'active))
  (check-equal? (hash-ref (room-get c id tid) 'events) "run.failed")
  (check-true (room-delete! c id tid))
  (check-false (room-delete! c id tid))
  (close-db! c))

(test-case "an inactive subscription, and one filtered to other events, is not notified"
  (define c (fresh))
  (define-values (uid tid) (owner c))
  (define all (room-create! c #:team tid #:user uid #:room-id "!all:example.internal"))
  (define some (room-create! c #:team tid #:user uid #:room-id "!some:example.internal"
                             #:events "run.failed"))
  (define off (room-create! c #:team tid #:user uid #:room-id "!off:example.internal"))
  (void (room-update! c off tid #:active? #f))
  (define (rooms e) (sort (for/list ([r (in-list (rooms-for-event c tid e))]) (hash-ref r 'room_id)) string<?))
  (check-equal? (rooms "run.failed") (list "!all:example.internal" "!some:example.internal"))
  (check-equal? (rooms "object.created") (list "!all:example.internal"))
  (check-equal? (rooms-for-event c "t-other" "run.failed") '())
  (close-db! c))

;; ---- 2. the sink only enqueues (MTX-5) --------------------------------------------------
(test-case "the sink enqueues a job and sends nothing itself"
  (define c (fresh))
  (define-values (uid tid) (owner c))
  (void (room-create! c #:team tid #:user uid #:room-id ROOM))
  ;; A homeserver that does not exist. A sink that POSTED would hang here for
  ;; MATRIX-TIMEOUT or raise; a sink that enqueues does not care.
  (with-env "TELEMACHUS_MATRIX_HOMESERVER" "http://127.0.0.1:1"
    (lambda ()
      (with-env "TELEMACHUS_MATRIX_TOKEN" "syt_test"
        (lambda ()
          (define before (query-value c "SELECT COUNT(*) FROM jobs"))
          (notify-sink c "run.failed" tid (hasheq 'run_id "r-1" 'url "/api/runs/r-1"))
          (check-equal? (query-value c "SELECT COUNT(*) FROM jobs") (add1 before))
          (check-equal? (query-value c "SELECT kind FROM jobs ORDER BY created_epoch DESC LIMIT 1")
                        MATRIX-KIND)
          ;; …and the job runs as the subscription's user, not as nobody
          (check-equal? (query-value c "SELECT user_id FROM jobs ORDER BY created_epoch DESC LIMIT 1")
                        uid)
          ;; a team with no subscription enqueues nothing
          (notify-sink c "run.failed" "t-other" (hasheq 'run_id "r-2"))
          (check-equal? (query-value c "SELECT COUNT(*) FROM jobs") (add1 before))))))
  (close-db! c))

;; ---- the platform half: several named sinks --------------------------------------------
(test-case "one subscriber raising does not cost another its delivery"
  (define c (fresh))
  (define-values (uid tid) (owner c))
  (define got (box '()))
  (dynamic-wind
   void
   (lambda ()
     (add-event-sink! "broken" (lambda (conn e team data) (error 'sink "boom")))
     (add-event-sink! "watcher" (lambda (conn e team data) (set-box! got (cons e (unbox got)))))
     (check-true (and (member "watcher" (event-sinks)) #t))
     ;; the first sink raises and is swallowed; the second still runs. With one
     ;; shared handler round the lot, this is the assertion that fails.
     (emit! c "run.failed" tid (hasheq 'run_id "r-1"))
     (check-equal? (unbox got) (list "run.failed"))
     ;; re-adding a NAME replaces it rather than appending — the loader may run
     ;; twice in one process
     (add-event-sink! "watcher" (lambda (conn e team data) (set-box! got (cons "second" (unbox got)))))
     (check-equal? (length (filter (lambda (n) (equal? n "watcher")) (event-sinks))) 1)
     (emit! c "ping" tid (hasheq))
     (check-equal? (unbox got) (list "second" "run.failed")))
   (lambda () (remove-event-sink! "broken") (remove-event-sink! "watcher")))
  (close-db! c))

;; ---- 3. the wire, over a real socket ----------------------------------------------------
(define (with-homeserver status proc)
  (define L (tcp-listen 0 8 #t "127.0.0.1"))
  (define-values (_h port _rh _rp) (tcp-addresses L #t))
  (define seen (box '()))
  (define t
    (thread (lambda ()
              (with-handlers ([(lambda (_) #t) void])
                (let loop ()
                  (define-values (i o) (tcp-accept L))
                  (thread (lambda ()
                            (with-handlers ([(lambda (_) #t) void])
                              (define lines
                                (let rl ([acc '()])
                                  (define l (read-line i 'return-linefeed))
                                  (cond [(or (eof-object? l) (string=? l "")) (reverse acc)]
                                        [else (rl (cons l acc))])))
                              (define len (for/or ([h (in-list lines)])
                                            (and (string-prefix? (string-downcase h) "content-length:")
                                                 (string->number (string-trim (cadr (string-split h ":")))))))
                              (define body (if (and len (> len 0)) (read-string len i) ""))
                              (set-box! seen (append (unbox seen) (list (cons lines body))))
                              (fprintf o "HTTP/1.1 ~a X\r\ncontent-type: application/json\r\ncontent-length: 17\r\nconnection: close\r\n\r\n{\"event_id\":\"$1\"}" status)
                              (flush-output o)
                              (with-handlers ([(lambda (_) #t) void]) (close-output-port o))
                              (with-handlers ([(lambda (_) #t) void]) (close-input-port i)))))
                  (loop))))))
  (define was (getenv "TELEMACHUS_EGRESS_ALLOW"))
  ;; a self-hosted homeserver is on a private network, which #142 refuses unless
  ;; the OPERATOR allowed it — which is this issue's whole case
  (putenv "TELEMACHUS_EGRESS_ALLOW" "127.0.0.0/8")
  (dynamic-wind
   void
   (lambda ()
     (with-env "TELEMACHUS_MATRIX_HOMESERVER" (format "http://127.0.0.1:~a" port)
       (lambda () (with-env "TELEMACHUS_MATRIX_TOKEN" "syt_s3cret"
                    (lambda () (proc seen))))))
   (lambda ()
     (putenv "TELEMACHUS_EGRESS_ALLOW" (or was ""))
     (kill-thread t)
     (tcp-close L))))

(test-case "the send is the client-server API's idempotent one, and it carries the token"
  (define c (fresh))
  (define-values (uid tid) (owner c))
  (define id (room-create! c #:team tid #:user uid #:room-id ROOM))
  (with-homeserver 200
    (lambda (seen)
      (define payload (hasheq 'room id 'room_id ROOM 'event "run.failed" 'text "run.failed: run abc FAILED"))
      (define r (parameterize ([current-job (hasheq 'id "job-1111" 'team tid 'user uid)])
                  (notify-job c (user-principal c uid tid) payload)))
      (check-true (hash-ref r 'ok))
      (check-equal? (hash-ref r 'status) 200)
      (define req (car (unbox seen)))
      (define line (car (car req)))
      ;; PUT …/rooms/{roomId}/send/m.room.message/{txnId}
      (check-true (string-prefix? line "PUT /_matrix/client/v3/rooms/") line)
      (check-true (string-contains? line "/send/m.room.message/job-1111") line)
      ;; THE ROOM ID GOES OUT WITH `!` AND `:` LITERAL, and that is the
      ;; fetcher's doing, not an oversight: #142 parses the URL and rebuilds the
      ;; path, which decodes any percent-encoding this plugin applied. Both
      ;; characters are legal in a path (RFC 3986) and Synapse accepts them. A
      ;; `/` would not survive that rebuild, which is why `room-problem` refuses
      ;; one — and this assertion is what would notice if the fetcher's
      ;; normalization ever changed.
      (check-true (string-contains? line "/rooms/!abcdef:example.internal/send/") line)
      ;; the credential is a HEADER, which is also why the stored error can name
      ;; the URL without naming the token
      ;; `string-downcase` on the whole header would also lower-case the TOKEN,
      ;; which is the quiet way to write an assertion that cannot fail.
      (check-true (for/or ([h (in-list (car req))])
                    (and (string-prefix? (string-downcase h) "authorization:")
                         (string-contains? h "Bearer syt_s3cret")))
                  (format "~a" (car req)))
      (define body (string->jsexpr (cdr req)))
      (check-equal? (hash-ref body 'msgtype) "m.text")
      (check-equal? (hash-ref body 'body) "run.failed: run abc FAILED")
      ;; the room row records the outcome
      (define room (room-get c id tid))
      (check-equal? (hash-ref room 'last_status) 200)
      (check-equal? (hash-ref room 'last_error) 'null)
      (check-true (number? (hash-ref room 'last_ok_epoch)))))
  (close-db! c))

(test-case "the transaction id is the job's, so a re-claimed attempt cannot post twice"
  (define c (fresh))
  (define-values (uid tid) (owner c))
  (define id (room-create! c #:team tid #:user uid #:room-id ROOM))
  (with-homeserver 200
    (lambda (seen)
      (define payload (hasheq 'room id 'room_id ROOM 'event "ping" 'text "ping"))
      (define (run!) (parameterize ([current-job (hasheq 'id "job-2222" 'team tid 'user uid)])
                       (notify-job c (user-principal c uid tid) payload)))
      (void (run!))
      (void (run!))
      ;; the request line is `PUT <path> HTTP/1.1`, and the txnId is the path's
      ;; last segment
      (define txns (for/list ([r (in-list (unbox seen))])
                     (last (string-split (cadr (string-split (car (car r)) " ")) "/"))))
      (check-equal? (length txns) 2)
      ;; THE POINT: both attempts carry the SAME txnId, which is what makes the
      ;; homeserver drop the second. A fresh id per attempt would post twice.
      (check-equal? (car txns) (cadr txns))
      (check-equal? (car txns) "job-2222")))
  (close-db! c))

(test-case "a homeserver that refuses is recorded as a status, and the room says so"
  (define c (fresh))
  (define-values (uid tid) (owner c))
  (define id (room-create! c #:team tid #:user uid #:room-id ROOM))
  (with-homeserver 403
    (lambda (seen)
      (define r (parameterize ([current-job (hasheq 'id "job-3333" 'team tid 'user uid)])
                  (notify-job c (user-principal c uid tid) (hasheq 'room id 'room_id ROOM
                                                                   'event "ping" 'text "ping"))))
      (check-false (hash-ref r 'ok))
      (check-equal? (hash-ref r 'status) 403)
      ;; two attempts, a second apart — enough for a homeserver restarting, and
      ;; deliberately not webhooks' ten with backoff
      (check-equal? (length (unbox seen)) 2)
      (define room (room-get c id tid))
      (check-equal? (hash-ref room 'last_status) 403)
      (check-true (string-contains? (hash-ref room 'last_error) "403"))
      (check-equal? (hash-ref room 'last_ok_epoch) 'null
                    "`last_ok_epoch` must not move on a refusal, or \"it last worked at\" is a lie")))
  (close-db! c))

(test-case "a subscription deleted between the enqueue and the claim is not an error"
  (define c (fresh))
  (define-values (uid tid) (owner c))
  (define id (room-create! c #:team tid #:user uid #:room-id ROOM))
  (void (room-delete! c id tid))
  (with-homeserver 200
    (lambda (seen)
      (define r (notify-job c (user-principal c uid tid)
                            (hasheq 'room id 'room_id ROOM 'event "ping" 'text "ping")))
      (check-true (string? (hash-ref r 'skipped #f)))
      (check-equal? (unbox seen) '() "nothing is sent for a subscription the team removed")))
  (close-db! c))

;; ---- off unless configured --------------------------------------------------------------
(test-case "with no homeserver the plugin registers nothing and the read says so"
  (with-env "TELEMACHUS_MATRIX_HOMESERVER" ""
    (lambda ()
      (with-env "TELEMACHUS_MATRIX_TOKEN" ""
        (lambda ()
          (check-false (matrix-configured?))
          (check-false (matrix-homeserver))
          ;; `init!` adds no sink and no job kind, so an instance that does not
          ;; use Matrix carries nothing extra in its emit path.
          ;;
          ;; Asserted about THIS sink by name rather than over the whole list:
          ;; `raco test` runs the suite's files in one process, environment
          ;; variables are process-global, and another file calling
          ;; `load-plugins!` while one of the cases above has a homeserver set
          ;; will legitimately register "matrix" from under us. The property
          ;; being tested is "init! does not add it", not "nobody else did".
          (remove-event-sink! "matrix")
          (init!)
          (check-false (and (member "matrix" (event-sinks)) #t))
          ;; THE JOB KIND IS REGISTERED EITHER WAY, deliberately:
          ;; `docs/reference/plugins.md` is generated from the loaded plugins and
          ;; gated on drift, so a kind that appeared only on a configured box
          ;; made that gate depend on the environment — which is exactly how CI
          ;; failed on this branch while the suite passed locally. The opt-in
          ;; protects the EMIT PATH, which is the sink above.
          (check-true (and (member MATRIX-KIND (registered-job-kinds)) #t))
          ;; and a send refuses by name rather than composing a URL from ""
          (check-exn exn:fail? (lambda () (send-to-room! ROOM "x" #:txn "t")))))))
  ;; configured, it registers both — and `init!` twice in one process is fine,
  ;; because the loader may run twice
  (with-env "TELEMACHUS_MATRIX_HOMESERVER" "http://127.0.0.1:1"
    (lambda ()
      (with-env "TELEMACHUS_MATRIX_TOKEN" "syt_test"
        (lambda ()
          (dynamic-wind
           void
           (lambda ()
             (init!)
             (init!)
             (check-true (and (member "matrix" (event-sinks)) #t))
             (check-equal? (length (filter (lambda (n) (equal? n "matrix")) (event-sinks))) 1)
             (check-true (and (member MATRIX-KIND (registered-job-kinds)) #t)))
           (lambda () (remove-event-sink! "matrix"))))))))
