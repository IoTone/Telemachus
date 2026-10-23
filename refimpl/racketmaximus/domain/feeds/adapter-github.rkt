#lang racket/base

;; domain/feeds/adapter-github.rkt — `github.issues` (#114 slice 4, FEED-16).
;;
;; The first adapter, because it is the first source the owner named. It reads
;; GitHub's issues REST endpoint — `/repos/:owner/:repo/issues`, the search API,
;; or an org-wide listing — and turns each issue into one repository object.
;;
;; THREE THINGS ABOUT THIS WIRE THAT ARE EASY TO GET WRONG, all of them paid for
;; here rather than by the next adapter:
;;
;;   • GITHUB REFUSES A REQUEST WITH NO USER-AGENT (403, with a body explaining
;;     it). `fetch` sends the headers it is given and adds none of its own, so
;;     the adapter sends one. A 403 on a perfectly good token reads as a
;;     permission problem, which is the wrong thing to go and check.
;;   • THE DEFAULT SORT IS `created`, DESCENDING, which cannot be walked
;;     incrementally: `since` filters by `updated_at`, so without
;;     `sort=updated&direction=asc` the first page of a busy repository is the
;;     newest issues and the cursor would jump past everything older that had
;;     just been touched. The adapter sets both.
;;   • THE ISSUES ENDPOINT RETURNS PULL REQUESTS TOO. They are not dropped —
;;     a PR is a work item in exactly the sense #114 means — but each item
;;     carries `feed_type`, so a trigger or slice 5's queue can tell them apart
;;     without parsing the payload.

(require json racket/string racket/list net/url
         "adapters.rkt")

(provide github-issues-adapter install-github-adapter!)

;; FEED-20: what this adapter writes beyond `FEED-ITEM-FIELDS`. Four, which with
;; the core four is eight of LAY-4's forty — stated because that cap is a real
;; cost to the team and the poll refuses rather than truncating.
(define GITHUB-FIELDS
  (list (hasheq 'key "feed_state"  'label "State")
        (hasheq 'key "feed_labels" 'label "Labels")
        (hasheq 'key "feed_repo"   'label "Repository")
        (hasheq 'key "feed_type"   'label "Item type")))

(define PER-PAGE "100")

;; Replace a query parameter rather than appending one: the operator's URL may
;; carry `?state=all&labels=bug`, which must survive, while a `since` they typed
;; by hand must NOT — the cursor is this instance's position and two of them
;; would walk different windows.
(define (query-set u . kvs)
  (define parsed (string->url u))
  (define drop (for/list ([kv (in-list kvs)] #:when #t) (car kv)))
  (define kept (for/list ([q (in-list (url-query parsed))]
                          #:unless (memq (car q) drop))
                 q))
  (url->string (make-url (url-scheme parsed) (url-user parsed) (url-host parsed)
                         (url-port parsed) (url-path-absolute? parsed) (url-path parsed)
                         (append kept (for/list ([kv (in-list kvs)] #:when (cdr kv)) kv))
                         (url-fragment parsed))))

(define HEADERS
  (list (cons "accept" "application/vnd.github+json")
        (cons "x-github-api-version" "2022-11-28")
        ;; not decoration: see the header comment
        (cons "user-agent" "Telemachus-feeds")))

;; The cursor is stored as epoch seconds (the platform's own form); GitHub wants
;; ISO-8601, so the conversion lives here — which is the point of `prepare`
;; taking the cursor rather than the poll formatting it for every source.
(define (gh-prepare feed cursor)
  (define since
    (and cursor (string->number (format "~a" cursor))
         (epoch->iso8601 (string->number (format "~a" cursor)))))
  (values (query-set (hash-ref feed 'url)
                     (cons 'per_page PER-PAGE)
                     (cons 'sort "updated")
                     (cons 'direction "asc")
                     (cons 'since since))
          HEADERS))

(define (owner-repo item)
  ;; `repository_url` is `https://api.github.com/repos/<owner>/<repo>` and is
  ;; present on an issue from every one of the three endpoints. Falling back to
  ;; `html_url` covers a response shape that omits it; falling back to neither
  ;; is a refusal, because an id with no repository in it would collide the
  ;; moment the feed is a search (FEED-16).
  (define (from-path s)
    (and (string? s)
         (let ([segs (filter (lambda (x) (not (string=? x "")))
                             (string-split (format "~a" s) "/"))])
           (let loop ([l segs])
             (cond
               [(or (null? l) (null? (cdr l))) #f]
               [(and (member (car l) '("repos" "repo")) (>= (length (cdr l)) 2))
                (cons (cadr l) (caddr l))]
               ;; an html_url is `https://github.com/<owner>/<repo>/issues/<n>`
               [(and (equal? (car l) "github.com") (>= (length (cdr l)) 2))
                (cons (cadr l) (caddr l))]
               [else (loop (cdr l))])))))
  (or (from-path (hash-ref item 'repository_url #f))
      (from-path (hash-ref item 'html_url #f))))

(define (gh-parse body headers request-url)
  (define parsed
    (with-handlers ([exn:fail? (lambda (_)
                                 (raise-user-error
                                  'feed "github.issues: the response did not parse as JSON"))])
      (bytes->jsexpr body)))
  ;; An OBJECT here is GitHub telling us something — `{"message": "Bad
  ;; credentials"}` on a 401 it already reported, or a search result wrapping
  ;; its items in `items`. The search shape is accepted because the owner's use
  ;; case ("issues across our repos") is a search; anything else is a REFUSAL
  ;; rather than a guess at where the items are (FEED-15).
  (define items
    (cond
      [(list? parsed) parsed]
      [(and (hash? parsed) (list? (hash-ref parsed 'items #f))) (hash-ref parsed 'items)]
      [else
       (raise-user-error
        'feed "github.issues: expected an array of issues~a"
        (if (and (hash? parsed) (string? (hash-ref parsed 'message #f)))
            (format ", and the source said: ~a" (hash-ref parsed 'message))
            ""))]))
  (values
   (for/list ([it (in-list items)] #:when (hash? it))
     (define n (hash-ref it 'number #f))
     (define or* (owner-repo it))
     (unless (and (exact-integer? n) or*)
       (raise-user-error 'feed (string-append
                                "github.issues: an item carries no `number` and `repository_url` — "
                                "without both, two issues from different repositories would be "
                                "stored over one key")))
     (define repo (format "~a/~a" (car or*) (cdr or*)))
     (define labels (for/list ([l (in-list (let ([v (hash-ref it 'labels '())]) (if (list? v) v '())))]
                               #:when (hash? l))
                      (format "~a" (hash-ref l 'name ""))))
     (define updated (hash-ref it 'updated_at #f))
     (feed-item
      (format "~a-~a-~a" (safe-id-part (car or*)) (safe-id-part (cdr or*)) n)
      (let ([t (format "~a" (hash-ref it 'title ""))])
        (if (string=? t "") (format "~a#~a" repo n) (format "~a#~a ~a" repo n t)))
      it
      (iso8601->epoch (and (string? updated) updated))
      (hasheq 'feed_item_id (format "~a" n)
              'feed_url (format "~a" (hash-ref it 'html_url ""))
              'feed_updated (if (string? updated) updated "")
              'feed_state (format "~a" (hash-ref it 'state ""))
              'feed_labels (string-join labels ",")
              'feed_repo repo
              ;; `'null` IS TRUTHY IN RACKET — the trap recorded in CLAUDE.md,
              ;; here on a key a proxy may send as JSON null rather than omit. A
              ;; PR carries an OBJECT, so that is what is asked for; anything
              ;; else, absent or null, is an issue.
              'feed_type (if (hash? (hash-ref it 'pull_request #f)) "pull_request" "issue"))))
   ;; One poll walks the `next` links, so a repository with 4,000 open issues is
   ;; pages rather than one 8 MiB response — bounded by the poll's own page cap.
   (link-rel headers "next")))

(define github-issues-adapter
  (feed-adapter "github.issues" "GitHub issues" gh-prepare gh-parse GITHUB-FIELDS))

(define (install-github-adapter!) (register-feed-adapter! github-issues-adapter))
