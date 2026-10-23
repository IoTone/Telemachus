#lang racket/base

;; domain/feeds/poll.rkt — one poll of one feed (#114 slice 4).
;;
;; This is the module the whole issue was waiting on, and it is deliberately the
;; only place in the slice that fetches, spends quota or writes a document. An
;; ADAPTER composes a request and reads a response (adapters.rkt) and knows
;; nothing else; everything that can go wrong for the TEAM — egress policy, the
;; budget, `can?`, the storage quota, the dedup rule, the cursor — happens here,
;; once, for every source anybody adds later.
;;
;; Five rules carry it:
;;
;;   • IT RUNS AS THE FEED'S USER (FEED-2). `(user-principal conn user team)`,
;;     so `can?` and both quota tiers decide and there is no new authorization
;;     code and no system principal.
;;   • AN UNCHANGED ITEM WRITES NOTHING (FEED-18). `repo-put!` on an existing key
;;     writes a new VERSION, so a poll that trusted the source's `updated_at`
;;     would version every item on every poll — the storage cost and the
;;     "updated" signal would both be lies. The hash is over the bytes this
;;     instance would store.
;;   • THE CURSOR ADVANCES ONLY OVER ITEMS THAT LANDED (FEED-19), and the next
;;     request's window is INCLUSIVE, so the newest item comes back and dedup
;;     absorbs it. A crash mid-page then costs a re-read, never a gap.
;;   • `feed.fetches` IS CHARGED PER REQUEST, NOT PER ITEM (FEED-9). The
;;     dimension protects the SOURCE's rate limit as much as this instance, and
;;     a page of 100 items cost the source one request.
;;   • A FAILURE NAMES THE HOST, THE PATH AND THE STATUS AND NOTHING ELSE
;;     (FEED-6). The response BODY is never stored: an error page is the
;;     source's own words and may quote the request we sent it, credential and
;;     all.

(require db-kit/portable
         json racket/string racket/list racket/port
         (only-in sha2-kit sha256-hex)
         (only-in "../authz/authz.rkt" audit! user-principal principal-team-id)
         (only-in "../orgs/orgs.rkt" tenant-quota-record!)
         (only-in "../net/fetch.rkt" fetch safe-url exn:fail:egress? exn:fail:egress-reason)
         (only-in "../repo/repo.rkt" repo-put! repo-get repo-set-attributes!
                  repo-fields repo-fields-set!)
         "adapters.rkt"
         (only-in "feeds.rkt" feed-by-id feed-auth-apply feed-cursor-set! feed-poll-recorded!
                  feed-item-ref feed-item-record! record-fetch! FEED-KINDS))

(provide (struct-out exn:fail:feed-store)
         poll-feed! FEED-MAX-PAGES FEED-MAX-ITEM-BYTES FEED-POLL-TIMEOUT FEED-MAX-BYTES
         declare-feed-fields! feed-item-key)

;; A repository with 40,000 open issues must not be one request, and a poll that
;; walked every page would hold a request thread (FEED-22's manual path) for as
;; long as the source cared to paginate. Ten pages of 100 is a working day's
;; backlog; what is left is picked up by the next tick, because the cursor only
;; advanced over what landed.
;; A write this platform refused — a storage quota, a key somebody else owns, a
;; validation rule on a `feed_*` field. Its own exception so the poll's summary
;; can name which half failed: "the source sent something I cannot read" and "I
;; could not store what the source sent" have no remedy in common.
(struct exn:fail:feed-store exn:fail () #:transparent)

(define FEED-MAX-PAGES 10)
(define FEED-MAX-BYTES (* 4 1024 1024))
;; One item is a ticket, an alert or an advisory. A megabyte of JSON for one is a
;; source doing something this adapter did not expect, and storing it would spend
;; the team's storage quota on it.
(define FEED-MAX-ITEM-BYTES (* 1024 1024))
(define FEED-POLL-TIMEOUT 30)

;; ---- FEED-20: the fields an item's attributes need -----------------------------------
;; LAY-4 REFUSES an attribute key the team has not defined, deliberately: a value
;; nothing can display or filter on is how a team concludes the model is broken.
;; So the adapter's declaration is added to the team's definitions, additively.
;;
;; Two rules make that safe. A key the team ALREADY defines is left exactly as it
;; is — a team's own label for `feed_state` is theirs, and overwriting it would
;; make a poll quietly rewrite configuration. And if the additions would exceed
;; LAY-4's forty-field cap the poll REFUSES BY NAME rather than truncating to
;; fit, because a truncated declaration is an attribute write that fails later,
;; on every item, for a reason nothing names.
(define (declare-feed-fields! conn team adapter)
  (define want (append FEED-ITEM-FIELDS (feed-adapter-fields adapter)))
  (define have (repo-fields conn team))
  (define known (for/list ([f (in-list have)]) (hash-ref f 'key "")))
  (define missing (for/list ([f (in-list want)] #:unless (member (hash-ref f 'key) known)) f))
  (cond
    [(null? missing) have]
    [(> (+ (length have) (length missing)) 40)
     (raise-user-error
      'feed (string-append
             "this feed's items need the fields ~a, and the team already defines ~a of the forty "
             "object fields LAY-4 allows. Remove a field the team no longer uses, or run this feed "
             "in a team of its own.")
      (string-join (for/list ([f (in-list missing)]) (hash-ref f 'key)) ", ")
      (length have))]
    [else
     (define r (repo-fields-set! conn team (append have missing)))
     (when (string? r) (raise-user-error 'feed "declaring this feed's item fields: ~a" r))
     r]))

;; FEED-1's key. `.json` because that is what the body IS, and an extension is
;; what a browser and a download both read; the external id is already reduced to
;; the key vocabulary by the adapter.
(define (feed-item-key slug external-id) (format "feeds/~a/~a.json" slug external-id))

;; ---- one poll ------------------------------------------------------------------------
;; -> a summary hash. It RAISES only for a configuration problem the caller must
;; fix (an unpollable kind, the field cap); everything a source can do to us is
;; an `ok: #f` summary with the reason, because a feed is expected to fail
;; sometimes and a failing poll must not fail the job that is only polling it.
(define (poll-feed! conn feed-id #:max-pages [max-pages FEED-MAX-PAGES])
  (define feed (feed-by-id conn feed-id))
  (unless feed (raise-user-error 'feed "no such feed"))
  (define kind (hash-ref feed 'kind))
  (define adapter (feed-adapter-for kind))
  (unless adapter
    ;; FEED-15, and the message names what CAN be polled rather than only what
    ;; cannot: an operator who configured `http.json` to probe a source is one
    ;; field away from a feed that works.
    (raise-user-error
     'feed (string-append "the feed kind `~a` can be probed but not polled by this build. "
                          "Kinds with an adapter: ~a")
     kind (let ([ks (feed-adapter-kinds)])
            (if (null? ks) "(none)" (string-join ks ", ")))))
  (define team (hash-ref feed 'team_id))
  (define p (user-principal conn (hash-ref feed 'user_id) team))
  (unless p
    ;; The member was removed or deactivated since the feed was configured. FEED-2
    ;; refuses that at the write, so this is the window afterwards — and running
    ;; as somebody else, or as nobody, is exactly what FEED-2 forbids.
    (raise-user-error 'feed "this feed's user is no longer an active member of the team"))
  (declare-feed-fields! conn team adapter)

  (define-values (first-url first-headers) ((feed-adapter-prepare adapter) feed (hash-ref feed 'cursor)))
  (define stats (make-hash))
  (define (bump! k [n 1]) (hash-set! stats k (+ n (hash-ref stats k 0))))
  ;; The cursor is advanced at the END, from the newest item that LANDED — never
  ;; inside the page loop, so a refusal halfway through a page cannot leave the
  ;; cursor past an item nothing stored.
  (define landed-epoch (box #f))
  (define (note-landed! e)
    (when (and e (or (not (unbox landed-epoch)) (> e (unbox landed-epoch))))
      (set-box! landed-epoch e)))

  (define outcome
    (let loop ([url first-url] [page 1])
      (define-values (authed hs) (feed-auth-apply conn feed url))
      (define request-headers (append first-headers hs))
      (define res
        (with-handlers ([exn:fail:egress?
                         (lambda (e) (hasheq 'ok #f 'reason (format "~a" (exn:fail:egress-reason e))
                                             'error (exn-message e)))]
                        ;; `reason` tells the two apart deliberately. A body the
                        ;; ADAPTER could not read is the source doing something
                        ;; unexpected; a write the platform REFUSED is the team's
                        ;; own budget or a key somebody else owns, and the
                        ;; remedies have nothing in common. Reported, not raised:
                        ;; a feed is expected to fail sometimes and a failing
                        ;; poll must not fail the job that is only polling it.
                        [exn:fail:feed-store?
                         (lambda (e) (hasheq 'ok #f 'reason "refused" 'error (exn-message e)))]
                        [exn:fail:user? (lambda (e) (hasheq 'ok #f 'reason "unreadable"
                                                            'error (exn-message e)))]
                        [exn:fail? (lambda (e) (hasheq 'ok #f 'reason "failed"
                                                       ;; never the body, never the URL as sent
                                                       'error (format "~a could not be fetched: ~a"
                                                                      (safe-url url) (exn-message e))))])
          ;; Charged BEFORE the request, so a source that hangs or refuses still
          ;; costs what it cost. Metering only successes would make a failing
          ;; feed free to hammer somebody's API.
          (bump! 'requests)
          (tenant-quota-record! conn p "feed.fetches" 1)
          (define-values (status _rh body)
            (fetch authed
                   ;; #142's `'trusted`: public, PLUS the private networks the
                   ;; OPERATOR allowed. The customer's feeds are "in our
                   ;; network" and this URL was chosen by a team admin, not by a
                   ;; model — FEED-4's whole argument.
                   #:policy 'trusted
                   #:timeout FEED-POLL-TIMEOUT
                   #:max-bytes FEED-MAX-BYTES
                   #:headers request-headers))
          (cond
            [(not (and (>= status 200) (< status 300)))
             (hasheq 'ok #f 'status status 'reason "status"
                     ;; FEED-6: the host, the path and the status. NOT the body —
                     ;; an error page is the source's own words and a great many
                     ;; of them quote the request, credential and all.
                     'error (format "the source answered ~a for ~a" status (safe-url url)))]
            [else
             (define-values (items next) ((feed-adapter-parse adapter) body _rh authed))
             ;; Re-raised as a STORE failure, so the summary can say which half
             ;; of the poll refused. The items already written stay written, and
             ;; the cursor has only advanced over them.
             (with-handlers ([exn:fail?
                              (lambda (e) (raise (exn:fail:feed-store (exn-message e)
                                                                      (exn-continuation-marks e))))])
               (for ([it (in-list items)]) (store-item! conn p feed it stats note-landed!)))
             (hasheq 'ok #t 'status status 'next next 'items (length items))])))
      (cond
        [(not (hash-ref res 'ok #f)) res]
        [(and (hash-ref res 'next #f) (< page max-pages))
         (loop (hash-ref res 'next) (add1 page))]
        [else (hash-set res 'truncated (and (hash-ref res 'next #f) #t))])))

  ;; The cursor and the counters are recorded whatever the outcome: a poll that
  ;; stored four items and then hit a 500 must not re-read those four for ever.
  (when (unbox landed-epoch) (feed-cursor-set! conn feed-id (unbox landed-epoch)))
  (feed-poll-recorded! conn feed-id (hash-ref stats 'stored 0))
  (record-fetch! conn feed-id
                 #:status (hash-ref outcome 'status #f)
                 #:error (hash-ref outcome 'error #f))
  (define summary
    (hasheq 'ok (and (hash-ref outcome 'ok #f) #t)
            'feed_id feed-id
            'slug (hash-ref feed 'slug)
            'status (or (hash-ref outcome 'status #f) 'null)
            'requests (hash-ref stats 'requests 0)
            'items (hash-ref stats 'items 0)
            'created (hash-ref stats 'created 0)
            'updated (hash-ref stats 'updated 0)
            'unchanged (hash-ref stats 'unchanged 0)
            'skipped (hash-ref stats 'skipped 0)
            'stored (hash-ref stats 'stored 0)
            'cursor (let ([c (unbox landed-epoch)]) (or c (hash-ref feed 'cursor) 'null))
            'truncated (and (hash-ref outcome 'truncated #f) #t)
            'error (or (hash-ref outcome 'error #f) 'null)
            'reason (or (hash-ref outcome 'reason #f) 'null)))
  ;; Audited once per poll, not once per item: an item is a document and
  ;; `repo-put!` already audits it with the team and the actor. The team is the
  ;; FEED's, which is what `audit-list` filters on — the seventh appearance of
  ;; that trap is recorded in CLAUDE.md and this is where it would have been the
  ;; eighth.
  (audit! conn #:action "feed.polled"
          #:actor-type "system" #:actor-id (hash-ref feed 'user_id)
          #:team-id team
          #:resource-type "feed" #:resource-id feed-id
          #:meta (jsexpr->string
                  (hasheq 'slug (hash-ref feed 'slug)
                          'kind kind
                          ;; `safe-url`, never the configured URL: the audit log
                          ;; is chained, exported off the box and kept through an
                          ;; erasure, so it outlives every other copy.
                          'url (safe-url (hash-ref feed 'url))
                          'requests (hash-ref stats 'requests 0)
                          'items (hash-ref stats 'items 0)
                          'stored (hash-ref stats 'stored 0)
                          'ok (and (hash-ref outcome 'ok #f) #t))))
  summary)

;; ---- one item ------------------------------------------------------------------------
(define (store-item! conn p feed it stats note-landed!)
  (define (bump! k [n 1]) (hash-set! stats k (+ n (hash-ref stats k 0))))
  (bump! 'items)
  (define feed-id (hash-ref feed 'id))
  (define ext (feed-item-external-id it))
  (define payload (canonical-json (feed-item-payload it)))
  (define bytes (string->bytes/utf-8 payload))
  (define hash (sha256-hex bytes))
  (define prior (feed-item-ref conn feed-id ext))
  ;; A prior row whose object has been DELETED is a tombstone, not a hit: the
  ;; item is skipped rather than recreated, because deleting a pulled document is
  ;; an ordinary repository delete and a poll that undid it would leave no way to
  ;; get rid of an item except by deleting the feed.
  (define prior-object
    (and prior (hash-ref prior 'object_id)
         (with-handlers ([(lambda (_) #t) (lambda (_) #f)])
           (repo-get conn p (hash-ref prior 'object_id)))))
  (cond
    [(> (bytes-length bytes) FEED-MAX-ITEM-BYTES)
     (bump! 'skipped)]
    [(and prior (not prior-object) (hash-ref prior 'object_id))
     ;; the tombstone above. Its `last_seen_epoch` still moves, so an operator
     ;; can see the feed is still offering it.
     (feed-item-record! conn feed-id ext #:hash (hash-ref prior 'content_hash)
                        #:epoch (feed-item-epoch it))
     (bump! 'skipped)
     (note-landed! (feed-item-epoch it))]
    [(and prior prior-object (equal? hash (hash-ref prior 'content_hash)))
     ;; FEED-18: an unchanged item costs one comparison and no write.
     (feed-item-record! conn feed-id ext #:hash hash #:epoch (feed-item-epoch it))
     (bump! 'unchanged)
     (note-landed! (feed-item-epoch it))]
    [else
     (define key (feed-item-key (hash-ref feed 'slug) ext))
     (define obj
       (with-handlers ([exn:fail:user?
                        (lambda (e)
                          ;; A storage quota, or a key somebody else owns. NOT
                          ;; swallowed into a count: the poll stops, and because
                          ;; the cursor only advanced over what landed, the next
                          ;; one starts here again.
                          (raise e))])
         (repo-put! conn p #:key key #:port (open-input-bytes bytes)
                    #:content-type "application/json"
                    ;; FEED-17: the title rides in the version's FILENAME, which
                    ;; is what search covers — `application/json` has no
                    ;; extractor, so without this a pulled item would be
                    ;; invisible to the only question anybody asks of it ("which
                    ;; document is issue #114?"). 0022-fold-documents already
                    ;; put a document's title here.
                    #:filename (feed-item-title it)
                    #:as (hash-ref feed 'user_id))))
     (define oid (hash-ref obj 'id))
     (define attrs (hash-set (feed-item-attributes it) 'feed_slug (hash-ref feed 'slug)))
     (define r (repo-set-attributes! conn p oid attrs))
     (when (string? r)
       ;; `declare-feed-fields!` ran at the top of the poll, so this is a field
       ;; the ADAPTER declared and the value failed — a validation rule the team
       ;; added to a `feed_*` key. Named, not dropped: slice 5's queue reads
       ;; exactly these keys.
       (raise-user-error 'feed "~a: ~a" key r))
     (feed-item-record! conn feed-id ext #:hash hash #:object oid
                        #:version (hash-ref obj 'version_id #f)
                        #:epoch (feed-item-epoch it))
     (bump! (if prior 'updated 'created))
     (bump! 'stored)
     (note-landed! (feed-item-epoch it))]))
