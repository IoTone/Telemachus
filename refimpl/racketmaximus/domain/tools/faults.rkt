#lang racket/base

;; faults.rkt — the ONE distinction a fan-out cannot make for itself: is this
;; refusal about THIS item, or about the configuration?
;;
;; WF-14. `map` grew a per-child failure policy (WF-11), and `continue` is only
;; safe because of this module. The text indexer's own carve-out is the
;; precedent, and CLAUDE.md has stated it for a year:
;;
;;     an UNREADABLE file is recorded as processed-with-nothing, never raised —
;;     one corrupt PDF must not wedge the team's indexing forever
;;     ('missing-tool still fails hard, deliberately)
;;
;; Those are two different failures wearing one exception type. A document a
;; model cannot extract verifiably is awkward and its twelve siblings are
;; innocent; `TMACH_EMBED_URL` being unset is wrong about the whole run, and
;; thirteen copies of that message are not more informative than one — they are
;; thirteen model requests, thirteen error rows and a buried signal.
;;
;; SO THE ENGINE IS TOLD, RATHER THAN GUESSING. There is no sound way to read
;; "no embedding model configured" out of a message string: the project's own
;; refusals are localized, rephrased by register sweeps and composed from
;; operator-facing variable names. A struct is what `exn:fail:unavailable`
;; (PULL-14), `exn:fail:feed-store` (FEED) and `exn:fail:model-retryable` each
;; chose for exactly this shape of question, and it is checkable at the catch.
;;
;; IT HAS NO DEPENDENCIES ON PURPOSE. A tool must be able to raise it without
;; requiring the workflow engine, and the engine must be able to catch it
;; without requiring a tool — so this module requires nothing at all and both
;; sides require it. Putting it in `executor.rkt` would have been the obvious
;; home and is wrong: `'missing-tool` is about `pdftotext`, not about a model.
;;
;; WHAT IT IS NOT FOR. Not a quota (the scheduler defers rather than failing,
;; QUOTA-3), not a permission (`exn:fail:forbidden` already says so and a
;; sibling may legitimately be readable where this one is not), and not a
;; transport error (PULL-14's `exn:fail:unavailable` is the host's, and the next
;; attempt may well succeed). It is for "an operator must change something
;; before any item of this fan-out can work".

(provide (struct-out exn:fail:misconfigured)
         raise-misconfigured
         misconfigured?)

(struct exn:fail:misconfigured exn:fail () #:transparent)

;; `who` and `message` compose the same way `error` does, so a call site reads
;; identically to the `raise-user-error` or `error` it replaces.
(define (raise-misconfigured who message)
  (raise (exn:fail:misconfigured
          (if who (format "~a: ~a" who message) message)
          (current-continuation-marks))))

;; A catch-site predicate, so the engine does not have to know the struct name
;; in three places.
(define (misconfigured? e) (exn:fail:misconfigured? e))
