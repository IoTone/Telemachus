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

(require racket/string racket/list json
         "../domain/agent/llm.rkt")      ; http-post-json

(define (env k [d #f]) (let ([v (getenv k)]) (if (and v (not (string=? v ""))) v d)))
(define BASE  (regexp-replace #rx"/+$" (env "TELEMACHUS_URL" "http://127.0.0.1:8835") ""))
(define TOKEN (env "TELEMACHUS_WORKER_TOKEN"))
(define MODEL-URL (env "TELEMACHUS_WORKER_MODEL_URL"))
(define MODEL-KEY (env "TELEMACHUS_WORKER_MODEL_KEY"))
(define MODELS (let ([m (env "TELEMACHUS_WORKER_MODELS" "")]) (filter (lambda (s) (not (string=? s ""))) (map string-trim (string-split m ",")))))
(define ONCE? (member "--once" (vector->list (current-command-line-arguments))))

(unless TOKEN (eprintf "TELEMACHUS_WORKER_TOKEN is not set\n") (exit 2))
(unless MODEL-URL (eprintf "TELEMACHUS_WORKER_MODEL_URL is not set (an OpenAI-compatible chat endpoint)\n") (exit 2))

(define auth (list (string-append "Authorization: Bearer " TOKEN) "Content-Type: application/json"))
(define (post path body)
  (http-post-json (string-append BASE path) body auth))

;; the one remote kind this worker knows: infer.chat — forward to the model
(define (run-infer-chat payload)
  (define body
    (hasheq 'model (let ([m (hash-ref payload 'model 'null)]) (if (string? m) m (if (pair? MODELS) (car MODELS) "local")))
            'messages (hash-ref payload 'messages '())
            'temperature (hash-ref payload 'temperature 0.7)
            'stream #f))
  (define-values (code resp)
    (http-post-json MODEL-URL body (append (list "Content-Type: application/json")
                                          (if MODEL-KEY (list (string-append "Authorization: Bearer " MODEL-KEY)) '()))))
  (unless (= code 200) (error 'worker "model endpoint returned HTTP ~a" code))
  (define choices (hash-ref resp 'choices '()))
  (define reply (if (pair? choices)
                    (let ([c (hash-ref (hash-ref (car choices) 'message (hasheq)) 'content "")]) (if (string? c) c ""))
                    ""))
  (define tokens (let ([t (hash-ref (hash-ref resp 'usage (hasheq)) 'total_tokens #f)])
                   (if (number? t) t (max 1 (quotient (string-length reply) 4)))))
  (hasheq 'reply reply 'tokens_used tokens))

(define (run-job job)
  (define id (hash-ref job 'id))
  (define kind (hash-ref job 'kind))
  (define lease (let ([l (hash-ref job 'lease_seconds 120)]) (if (number? l) l 120)))
  ;; heartbeat at a third of the lease while the job runs
  (define beat (thread (lambda () (let loop () (sleep (max 1 (quotient lease 3)))
                                    (post (format "/api/workers/jobs/~a/heartbeat" id) (hasheq)) (loop)))))
  (with-handlers ([exn:fail? (lambda (e)
                               (kill-thread beat)
                               (post (format "/api/workers/jobs/~a/fail" id) (hasheq 'error (exn-message e)))
                               (printf "job ~a (~a): FAILED — ~a\n" id kind (exn-message e)))])
    (define result
      (case kind
        [("infer.chat") (run-infer-chat (hash-ref job 'payload (hasheq)))]
        [else (error 'worker "this worker does not run ~a" kind)]))
    (kill-thread beat)
    (define-values (code resp) (post (format "/api/workers/jobs/~a/complete" id) (hasheq 'result result)))
    (printf "job ~a (~a): ~a\n" id kind (if (= code 200) "done" (format "complete refused (HTTP ~a)" code)))))

(printf "telemachus-worker → ~a  models ~a  kinds infer.chat\n" BASE (if (null? MODELS) "(any)" (string-join MODELS ",")))
(let loop ()
  (define-values (code resp)
    (with-handlers ([exn:fail? (lambda (e) (values 0 (hasheq 'error (exn-message e))))])
      (post "/api/workers/claim" (hasheq 'kinds '("infer.chat") 'models MODELS 'max_wait 20))))
  (cond
    [(and (= code 200) (hash? resp) (string? (hash-ref resp 'id #f))) (run-job resp)]
    [(= code 204) (void)]
    [(= code 0) (eprintf "claim: ~a (retrying)\n" (hash-ref resp 'error "?")) (sleep 3)]
    [(member code '(401 403)) (eprintf "claim refused: HTTP ~a — is the worker token valid and bound to an executor?\n" code) (exit 1)]
    [else (eprintf "claim: HTTP ~a\n" code) (sleep 3)])
  (unless ONCE? (loop)))
