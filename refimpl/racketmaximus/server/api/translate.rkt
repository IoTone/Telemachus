#lang racket/base

;; server/api/translate.rkt — the Translation app
;;
;; Split out of main.rkt by #110 r3. The shared surface every handler here
;; needs — the pool, the request accessors, with-auth/with-mt, the response
;; constructors — is server/kit.rkt.

(provide ep-translate ep-translate-job ep-translate-list ep-translate-catalog
         ep-glossary-list ep-glossary-add)

(require web-kit
         (only-in "../../domain/authz/authz.rkt" principal-team-id principal-user-id require-perm)
         (only-in "../../domain/apps/translate.rkt" glossary-add! glossary-list translate! translate-catalog! translate-list translate-max-chars
                  ;; #232: a long translation is N model calls, so the endpoint
                  ;; has to know N before it admits anything
                  translate-plan
                  ;; #233: the admit/record pair, shared with the job kind
                  translate-metering)
         (only-in "../../domain/sched/scheduler.rkt" enqueue-job!)
         (only-in "../../domain/orgs/orgs.rkt" tenant-quota-check tenant-quota-record!)
         (only-in "../../domain/quota/quota.rkt" get-limit)
         (only-in "../../domain/sched/governor.rkt" with-slot)
         (only-in "../../domain/ai/executor.rkt" estimate-tokens)
         "../kit.rkt"
         "../admission.rkt")

;; ---- Translation app --------------------------------------------------------
(define (ep-translate req)
  (with-auth req (lambda (p)
    (require-perm db-conn p "chat:use")
    (require-feature p "translate")
    (define b (read-json-body req))
    (define text (hash-ref b 'text ""))
    (define tgt (hash-ref b 'target_lang ""))
    (cond
      [(or (string=? text "") (string=? tgt "")) (err "text and target_lang required" 400)]
      [else
       (define sid (principal-team-id p))
       ;; #232: THE WHOLE DOCUMENT, IN N SECTIONS. `translate-plan` is the same
       ;; function `translate!` runs, with the same glossary, so the count
       ;; admitted here cannot disagree with the count performed there — which
       ;; is why the glossary is read twice on this path. One indexed query
       ;; against N model calls is noise, and a plan computed WITHOUT the terms
       ;; would size its chunks larger than the real prompt allows and so
       ;; under-admit.
       (define-values (chunks _problem)
         (translate-plan text #:target tgt
                         #:source (hash-ref b 'source_lang "auto")
                         #:terms (if (and (hash-ref b 'use_glossary #t) #t)
                                     (glossary-list db-conn p #:target-lang tgt)
                                     '())))
       (define nreq (max 1 (length chunks)))
       (define est (estimate-tokens text))
       (define rq (tenant-quota-check db-conn p "ai.requests" nreq))
       (define tq (tenant-quota-check db-conn p "ai.tokens.total" est))
       (cond
         [(not (hash-ref rq 'allowed)) (quota-429 rq "ai.requests")]
         [(not (hash-ref tq 'allowed)) (quota-429 tq "ai.tokens.total")]
         [else
          (define-values (climit _w) (get-limit db-conn "team" sid "ai.concurrency"))
          (with-slot GOV (string-append "team:" sid) (or climit 2)
            (lambda (inflight)
              ;; #232: PER CHUNK, AND BEFORE EACH ONE (FEED-9). A long document
              ;; is several model calls, so admitting one request up front and
              ;; recording one at the end would let a team paste sixty pages
              ;; against a 200/day allowance and be billed for a single request.
              ;; The pre-check above already refused the obvious case; this is
              ;; the per-call admission, which is also what stops a team that
              ;; crosses its budget MID-document with a named reason instead of
              ;; half a translation.
              ;; #233: the same pair the `translate` job kind fills, built in
              ;; one place so the two callers cannot bill differently
              (define-values (admit record-chunk!) (translate-metering db-conn p))
              (define-values (job tokens)
                (translate! db-conn p #:text text #:target-lang tgt
                            #:source-lang (hash-ref b 'source_lang "auto")
                            #:use-glossary (and (hash-ref b 'use_glossary #t) #t)
                            #:admit admit #:record! record-chunk!))
              (json-response (hash-set (hash-set job 'tokens_used tokens) 'concurrent inflight))))])]))))


;; ---- the same translation, as a job (TR-12, #233) ---------------------------
;;
;; WHY A SEPARATE ROUTE RATHER THAN `?async=1` ON THE ONE ABOVE: the two answer
;; different things. This one answers a JOB — an id, a status and the unit count
;; — and the one above answers a TRANSLATION. A flag that changed the shape of a
;; 200 would make every client branch on a query parameter it sent, and FLEET-2a
;; already settled the same question the same way.
;;
;; AND WHY NOT JUST `POST /api/jobs {"kind":"translate"}`, which has worked since
;; the kind was registered: that route is `chat:use` and carries NO
;; `#:feature "translate"`, so routing the tab through it would be a way past
;; the feature switch for the one app the switch is named after. It also admits
;; ONE request where a long document is up to 24, so an over-budget team would
;; be accepted and then fail mid-document — and it cannot refuse a text past the
;; cap at all, because `translate-plan` is what knows the cap and only
;; `translate!` runs it, by which time there is a job row and a failure instead
;; of a 400 somebody can read.
;;
;; THE PRE-FLIGHT IS THE SYNCHRONOUS PATH'S, DELIBERATELY UNCHANGED: the plan,
;; the cap refusal, and both budget checks against the REAL section count. What
;; it buys is that an enqueue which could never succeed never becomes a row.
(define (ep-translate-job req)
  (with-auth req (lambda (p)
    (require-perm db-conn p "chat:use")
    (require-feature p "translate")
    (define b (read-json-body req))
    (define text (hash-ref b 'text ""))
    (define tgt (hash-ref b 'target_lang ""))
    (define src (hash-ref b 'source_lang "auto"))
    (define gl? (and (hash-ref b 'use_glossary #t) #t))
    (cond
      [(or (not (string? text)) (not (string? tgt)) (string=? text "") (string=? tgt ""))
       (err "text and target_lang required" 400)]
      [else
       (define-values (chunks problem)
         (translate-plan text #:target tgt #:source src
                         #:terms (if gl? (glossary-list db-conn p #:target-lang tgt) '())))
       (cond
         ;; past the cap: a 400 before anything is enqueued, which is the same
         ;; answer the synchronous route gives and for the same reason — nothing
         ;; is stored, and a person can read why
         [problem (err problem 400)]
         [else
          (define nreq (max 1 (length chunks)))
          (define rq (tenant-quota-check db-conn p "ai.requests" nreq))
          (define tq (tenant-quota-check db-conn p "ai.tokens.total" (estimate-tokens text)))
          (cond
            [(not (hash-ref rq 'allowed)) (quota-429 rq "ai.requests")]
            [(not (hash-ref tq 'allowed)) (quota-429 tq "ai.tokens.total")]
            [else
             (with-idem req p b #:endpoint "POST /api/translate/job"
                        #:payload (hasheq 'text text 'target_lang tgt
                                          'source_lang src 'use_glossary gl?)
                        (lambda ()
                          (define id (enqueue-job! db-conn #:team (principal-team-id p)
                                                   #:user (principal-user-id p)
                                                   #:kind "translate"
                                                   #:payload (hasheq 'text text 'target_lang tgt
                                                                     'source_lang src
                                                                     'use_glossary gl?)))
                          ;; `sections` is the plan, reported so the form can say
                          ;; what it just accepted without waiting for the first
                          ;; poll. The JOB reports its own progress against the
                          ;; same number once it starts (TR-9).
                          (values (hasheq 'job_id id 'status "queued" 'sections nreq) 202)))])])]))))

;; `max_chars` rides on the LIST read because that is the call the tab already
;; makes before anybody types (#231): the console shows the limit beside the
;; field and counts against it, so a long paste is refused by a number the
;; person can see rather than by a surprise after the wait. ONE home for it —
;; the server's — so the count in the browser cannot disagree with the rule.
(define (ep-translate-list req)
  (with-auth req (lambda (p) (json-response (hasheq 'translations (translate-list db-conn p)
                                                    'max_chars (translate-max-chars))))))

(define (ep-translate-catalog req)
  (with-auth req (lambda (p)
    (require-perm db-conn p "chat:use")
    (require-feature p "translate")
    (define b (read-json-body req))
    (define cat (hash-ref b 'catalog (hasheq)))
    (define tgt (hash-ref b 'target_lang ""))
    (cond
      [(or (not (hash? cat)) (string=? tgt "")) (err "catalog (object) and target_lang required" 400)]
      [else
       (define sid (principal-team-id p))
       (define tq (tenant-quota-check db-conn p "ai.tokens.total" (estimate-tokens (format "~a" cat))))
       (cond
         [(not (hash-ref tq 'allowed)) (quota-429 tq "ai.tokens.total")]
         [else
          (define-values (climit _w) (get-limit db-conn "team" sid "ai.concurrency"))
          (with-slot GOV (string-append "team:" sid) (or climit 2)
            (lambda (_inflight)
              (define-values (out tokens) (translate-catalog! db-conn p #:catalog cat #:target-lang tgt))
              (tenant-quota-record! db-conn p "ai.tokens.total" tokens)
              (json-response (hasheq 'catalog out 'target_lang tgt 'tokens_used tokens))))])]))))

(define (ep-glossary-list req)
  (with-auth req (lambda (p) (json-response (hasheq 'glossary (glossary-list db-conn p))))))

(define (ep-glossary-add req)
  (with-auth req (lambda (p)
    (define b (read-json-body req))
    (define term (hash-ref b 'term ""))
    (define tr (hash-ref b 'translation ""))
    (define tgt (hash-ref b 'target_lang ""))
    (cond
      [(or (string=? term "") (string=? tr "") (string=? tgt "")) (err "term, translation, target_lang required" 400)]
      [else (json-response (glossary-add! db-conn p #:term term #:translation tr #:target-lang tgt))]))))
