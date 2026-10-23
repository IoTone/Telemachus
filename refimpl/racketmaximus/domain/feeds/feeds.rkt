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
         (only-in "../net/fetch.rkt" fetch safe-url exn:fail:egress? exn:fail:egress-reason)
         "../db/nulls.rkt")

(provide FEED-KINDS FEED-AUTHS PROBE-TIMEOUT PROBE-MAX-BYTES
         feed-problem feed-create! feed-list feed-get feed-update! feed-delete!
         feed-secret-of feed-request probe-feed! record-fetch!)

;; #19's seam. A feed's token is a CREDENTIAL — it is replayed against somebody
;; else's API — so it belongs in `CREDENTIAL-SECRETS` beside the webhook signing
;; key, not in `CONTENT-SECRETS`, and `rewrap` rotates it whether or not the
;; operator turned content encryption on.
(define-sealed-column "feeds.secret" (seal-secret unseal-secret) (id) #:credential)

;; CLOSED vocabularies, as `WORKER-STATES`, `EXTRACT-REASONS` and
;; `RELEASE-REASONS` are. `http.json` is the one kind v1 commits to: fetch a URL
;; and read JSON. A second kind is an adapter decision, and the adapter registry
;; the fourth or fifth kind will want is not built on the strength of one.
(define FEED-KINDS '("http.json"))

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
    [(not (member kind FEED-KINDS))
     (format "unknown feed kind `~a` — this build pulls: ~a" kind (string-join FEED-KINDS ", "))]
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
    [else #f]))

;; ---- rows -------------------------------------------------------------------------
(define SELECT
  (string-append "SELECT id, team_id, user_id, slug, name, kind, url, auth, auth_name, active, "
                 "created_by, created_epoch, last_fetch_epoch, last_ok_epoch, last_status, "
                 "last_error, secret FROM feeds "))

(define (row->feed r)
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
          ;; Stated rather than implied: the row is configuration until slice 4
          ;; polls it, and a reader who cannot tell would conclude the feed is
          ;; broken. `probe` is what answers today.
          'polling #f))

(define (feed-list conn team)
  (for/list ([r (in-list (query-rows conn (string-append SELECT "WHERE team_id = ? ORDER BY slug") team))])
    (row->feed r)))

(define (feed-get conn id team)
  (define r (query-maybe-row conn (string-append SELECT "WHERE id = ? AND team_id = ?") id team))
  (and r (row->feed r)))

(define (active-member? conn team user)
  (and (string? user)
       (not (string=? user ""))
       (positive? (query-value conn
                   "SELECT COUNT(*) FROM memberships WHERE team_id = ? AND user_id = ? AND status = 'active'"
                   team user))))

;; -> id, or 'no-such-user / 'duplicate-slug
(define (feed-create! conn #:team team #:user user #:slug slug #:name name #:kind kind
                      #:url url #:auth auth #:auth-name auth-name #:secret secret
                      #:created-by created-by)
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
     id]))

;; Every field is 'same-by-default, so a patch touches what it names and nothing
;; else. `#:secret` of `'same` keeps the stored credential, a string replaces it,
;; and #f CLEARS it — which is why `auth` and the secret are validated together.
(define (feed-update! conn id team #:user [user 'same] #:slug [slug 'same] #:name [name 'same]
                      #:kind [kind 'same] #:url [url 'same] #:auth [auth 'same]
                      #:auth-name [auth-name 'same] #:secret [secret 'same]
                      #:active? [active? 'same])
  (define cur (query-maybe-row conn (string-append SELECT "WHERE id = ? AND team_id = ?") id team))
  (cond
    [(not cur) #f]
    [(and (string? user) (not (active-member? conn team user))) 'no-such-user]
    [(and (string? slug) (not (string=? slug (vector-ref cur 3)))
          (query-maybe-value conn "SELECT id FROM feeds WHERE team_id = ? AND slug = ?" team slug))
     'duplicate-slug]
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
     (feed-get conn id team)]))

(define (feed-delete! conn id team)
  (and (query-maybe-value conn "SELECT id FROM feeds WHERE id = ? AND team_id = ?" id team)
       (begin (query-exec conn "DELETE FROM feeds WHERE id = ?" id) #t)))

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
  (define id (hash-ref feed-row 'id))
  (define target (hash-ref feed-row 'url))
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
