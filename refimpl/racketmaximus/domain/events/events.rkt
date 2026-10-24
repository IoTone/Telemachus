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
;;
;; THERE IS MORE THAN ONE SUBSCRIBER NOW (#133). The paragraph above promised
;; that "the next consumer plugs in here rather than growing a box of its own",
;; and the box was single-slot and taken by webhooks — so the Matrix plugin
;; could not have plugged in at all without either displacing webhooks or
;; growing the fourth hook this module exists to prevent. Sinks are NAMED and
;; there may be several:
;;
;;   • each is wrapped SEPARATELY, so one subscriber's missing table or broken
;;     transport cannot stop another's delivery. With one shared handler the
;;     first sink to raise would have swallowed the rest, which is the failure
;;     nobody would notice until the day it mattered;
;;   • re-adding your OWN name REPLACES it, because the plugin loader may run
;;     twice in one process — `register-extractor!`'s rule, and the reason sinks
;;     are named rather than appended blindly;
;;   • the order is the order they were added, and nothing may depend on it: a
;;     subscriber that needed to run after another would be a pipeline, not a
;;     sink.

(require racket/list)

(provide EVENTS event? emit! add-event-sink! remove-event-sink! event-sinks
         set-event-sink! current-event-sink)

;; A CLOSED vocabulary, like `WORKER-STATES` and `REVIEW-VERDICTS`. A subscriber
;; filters on these names, so one invented in passing is a filter that silently
;; matches nothing — and `ping` is in the list because a subscription nobody can
;; test is a subscription nobody trusts (#85 requirement 6).
(define EVENTS
  '("run.completed" "run.failed" "job.completed"
    "object.created" "object.deleted" "review.decided" "ping"))

(define (event? e) (and (member e EVENTS) #t))

;; (list (cons name proc) ...), in the order they were added.
(define *sinks* (box '()))

(define (add-event-sink! name f)
  (unless (and (string? name) (not (string=? name ""))) (error 'add-event-sink! "a sink needs a name"))
  (unless (procedure? f) (error 'add-event-sink! "~a: a sink must be a procedure" name))
  (set-box! *sinks* (append (filter (lambda (kv) (not (equal? (car kv) name))) (unbox *sinks*))
                            (list (cons name f))))
  name)

(define (remove-event-sink! name)
  (set-box! *sinks* (filter (lambda (kv) (not (equal? (car kv) name))) (unbox *sinks*))))

;; name -> proc, for a test that wants to see who is subscribed without emitting.
(define (event-sinks) (map car (unbox *sinks*)))

;; Kept for the single-subscriber callers that predate #133: `#f` clears
;; everything, which is what every test using it meant by it.
(define (set-event-sink! f)
  (if f (add-event-sink! "default" f) (set-box! *sinks* '())))

(define (current-event-sink)
  (let ([l (unbox *sinks*)]) (and (pair? l) (cdr (car l)))))

;; (emit! conn event team data) — `data` is a jsexpr hash of IDS AND STATUS, never
;; content. The payload crosses the network to somebody else's server, so the
;; rule is #85's: ids, status, timestamps and a link, and the receiver fetches
;; the rest under its own credentials.
(define (emit! conn event team data)
  (when (and (event? event) team)
    (for ([kv (in-list (unbox *sinks*))])
      ;; Wrapped PER SINK, deliberately: one subscriber's failure must not cost
      ;; another's delivery, and the emitter is told nothing either way. See the
      ;; header.
      (with-handlers ([(lambda (_) #t)
                       (lambda (e)
                         (eprintf "event sink ~a (~a): ~a\n" (car kv) event
                                  (if (exn? e) (exn-message e) e)))])
        ((cdr kv) conn event team data)))))
