#lang racket/base

;; domain/flow/spec.rkt — the workflow spec: THE CONTRACT (WF-1, WF-9).
;;
;; This module is normative. Both `define-workflow`'s output and a document
;; submitted to POST /api/workflows pass through `validate-spec`, so there is
;; exactly one definition of "valid" and no path that skips it — if the macro
;; ever grows a private fast path, the two drift inside a single release.
;;
;; STRICT BY DESIGN (WF-10): an unrecognised key is a rejection, not something to
;; ignore. A public format eventually receives a document from a newer writer, and
;; silently no-opping a step that takes an action reads as "the approval step was
;; skipped". Refusing is the kinder failure.
;;
;; Additive-only within a spec format version: new step kinds and new OPTIONAL
;; keys are free; removing or repurposing a key is a bump of `spec`.
;;
;;   { "spec": 1, "slug": "triage-lead", "version": 1,
;;     "input": { "lead_id": "string" },
;;     "steps": [ { "id": "fetch", "uses": "tool:get_lead",
;;                  "with": { "id": "${input.lead_id}" } },
;;                { "id": "gate",  "uses": "choice",
;;                  "when": { "gt": ["${steps.fetch.output.rating}", 3] },
;;                  "then": "notify", "else": "archive" } ] }

(require racket/string racket/list json "bind.rkt")

(provide SPEC-FORMAT-VERSION
         validate-spec spec-schema
         (struct-out exn:fail:spec)
         spec-slug spec-version spec-max-steps spec-steps spec-start
         step-ref step-kind step-tool-name step-next map-template)

(define SPEC-FORMAT-VERSION 1)
(define MAX-STEPS-CEILING 1000)
(define DEFAULT-MAX-STEPS 100)
(define MAX-RETRIES 10)

(struct exn:fail:spec exn:fail (detail) #:transparent)

(define (bad fmt . args)
  (define m (apply format fmt args))
  (raise (exn:fail:spec (string-append "invalid workflow spec: " m) (current-continuation-marks) m)))

;; ---- small helpers -----------------------------------------------------------
(define SLUG-RX #px"^[a-z0-9][a-z0-9_-]*$")
(define ID-RX   #px"^[a-zA-Z0-9][a-zA-Z0-9_-]*$")
(define INPUT-TYPES '("string" "number" "boolean" "object" "array"))

(define (allow! where h keys)
  (for ([k (in-list (hash-keys h))])
    (unless (memq k keys)
      (bad "~a: unknown field '~a' (allowed: ~a)" where k
           (string-join (map symbol->string keys) ", ")))))

(define (want h k pred what where)
  (define v (hash-ref h k 'missing))
  (when (eq? v 'missing) (bad "~a: '~a' is required" where k))
  (unless (pred v) (bad "~a: '~a' must be ~a" where k what))
  v)

(define (opt h k pred what where default)
  (define v (hash-ref h k 'missing))
  (cond [(eq? v 'missing) default]
        [(pred v) v]
        [else (bad "~a: '~a' must be ~a" where k what)]))

(define (pos-int? v) (and (exact-integer? v) (> v 0)))
(define (nonempty-string? v) (and (string? v) (> (string-length (string-trim v)) 0)))

;; ---- binding checks ----------------------------------------------------------
;; Every string reachable from a step's data is scanned: a malformed reference, or
;; one naming a step that does not exist, is a publish-time rejection rather than a
;; run-time surprise. Whether a *tool* exists is deliberately NOT checked here —
;; plugins register tools at load time, so that is resolved when the step runs.
(define (check-bindings! v step-ids where #:in-map? [in-map? #f])
  (cond
    [(string? v)
     (when (and (item-ref? v) (not in-map?))
       (bad "~a: '${item}' / '${index}' are only meaningful inside a `map` step" where))
     (for ([body (in-list (binding-refs v))])
       (unless (valid-ref? body)
         (bad "~a: '${~a}' is not a valid reference (use input.* , steps.<id>.output.* , run.id , principal.team_id , principal.user_id)" where body))
       (define sid (ref-step-id body))
       (when (and sid (not (member sid step-ids)))
         (bad "~a: '${~a}' references unknown step '~a'" where body sid)))]
    [(hash? v) (for ([(k x) (in-hash v)]) (check-bindings! x step-ids (format "~a.~a" where k) #:in-map? in-map?))]
    [(list? v) (for ([x (in-list v)] [i (in-naturals)]) (check-bindings! x step-ids (format "~a[~a]" where i) #:in-map? in-map?))]
    [else (void)]))

;; ---- steps -------------------------------------------------------------------
;; `tool:<name>`, `choice` (slice 46) and `map` (slice 47). `agent`, `job:<kind>`
;; and `flow:<slug>` are still REJECTED — that refusal is WF-10 working as
;; intended, not a gap.
(define TOOL-KEYS   '(id uses with next end retry))
(define CHOICE-KEYS '(id uses when then else))
(define MAP-KEYS    '(id uses over step next end))
(define MAP-STEP-KEYS '(uses with retry))            ; the per-item template: no id, no control

(define (step-kind s)
  (define u (hash-ref s 'uses ""))
  (cond [(and (string? u) (string-prefix? u "tool:")) 'tool]
        [(equal? u "choice") 'choice]
        [(equal? u "map") 'map]
        [else #f]))

;; the tool template a `map` applies to each item
(define (map-template s) (hash-ref s 'step (hasheq)))

(define (step-tool-name s) (substring (hash-ref s 'uses "") 5))

(define (validate-step! s ids)
  (unless (hash? s) (bad "steps: each step must be an object"))
  (define id (want s 'id nonempty-string? "a non-empty string" "step"))
  (unless (regexp-match ID-RX id) (bad "step '~a': id must match ~a" id ID-RX))
  (define where (format "step '~a'" id))
  (want s 'uses nonempty-string? "a non-empty string" where)
  (define kind (step-kind s))
  (unless kind
    (bad "~a: unsupported step kind '~a' (this version supports tool:<name> and choice)" where (hash-ref s 'uses)))
  (case kind
    [(tool)
     (allow! where s TOOL-KEYS)
     (unless (nonempty-string? (step-tool-name s)) (bad "~a: 'tool:' needs a tool name" where))
     (define w (opt s 'with hash? "an object" where (hasheq)))
     (check-bindings! w ids (format "~a.with" where))
     (define nxt (opt s 'next nonempty-string? "a step id" where #f))
     (define end (opt s 'end boolean? "a boolean" where #f))
     (when (and nxt end) (bad "~a: 'next' and 'end' are mutually exclusive" where))
     (when (and nxt (not (member nxt ids))) (bad "~a: 'next' names unknown step '~a'" where nxt))
     (define r (opt s 'retry hash? "an object" where #f))
     (when r
       (allow! (format "~a.retry" where) r '(max))
       (define m (want r 'max exact-integer? "an integer" (format "~a.retry" where)))
       (unless (and (>= m 0) (<= m MAX-RETRIES))
         (bad "~a.retry: 'max' must be between 0 and ~a" where MAX-RETRIES)))]
    [(map)
     ;; A fan-out: `over` is a list (or a reference to one) and `step` is a tool
     ;; template run once per item, with ${item} / ${index} bound. Each item is its
     ;; own scheduler job, so the team's existing concurrency cap is what bounds
     ;; the parallelism — nothing new to configure, and no way to self-DDOS.
     (allow! where s MAP-KEYS)
     (define over (hash-ref s 'over 'missing))
     (when (eq? over 'missing) (bad "~a: 'over' is required" where))
     (unless (or (string? over) (list? over)) (bad "~a: 'over' must be an array or a reference to one" where))
     (check-bindings! over ids (format "~a.over" where))
     (define tmpl (hash-ref s 'step 'missing))
     (when (eq? tmpl 'missing) (bad "~a: 'step' (the per-item template) is required" where))
     (unless (hash? tmpl) (bad "~a: 'step' must be an object" where))
     (allow! (format "~a.step" where) tmpl MAP-STEP-KEYS)
     (define u (hash-ref tmpl 'uses ""))
     (unless (and (string? u) (string-prefix? u "tool:") (> (string-length u) 5))
       (bad "~a.step: a map runs a tool per item — 'uses' must be tool:<name>" where))
     (check-bindings! (hash-ref tmpl 'with (hasheq)) ids (format "~a.step.with" where) #:in-map? #t)
     (define r (hash-ref tmpl 'retry #f))
     (when r
       (unless (hash? r) (bad "~a.step.retry: must be an object" where))
       (allow! (format "~a.step.retry" where) r '(max))
       (define m (want r 'max exact-integer? "an integer" (format "~a.step.retry" where)))
       (unless (and (>= m 0) (<= m MAX-RETRIES))
         (bad "~a.step.retry: 'max' must be between 0 and ~a" where MAX-RETRIES)))
     (define nxt (opt s 'next nonempty-string? "a step id" where #f))
     (define end (opt s 'end boolean? "a boolean" where #f))
     (when (and nxt end) (bad "~a: 'next' and 'end' are mutually exclusive" where))
     (when (and nxt (not (member nxt ids))) (bad "~a: 'next' names unknown step '~a'" where nxt))]
    [(choice)
     (allow! where s CHOICE-KEYS)
     (define p (hash-ref s 'when 'missing))
     (when (eq? p 'missing) (bad "~a: 'when' is required" where))
     (unless (predicate? p)
       (bad "~a: 'when' must be one of ~a with the right number of operands"
            where (string-join (map symbol->string predicate-keys) ", ")))
     (check-bindings! p ids (format "~a.when" where))
     (define then (want s 'then nonempty-string? "a step id" where))
     (unless (member then ids) (bad "~a: 'then' names unknown step '~a'" where then))
     (define els (opt s 'else nonempty-string? "a step id" where #f))
     (when (and els (not (member els ids))) (bad "~a: 'else' names unknown step '~a'" where els))])
  id)

;; ---- the document ------------------------------------------------------------
(define TOP-KEYS '(spec slug name description version max_steps input start steps))

(define (validate-spec doc)
  (unless (hash? doc) (bad "the document must be a JSON object"))
  (allow! "spec" doc TOP-KEYS)

  (define v (hash-ref doc 'spec 'missing))
  (when (eq? v 'missing) (bad "'spec' (the format version) is required — this server speaks ~a" SPEC-FORMAT-VERSION))
  (unless (equal? v SPEC-FORMAT-VERSION)
    (bad "unsupported spec format version ~a — this server speaks ~a" v SPEC-FORMAT-VERSION))

  (define slug (want doc 'slug nonempty-string? "a non-empty string" "spec"))
  (unless (regexp-match SLUG-RX slug) (bad "spec: slug must match ~a" SLUG-RX))
  (opt doc 'name string? "a string" "spec" "")
  (opt doc 'description string? "a string" "spec" "")
  (opt doc 'version pos-int? "a positive integer" "spec" 1)

  (define ms (opt doc 'max_steps pos-int? "a positive integer" "spec" DEFAULT-MAX-STEPS))
  (when (> ms MAX-STEPS-CEILING) (bad "spec: max_steps may not exceed ~a" MAX-STEPS-CEILING))

  (define in (opt doc 'input hash? "an object" "spec" (hasheq)))
  (for ([(k t) (in-hash in)])
    (unless (and (string? t) (member t INPUT-TYPES))
      (bad "spec.input.~a: type must be one of ~a" k (string-join INPUT-TYPES ", "))))

  (define steps (hash-ref doc 'steps 'missing))
  (when (eq? steps 'missing) (bad "'steps' is required"))
  (unless (and (list? steps) (pair? steps)) (bad "spec: 'steps' must be a non-empty array"))

  ;; ids first, so a step may reference one declared later (loops are legal and
  ;; bounded by max_steps — that is how a retry-ish cycle is expressed)
  (define ids (for/list ([s (in-list steps)])
                (unless (hash? s) (bad "steps: each step must be an object"))
                (define id (hash-ref s 'id 'missing))
                (when (eq? id 'missing) (bad "steps: every step needs an 'id'"))
                (unless (nonempty-string? id) (bad "steps: 'id' must be a non-empty string"))
                id))
  (let loop ([seen '()] [rest ids])
    (unless (null? rest)
      (when (member (car rest) seen) (bad "steps: duplicate step id '~a'" (car rest)))
      (loop (cons (car rest) seen) (cdr rest))))

  (for ([s (in-list steps)]) (validate-step! s ids))

  (define start (opt doc 'start nonempty-string? "a step id" "spec" (car ids)))
  (unless (member start ids) (bad "spec: 'start' names unknown step '~a'" start))
  doc)

;; ---- accessors (post-validation) ---------------------------------------------
(define (spec-slug s)      (hash-ref s 'slug))
(define (spec-version s)   (hash-ref s 'version 1))
(define (spec-max-steps s) (hash-ref s 'max_steps DEFAULT-MAX-STEPS))
(define (spec-steps s)     (hash-ref s 'steps '()))
(define (spec-start s)     (hash-ref s 'start (let ([ss (spec-steps s)]) (if (pair? ss) (hash-ref (car ss) 'id) #f))))

(define (step-ref s id) (findf (lambda (x) (equal? (hash-ref x 'id) id)) (spec-steps s)))

;; where control goes after `step` finishes: explicit `next`, else `end`, else the
;; following step in document order, else the run is done.
(define (step-next s step)
  (cond
    [(hash-ref step 'end #f) #f]
    [(hash-ref step 'next #f) => values]
    [else
     (let loop ([ss (spec-steps s)])
       (cond [(or (null? ss) (null? (cdr ss))) #f]
             [(equal? (hash-ref (car ss) 'id) (hash-ref step 'id)) (hash-ref (cadr ss) 'id)]
             [else (loop (cdr ss))]))]))

;; served at GET /api/workflows/schema — contract discovery for an editor or a
;; second implementation (WF-9). Deliberately describes what this build accepts.
(define (spec-schema)
  (hasheq 'spec SPEC-FORMAT-VERSION
          'step_kinds '("tool:<name>" "choice" "map")
          'planned_step_kinds '("agent" "job:<kind>" "flow:<slug>")
          'unknown_fields "rejected"
          'top_level (for/list ([k (in-list TOP-KEYS)]) (symbol->string k))
          'step_fields (hasheq 'tool (for/list ([k (in-list TOOL-KEYS)]) (symbol->string k))
                               'choice (for/list ([k (in-list CHOICE-KEYS)]) (symbol->string k))
                               'map (for/list ([k (in-list MAP-KEYS)]) (symbol->string k)))
          'references '("input.*" "steps.<id>.output.*" "run.id"
                        "principal.team_id" "principal.user_id" "principal.locale"
                        "item" "item.*" "index")
          'predicates (for/list ([k (in-list predicate-keys)]) (symbol->string k))
          'limits (hasheq 'max_steps_ceiling MAX-STEPS-CEILING 'default_max_steps DEFAULT-MAX-STEPS
                          'max_retries MAX-RETRIES)
          'conformance "subset of CNCF Serverless Workflow vocabulary; not conformant"))
