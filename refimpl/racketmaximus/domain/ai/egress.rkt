#lang racket/base

;; domain/ai/egress.rkt — where a model request is going, and what that backend
;; has been declared to do with it. Issue #91 requirement 3 (RED-20, RED-21).
;;
;; PURE of the database, deliberately, and that is the whole reason it is not in
;; `requestlog.rkt` beside the row it fills: `domain/ai/executor.rkt` asks it on
;; the path of every model call to decide whether the call may go at all, and
;; that module knows nothing of the database — the same property that makes
;; `pull-router` a box rather than a call. A policy that could only be asked
;; through a connection would have to be re-derived there, which is
;; `executor-can-run?`'s drift.

(require racket/string
         net/url
         (only-in "../authz/peer.rkt" loopback-host?)
         (only-in "../exec/federation.rkt" executor-caps))

(provide CONTENT-LOGGING
         endpoint-host endpoint-hosted? content-logging-of
         require-no-content-logging? content-logging-refusal)

;; CLOSED:
;;   declared-none — the executor's capability document says no_content_logging
;;   undeclared    — a hosted backend whose operator has not said either way
;;   local         — loopback: nothing left the box, so there is nothing to declare
(define CONTENT-LOGGING '("declared-none" "undeclared" "local"))

;; ---- where a backend is (RED-21) --------------------------------------------

;; The host of an endpoint URL, or #f. Never the query, never the userinfo —
;; FEED-6's rule, and this string is stored.
(define (endpoint-host u)
  (and (string? u) (not (string=? (string-trim u) ""))
       (with-handlers ([exn:fail? (lambda (_) #f)])
         (let ([h (url-host (string->url u))])
           (and (string? h) (not (string=? h "")) h)))))

;; Was this backend off the box? `loopback-host?` is peer.rkt's one predicate for
;; "only this host can reach it" — never a second copy here, or this policy and
;; the TLS startup warning would drift about what counts as private.
;;
;; An endpoint we cannot parse counts as HOSTED, for the same reason a name
;; nobody can resolve does: the policy exists for exactly the backends nobody can
;; place, so an unreadable one must not be exempted by its own unreadability.
(define (endpoint-hosted? u)
  (define h (endpoint-host u))
  (not (and h (loopback-host? h))))

;; ---- the declaration (RED-20) -----------------------------------------------

;; `no_content_logging` rides in the LAY-9 capability document, so it needs no
;; migration and arrives identically from `executors.json` and from an executors
;; row. An absent capability is UNKNOWN there and unknown is permissive, which is
;; right for "can you tool-call" and is NOT what this field means: here the
;; ABSENCE is the thing being reported, so it gets its own value rather than a
;; silent pass.
(define (content-logging-of executor endpoint)
  (cond
    [(not (endpoint-hosted? endpoint)) "local"]
    [(eq? #t (hash-ref (executor-caps (or executor "")) 'no_content_logging 'unknown)) "declared-none"]
    [else "undeclared"]))

;; OFF unless configured. Every default-bearing knob in this tree makes the same
;; call (the retention horizon, the worker-token lifetime, the anchor cadence): a
;; real default means an upgrade silently starts refusing model calls on
;; instances that work today, and here those calls are the product.
(define (require-no-content-logging?)
  (and (member (or (getenv "TELEMACHUS_REQUIRE_NO_CONTENT_LOGGING") "")
               '("1" "true" "yes" "on"))
       #t))

;; -> #f, or a sentence naming the executor and what has to be declared.
;;
;; WHAT THIS ENFORCES IS THAT SOMEBODY MADE THE ASSERTION, never the assertion
;; itself. The platform cannot check what a remote operator retains; nothing can,
;; and a feature claiming to would be worse than this one. What it CAN do is
;; refuse to send a team's document text to a backend that is not on this box
;; until this instance's own operator has declared, per executor, that the
;; backend does not log content — which turns an assumption nobody wrote down
;; into a decision with a name attached to it.
(define (content-logging-refusal executor endpoint)
  (and (require-no-content-logging?)
       (string=? (content-logging-of executor endpoint) "undeclared")
       (format (string-append
                "executor ~a is not on this host and does not declare no_content_logging, "
                "so this instance will not send it content "
                "(set that capability on the executor, or unset "
                "TELEMACHUS_REQUIRE_NO_CONTENT_LOGGING)")
               (or executor "the configured local model"))))
