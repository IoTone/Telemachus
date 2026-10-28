#lang racket/base

;; #128 job 2: operator-facing variables are read through ONE accessor,
;; which tries TMACH_<name> and falls back to TELEMACHUS_<name>.
(require (only-in "../config.rkt" tmach-env))

;; test/feed-poll-tests.rkt — the first feed adapter and the poll (#114 slice 4).
;;
;;   raco test test/feed-poll-tests.rkt
;;
;; The slice's acceptance criteria are the three cases nobody can argue with, and
;; each is written so that the obvious wrong implementation fails it:
;;
;;   1. AN ITEM BECOMES A DOCUMENT THE FEED'S USER CAN READ — under the right
;;      key, with the payload as the body and the TITLE where search can see it.
;;   2. AN UNCHANGED ITEM ON THE NEXT POLL WRITES NO NEW VERSION. Asserted over
;;      the version COUNT, not over a summary field: a poller that versioned
;;      every item would report `unchanged: 1` quite happily if the count were
;;      not checked.
;;   3. `feed.fetches` IS CHARGED, PER REQUEST. Read off the LEDGER
;;      (`quota-used`), because `quota-check` reports `used: 0` when no limit is
;;      set — the trap recorded in CLAUDE.md.
;;
;; Plus the three rules that are easy to get wrong and silent when wrong: the
;; cursor advances only over what landed (FEED-19), an id composed without its
;; repository would collide (FEED-16), and the canonical payload must not depend
;; on this process's hash order (FEED-18).

(require rackunit db-kit/portable db-kit/migrate
         racket/tcp racket/string racket/list racket/file racket/port json
         "../domain/db/migrations.rkt"
         "db-fixture.rkt"
         "../domain/authz/authz.rkt"
         "../domain/repo/blobs.rkt"
         (only-in "../domain/repo/repo.rkt" repo-list repo-open repo-get repo-versions
                  repo-fields repo-fields-set! repo-delete!)
         (only-in "../domain/quota/quota.rkt" quota-used set-limit!)
         "../domain/feeds/feeds.rkt"
         "../domain/feeds/adapters.rkt"
         "../domain/feeds/adapter-github.rkt"
         "../domain/feeds/poll.rkt")

(define BLOB-ROOT (make-temporary-file "telemachus-feedpoll-~a" 'directory))
(current-blob-root BLOB-ROOT)

;; The adapter is a platform one, so it owns an unprefixed name and registering
;; it twice in one process is fine — which is what makes this safe to call from
;; a test file as well as from the boot sequence.
(void (install-github-adapter!))

(define (fresh) (define c (fresh-db #:migrate? #f)) (migrate! c all-migrations) c)

(define (owner conn)
  (define-values (u t) (bootstrap! conn #:username "alice" #:org-name "Acme" #:org-slug "acme"
                                   #:team-name "Eng" #:team-slug "eng"))
  (values u t))

;; ---- a GitHub-shaped source over a real socket ----------------------------------------
;; `with-source` hands out one response per request, in order, so pagination and
;; a mid-poll failure are both expressible. The requests are kept, because WHERE
;; the cursor and the credential went is half of what is being asserted.
(define (with-source responses proc)
  (define L (tcp-listen 0 8 #t "127.0.0.1"))
  (define-values (_h port _rh _rp) (tcp-addresses L #t))
  (define seen (box '()))
  ;; A procedure is accepted as well as a list, because a `Link: rel="next"` has
  ;; to name THIS listener's port and the port is not known until it is bound.
  (define left (box (if (procedure? responses) (responses port) responses)))
  (define t
    (thread (lambda ()
              (with-handlers ([(lambda (_) #t) void])
                (let loop ()
                  (define-values (i o) (tcp-accept L))
                  (thread (lambda ()
                            (with-handlers ([(lambda (_) #t) void])
                              (define lines
                                (let rl ([acc '()])
                                  (define l (read-line i 'return-linefeed))
                                  (cond [(or (eof-object? l) (string=? l "")) (reverse acc)]
                                        [else (rl (cons l acc))])))
                              (set-box! seen (append (unbox seen) (list lines)))
                              (define r (if (pair? (unbox left))
                                            (let ([h (car (unbox left))])
                                              (set-box! left (cdr (unbox left)))
                                              h)
                                            (list 200 "[]" '())))
                              (define body (cadr r))
                              (define extra (if (> (length r) 2) (caddr r) '()))
                              (fprintf o "HTTP/1.1 ~a X\r\ncontent-type: application/json\r\n" (car r))
                              (for ([kv (in-list extra)]) (fprintf o "~a: ~a\r\n" (car kv) (cdr kv)))
                              (fprintf o "content-length: ~a\r\nconnection: close\r\n\r\n~a"
                                       (bytes-length (string->bytes/utf-8 body)) body)
                              (flush-output o)
                              (with-handlers ([(lambda (_) #t) void]) (close-output-port o))
                              (with-handlers ([(lambda (_) #t) void]) (close-input-port i)))))
                  (loop))))))
  (define was (tmach-env "EGRESS_ALLOW"))
  ;; loopback, which #142 refuses unless the OPERATOR allowed that network —
  ;; which IS the customer's "feeds in our network" case
  (putenv "TMACH_EGRESS_ALLOW" "127.0.0.0/8")
  (dynamic-wind
   void
   (lambda () (proc (format "http://127.0.0.1:~a/repos/iotone/telemachus/issues" port) seen port))
   (lambda ()
     (putenv "TMACH_EGRESS_ALLOW" (or was ""))
     (kill-thread t)
     (tcp-close L))))

(define (issue n #:title [title #f] #:updated [updated "2026-10-23T08:42:26Z"]
               #:state [state "open"] #:repo [repo "iotone/telemachus"] #:labels [labels '("bug")]
               #:pr [pr #f] #:body [body "it broke"])
  (hasheq 'number n
          'title (or title (format "issue ~a" n))
          'state state
          'updated_at updated
          'body body
          'html_url (format "https://github.com/~a/issues/~a" repo n)
          'repository_url (format "https://api.github.com/repos/~a" repo)
          'labels (for/list ([l (in-list labels)]) (hasheq 'name l 'color "ededed"))
          'pull_request (if pr (hasheq 'url "x") 'null)))

(define (page . issues) (jsexpr->string issues))

(define (mk conn team user url #:slug [slug "gh"] #:kind [kind "github.issues"])
  (feed-create! conn #:team team #:user user #:slug slug #:name "GitHub" #:kind kind
                #:url url #:auth "bearer" #:auth-name #f #:secret "ghp_t0ken"
                #:created-by user))

;; ---- 1. an item becomes a document ------------------------------------------------------
(test-case "a pulled item is a repository object the feed's user can read"
  (define c (fresh))
  (define-values (uid tid) (owner c))
  (with-source (list (list 200 (page (issue 114) (issue 115 #:pr #t))))
    (lambda (url seen _p)
      (define fid (mk c tid uid url))
      (define s (poll-feed! c fid))
      (check-true (hash-ref s 'ok) (format "~a" (hash-ref s 'error)))
      (check-equal? (hash-ref s 'items) 2)
      (check-equal? (hash-ref s 'created) 2)
      (define p (user-principal c uid tid))
      (define objs (repo-list c p))
      (define keys (sort (for/list ([o (in-list objs)]) (hash-ref o 'key)) string<?))
      ;; FEED-16: the id carries its repository, or two repos' #114 would be one key
      (check-equal? keys (list "feeds/gh/iotone-telemachus-114.json"
                               "feeds/gh/iotone-telemachus-115.json"))
      (define one (for/first ([o (in-list objs)]
                              #:when (string=? (hash-ref o 'key) "feeds/gh/iotone-telemachus-114.json"))
                    o))
      ;; FEED-17: the payload is the source's own, and the TITLE is where search
      ;; can see it — `application/json` has no extractor, so without the
      ;; filename a pulled item is invisible to the only question anybody asks.
      (check-equal? (hash-ref one 'content_type) "application/json")
      (check-true (string-contains? (hash-ref one 'filename) "issue 114"))
      (check-true (string-contains? (hash-ref one 'filename) "#114"))
      (define-values (o in) (repo-open c p (hash-ref one 'id)))
      (define stored (bytes->jsexpr (port->bytes in)))
      (close-input-port in)
      (check-equal? (hash-ref stored 'number) 114)
      (check-equal? (hash-ref stored 'body) "it broke")
      ;; FEED-20: the attributes landed, which means the fields were declared
      (define attrs (hash-ref (repo-get c p (hash-ref one 'id)) 'attributes))
      (check-equal? (hash-ref attrs 'feed_slug) "gh")
      (check-equal? (hash-ref attrs 'feed_item_id) "114")
      (check-equal? (hash-ref attrs 'feed_state) "open")
      (check-equal? (hash-ref attrs 'feed_labels) "bug")
      (check-equal? (hash-ref attrs 'feed_repo) "iotone/telemachus")
      (check-equal? (hash-ref attrs 'feed_type) "issue")
      ;; the issues endpoint returns pull requests too, and they are KEPT and
      ;; marked rather than dropped — a PR is a work item in #114's sense
      (define pr (for/first ([o (in-list objs)]
                             #:when (string=? (hash-ref o 'key) "feeds/gh/iotone-telemachus-115.json")) o))
      (check-equal? (hash-ref (hash-ref (repo-get c p (hash-ref pr 'id)) 'attributes) 'feed_type)
                    "pull_request")
      ;; the credential went in the header the mode names, on the FIRST request
      (define hs (map string-downcase (car (unbox seen))))
      (check-true (and (member "authorization: Bearer ghp_t0ken" (car (unbox seen))) #t))
      ;; and GitHub's own requirements: a user-agent (it answers 403 without one)
      (check-true (for/or ([h (in-list hs)]) (string-prefix? h "user-agent:")))
      (check-true (for/or ([h (in-list hs)]) (string-contains? h "vnd.github+json")))))
  (close-db! c))

;; ---- 2. an unchanged item writes nothing ------------------------------------------------
(test-case "an unchanged item on the next poll writes no new version"
  (define c (fresh))
  (define-values (uid tid) (owner c))
  (with-source (list (list 200 (page (issue 114)))
                     (list 200 (page (issue 114)))
                     (list 200 (page (issue 114 #:title "issue 114 (edited)"
                                            #:updated "2026-10-24T09:00:00Z"))))
    (lambda (url seen _p)
      (define fid (mk c tid uid url))
      (define p (user-principal c uid tid))
      (check-equal? (hash-ref (poll-feed! c fid) 'created) 1)
      (define oid (hash-ref (car (repo-list c p)) 'id))
      (check-equal? (length (repo-versions c p oid)) 1)
      ;; the same item again: one comparison, no write
      (define s2 (poll-feed! c fid))
      (check-equal? (hash-ref s2 'unchanged) 1)
      (check-equal? (hash-ref s2 'created) 0)
      (check-equal? (hash-ref s2 'stored) 0)
      ;; THE ASSERTION THAT MATTERS. A poller that versioned every item would
      ;; still report `unchanged: 1` if nothing counted the versions.
      (check-equal? (length (repo-versions c p oid)) 1
                    "an unchanged item must not write a version")
      ;; a CHANGED item is a new version of the same object, not a second object
      (define s3 (poll-feed! c fid))
      (check-equal? (hash-ref s3 'updated) 1)
      (check-equal? (length (repo-list c p)) 1)
      (check-equal? (length (repo-versions c p oid)) 2)))
  (close-db! c))

;; ---- 3. the fetch is metered ------------------------------------------------------------
(test-case "feed.fetches is charged per REQUEST, not per item"
  (define c (fresh))
  (define-values (uid tid) (owner c))
  (with-source (list (list 200 (page (issue 114)) '()))
    (lambda (url seen port)
      (define fid (mk c tid uid url))
      (define s (poll-feed! c fid))
      (check-equal? (hash-ref s 'requests) 1)
      (check-equal? (hash-ref s 'items) 1)
      ;; read off the LEDGER: `quota-check` reports used: 0 with no limit set
      (check-equal? (quota-used c "team" tid "feed.fetches" "total") 1)
      (void (poll-feed! c fid))
      (check-equal? (quota-used c "team" tid "feed.fetches" "total") 2)))
  (close-db! c))

(test-case "pagination is one poll, and every page carries the credential"
  (define c (fresh))
  (define-values (uid tid) (owner c))
  (with-source
    (lambda (port)
      (list (list 200 (page (issue 114))
                  (list (cons "link" (format (string-append "<http://127.0.0.1:~a/repos/iotone/"
                                                            "telemachus/issues?page=2>; rel=\"next\", "
                                                            "<http://127.0.0.1:~a/p9>; rel=\"last\"")
                                             port port))))
            (list 200 (page (issue 115)) '())))
    (lambda (url seen _p)
      (define fid (mk c tid uid url))
      (define s (poll-feed! c fid))
      (check-true (hash-ref s 'ok) (format "~a" (hash-ref s 'error)))
      ;; ONE poll, two requests, both items
      (check-equal? (hash-ref s 'requests) 2)
      (check-equal? (hash-ref s 'items) 2)
      (check-equal? (hash-ref s 'created) 2)
      (check-equal? (length (repo-list c (user-principal c uid tid))) 2)
      (check-false (hash-ref s 'truncated))
      ;; THE ONE THAT WOULD BE SILENT: page two must carry the credential too. A
      ;; poller that applied auth only to the first request gets a 401 on page
      ;; two, which reads as the source rate-limiting us.
      (define second (cadr (unbox seen)))
      (check-true (and (member "authorization: Bearer ghp_t0ken" second) #t)
                  "every page carries the credential")
      (check-true (string-contains? (car second) "page=2"))
      ;; and it is charged per request
      (check-equal? (quota-used c "team" tid "feed.fetches" "total") 2)))
  (close-db! c))

;; ---- the cursor (FEED-19) ---------------------------------------------------------------
(test-case "the cursor advances only over items that landed, and the window stays inclusive"
  (define c (fresh))
  (define-values (uid tid) (owner c))
  (with-source (list (list 200 (page (issue 114 #:updated "2026-10-20T10:00:00Z")
                                     (issue 115 #:updated "2026-10-21T11:00:00Z")))
                     (list 200 (page (issue 115 #:updated "2026-10-21T11:00:00Z"))))
    (lambda (url seen _p)
      (define fid (mk c tid uid url))
      (void (poll-feed! c fid))
      (define f (feed-get c fid tid))
      ;; the NEWEST item that landed, as epoch seconds
      (check-equal? (hash-ref f 'cursor) (format "~a" (iso8601->epoch "2026-10-21T11:00:00Z")))
      ;; the second request asks the source for it, in the source's own spelling
      (void (poll-feed! c fid))
      (define req (cadr (unbox seen)))
      (define line (car req))
      (check-true (string-contains? line "since=2026-10-21T11%3A00%3A00Z")
                  (format "the second request must carry the cursor: ~a" line))
      ;; sort and direction too, or `since` cannot be walked forward
      (check-true (string-contains? line "sort=updated"))
      (check-true (string-contains? line "direction=asc"))))
  (close-db! c))

(test-case "a poll whose write is refused does not advance the cursor past it"
  (define c (fresh))
  (define-values (uid tid) (owner c))
  ;; a storage quota of one byte: the first `repo-put!` is refused
  (set-limit! c "team" tid "storage.bytes" 1 #:window "total")
  (with-source (list (list 200 (page (issue 114 #:updated "2026-10-20T10:00:00Z"))))
    (lambda (url seen _p)
      (define fid (mk c tid uid url))
      (define s (poll-feed! c fid))
      ;; REPORTED, not raised: a feed is expected to fail sometimes, and the
      ;; reason distinguishes the team's own budget from a source sending
      ;; something unreadable — the two have no remedy in common.
      (check-false (hash-ref s 'ok))
      (check-equal? (hash-ref s 'reason) "refused")
      (check-true (string-contains? (hash-ref s 'error) "storage quota"))
      ;; nothing landed, so there is nothing to advance to: the next poll reads
      ;; the same window and tries again
      (check-equal? (hash-ref (feed-get c fid tid) 'cursor) 'null)
      (check-equal? (length (repo-list c (user-principal c uid tid))) 0)))
  (close-db! c))

;; ---- what a failure is allowed to say ---------------------------------------------------
(test-case "a refusing source is recorded as host, path and status — never the body"
  (define c (fresh))
  (define-values (uid tid) (owner c))
  (with-source (list (list 401 "{\"message\":\"Bad credentials: ghp_t0ken\"}"))
    (lambda (url seen _p)
      (define fid (mk c tid uid url))
      (define s (poll-feed! c fid))
      (check-false (hash-ref s 'ok))
      (check-equal? (hash-ref s 'status) 401)
      (define f (feed-get c fid tid))
      (check-equal? (hash-ref f 'last_status) 401)
      (define e (hash-ref f 'last_error))
      (check-true (string? e))
      ;; FEED-6, and the one thing a source can do that the fetcher cannot
      ;; protect us from: its own error page quoting what we sent it. The body is
      ;; not stored at all.
      (check-false (string-contains? e "ghp_t0ken"))
      (check-false (string-contains? e "Bad credentials"))
      (check-true (string-contains? e "401"))
      (check-true (string-contains? e "127.0.0.1"))
      ;; CHARGED ANYWAY. Metering only successes would make a failing feed free
      ;; to hammer somebody's API, which is half of what FEED-9 is for.
      (check-equal? (quota-used c "team" tid "feed.fetches" "total") 1)
      ;; and nothing was stored
      (check-equal? (length (repo-list c (user-principal c uid tid))) 0)))
  (close-db! c))

(test-case "a body the adapter cannot read is a named refusal, not a guess"
  (define c (fresh))
  (define-values (uid tid) (owner c))
  (with-source (list (list 200 "{\"message\":\"Not Found\"}")
                     (list 200 "[{\"title\":\"no number\"}]"))
    (lambda (url seen _p)
      (define fid (mk c tid uid url))
      (define s (poll-feed! c fid))
      (check-false (hash-ref s 'ok))
      (check-equal? (hash-ref s 'reason) "unreadable")
      (check-true (string-contains? (hash-ref s 'error) "array of issues"))
      ;; FEED-16's refusal: an item with no repository would collide
      (define s2 (poll-feed! c fid))
      (check-false (hash-ref s2 'ok))
      (check-true (string-contains? (hash-ref s2 'error) "number"))))
  (close-db! c))

;; ---- the kinds, and the one with no adapter (FEED-15) -----------------------------------
(test-case "a kind with no adapter can be probed and refuses to be polled"
  (define c (fresh))
  (define-values (uid tid) (owner c))
  (check-true (and (member "http.json" (FEED-KINDS)) #t))
  (check-true (and (member "github.issues" (FEED-KINDS)) #t))
  ;; derived from the registry, so the two cannot disagree
  (check-false (and (member "http.json" (feed-adapter-kinds)) #t))
  (define fid (feed-create! c #:team tid #:user uid #:slug "plain" #:name #f #:kind "http.json"
                            #:url "https://src.example.com/api/items" #:auth "none"
                            #:auth-name #f #:secret #f #:created-by uid))
  (check-false (hash-ref (feed-get c fid tid) 'pollable))
  (define e (with-handlers ([exn:fail:user? exn-message]) (poll-feed! c fid) "no refusal"))
  (check-true (string-contains? e "probed but not polled"))
  ;; the message names what CAN be polled: an operator is one field away
  (check-true (string-contains? e "github.issues"))
  (close-db! c))

;; ---- a deleted item stays deleted -------------------------------------------------------
(test-case "deleting a pulled document is not undone by the next poll"
  (define c (fresh))
  (define-values (uid tid) (owner c))
  (with-source (list (list 200 (page (issue 114)))
                     (list 200 (page (issue 114))))
    (lambda (url seen _p)
      (define fid (mk c tid uid url))
      (define p (user-principal c uid tid))
      (void (poll-feed! c fid))
      (define oid (hash-ref (car (repo-list c p)) 'id))
      (void (repo-delete! c p oid))
      (define s (poll-feed! c fid))
      (check-equal? (hash-ref s 'skipped) 1)
      (check-equal? (hash-ref s 'created) 0)
      (check-equal? (length (repo-list c p)) 0
                    "a poll must not re-create a document somebody deleted")))
  (close-db! c))

;; ---- FEED-20's cap ----------------------------------------------------------------------
(test-case "the item fields are declared additively, and the forty-field cap is a refusal"
  (define c (fresh))
  (define-values (uid tid) (owner c))
  ;; the team's own label for a key the adapter also writes must survive
  (void (repo-fields-set! c tid (list (hasheq 'key "feed_state" 'label "Ticket state")
                                      (hasheq 'key "project" 'label "Project"))))
  (with-source (list (list 200 (page (issue 114))))
    (lambda (url seen _p)
      (define fid (mk c tid uid url))
      (void (poll-feed! c fid))
      (define defs (repo-fields c tid))
      (define (label k) (for/first ([f (in-list defs)] #:when (equal? (hash-ref f 'key) k))
                          (hash-ref f 'label)))
      (check-equal? (label "feed_state") "Ticket state" "a team's own label is not overwritten")
      (check-equal? (label "project") "Project" "a team's own field is not removed")
      (check-true (string? (label "feed_repo")) "the adapter's missing fields were added")))
  ;; and the cap: 36 of the team's own plus eight the adapter wants is over forty
  (define c2 (fresh))
  (define-values (uid2 tid2) (owner c2))
  (void (repo-fields-set! c2 tid2 (for/list ([i (in-range 36)])
                                    (hasheq 'key (format "own_~a" i) 'label (format "Own ~a" i)))))
  (with-source (list (list 200 (page (issue 114))))
    (lambda (url seen _p)
      (define fid (mk c2 tid2 uid2 url))
      (define e (with-handlers ([exn:fail:user? exn-message]) (poll-feed! c2 fid) "no refusal"))
      (check-true (string-contains? e "forty"))
      ;; refused BEFORE a request is made: a poll that fetched and then could not
      ;; store would have spent the team's fetch budget for nothing
      (check-equal? (quota-used c2 "team" tid2 "feed.fetches" "total") 0)))
  (close-db! c)
  (close-db! c2))

;; ---- the canonical payload (FEED-18) ----------------------------------------------------
(test-case "the stored bytes do not depend on this process's hash order"
  ;; THE TRAP THIS CASE EXISTS FOR: `hasheq` iteration order is not stable across
  ;; processes, so `jsexpr->string` of an item would hash differently in a
  ;; restarted server — and an unstable hash means every poll writes a new
  ;; version of every item and charges the team's storage for it.
  ;;
  ;; THE CONTROL FOR THIS ONE DOES NOT BITE, and that is worth writing down:
  ;; Racket's own `write-json` sorts keys in 9.3, so substituting
  ;; `jsexpr->string` for `canonical-json` leaves all 14 cases passing. The
  ;; literal below is what would catch a writer that stopped sorting; nothing
  ;; here can catch this module choosing to trust the writer again, which is why
  ;; `adapters.rkt` states the guarantee instead of inheriting it.
  (define a (hasheq 'b 2 'a 1 'c (hasheq 'z 1 'y 2) 'd (list (hasheq 'q 1 'p 2))))
  (define b (hasheq 'c (hasheq 'y 2 'z 1) 'd (list (hasheq 'p 2 'q 1)) 'a 1 'b 2))
  (check-equal? (canonical-json a) (canonical-json b))
  (check-equal? (canonical-json a) "{\"a\":1,\"b\":2,\"c\":{\"y\":2,\"z\":1},\"d\":[{\"p\":2,\"q\":1}]}")
  ;; and it is still the item's own fields: nothing dropped, added or reshaped
  (check-equal? (bytes->jsexpr (string->bytes/utf-8 (canonical-json a))) a))

(test-case "a link header is read for its rel, and an id is reduced to the key vocabulary"
  (check-equal? (link-rel (list (cons "link" "<https://h/p2>; rel=\"next\", <https://h/p9>; rel=\"last\""))
                          "next")
                "https://h/p2")
  (check-equal? (link-rel (list (cons "link" "<https://h/p9>; rel=last")) "next") #f)
  (check-equal? (link-rel '() "next") #f)
  ;; a repository name is somebody else's string, and it becomes part of a KEY
  (check-equal? (safe-id-part "IoTone/Telemachus") "iotone-telemachus")
  (check-equal? (safe-id-part "../../etc") "etc")
  (check-equal? (safe-id-part "") "x"))

(test-case "ISO-8601 in, epoch out, and back"
  (check-equal? (iso8601->epoch "1970-01-01T00:00:00Z") 0)
  (check-equal? (epoch->iso8601 0) "1970-01-01T00:00:00Z")
  (check-equal? (epoch->iso8601 (iso8601->epoch "2026-10-23T08:42:26Z")) "2026-10-23T08:42:26Z")
  ;; a value this cannot read answers #f rather than guessing a time — a wrong
  ;; cursor SKIPS items, which is the one failure a feed must not have
  (check-false (iso8601->epoch "last tuesday"))
  (check-false (iso8601->epoch #f)))

;; ---- a next page is a URL the SOURCE chose ------------------------------------------
(test-case "a next link to another origin is refused, and the credential is not sent there"
  ;; `feed-auth-apply` puts the credential on whatever URL the loop is given, and a
  ;; `Link: rel="next"` is the source's choice. The fetcher's redirect rule cannot
  ;; help: this is the first hop of a NEW request.
  (define c (fresh))
  (define-values (uid tid) (owner c))
  (with-source (list (list 200 "[]" '()))
    (lambda (b-url b-seen _bp)
      (with-source
        (lambda (_port)
          (list (list 200 (page (issue 114))
                      (list (cons "link" (format "<~a/p2>; rel=\"next\"" b-url))))))
        (lambda (url _seen _p)
          (define fid (mk c tid uid url))
          (define s (poll-feed! c fid))
          (check-false (hash-ref s 'ok))
          (check-equal? (hash-ref s 'reason) "cross-origin")
          ;; page one still landed and is still accounted for: the refusal stops
          ;; page two, it does not throw away what was already written
          (check-equal? (hash-ref s 'stored) 1)
          (check-equal? (length (repo-list c (user-principal c uid tid))) 1)
          ;; the other host was never contacted at all
          (check-equal? (unbox b-seen) '())
          ;; and the message names both places without a query string
          (check-true (string-contains? (hash-ref s 'error) "which is not"))))))
  (close-db! c))

(test-case "a RELATIVE next link is resolved against the page just read"
  ;; A source may answer with `Link: </page2>; rel="next"`. `fetch` refuses a
  ;; hostless URL, so the poll resolves it against the current page before
  ;; comparing origins — and reports a real cross-origin hop as one, rather than
  ;; calling every relative link cross-origin.
  (define c (fresh))
  (define-values (uid tid) (owner c))
  (with-source
    (lambda (port)
      (list (list 200 (page (issue 114)) (list (cons "link" "</issues?page=2>; rel=\"next\"")))
            (list 200 (page (issue 115)) '())))
    (lambda (url _seen port)
      (define fid (mk c tid uid url))
      (define s (poll-feed! c fid))
      (check-true (hash-ref s 'ok) (format "~a" (hash-ref s 'error)))
      (check-equal? (hash-ref s 'requests) 2)
      (check-equal? (hash-ref s 'stored) 2)
      ;; the resolved page two kept the host and the port
      (check-equal? (hash-ref s 'reason) 'null)))
  (close-db! c))
