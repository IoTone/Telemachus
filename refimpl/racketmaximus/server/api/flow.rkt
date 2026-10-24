#lang racket/base

;; server/api/flow.rkt — workflows, their runs and the upload triggers that
;; start them
;;
;; Split out of main.rkt by #110 r3. The shared surface every handler here
;; needs — the pool, the request accessors, with-auth/with-mt, the response
;; constructors — is server/kit.rkt.

(provide ep-workflows-create ep-workflows-list ep-workflow-schema
         ep-workflow-get ep-doc-triggers-list ep-doc-triggers-create
         ep-doc-trigger-get ep-doc-trigger-update ep-doc-trigger-delete
         ep-workflow-run ep-runs-list ep-run-get ep-run-cancel)

(require web-kit
         (only-in "../../domain/orgs/orgs.rkt" tenant-quota-check)
         (only-in "../../domain/idem/idem.rkt" idem-fingerprint)
         (only-in "../../domain/repo/triggers.rkt" trigger-create! trigger-delete! trigger-fires trigger-get trigger-list trigger-update!)
         (only-in "../../domain/flow/spec.rkt" spec-schema)
         (only-in "../../domain/flow/run.rkt" flow-def-by-slug flow-defs flow-publish! flow-run-cancel! flow-run-get flow-run-start! flow-runs)
         (only-in "../../domain/i18n/i18n.rkt" t)
         "../kit.rkt"
         "../admission.rkt")

;; ---- workflows (slice 46) ---------------------------------------------------
;; The spec is the contract: `validate-spec` is reached the same way from here as
;; from `define-workflow`, so a JSON document and a Racket-authored one are held to
;; one definition of valid. Every run pins the caller as its principal and each
;; step re-checks it, so a workflow can never do what its starter could not.
(define (ep-workflows-create req)
  (with-auth req (lambda (p)
    (require-feature p "workflows")
    (define d (flow-publish! db-conn p (read-json-body req)))
    (json-response d #:code 201))))

(define (ep-workflows-list req)
  (with-auth req (lambda (p)
    (require-feature p "workflows")
    (json-response (hasheq 'workflows (flow-defs db-conn p))))))

;; contract discovery — deliberately unauthenticated: it describes the format this
;; build accepts, which an editor or a second implementation needs before it holds
;; a token, and it reveals nothing about the instance.
(define (ep-workflow-schema req) (json-response (spec-schema)))

(define (ep-workflow-get req slug)
  (with-auth req (lambda (p)
    (require-feature p "workflows")
    (define d (flow-def-by-slug db-conn p slug))
    (if d (json-response d) (err "not found" 404)))))

;; ---- upload triggers (slice 58) ------------------------------------------------
;; The list carries the team's remaining AI budget: a trigger whose runs sit
;; queued is a team out of tokens, not a broken trigger, and this is where an
;; operator looks first.
(define (ep-doc-triggers-list req)
  (with-auth req (lambda (p)
    (require-feature p "workflows")
    (json-response (hasheq 'triggers (trigger-list db-conn p)
                           'budget (tenant-quota-check db-conn p "ai.tokens.total" 0))))))

(define (ep-doc-triggers-create req)
  (with-auth req (lambda (p)
    (require-feature p "workflows")
    (with-handlers ([exn:fail:user? (lambda (e) (err (exn-message e) 400))])
      (define b (read-json-body req))
      (define (flag k d) (let ([v (hash-ref b k d)]) (and v (not (eq? v 'null)))))
      (json-response
       (trigger-create! db-conn p #:workflow (fmt b 'workflow_slug)
                        #:prefix (fmt b 'match_prefix) #:types (hash-ref b 'match_types "")
                        #:attrs (let ([a (hash-ref b 'match_attrs (hasheq))])
                                  (if (or (not a) (eq? a 'null)) (hasheq) a))
                        #:input (let ([i (hash-ref b 'input (hasheq))]) (if (eq? i 'null) (hasheq) i))
                        #:fire-on-derived? (flag 'fire_on_derived #f) #:enabled? (flag 'enabled #t))
       #:code 201)))))

(define (ep-doc-trigger-get req id)
  (with-auth req (lambda (p)
    (define t (trigger-get db-conn p id))
    (if t
         (json-response (hash-set t 'fires (trigger-fires db-conn p id)))
         (err "not found" 404)))))

(define (ep-doc-trigger-update req id)
  (with-auth req (lambda (p)
    (with-handlers ([exn:fail:user? (lambda (e) (err (exn-message e) 400))])
      (define t (trigger-update! db-conn p id (read-json-body req)))
      (if t (json-response t) (err "not found" 404))))))

(define (ep-doc-trigger-delete req id)
  (with-auth req (lambda (p)
    (if (trigger-delete! db-conn p id) (json-response (hasheq 'ok #t)) (err "not found" 404)))))

(define (ep-workflow-run req slug)
  (with-auth req (lambda (p)
    (require-feature p "workflows")
    (define d (flow-def-by-slug db-conn p slug))
    (cond
      [(not d) (err "not found" 404)]
      [else
       (define b (read-json-body req))
       (define in (let ([i (hash-ref b 'input (hasheq))]) (if (hash? i) i (hasheq))))
       ;; r2: `dedupe: true` DERIVES a key from the work itself — the slug, the
       ;; definition's version and the input — so re-processing an unchanged
       ;; object is a no-op that returns the previous run. The version is in the
       ;; derivation deliberately: an EDITED workflow legitimately re-runs, which
       ;; is why r3 exposes the version on the run at all. The object id and
       ;; version the issue names are already IN the input for this pipeline
       ;; (`process-upload` binds `object_id`), so hashing the input covers them
       ;; without this endpoint having to know a particular workflow's shape.
       ;;
       ;; An EXPLICIT key always wins: the client's own idea of what its retry is
       ;; beats ours.
       (define derived
         (and (eq? (hash-ref b 'dedupe #f) #t)
              (not (idem-key-of req b))
              (string-append "auto:" (idem-fingerprint
                                      (format "run:~a:~a" slug (hash-ref d 'version "?"))
                                      in))))
       (with-idem req p b #:endpoint (format "POST /api/workflows/~a/run" slug)
                  #:payload (hasheq 'input in) #:key derived
                  (lambda () (values (flow-run-start! db-conn p d #:input in) 202)))]))))

(define (ep-runs-list req)
  (with-auth req (lambda (p)
    (require-feature p "workflows")
    (json-response (hasheq 'runs (flow-runs db-conn p))))))

(define (ep-run-get req id)
  (with-auth req (lambda (p)
    (require-feature p "workflows")
    (define r (flow-run-get db-conn p id))
    (if r (json-response r) (err "not found" 404)))))

(define (ep-run-cancel req id)
  (with-auth req (lambda (p)
    (require-feature p "workflows")
    (define r (flow-run-cancel! db-conn p id))
    (cond
      [(eq? r #t) (json-response (hasheq 'ok #t 'id id 'status "canceled"))]
      [(eq? r 'not-cancelable) (err "run already finished — cannot cancel" 409)]
      [else (err "not found" 404)]))))
