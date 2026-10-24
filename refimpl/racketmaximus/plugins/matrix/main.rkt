#lang racket/base

;; plugins/matrix/main.rkt — notify a team in a Matrix room (issue #133).
;;
;; "We find matrix to be useful for sending notifications to teams securely.
;; Since we can run this on our own infrastructure, we feel this works as an
;; integration tool." So this is a TRANSPORT and nothing else: the events, the
;; per-team subscription shape and the rule about what a notification may say
;; are all #85's, and a notifier that invented its own event names would be a
;; second vocabulary serving one transport.
;;
;; What it adds, and why each decision is what it is:
;;
;;   • THE CREDENTIAL IS THE OPERATOR'S AND IS NOT IN THE DATABASE. A plugin
;;     cannot own a sealed column — FEED-5 recorded that gap deliberately,
;;     because a plugin-owned sealed column is missing from
;;     `CREDENTIAL-SECRETS` and is therefore silently unrotatable — and an
;;     access token is a credential. Storing it unsealed to get round that
;;     would be the exact failure that rule exists to prevent. So the
;;     homeserver and the bot's token are ENVIRONMENT, the same trust as
;;     `TELEMACHUS_MODEL_URL` or `executors.json`, and a TEAM configures only
;;     which room. Three consequences, all stated rather than discovered: one
;;     bot identity per instance (which is what a self-hosted notifier is), a
;;     tenant admin never sees the token (a property, not a limitation), and
;;     per-team credentials have to wait for the seam FEED-5 named.
;;   • A MESSAGE CARRIES IDS, STATUS AND A LINK — NEVER CONTENT. #85 r2, and it
;;     matters more here than it does for a webhook: a room is read by PEOPLE
;;     who may hold no `can?` on the thing that happened, and Matrix rooms are
;;     routinely bridged to somewhere else again. No document title, no note
;;     body, no prompt, no model output.
;;   • THE SINK ONLY ENQUEUES; A JOB DOES THE SENDING. The sink runs inline in
;;     the emitter's thread (webhooks writes a row for the same reason), and a
;;     job inherits quota admission, the org gate, the lease, the fence,
;;     cancellation and the whole FLEET surface — and `jobs.payload` is sealed,
;;     so the composed line is encrypted at rest with nothing extra here. The
;;     job row IS the pending state, so this plugin needs no table for it.
;;   • THE MATRIX TRANSACTION ID IS THE JOB'S ID. A homeserver ignores a repeat
;;     of a `txnId` it has already seen on that access token, so a job the
;;     lease reaper re-queued cannot post the same line twice. The idempotency
;;     is the protocol's, not a table of ours.
;;   • IT REGISTERS NOTHING WITHOUT A HOMESERVER. `init!` with no
;;     `TELEMACHUS_MATRIX_HOMESERVER` adds no sink and no job kind, so an
;;     instance that does not use Matrix carries no sink in its emit path. The
;;     OCR plugin's opt-in rule: a component that took over because a variable
;;     happened to be set is the mistake the blob-store check refuses.

(require db-kit/portable
         json racket/string racket/list
         (only-in "../../domain/db/id.rkt" new-id)
         (only-in "../../domain/events/events.rkt" EVENTS event? add-event-sink!)
         (only-in "../../domain/sched/scheduler.rkt" register-job-kind! enqueue-job! current-job)
         (only-in "../../domain/authz/authz.rkt" audit! principal-team-id principal-user-id)
         (only-in "../../domain/net/fetch.rkt" fetch safe-url exn:fail:egress? exn:fail:egress-reason)
         (only-in "../../domain/db/nulls.rkt" nz))

(provide migrations routes init!
         ;; exported FOR the tests: the composer and the room rules are the two
         ;; halves worth asserting without a homeserver, and an export with a
         ;; test behind it is not an over-wide export (#110 r4).
         matrix-configured? matrix-homeserver event-line room-create! room-list room-get
         room-update! room-delete! room-problem rooms-for-event send-to-room!
         notify-sink notify-job
         MATRIX-KIND MATRIX-TIMEOUT)

;; ---- the operator's half -------------------------------------------------------------
(define (env n) (let ([v (getenv n)]) (and v (not (string=? (string-trim v) "")) (string-trim v))))
(define (matrix-homeserver) (env "TELEMACHUS_MATRIX_HOMESERVER"))
(define (matrix-token) (env "TELEMACHUS_MATRIX_TOKEN"))
(define (matrix-configured?) (and (matrix-homeserver) (matrix-token) #t))
(define MATRIX-TIMEOUT 15)
(define MATRIX-KIND "x.matrix.notify")
;; A notification is for people. Webhooks' ten attempts with backoff live in a
;; table built for them, and duplicating that here would be a second delivery
;; subsystem inside a plugin; a missed chat line is not a lost event, because
;; the audit log and the webhook path both still have it. So: two attempts a
;; second apart, which covers a homeserver restarting, and then the failure is
;; recorded on the room. A team that needs guaranteed delivery wants a webhook,
;; and the README says so.
(define SEND-ATTEMPTS 2)

;; ---- the team's half -----------------------------------------------------------------
;; One table, and it holds NO credential. Every table and index is named
;; `x_matrix_…`, which the loader enforces.
(define migrations
  (list
   (list "rooms"
         (string-append "CREATE TABLE x_matrix_rooms ("
                        "  id TEXT PRIMARY KEY,"
                        "  team_id TEXT NOT NULL,"
                        ;; FEED-2's rule: the notification is somebody's. The job
                        ;; runs as this member, so the per-team cap, the org gate
                        ;; and the audit trail all name a person rather than a
                        ;; system principal this platform does not have.
                        "  user_id TEXT NOT NULL,"
                        ;; `!abc:example.org` — a room the operator's bot is
                        ;; already in. The plugin never JOINS one (see README).
                        "  room_id TEXT NOT NULL,"
                        "  label TEXT,"
                        ;; "*" or a comma-separated subset of EVENTS, exactly as
                        ;; a webhook subscription spells it
                        "  events TEXT NOT NULL DEFAULT '*',"
                        "  active INTEGER NOT NULL DEFAULT 1,"
                        "  created_by TEXT,"
                        "  created_epoch BIGINT NOT NULL,"
                        "  last_send_epoch BIGINT,"
                        "  last_ok_epoch BIGINT,"
                        ;; the homeserver's status and a message that names the
                        ;; host and the status and nothing else — #142's
                        ;; `safe-url` does the redacting, as it does for a feed
                        "  last_status INTEGER,"
                        "  last_error TEXT)")
         "CREATE INDEX x_matrix_rooms_team ON x_matrix_rooms (team_id)")))

(define (now) (current-seconds))

(define COLS (string-append "id, team_id, user_id, room_id, label, events, active, created_by, "
                            "created_epoch, last_send_epoch, last_ok_epoch, last_status, last_error"))

(define (row->room r)
  (hasheq 'id (vector-ref r 0) 'team_id (vector-ref r 1) 'user_id (vector-ref r 2)
          'room_id (vector-ref r 3) 'label (nz (vector-ref r 4)) 'events (vector-ref r 5)
          'active (= 1 (vector-ref r 6)) 'created_by (nz (vector-ref r 7))
          'created_epoch (vector-ref r 8)
          'last_send_epoch (nz (vector-ref r 9)) 'last_ok_epoch (nz (vector-ref r 10))
          'last_status (nz (vector-ref r 11)) 'last_error (nz (vector-ref r 12))))

;; A Matrix room id is `!opaque:server.name`; an ALIAS is `#room:server.name`
;; and is deliberately not accepted — an alias is resolved by the homeserver and
;; can be moved to point at another room by whoever controls it, which would
;; silently redirect a team's notifications.
;;
;; A `/` IS REFUSED, AND THAT IS NOT COSMETIC. `!` and `:` are legal path
;; characters (RFC 3986) and the client-server API's own examples percent-encode
;; the room id — but #142's fetcher parses the URL and rebuilds the path from it,
;; which decodes `%21`/`%3A` back to the literals, so percent-encoding here is
;; defeated one layer down and the request goes out with `!abc:server` in the
;; path. Synapse accepts that. What it could NOT survive is a slash: it would be
;; rebuilt as a path separator and address a different endpoint entirely. Room
;; ids the homeserver mints do not contain one, so refusing it costs nothing and
;; the alternative — teaching the fetcher to carry a raw path — would weaken the
;; one place every outbound request is normalized.
(define (room-id-ok? s)
  (and (string? s) (regexp-match? #px"^![A-Za-z0-9._=+-]{1,255}:[A-Za-z0-9.-]+(:[0-9]+)?$" s)))

(define (events-ok? e)
  (or (equal? e "*")
      (and (string? e)
           (let ([parts (map string-trim (string-split e ","))])
             (and (pair? parts) (andmap event? parts))))))

(define (room-problem #:room-id room-id #:events events)
  (cond
    [(not (room-id-ok? room-id))
     (string-append "`room_id` must be a Matrix room id like `!abcdef:example.org` — not an alias "
                    "(`#room:example.org`), because an alias is resolved by the homeserver and can "
                    "be repointed at another room by whoever controls it")]
    [(not (events-ok? events))
     (format "`events` must be \"*\" or a comma-separated subset of: ~a" (string-join EVENTS ", "))]
    [else #f]))

(define (room-create! conn #:team team #:user user #:room-id room-id #:label [label #f]
                      #:events [events "*"] #:created-by [by #f])
  (cond
    ;; The member must be ACTIVE, checked at the write: a notification acting as
    ;; somebody outside the team would be a standing grant nobody could see in
    ;; the membership list (FEED-2's reason, and the same statement).
    [(not (positive? (query-value conn (string-append "SELECT COUNT(*) FROM memberships "
                                                      "WHERE team_id = ? AND user_id = ? AND status = 'active'")
                                   team user)))
     'no-such-user]
    [(query-maybe-value conn "SELECT id FROM x_matrix_rooms WHERE team_id = ? AND room_id = ?" team room-id)
     ;; Two subscriptions to one room would post every line twice.
     'duplicate-room]
    [else
     (define id (new-id))
     (query-exec conn (string-append "INSERT INTO x_matrix_rooms (id, team_id, user_id, room_id, label, "
                                     "events, active, created_by, created_epoch) VALUES (?,?,?,?,?,?,1,?,?)")
                 id team user room-id (or label sql-null) (or events "*") (or by sql-null) (now))
     id]))

(define (room-list conn team)
  (for/list ([r (in-list (query-rows conn (string-append "SELECT " COLS " FROM x_matrix_rooms "
                                                         "WHERE team_id = ? ORDER BY created_epoch, id")
                                     team))])
    (row->room r)))

;; Team-scoped IN THE STATEMENT, so another team's id is a miss rather than a
;; refusal — the rule the session, schedule and feed routes follow.
(define (room-get conn id team)
  (define r (query-maybe-row conn (string-append "SELECT " COLS " FROM x_matrix_rooms "
                                                 "WHERE id = ? AND team_id = ?") id team))
  (and r (row->room r)))

(define (room-update! conn id team #:events [events 'same] #:label [label 'same] #:active? [active? 'same])
  (and (room-get conn id team)
       (let ()
         ;; One column per statement: building one UPDATE with a conditional
         ;; clause list and a fixed argument list is how a clause and its
         ;; parameter come apart, six times over in this tree.
         (define (put! col v)
           (query-exec conn (format "UPDATE x_matrix_rooms SET ~a = ? WHERE id = ?" col) v id))
         (when (string? events) (put! "events" events))
         (unless (eq? label 'same) (put! "label" (or label sql-null)))
         (when (boolean? active?) (put! "active" (if active? 1 0)))
         (room-get conn id team))))

(define (room-delete! conn id team)
  (and (room-get conn id team)
       (begin (query-exec conn "DELETE FROM x_matrix_rooms WHERE id = ?" id) #t)))

(define (rooms-for-event conn team event)
  (for/list ([r (in-list (room-list conn team))]
             #:when (and (hash-ref r 'active)
                         (let ([e (hash-ref r 'events)])
                           (or (equal? e "*")
                               (and (member event (map string-trim (string-split e ","))) #t)))))
    r))

;; ---- what a room is told (MTX-8) -----------------------------------------------------
;; IDS, STATUS AND A LINK. The whole function is the rule, which is why it is one
;; function and not a format string per call site: a room is read by people who
;; may hold no `can?` on the subject, and a bridged room is read by people this
;; instance has never heard of. `data` already carries no content (events.rkt
;; says so) — this keeps it true if an emitter ever forgets.
(define (event-line event data)
  (define (id k) (let ([v (hash-ref data k #f)]) (and (string? v) v)))
  (define (short s) (if (and (string? s) (> (string-length s) 12)) (substring s 0 8) s))
  (define url (id 'url))
  (define subject
    (cond
      [(id 'run_id) (format "run ~a" (short (id 'run_id)))]
      [(id 'job_id) (format "job ~a" (short (id 'job_id)))]
      [(id 'object_id) (format "document ~a" (short (id 'object_id)))]
      [(id 'review_id) (format "review ~a" (short (id 'review_id)))]
      [else "something"]))
  (define verb
    (cond
      [(equal? event "run.completed") "finished"]
      [(equal? event "run.failed") "FAILED"]
      [(equal? event "job.completed") "finished"]
      [(equal? event "object.created") "arrived"]
      [(equal? event "object.deleted") "was deleted"]
      [(equal? event "review.decided") (format "was decided: ~a" (or (id 'verdict) "?"))]
      [(equal? event "ping") "— this is a test notification from Telemachus"]
      [else event]))
  ;; The workflow SLUG is a team's own word for a process and is not document
  ;; content, so it earns its place: "run 3f2a finished" tells nobody which
  ;; thing finished.
  (define what (let ([s (id 'workflow)]) (if s (format " (~a)" s) "")))
  (string-append event ": " subject what " " verb (if url (string-append " — " url) "")))

;; ---- the transport -------------------------------------------------------------------
;; `PUT /_matrix/client/v3/rooms/{roomId}/send/m.room.message/{txnId}` — the
;; client-server API's own idempotent send. `txnId` is the JOB's id (MTX-6).
(define (send-to-room! room-id text #:txn txn)
  (define base (matrix-homeserver))
  (define token (matrix-token))
  (unless (and base token) (raise-user-error 'matrix "no Matrix homeserver is configured"))
  (define u (format "~a/_matrix/client/v3/rooms/~a/send/m.room.message/~a"
                    (string-trim base "/" #:left? #f)
                    room-id txn))
  (define body (string->bytes/utf-8 (jsexpr->string (hasheq 'msgtype "m.text" 'body text))))
  (define-values (status _hs _body)
    (fetch u
           #:method "PUT"
           ;; #142's `'trusted`: public, PLUS the private networks the OPERATOR
           ;; allowed. A self-hosted homeserver is exactly the "in our network"
           ;; case, and the URL was chosen by the operator, not by a model.
           #:policy 'trusted
           #:timeout MATRIX-TIMEOUT
           #:headers (list (cons "authorization" (string-append "Bearer " token))
                           (cons "content-type" "application/json"))
           #:body body))
  (values status u))

;; ---- the sink (MTX-5) ----------------------------------------------------------------
;; ENQUEUES ONLY. It runs inline in the emitter's thread, so a homeserver that
;; has stopped answering must not be able to hold a workflow run open for
;; fifteen seconds — which is what sending from here would do.
(define (notify-sink conn event team data)
  (for ([room (in-list (rooms-for-event conn team event))])
    (enqueue-job! conn #:team team #:user (hash-ref room 'user_id) #:kind MATRIX-KIND
                  #:payload (hasheq 'room (hash-ref room 'id)
                                    'room_id (hash-ref room 'room_id)
                                    'event event
                                    'text (event-line event data)))))

(define (notify-job conn p payload)
  (define room (format "~a" (hash-ref payload 'room "")))
  (define room-id (format "~a" (hash-ref payload 'room_id "")))
  (define text (format "~a" (hash-ref payload 'text "")))
  ;; The subscription may have been deleted between the enqueue and the claim.
  ;; Not an error: the team said stop, and a red row in their history for
  ;; housekeeping working correctly is noise.
  (define live (query-maybe-value conn "SELECT id FROM x_matrix_rooms WHERE id = ?" room))
  (cond
    [(not live) (hasheq 'skipped "the room subscription was removed")]
    [else
     ;; `current-job` is the scheduler's parameter, bound around a claimed job.
     ;; Outside a job — a test calling the handler directly — a fresh id is
     ;; right, because there is no attempt to be idempotent about.
     (define txn (let ([j (current-job)]) (if (hash? j) (format "~a" (hash-ref j 'id)) (new-id))))
     (define outcome
       (let attempt ([n 1])
         (define r
           (with-handlers ([exn:fail:egress?
                            (lambda (e) (hasheq 'ok #f 'error (exn-message e)))]
                           [exn:fail?
                            (lambda (e) (hasheq 'ok #f
                                                ;; never the body, never the token: the
                                                ;; homeserver's own error page is its words,
                                                ;; and the URL carries no credential only
                                                ;; because the token is a header
                                                'error (format "~a could not be reached: ~a"
                                                               (safe-url (or (matrix-homeserver) ""))
                                                               (exn-message e))))])
             ;; THE TRANSACTION ID IS THE JOB'S, so a re-claimed attempt cannot
             ;; post the line twice (MTX-6) — and it is the SAME across this
             ;; function's two attempts, which is what makes the retry safe when
             ;; the first attempt actually reached the homeserver and only its
             ;; answer was lost.
             (define-values (status u) (send-to-room! room-id text #:txn txn))
             (hasheq 'ok (and (>= status 200) (< status 300)) 'status status)))
         (if (or (hash-ref r 'ok #f) (>= n SEND-ATTEMPTS))
             r
             (begin (sleep 1) (attempt (add1 n))))))
     (query-exec conn "UPDATE x_matrix_rooms SET last_send_epoch = ?, last_status = ?, last_error = ? WHERE id = ?"
                 (now) (or (hash-ref outcome 'status #f) sql-null)
                 (or (hash-ref outcome 'error #f)
                     (if (hash-ref outcome 'ok #f) sql-null
                         (format "the homeserver answered ~a" (hash-ref outcome 'status "?"))))
                 room)
     (when (hash-ref outcome 'ok #f)
       (query-exec conn "UPDATE x_matrix_rooms SET last_ok_epoch = ? WHERE id = ?" (now) room))
     (hasheq 'ok (and (hash-ref outcome 'ok #f) #t)
             'status (or (hash-ref outcome 'status #f) 'null)
             'room room)]))

;; ---- routes --------------------------------------------------------------------------
;; `webhooks:manage` deliberately, rather than a permission of this plugin's
;; own: it is the same question — where may this instance send notifications —
;; and a PLUGIN CANNOT ADD A PERMISSION to the catalog, which is #113's rule
;; working rather than a limitation. Inventing `matrix:manage` would produce a
;; permission no role grants and `GET /api/roles` never mentions.
(define (rooms-get conn p args)
  (hasheq 'rooms (room-list conn (principal-team-id p))
          'events EVENTS
          ;; An operator who has not set the two variables gets a feed of
          ;; configuration that will never send anything, so the read says so
          ;; rather than leaving it to be discovered — FEED-12's `polling` field,
          ;; for its reason.
          'configured (matrix-configured?)
          'homeserver (let ([h (matrix-homeserver)]) (if h (safe-url h) 'null))))

(define (rooms-post conn p args)
  (define b (let ([v (hash-ref args 'body)]) (if (hash? v) v (hasheq))))
  (define room-id (format "~a" (hash-ref b 'room_id "")))
  (define events (let ([v (hash-ref b 'events "*")]) (if (string? v) v "*")))
  (define label (let ([v (hash-ref b 'label #f)]) (and (string? v) v)))
  (define problem (room-problem #:room-id room-id #:events events))
  (when problem (raise-user-error 'matrix "~a" problem))
  (define r (room-create! conn #:team (principal-team-id p)
                          #:user (let ([v (hash-ref b 'user_id #f)])
                                   (if (string? v) v (principal-user-id p)))
                          #:room-id room-id #:label label #:events events
                          #:created-by (principal-user-id p)))
  (cond
    [(eq? r 'no-such-user)
     (raise-user-error 'matrix "`user_id` must be an active member of this team")]
    [(eq? r 'duplicate-room)
     (raise-user-error 'matrix "this team already notifies that room — two subscriptions would post every line twice")]
    [else
     (audit! conn #:action "matrix.room.create" #:actor-type "user" #:actor-id (principal-user-id p)
             #:team-id (principal-team-id p) #:resource-type "matrix_room" #:resource-id r
             #:meta (jsexpr->string (hasheq 'room_id room-id 'events events)))
     (hasheq 'room (room-get conn r (principal-team-id p)))]))

(define (room-patch conn p args)
  (define id (hash-ref (hash-ref args 'params) 'id #f))
  (define b (let ([v (hash-ref args 'body)]) (if (hash? v) v (hasheq))))
  (define events (let ([v (hash-ref b 'events 'same)]) (if (string? v) v 'same)))
  (when (string? events)
    (let ([problem (room-problem #:room-id "!x:y" #:events events)])
      (when problem (raise-user-error 'matrix "~a" problem))))
  (define r (room-update! conn id (principal-team-id p)
                          #:events events
                          #:label (let ([v (hash-ref b 'label 'same)])
                                    (cond [(eq? v 'same) 'same] [(string? v) v] [else #f]))
                          #:active? (let ([v (hash-ref b 'active 'same)]) (if (boolean? v) v 'same))))
  (unless r (raise-user-error 'matrix "no such room subscription"))
  (hasheq 'room r))

(define (room-del conn p args)
  (define id (hash-ref (hash-ref args 'params) 'id #f))
  (unless (room-delete! conn id (principal-team-id p))
    (raise-user-error 'matrix "no such room subscription"))
  (audit! conn #:action "matrix.room.delete" #:actor-type "user" #:actor-id (principal-user-id p)
          #:team-id (principal-team-id p) #:resource-type "matrix_room" #:resource-id id
          #:meta "{}")
  (hasheq 'ok #t))

;; #85's ping, for #85's reason: a subscription nobody can test is a
;; subscription nobody trusts. It goes through the SAME job as a real
;; notification — a test that took a different path would prove the wrong thing.
(define (room-test conn p args)
  (define id (hash-ref (hash-ref args 'params) 'id #f))
  (define room (room-get conn id (principal-team-id p)))
  (unless room (raise-user-error 'matrix "no such room subscription"))
  (unless (matrix-configured?)
    (raise-user-error 'matrix (string-append "no Matrix homeserver is configured on this instance: set "
                                             "TELEMACHUS_MATRIX_HOMESERVER and TELEMACHUS_MATRIX_TOKEN")))
  (define jid (enqueue-job! conn #:team (principal-team-id p) #:user (hash-ref room 'user_id)
                            #:kind MATRIX-KIND
                            #:payload (hasheq 'room (hash-ref room 'id)
                                              'room_id (hash-ref room 'room_id)
                                              'event "ping"
                                              'text (event-line "ping" (hasheq)))))
  (hasheq 'queued #t 'job_id jid))

(define routes
  (list (list "GET" "/rooms" "webhooks:manage" rooms-get
              "The team's Matrix room subscriptions, the events they may filter on, and whether this instance has a homeserver configured at all.")
        (list "POST" "/rooms" "webhooks:manage" rooms-post
              "Notify a room: {room_id, events?, label?, user_id?}. The room id is a Matrix id (`!abc:example.org`) and never an alias; the bot must already be in it.")
        (list "PATCH" "/rooms/:id" "webhooks:manage" room-patch
              "Change a subscription's `events`, `label` or `active`.")
        (list "DELETE" "/rooms/:id" "webhooks:manage" room-del
              "Stop notifying a room.")
        (list "POST" "/rooms/:id/test" "webhooks:manage" room-test
              "Send a test notification through the same job a real one takes.")))

(define (init!)
  ;; THE JOB KIND IS REGISTERED UNCONDITIONALLY AND THE SINK IS NOT, and the
  ;; asymmetry is the point rather than an inconsistency.
  ;;
  ;; `docs/reference/plugins.md` is GENERATED from the loaded plugins and is
  ;; COMMITTED, with a CI gate on drift — so anything in it that depends on the
  ;; machine's environment makes that gate non-deterministic. The first version
  ;; registered the kind inside the `when` and the reference therefore said
  ;; something different on a box with a homeserver configured than on one
  ;; without: CI caught it on this very branch, because the file had been
  ;; rendered in a shell where the variables were set. The generated reference
  ;; is a property of the BUILD, and this is now one.
  ;;
  ;; Registering the kind costs nothing: nothing enqueues it unless the sink
  ;; does, and the handler refuses by name if somebody enqueues one by hand with
  ;; no homeserver to send to. What the opt-in has to protect is the EMIT PATH —
  ;; a sink in every emitter of an instance that does not speak Matrix — and
  ;; that is the half still behind the switch.
  (register-job-kind! MATRIX-KIND notify-job)
  (when (matrix-configured?)
    (add-event-sink! "matrix" notify-sink)))
