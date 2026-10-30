#lang racket/base

;; domain/feeds/adapter-alerts.rkt — `alerts.alertmanager` (#193, FEED‑33…36).
;;
;; #114's sixth named source is "OTel server notifications", and **OTel itself
;; cannot be an adapter** (FEED‑33). OTLP is a PUSH protocol: a collector or an
;; SDK opens a connection and POSTs spans, metrics and logs at this instance.
;; A feed POLLS. So asking for an OTel adapter here is the same category error
;; #114 already found with Matrix — "a protocol rather than a shape", which
;; shipped as #133 in the NOTIFYING direction instead. The honest shapes for
;; OTLP arriving are an ingest endpoint and a job kind, which is its own issue
;; and is not this one.
;;
;; What an operator running that stack actually HAS that is pollable is the thing
;; that fires when something is wrong: **Prometheus Alertmanager**,
;; `GET /api/v2/alerts`. So that is what this adapter reads, and the substitution
;; is recorded rather than quietly made.
;;
;; FEED‑34 — THERE IS NO CURSOR, AND THAT IS THE SOURCE'S SHAPE. Alertmanager
;; answers "what is firing now"; it has no modification window, no `since` and
;; no pagination. Every poll therefore sees the whole current set, which is
;; bounded by how much is broken rather than by how long the feed has existed.
;; The cursor is stored and ignored — `feed-cursor-set!` still advances it, so
;; an operator reading the feed can see the poll is working, and nothing depends
;; on it.
;;
;; FEED‑35 — THE IDENTITY IS `<fingerprint>-<startsAt>`, which is Kuma's lesson
;; a second time. A fingerprint identifies the LABEL SET, so the same alert
;; firing again next month carries the same fingerprint and is a different
;; incident; keying on the fingerprint alone would store the second occurrence
;; over the first and the dedup hash would then report a document that changes
;; every time anything flaps. Keying on the instant as well makes each firing its
;; own immutable item — and an alert whose annotations change WHILE it is firing
;; is one document that updates, which is correct.
;;
;; THE SHAPE IS FROM ALERTMANAGER'S PUBLISHED v2 SCHEMA AND IS NOT VERIFIED
;; AGAINST A LIVE SOURCE in this build.

(require json racket/string racket/list
         "adapters.rkt")

(provide alertmanager-adapter install-alerts-adapter!)

(define ALERT-FIELDS
  (list (hasheq 'key "feed_alertname" 'label "Alert")
        (hasheq 'key "feed_state"     'label "State")
        (hasheq 'key "feed_severity"  'label "Severity")
        (hasheq 'key "feed_instance"  'label "Instance")))

(define HEADERS (list (cons "accept" "application/json")
                      (cons "user-agent" "Telemachus-feeds")))

;; `active=true&silenced=false&inhibited=false` is what "notify me about this"
;; means: a silenced alert is one somebody has already acknowledged, and an
;; inhibited one is suppressed by a rule the operator wrote. Set here rather than
;; left to the URL because the DEFAULT includes all three — so a feed configured
;; with the bare endpoint would pull in exactly the alerts its operator has said
;; they do not want to hear about. `query-set` replaces, so an operator who
;; really wants the silenced ones cannot have them back by editing the URL; that
;; is deliberate, and the remedy is a second feed on a kind that does not filter.
(define (am-prepare feed cursor)
  (values (query-set (hash-ref feed 'url)
                     (cons 'active "true")
                     (cons 'silenced "false")
                     (cons 'inhibited "false"))
          HEADERS))

(define (label a k [dflt ""])
  (define ls (let ([v (hash-ref a 'labels #f)]) (and (hash? v) v)))
  (define v (and ls (hash-ref ls k #f)))
  (if (string? v) v dflt))

(define (annotation a k)
  (define as (let ([v (hash-ref a 'annotations #f)]) (and (hash? v) v)))
  (define v (and as (hash-ref as k #f)))
  (if (string? v) v ""))

(define (am-parse body headers request-url)
  (define parsed
    (with-handlers ([exn:fail? (lambda (_)
                                 (raise-user-error
                                  'feed "alerts.alertmanager: the response did not parse as JSON"))])
      (bytes->jsexpr body)))
  (unless (list? parsed)
    (raise-user-error
     'feed (string-append "alerts.alertmanager: expected an array of alerts — the URL should be "
                          "Alertmanager's /api/v2/alerts")))
  (values
   (for/list ([a (in-list parsed)] #:when (hash? a))
     (define fp (let ([v (hash-ref a 'fingerprint #f)]) (and (string? v) (> (string-length v) 0) v)))
     (define starts (let ([v (hash-ref a 'startsAt #f)]) (and (string? v) v)))
     (define start-epoch (and starts (iso8601->epoch starts)))
     (unless (and fp start-epoch)
       (raise-user-error
        'feed (string-append "alerts.alertmanager: an alert carries no `fingerprint` and "
                             "readable `startsAt` — the identity is the label set AND the "
                             "firing, so without both a new incident would be stored over an "
                             "old one")))
     (define name (label a 'alertname))
     (define inst (label a 'instance))
     (define sev (label a 'severity))
     (define state (let* ([s (hash-ref a 'status #f)]
                          [v (and (hash? s) (hash-ref s 'state #f))])
                     (if (string? v) v "")))
     ;; `updatedAt` is when Alertmanager last heard about it, which is what
     ;; should move the cursor and the document: an alert still firing an hour
     ;; later is the same incident with a newer heartbeat. Falls back to the
     ;; firing instant, so an alert without it is still stored once.
     (define updated (let ([v (hash-ref a 'updatedAt #f)]) (and (string? v) v)))
     (feed-item
      (format "~a-~a" (safe-id-part fp) start-epoch)
      (let ([summary (annotation a 'summary)])
        (cond
          [(not (string=? summary "")) (format "~a: ~a" (if (string=? name "") "alert" name) summary)]
          [(and (string=? name "") (string=? inst "")) (format "alert ~a" fp)]
          [(string=? inst "") name]
          [else (format "~a on ~a" name inst)]))
      a
      (or (and updated (iso8601->epoch updated)) start-epoch)
      (hasheq 'feed_item_id (format "~a-~a" fp start-epoch)
              ;; `generatorURL` is the rule's own link into Prometheus, which is
              ;; where somebody goes to see the graph. Empty rather than guessed
              ;; when the alert does not carry one.
              'feed_url (let ([v (hash-ref a 'generatorURL #f)]) (if (string? v) v ""))
              'feed_updated (or updated starts "")
              'feed_alertname name
              'feed_state state
              'feed_severity sev
              'feed_instance inst)))
   ;; No pagination: see FEED‑34.
   #f))

(define alertmanager-adapter
  (feed-adapter "alerts.alertmanager" "Prometheus Alertmanager" am-prepare am-parse ALERT-FIELDS))

(define (install-alerts-adapter!) (register-feed-adapter! alertmanager-adapter))
