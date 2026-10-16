#lang racket/base

;; cli/telemachus-worker.rkt — the reference pull worker (slice 66, PULL-7).
;;
;;   TELEMACHUS_URL=http://host:8835 TELEMACHUS_WORKER_TOKEN=tk_… \
;;   TELEMACHUS_WORKER_MODEL_URL=http://127.0.0.1:11434/v1/chat/completions \
;;   TELEMACHUS_WORKER_MODELS=qwen2.5:7b \
;;   racket cli/telemachus-worker.rkt [--once]
;;
;; A loop any language can write: long-poll a claim, heartbeat while running,
;; run the job against the local OpenAI-compatible endpoint, post the result or
;; the failure. The bearer is a worker token (scope jobs:execute) returned once
;; when the executor was created. Works through NAT and a tailnet — the worker
;; only ever connects OUT.

(require racket/string racket/list racket/port json
         net/http-client net/url
         "../domain/agent/llm.rkt"       ; http-post-json
         (only-in "../domain/ai/content.rkt" content->text))

(define (env k [d #f]) (let ([v (getenv k)]) (if (and v (not (string=? v ""))) v d)))
(define BASE  (regexp-replace #rx"/+$" (env "TELEMACHUS_URL" "http://127.0.0.1:8835") ""))
(define TOKEN (env "TELEMACHUS_WORKER_TOKEN"))
(define MODEL-URL (env "TELEMACHUS_WORKER_MODEL_URL"))
(define MODEL-KEY (env "TELEMACHUS_WORKER_MODEL_KEY"))
(define MODELS (let ([m (env "TELEMACHUS_WORKER_MODELS" "")]) (filter (lambda (s) (not (string=? s ""))) (map string-trim (string-split m ",")))))
;; JUDGE-14: a loopback `laya_serve.py --port` (run it with --batch-size 1).
;; Set, it adds judge.typed to this worker's kinds; the chat endpoint is then
;; optional, so a Mac can be a judge host and nothing else.
(define LAYA-URL (let ([u (env "TELEMACHUS_WORKER_LAYA_URL")])
                   (and u (regexp-replace #rx"/+$" u ""))))
(define KINDS (append (if MODEL-URL '("infer.chat") '())
                      (if LAYA-URL '("judge.typed") '())))
(define ONCE? (member "--once" (vector->list (current-command-line-arguments))))

(unless TOKEN (eprintf "TELEMACHUS_WORKER_TOKEN is not set\n") (exit 2))
(when (null? KINDS)
  (eprintf "set TELEMACHUS_WORKER_MODEL_URL (an OpenAI-compatible chat endpoint) and/or TELEMACHUS_WORKER_LAYA_URL (a loopback laya_serve.py)\n")
  (exit 2))

(define auth (list (string-append "Authorization: Bearer " TOKEN) "Content-Type: application/json"))
(define (post path body)
  (http-post-json (string-append BASE path) body auth))

;; infer.chat — forward to the model.
;; `response_format` is forwarded when the platform asked for one (issue #18), so
;; a schema request routed to a pull executor reaches the provider as it would
;; locally; the platform checks the reply against it either way.
(define (run-infer-chat payload)
  (define body
    (let ([b (hasheq 'model (let ([m (hash-ref payload 'model 'null)]) (if (string? m) m (if (pair? MODELS) (car MODELS) "local")))
                     'messages (hash-ref payload 'messages '())
                     'temperature (hash-ref payload 'temperature 0.7)
                     'stream #f)])
      (let ([rf (hash-ref payload 'response_format #f)])
        (if (and rf (not (eq? rf 'null))) (hash-set b 'response_format rf) b))))
  (define-values (code resp)
    (http-post-json MODEL-URL body (append (list "Content-Type: application/json")
                                          (if MODEL-KEY (list (string-append "Authorization: Bearer " MODEL-KEY)) '()))))
  (unless (= code 200) (error 'worker "model endpoint returned HTTP ~a" code))
  (define choices (hash-ref resp 'choices '()))
  ;; a provider may answer with content PARTS; join their text rather than
  ;; posting an empty reply the platform cannot tell from a quiet model
  (define reply (if (pair? choices)
                    (let-values ([(t problem) (content->text (hash-ref (hash-ref (car choices) 'message (hasheq)) 'content ""))])
                      (when problem (error 'worker "the model's reply could not be read as text: ~a" problem))
                      t)
                    ""))
  (define tokens (let ([t (hash-ref (hash-ref resp 'usage (hasheq)) 'total_tokens #f)])
                   (if (number? t) t (max 1 (quotient (string-length reply) 4)))))
  (hasheq 'reply reply 'tokens_used tokens))

;; The job this worker is holding right now, for the shutdown flush (issue #61).
;; Cleared in a dynamic-wind at the call site, so it is right however run-job
;; exits — a release posted for a job that already completed would be refused as
;; not-holder, which is harmless but would print a confusing line on every stop.
(define held (box #f))

;; judge.typed — forward to laya (JUDGE-8/13/14). The payload's `request_json`
;; goes out EXACTLY as the platform composed it, and the verdict goes back
;; EXACTLY as laya wrote it: both are bytes this worker must not parse and
;; re-serialize, because the object key order inside them is part of the
;; question. http-post-json would re-encode, so this one speaks raw.
(define (run-judge-typed payload)
  (define rq (hash-ref payload 'request_json #f))
  (unless (string? rq) (error 'worker "judge.typed payload carries no request_json"))
  (define u (string->url LAYA-URL))
  (define path (string-append
                (let ([pp (string-join (map path/param-path (url-path u)) "/")])
                  (if (string=? pp "") "" (string-append "/" pp)))
                "/v1/systemone"))
  (define-values (status _hdrs in)
    (http-sendrecv (url-host u) path
                   #:port (or (url-port u) (if (equal? (url-scheme u) "https") 443 80))
                   #:ssl? (equal? (url-scheme u) "https")
                   #:method #"POST"
                   #:data (string->bytes/utf-8 rq)
                   #:headers '("Content-Type: application/json")))
  (define body (port->string in))
  (define code (let ([m (regexp-match #rx"^HTTP/[^ ]+ ([0-9]+)" status)])
                 (if m (string->number (bytes->string/utf-8 (cadr m))) 0)))
  (unless (= code 200)
    (error 'worker "laya returned HTTP ~a: ~a" code
           (let ([b (string-trim body)]) (substring b 0 (min 300 (string-length b))))))
  (hasheq 'verdict_json body))

(define (run-job job)
  (define id (hash-ref job 'id))
  (define kind (hash-ref job 'kind))
  (define lease (let ([l (hash-ref job 'lease_seconds 120)]) (if (number? l) l 120)))
  ;; the claim's fencing token (issue #24): it goes back with every heartbeat and
  ;; with the result, so a run whose lease lapsed cannot complete the attempt that
  ;; replaced it. A worker that drops it will be refused with 409.
  (define token (let ([t (hash-ref job 'claim_token #f)]) (if (string? t) t 'null)))
  ;; what the shutdown flush would have to hand back (issue #61)
  (set-box! held (cons id token))
  ;; Heartbeat at a third of the lease while the job runs — and READ the answer.
  ;; A 409 means this attempt is no longer ours to finish: the lease lapsed and
  ;; somebody re-claimed it, or the job was canceled (SCHED-8). Either way the
  ;; right move is to stop, because the result can no longer land. The beat
  ;; thread breaks the thread doing the work; the handler below posts /fail,
  ;; which is what lets the server settle the row at once instead of waiting the
  ;; lease out. A worker in another language does the same thing: stop when the
  ;; heartbeat stops saying 200.
  (define worker-thd (current-thread))
  (define stopped (box #f))
  (define beat (thread (lambda ()
                         (let loop ()
                           (sleep (max 1 (quotient lease 3)))
                           (define-values (code resp)
                             ;; `state` rides on the heartbeat (issue #58), so an
                             ;; operator reading GET /api/executors sees "busy"
                             ;; rather than inferring it from a timestamp
                             (post (format "/api/workers/jobs/~a/heartbeat" id)
                                   (hasheq 'claim_token token 'state "busy")))
                           (cond
                             [(= code 200) (loop)]
                             [else
                              (set-box! stopped (let ([e (and (hash? resp) (hash-ref resp 'error #f))])
                                                  (if (string? e) e (format "heartbeat refused (HTTP ~a)" code))))
                              (break-thread worker-thd)])))))
  (with-handlers ([exn:break? (lambda (_)
                                (kill-thread beat)
                                (define why (or (unbox stopped) "interrupted"))
                                (post (format "/api/workers/jobs/~a/fail" id)
                                      (hasheq 'error why 'claim_token token))
                                (printf "job ~a (~a): STOPPED — ~a\n" id kind why))]
                  [exn:fail? (lambda (e)
                               (kill-thread beat)
                               (post (format "/api/workers/jobs/~a/fail" id)
                                     (hasheq 'error (exn-message e) 'claim_token token))
                               (printf "job ~a (~a): FAILED — ~a\n" id kind (exn-message e)))])
    (define result
      (case kind
        [("infer.chat") (run-infer-chat (hash-ref job 'payload (hasheq)))]
        [("judge.typed") (run-judge-typed (hash-ref job 'payload (hasheq)))]
        [else (error 'worker "this worker does not run ~a" kind)]))
    (kill-thread beat)
    (define-values (code resp) (post (format "/api/workers/jobs/~a/complete" id)
                                     (hasheq 'result result 'claim_token token)))
    (printf "job ~a (~a): ~a\n" id kind (if (= code 200) "done" (format "complete refused (HTTP ~a)" code)))))

(printf "telemachus-worker → ~a  models ~a  kinds ~a\n" BASE (if (null? MODELS) "(any)" (string-join MODELS ",")) (string-join KINDS ","))

;; Say so on the way out (issue #58). A worker that is stopped — Ctrl-C, a
;; systemd stop, a drain before maintenance — otherwise just goes quiet, and
;; quiet is what a CRASHED worker looks like. One request turns an operator's
;; guess into a fact; it is best-effort, because a host being torn down may have
;; no network left and failing the shutdown over that would be worse.
(define (report-paused!)
  (with-handlers ([exn:fail? void])
    (post "/api/workers/state" (hasheq 'state "paused"))
    (printf "telemachus-worker: reported paused\n")))

;; …and hand back the job it is holding, if any (issue #61). Letting the lease
;; lapse instead costs the job one of its three attempts for something that was
;; this host's business, not the job's — and a worker stopped mid-job is the most
;; ordinary way that used to happen. `shutdown` is the reason; the release spends
;; no attempt, and another worker may take the job at once rather than waiting
;; out the 120-second lease.
;;
;; Best-effort for report-paused!'s reason, and in this ORDER: the release is the
;; one that matters to the work, so it goes first in case the host dies between
;; the two requests.
(define (release-held!)
  (define h (unbox held))
  (when h
    (with-handlers ([exn:fail? void])
      (post (format "/api/workers/jobs/~a/release" (car h))
            (hasheq 'claim_token (cdr h) 'reason "shutdown"))
      (printf "telemachus-worker: released ~a on the way out\n" (car h)))))
(plumber-add-flush! (current-plumber) (lambda (_) (release-held!) (report-paused!)))

(let loop ()
  (define-values (code resp)
    (with-handlers ([exn:fail? (lambda (e) (values 0 (hasheq 'error (exn-message e))))])
      (post "/api/workers/claim" (hasheq 'kinds KINDS 'models MODELS 'max_wait 20
                                         ;; about to long-poll, so by definition
                                         ;; there is capacity for another job
                                         'state "ready"))))
  (cond
    [(and (= code 200) (hash? resp) (string? (hash-ref resp 'id #f)))
     (dynamic-wind void (lambda () (run-job resp)) (lambda () (set-box! held #f)))]
    [(= code 204) (void)]
    [(= code 0) (eprintf "claim: ~a (retrying)\n" (hash-ref resp 'error "?")) (sleep 3)]
    [(member code '(401 403)) (eprintf "claim refused: HTTP ~a — is the worker token valid and bound to an executor?\n" code) (exit 1)]
    [else (eprintf "claim: HTTP ~a\n" code) (sleep 3)])
  (unless ONCE? (loop)))
