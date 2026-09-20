#lang racket/base

;; plugins/integrator-demo/main.rkt — the plugin docs/integrators-guide.md walks
;; through. It fills all four seams a customer's app needs and nothing else, so it
;; can be read start to finish:
;;
;;   tools      a capability the model may call, RBAC-checked like a built-in
;;   routes     the API the customer's own screens call
;;   job kinds  background work, on the platform's queue and quotas
;;   bundle/    the screens themselves, served to a signed-in caller
;;
;; It deliberately stores nothing and reads nothing it does not own: an example
;; that reaches into core tables teaches the wrong lesson about the seam.

(require racket/string racket/list json
         (only-in "../../domain/sched/scheduler.rkt" register-job-kind!))

(provide tools routes init!)

;; ---- a tool -------------------------------------------------------------------
;; The schema is plain OpenAI-compatible JSON; the handler is
;; (conn principal args) -> a string or a jsexpr. The permission named here is
;; checked by the platform before the handler runs.
(define shipment-eta-schema
  (hasheq 'type "function"
          'function (hasheq
                     'name "shipment_eta"
                     'description "Estimate arrival days for a shipment lane."
                     'parameters (hasheq
                                  'type "object"
                                  'properties (hasheq 'lane (hasheq 'type "string"
                                                                    'description "Lane, e.g. SIN-LAX"))
                                  'required '("lane")))))

;; A stand-in for whatever the customer's domain actually computes.
(define (lane-days lane)
  (case (string-upcase (string-trim lane))
    [("SIN-LAX") 18] [("SIN-RTM") 26] [("HKG-LAX") 16] [else 21]))

(define (shipment-eta conn principal args)
  (define lane (let ([v (hash-ref args 'lane "")]) (if (string? v) v "")))
  (format "~a: about ~a days door to door" (string-upcase lane) (lane-days lane)))

(define tools (list (list "shipment_eta" shipment-eta-schema "chat:use" shipment-eta)))

;; ---- an authenticated route ----------------------------------------------------
;; Mounted by the platform at /api/x/integrator-demo/<path> — the prefix is fixed,
;; so this can never shadow a core route or another plugin's. `args` carries
;; 'params (path), 'query and 'body; a raise-user-error is the caller's 400.
(define (eta-route conn principal args)
  (define lane (or (hash-ref (hash-ref args 'query) 'lane #f)
                   (let ([b (hash-ref args 'body)]) (and (hash? b) (hash-ref b 'lane #f)))))
  (unless (string? lane) (raise-user-error 'shipment_eta "lane is required"))
  (hasheq 'lane (string-upcase lane) 'days (lane-days lane)))

(define routes
  (list (list "GET"  "/eta" "chat:use" eta-route "Estimated days for ?lane=.")
        (list "POST" "/eta" "chat:use" eta-route "Estimated days for {lane}.")))

;; ---- a background job kind -----------------------------------------------------
;; init! runs at load with full SDK access. A plugin's kinds are namespaced
;; x.<plugin-id>.<name> and the loader enforces it; the job itself is ordinary —
;; the enqueuing team and user, the per-team cap, quota admission, the org gate,
;; cancellation and the lease all apply, and none of it is inherited from here.
(define (lane-report conn principal payload)
  (define lanes (let ([v (hash-ref payload 'lanes '())]) (if (list? v) v '())))
  (hasheq 'rows (for/list ([l (in-list lanes)] #:when (string? l))
                  (hasheq 'lane (string-upcase l) 'days (lane-days l)))))

(define (init!)
  (register-job-kind! "x.integrator-demo.lane-report" lane-report))
