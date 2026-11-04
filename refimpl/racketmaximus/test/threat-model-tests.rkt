#lang racket/base

;; test/threat-model-tests.rkt — the surfaces `docs/design/threat-model.md`
;; enumerates, pinned (issue #186, SEC-10).
;;
;;   raco test test/threat-model-tests.rkt
;;
;; WHY THIS EXISTS, AND IT IS A MEASUREMENT RATHER THAN A PRINCIPLE. #186 asked
;; for a threat model per surface as the METHOD. Two passes were made before that
;; document existed and each was one enumeration chosen from the previous pass's
;; leftovers. In between, **the public surface grew from 23 routes to 25, and the
;; two new ones are in the exact class the first pass had flagged and left open**:
;; a public endpoint that redeems a mailed token with no throttle. Nothing
;; re-ran the survey, because nothing said when to.
;;
;; So the two surfaces that grow by accident are pinned here as LITERALS. A route
;; added to either fails this file until somebody edits the list AND the document
;; that reasons about it, which is the only thing that makes "we look when it
;; changes" true rather than hoped for. It is `pollable_kinds`' shape (the
;; derived set pinned whole, so an addition is a deliberate edit) and the
;; console's `src`-tags rule (both directions, so a removal fails too).
;;
;; THE LIST ITSELF IS PINNED, NOT RE-DERIVED. A test that rebuilt either list
;; from `ROUTES` would agree with any change whatsoever, which is the whole point
;; of `vocabulary-tests.rkt`'s own note about a closed vocabulary: adding to it
;; is a decision somebody makes on purpose.

(require rackunit racket/list racket/string racket/path racket/runtime-path
         (only-in racket/file file->string)
         "../server/routes.rkt")

(define-runtime-path here ".")
(define (doc-path) (build-path here ".." ".." ".." "docs" "design" "threat-model.md"))

(define (routes-where pred)
  (sort (for/list ([r (in-list ROUTES)] #:when (pred r))
          (format "~a ~a" (rt-method r) (rt-path r)))
        string<?))

;; ---- surface 1: what an unauthenticated stranger can reach ------------------------
;; 25 routes. Every one of them is reachable by anybody who can open a socket to
;; the instance, so each needs an answer to "what does this cost me if a stranger
;; calls it a million times" and "what does it tell them".
(define PUBLIC
  (sort '("GET /"
          "GET /index.html"
          "GET /login"
          "GET /activate"
          "GET /health"
          "GET /beta-sdk.js"
          "GET /console/*path"
          "GET /beta/bundle/:plugin/*path"
          "GET /beta/template"
          "GET /api/config"
          "GET /api/branding"
          "GET /api/i18n/catalog"
          "GET /api/beta/config"
          "OPTIONS /api/beta/signup"
          "OPTIONS /api/beta/config"
          "OPTIONS /api/beta/challenge"
          "GET /api/beta/asset/:id"
          "GET /api/beta/challenge"
          "POST /api/beta/signup"
          "POST /api/bootstrap"
          "POST /api/activate"
          "POST /api/password-reset"
          "POST /api/password-reset/confirm"
          "POST /api/login"
          "GET /api/workflows/schema")
        string<?))

;; ---- surface 2: what a WORKER TOKEN can reach -------------------------------------
;; A worker holds `jobs:execute` and a claim. It is operator-registered and
;; semi-trusted, and SEC-9 is what happens when a route on this surface is
;; believed to be bounded by something that does not bound it.
(define WORKER
  (sort '("POST /api/workers/claim"
          "POST /api/workers/state"
          "GET /api/workers/token"
          "POST /api/workers/token"
          "POST /api/workers/jobs/:id/heartbeat"
          "POST /api/workers/jobs/:id/complete"
          "POST /api/workers/jobs/:id/fail"
          "POST /api/workers/jobs/:id/release"
          "POST /api/workers/jobs/:id/document"
          "POST /api/workers/jobs/:id/derive")
        string<?))

(define ADVICE
  (string-append "\n  A route joined or left a surface docs/design/threat-model.md reasons about."
                 "\n  Update that document AND this list in the same commit — the point of the"
                 "\n  pin is that growing one of these surfaces cannot happen by accident."))

(test-case "the public surface is exactly what the threat model enumerates"
  (define actual (routes-where (lambda (r) (eq? (rt-auth r) 'public))))
  (check-equal? actual PUBLIC
                (string-append "added: " (format "~a" (remove* PUBLIC actual))
                               "  removed: " (format "~a" (remove* actual PUBLIC))
                               ADVICE)))

(test-case "the worker-facing surface is exactly what the threat model enumerates"
  (define actual (routes-where (lambda (r) (string-prefix? (rt-path r) "/api/workers"))))
  (check-equal? actual WORKER
                (string-append "added: " (format "~a" (remove* WORKER actual))
                               "  removed: " (format "~a" (remove* actual WORKER))
                               ADVICE)))

;; A route that authenticates ITSELF is outside the dispatcher's pre-check, so it
;; is its own surface — and there have only ever been two (#43's bundle ticket,
;; which takes a bearer OR a ticket, because pre-authenticating refused the
;; ticket navigation). A third is a decision, not an implementation detail.
(test-case "only the documented routes authenticate themselves"
  (check-equal? (routes-where (lambda (r) (eq? (rt-auth r) 'handler)))
                (list "GET /api/x/:plugin/bundle/*path")
                ADVICE))

;; THE DOCUMENT HAS TO EXIST, or the lists above are a pin with nothing behind
;; them — the shape ENVN-11's second direction guards for the configuration
;; reference's compatibility section. Checked for its surface HEADINGS rather
;; than its prose, so editing the reasoning is free and deleting a surface is
;; not.
(test-case "the threat model exists and still covers each pinned surface"
  ;; THE DOCUMENT IS ABOVE `src`, SO IT IS ABSENT FROM THE NIX SANDBOX —
  ;; `nix/telemachus.nix` sets `src = ../refimpl/racketmaximus` and `doCheck`
  ;; runs this very suite, so `nix build` has nothing above this directory to
  ;; read. REL-2's own fact, and `test/build-identity-tests.rkt` met it from
  ;; inside the test written to document it.
  ;;
  ;; So this case SKIPS there and SAYS SO — a silent skip is how a path goes
  ;; unexercised for a year. The half that matters is never skipped: the route
  ;; pins above read `server/routes.rkt`, which IS inside `src`, so a surface
  ;; growing in the sandbox still fails. And CI runs the suite in a checkout as
  ;; well, where this case runs and is positive-controlled.
  (cond
    [(not (file-exists? (doc-path)))
     (printf (string-append "  SKIPPED: docs/design/threat-model.md is above `src` and so is not "
                            "in this tree (a Nix sandbox). Run this case from a checkout.\n"))]
    [else
     (define text (file->string (doc-path)))
     (for ([needle (in-list '("## Surface 1 — the unauthenticated public"
                              "## Surface 2 — the worker token"))])
       (check-true (string-contains? text needle)
                   (format "the threat model no longer has a section headed ~s" needle)))]))
