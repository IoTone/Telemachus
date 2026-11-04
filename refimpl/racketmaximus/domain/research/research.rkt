#lang racket/base

;; domain/research/research.rkt — a bookmarked URL, archived (issue #191 slice 1,
;; RG-1/-2/-3).
;;
;; #191's motive, in its own words, is that "that old CERN philosophy about the
;; permanence of links is being eroded". The answer needs almost no new
;; mechanism, and saying which part is new matters more than the code:
;;
;;   • THE BYTES ARE A REPOSITORY DOCUMENT. `research/<host>/<slug>-<id8>` under
;;     the content type as served. Visibility, grants and sharing, keyword search
;;     over extracted text, `?semantic=1`, `repo_retrieve`, retention, the
;;     cascade delete, "Processed by", `storage.bytes`, the read audit and the
;;     put-hook trigger seam all arrive with it and none of them is written here.
;;   • PERMANENCE IS THE CONTENT-ADDRESSED STORE PLUS VERSIONING, and it is
;;     already built. A re-fetch is a NEW VERSION OF THE SAME KEY — never a new
;;     object — so the old bytes stay addressable under their own digest and
;;     "what did this page say when I bookmarked it" is a version read. Identical
;;     bytes dedup to the same blob, so watching a stable page costs one row and
;;     no storage.
;;   • THE ROW ANSWERS WHAT THE DOCUMENT CANNOT (QUEUE-1). "Have we already got
;;     this" is a unique index, "which are stale" is an epoch sort, "did it
;;     change" is a digest and "did the last fetch fail" is a status and a sealed
;;     message. A LAY-4 attribute is a string compared for equality and answers
;;     none of them in SQL.
;;   • THE FETCH IS `'untrusted` AND THERE IS NO WAY TO SAY OTHERWISE (RG-3).
;;     FEED-4's rule is that the egress policy attaches to WHO CHOSE THE URL, not
;;     to where it points. A feed URL is operator-authored behind
;;     `feeds:manage` — the same trust as `TMACH_MODEL_URL` — which is why #114
;;     could ask for feeds inside the network. A bookmark is MEMBER-authored
;;     behind `research:use`, so this is the first URL an ordinary member makes
;;     this server fetch, and being authenticated does not make
;;     `http://169.254.169.254/latest/meta-data/` safe to request. There is no
;;     `'trusted` mode on this surface and not even an operator has one: an
;;     internal page that should be archived is a FEED, which already has the
;;     right permission and the right argument. A flag here would put an SSRF
;;     switch behind a permission a plain member holds.
;;
;; WHAT THIS DOES NOT ARCHIVE, STATED RATHER THAN IMPLIED (RG-2): the bytes the
;; FETCHER received, not the page a browser renders. A single-page application
;; archives as its loader shell. Fixing that means a headless browser in the
;; image, which this project has declined three times — HPDF-1 on the merits and
;; OFFICE-1 and `container.md` on the ~1 GB — so the honest answer for a
;; JS-rendered page is a reader-mode copy the person uploads, which the
;; repository already takes.

(require db-kit/portable
         racket/string
         net/url
         (only-in sha2-kit sha256-hex)
         "../db/id.rkt"
         "../db/nulls.rkt"
         (only-in "../authz/sealed.rkt" define-sealed-column)
         (only-in "../net/fetch.rkt" fetch safe-url exn:fail:egress? exn:fail:egress-reason)
         (only-in "../repo/keyparts.rkt" safe-key-part)
         (only-in "../repo/repo.rkt" repo-put!)
         (only-in "../orgs/orgs.rkt" tenant-quota-check tenant-quota-record!))

(provide RESEARCH-MAX-NOTE RESEARCH-MAX-URL
         canonical-url research-problem research-key
         research-create! research-list research-get research-by-id research-delete!
         research-fetch! record-research-fetch! RESEARCH-DIM)

;; A fetch failure is somebody else's server's words about a URL a member chose,
;; so the column is sealed under the CONTENT switch (RG-3, #83 r4's reason) and
;; `#:forgiving`, which is ENC-21: a payload that will not open must RAISE, and a
;; stored DIAGNOSTIC must never take the row it describes down with it. It is in
;; `CONTENT-SECRETS` in `cli/telemachus-secrets.rkt` for the reason the schedule
;; payload is — LIFETIME. A job row settles in minutes and #59 purges it; a
;; bookmark is configuration that outlives key rotations, and a sealed column
;; `rewrap` does not walk is silently unrotatable.
(define-sealed-column "research_sources.last_error"
                      (seal-fetch-error unseal-fetch-error) (id) #:forgiving)

;; THE BYTE CAP AND THE TIMEOUT ARE THE FETCHER'S AND ARE NOT NAMED AGAIN HERE.
;; 8 MiB and 30 seconds are generous for a web page, and a second home for either
;; number is LIVE-IN's shape: two literals saying one thing with nothing stopping
;; one from moving. A research fetch that wants its own figures should say so by
;; passing them, not by shadowing them.
;;
;; What this module does bound is its own: how much a person may hang off a
;; bookmark, because both fields are stored unsealed and listed on every read.
(define RESEARCH-MAX-NOTE 4000)
(define RESEARCH-MAX-URL  2000)

;; `nz` renders SQL NULL as the jsexpr null, AND `'null` IS TRUTHY IN RACKET —
;; the trap this tree has paid for in `feed_items`, in `research`'s own first
;; draft and in a schedule's "has this ever fired". A row field is read through
;; this wherever Racket is going to branch on it.
(define (field h k)
  (define v (hash-ref h k 'null))
  (if (eq? v 'null) #f v))

(define (now) (current-seconds))

;; ---- RG-1: the canonical URL is the identity, and this is narrow ON PURPOSE --------
;; Lower-case the scheme and the host, drop a default port, drop the fragment.
;; NOTHING ELSE.
;;
;; Every tempting addition changes which resource is addressed on some real site,
;; and the failure is SILENT in the worst direction:
;;
;;   • stripping tracking parameters merges two pages that differ (`?page=2`
;;     looks like tracking to a list of patterns somebody maintains);
;;   • normalizing a trailing slash: `/a` and `/a/` are different resources on
;;     any server that says so;
;;   • sorting the query: order is significant to plenty of real applications.
;;
;; A person who pastes two spellings of one URL gets two rows, which is visible
;; in a listing and fixable with a delete. A platform that merges two different
;; pages into one archive is neither — the second page's bytes land as a VERSION
;; of the first, and the version chain then says a page changed when it did not.
(define (canonical-url s)
  (define u (with-handlers ([exn:fail? (lambda (_) #f)]) (string->url (format "~a" s))))
  (and u
       (url-scheme u)
       (url-host u)
       ;; The SCHEME is checked here as well as in `research-problem`, and the
       ;; two are not redundant: this function is the IDENTITY, so anything that
       ;; can reach it — a row written before a validation rule existed, a future
       ;; caller — must not be handed a canonical form for a URL this surface
       ;; would never fetch.
       (member (string-downcase (url-scheme u)) '("http" "https"))
       (let* ([scheme (string-downcase (url-scheme u))]
              [host (string-downcase (url-host u))]
              [port (url-port u)]
              [default? (or (not port)
                            (and (string=? scheme "http") (= port 80))
                            (and (string=? scheme "https") (= port 443)))])
         (url->string
          (make-url scheme
                    (url-user u)
                    host
                    (if default? #f port)
                    (url-path-absolute? u)
                    (url-path u)
                    (url-query u)
                    ;; the fragment is a position in the page, never part of what
                    ;; is addressed — the one normalization nobody can argue with
                    #f)))))

;; ---- validation -------------------------------------------------------------------
;; One function, so nothing a create refuses can be reached another way.
(define (research-problem #:url url #:title title #:note note)
  (define parsed (with-handlers ([exn:fail? (lambda (_) #f)])
                   (string->url (if (string? url) url ""))))
  (cond
    [(not (and (string? url) (positive? (string-length url))))
     "`url` is required"]
    [(> (string-length url) RESEARCH-MAX-URL)
     (format "`url` must be at most ~a characters" RESEARCH-MAX-URL)]
    [(not (and parsed (url-host parsed) (not (string=? (url-host parsed) ""))
               (member (url-scheme parsed) '("http" "https"))))
     "`url` must be an http(s) URL"]
    ;; `https://user:pass@host/` is unambiguously a credential, and unlike a feed
    ;; this row has NO sealed place to put one (RG-1) — a bookmark is a public
    ;; page. Refused rather than stored, because stored it would be in the clear
    ;; in every read of the row, and refused rather than stripped, because
    ;; silently fetching a different request from the one somebody asked for is
    ;; worse than saying no.
    [(url-user parsed)
     "take the credential out of `url` — a bookmark is a public page and this row has nowhere to keep one. If the page needs a credential it is a FEED, which is configured by an operator and stores the secret sealed."]
    [(not (canonical-url url)) "`url` could not be read"]
    [(and note (> (string-length note) RESEARCH-MAX-NOTE))
     (format "`note` must be at most ~a characters" RESEARCH-MAX-NOTE)]
    [(and title (> (string-length title) 500))
     "`title` must be at most 500 characters"]
    [else #f]))

;; ---- RG-2: the key, composed ONCE ------------------------------------------------
;; `research/<host>/<slug>-<id8>.<ext>`. The host and the slug are somebody
;; else's strings on their way into a repository key, so both go through
;; `safe-key-part` — the one home for that rule, which `domain/feeds/adapters.rkt`
;; is the other asker of.
;;
;; The `<id8>` is what makes the key UNIQUE without making it unpredictable: two
;; different URLs on one host whose paths reduce to the same slug would otherwise
;; collide, and a collision here writes one page's bytes as a version of the
;; other — the failure the canonicalization rule above exists to avoid, arriving
;; by a different door.
(define (research-key id url ext)
  (define u (string->url url))
  (define host (safe-key-part (or (url-host u) "x")))
  ;; A `..` SEGMENT IS A SYMBOL, NOT A STRING — Racket's URL parser answers
  ;; `'up` for `..` and `'same` for `.`, which is the trap recorded in CLAUDE.md
  ;; from the day the public bundle route answered 500 instead of its intended
  ;; 404. So every segment is formatted BEFORE it is compared, and the result
  ;; then goes through `safe-key-part` anyway.
  (define segs (for/list ([seg (in-list (url-path u))]
                          #:unless (string=? (format "~a" (path/param-path seg)) ""))
                 (format "~a" (path/param-path seg))))
  (define slug (safe-key-part (if (null? segs) "index" (string-join segs "-"))))
  (format "research/~a/~a-~a~a" host slug (substring id 0 8) (or ext "")))

;; What extension to hang off the key, from the content type the FIRST fetch was
;; served. Deliberately a short list and `""` for anything else: the extension is
;; a courtesy to whoever downloads the archive, and the authoritative type is the
;; version's own `content_type`. Guessing an extension from a type nobody listed
;; would put `.bin` on a page that is perfectly readable.
(define (ext-for content-type)
  (define parts (string-split (string-downcase (format "~a" (or content-type ""))) ";"))
  (define t (if (null? parts) "" (car parts)))
  (cond
    [(string=? t "text/html") ".html"]
    [(string=? t "application/xhtml+xml") ".html"]
    [(string=? t "text/plain") ".txt"]
    [(string=? t "text/markdown") ".md"]
    [(string=? t "application/pdf") ".pdf"]
    [(string=? t "application/json") ".json"]
    [(string=? t "text/xml") ".xml"]
    [(string=? t "application/xml") ".xml"]
    [else ""]))

;; ---- rows -------------------------------------------------------------------------
;; `archived` IS JOINED, NOT READ OFF `object_id`, and that is not a tidy-up.
;; The archive is an ordinary repository document, so #86's retention sweep and
;; an ordinary `DELETE /api/repo-obj/<id>` can both take it away — and a row that
;; still carried a non-NULL `object_id` would then report `archived: true` with
;; nothing behind it. PULL-11e's rule: a field a reader learns to distrust is
;; worse than no field, which is why `worker_state` is WITHDRAWN when its row
;; goes stale rather than repeated.
;;
;; `object_id` is reported only when the document is really there, for the same
;; reason — a dangling id is the distrust in its most literal form. What is NOT
;; cleared is `object_key`: it is what makes a re-fetch land on the SAME key
;; (RG-15), so after a retention delete the bookmark re-archives where it always
;; was rather than starting a second archive nobody can diff against the first.
(define SELECT
  (string-append "SELECT s.id, s.team_id, s.user_id, s.url, s.url_canon, s.title, s.note, "
                 "s.object_key, o.id, s.active, s.created_by, s.created_epoch, s.fetched_epoch, "
                 "s.last_ok_epoch, s.last_status, s.last_error, s.content_type, s.content_sha256, "
                 "s.content_bytes, s.etag, s.last_modified, s.fetches "
                 "FROM research_sources s LEFT JOIN repo_objects o "
                 ;; `deleted_at IS NULL` is NOT optional and the test is what
                 ;; said so: a repository delete is a SOFT delete — it stamps
                 ;; `deleted_at` and nulls `current_version_id`, and the row
                 ;; stays — so a join on the id alone goes on matching a
                 ;; document nobody can read and `archived` goes on claiming it.
                 "ON o.id = s.object_id AND o.deleted_at IS NULL "))

(define (row->source r)
  (define id (vector-ref r 0))
  (hasheq 'id id
          'team_id (vector-ref r 1)
          'user_id (vector-ref r 2)
          ;; AS GIVEN. A read is behind the same permission that wrote it, and
          ;; somebody who cannot see the URL they pasted cannot tell two
          ;; bookmarks apart. There is no credential to withhold — userinfo is
          ;; refused at the write, and this row has no secret column at all.
          'url (vector-ref r 3)
          'url_canon (vector-ref r 4)
          'title (nz (vector-ref r 5))
          'note (nz (vector-ref r 6))
          'object_key (nz (vector-ref r 7))
          'object_id (nz (vector-ref r 8))
          'active (= 1 (vector-ref r 9))
          'created_by (nz (vector-ref r 10))
          'created_epoch (vector-ref r 11)
          'fetched_epoch (nz (vector-ref r 12))
          'last_ok_epoch (nz (vector-ref r 13))
          'last_status (nz (vector-ref r 14))
          'last_error (let ([e (vector-ref r 15)])
                        (if (sql-null? e) 'null (unseal-fetch-error id e)))
          'content_type (nz (vector-ref r 16))
          'content_sha256 (nz (vector-ref r 17))
          'content_bytes (nz (vector-ref r 18))
          'etag (nz (vector-ref r 19))
          'last_modified (nz (vector-ref r 20))
          'fetches (vector-ref r 21)
          ;; DERIVED from the JOIN, never stored and never read off `object_id` —
          ;; the rule `polling`, `missing`/`stale` and `worker_state` all live by.
          'archived (not (sql-null? (vector-ref r 8)))))

(define (research-list conn team)
  (for/list ([r (in-list (query-rows conn (string-append SELECT "WHERE s.team_id = ? ORDER BY s.created_epoch DESC, s.id")
                                     team))])
    (row->source r)))

(define (research-get conn id team)
  (define r (query-maybe-row conn (string-append SELECT "WHERE s.id = ? AND s.team_id = ?") id team))
  (and r (row->source r)))

;; For a caller that has a row id and no team — a job, which carries neither. The
;; row itself says which team it belongs to. Team-scoped reads stay the API's.
(define (research-by-id conn id)
  (define r (query-maybe-row conn (string-append SELECT "WHERE s.id = ?") id))
  (and r (row->source r)))

(define (active-member? conn team user)
  (and (string? user)
       (not (string=? user ""))
       (positive? (query-value conn
                   "SELECT COUNT(*) FROM memberships WHERE team_id = ? AND user_id = ? AND status = 'active'"
                   team user))))

;; -> id, or 'duplicate-url / 'no-such-user
;;
;; A duplicate is a 409 and NOT a converging create. Re-posting a feed would
;; silently adopt whatever URL and credential were already there (TEN-2f's
;; distinction); here the cost is different and no smaller — a converging create
;; would quietly re-point somebody else's bookmark, with its note and its whole
;; version history, at a title and a note this caller supplied.
(define (research-create! conn #:team team #:user user #:url url #:title title #:note note
                          #:created-by created-by)
  (define canon (canonical-url url))
  (cond
    [(not (active-member? conn team user)) 'no-such-user]
    [(query-maybe-value conn "SELECT id FROM research_sources WHERE team_id = ? AND url_canon = ?"
                        team canon)
     'duplicate-url]
    [else
     (define id (new-id))
     (query-exec conn (string-append
                       "INSERT INTO research_sources (id, team_id, user_id, url, url_canon, title, "
                       "note, active, created_by, created_epoch) VALUES (?,?,?,?,?,?,?,1,?,?)")
                 id team user url canon (or title sql-null) (or note sql-null)
                 (or created-by sql-null) (now))
     id]))

(define (research-delete! conn id team)
  ;; The ROW only. What was archived is an ordinary repository document and is
  ;; untouched — deleting the bookmark is not a retraction of the page, exactly
  ;; as deleting a feed is not a retraction of its items. Somebody who wants the
  ;; bytes gone deletes the document, which is where the cascade, the blob
  ;; release and the storage refund all live.
  (define n (query-maybe-value conn "SELECT id FROM research_sources WHERE id = ? AND team_id = ?"
                               id team))
  (and n (begin (query-exec conn "DELETE FROM research_sources WHERE id = ?" id) #t)))

;; ---- the outcome of a fetch -------------------------------------------------------
(define (record-research-fetch! conn id #:status [status #f] #:error [error #f]
                                #:content-type [content-type #f] #:sha256 [sha #f]
                                #:bytes [nbytes #f] #:etag [etag #f] #:last-modified [lm #f]
                                #:object [object #f] #:key [key #f])
  (query-exec conn (string-append "UPDATE research_sources SET fetched_epoch = ?, last_status = ?, "
                                  "last_error = ?, fetches = fetches + 1 WHERE id = ?")
              (now) (or status sql-null)
              (if error (seal-fetch-error id error) sql-null)
              id)
  ;; `last_ok_epoch` moves only on a 2xx, so "it last worked at" survives a run
  ;; of failures — which is the figure somebody wants when a bookmark has been
  ;; quietly 404ing for a month. FEED's own rule, and the test has to AGE the row
  ;; to see it, because the column is seconds.
  (when (and status (>= status 200) (< status 300))
    (query-exec conn "UPDATE research_sources SET last_ok_epoch = ? WHERE id = ?" (now) id))
  ;; Column by column, each under its own `when`. One UPDATE built with a
  ;; conditional clause list and a fixed argument list is how a clause and its
  ;; parameter come apart — a bug this tree has recorded six times, once in this
  ;; module's own sibling.
  (when content-type
    (query-exec conn "UPDATE research_sources SET content_type = ? WHERE id = ?" content-type id))
  (when sha (query-exec conn "UPDATE research_sources SET content_sha256 = ? WHERE id = ?" sha id))
  (when nbytes (query-exec conn "UPDATE research_sources SET content_bytes = ? WHERE id = ?" nbytes id))
  (when etag (query-exec conn "UPDATE research_sources SET etag = ? WHERE id = ?" etag id))
  (when lm (query-exec conn "UPDATE research_sources SET last_modified = ? WHERE id = ?" lm id))
  (when key (query-exec conn "UPDATE research_sources SET object_key = ? WHERE id = ?" key id))
  (when object (query-exec conn "UPDATE research_sources SET object_id = ? WHERE id = ?" object id)))

(define (header-value hs name)
  (define want (string-downcase name))
  (for/or ([kv (in-list hs)])
    (and (string=? (string-downcase (format "~a" (car kv))) want)
         (format "~a" (cdr kv)))))

;; ---- the fetch ---------------------------------------------------------------------
;; One request, stored as a new version of the row's own key. Answers what
;; happened; raises only for a write this platform refused, which is the caller's
;; to report.
;;
;; `#:fetch` is a seam for the tests, which must be able to exercise the store,
;; the same-key rule and the dedup WITHOUT a socket — and, more to the point,
;; must be able to assert that a refusal by POLICY stores nothing. It defaults to
;; the real fetcher, so no production caller chooses.
(define RESEARCH-DIM "research.fetches")

(define (research-fetch! conn p row #:fetch [do-fetch #f])
  (define id (hash-ref row 'id))
  (define url (hash-ref row 'url))
  ;; THE BUDGET IS ASKED HERE, NOT AT THE TWO ENDPOINTS, and that is FEED-9's
  ;; rule with one home rather than two: charged PER REQUEST and BEFORE the
  ;; request, because metering only successes would make a bookmark pointed at a
  ;; site that refuses free to retry for ever. Two call sites would be one more
  ;; place to forget, and the one that forgot would be the cheap-looking one.
  ;;
  ;; The DECISION comes back rather than a response, because this module has no
  ;; HTTP in it: the endpoint renders the 429 (and its `resets_at`), which is
  ;; also what lets a test assert the refusal without a server.
  (define budget (tenant-quota-check conn p RESEARCH-DIM 1))
  (cond
    [(not (hash-ref budget 'allowed))
     (hasheq 'ok #f 'reason "quota" 'quota budget 'status 'null)]
    [else
     (tenant-quota-record! conn p RESEARCH-DIM 1)
     (research-fetch-now! conn p row id url do-fetch)]))

(define (research-fetch-now! conn p row id url do-fetch)
  (define outcome
    (with-handlers
      ([exn:fail:egress?
        ;; A refusal BY POLICY is its own answer, and it is the one this surface
        ;; exists to give: "we would not go there" is not "it did not answer".
        ;; `fetch` has already dropped the query on the way into the message.
        (lambda (e) (hasheq 'ok #f 'reason (format "~a" (exn:fail:egress-reason e))
                            'error (exn-message e)))]
       [(lambda (_) #t)
        ;; A TLS failure or a reset may carry the host and cannot carry the
        ;; query, because the query never reached it. Still never quotes the
        ;; request.
        (lambda (e) (hasheq 'ok #f 'reason "failed"
                            'error (if (exn? e) (exn-message e) (format "~a" e))))])
      (define-values (status hs body)
        (if do-fetch
            (do-fetch url)
            (fetch url
                   ;; RG-3. Passed EXPLICITLY although it is the fetcher's
                   ;; default, because this is the decision of the slice and a
                   ;; reader must be able to see it made rather than inherited.
                   #:policy 'untrusted)))
      (hasheq 'ok (and (>= status 200) (< status 300))
              'status status
              'headers hs
              'body body
              'bytes (bytes-length body))))
  (cond
    [(not (hash-ref outcome 'ok))
     (record-research-fetch! conn id
                             #:status (hash-ref outcome 'status #f)
                             #:error (or (hash-ref outcome 'error #f)
                                         (format "the source answered ~a"
                                                 (hash-ref outcome 'status "nothing"))))
     (hasheq 'ok #f
             'reason (hash-ref outcome 'reason "refused")
             'status (or (hash-ref outcome 'status #f) 'null))]
    [else
     (define body (hash-ref outcome 'body))
     (define hs (hash-ref outcome 'headers))
     (define ctype (or (and (header-value hs "content-type")
                            (car (string-split (header-value hs "content-type") ";")))
                       "application/octet-stream"))
     (define digest (sha256-hex body))
     ;; RG-2: the SAME KEY, for ever. Composed on the first fetch from the
     ;; content type that fetch was served, then reused whatever the type does
     ;; later — a page that starts answering as a PDF becomes a new VERSION with
     ;; its own `content_type` under a key that still ends `.html`, which is odd
     ;; to read and is the right trade: the alternative is a second object, and
     ;; then "what did this page say when I bookmarked it" has two answers in two
     ;; places and the version chain is broken at exactly the moment it became
     ;; interesting.
     (define key (or (field row 'object_key) (research-key id url (ext-for ctype))))
     (define unchanged? (equal? digest (field row 'content_sha256)))
     (define obj
       (repo-put! conn p #:key key #:port (open-input-bytes body)
                  #:content-type ctype
                  ;; The TITLE rides in the version's filename, which is what
                  ;; search covers and what `title-like?` (#239 PATH-5) reads to
                  ;; decide whether a row has a human title to show instead of a
                  ;; path. Without it an archived page is listed by its key.
                  #:filename (or (field row 'title) "")
                  ;; DWF-3: this is not a pipeline output, and the one thing
                  ;; `#:derived?` would buy — stopping a trigger firing on it —
                  ;; is the opposite of what an archived page wants. A trigger on
                  ;; `text/html` SHOULD fire on a page somebody bookmarked;
                  ;; that is the whole point of slice 2's distillation being a
                  ;; workflow. Left #f deliberately rather than by omission.
                  #:as (hash-ref row 'user_id)))
     (record-research-fetch! conn id
                             #:status (hash-ref outcome 'status)
                             #:error #f
                             #:content-type ctype
                             #:sha256 digest
                             #:bytes (hash-ref outcome 'bytes)
                             #:etag (header-value hs "etag")
                             #:last-modified (header-value hs "last-modified")
                             #:object (hash-ref obj 'id)
                             #:key key)
     (hasheq 'ok #t
             'status (hash-ref outcome 'status)
             'bytes (hash-ref outcome 'bytes)
             'content_type ctype
             'sha256 digest
             ;; The row's own answer to "did it change", computed against the
             ;; digest BEFORE this fetch overwrote it. The blob store dedups
             ;; identical bytes, so an unchanged page costs a version row and no
             ;; storage — but the version row is still written, because "we
             ;; looked on Tuesday and it was the same" is a fact about the
             ;; archive and the alternative is a gap nobody can distinguish from
             ;; not having looked.
             'unchanged unchanged?
             'key key
             'object_id (hash-ref obj 'id)
             'version_id (hash-ref obj 'version_id (hash-ref obj 'id)))]))
