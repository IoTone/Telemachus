#lang racket/base

;; domain/events/describe.rkt — ONE phrasing of "what happened", and where to go
;; and look at it.
;;
;; WHY THIS IS CORE AND NOT IN EITHER NOTIFIER. `plugins/matrix/main.rkt` has
;; composed a line out of an `emit!` payload since #133, and the email notifier
;; needs the same sentence with a subject and a link around it. Two copies of the
;; event → phrase mapping is `executor-can-run?`'s drift in the place it is least
;; visible: `EVENTS` is a closed vocabulary that grows, and the eighth member
;; would get a Matrix line and no email subject, or the reverse, with nothing
;; failing either way. So the mapping is here, with two askers — the move
;; `repo-fields-declare!` made when the classifier became `poll.rkt`'s second
;; asker, and `query-set` when the second feed adapter wanted it.
;;
;; A plugin may require a core module; core may not require a plugin. So the
;; shared half had to come up here rather than Matrix exporting it.
;;
;; IT CARRIES IDS, A STATUS AND A LINK — NEVER CONTENT (MTX-8, MAIL-9). The
;; payloads this reads are already built to that rule — `repo.rkt` leaves the
;; object KEY out deliberately, because a key routinely carries a person's name,
;; and `review.rkt` sends the verdict and not the rationale. This module must not
;; be the place that reintroduces any of it: it is handed `data` and may not go
;; to the database for more.
;;
;; THE WORKFLOW SLUG IS THE ONE WORD THAT RIDES ALONG, and MTX-8 earned it: a
;; team's own name for a process is not document content, and without it "run
;; 3f2a finished" tells nobody which thing finished.

(require racket/string
         (only-in "events.rkt" EVENTS event?))

(provide event-subject event-phrase event-console-path CONSOLE-PATHS
         short-id)

;; A uuid is 36 characters and an inbox subject has about 50 usable ones, so the
;; id is shortened — to EIGHT, which is `fleet.rkt`'s and the Matrix line's own
;; figure. It is a label, never something to look up by: the link carries the
;; whole id.
(define (short-id s)
  (if (and (string? s) (> (string-length s) 12)) (substring s 0 8) s))

(define (data-ref data k)
  (let ([v (hash-ref data k #f)]) (and (string? v) (not (string=? v "")) v)))

;; What the thing IS — "run 3f2a", "document 91bc". Separate from the verb
;; because a subject line wants them in one order and a chat line in another.
(define (event-noun data)
  (cond
    [(data-ref data 'run_id) => (lambda (v) (format "run ~a" (short-id v)))]
    [(data-ref data 'job_id) => (lambda (v) (format "job ~a" (short-id v)))]
    [(data-ref data 'object_id) => (lambda (v) (format "document ~a" (short-id v)))]
    [(data-ref data 'review_id) => (lambda (v) (format "review ~a" (short-id v)))]
    [else "something"]))

(define (event-verb event data)
  (cond
    [(equal? event "run.completed") "finished"]
    [(equal? event "run.failed") "FAILED"]
    [(equal? event "job.completed") "finished"]
    [(equal? event "object.created") "arrived"]
    [(equal? event "object.deleted") "was deleted"]
    [(equal? event "review.decided")
     (format "was decided: ~a" (or (data-ref data 'verdict) "?"))]
    [(equal? event "ping") "— this is a test notification from TMach"]
    [else event]))

;; The workflow slug, in parentheses, or "". A team's own word (MTX-8).
(define (event-qualifier data)
  (let ([s (data-ref data 'workflow)]) (if s (format " (~a)" s) "")))

;; "run 3f2a (index-documents) finished" — the sentence both notifiers are about.
;; A SUBJECT LINE AND A BODY GO THROUGH THE SAME COMPOSER (MAIL-9), so a subject
;; cannot leak what a body refuses; this is that composer's one source of words.
(define (event-subject event data)
  (string-append (event-noun data) (event-qualifier data) " " (event-verb event data)))

;; Matrix's line: the event name, then the sentence, then the URL. Kept in this
;; shape because it is what that plugin has sent for a year and a room's history
;; should stay greppable.
(define (event-phrase event data #:url [url #f])
  (string-append event ": " (event-subject event data)
                 (if url (string-append " — " url) "")))

;; ---- where a person goes to look at it ----------------------------------------
;;
;; THE `url` IN AN `emit!` PAYLOAD IS AN API PATH, AND THAT IS RIGHT FOR A
;; WEBHOOK AND USELESS TO A PERSON. #85 r2's whole model is that the payload
;; carries ids and the RECEIVER fetches the rest under its own credentials — so
;; `/api/runs/<id>` is what a machine wants. A notification is read by somebody in
;; an inbox, and handing them a URL that answers JSON is a link that does not work.
;;
;; THIS IS A SECOND RULE DERIVED FROM JAVASCRIPT, AND IT IS GATED FOR THAT
;; REASON. The grammar lives in `static/console/19-route.js` (#230) and a rename
;; there would silently break every notification link in every message with
;; nothing failing — so `test/console-tests.rkt` asserts, in both directions, that
;; every pattern below really is a route the console parses. #110 r6's `src`-tags
;; rule, applied to a link.
(define CONSOLE-PATHS
  (list (cons "run.completed"   "#/workflows/runs/~a")
        (cons "run.failed"      "#/workflows/runs/~a")
        (cons "object.created"  "#/repository/~a")
        ;; A DELETED DOCUMENT HAS NO PAGE, so the link is the tab rather than a
        ;; detail view of something that is gone — which would render an empty
        ;; panel and read as a broken link.
        (cons "object.deleted"  "#/repository")
        (cons "job.completed"   "#/jobs")
        ;; The review QUEUE, not one review: the console has no deep link for a
        ;; single decision, and inventing one here would be a path nothing parses.
        (cons "review.decided"  "#/reviews")
        (cons "ping"            "#/jobs")))

;; -> a fragment path, or #f when there is nothing to link to. `base` is the
;; transport's `base_url`; with none configured there is no link, because a
;; relative fragment in an email is not a link at all.
(define (event-console-path event data)
  (define pat (let ([kv (assoc event CONSOLE-PATHS)]) (and kv (cdr kv))))
  (cond
    [(not pat) #f]
    [(not (regexp-match? #px"~a" pat)) pat]
    [else
     (define id (or (data-ref data 'run_id) (data-ref data 'object_id)
                    (data-ref data 'job_id) (data-ref data 'review_id)))
     ;; An id-shaped pattern with no id is NOT silently turned into a tab link:
     ;; it means the payload changed shape, and a link to the wrong place is
     ;; worse than none.
     (and id (format pat id))]))
