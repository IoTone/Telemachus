#lang racket/base

;; test/feed-adapters-tests.rkt — the four adapters #114 named and #193 built
;; (`cve.nvd`, `kuma.status`, `discord.messages`, `alerts.alertmanager`).
;;
;;   raco test test/feed-adapters-tests.rkt
;;
;; NO DATABASE AND NO SOCKET, which is the whole point of FEED‑14's contract: an
;; adapter composes a request and reads a response, so every case here is a byte
;; string in and a list of `feed-item` out. The poll's own half — the cursor, the
;; dedup, the quota, the write — is `feed-poll-tests.rkt`'s and is not re-tested.
;;
;; WHAT THESE CASES CANNOT ESTABLISH, stated because it matters: the response
;; shapes are from each source's PUBLISHED schema and are not verified against a
;; live source in this build. A fixture written from the same documentation the
;; parser was written from agrees with the parser by construction. What they DO
;; establish is every rule the adapter decides for itself — the composed
;; identity, the cursor conversion, the refusals, and the field set — which is
;; where #193 said the decisions were.

(require rackunit racket/string racket/list racket/port json net/url
         "../domain/feeds/adapters.rkt"
         "../domain/feeds/adapter-cve.rkt"
         "../domain/feeds/adapter-kuma.rkt"
         "../domain/feeds/adapter-discord.rkt"
         "../domain/feeds/adapter-alerts.rkt")

(define (feed url) (hasheq 'url url 'slug "f" 'cursor #f))
(define (feed/cursor url c) (hasheq 'url url 'slug "f" 'cursor c))

(define (prep a f c) (let-values ([(u h) ((feed-adapter-prepare a) f c)]) (cons u h)))
(define (parse a body [headers '()] [url "https://example.test/x"])
  ((feed-adapter-parse a) (string->bytes/utf-8 body) headers url))
(define (items a body [headers '()] [url "https://example.test/x"])
  (let-values ([(its _n) (parse a body headers url)]) its))
(define (next a body [headers '()] [url "https://example.test/x"])
  (let-values ([(_i n) (parse a body headers url)]) n))

(define (q u k) (let ([p (assq k (url-query (string->url u)))]) (and p (cdr p))))

;; Every adapter's declared fields must be LAY‑4 keys, or the poll's
;; `repo-fields-declare!` refuses the lot and the feed stores nothing. Asserted
;; for all four at once, because the failure is identical and silent per adapter.
(test-case "0. every declared field is a legal LAY-4 key, prefixed, and within the cap"
  (for ([a (in-list (list cve-nvd-adapter kuma-status-adapter
                          discord-messages-adapter alertmanager-adapter))])
    (define fs (feed-adapter-fields a))
    (check-true (list? fs) (format "~a has a field list" (feed-adapter-kind a)))
    (for ([f (in-list fs)])
      (define k (hash-ref f 'key))
      (check-true (and (regexp-match? #px"^[a-z][a-z0-9_]{0,39}$" k) #t)
                  (format "~a: ~s is a legal attribute key" (feed-adapter-kind a) k))
      (check-true (string-prefix? k "feed_")
                  (format "~a: ~s stays out of the team's own namespace" (feed-adapter-kind a) k))
      (check-true (string? (hash-ref f 'label))))
    ;; the core four plus the adapter's own, against LAY-4's forty
    (check-true (<= (+ (length FEED-ITEM-FIELDS) (length fs)) 40))))

;; =============================================================================
;; cve.nvd

(define NVD-BODY
  (string-append
   "{\"resultsPerPage\":2,\"startIndex\":0,\"totalResults\":5,\"vulnerabilities\":["
   "{\"cve\":{\"id\":\"CVE-2026-1234\",\"published\":\"2026-03-01T10:00:00.000\","
   "\"lastModified\":\"2026-04-02T11:30:00.000\","
   "\"descriptions\":[{\"lang\":\"es\",\"value\":\"Una vulnerabilidad.\"},"
   "{\"lang\":\"en\",\"value\":\"A heap overflow in libwidget allows remote code execution. More text.\"}],"
   "\"metrics\":{\"cvssMetricV2\":[{\"baseSeverity\":\"medium\"}],"
   "\"cvssMetricV31\":[{\"cvssData\":{\"baseSeverity\":\"CRITICAL\"}}]},"
   "\"configurations\":[{\"nodes\":[{\"cpeMatch\":["
   "{\"criteria\":\"cpe:2.3:a:acme:libwidget:1.0:*:*:*:*:*:*:*\"},"
   "{\"criteria\":\"cpe:2.3:a:acme:libwidget:1.1:*:*:*:*:*:*:*\"},"
   "{\"criteria\":\"cpe:2.3:a:other:thing:*:*:*:*:*:*:*:*\"}]}]}]}},"
   "{\"cve\":{\"id\":\"CVE-2026-9999\",\"lastModified\":\"2026-04-03T09:00:00.000\","
   "\"descriptions\":[{\"lang\":\"en\",\"value\":\"Another one.\"}]}}"
   "]}"))

(test-case "1. cve.nvd: the CVE id IS the identity, and one advisory is one item"
  (define its (items cve-nvd-adapter NVD-BODY))
  (check-equal? (length its) 2 "FEED-24: one advisory, one item — not one per affected package")
  (define a (car its))
  (check-equal? (feed-item-external-id a) "cve-2026-1234"
                "globally unique by construction, with nothing to compose it against")
  (check-true (string-prefix? (feed-item-title a) "CVE-2026-1234 "))
  (check-true (string-contains? (feed-item-title a) "heap overflow")
              "the English description, so a stored advisory is findable by a person")
  (check-false (string-contains? (feed-item-title a) "More text")
               "the first sentence, not the whole description")
  (define attrs (feed-item-attributes a))
  (check-equal? (hash-ref attrs 'feed_cve) "CVE-2026-1234")
  (check-equal? (hash-ref attrs 'feed_url) "https://nvd.nist.gov/vuln/detail/CVE-2026-1234"
                "composed, because the API carries no human link")
  (check-equal? (hash-ref attrs 'feed_published) "2026-03-01T10:00:00.000"))

(test-case "2. cve.nvd: the severity is the WORST across every metric version"
  ;; An advisory may carry v2, v3.0 and v3.1 at once and any subset of them, so
  ;; asking for one by name reports "" for a perfectly scored advisory — and
  ;; taking the first in hash order would report whichever one Racket happened to
  ;; iterate first, which is not stable across processes.
  ;; The fixture carries a MEDIUM v2 score and a CRITICAL v3.1 one, and the keys
  ;; are walked in SORTED order — so `cvssMetricV2` is reached first and a "first
  ;; non-empty wins" implementation answers MEDIUM. Before the sort this case
  ;; could not tell the two apart: Racket's hash order happened to reach v3.1
  ;; first, so the control did not bite.
  (define a (car (items cve-nvd-adapter NVD-BODY)))
  (check-equal? (hash-ref (feed-item-attributes a) 'feed_severity) "CRITICAL"
                "CRITICAL from v3.1 beats medium from v2, whichever is seen first")
  (define b (cadr (items cve-nvd-adapter NVD-BODY)))
  (check-equal? (hash-ref (feed-item-attributes b) 'feed_severity) ""
                "and an advisory with no metrics says nothing rather than guessing"))

(test-case "3. cve.nvd: the affected packages are vendor/product, de-duplicated"
  (define a (car (items cve-nvd-adapter NVD-BODY)))
  (check-equal? (hash-ref (feed-item-attributes a) 'feed_packages) "acme/libwidget,other/thing"
                "two CPEs for the same product are one package; the version is in the payload")
  (define b (cadr (items cve-nvd-adapter NVD-BODY)))
  (check-equal? (hash-ref (feed-item-attributes b) 'feed_packages) ""))

(test-case "4. cve.nvd: FEED-25 — the window is bounded at 120 days and walks FORWARD"
  (define old (- (current-seconds) (* 400 86400)))
  (define u (car (prep cve-nvd-adapter (feed/cursor "https://nvd.test/cves" old) old)))
  (define from (iso8601->epoch (q u 'lastModStartDate)))
  (define to (iso8601->epoch (q u 'lastModEndDate)))
  (check-equal? from old "the start is the cursor — never clamped, which would skip a year silently")
  (check-true (and to (<= (- to from) (* NVD-WINDOW-DAYS 86400)))
              "and the end is at most 120 days on, because the source refuses a wider range")
  (check-true (and to (> to from)))
  ;; a cursor inside the window asks for exactly it
  (define recent (- (current-seconds) 3600))
  (define u2 (car (prep cve-nvd-adapter (feed/cursor "https://nvd.test/cves" recent) recent)))
  (check-true (<= (- (iso8601->epoch (q u2 'lastModEndDate)) recent) (* NVD-WINDOW-DAYS 86400)))
  ;; a FIRST poll sends no window: what "everything" means is the operator's URL
  (define u3 (car (prep cve-nvd-adapter (feed "https://nvd.test/cves?keywordSearch=racket") #f)))
  (check-false (q u3 'lastModStartDate))
  (check-false (q u3 'lastModEndDate))
  (check-equal? (q u3 'keywordSearch) "racket" "and the operator's own query survives"))

(test-case "5. cve.nvd: pagination is an OFFSET computed from the response's own counters"
  (check-equal? (q (next cve-nvd-adapter NVD-BODY '() "https://nvd.test/cves?startIndex=0") 'startIndex)
                "2" "startIndex + resultsPerPage, from the response rather than counted here")
  ;; the walk stops when the offset reaches the total
  (define last-page
    "{\"resultsPerPage\":2,\"startIndex\":4,\"totalResults\":5,\"vulnerabilities\":[]}")
  (check-false (next cve-nvd-adapter last-page '() "https://nvd.test/cves")
               "4 + 2 >= 5, so there is no next page")
  (check-false (next cve-nvd-adapter
                     "{\"resultsPerPage\":0,\"startIndex\":0,\"totalResults\":0,\"vulnerabilities\":[]}")
               "and an empty result is not an infinite walk"))

(test-case "6. cve.nvd: a response it cannot read is a named refusal, never a guess"
  (check-exn #px"did not parse as JSON" (lambda () (items cve-nvd-adapter "<html>nope</html>")))
  (check-exn #px"vulnerabilities" (lambda () (items cve-nvd-adapter "[]")))
  (check-exn #px"rate limit"
             (lambda () (items cve-nvd-adapter "{\"message\":\"rate limit exceeded\"}"))
             "and what the source said is quoted back, because that is the actionable half")
  (check-exn #px"no .id."
             (lambda () (items cve-nvd-adapter
                               "{\"resultsPerPage\":1,\"startIndex\":0,\"totalResults\":1,\"vulnerabilities\":[{\"cve\":{}}]}"))
             "an advisory with no id would be stored over another's key"))

;; =============================================================================
;; kuma.status

(define (beat time status [msg ""])
  (format "{\"time\":\"~a\",\"status\":~a,\"msg\":\"~a\"}" time status msg))

(define KUMA-BODY
  (string-append
   "{\"heartbeatList\":{\"7\":["
   (beat "2026-04-01 10:00:00" 1) "," (beat "2026-04-01 10:01:00" 1) ","
   (beat "2026-04-01 10:02:00" 0 "timeout") "," (beat "2026-04-01 10:05:00" 1)
   "],\"8\":[" (beat "2026-04-01 10:00:00" 1) "," (beat "2026-04-01 10:01:00" 1)
   "]},\"uptimeList\":{}}"))

(test-case "7. kuma.status: FEED-27 — an item is a TRANSITION, not a heartbeat"
  (define its (items kuma-status-adapter KUMA-BODY
                     '() "https://kuma.test/api/status-page/heartbeat/acme"))
  (check-equal? (length its) 2
                "six beats, two changes — one item per beat would be 14,400 documents a day")
  (define states (sort (for/list ([i (in-list its)])
                         (hash-ref (feed-item-attributes i) 'feed_status)) string<?))
  (check-equal? states '("down" "up"))
  ;; the monitor with no change contributes nothing
  (check-true (for/and ([i (in-list its)])
                (equal? (hash-ref (feed-item-attributes i) 'feed_monitor) "7"))))

(test-case "8. kuma.status: the FIRST beat in a list is never a transition"
  ;; Otherwise every monitor emits a spurious event on the first poll, and again
  ;; every time the window slides.
  (check-equal? (length (kuma-transitions (list (hasheq 'time "2026-04-01 10:00:00" 'status 0)))) 0)
  ;; …and the comparison is against the beat BEFORE it in time, not in list order
  (define shuffled (list (hasheq 'time "2026-04-01 10:02:00" 'status 0)
                         (hasheq 'time "2026-04-01 10:00:00" 'status 1)
                         (hasheq 'time "2026-04-01 10:01:00" 'status 1)))
  ;; `kuma-transitions` answers (epoch . beat) pairs, so the instant is computed
  ;; once for the identity, the title and the cursor.
  (define ts (kuma-transitions shuffled))
  (check-equal? (length ts) 1)
  (check-equal? (hash-ref (cdr (car ts)) 'status) 0 "the down beat, however the list arrived")
  (check-equal? (car (car ts)) (iso8601->epoch "2026-04-01 10:02:00")))

(test-case "9. kuma.status: FEED-28 — the identity carries the INSTANT"
  (define its (items kuma-status-adapter KUMA-BODY
                     '() "https://kuma.test/api/status-page/heartbeat/acme"))
  (for ([i (in-list its)])
    (check-true (regexp-match? #px"^7-[0-9]+$" (feed-item-external-id i))
                (format "~a is <monitor>-<instant>" (feed-item-external-id i))))
  (check-equal? (length (remove-duplicates (for/list ([i (in-list its)]) (feed-item-external-id i))))
                2 "two 'down' events an hour apart are two items, which is why the instant is in the id")
  ;; the status page a person reads, derived from the API URL rather than configured twice
  (check-equal? (hash-ref (feed-item-attributes (car its)) 'feed_url)
                "https://kuma.test/status/acme")
  ;; …and left empty rather than guessed when the path is not the documented one
  (check-equal? (hash-ref (feed-item-attributes
                           (car (items kuma-status-adapter KUMA-BODY '() "https://kuma.test/other")))
                          'feed_url)
                ""))

(test-case "10. kuma.status: the monitor id rides inside the payload too"
  ;; The response keys the lists by monitor, so a heartbeat on its own does not
  ;; say which monitor it belongs to — a stored document that cannot name its own
  ;; subject is one nobody can read.
  (define i (car (items kuma-status-adapter KUMA-BODY
                        '() "https://kuma.test/api/status-page/heartbeat/acme")))
  (check-equal? (hash-ref (feed-item-payload i) 'monitor) "7")
  (check-true (hash? (hash-ref (feed-item-payload i) 'heartbeat)))
  (check-true (string-contains? (feed-item-title i) "monitor 7")))

(test-case "11. kuma.status: the refusals"
  (check-exn #px"did not parse as JSON" (lambda () (items kuma-status-adapter "nope")))
  (check-exn #px"heartbeatList" (lambda () (items kuma-status-adapter "{\"foo\":1}")))
  ;; A BEAT WITH NO READABLE TIME IS DROPPED, NOT REFUSED, and the first version
  ;; of this case expected a refusal — which never fired, because an undated beat
  ;; sorted to epoch 0 and became the "first" beat, discarded for the wrong
  ;; reason. It cannot be ORDERED, and a transition is entirely about order.
  (define undated
    (string-append "{\"heartbeatList\":{\"1\":["
                   "{\"time\":\"2026-04-01 10:00:00\",\"status\":1},"
                   "{\"time\":\"never\",\"status\":0},"
                   "{\"time\":\"2026-04-01 10:02:00\",\"status\":0}"
                   "]}}"))
  (define its (items kuma-status-adapter undated '() "https://kuma.test/api/status-page/heartbeat/a"))
  (check-equal? (length its) 1 "the undated beat is dropped; the outer two still compare")
  (check-equal? (hash-ref (feed-item-attributes (car its)) 'feed_status) "down")
  (check-equal? (length (kuma-transitions (list (hasheq 'time "never" 'status 0)
                                                (hasheq 'time "also never" 'status 1))))
                0 "a list with nothing datable in it yields nothing rather than raising")
  (check-false (next kuma-status-adapter KUMA-BODY) "one response is the whole window"))

;; =============================================================================
;; discord.messages

(define DISCORD-BODY
  (string-append
   "[{\"id\":\"1234567890123456789\",\"channel_id\":\"999\",\"type\":0,"
   "\"timestamp\":\"2026-04-02T08:00:00.000000+00:00\","
   "\"content\":\"the   deploy   finished\",\"author\":{\"id\":\"7\",\"username\":\"sven\","
   "\"global_name\":\"Sven O\"}},"
   "{\"id\":\"1234567890123456790\",\"channel_id\":\"999\",\"type\":7,"
   "\"timestamp\":\"2026-04-02T08:01:00.000000+00:00\","
   "\"content\":\"\",\"author\":{\"id\":\"8\",\"username\":\"bot\"}}]"))

(test-case "12. discord.messages: the snowflake IS the identity and the time"
  (define its (items discord-messages-adapter DISCORD-BODY))
  (check-equal? (length its) 2)
  (define a (car its))
  (check-equal? (feed-item-external-id a) "1234567890123456789"
                "unique across every channel and guild by construction")
  (check-equal? (feed-item-title a) "Sven O: the deploy finished"
                "the global name where there is one, and whitespace collapsed")
  (define attrs (feed-item-attributes a))
  (check-equal? (hash-ref attrs 'feed_author) "Sven O")
  (check-equal? (hash-ref attrs 'feed_channel) "999")
  (check-equal? (hash-ref attrs 'feed_kind) "message")
  (check-equal? (hash-ref (feed-item-attributes (cadr its)) 'feed_kind) "system"
                "a join or a pin is kept and MARKED, as the GitHub adapter keeps a pull request")
  (check-equal? (hash-ref (feed-item-attributes (cadr its)) 'feed_author) "bot"
                "…and falls back to the username when there is no global name"))

(test-case "13. discord.messages: FEED-30 — the epoch cursor converts to a snowflake exactly"
  ;; The top 42 bits of a snowflake ARE a millisecond timestamp with a fixed
  ;; epoch, so this is a conversion rather than an approximation.
  (check-equal? (snowflake->epoch 0) (quotient DISCORD-EPOCH-MS 1000)
                "snowflake zero is Discord's own epoch")
  (define t 1775116800)                                  ; some instant after 2015
  (check-equal? (snowflake->epoch (epoch->snowflake t)) t "round trip, to the second")
  (check-false (epoch->snowflake 100) "an instant before Discord existed has no snowflake")
  (check-false (snowflake->epoch "not a number"))
  ;; and `after` is EXCLUSIVE, so the request goes back a second — the inclusive
  ;; window of FEED-19 in the one form this source allows
  (define u (car (prep discord-messages-adapter
                       (feed/cursor "https://discord.test/channels/9/messages" t) t)))
  (check-equal? (q u 'after) (number->string (epoch->snowflake (- t 1))))
  (check-equal? (q u 'limit) "100")
  ;; a first poll asks for no window
  (check-false (q (car (prep discord-messages-adapter
                             (feed "https://discord.test/channels/9/messages") #f)) 'after)))

(test-case "14. discord.messages: the refusals, and the object a 401 sends"
  (check-exn #px"did not parse as JSON" (lambda () (items discord-messages-adapter "nope")))
  (check-exn #px"401: Unauthorized"
             (lambda () (items discord-messages-adapter
                               "{\"message\":\"401: Unauthorized\",\"code\":0}"))
             "Discord reports in an object; the refusal quotes what it said")
  (check-exn #px"readable .id."
             (lambda () (items discord-messages-adapter "[{\"channel_id\":\"9\"}]"))
             "a snowflake is the identity AND the cursor")
  (check-false (next discord-messages-adapter DISCORD-BODY)
               "the next page is the next poll's `after`, which the cursor already is"))

;; =============================================================================
;; alerts.alertmanager

(define AM-BODY
  (string-append
   "[{\"fingerprint\":\"abc123\",\"startsAt\":\"2026-04-02T07:00:00.000Z\","
   "\"updatedAt\":\"2026-04-02T07:30:00.000Z\","
   "\"status\":{\"state\":\"active\"},\"generatorURL\":\"https://prom.test/graph?g0=x\","
   "\"labels\":{\"alertname\":\"DiskFull\",\"instance\":\"db-1\",\"severity\":\"critical\"},"
   "\"annotations\":{\"summary\":\"only 2% left\"}},"
   "{\"fingerprint\":\"def456\",\"startsAt\":\"2026-04-02T07:10:00.000Z\","
   "\"status\":{\"state\":\"suppressed\"},\"labels\":{\"alertname\":\"Flapping\"},"
   "\"annotations\":{}}]"))

(test-case "15. alerts.alertmanager: FEED-35 — the identity is the label set AND the firing"
  (define its (items alertmanager-adapter AM-BODY))
  (check-equal? (length its) 2)
  (define a (car its))
  (check-equal? (feed-item-external-id a)
                (format "abc123-~a" (iso8601->epoch "2026-04-02T07:00:00.000Z"))
                "a fingerprint alone would store next month's incident over this one")
  (check-equal? (feed-item-title a) "DiskFull: only 2% left")
  (check-equal? (feed-item-title (cadr its)) "Flapping"
                "…and an alert with no summary and no instance is just its name")
  (define attrs (feed-item-attributes a))
  (check-equal? (hash-ref attrs 'feed_alertname) "DiskFull")
  (check-equal? (hash-ref attrs 'feed_severity) "critical")
  (check-equal? (hash-ref attrs 'feed_instance) "db-1")
  (check-equal? (hash-ref attrs 'feed_state) "active")
  (check-equal? (hash-ref attrs 'feed_url) "https://prom.test/graph?g0=x"
                "the rule's own link into Prometheus, which is where somebody goes to look")
  (check-equal? (hash-ref (feed-item-attributes (cadr its)) 'feed_url) ""
                "empty rather than guessed when the alert carries none"))

(test-case "16. alerts.alertmanager: `updatedAt` is what moves, and `startsAt` is the fallback"
  ;; An alert still firing an hour later is the SAME incident with a newer
  ;; heartbeat, so the document updates and the cursor advances; an alert with no
  ;; updatedAt is still stored once.
  (define its (items alertmanager-adapter AM-BODY))
  (check-equal? (feed-item-epoch (car its)) (iso8601->epoch "2026-04-02T07:30:00.000Z"))
  (check-equal? (feed-item-epoch (cadr its)) (iso8601->epoch "2026-04-02T07:10:00.000Z")))

(test-case "17. alerts.alertmanager: the poll asks only for what is actually firing"
  ;; The DEFAULT includes silenced and inhibited alerts, so a feed on the bare
  ;; endpoint would pull in exactly the ones its operator has said they do not
  ;; want to hear about.
  (define u (car (prep alertmanager-adapter (feed "https://am.test/api/v2/alerts") #f)))
  (check-equal? (q u 'active) "true")
  (check-equal? (q u 'silenced) "false")
  (check-equal? (q u 'inhibited) "false")
  ;; FEED-34: no cursor goes to the source, because it has no window
  (define u2 (car (prep alertmanager-adapter
                        (feed/cursor "https://am.test/api/v2/alerts" 1775116800) 1775116800)))
  (check-equal? u u2 "the cursor changes nothing about the request")
  (check-false (next alertmanager-adapter AM-BODY) "and there is nothing to page through"))

(test-case "18. alerts.alertmanager: the refusals"
  (check-exn #px"did not parse as JSON" (lambda () (items alertmanager-adapter "nope")))
  (check-exn #px"array of alerts" (lambda () (items alertmanager-adapter "{\"status\":\"error\"}")))
  (check-exn #px"fingerprint"
             (lambda () (items alertmanager-adapter "[{\"startsAt\":\"2026-04-02T07:00:00Z\"}]")))
  (check-exn #px"startsAt"
             (lambda () (items alertmanager-adapter "[{\"fingerprint\":\"x\"}]"))))

;; =============================================================================

(test-case "19. the four kinds are distinct, unprefixed and labelled"
  ;; A platform adapter owns an unprefixed name; a plugin's would be
  ;; `x.<id>.<name>`. The LABEL is what the feed plane shows an operator, so an
  ;; empty one is a kind nobody can choose on purpose.
  (define as (list cve-nvd-adapter kuma-status-adapter
                   discord-messages-adapter alertmanager-adapter))
  (define kinds (for/list ([a (in-list as)]) (feed-adapter-kind a)))
  (check-equal? (length (remove-duplicates kinds)) 4)
  (check-equal? kinds '("cve.nvd" "kuma.status" "discord.messages" "alerts.alertmanager"))
  (for ([a (in-list as)])
    (check-false (string-prefix? (feed-adapter-kind a) "x.")
                 "the platform owns the unprefixed namespace")
    (check-true (> (string-length (feed-adapter-label a)) 0))))
