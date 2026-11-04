#lang racket/base

;; server/api/research.rkt — the research archive (#191 slice 1, RG-1/-3/-11).

(provide ep-research-list ep-research-create ep-research-get ep-research-delete
         ep-research-fetch)

(require db-kit/portable
         web-kit
         json
         racket/string
         (only-in "../../domain/authz/authz.rkt" audit! principal-team-id principal-user-id
                  require-perm)
         (only-in "../../domain/net/fetch.rkt" safe-url)
         (only-in "../../domain/research/research.rkt"
                  canonical-url research-problem research-create! research-list research-get
                  research-delete! research-fetch!)
         "../admission.rkt"
         "../kit.rkt")

(define (str b k [d #f])
  (let ([v (hash-ref b k 'missing)])
    (cond [(eq? v 'missing) d]
          [(eq? v 'null) #f]
          [(not v) #f]
          [else (format "~a" v)])))

;; The audit meta carries `safe-url`, NEVER the URL as given. The audit log is
;; hash-chained, exported off the box and deliberately kept through an erasure
;; (DEL-7), so it outlives every other copy of anything written into it — and
;; while this surface refuses userinfo at the write, a URL's QUERY is routinely
;; where a session id or a one-time token lives on somebody else's site.
(define (research-meta row extra)
  (jsexpr->string (for/fold ([h (hasheq 'url (safe-url (hash-ref row 'url))
                                        'canon (safe-url (hash-ref row 'url_canon))
                                        'user_id (hash-ref row 'user_id))])
                            ([(k v) (in-hash extra)])
                    (hash-set h k v))))

(define (ep-research-list req)
  (with-auth req (lambda (p)
    (require-perm db-conn p "research:use")
    (json-response (hasheq 'sources (research-list db-conn (principal-team-id p)))))))

(define (ep-research-get req id)
  (with-auth req (lambda (p)
    (require-perm db-conn p "research:use")
    (define row (research-get db-conn id (principal-team-id p)))
    ;; Another team's id is a 404, not a 403: whether this instance holds a
    ;; bookmark is not a question to answer to somebody it does not belong to.
    (if row (json-response row) (err "no such bookmark" 404)))))

;; `fetch` defaults to TRUE, which is the one place this surface differs in shape
;; from the feed plane, and it differs on purpose. A feed is CONFIGURATION that
;; an operator probes once and then polls on a timer; a bookmark exists because
;; somebody is reading a page NOW and #191's motive is that the page will not
;; keep. A create that only wrote a row would make the archive a second call that
;; the one case this feature is for — capture it before it rots — depends on
;; somebody remembering to make.
(define (fetch-wanted? b)
  (define v (hash-ref b 'fetch 'missing))
  (cond [(eq? v 'missing) #t]
        [(eq? v #f) #f]
        [(eq? v 'null) #f]
        [(equal? v "false") #f]
        [else #t]))

;; THE BUDGET IS THE DOMAIN'S (FEED-9, `research-fetch!`), charged per request and
;; before it. What is left here is rendering the refusal: a 429 with the tier
;; that said no and `resets_at`, which is the shape issue #55 settled — "come
;; back then" rather than "come back later".
;;
;; `research.fetches` is in `QUOTA-HOLD-DIMS`, so where an operator HAS set a
;; limit, reaching it also holds the team's scheduler queue rather than failing
;; work — which is what RG-12's scheduled re-fetch will need, and why the
;; dimension is wired now rather than when that lands.
(define (fetch-response row-thunk out)
  (if (equal? (hash-ref out 'reason #f) "quota")
      (quota-429 (hash-ref out 'quota) "research.fetches")
      (json-response (hasheq 'source (row-thunk) 'fetched out))))

(define (ep-research-create req)
  (with-auth req (lambda (p)
    (require-perm db-conn p "research:use")
    (define b (read-json-body req))
    (define url (or (str b 'url) ""))
    (define title (str b 'title))
    (define note (str b 'note))
    (define problem (research-problem #:url url #:title title #:note note))
    (cond
      [problem (err problem 400)]
      [else
       (define r (research-create! db-conn
                                   #:team (principal-team-id p)
                                   #:user (principal-user-id p)
                                   #:url url #:title title #:note note
                                   #:created-by (principal-user-id p)))
       (cond
         [(eq? r 'no-such-user)
          ;; The caller's own membership. Reachable by an OPERATOR, whose
          ;; `can?` passes every team-tier permission while they hold no
          ;; membership row in the team they are acting for — and a bookmark
          ;; whose `user_id` is not a member of its team would be a standing
          ;; grant nobody could see in the membership list (FEED-2's rule).
          (err "a bookmark acts as a member of its team, and you are not one — act as a team you belong to" 400)]
         [(eq? r 'duplicate-url)
          (err (format "this team has already bookmarked that URL (canonically `~a`)"
                       (canonical-url url))
               409)]
         [else
          (define row (research-get db-conn r (principal-team-id p)))
          (audit! db-conn #:action "research.bookmarked" #:result "ok"
                  #:actor-id (principal-user-id p)
                  #:team-id (principal-team-id p)
                  #:resource-type "research" #:resource-id r
                  #:meta (research-meta row (hasheq)))
          (cond
            [(not (fetch-wanted? b))
             (json-response (hasheq 'source row 'fetched 'null) #:code 201)]
            [else
             (define out (research-fetch! db-conn p row))
             (cond
               [(equal? (hash-ref out 'reason #f) "quota")
                ;; The BOOKMARK is made and the archive is not, so the honest
                ;; answer is the quota's: a 429 naming the tier and when it
                ;; resets. The row is there to re-fetch from, which is what the
                ;; `fetch` route is for.
                (quota-429 (hash-ref out 'quota) "research.fetches")]
               [else
                ;; THE ROW SURVIVES A FAILED FETCH, and the 201 is about the
                ;; bookmark rather than about the page: a site that is down today
                ;; is the ordinary case this feature exists for, and losing the
                ;; bookmark because of it would be the one outcome nobody asked
                ;; for. What happened to the fetch is in `fetched`.
                (json-response (hasheq 'source (research-get db-conn r (principal-team-id p))
                                       'fetched out)
                               #:code 201)])])])]))))

(define (ep-research-delete req id)
  (with-auth req (lambda (p)
    (require-perm db-conn p "research:use")
    (define row (research-get db-conn id (principal-team-id p)))
    (cond
      [(not row) (err "no such bookmark" 404)]
      [else
       (research-delete! db-conn id (principal-team-id p))
       (audit! db-conn #:action "research.forgotten" #:result "ok"
               #:actor-id (principal-user-id p)
               #:team-id (principal-team-id p)
               #:resource-type "research" #:resource-id id
               #:meta (research-meta row (hasheq 'object_id (hash-ref row 'object_id))))
       (json-response (hasheq 'ok #t))]))))

(define (ep-research-fetch req id)
  (with-auth req (lambda (p)
    (require-perm db-conn p "research:use")
    (define row (research-get db-conn id (principal-team-id p)))
    (cond
      [(not row) (err "no such bookmark" 404)]
      [else
       (define out (research-fetch! db-conn p row))
       (audit! db-conn #:action "research.fetched"
               #:result (if (hash-ref out 'ok) "ok" "refused")
               #:actor-id (principal-user-id p)
               #:team-id (principal-team-id p)
               #:resource-type "research" #:resource-id id
               #:meta (research-meta row (hasheq 'status (hash-ref out 'status 'null)
                                                 'reason (hash-ref out 'reason 'null))))
       ;; 200 even when the SOURCE refused, which is the feed probe's own posture:
       ;; the fetch RAN, and whether somebody else's server answered is in the
       ;; body. A 502 here would be this instance reporting somebody else's
       ;; failure as its own. A refusal by QUOTA is different in kind — this
       ;; instance declined — and gets its 429.
       (fetch-response (lambda () (research-get db-conn id (principal-team-id p))) out)]))))
