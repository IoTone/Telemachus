#lang racket/base

;; domain/feeds/adapter-cve.rkt — `cve.nvd` (#193, decisions FEED‑23…26).
;;
;; #114's second named source: "CERT advisories against the pinned BOM
;; dependencies our own source scanning finds", and #193 calls it the most
;; valuable of the four with the most to decide. The source is the **NVD CVE API
;; 2.0** (`https://services.nvd.nist.gov/rest/json/cves/2.0`), which is JSON over
;; a GET with a modification window and an offset — the only one of the shapes
;; considered that the adapter contract already fits.
;;
;; WHY NOT OSV, WHICH IS THE OBVIOUS CHOICE FOR "against my dependencies":
;; `osv.dev`'s batch query is a **POST with a body**, and `feed-adapter`'s
;; `prepare` answers a URL and headers — no method, no body. `fetch` itself takes
;; `#:method` and `#:body`, so the gap is the ADAPTER contract rather than the
;; transport, and widening a contract four adapters share for one source that
;; nobody has asked for yet is the wrong trade. Recorded as FEED‑26 so the next
;; reader does not re-derive it: the day a POST source is wanted, `prepare`
;; grows a method and a body and `poll.rkt` passes them through.
;;
;; FEED‑24 — ONE ADVISORY IS ONE ITEM, NOT ONE PER AFFECTED DEPENDENCY, which is
;; #193's own open question. An advisory is the thing that gets published,
;; revised and withdrawn, so it is the thing with an identity; one item per
;; affected package would write N documents that all change together on every
;; revision, and the dedup hash would re-version all N and charge the team's
;; storage for it each time. The affected packages ride in the payload and in
;; `feed_packages`, which is what a trigger or the queue filters on.
;;
;; THE SHAPES HERE ARE FROM NVD'S PUBLISHED SCHEMA AND ARE NOT VERIFIED AGAINST A
;; LIVE SOURCE in this build — stated rather than implied, as the LibreOffice
;; branch and the SSE round trip are. Every read is defensive and a response this
;; cannot understand is a named refusal (FEED‑15), never a guess at where the
;; items are.

(require json racket/string racket/list
         "adapters.rkt")

(provide cve-nvd-adapter install-cve-adapter! NVD-WINDOW-DAYS NVD-PAGE)

;; FEED‑20: four beyond `FEED-ITEM-FIELDS`, so eight of LAY‑4's forty.
(define CVE-FIELDS
  (list (hasheq 'key "feed_cve"       'label "CVE")
        (hasheq 'key "feed_severity"  'label "Severity")
        (hasheq 'key "feed_published" 'label "Published")
        (hasheq 'key "feed_packages"  'label "Affected packages")))

(define NVD-PAGE "200")

;; FEED‑25 — THE WINDOW IS BOUNDED AT 120 DAYS BECAUSE THE SOURCE BOUNDS IT, and
;; the way that is handled is the decision. NVD refuses a `lastModStartDate`
;; range wider than 120 days, and the two dates are required TOGETHER — a start
;; with no end is a 404 with a body explaining it.
;;
;; A feed whose cursor is a year old therefore cannot be caught up in one
;; request. Clamping the START to now-120d would silently skip a year of
;; advisories; refusing would leave the feed permanently broken. So the adapter
;; walks **forward** at most 120 days per poll — start at the cursor, end at the
;; earlier of now and cursor+120d — and the cursor only advances over what
;; landed (FEED‑19), so the next poll continues from there. A year's backlog is
;; three polls rather than a gap.
(define NVD-WINDOW-DAYS 120)
(define DAY 86400)

(define HEADERS
  (list (cons "accept" "application/json")
        ;; GitHub's lesson, applied before it costs anything: a source that
        ;; refuses an anonymous-looking request does it with a status that reads
        ;; as a permission problem.
        (cons "user-agent" "Telemachus-feeds")))

(define (cursor->epoch cursor)
  (define n (and cursor (string->number (format "~a" cursor))))
  (and (real? n) (inexact->exact (floor n))))

(define (nvd-prepare feed cursor)
  (define from (cursor->epoch cursor))
  (define now (current-seconds))
  (values
   (if from
       (query-set (hash-ref feed 'url)
                  (cons 'resultsPerPage NVD-PAGE)
                  (cons 'startIndex "0")
                  (cons 'lastModStartDate (epoch->iso8601 from))
                  (cons 'lastModEndDate (epoch->iso8601 (min now (+ from (* NVD-WINDOW-DAYS DAY))))))
       ;; A FIRST poll asks for no window at all, which is deliberate: what
       ;; "everything" means is the operator's URL — a CPE, a keyword, a
       ;; severity — and the page cap in `poll.rkt` is what bounds it. Choosing a
       ;; start date here would be this adapter deciding how much history a team
       ;; gets, which is not its decision to make.
       (query-set (hash-ref feed 'url)
                  (cons 'resultsPerPage NVD-PAGE)
                  (cons 'startIndex "0")))
   HEADERS))

;; The English description, which is what makes a stored advisory findable by a
;; person. NVD sends every translation it has; `lang` is the only way to tell
;; them apart, and taking the first would give whichever one the source happened
;; to order first.
(define (english-description cve)
  (define ds (let ([v (hash-ref cve 'descriptions '())]) (if (list? v) v '())))
  (or (for/or ([d (in-list ds)] #:when (hash? d))
        (and (equal? (format "~a" (hash-ref d 'lang "")) "en")
             (let ([v (hash-ref d 'value #f)]) (and (string? v) v))))
      (for/or ([d (in-list ds)] #:when (hash? d))
        (let ([v (hash-ref d 'value #f)]) (and (string? v) v)))
      ""))

;; The worst severity any of the metric versions reports. NVD carries
;; `cvssMetricV31`, `V30`, `V2` and more at once and an advisory may have any
;; subset, so asking for one of them by name gives "" for a perfectly scored
;; advisory. Read as a RANK rather than a score: the severity words are what a
;; trigger can filter on, and `?attr=` is an equality filter (CLS‑8's reason).
;;
;; THE KEYS ARE SORTED, AND A CONTROL THAT DID NOT BITE IS WHY. With
;; `in-hash` the scan ran in Racket's own hash order, so on a fixture carrying a
;; MEDIUM v2 score and a CRITICAL v3.1 one, substituting "the first non-empty
;; wins" for the rank comparison changed nothing — the iteration happened to
;; reach v3.1 first. That is `canonical-json`'s trap in a second place: not a
;; cosmetic diff here but a severity that could differ between two processes
;; reading the same advisory, which is the field a trigger routes on. Sorted, the
;; walk is deterministic AND the control bites.
(define SEVERITY-RANK '("NONE" "LOW" "MEDIUM" "HIGH" "CRITICAL"))

(define (worst-severity cve)
  (define metrics (let ([v (hash-ref cve 'metrics #f)]) (and (hash? v) v)))
  (define found
    (if (not metrics) '()
        (for*/list ([k (in-list (sort (hash-keys metrics) symbol<?))]
                    [v (in-value (hash-ref metrics k))]
                    #:when (list? v)
                    [m (in-list v)] #:when (hash? m)
                    [s (in-value (severity-of m))]
                    #:when s)
          s)))
  (for/fold ([best ""]) ([s (in-list found)])
    (if (> (or (index-of SEVERITY-RANK s) -1) (or (index-of SEVERITY-RANK best) -1)) s best)))

(define (severity-of m)
  ;; v3 puts it on the cvssData, v2 on the metric itself. Both spellings, because
  ;; an advisory with only a v2 score is a real advisory.
  (define d (let ([v (hash-ref m 'cvssData #f)]) (and (hash? v) v)))
  (define s (or (and d (hash-ref d 'baseSeverity #f)) (hash-ref m 'baseSeverity #f)))
  (and (string? s) (string-upcase s)))

;; Every package the advisory names, from the configuration tree. A CPE is
;; `cpe:2.3:a:<vendor>:<product>:<version>:…`, and vendor/product is the pair an
;; operator matches a BOM against — the version belongs in the payload, where a
;; reader can see the range.
(define (affected-packages cve)
  (define cfgs (let ([v (hash-ref cve 'configurations '())]) (if (list? v) v '())))
  (remove-duplicates
   (for*/list ([c (in-list cfgs)] #:when (hash? c)
               [n (in-list (let ([v (hash-ref c 'nodes '())]) (if (list? v) v '())))] #:when (hash? n)
               [m (in-list (let ([v (hash-ref n 'cpeMatch '())]) (if (list? v) v '())))] #:when (hash? m)
               [pair (in-value (cpe-vendor-product (hash-ref m 'criteria #f)))]
               #:when pair)
     pair)))

(define (cpe-vendor-product criteria)
  (and (string? criteria)
       (let ([parts (string-split criteria ":" #:trim? #f)])
         ;; cpe : 2.3 : part : vendor : product : …
         (and (>= (length parts) 5)
              (let ([v (list-ref parts 3)] [p (list-ref parts 4)])
                (and (not (string=? p "")) (not (string=? p "*"))
                     (format "~a/~a" v p)))))))

(define (nvd-parse body headers request-url)
  (define parsed
    (with-handlers ([exn:fail? (lambda (_)
                                 (raise-user-error
                                  'feed "cve.nvd: the response did not parse as JSON"))])
      (bytes->jsexpr body)))
  (unless (and (hash? parsed) (list? (hash-ref parsed 'vulnerabilities #f)))
    (raise-user-error
     'feed "cve.nvd: expected an object with a `vulnerabilities` array~a"
     (if (and (hash? parsed) (string? (hash-ref parsed 'message #f)))
         (format ", and the source said: ~a" (hash-ref parsed 'message))
         "")))
  (define vulns (hash-ref parsed 'vulnerabilities))
  (values
   (for/list ([v (in-list vulns)] #:when (and (hash? v) (hash? (hash-ref v 'cve #f))))
     (define cve (hash-ref v 'cve))
     (define id (hash-ref cve 'id #f))
     (unless (and (string? id) (> (string-length id) 0))
       (raise-user-error
        'feed (string-append "cve.nvd: an advisory carries no `id` — the CVE id is the "
                             "identity, and without it two advisories would be stored over "
                             "one key")))
     (define modified (let ([m (hash-ref cve 'lastModified #f)]) (and (string? m) m)))
     (define published (let ([m (hash-ref cve 'published #f)]) (and (string? m) m)))
     (define pkgs (affected-packages cve))
     (define desc (english-description cve))
     (feed-item
      ;; FEED‑23: the CVE id and nothing else. It is globally unique by
      ;; construction, stable across revisions, and it is what a person types
      ;; into a search box — unlike GitHub's issue number, there is nothing to
      ;; compose it with and nothing it can collide against.
      (safe-id-part id)
      (if (string=? desc "")
          id
          (format "~a ~a" id (first-sentence desc)))
      v
      (iso8601->epoch modified)
      (hasheq 'feed_item_id id
              ;; NVD's own human page for the advisory. Composed rather than read
              ;; off the response, because the API does not carry one — and a
              ;; stored item whose `feed_url` is empty is one somebody cannot go
              ;; and look at.
              'feed_url (format "https://nvd.nist.gov/vuln/detail/~a" id)
              'feed_updated (or modified "")
              'feed_cve id
              'feed_severity (worst-severity cve)
              'feed_published (or published "")
              ;; Capped, because LAY‑4 values are strings and an advisory against
              ;; a widely-used library can name hundreds of products. The count
              ;; says what was dropped, so the attribute never lies by omission.
              'feed_packages (packages-value pkgs))))
   (next-page parsed request-url)))

(define PACKAGES-MAX 20)

(define (packages-value pkgs)
  (cond
    [(null? pkgs) ""]
    [(<= (length pkgs) PACKAGES-MAX) (string-join pkgs ",")]
    [else (format "~a,+~a more" (string-join (take pkgs PACKAGES-MAX) ",")
                  (- (length pkgs) PACKAGES-MAX))]))

(define (first-sentence s)
  (define t (regexp-replace* #px"\\s+" s " "))
  (define m (regexp-match #px"^(.{1,160}?)(?:\\.\\s|$)" t))
  (if m (cadr m) (substring t 0 (min 160 (string-length t)))))

;; NVD paginates by OFFSET, not by a `Link` header — so the next page is composed
;; from the three counters it returns, and the walk stops the moment the offset
;; reaches the total. Computed from the RESPONSE rather than counted here,
;; because a page the source trimmed would otherwise desynchronise the offset and
;; the walk would skip or repeat a page for ever.
(define (next-page parsed request-url)
  (define (num k) (let ([v (hash-ref parsed k #f)]) (and (real? v) (inexact->exact (floor v)))))
  (define start (or (num 'startIndex) 0))
  (define per (or (num 'resultsPerPage) 0))
  (define total (or (num 'totalResults) 0))
  (define next (+ start per))
  (and (> per 0) (< next total)
       (query-set request-url (cons 'startIndex (number->string next)))))

(define cve-nvd-adapter
  (feed-adapter "cve.nvd" "CVE advisories (NVD)" nvd-prepare nvd-parse CVE-FIELDS))

(define (install-cve-adapter!) (register-feed-adapter! cve-nvd-adapter))
