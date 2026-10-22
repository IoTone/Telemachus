#lang racket/base

;; domain/events/events.rkt — ONE seam for "something happened" (#85).
;;
;; Five places in the platform settle something a subscriber cares about: a
;; workflow run, a scheduler job, a repository object arriving or going, and a
;; review decision. Before this they had nothing in common and no way to tell
;; anybody.
;;
;; WHY A SEAM OF ITS OWN RATHER THAN THE HOOKS THAT ALREADY EXIST. `repo.rkt`
;; carries `set-put-hook!` and `set-delete-hook!`, and each is a SINGLE-SLOT box
;; already taken — by `triggers.rkt` and by the knowledge graph. Adding webhooks
;; to one of them would mean either multiplexing a seam whose single consumer is
;; load-bearing, or a third box in repo.rkt and a fourth in the scheduler. One
;; sink that every emitter reaches is the same move `set-reaper!` made for
;; periodic work, and the next consumer (an SSE stream, an audit mirror) plugs in
;; here rather than growing a box of its own.
;;
;; THE SINK NEVER RAISES INTO ITS EMITTER. A run must not fail because a
;; subscriber's table is missing, and this is the rule `fire-triggers!` already
;; lives by at the end of `repo-put!`.

(require racket/list)

(provide EVENTS event? emit! set-event-sink! current-event-sink)

;; A CLOSED vocabulary, like `WORKER-STATES` and `REVIEW-VERDICTS`. A subscriber
;; filters on these names, so one invented in passing is a filter that silently
;; matches nothing — and `ping` is in the list because a subscription nobody can
;; test is a subscription nobody trusts (#85 requirement 6).
(define EVENTS
  '("run.completed" "run.failed" "job.completed"
    "object.created" "object.deleted" "review.decided" "ping"))

(define (event? e) (and (member e EVENTS) #t))

(define *sink* (box #f))
(define (set-event-sink! f) (set-box! *sink* f))
(define (current-event-sink) (unbox *sink*))

;; (emit! conn event team data) — `data` is a jsexpr hash of IDS AND STATUS, never
;; content. The payload crosses the network to somebody else's server, so the
;; rule is #85's: ids, status, timestamps and a link, and the receiver fetches
;; the rest under its own credentials.
(define (emit! conn event team data)
  (define sink (unbox *sink*))
  (when (and sink (event? event) team)
    ;; Swallowed deliberately, and the emitter is told nothing: see the header.
    (with-handlers ([(lambda (_) #t)
                     (lambda (e)
                       (eprintf "event sink (~a): ~a\n" event
                                (if (exn? e) (exn-message e) e)))])
      (sink conn event team data))))
