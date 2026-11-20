#lang racket/base

;; Scheduled re-fetching of bookmarks (issue #191, RG-12; decisions RG-28…34).
;;
;; Every case drives `refetch-run!` with a scripted fetch, a scripted sleep and a
;; scripted clock, so the courtesy rules are observed without a socket and
;; without waiting. The egress policy itself is `research-tests.rkt`'s: this
;; file adds no fetch path, and the last case says so by checking that a run
;; with NO seam still refuses loopback.

(require rackunit db-kit/portable db-kit/migrate
         racket/list racket/string racket/tcp racket/file json
         "../domain/db/migrations.rkt"
         "db-fixture.rkt"
         "../domain/authz/authz.rkt"
         "../domain/repo/blobs.rkt"
         (only-in "../domain/repo/repo.rkt" repo-versions repo-get)
         (only-in "../domain/quota/quota.rkt" set-limit!)
         (only-in "../domain/sched/schedules.rkt" schedule-get schedule-delete! schedule-list)
         "../domain/research/research.rkt"
         "../domain/research/refetch.rkt")

(define BLOB-ROOT (make-temporary-file "telemachus-refetch-~a" 'directory))
(current-blob-root BLOB-ROOT)

(define (fresh) (define c (fresh-db #:migrate? #f)) (migrate! c all-migrations) c)

(define (owner conn)
  (bootstrap! conn #:username "alice" #:org-name "Acme" #:org-slug "acme"
              #:team-name "Eng" #:team-slug "eng"))

(define (member! c team name)
  (define u (create-user! c #:username name #:password "pw-fixture-12"))
  (add-member! c #:user u #:team team #:role "member")
  u)

(define DAY 86400)
(define HTML #"<html><body>Cephalopods have eight arms.</body></html>")

(define (bookmark! c u t url)
  (define id (research-create! c #:team t #:user u #:url url #:title "Page" #:note #f
                               #:created-by u))
  (check-true (string? id) (format "create answered ~a" id))
  id)

;; A first, person-initiated fetch, so there is an archive to be unchanged against.
(define (archive! c u t id #:body [body HTML] #:etag [etag "\"v1\""])
  (define out
    (research-fetch! c (user-principal c u t) (research-get c id t)
                     #:fetch (lambda (_url)
                               (values 200 `(("content-type" . "text/html") ("etag" . ,etag)) body))))
  (check-true (hash-ref out 'ok))
  out)

;; "The last fetch was `secs` ago."
(define (age! c id secs)
  (query-exec c "UPDATE research_sources SET fetched_epoch = ?, last_ok_epoch = ? WHERE id = ?"
              (- (current-seconds) secs) (- (current-seconds) secs) id))

;; A recording fetch seam: every (url . headers) it was handed, and what to answer.
(define (recorder answer)
  (define seen '())
  (values (lambda (url headers)
            (set! seen (append seen (list (cons url headers))))
            (answer url headers))
          (lambda () seen)))

(define (ok-200 [body HTML]) (lambda (_u _h) (values 200 '(("content-type" . "text/html")) body)))

(define (run c t fetch #:sleeps [sleeps #f])
  (refetch-run! c t #:fetch fetch
                #:sleep (lambda (s) (when sleeps (set-box! sleeps (append (unbox sleeps) (list s)))))
                ;; a clock that never moves, so the whole delay is always owed
                #:clock (lambda () 0.0)))

(test-case "off unless configured: nothing is scheduled, the report says so, and a run fetches nothing"
  (define c (fresh))
  (define-values (u t) (owner c))
  (define id (bookmark! c u t "https://example.test/a"))
  (age! c id (* 30 DAY))
  (define cfg (refetch-config c t))
  (check-false (hash-ref cfg 'enabled))
  (check-false (hash-has-key? cfg 'every_seconds))
  (check-equal? (hash-ref cfg 'min_seconds) 3600)
  (check-equal? (schedule-list c t) '())
  (define-values (f seen) (recorder (ok-200)))
  (define out (run c t f))
  (check-true (string? (hash-ref out 'skipped #f)))
  (check-equal? (seen) '()))

(test-case "the interval has a floor of an hour, a ceiling, and must be whole seconds"
  (check-false (refetch-problem #f))
  (check-false (refetch-problem 'null))
  (check-false (refetch-problem 3600))
  (check-true (string? (refetch-problem 3599)))
  (check-true (string? (refetch-problem 60)))
  (check-true (string? (refetch-problem 0)))
  (check-true (string? (refetch-problem -5)))
  (check-true (string? (refetch-problem 3600.5)))
  (check-true (string? (refetch-problem "86400")))
  (check-true (string? (refetch-problem (* 400 DAY)))))

(test-case "turning it on owns ONE schedule of the platform's kind with an empty payload; retuning keeps it; null removes it"
  (define c (fresh))
  (define-values (u t) (owner c))
  (define on (refetch-set! c t u DAY))
  (check-true (hash-ref on 'enabled))
  (check-equal? (hash-ref on 'every_seconds) DAY)
  (define scheds (schedule-list c t))
  (check-equal? (length scheds) 1)
  (check-equal? (hash-ref (car scheds) 'kind) REFETCH-KIND)
  (check-equal? (hash-ref (car scheds) 'payload) (hasheq))
  (check-equal? (hash-ref (car scheds) 'interval_seconds) DAY)
  (define sid (hash-ref (car scheds) 'id))
  ;; retune: the same row, not a second timer
  (define tuned (refetch-set! c t u (* 7 DAY)))
  (check-equal? (hash-ref tuned 'every_seconds) (* 7 DAY))
  (check-equal? (map (lambda (s) (hash-ref s 'id)) (schedule-list c t)) (list sid))
  (check-equal? (hash-ref (car (schedule-list c t)) 'interval_seconds) (* 7 DAY))
  ;; off
  (define off (refetch-set! c t u #f))
  (check-false (hash-ref off 'enabled))
  (check-equal? (schedule-list c t) '()))

(test-case "`enabled` is derived from the schedule: delete it from the schedules plane and the report turns off"
  (define c (fresh))
  (define-values (u t) (owner c))
  (refetch-set! c t u DAY)
  (schedule-delete! c (hash-ref (car (schedule-list c t)) 'id) t)
  (check-false (hash-ref (refetch-config c t) 'enabled))
  ;; and turning it on again makes a new one rather than failing on the stale id
  (check-true (hash-ref (refetch-set! c t u DAY) 'enabled))
  (check-equal? (length (schedule-list c t)) 1))

(test-case "a run takes what is at least one interval old, stalest first, and leaves the rest alone"
  (define c (fresh))
  (define-values (u t) (owner c))
  (refetch-set! c t u DAY)
  (define fresh-one (bookmark! c u t "https://a.test/fresh"))
  (define old (bookmark! c u t "https://b.test/old"))
  (define older (bookmark! c u t "https://c.test/older"))
  (define never (bookmark! c u t "https://d.test/never"))
  (age! c fresh-one 60)
  (age! c old (* 2 DAY))
  (age! c older (* 9 DAY))
  (define-values (f seen) (recorder (ok-200)))
  (define out (run c t f))
  (check-equal? (map car (seen))
                '("https://d.test/never" "https://c.test/older" "https://b.test/old"))
  (check-equal? (hash-ref out 'due) 3)
  (check-equal? (hash-ref out 'changed) 3)
  (check-false (hash-ref out 'truncated))
  (check-equal? (hash-ref out 'stopped) 'null)
  ;; the second run finds nothing due
  (define-values (f2 seen2) (recorder (ok-200)))
  (check-equal? (hash-ref (run c t f2) 'due) 0)
  (check-equal? (seen2) '()))

(test-case "a scheduled request is conditional, and a 304 is a success that stores nothing"
  (define c (fresh))
  (define-values (u t) (owner c))
  (refetch-set! c t u DAY)
  (define id (bookmark! c u t "https://example.test/page"))
  (define first (archive! c u t id #:etag "\"v1\""))
  (age! c id (* 3 DAY))
  (define before (research-get c id t))
  (define-values (f seen) (recorder (lambda (_u _h) (values 304 '() #""))))
  (define out (run c t f))
  (check-equal? (cdr (assoc "If-None-Match" (cdar (seen)))) "\"v1\"")
  (check-equal? (hash-ref out 'unchanged) 1)
  (check-equal? (hash-ref out 'failed) 0)
  (define after (research-get c id t))
  (check-equal? (hash-ref after 'last_status) 304)
  (check-equal? (hash-ref after 'last_error) 'null)
  (check-true (hash-ref after 'archived))
  ;; "it last worked at" moved; the digest and the archive did not
  (check-true (> (hash-ref after 'last_ok_epoch) (hash-ref before 'last_ok_epoch)))
  (check-equal? (hash-ref after 'content_sha256) (hash-ref before 'content_sha256))
  (check-equal? (length (repo-versions c (user-principal c u t) (hash-ref first 'object_id))) 1))

(test-case "a 304 nobody asked for is still a failure: a bookmark with no archive sends no condition"
  (define c (fresh))
  (define-values (u t) (owner c))
  (refetch-set! c t u DAY)
  (define id (bookmark! c u t "https://example.test/never-archived"))
  (define-values (f seen) (recorder (lambda (_u _h) (values 304 '() #""))))
  (define out (run c t f))
  (check-equal? (cdar (seen)) '())
  (check-equal? (hash-ref out 'failed) 1)
  (check-false (hash-ref (research-get c id t) 'archived))
  (check-true (string? (hash-ref (research-get c id t) 'last_error))))

(test-case "unchanged bytes write no new version on the timer; changed bytes write one; a person's fetch still writes one"
  (define c (fresh))
  (define-values (u t) (owner c))
  (define p (user-principal c u t))
  (refetch-set! c t u DAY)
  (define id (bookmark! c u t "https://example.test/stable"))
  (define first (archive! c u t id))
  (define obj (hash-ref first 'object_id))
  (age! c id (* 2 DAY))
  (define out1 (run c t (ok-200 HTML)))
  (check-equal? (hash-ref out1 'unchanged) 1)
  (check-equal? (length (repo-versions c p obj)) 1)
  (age! c id (* 2 DAY))
  (define out2 (run c t (ok-200 #"<html>nine arms now</html>")))
  (check-equal? (hash-ref out2 'changed) 1)
  (check-equal? (length (repo-versions c p obj)) 2)
  ;; the person-initiated path is unchanged by this slice: no condition, and a
  ;; version row even for identical bytes
  (define-values (f seen) (recorder (ok-200 #"<html>nine arms now</html>")))
  (define manual (research-fetch! c p (research-get c id t) #:fetch f))
  (check-equal? (cdar (seen)) '())
  (check-true (hash-ref manual 'unchanged))
  (check-equal? (length (repo-versions c p obj)) 3))

(test-case "two requests to one host are spaced, another host is not made to wait, and one host gets a few per run"
  (define c (fresh))
  (define-values (u t) (owner c))
  (refetch-set! c t u DAY)
  (for ([i (in-range 7)]) (bookmark! c u t (format "https://busy.test/p~a" i)))
  (bookmark! c u t "https://quiet.test/one")
  (define sleeps (box '()))
  (define-values (f seen) (recorder (ok-200)))
  (define out (run c t f #:sleeps sleeps))
  (define hosts (map (lambda (s) (cadr (regexp-match #rx"^https://([^/]+)/" (car s)))) (seen)))
  (check-equal? (length (filter (lambda (h) (string=? h "busy.test")) hosts)) REFETCH-HOST-MAX)
  (check-equal? (length (filter (lambda (h) (string=? h "quiet.test")) hosts)) 1)
  ;; one wait before each request to busy.test after its first, and none for quiet.test
  (check-equal? (length (unbox sleeps)) (sub1 REFETCH-HOST-MAX))
  (check-true (andmap (lambda (s) (= s REFETCH-HOST-DELAY)) (unbox sleeps)))
  (check-equal? (hash-ref out 'deferred) 2)
  (check-true (hash-ref out 'truncated))
  ;; the deferred ones are still the stalest, so the next run reaches them
  (define-values (f2 seen2) (recorder (ok-200)))
  (run c t f2)
  (check-equal? (length (seen2)) 2))

(test-case "a run sends at most a batch, and says there was more"
  (define c (fresh))
  (define-values (u t) (owner c))
  (refetch-set! c t u DAY)
  (for ([i (in-range (+ REFETCH-BATCH 4))]) (bookmark! c u t (format "https://h~a.test/" i)))
  (define-values (f seen) (recorder (ok-200)))
  (define out (run c t f))
  (check-equal? (length (seen)) REFETCH-BATCH)
  (check-true (hash-ref out 'truncated)))

(test-case "the budget is charged per request and a spent one stops the run without sending the next"
  (define c (fresh))
  (define-values (u t) (owner c))
  (refetch-set! c t u DAY)
  (for ([i (in-range 4)]) (bookmark! c u t (format "https://q~a.test/" i)))
  (set-limit! c "team" t RESEARCH-DIM 2 #:window "day")
  (define-values (f seen) (recorder (ok-200)))
  (define out (run c t f))
  (check-equal? (length (seen)) 2)
  (check-equal? (hash-ref out 'stopped) "quota")
  (check-true (hash-ref out 'truncated)))

(test-case "each fetch acts as the bookmark's own user, and a bookmark whose user has left is not fetched"
  (define c (fresh))
  (define-values (alice t) (owner c))
  (define bob (member! c t "bob"))
  (define carol (member! c t "carol"))
  (refetch-set! c t alice DAY)
  (define b (bookmark! c bob t "https://bob.test/page"))
  (define k (bookmark! c carol t "https://carol.test/page"))
  (query-exec c "UPDATE memberships SET status = 'inactive' WHERE user_id = ? AND team_id = ?" carol t)
  (define-values (f seen) (recorder (ok-200)))
  (define out (run c t f))
  (check-equal? (map car (seen)) '("https://bob.test/page"))
  (check-equal? (hash-ref out 'no_user) 1)
  (check-false (hash-ref (research-get c k t) 'archived))
  ;; the archive is bob's document, though alice turned the timer on
  (define obj (repo-get c (user-principal c bob t) (hash-ref (research-get c b t) 'object_id)))
  (check-equal? (hash-ref obj 'owner_user_id) bob))

(test-case "another team's bookmarks are not this team's run"
  (define c (fresh))
  (define-values (u t) (owner c))
  (define t2 (create-team! c #:name "Ops" #:slug "ops" #:org (team-org c t)))
  (add-member! c #:user u #:team t2 #:role "owner")
  (refetch-set! c t u DAY)
  (bookmark! c u t2 "https://other.test/page")
  (define-values (f seen) (recorder (ok-200)))
  (check-equal? (hash-ref (run c t f) 'due) 0)
  (check-equal? (seen) '()))

(test-case "one audit entry per run, in the team's own trail, with counts and no URL"
  (define c (fresh))
  (define-values (u t) (owner c))
  (refetch-set! c t u DAY)
  (bookmark! c u t "https://secret-reading.test/a?token=abc")
  (run c t (ok-200))
  (define rows (query-rows c "SELECT team_id, actor_type, meta FROM audit_log WHERE action = 'research.refetched'"))
  (check-equal? (length rows) 1)
  (check-equal? (vector-ref (car rows) 0) t)
  (check-equal? (vector-ref (car rows) 1) "system")
  (define meta (vector-ref (car rows) 2))
  (check-false (regexp-match? #rx"secret-reading|token" meta))
  (check-equal? (hash-ref (string->jsexpr meta) 'changed) 1)
  ;; a run with nothing due writes nothing
  (run c t (ok-200))
  (check-equal? (query-value c "SELECT COUNT(*) FROM audit_log WHERE action = 'research.refetched'") 1))

(test-case "the timer adds no fetch path: with no seam, a loopback bookmark is refused by the same egress policy"
  (define c (fresh))
  (define-values (u t) (owner c))
  (refetch-set! c t u DAY)
  (define L (tcp-listen 0 8 #t "127.0.0.1"))
  (define-values (_h port _rh _rp) (tcp-addresses L #t))
  (define id (bookmark! c u t (format "http://127.0.0.1:~a/" port)))
  (define out (refetch-run! c t))
  (tcp-close L)
  (check-equal? (hash-ref out 'failed) 1)
  (define row (research-get c id t))
  (check-false (hash-ref row 'archived))
  (check-true (string? (hash-ref row 'last_error))))
