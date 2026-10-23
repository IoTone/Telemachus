#lang racket/base

;; domain/feeds/adapters.rkt — the feed ADAPTER registry (#114 slice 4, FEED-14).
;;
;; A feed's kind decides how a response becomes items. The owner's answer to
;; #114's blocking question named SIX sources — a GitHub issue tracker, CERT
;; advisories against pinned BOM dependencies, Kuma uptime alerts, Discord,
;; Matrix and OTel — and five of the six are "JSON over HTTP with a different
;; item shape". That is the evidence a registry needs and one source was not:
;; a `cond` over six shapes would sit inside the loop that spends the team's
;; quota and writes its documents, which is #110 r1's shape exactly.
;;
;; So an adapter is a REGISTRY ENTRY with LAY-7's ownership rule, and a plugin
;; may add one under `x.<plugin-id>.<name>` just as it adds a job kind or an
;; extractor. `FEED-KINDS` is DERIVED from what is registered (the `available`
;; locales rule), so a kind this build cannot pull cannot be configured.
;;
;; THE ADAPTER NEVER FETCHES AND NEVER WRITES. It composes a request and reads a
;; response, and that is the whole contract — which is what makes every adapter
;; testable with a byte string and no socket, and what keeps the egress policy,
;; the quota and the repository writes in one place (poll.rkt).

(require json racket/string racket/list racket/date net/url
         (only-in "../sched/scheduler.rkt" current-plugin plugin-kind-prefix))

(provide (struct-out feed-adapter) (struct-out feed-item)
         register-feed-adapter! unregister-feed-adapter!
         feed-adapter-for feed-adapter-kinds registered-feed-adapters feed-adapters-of-plugin
         canonical-json iso8601->epoch epoch->iso8601
         FEED-ITEM-FIELDS safe-id-part link-rel)

;; `prepare` : (feed-row cursor-or-#f) -> (values url extra-headers)
;;   the FIRST request of a poll. The cursor is this instance's own string (see
;;   FEED-19); the adapter decides what the source wants it to look like.
;; `parse`   : (body-bytes response-headers request-url) -> (values items next-url)
;;   `items` is a list of `feed-item`; `next-url` continues the SAME poll.
;;   A body it cannot read is a `raise-user-error`, never a guess (FEED-15).
;; `fields`  : the LAY-4 field definitions this adapter writes beyond the core
;;   set, so the poll can declare them on the team (FEED-20).
(struct feed-adapter (kind label prepare parse fields) #:transparent)

;; `payload` is the jsexpr; poll.rkt canonicalizes and hashes it. `epoch` is the
;; source's own notion of when the item last changed, or #f.
(struct feed-item (external-id title payload epoch attributes) #:transparent)

;; The attribute keys EVERY adapter's items carry, declared once here so a
;; consumer (slice 5's queue) can rely on them whatever the source is. LAY-4's
;; key vocabulary is `^[a-z][a-z0-9_]{0,39}$`, and the `feed_` prefix is what
;; keeps an adapter out of the team's own namespace.
(define FEED-ITEM-FIELDS
  (list (hasheq 'key "feed_slug"    'label "Feed")
        (hasheq 'key "feed_item_id" 'label "Item id")
        (hasheq 'key "feed_url"     'label "Item link")
        (hasheq 'key "feed_updated" 'label "Item updated")))

(define *adapters* (make-hash))   ;; kind -> (cons owner-plugin-id adapter)

(define (register-feed-adapter! a)
  (unless (feed-adapter? a) (error 'register-feed-adapter! "expected a feed-adapter"))
  (define kind (feed-adapter-kind a))
  (define pid (current-plugin))
  (when pid
    ;; The platform owns the unprefixed namespace, as it does for job kinds and
    ;; plugin routes: a plugin cannot claim `github.issues` and answer for it.
    (define want (plugin-kind-prefix pid))
    (unless (and (string? kind) (string-prefix? kind want) (> (string-length kind) (string-length want)))
      (error 'register-feed-adapter! "plugin ~a: a feed kind must be named ~a<name> (got ~s)" pid want kind)))
  (define owner (let ([e (hash-ref *adapters* kind #f)]) (and e (car e))))
  ;; Re-registering your OWN is fine — the loader may run twice in one process,
  ;; and a reload must not fail the plugin. Somebody else's is not.
  (when (and (hash-ref *adapters* kind #f) (not (equal? owner pid)))
    (error 'register-feed-adapter! "feed kind ~s is already claimed by ~a" kind (or owner "the platform")))
  (hash-set! *adapters* kind (cons pid a))
  kind)

(define (unregister-feed-adapter! kind) (hash-remove! *adapters* kind))

(define (feed-adapter-for kind)
  (define e (hash-ref *adapters* kind #f))
  (and e (cdr e)))

(define (feed-adapter-kinds) (sort (hash-keys *adapters*) string<?))

;; kind -> owner plugin id (#f for one registered outside a plugin), for
;; `GET /api/plugins` and the generated reference.
(define (registered-feed-adapters)
  (for/list ([k (in-list (feed-adapter-kinds))]) (cons k (car (hash-ref *adapters* k)))))

(define (feed-adapters-of-plugin id)
  (sort (for/list ([(k e) (in-hash *adapters*)] #:when (equal? (car e) id)) k) string<?))

;; ---- the canonical payload (FEED-18) ------------------------------------------------
;; THE STORED BYTES ARE WHAT THE HASH COVERS, so they must not depend on this
;; process. `hasheq` iteration order is not stable across processes — the trap
;; `json-out` sorts for, LAY-11 keeps an ordered list for, and JUDGE-13 refuses
;; to re-serialize over — and here it would be worse than cosmetic: an unstable
;; rendering means every poll sees a different hash, writes a new version of
;; every item, and charges the team's storage quota for it. So keys are sorted
;; recursively. Nothing is dropped, added or reshaped: "verbatim" means the
;; item's own fields and values, in an order chosen by the alphabet rather than
;; by a hash function.
;;
;; RACKET'S OWN `write-json` HAPPENS TO SORT KEYS TODAY (checked, 9.3), which is
;; why the positive control for this — swapping in `jsexpr->string` — does NOT
;; fail the test. That is the reason to state the guarantee here rather than
;; inherit it: everywhere else in the tree an unstable key order is a cosmetic
;; diff or a cry-wolf drift gate, and here it would silently re-version every
;; item in every feed for ever. The test pins the SORTED form as a literal, so a
;; writer that stopped sorting would be caught; what it cannot catch is this
;; module quietly starting to rely on the writer again.
(define (canonical-json v)
  (define out (open-output-string))
  (let write-it ([v v])
    (cond
      [(hash? v)
       (write-string "{" out)
       (for ([k (in-list (sort (hash-keys v) symbol<?))] [i (in-naturals)])
         (unless (zero? i) (write-string "," out))
         (write-string (jsexpr->string (symbol->string k)) out)
         (write-string ":" out)
         (write-it (hash-ref v k)))
       (write-string "}" out)]
      [(list? v)
       (write-string "[" out)
       (for ([x (in-list v)] [i (in-naturals)])
         (unless (zero? i) (write-string "," out))
         (write-it x))
       (write-string "]" out)]
      [else (write-string (jsexpr->string v) out)]))
  (get-output-string out))

;; ---- time ---------------------------------------------------------------------------
;; The sources speak ISO-8601 in UTC (`2026-10-23T08:42:26Z`). Stored epochs,
;; always, for the reason every migration since 0038 carries: a TEXT timestamp's
;; format differs by dialect. A value this cannot read answers #f rather than
;; guessing a time — a wrong cursor skips items.
(define (iso8601->epoch s)
  (and (string? s)
       (let ([m (regexp-match #px"^([0-9]{4})-([0-9]{2})-([0-9]{2})[Tt ]([0-9]{2}):([0-9]{2}):([0-9]{2})" s)])
         (and m
              (with-handlers ([exn:fail? (lambda (_) #f)])
                (define (n i) (string->number (list-ref m i)))
                (find-seconds (n 6) (n 5) (n 4) (n 3) (n 2) (n 1) #f))))))

(define (epoch->iso8601 secs)
  (define d (seconds->date secs #f))
  (define (p2 n) (if (< n 10) (format "0~a" n) (number->string n)))
  (format "~a-~a-~aT~a:~a:~aZ" (date-year d) (p2 (date-month d)) (p2 (date-day d))
          (p2 (date-hour d)) (p2 (date-minute d)) (p2 (date-second d))))

;; ---- helpers every adapter wants ----------------------------------------------------
;; An external id becomes part of a repository KEY, and the pieces it is composed
;; from (a repository name, a project slug) are somebody else's strings. So they
;; are reduced to the key vocabulary rather than trusted — blobs.rkt's rule for a
;; digest, and the reason `..` is the whole point.
(define (safe-id-part s)
  (define t (string-downcase (format "~a" s)))
  (define cleaned (regexp-replace* #px"[^a-z0-9._-]+" t "-"))
  ;; Dots are kept INSIDE (a source's `v1.2` is a legitimate id) and trimmed at
  ;; the EDGES, because `valid-key?` refuses a segment that is exactly `.` or
  ;; `..` and a leading dot is how that happens — `../../etc` arriving as a
  ;; repository name is the case this is written for.
  (define collapsed (regexp-replace* #px"-{2,}" cleaned "-"))
  (define trimmed (regexp-replace* #px"^[-.]+|[-.]+$" collapsed ""))
  (if (string=? trimmed "") "x" (substring trimmed 0 (min 64 (string-length trimmed)))))

;; `Link: <https://…?page=2>; rel="next", <…>; rel="last"` — RFC 8288, and how
;; every one of the named JSON sources paginates. Returns the URL for a rel, or
;; #f. Parsed rather than regexped whole, because a `rel` may be unquoted.
(define (link-rel headers rel)
  (define h (let ([p (assoc "link" headers)]) (and p (cdr p))))
  (and h
       (for/or ([part (in-list (string-split h ","))])
         (define m (regexp-match #px"^\\s*<([^>]+)>\\s*;(.*)$" part))
         (and m
              (regexp-match? (pregexp (format "rel\\s*=\\s*\"?~a\"?" (regexp-quote rel))) (caddr m))
              (cadr m)))))
