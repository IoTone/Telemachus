#lang racket/base

;; domain/ai/executor.rkt — the local-model executor (data plane). Calls an
;; OpenAI-compatible chat endpoint (llama-server / ollama / vLLM / …) configured
;; by env, and reports actual token usage for metering. When no model is
;; configured it FALLS BACK to a deterministic simulated reply, so the platform
;; is demoable with or without a model running.
;;
;;   TELEMACHUS_MODEL_URL  e.g. http://127.0.0.1:11434/v1/chat/completions
;;   TELEMACHUS_MODEL      model name (default "local")
;;   TELEMACHUS_MODEL_KEY  bearer token (optional)
;;
;; The scheduler/governor wraps `run-chat`, so real model latency queues behind
;; the per-team concurrency cap exactly like the simulated job did.

(require racket/string
         "../agent/llm.rkt")            ; http-post-json

(provide model-configured? model-info run-chat run-chat-stream parse-chat-response estimate-tokens
         model-url model-name model-key)

(define (env k) (let ([v (getenv k)]) (and v (not (string=? v "")) v)))
(define (model-url)  (env "TELEMACHUS_MODEL_URL"))
(define (model-name) (or (env "TELEMACHUS_MODEL") "local"))
(define (model-key)  (env "TELEMACHUS_MODEL_KEY"))

(define (model-configured?) (and (model-url) #t))
(define (model-info)
  (hasheq 'configured (model-configured?)
          'url (or (model-url) 'null)
          'model (model-name)))

(define (estimate-tokens . strs)
  (max 1 (quotient (for/sum ([s (in-list strs)]) (string-length s)) 4)))

;; PURE: pull reply text + total_tokens (or #f) out of an OpenAI-compatible resp
(define (parse-chat-response resp)
  (define choices (hash-ref resp 'choices '()))
  (define reply
    (if (pair? choices)
        (let ([c (hash-ref (hash-ref (car choices) 'message (hasheq)) 'content "")])
          (if (string? c) c ""))
        ""))
  (define t (hash-ref (hash-ref resp 'usage (hasheq)) 'total_tokens #f))
  (values reply (and (number? t) t)))

(define (headers)
  (append (list "Content-Type: application/json")
          (if (model-key) (list (string-append "Authorization: Bearer " (model-key))) '())))

;; run-chat : string -> (values reply-text tokens-used)
(define (run-chat prompt #:system [system #f] #:temperature [temp 0.7])
  (cond
    [(not (model-configured?))
     (values (string-upcase prompt) (estimate-tokens prompt))]     ; simulated fallback
    [else
     (define msgs
       (append (if system (list (hasheq 'role "system" 'content system)) '())
               (list (hasheq 'role "user" 'content prompt))))
     (define-values (code resp)
       (http-post-json (model-url)
                       (hasheq 'model (model-name) 'messages msgs 'temperature temp 'stream #f)
                       (headers)))
     (unless (= code 200) (error 'run-chat "model endpoint returned HTTP ~a" code))
     (define-values (reply tokens) (parse-chat-response resp))
     (values reply (or tokens (estimate-tokens prompt reply)))]))

;; run-chat-stream : string × (string -> void) -> tokens-used
;; calls `on-token` with each chunk as it arrives; returns the token estimate.
(define (run-chat-stream prompt on-token #:system [system #f] #:temperature [temp 0.7])
  (cond
    [(not (model-configured?))
     (define reply (string-upcase prompt))                     ; simulated: stream word by word
     (for ([w (in-list (string-split reply))]) (on-token (string-append w " ")) (sleep 0.06))
     (estimate-tokens prompt)]
    [else
     (define acc (open-output-string))
     (define (tap s) (write-string s acc) (on-token s))
     (define msgs
       (append (if system (list (hasheq 'role "system" 'content system)) '())
               (list (hasheq 'role "user" 'content prompt))))
     ((openai-llm-stream #:endpoint (model-url) #:model (model-name) #:api-key (model-key)
                         #:temperature temp #:on-content tap) msgs)
     (estimate-tokens prompt (get-output-string acc))]))
