#lang racket/base

;; domain/feeds/feeds.rkt — external feed CONFIGURATION (#114, FEED-2/-5/-6/-12).
;;
;; Every ingestion path this platform has is PUSHED: a console upload, an API
;; PUT, an S3 PUT, a worker's derive. A feed is the configuration a PULL needs —
;; where to fetch from, whose authority the fetch spends, and the credential to
;; present. What a pull LANDS is slice 4 (`feeds/<slug>/<external-id>` as a repo
;; object, with per-item dedup); this module deliberately ships first, because
;; the credential and its rotation are the half that has to be right before a
;; single byte crosses the network.
;;
;; Three rules carry the slice:
;;
;;   • THE FETCH IS SOMEBODY'S. `user_id` is NOT NULL — there is no system
;;     principal here (0051's schedules made the same call), so everything a
;;     poll writes is that person's, judged by their `can?` and billed to their
;;     team. The user must be an ACTIVE MEMBER of the feed's team, checked at
;;     write time: a feed acting as somebody outside the team would be a
;;     standing grant nobody could see in the membership list.
;;   • THE SECRET IS SEALED AND ROTATABLE. `define-sealed-column` (#110 r1) with
;;     AAD `feeds.secret:<id>`, plus a row in `CREDENTIAL-SECRETS` so
;;     `telemachus-secrets rewrap` walks it. It is unsealed at REQUEST time and
;;     never returned by any read — `GET` answers `has_secret`, not the secret.
;;   • A FAILURE NAMES THE HOST, THE PATH AND THE STATUS (FEED-6). The redaction
;;     lives in #142's fetcher, so it cannot be forgotten here; what this module
;;     adds is the discipline of storing `last_error` from that message and
;;     putting `safe-url` — not `url` — in the audit meta, because the audit log
;;     is chained, exported and kept through an erasure (DEL-7).

(require db-kit/portable
         json
         racket/string
         net/url
         "../db/id.rkt"
         (only-in "../authz/sealed.rkt" define-sealed-column)
         (only-in "../net/fetch.rkt" fetch safe-url same-origin? exn:fail:egress? exn:fail:egress-reason)
         (only-in "adapters.rkt" feed-adapter-for feed-adapter-kinds)
         (only-in "../sched/schedules.rkt" schedule-create! schedule-delete! schedule-get
                  schedule-update! SCHEDULE-MIN-INTERVAL)
         "../db/nulls.rkt")

(provide FEED-KINDS FEED-AUTHS PROBE-ONLY-KINDS POLL-KIND PROBE-TIMEOUT PROBE-MAX-BYTES
         feed-problem feed-create! feed-list feed-get feed-update! feed-delete!
         feed-secret-of feed-credential-headers feed-request feed-auth-apply probe-feed! record-fetch!
         feed-by-id feed-cursor-set! feed-poll-recorded!
         feed-item-ref feed-item-record! feed-item-forget! feed-items-count)

;; #19's seam. A feed's token is a CREDENTIAL — it is replayed against somebody
;; else's API — so it belongs in `CREDENTIAL-SECRETS` beside the webhook signing
;; key, not in `CONTENT-SECRETS`, and `rewrap` rotates it whether or not the
;; operator turned content encryption on.
(define-sealed-column "feeds.secret" (seal-secret unseal-secret) (id) #:credential)

;; FEED-14: THE KIND LIST IS DERIVED FROM THE ADAPTER REGISTRY, never a second
;; list beside it — the rule `available` locales live by, and the reason a
;; configurable kind this build cannot pull is impossible rather than merely
;; unlikely (#113's shape).
;;
;; `http.json` is the one kind with NO adapter, and it stays (FEED-15): a probe
;; is the honest first step of configuring any source, so the kind is reachable
;; by `probe` and refused by name by `poll`. Guessing where the items are in an
;; unknown body — and which field is the identity — is what DWF-5 refuses on the
;; model's own output, and here a wrong guess would write somebody else's data
;; under an identity that is not theirs, which the dedup hash then makes
;; permanent.
(define PROBE-ONLY-KINDS '("http.json"))

;; The job kind a feed's own schedule fires (FEED-21). Platform-set, never the
;; caller's, which is what stops the feed plane being a way to schedule
;; arbitrary work for somebody holding `feeds:manage` and not `jobs:schedule`.
(define POLL-KIND "feed.poll")

(define (FEED-KINDS) (sort (append PROBE-ONLY-KINDS (feed-adapter-kinds)) string<?))

;; How the stored secret is presented to the source.
;;
;; `query` IS SUPPORTED, AND IT IS THE UNCOMFORTABLE ONE. A token in a query
;; string is exactly what FEED-6 is about — but it is also how a great many real
;; feeds authenticate, and refusing it would not make those sources safer, it
;; would make them unreachable and push the operator into pasting the token into
;; the `url` field, where it would be stored UNSEALED and logged. So it is a
;; first-class auth mode: the secret is sealed at rest, appended at request time,
;; and the fetcher redacts the query out of every error it raises.
;;
;; Basic auth is deliberately not its own mode — it is `header` with a
;; pre-encoded `Basic …` value, which keeps this list to the shapes that differ.
(define FEED-AUTHS '("none" "bearer" "header" "query"))

(define PROBE-TIMEOUT 15)
;; A probe answers "is this reachable, and does it look like the kind it claims".
;; It is not an ingest, so it reads a little and stops; slice 4 sets its own cap.
(define PROBE-MAX-BYTES (* 64 1024))

(define (now) (current-seconds))

(define (slug-ok? s)
  (and (string? s) (regexp-match? #px"^[a-z0-9][a-z0-9-]{0,62}$" s)))

;; ---- validation -------------------------------------------------------------------
;; One function for create AND patch, so a patch cannot reach a state a create
;; could not — the rule the schedule and webhook routes follow.
(define (feed-problem #:slug slug #:kind kind #:url url #:auth auth #:auth-name auth-name
                      #:secret secret)
  (define parsed (with-handlers ([exn:fail? (lambda (_) #f)]) (string->url (if (string? url) url ""))))
  (cond
    [(not (slug-ok? slug))
     "`slug` must be 1-63 characters of a-z, 0-9 and dashes, starting with a letter or digit — it is the key prefix pulled items land under"]
    [(not (member kind (FEED-KINDS)))
     (format "unknown feed kind `~a` — this build knows: ~a" kind (string-join (FEED-KINDS) ", "))]
    [(not (and parsed (url-host parsed) (member (url-scheme parsed) '("http" "https"))))
     "`url` must be an http(s) URL"]
    ;; `https://user:pass@host/…` is UNAMBIGUOUSLY a credential, and this row has
    ;; a sealed place for one. Stored in the URL it would be in the clear, in
    ;; every read of the row, and — the reason it is refused rather than quietly
    ;; moved — the operator would have no idea which of the two homes was in use.
    ;; A query token is NOT refused, because `?project=FOO&token=…` cannot be told
    ;; apart from configuration by inspection; `auth: "query"` is how that one is
    ;; stored properly, and the fetcher redacts the query out of every error.
    [(url-user parsed)
     "take the credential out of `url` — a username or password there is stored in the clear. Use `auth` with a `secret`: `bearer`, a named `header` (a pre-encoded `Basic …` value for basic auth), or `query`."]
    [(not (member auth FEED-AUTHS))
     (format "unknown auth `~a` — one of: ~a" auth (string-join FEED-AUTHS ", "))]
    ;; A credential with no way to present it, and a presentation with no
    ;; credential, are both configuration that will fail on the first poll. Said
    ;; now, where somebody is looking, rather than in `last_error` tomorrow.
    [(and (member auth '("bearer" "header" "query")) (not secret))
     (format "auth `~a` needs a `secret`" auth)]
    [(and (string=? auth "none") secret)
     "auth `none` takes no `secret` — choose how the secret is presented, or send none"]
    [(and (member auth '("header" "query"))
          (not (and (string? auth-name) (regexp-match? #px"^[A-Za-z0-9_-]{1,64}$" auth-name))))
     (format "auth `~a` needs `auth_name` — the ~a the secret travels in" auth
             (if (string=? auth "header") "header name" "query parameter name"))]
    ;; A header request is built as `name: value`, and the fetcher writes the
    ;; pairs as `~a: ~a\r\n`, so a break in the secret adds a header. Refused
    ;; here for a feedback loop an operator reads, and again in the fetcher,
    ;; because a row stored before this check exists is never re-validated.
    [(and (string? secret) (member auth '("bearer" "header" "query"))
          (secret-has-a-control-character? secret))
     "`secret` must not contain control characters — a line break in it would add headers to the request"]
    [else #f]))

(define (secret-has-a-control-character? s)
  (for/or ([c (in-string s)]) (or (< (char->integer c) 32) (= (char->integer c) 127))))

;; ---- rows -------------------------------------------------------------------------
(define SELECT
  (string-append "SELECT id, team_id, user_id, slug, name, kind, url, auth, auth_name, active, "
                 "created_by, created_epoch, last_fetch_epoch, last_ok_epoch, last_status, "
                 "last_error, secret, cursor, poll_seconds, schedule_id, last_items FROM feeds "))

(define (row->feed conn r)
  (hasheq 'id (vector-ref r 0)
          'team_id (vector-ref r 1)
          'user_id (vector-ref r 2)
          'slug (vector-ref r 3)
          'name (nz (vector-ref r 4))
          'kind (vector-ref r 5)
          ;; As CONFIGURED, deliberately. A read is behind the same permission
          ;; that wrote it, and an operator who cannot see the URL they typed
          ;; cannot maintain the feed. What is NOT returned is the credential —
          ;; and `url` cannot carry one, because userinfo is refused and a query
          ;; token has `auth: "query"` as its proper home.
          'url (vector-ref r 6)
          'auth (vector-ref r 7)
          'auth_name (nz (vector-ref r 8))
          'active (= 1 (vector-ref r 9))
          'created_by (nz (vector-ref r 10))
          'created_epoch (vector-ref r 11)
          'last_fetch_epoch (nz (vector-ref r 12))
          'last_ok_epoch (nz (vector-ref r 13))
          'last_status (nz (vector-ref r 14))
          'last_error (nz (vector-ref r 15))
          ;; NEVER the secret, in any read. Whether there IS one is configuration
          ;; the operator needs to see; the value is write-only after create.
          'has_secret (not (sql-null? (vector-ref r 16)))
          'cursor (nz (vector-ref r 17))
          'poll_seconds (nz (vector-ref r 18))
          'last_items (nz (vector-ref r 20))
          ;; Whether a kind can be polled at all is a property of the BUILD, not
          ;; of the row (FEED-15): `http.json` is probe-only, and a reader who
          ;; could not tell would configure a feed and wait for items that are
          ;; never coming.
          'pollable (and (feed-adapter-for (vector-ref r 5)) #t)
          ;; FEED-21: `polling` is DERIVED from the schedule row the feed owns,
          ;; never stored — the rule `missing`/`stale` and `worker_state` already
          ;; live by. A stored flag could disagree with the row that actually
          ;; fires, and then "polling: true" beside a feed nothing has polled for
          ;; a week leaves nobody able to say which of the two is lying.
          'polling (let* ([sid (vector-ref r 19)]
                          [sched (and (not (sql-null? sid))
                                      (schedule-get conn sid (vector-ref r 1)))])
                     (and sched (not (hash-ref sched 'paused #f)) #t))))

(define (feed-list conn team)
  (for/list ([r (in-list (query-rows conn (string-append SELECT "WHERE team_id = ? ORDER BY slug") team))])
    (row->feed conn r)))

(define (feed-get conn id team)
  (define r (query-maybe-row conn (string-append SELECT "WHERE id = ? AND team_id = ?") id team))
  (and r (row->feed conn r)))

;; The poll runs from a JOB, which carries a feed id and no team — and the row
;; itself is what says which team it belongs to. Team-scoped reads stay the API's
;; (`feed-get`), so this is deliberately not a route's entry point.
(define (feed-by-id conn id)
  (define r (query-maybe-row conn (string-append SELECT "WHERE id = ?") id))
  (and r (row->feed conn r)))

(define (active-member? conn team user)
  (and (string? user)
       (not (string=? user ""))
       (positive? (query-value conn
                   "SELECT COUNT(*) FROM memberships WHERE team_id = ? AND user_id = ? AND status = 'active'"
                   team user))))

;; -> id, or 'no-such-user / 'duplicate-slug
(define (feed-create! conn #:team team #:user user #:slug slug #:name name #:kind kind
                      #:url url #:auth auth #:auth-name auth-name #:secret secret
                      #:created-by created-by #:poll-seconds [poll-seconds #f])
  (cond
    [(not (active-member? conn team user)) 'no-such-user]
    [(query-maybe-value conn "SELECT id FROM feeds WHERE team_id = ? AND slug = ?" team slug)
     ;; The slug is a key prefix, so a second feed claiming it would write items
     ;; over the first one's. A converging create was considered and declined:
     ;; unlike an org (TEN-2f), re-posting a feed would silently adopt whatever
     ;; url and credential were already there.
     'duplicate-slug]
    [else
     (define id (new-id))
     (query-exec conn (string-append
                       "INSERT INTO feeds (id, team_id, user_id, slug, name, kind, url, secret, "
                       "auth, auth_name, active, created_by, created_epoch) "
                       "VALUES (?,?,?,?,?,?,?,?,?,?,1,?,?)")
                 id team user slug (or name sql-null) kind url
                 (if secret (seal-secret id secret) sql-null)
                 auth (or auth-name sql-null) (or created-by sql-null) (now))
     (when poll-seconds (feed-poll-set! conn id team poll-seconds))
     id]))

;; ---- FEED-21: the feed owns its schedule -------------------------------------------
;; A `poll_seconds` of #f REMOVES the schedule, so "stop polling" is one field and
;; not a second plane to visit. The kind and the payload are PLATFORM-SET: a
;; caller holding `feeds:manage` can schedule this feed's poll and nothing else,
;; which is why this does not widen `jobs:schedule` even though the two sit in
;; the same role today.
(define (feed-poll-set! conn id team secs)
  (define cur (query-maybe-value conn "SELECT schedule_id FROM feeds WHERE id = ?" id))
  (define sid (and cur (not (sql-null? cur)) cur))
  (define user (query-value conn "SELECT user_id FROM feeds WHERE id = ?" id))
  (define name (format "feed poll: ~a" (query-value conn "SELECT slug FROM feeds WHERE id = ?" id)))
  (cond
    [(not secs)
     (when sid (schedule-delete! conn sid team))
     (query-exec conn "UPDATE feeds SET schedule_id = NULL, poll_seconds = NULL WHERE id = ?" id)]
    [else
     ;; The schedule's own floor applies — the tick rides `set-reaper!` at 30
     ;; seconds, so anything shorter could not be honoured and a feed promising
     ;; it would be lying about its own cadence.
     (define every (max SCHEDULE-MIN-INTERVAL secs))
     (define live (and sid (schedule-get conn sid team)))
     (cond
       [live (schedule-update! conn sid team #:interval every #:paused? #f)]
       [else
        (define new-sid
          (schedule-create! conn #:team team #:user user #:kind POLL-KIND #:interval every
                            #:payload (hasheq 'feed_id id) #:name name #:created-by user))
        (query-exec conn "UPDATE feeds SET schedule_id = ? WHERE id = ?" new-sid id)])
     (query-exec conn "UPDATE feeds SET poll_seconds = ? WHERE id = ?" every id)]))

;; Every field is 'same-by-default, so a patch touches what it names and nothing
;; else. `#:secret` of `'same` keeps the stored credential, a string replaces it,
;; and #f CLEARS it — which is why `auth` and the secret are validated together.
(define (feed-update! conn id team #:user [user 'same] #:slug [slug 'same] #:name [name 'same]
                      #:kind [kind 'same] #:url [url 'same] #:auth [auth 'same]
                      #:auth-name [auth-name 'same] #:secret [secret 'same]
                      #:active? [active? 'same] #:poll-seconds [poll-seconds 'same])
  (define cur (query-maybe-row conn (string-append SELECT "WHERE id = ? AND team_id = ?") id team))
  (cond
    [(not cur) #f]
    [(and (string? user) (not (active-member? conn team user))) 'no-such-user]
    [(and (string? slug) (not (string=? slug (vector-ref cur 3)))
          (query-maybe-value conn "SELECT id FROM feeds WHERE team_id = ? AND slug = ?" team slug))
     'duplicate-slug]
    ;; THE CREDENTIAL IS ADDRESSED TO AN ORIGIN. A patch that moves the URL to
    ;; another scheme, host or port while keeping the sealed secret would aim
    ;; that secret at a host the operator chose AFTER sealing it — the one step
    ;; `feed-problem`'s "no credential in the url" rule exists to prevent, taken
    ;; a different way. Rotating the secret in the same patch is the answer, so
    ;; it is asked for rather than guessed: clearing it silently would turn a
    ;; typo fix into a 401 whose cause is invisible.
    ;; Column 6 is `url` and 16 is `secret` in `SELECT`; read through the row so
    ;; one statement cannot half-apply.
    [(and (string? url) (eq? secret 'same)
          (not (sql-null? (vector-ref cur 16)))
          (not (same-origin? url (vector-ref cur 6))))
     'secret-required]
    [else
     ;; One column per statement. Building one UPDATE with a conditional clause
     ;; list and a fixed argument list is how a clause and its parameter come
     ;; apart — five appearances of that bug are recorded in CLAUDE.md.
     (define (put! col v) (query-exec conn (format "UPDATE feeds SET ~a = ? WHERE id = ?" col) v id))
     (when (string? user) (put! "user_id" user))
     (when (string? slug) (put! "slug" slug))
     (unless (eq? name 'same) (put! "name" (or name sql-null)))
     (when (string? kind) (put! "kind" kind))
     (when (string? url) (put! "url" url))
     (when (string? auth) (put! "auth" auth))
     (unless (eq? auth-name 'same) (put! "auth_name" (or auth-name sql-null)))
     (unless (eq? secret 'same)
       (put! "secret" (if secret (seal-secret id secret) sql-null)))
     (when (boolean? active?) (put! "active" (if active? 1 0)))
     ;; The user may have changed in this same patch, and the schedule runs as
     ;; the feed's user — so the schedule is rewritten AFTER the columns, from
     ;; the row as it now stands, rather than from the arguments.
     (unless (eq? poll-seconds 'same) (feed-poll-set! conn id team poll-seconds))
     ;; Deactivating a feed must stop the timer, or `active: false` would mean
     ;; "not polled" everywhere except in the one place that polls it.
     (when (and (boolean? active?) (not active?))
       (let ([sid (query-maybe-value conn "SELECT schedule_id FROM feeds WHERE id = ?" id)])
         (when (and sid (not (sql-null? sid))) (schedule-update! conn sid team #:paused? #t))))
     (when (eq? active? #t)
       (let ([sid (query-maybe-value conn "SELECT schedule_id FROM feeds WHERE id = ?" id)])
         (when (and sid (not (sql-null? sid))) (schedule-update! conn sid team #:paused? #f))))
     (feed-get conn id team)]))

(define (feed-delete! conn id team)
  (and (query-maybe-value conn "SELECT id FROM feeds WHERE id = ? AND team_id = ?" id team)
       (begin
         ;; The schedule and the dedup rows go with it. The DOCUMENTS do not:
         ;; what a feed pulled is an ordinary repository object with its own
         ;; retention, grants and history, and deleting a configuration row must
         ;; not be a way to delete a team's documents.
         (let ([sid (query-maybe-value conn "SELECT schedule_id FROM feeds WHERE id = ?" id)])
           (when (and sid (not (sql-null? sid))) (schedule-delete! conn sid team)))
         (query-exec conn "DELETE FROM feed_items WHERE feed_id = ?" id)
         (query-exec conn "DELETE FROM feeds WHERE id = ?" id)
         #t)))

;; The one place a feed's credential is unsealed. A value that will not open
;; RAISES, as #19 requires — a feed quietly polling with no credential would be
;; answered 401 by the source and read as the source's fault.
(define (feed-secret-of conn id)
  (define r (query-maybe-row conn "SELECT id, secret FROM feeds WHERE id = ?" id))
  (and r (not (sql-null? (vector-ref r 1)))
       (unseal-secret (vector-ref r 0) (vector-ref r 1))))

;; ---- making the request ------------------------------------------------------------
;; The auth modes applied: -> (values url headers). Separated from the fetch so a
;; test can assert WHERE the credential went without a socket, and so slice 4's
;; poll composes the request the same way a probe does rather than a second way.
(define ACCEPT-JSON (list (cons "accept" "application/json")))

(define (feed-request conn feed-row)
  (feed-auth-apply conn feed-row (hash-ref feed-row 'url)))

;; WHICH header carries this feed's credential, so the fetcher can withhold it
;; from an origin the credential was not configured for. `bearer` writes
;; `authorization`, `header` writes the operator's own name (which no fixed list
;; would cover), and `query` carries it in the URL, where the redirect target
;; replaces the query and there is nothing to withhold.
(define (feed-credential-headers feed-row)
  (define auth (hash-ref feed-row 'auth))
  (cond
    [(string=? auth "bearer") (list "authorization")]
    [(string=? auth "header")
     (define nm (hash-ref feed-row 'auth_name #f))
     (if (and nm (not (eq? nm 'null)) (string? nm)) (list (string-downcase nm)) '())]
    [else '()]))

;; The same credential, applied to a url the ADAPTER composed — the first request
;; of a poll carries a cursor, and the second is a `Link: rel="next"` the source
;; chose. Separated from `feed-request` so pagination cannot quietly lose the
;; credential on page two, which is a failure that looks like the source
;; rate-limiting us.
(define (feed-auth-apply conn feed-row target)
  (define id (hash-ref feed-row 'id))
  (define auth (hash-ref feed-row 'auth))
  (define nm (hash-ref feed-row 'auth_name))
  (define secret (and (hash-ref feed-row 'has_secret) (feed-secret-of conn id)))
  (cond
    [(or (not secret) (string=? auth "none")) (values target ACCEPT-JSON)]
    [(string=? auth "bearer")
     (values target (cons (cons "authorization" (string-append "Bearer " secret)) ACCEPT-JSON))]
    [(string=? auth "header")
     (values target (cons (cons (string-downcase nm) secret) ACCEPT-JSON))]
    [else
     ;; `query`. APPENDED to whatever query the operator configured, so a feed
     ;; that needs both a project filter and a token works.
     (define u (string->url target))
     (values (url->string (make-url (url-scheme u) (url-user u) (url-host u) (url-port u)
                                    (url-path-absolute? u) (url-path u)
                                    (append (url-query u) (list (cons (string->symbol nm) secret)))
                                    (url-fragment u)))
             ACCEPT-JSON)]))

;; FEED-6's storage half. The message comes from the fetcher, which has already
;; redacted it; this records the status and that message and nothing else.
(define (record-fetch! conn id #:status [status #f] #:error [error #f])
  (query-exec conn (string-append "UPDATE feeds SET last_fetch_epoch = ?, last_status = ?, "
                                  "last_error = ? WHERE id = ?")
              (now) (or status sql-null) (or error sql-null) id)
  ;; `last_ok_epoch` moves only on a 2xx, so "it last worked at" survives a run
  ;; of failures — which is the number an operator actually wants when a feed
  ;; has been quietly failing for a week.
  (when (and status (>= status 200) (< status 300))
    (query-exec conn "UPDATE feeds SET last_ok_epoch = ? WHERE id = ?" (now) id)))

;; One fetch, nothing stored but the outcome. This is what makes the
;; configuration plane answerable BEFORE an adapter exists: an operator who has
;; typed a URL and a credential can find out whether the source answers, and a
;; wrong credential shows up as a 401 here rather than as silence on a timer.
(define (probe-feed! conn feed-row)
  (define id (hash-ref feed-row 'id))
  (define-values (u hs) (feed-request conn feed-row))
  (define outcome
    (with-handlers ([exn:fail:egress?
                     (lambda (e) (hasheq 'ok #f 'reason (format "~a" (exn:fail:egress-reason e))
                                         'error (exn-message e)))]
                    [(lambda (_) #t)
                     ;; Anything else — a TLS failure, a reset — may carry the
                     ;; host but not the query, because the query never reached
                     ;; it. Still passed through `safe-url`'s rule by not
                     ;; quoting the request at all.
                     (lambda (e) (hasheq 'ok #f 'reason "failed"
                                         'error (if (exn? e) (exn-message e) (format "~a" e))))])
      (define-values (status _hs body)
        (fetch u
               ;; #142's `'trusted`: public, PLUS the private networks the
               ;; OPERATOR allowed. The customer's feeds are "in our network",
               ;; and a tenant admin who could name any private URL would be
               ;; reading the instance's own cloud metadata — so the allowlist,
               ;; not the caller, decides which private networks exist.
               #:policy 'trusted
               #:timeout PROBE-TIMEOUT
               #:max-bytes PROBE-MAX-BYTES
               ;; the probe follows redirects like a poll does, so it withholds
               ;; the same header when the source moves it to another origin
               #:credential-headers (feed-credential-headers feed-row)
               #:headers hs))
      (define json?
        (and (with-handlers ([exn:fail? (lambda (_) #f)])
               (bytes->jsexpr body))
             #t))
      (hasheq 'ok (and (>= status 200) (< status 300) json?)
              'status status
              ;; The kind claims JSON, so "it answered 200 with HTML" is the
              ;; commonest misconfiguration and is worth naming on its own.
              'json json?
              'bytes (bytes-length body))))
  (record-fetch! conn id
                 #:status (hash-ref outcome 'status #f)
                 #:error (let ([m (hash-ref outcome 'error #f)])
                           (cond
                             [m m]
                             [(hash-ref outcome 'ok #f) #f]
                             [(not (hash-ref outcome 'json #f)) "the response was not JSON"]
                             [else "the source refused the request"])))
  outcome)

;; ---- the poll's own bookkeeping (FEED-18, FEED-19) ---------------------------------
;; One row per (feed, external-id), holding the hash of what this instance would
;; store. It OUTLIVES the document deliberately: deleting a pulled item is an
;; ordinary repository delete, and a poll that re-created it would make that
;; delete undoable except by deleting the feed.
(define (feed-item-ref conn feed-id external-id)
  (define r (query-maybe-row conn (string-append
                                   "SELECT id, content_hash, object_id, version_id, item_epoch "
                                   "FROM feed_items WHERE feed_id = ? AND external_id = ?")
                             feed-id external-id))
  (and r (hasheq 'id (vector-ref r 0) 'content_hash (vector-ref r 1)
                 'object_id (nz/false (vector-ref r 2)) 'version_id (nz/false (vector-ref r 3))
                 'item_epoch (nz/false (vector-ref r 4)))))

(define (feed-item-record! conn feed-id external-id #:hash hash #:object [object #f]
                           #:version [version #f] #:epoch [epoch #f])
  (define cur (feed-item-ref conn feed-id external-id))
  (cond
    [cur
     ;; Column by column. One UPDATE with a conditional clause list and a fixed
     ;; argument list is how a clause and its parameter come apart — six
     ;; appearances of that bug are recorded in CLAUDE.md, one of them in this
     ;; very module's sibling.
     (query-exec conn "UPDATE feed_items SET content_hash = ?, last_seen_epoch = ? WHERE id = ?"
                 hash (now) (hash-ref cur 'id))
     (when object (query-exec conn "UPDATE feed_items SET object_id = ? WHERE id = ?" object (hash-ref cur 'id)))
     (when version (query-exec conn "UPDATE feed_items SET version_id = ? WHERE id = ?" version (hash-ref cur 'id)))
     (when epoch (query-exec conn "UPDATE feed_items SET item_epoch = ? WHERE id = ?" epoch (hash-ref cur 'id)))
     (hash-ref cur 'id)]
    [else
     (define id (new-id))
     (query-exec conn (string-append
                       "INSERT INTO feed_items (id, feed_id, external_id, content_hash, object_id, "
                       "version_id, item_epoch, first_seen_epoch, last_seen_epoch) "
                       "VALUES (?,?,?,?,?,?,?,?,?)")
                 id feed-id external-id hash (or object sql-null) (or version sql-null)
                 (or epoch sql-null) (now) (now))
     id]))

;; Only for a feed whose dedup state an operator means to reset — not called by
;; the poll, which is the point: forgetting an item makes the next poll store it
;; again, and that is a decision somebody makes rather than a side effect.
(define (feed-item-forget! conn feed-id external-id)
  (query-exec conn "DELETE FROM feed_items WHERE feed_id = ? AND external_id = ?" feed-id external-id))

(define (feed-items-count conn feed-id)
  (query-value conn "SELECT COUNT(*) FROM feed_items WHERE feed_id = ?" feed-id))

;; FEED-19: the cursor is the newest item that actually LANDED, so a write the
;; storage quota refused cannot be skipped past. Stored as a string because the
;; adapter decides what the source wants it to look like; it is epoch seconds
;; here, which is the platform's own form.
(define (feed-cursor-set! conn id cursor)
  (query-exec conn "UPDATE feeds SET cursor = ? WHERE id = ?" (if cursor (format "~a" cursor) sql-null) id))

(define (feed-poll-recorded! conn id items)
  (query-exec conn "UPDATE feeds SET last_items = ? WHERE id = ?" items id))
