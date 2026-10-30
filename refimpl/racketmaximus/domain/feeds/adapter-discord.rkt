#lang racket/base

;; domain/feeds/adapter-discord.rkt — `discord.messages` (#193, FEED‑30…32).
;;
;; #114's fourth named source: Discord, "for the servers we operate". The
;; endpoint is `GET /api/v10/channels/<id>/messages`, which takes `after` and
;; `limit` and needs `Authorization: Bot <token>` — so the feed is configured
;; with `auth: "header"`, header name `Authorization`, and the secret
;; `Bot <token>`. The adapter sends no credential of its own; `feed-auth-apply`
;; does that, as it does for every kind.
;;
;; FEED‑30 — THE CURSOR IS A SNOWFLAKE AND THE PLATFORM'S CURSOR IS AN EPOCH, so
;; the adapter converts. This is the first source whose window is not a time at
;; all: `after` takes a message id, and Discord's ids are snowflakes whose top 42
;; bits ARE a millisecond timestamp with a fixed epoch (2015-01-01). So an epoch
;; cursor converts exactly, which is what makes the conversion safe rather than
;; approximate — and it is the same shape as `github.issues` turning an epoch
;; into ISO‑8601, which is the whole reason `prepare` takes the cursor instead of
;; `poll.rkt` formatting one for every source.
;;
;; The conversion goes back a SECOND before the cursor, deliberately: the cursor
;; is the newest epoch that landed, `after` is exclusive, and a message in the
;; same second as the last one stored would otherwise never be asked for. Dedup
;; absorbs the overlap (FEED‑19's inclusive window, in the one form this source
;; allows).
;;
;; FEED‑31 — ORDER DOES NOT MATTER HERE AND THAT IS WORTH KNOWING. Discord
;; returns messages newest-first, which `github.issues` had to override with
;; `sort=updated&direction=asc` because its cursor filtered on a field the
;; default sort did not use. Here the cursor IS the id, every message carries
;; one, and `note-landed!` keeps the maximum — so a descending page advances the
;; cursor correctly on its first element. Nothing needs reordering.
;;
;; THE SHAPE IS FROM DISCORD'S PUBLISHED SCHEMA AND IS NOT VERIFIED AGAINST A
;; LIVE SOURCE in this build.

(require json racket/string racket/list
         "adapters.rkt")

(provide discord-messages-adapter install-discord-adapter!
         snowflake->epoch epoch->snowflake DISCORD-EPOCH-MS)

(define DISCORD-FIELDS
  (list (hasheq 'key "feed_author"  'label "Author")
        (hasheq 'key "feed_channel" 'label "Channel")
        (hasheq 'key "feed_kind"    'label "Message kind")))

(define LIMIT "100")

;; 2015-01-01T00:00:00Z in milliseconds — Discord's own constant. Written down
;; rather than computed, because it is a protocol constant and a derived one
;; would be a date this code chose.
(define DISCORD-EPOCH-MS 1420070400000)

(define (snowflake->epoch id)
  (define n (cond [(string? id) (string->number id)]
                  [(real? id) (inexact->exact (floor id))]
                  [else #f]))
  (and (exact-integer? n) (>= n 0)
       (quotient (+ (arithmetic-shift n -22) DISCORD-EPOCH-MS) 1000)))

(define (epoch->snowflake secs)
  (define ms (- (* (inexact->exact (floor secs)) 1000) DISCORD-EPOCH-MS))
  (and (>= ms 0) (arithmetic-shift ms 22)))

(define HEADERS (list (cons "accept" "application/json")
                      (cons "user-agent" "Telemachus-feeds")))

(define (dc-prepare feed cursor)
  (define n (and cursor (string->number (format "~a" cursor))))
  (define after (and (real? n) (epoch->snowflake (- n 1))))
  (values (query-set (hash-ref feed 'url)
                     (cons 'limit LIMIT)
                     (cons 'after (and after (number->string after))))
          HEADERS))

(define (author-name m)
  (define a (let ([v (hash-ref m 'author #f)]) (and (hash? v) v)))
  (cond
    [(not a) ""]
    [else
     (define gn (hash-ref a 'global_name #f))
     (define un (hash-ref a 'username #f))
     (cond [(and (string? gn) (> (string-length gn) 0)) gn]
           [(string? un) un]
           [else (format "~a" (hash-ref a 'id ""))])]))

(define (dc-parse body headers request-url)
  (define parsed
    (with-handlers ([exn:fail? (lambda (_)
                                 (raise-user-error
                                  'feed "discord.messages: the response did not parse as JSON"))])
      (bytes->jsexpr body)))
  ;; An OBJECT is Discord reporting something — `{"message": "401: Unauthorized",
  ;; "code": 0}` — so it is a refusal naming what the source said, never a guess
  ;; at where the messages are (FEED‑15).
  (unless (list? parsed)
    (raise-user-error
     'feed "discord.messages: expected an array of messages~a"
     (if (and (hash? parsed) (hash-ref parsed 'message #f))
         (format ", and the source said: ~a" (hash-ref parsed 'message))
         "")))
  (values
   (for/list ([m (in-list parsed)] #:when (hash? m))
     (define id (hash-ref m 'id #f))
     (unless (and (or (string? id) (real? id))
                  (snowflake->epoch id))
       (raise-user-error
        'feed (string-append "discord.messages: a message carries no readable `id` — a "
                             "snowflake is the identity AND the cursor, so there is nothing "
                             "to store it under and nothing to continue from")))
     (define sid (format "~a" id))
     (define chan (format "~a" (hash-ref m 'channel_id "")))
     (define ts (let ([v (hash-ref m 'timestamp #f)]) (and (string? v) v)))
     ;; The snowflake is the FALLBACK for the time, not the other way round:
     ;; `timestamp` is what the source says, and an edited message keeps its
     ;; original id. Either way the cursor advances on an id-derived instant,
     ;; which is what `after` compares.
     (define epoch (or (iso8601->epoch ts) (snowflake->epoch id)))
     (define content (let ([v (hash-ref m 'content #f)]) (if (string? v) v "")))
     (define who (author-name m))
     (feed-item
      ;; A snowflake is unique across every channel and guild by construction,
      ;; so unlike GitHub's issue number there is nothing to compose it with.
      (safe-id-part sid)
      (let ([head (first-line content)])
        (cond [(and (string=? who "") (string=? head "")) (format "message ~a" sid)]
              [(string=? head "") (format "~a in ~a" who chan)]
              [(string=? who "") head]
              [else (format "~a: ~a" who head)]))
      m
      epoch
      (hasheq 'feed_item_id sid
              ;; Composed, because the API carries no permalink. The guild id is
              ;; not in a message from this endpoint, so `@me` is the form that
              ;; resolves for a channel in any guild the reader can see.
              'feed_url (if (string=? chan "")
                            ""
                            (format "https://discord.com/channels/@me/~a/~a" chan sid))
              'feed_updated (or ts (epoch->iso8601 epoch))
              'feed_author who
              'feed_channel chan
              ;; Discord's numeric `type`: 0 is an ordinary message and the rest
              ;; are joins, pins, boosts and system notices. Kept rather than
              ;; filtered — the operator's channel is theirs to decide about —
              ;; and surfaced so a trigger can tell them apart without parsing
              ;; the payload, which is `feed_type`'s job on the GitHub adapter.
              'feed_kind (let ([t (hash-ref m 'type #f)])
                           (if (real? t)
                               (if (zero? (inexact->exact (floor t))) "message" "system")
                               "")))))
   ;; Discord has no `Link` header; the next page is the next poll's `after`,
   ;; which the cursor already is.
   #f))

(define (first-line s)
  (define t (regexp-replace* #px"\\s+" s " "))
  (define trimmed (string-trim t))
  (if (> (string-length trimmed) 120) (string-append (substring trimmed 0 120) "…") trimmed))

(define discord-messages-adapter
  (feed-adapter "discord.messages" "Discord messages" dc-prepare dc-parse DISCORD-FIELDS))

(define (install-discord-adapter!) (register-feed-adapter! discord-messages-adapter))
