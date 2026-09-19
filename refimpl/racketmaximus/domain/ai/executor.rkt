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
         "../agent/llm.rkt"             ; http-post-json
         "content.rkt"                  ; content->text, response formats (issue #18)
         "../exec/federation.rkt")      ; executor-config — route to a named backend

(provide model-configured? model-info run-chat run-chat-stream parse-chat-response estimate-tokens
         model-url model-name model-key pull-router)

;; PULL-5: a named executor that is not a push backend may be a PULL executor. The
;; server installs a router (name messages temperature response-format) -> (cons
;; reply tokens) that enqueues an infer.chat sub-job and waits; executor.rkt knows
;; nothing of the database. #f for a name the router does not own.
(define pull-router (box (lambda (name msgs temp rf) #f)))

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

;; PURE: pull reply text + total_tokens (or #f) out of an OpenAI-compatible resp.
;; Content PARTS are read, not discarded (issue #18): a provider that answers
;; `[{type:"text",…}]` used to produce "" here, and an empty reply the caller
;; could not tell from a quiet model. A content that carries parts and no text is
;; refused by name instead.
(define (parse-chat-response resp)
  (define choices (hash-ref resp 'choices '()))
  (define-values (reply problem)
    (if (pair? choices)
        (content->text (hash-ref (hash-ref (car choices) 'message (hasheq)) 'content ""))
        (values "" #f)))
  (when problem (error 'run-chat "the model's reply could not be read as text: ~a" problem))
  (define t (hash-ref (hash-ref resp 'usage (hasheq)) 'total_tokens #f))
  (values reply (and (number? t) t)))

(define (headers* key)
  (append (list "Content-Type: application/json")
          (if key (list (string-append "Authorization: Bearer " key)) '())))

;; resolve a backend: a named federated executor, else the env-configured local.
;; -> (values url model key configured?)
(define (backend name)
  (cond
    [(and name (executor-config name)) => (lambda (c) (values (car c) (cadr c) (caddr c) #t))]
    [else (values (model-url) (model-name) (model-key) (model-configured?))]))

;; run-chat : content -> (values reply-text tokens-used).  #:executor routes to a
;; named federated backend; #f uses the local node.
;;
;; `prompt` is a string or a list of content parts (issue #18); a malformed one is
;; refused here rather than becoming an opaque provider 400. #:response-format
;; rides to the provider AND is checked against the reply — a local server that
;; ignores the field must not be able to answer a schema request with prose.
(define (run-chat prompt #:system [system #f] #:temperature [temp 0.7] #:executor [executor #f]
                  #:response-format [rf #f])
  (define-values (url mdl key conf?) (backend executor))
  (let ([bad (content-problem prompt)]) (when bad (error 'run-chat "~a" bad)))
  (when rf (let ([bad (response-format-problem rf)]) (when bad (error 'run-chat "~a" bad))))
  (define prompt-text (let-values ([(t _p) (content->text prompt)]) t))
  (define msgs
    (append (if system (list (hasheq 'role "system" 'content system)) '())
            (list (hasheq 'role "user" 'content prompt))))
  (define routed (and executor (not (executor-config executor)) ((unbox pull-router) executor msgs temp rf)))
  (define (verify! reply)
    (when rf
      (define-values (_parsed problem) (response-format-verify rf reply))
      (when problem (error 'run-chat "the reply does not honour response_format: ~a" problem))))
  (cond
    [routed (verify! (car routed)) (values (car routed) (cdr routed))]   ; a pull executor answered
    [(not conf?)
     ;; the simulated fallback cannot honour a schema, and pretending it did would
     ;; hand the caller an upper-cased echo as "conforming JSON"
     (when rf (error 'run-chat "no model configured: response_format cannot be honoured"))
     (values (string-upcase prompt-text) (estimate-tokens prompt-text))]
    [else
     (define-values (code resp)
       (http-post-json url (let ([b (hasheq 'model mdl 'messages msgs 'temperature temp 'stream #f)])
                             (if rf (hash-set b 'response_format rf) b))
                       (headers* key)))
     (unless (= code 200) (error 'run-chat "model endpoint returned HTTP ~a" code))
     (define-values (reply tokens) (parse-chat-response resp))
     (verify! reply)
     (values reply (or tokens (estimate-tokens prompt-text reply)))]))

;; run-chat-stream : content × (string -> void) -> (values tokens-used full-text)
;; calls `on-token` with each chunk as it arrives. The full text comes back too
;; (issue #18): a response format can only be checked once the stream has ended,
;; and the endpoint reports the verdict in its final event rather than raising
;; after it has already streamed the answer.
(define (run-chat-stream prompt on-token #:system [system #f] #:temperature [temp 0.7] #:executor [executor #f]
                         #:response-format [rf #f])
  (define-values (url mdl key conf?) (backend executor))
  (let ([bad (content-problem prompt)]) (when bad (error 'run-chat "~a" bad)))
  (when rf (let ([bad (response-format-problem rf)]) (when bad (error 'run-chat "~a" bad))))
  (define prompt-text (let-values ([(t _p) (content->text prompt)]) t))
  (cond
    [(not conf?)
     (when rf (error 'run-chat "no model configured: response_format cannot be honoured"))
     (define reply (string-upcase prompt-text))                ; simulated: stream word by word
     (for ([w (in-list (string-split reply))]) (on-token (string-append w " ")) (sleep 0.06))
     (values (estimate-tokens prompt-text) reply)]
    [else
     (define acc (open-output-string))
     (define (tap s) (write-string s acc) (on-token s))
     (define msgs
       (append (if system (list (hasheq 'role "system" 'content system)) '())
               (list (hasheq 'role "user" 'content prompt))))
     ((openai-llm-stream #:endpoint url #:model mdl #:api-key key
                         #:temperature temp #:on-content tap #:response-format rf) msgs)
     (define text (get-output-string acc))
     (values (estimate-tokens prompt-text text) text)]))
