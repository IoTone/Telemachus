#lang racket/base

;; #128 job 2: operator-facing variables are read through ONE accessor,
;; which tries TMACH_<name> and falls back to TELEMACHUS_<name>.
(require (only-in "../../config.rkt" tmach-env))

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
         "../agent/llm.rkt"             ; http-post-json, sanitize-wire-messages
                                        ; + exn:fail:model-retryable's reason, which
                                        ; is what makes the log's error kind honest
         "content.rkt"                  ; content->text, response formats (issue #18)
         "../exec/federation.rkt"       ; executor-config — route to a named backend
         ;; #91 req 3: where this request is going, and what that backend has
         ;; been declared to do with it. PURE — no database reaches this module.
         "egress.rkt")

(provide model-configured? model-info chat-simulated? run-chat run-chat-stream parse-chat-response estimate-tokens
         model-name pull-router
         model-request-logger log-model-request! transport-error-kind
         egress-policy egress-refusal
         model-exchange response-tokens
         embed-exchange embed-configured? embed-model embedding-vectors embedding-tokens)

;; PULL-5: a named executor that is not a push backend may be a PULL executor. The
;; server installs a router (name messages temperature response-format) -> (cons
;; reply tokens) that enqueues an infer.chat sub-job and waits; executor.rkt knows
;; nothing of the database. #f for a name the router does not own.
(define pull-router (box (lambda (name msgs temp rf) #f)))

;; RED-17: the model-request log (issue #91 requirement 3). This module writes no
;; rows — the same reason `pull-router` above is a box — so `server/main.rkt`
;; installs a writer that knows the connection and the principal, and until it
;; does, nothing is logged and nothing fails.
;;
;; (executor transport operation model endpoint messages tokens status
;;  error-kind http-status ms) -> void
;;
;; EVERY KEYWORD THE REAL WRITER TAKES MUST BE HERE, with the same default.
;; This no-op is what runs in every unit test that does not install a writer, so
;; a keyword added to the real one and forgotten here fails only in the tests
;; that exercise the new path — which is exactly where it looks like a defect in
;; the new path.
(define model-request-logger
  (box (lambda (#:executor e #:transport t #:model m #:endpoint u #:messages msgs
                #:tokens tok #:status st #:error-kind ek #:http-status hs
                #:operation [op "chat"] #:ms ms)
         (void))))

;; A FAILURE HERE NEVER FAILS THE MODEL CALL — the trigger seam's rule. An
;; unwritable log is an operational problem; losing somebody's answer is theirs.
(define (log-model-request! #:executor executor #:transport transport #:model [model #f]
                            #:endpoint [endpoint #f] #:messages [msgs '()]
                            #:tokens [tokens #f] #:status status
                            #:error-kind [error-kind #f] #:http-status [http-status #f]
                            #:operation [operation "chat"]
                            #:ms [ms #f])
  ;; `exn:fail?`, NOT a catch-all: a break must pass through. The model deadline
  ;; shuts its request's custodian down and the shutdown drain stops the server
  ;; with one, and a logger that swallowed either would turn a stop into a hang.
  (with-handlers ([exn:fail? (lambda (e)
                               (eprintf "model-request log: ~a\n" (exn-message e))
                               (void))])
    ((unbox model-request-logger)
     #:executor executor #:transport transport #:model model #:endpoint endpoint
     #:messages msgs #:tokens tokens #:status status #:error-kind error-kind
     #:http-status http-status #:operation operation #:ms ms)))

;; RED-26: the per-org executor policy (issue #91 requirement 4). A box for the
;; reason `pull-router` and `model-request-logger` above are boxes — the policy
;; lives in two `instance_settings` documents and this module has no connection —
;; and until `server/main.rkt` installs one, nothing is refused.
;;
;; (executor endpoint document) -> #f to allow, or a sentence to refuse with.
(define egress-policy
  (box (lambda (#:executor e #:endpoint u #:document d) #f)))

;; The ONE gate the three transports share, so a policy cannot reach two of them
;; and miss the third. RED-16 is the reason that is a real risk rather than a
;; tidiness argument: `model-exchange` is not the only place content leaves, its
;; own header notwithstanding, and `content-logging-refusal` had to be written
;; into all three by hand one requirement ago.
;;
;; A POLICY THAT CANNOT BE READ REFUSES. That is the opposite of
;; `log-model-request!` two definitions above, which swallows its own failures,
;; and deliberately: a log that does not write costs an operator a record, while
;; a control that does not run costs somebody their document. So an unreadable
;; policy is a refusal naming itself — and it can only be reached by a request
;; that carries a LABEL, because an unlabelled one never asks, which keeps a
;; broken database from stopping every model call on the instance.
(define (egress-refusal executor endpoint)
  (or (content-logging-refusal executor endpoint)
      (let ([doc (current-egress-document)])
        (and doc (hash-ref doc 'label #f)
             (with-handlers ([exn:fail?
                              (lambda (ex)
                                (format (string-append
                                         "the executor policy for label ~a could not be read, "
                                         "so this request is refused: ~a")
                                        (hash-ref doc 'label #f) (exn-message ex)))])
               ((unbox egress-policy)
                #:executor executor #:endpoint endpoint #:document doc))))))

(define (ms-since start) (inexact->exact (round (- (current-inexact-milliseconds) start))))

;; Which of RED-19's short labels a transport failure is. `llm.rkt` already
;; separates these for its own retry decision (PULL-14 reads the same seam), so
;; the log inherits the classification rather than guessing from a message — and
;; every label the vocabulary declares is one something actually produces, which
;; is the half of #113 a declaration on its own never keeps.
;;
;;   a stalled stream IS a timeout from the operator's side: the remedy is the
;;   same, and a fifth label for it would be a distinction with no reader.
(define (transport-error-kind e)
  (define r (and (exn:fail:model-retryable? e) (exn:fail:model-retryable-reason e)))
  (case r
    [(timeout idle) "timeout"]
    [(network) "unreachable"]
    [else "transport"]))

(define (env k) (let ([v (getenv k)]) (and v (not (string=? v "")) v)))
(define (model-url)  (tmach-env "MODEL_URL"))
(define (model-name) (or (tmach-env "MODEL") "local"))
(define (model-key)  (tmach-env "MODEL_KEY"))

;; What the ENV-CONFIGURED local model can do (LAY-9). The named backends keep
;; their capability document on the executor row; the local model has no row, and
;; it is the path most calls take — so without this the operator who most needs
;; the warning is the one who gets none. That operator is not hypothetical: the
;; failure this feature exists to catch is pointing TELEMACHUS_MODEL at a model
;; that cannot tool-call, and Japanese models of a given size lead on general
;; benchmarks while lagging specifically on function-calling.
;;
;;   TELEMACHUS_MODEL_CAPS="tools=false,json_schema=true"
;;
;; Unset, or a key left out, means UNKNOWN — and unknown is permissive, so
;; nothing that works today starts failing.
(define (model-caps)
  (define raw (tmach-env "MODEL_CAPS"))
  (cond
    [(not raw) (hasheq)]
    [else
     (for/fold ([h (hasheq)]) ([part (in-list (string-split raw ","))])
       (define kv (string-split (string-trim part) "="))
       (cond
         [(= 2 (length kv))
          (define v (string-downcase (string-trim (cadr kv))))
          (hash-set h (string->symbol (string-trim (car kv)))
                    (cond [(member v '("true" "yes" "1")) #t]
                          [(member v '("false" "no" "0")) #f]
                          [else 'unknown]))]
         [else h]))]))

(define (local-capability-refusal needs)
  (define caps (model-caps))
  (for/or ([k (in-list needs)])
    (and (eq? (hash-ref caps k 'unknown) #f)
         (format "the configured model (~a) declares it cannot do ~a — see TMACH_MODEL_CAPS"
                 (model-name) k))))

;; ---- EMB-1: the embedding endpoint is its OWN, and that is forced ------------
;; An embedding model is a DIFFERENT model from the chat model — `nomic-embed-text`
;; or `bge-m3`, never `qwen2.5:7b` — so the model NAME cannot be shared with
;; `TMACH_MODEL`, and once the name is separate the URL may as well be rather
;; than derived by surgery on `/v1/chat/completions`. That derivation is the
;; obvious shortcut and it is wrong twice: it assumes the embedding model lives
;; on the same server as the chat model, and it would silently send the chat
;; model's NAME to an endpoint that cannot use it.
(define (embed-url)   (tmach-env "EMBED_URL"))
(define (embed-model) (or (tmach-env "EMBED_MODEL") "local-embed"))
(define (embed-key)   (tmach-env "EMBED_KEY"))

;; EMB-3: CONFIGURATION IS THE CAPABILITY. #163 asked for an `embeddings` entry in
;; LAY-9's capability document, on the premise that embeddings ride the chat
;; endpoint — with an endpoint of their own there is nothing for a declaration to
;; add, and a declared capability that can disagree with whether the endpoint is
;; set would be a second answer to one question (`executor-can-run?`'s drift). An
;; unset endpoint is refused BY NAME before anything leaves, which is the property
;; the capability was wanted for. The day an embedding is ROUTED to a named
;; executor, that executor's document is where `embeddings` belongs.
(define (embed-configured?) (and (embed-url) #t))

(define (model-configured?) (and (model-url) #t))
(define (model-info)
  (hasheq 'configured (model-configured?)
          'url (or (model-url) 'null)
          'model (model-name)
          'capabilities (model-caps)))

;; total_tokens as the provider reported it, or #f. The agent needs the count
;; WITHOUT the text: a tool-call-only turn has no readable content, which is
;; exactly the case parse-chat-response refuses.
(define (response-tokens resp)
  (define t (hash-ref (hash-ref resp 'usage (hasheq)) 'total_tokens #f))
  (and (number? t) t))

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
  (values reply (response-tokens resp)))

(define (headers* key)
  (append (list "Content-Type: application/json")
          (if key (list (string-append "Authorization: Bearer " key)) '())))

;; Would this call be answered by the SIMULATED echo rather than by a model?
;; (issue #64) The echo exists so the platform is demoable with nothing running,
;; and that is worth keeping — but a caller got a plausible-looking reply with
;; nothing saying no model was ever called, which is the gotcha that keeps being
;; rediscovered as "the judge is broken".
;;
;; This is the SAME decision `run-chat` makes, read from the same `backend` seam,
;; because one policy now has two askers: the call, which must decide, and the
;; endpoint, which must explain. Two implementations would drift — the shape
;; QUOTA-3 settled for a held job's reason. It is PURE and cheap, so an endpoint
;; may ask it on every request.
;;
;; A NAMED executor is never simulated: a pull worker answers it, or `run-chat`
;; refuses it by name. Only the unnamed local path can fall through to the echo.
(define (chat-simulated? [executor #f])
  (define-values (_u _m _k conf?) (backend executor))
  (and (not conf?) (not executor)))

;; resolve a backend: a named federated executor, else the env-configured local.
;; -> (values url model key configured?)
(define (backend name)
  (cond
    [(and name (executor-config name)) => (lambda (c) (values (car c) (cadr c) (caddr c) #t))]
    [else (values (model-url) (model-name) (model-key) (model-configured?))]))

;; model-exchange : the ONE place a model request leaves this process.
;;
;; Routing (a named push backend, else the env-configured local node), the
;; deadline, the bounded retry and the status check all live here, so a feature
;; that adds one of them cannot reach some callers and miss others. That is not
;; hypothetical: the agent built its own HTTP call, so slice 66's pull executors
;; and slice 67's model roles never applied to it, and it metered an ESTIMATE
;; because it threw the provider's `usage` away.
;;
;; Response PARSING is deliberately NOT here. The agent's tool-call parser takes
;; any registered tool name; the chat parser goes through function-call->tool-block,
;; which drops anything outside `tool-tags`. Folding them together would silently
;; disable every plugin tool.
;;
;; A named executor that is not a push backend is REFUSED rather than quietly
;; served by the local model: a misroute that reports the executor's name back to
;; the caller is the worst shape this can take.
;;
;; -> (values jsexpr url model)
(define (model-exchange messages #:extras [extras (hasheq)] #:temperature [temp 0.7]
                        #:executor [executor #f] #:who [who 'model]
                        ;; LAY-9: what this call REQUIRES of the backend —
                        ;; '(tools), '(json_schema). A backend that declares it
                        ;; cannot do one is refused BY NAME here, instead of the
                        ;; provider answering an opaque 400 three layers down.
                        ;; An undeclared capability is unknown, and unknown is
                        ;; allowed: nothing that works today starts failing.
                        #:needs [needs '()])
  (when (and executor (not (executor-config executor)))
    (error who "executor ~a is not a push backend, so this call cannot be routed to it" executor))
  ;; the named backend's document, or the local model's environment — the local
  ;; path is checked too, because it is the one most calls take
  (let ([bad (if executor (capability-refusal executor needs) (local-capability-refusal needs))])
    (when bad
      (log-model-request! #:executor executor #:transport "push" #:messages messages
                          #:status "refused" #:error-kind "capability")
      (error who "~a" bad)))
  (define-values (url mdl key conf?) (backend executor))
  ;; RED-20 and RED-26: a hosted backend with no no_content_logging declaration
  ;; when the instance requires one, and a document whose sensitivity label this
  ;; executor is not allowed to see unredacted. Refused HERE, before the body is
  ;; composed, because the point of either check is that the content does not
  ;; leave — a refusal after
  ;; the POST would be a report, not a policy. The refusal is itself a row: a
  ;; call that was stopped is exactly what somebody auditing this would look for.
  (let ([bad (and conf? (egress-refusal executor url))])
    (when bad
      (log-model-request! #:executor executor #:transport "push" #:model mdl #:endpoint url
                          #:messages messages #:status "refused" #:error-kind "policy")
      (raise-user-error who "~a" bad)))
  ;; #123: raise-user-error, not `error`. This is a deliberate, documented
  ;; refusal a CALLER has to see — and until the 500 stopped carrying
  ;; exn-message, the only reason it reached them was that leak. It is the
  ;; caller's mistake (or their operator's), so it is a 400.
  (unless conf? (raise-user-error who "no model configured (set TMACH_MODEL_URL)"))
  (define body
    (for/fold ([b (hasheq 'model mdl 'messages (sanitize-wire-messages messages)
                          'temperature temp 'stream #f)])
              ([(k v) (in-hash extras)])
      (hash-set b k v)))
  (define started (current-inexact-milliseconds))
  (define (log! status #:kind [kind #f] #:http [http #f] #:tokens [tokens #f])
    (log-model-request! #:executor executor #:transport "push" #:model mdl #:endpoint url
                        #:messages messages #:tokens tokens #:status status
                        #:error-kind kind #:http-status http #:ms (ms-since started)))
  ;; RED-19: the row is what the request WAS, so a transport failure is logged
  ;; too. A 502 from somebody else's gateway is precisely the row an operator
  ;; auditing a hosted backend came to read, and a log that only recorded
  ;; successes would agree with every happy path.
  (define-values (code resp)
    (with-handlers ([exn:fail? (lambda (e) (log! "error" #:kind (transport-error-kind e)) (raise e))])
      (http-post-json url body (headers* key))))
  (unless (= code 200)
    (log! "error" #:kind "http" #:http code)
    (error who "model endpoint returned HTTP ~a: ~a" code
           (let ([e (hash-ref resp 'error #f)]) (if e (format "~a" e) "no detail"))))
  (log! "ok" #:http 200 #:tokens (response-tokens resp))
  (values resp url mdl))

;; embed-exchange : the ONE place an EMBEDDING request leaves this process.
;;
;; EMB-2: THE POLICY IS SHARED AND THE BODY IS NOT. Everything between the
;; caller and the socket — the egress refusal, the no-content-logging policy, the
;; request log, the transport error classification — is the same question for an
;; embedding as for a chat, and RED-16 is the lesson that made this a seam rather
;; than a call site: `model-exchange`'s own header called itself "the ONE place a
;; model request leaves this process" while `run-chat-stream` and the pull wire
;; each had their own, and a log covering one of three was silent about exactly
;; the paths an operator would check. An embedding sends DOCUMENT TEXT to a
;; backend; it must not be the fourth.
;;
;; What is NOT shared is the body, the response shape and what a token means. A
;; chat reports `total_tokens` over a prompt and a completion; an embedding has
;; an input count and no output at all, which is the shape JUDGE-10 met with
;; `output_tokens` always 0 and answered with a dimension of its own.
;;
;; EMB-4: A NAMED EXECUTOR IS REFUSED BY NAME. An executor's document declares
;; ONE endpoint and it is its chat endpoint, so serving the call from the
;; instance's embedding endpoint while the caller believes it went to the
;; executor is the misroute-that-lies this module refuses everywhere else. Model
;; ROLES point at executors, so this is reachable the moment somebody sets the
;; utility role — it is a refusal, not an impossibility.
;;
;; -> (values (listof (vectorof real)) input-tokens url model)
(define (embed-exchange texts #:executor [executor #f] #:who [who 'embed])
  (when executor
    (log-model-request! #:executor executor #:transport "push" #:operation "embed"
                        #:messages (for/list ([t (in-list texts)])
                                     (hasheq 'role "user" 'content t))
                        #:status "refused" #:error-kind "capability")
    (raise-user-error who
      (string-append "an embedding cannot be routed to the named executor '~a': an executor "
                     "declares one endpoint and it is its chat endpoint. Embeddings use the "
                     "instance's TMACH_EMBED_URL.") executor))
  (define url (embed-url))
  (define mdl (embed-model))
  (define msgs (for/list ([t (in-list texts)]) (hasheq 'role "user" 'content t)))
  ;; the same order model-exchange uses: refuse before composing, because the
  ;; point of either check is that the content does not leave.
  (let ([bad (and (embed-configured?) (egress-refusal #f url))])
    (when bad
      (log-model-request! #:executor #f #:transport "push" #:operation "embed" #:model mdl
                          #:endpoint url #:messages msgs #:status "refused" #:error-kind "policy")
      (raise-user-error who "~a" bad)))
  (unless (embed-configured?)
    (raise-user-error who "no embedding model configured (set TMACH_EMBED_URL)"))
  (when (null? texts) (error who "nothing to embed"))
  (define body (hasheq 'model mdl 'input texts))
  (define started (current-inexact-milliseconds))
  (define (log! status #:kind [kind #f] #:http [http #f] #:tokens [tokens #f])
    (log-model-request! #:executor #f #:transport "push" #:operation "embed" #:model mdl
                        #:endpoint url #:messages msgs #:tokens tokens #:status status
                        #:error-kind kind #:http-status http #:ms (ms-since started)))
  (define-values (code resp)
    (with-handlers ([exn:fail? (lambda (e) (log! "error" #:kind (transport-error-kind e)) (raise e))])
      (http-post-json url body (headers* (embed-key)))))
  (unless (= code 200)
    (log! "error" #:kind "http" #:http code)
    (error who "embedding endpoint returned HTTP ~a: ~a" code
           (let ([e (hash-ref resp 'error #f)]) (if e (format "~a" e) "no detail"))))
  (define vecs (embedding-vectors resp (length texts) who))
  (define toks (embedding-tokens resp))
  (log! "ok" #:http 200 #:tokens toks)
  (values vecs toks url mdl))

;; The OpenAI embeddings response: {"data":[{"index":n,"embedding":[...]},...]}.
;;
;; THE INDEX IS HONOURED RATHER THAN THE ORDER. The field exists precisely
;; because a server may answer out of order, and a nearest-label backend that
;; paired the wrong vector with the wrong label would not fail — it would
;; classify confidently and wrongly, for ever, with every figure in the
;; evaluation harness agreeing that the model is simply poor.
(define (embedding-vectors resp n who)
  (define data (hash-ref resp 'data #f))
  (unless (and (list? data) (= (length data) n))
    (error who "the embedding endpoint returned ~a vector(s) for ~a input(s)"
           (if (list? data) (length data) "no") n))
  (define slots (make-vector n #f))
  (for ([(d i) (in-indexed (in-list data))])
    (define idx (let ([v (hash-ref d 'index i)]) (if (exact-nonnegative-integer? v) v i)))
    (unless (< idx n) (error who "the embedding endpoint returned index ~a for ~a input(s)" idx n))
    (define e (hash-ref d 'embedding #f))
    (unless (and (list? e) (pair? e) (andmap real? e))
      (error who "the embedding endpoint returned no usable vector for input ~a" idx))
    (when (vector-ref slots idx)
      (error who "the embedding endpoint returned index ~a twice" idx))
    (vector-set! slots idx (for/vector ([x (in-list e)]) (exact->inexact x))))
  (define out (vector->list slots))
  (when (memf not out) (error who "the embedding endpoint left an input unanswered"))
  ;; Every vector must have the SAME width, or cosine is meaningless and would
  ;; raise deep inside the arithmetic rather than here, where the endpoint can be
  ;; named.
  (define d0 (vector-length (car out)))
  (unless (andmap (lambda (v) (= (vector-length v) d0)) out)
    (error who "the embedding endpoint returned vectors of differing widths"))
  out)

;; An embedding has an INPUT count and no output. Providers spell it
;; `prompt_tokens`; `total_tokens` is the same number here and is accepted as a
;; fallback. #f when the provider said nothing, which the meter reads as "charge
;; nothing" rather than guessing — an estimate is what the agent used to bill
;; before the model-access consolidation, and it was wrong by two orders.
(define (embedding-tokens resp)
  (define u (hash-ref resp 'usage (hasheq)))
  (define v (or (hash-ref u 'prompt_tokens #f) (hash-ref u 'total_tokens #f)))
  (and (exact-nonnegative-integer? v) v))

;; run-chat : content -> (values reply-text tokens-used).  #:executor routes to a
;; named federated backend; #f uses the local node.
;;
;; `prompt` is a string or a list of content parts (issue #18); a malformed one is
;; refused here rather than becoming an opaque provider 400. #:response-format
;; rides to the provider AND is checked against the reply — a local server that
;; ignores the field must not be able to answer a schema request with prose.
(define (run-chat prompt #:system [system #f] #:temperature [temp 0.7] #:executor [executor #f]
                  #:response-format [rf #f])
  (define-values (_u _m _k conf?) (backend executor))
  (let ([bad (content-problem prompt)]) (when bad (error 'run-chat "~a" bad)))
  (when rf (let ([bad (response-format-problem rf)]) (when bad (error 'run-chat "~a" bad))))
  (define prompt-text (let-values ([(t _p) (content->text prompt)]) t))
  (define msgs
    (append (if system (list (hasheq 'role "system" 'content system)) '())
            (list (hasheq 'role "user" 'content prompt))))
  ;; A PULL executor's content leaves this process too — by the job row, to a
  ;; worker on another host — so it is logged with the same seam and the row says
  ;; `pull` (RED-16). A log that covered only `model-exchange` would be silent
  ;; about the two paths an operator would most want to check.
  ;;
  ;; `endpoint` is deliberately absent: the platform does not know, and must not
  ;; guess, which model URL a worker will call. So the worker's host is NOT
  ;; loopback as far as this row is concerned, which is the honest answer.
  (define pull-started (current-inexact-milliseconds))
  (define routed
    (and executor (not (executor-config executor))
         (let ([bad (egress-refusal executor #f)])
           (when bad
             (log-model-request! #:executor executor #:transport "pull" #:messages msgs
                                 #:status "refused" #:error-kind "policy")
             (raise-user-error 'run-chat "~a" bad))
           (with-handlers ([exn:fail?
                            (lambda (e)
                              (log-model-request! #:executor executor #:transport "pull"
                                                  #:messages msgs #:status "error"
                                                  #:error-kind (transport-error-kind e)
                                                  #:ms (ms-since pull-started))
                              (raise e))])
             (define r ((unbox pull-router) executor msgs temp rf))
             (when r
               (log-model-request! #:executor executor #:transport "pull" #:messages msgs
                                   #:tokens (cdr r) #:status "ok"
                                   #:ms (ms-since pull-started)))
             r))))
  (define (verify! reply)
    (when rf
      (define-values (_parsed problem) (response-format-verify rf reply))
      ;; #123: the CALLER's own request — they supplied the prompt and the schema,
      ;; and the value named here is from the model's reply to it, so the detail
      ;; is theirs and this is a 400. Worth distinguishing from the copy #83
      ;; sealed: a workflow STEP's stored `error` quotes content out of a document
      ;; somebody else may own, and that one is not the requester's to read.
      (when problem
        (raise-user-error 'run-chat "the reply does not honour response_format: ~a" problem))))
  (cond
    [routed (verify! (car routed)) (values (car routed) (cdr routed))]   ; a pull executor answered
    ;; A NAMED executor that neither a pull worker nor the push registry owns must
    ;; not fall through: with a local model it would quietly run there while the
    ;; response still reported the executor's name, and with no local model it
    ;; would hand back the simulated upper-cased echo as if a model had answered.
    [(and executor (not (executor-config executor)))
     (error 'run-chat "executor ~a is not available: no pull worker answered and it is not a push backend" executor)]
    [(not conf?)
     ;; the simulated fallback cannot honour a schema, and pretending it did would
     ;; hand the caller an upper-cased echo as "conforming JSON"
     (when rf (raise-user-error 'run-chat "no model configured: response_format cannot be honoured"))
     (values (string-upcase prompt-text) (estimate-tokens prompt-text))]
    [else
     (define-values (resp _url _mdl)
       (model-exchange msgs #:temperature temp #:executor executor #:who 'run-chat
                       #:needs (if rf '(json_schema) '())
                       #:extras (if rf (hasheq 'response_format rf) (hasheq))))
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
  ;; #173: a fleet request CANNOT stream, and it says so rather than quietly
  ;; streaming from somewhere else. `backend` answers the local model for any
  ;; name it does not own, so without this guard a caller who asked for the
  ;; fleet would be served by this box while the response named `@fleet` — the
  ;; "misroute that lies about where it ran" this module already refuses for a
  ;; named executor that is not a push backend. A pull worker returns a whole
  ;; reply on a job row; there is no token stream to forward.
  (when (equal? executor "@fleet")
    (raise-user-error 'run-chat
                      (string-append "the fleet cannot stream: a worker answers with a whole reply, "
                                     "not a token stream — use POST /api/ai/chat")))
  (define-values (url mdl key conf?) (backend executor))
  (let ([bad (content-problem prompt)]) (when bad (error 'run-chat "~a" bad)))
  (when rf (let ([bad (response-format-problem rf)]) (when bad (error 'run-chat "~a" bad))))
  (define prompt-text (let-values ([(t _p) (content->text prompt)]) t))
  (cond
    [(not conf?)
     (when rf (raise-user-error 'run-chat "no model configured: response_format cannot be honoured"))
     (define reply (string-upcase prompt-text))                ; simulated: stream word by word
     (for ([w (in-list (string-split reply))]) (on-token (string-append w " ")) (sleep 0.06))
     (values (estimate-tokens prompt-text) reply)]
    [else
     (define acc (open-output-string))
     (define (tap s) (write-string s acc) (on-token s))
     (define msgs
       (append (if system (list (hasheq 'role "system" 'content system)) '())
               (list (hasheq 'role "user" 'content prompt))))
     ;; RED-16: a stream does not go through `model-exchange` — it calls
     ;; `openai-llm-stream` directly — and it is still content crossing the
     ;; network. It is logged with transport `stream`, and the policy gate
     ;; applies before the first byte for the same reason it does there.
     (let ([bad (egress-refusal executor url)])
       (when bad
         (log-model-request! #:executor executor #:transport "stream" #:model mdl
                             #:endpoint url #:messages msgs #:status "refused"
                             #:error-kind "policy")
         (raise-user-error 'run-chat "~a" bad)))
     (define started (current-inexact-milliseconds))
     (with-handlers ([exn:fail?
                      (lambda (e)
                        (log-model-request! #:executor executor #:transport "stream" #:model mdl
                                            #:endpoint url #:messages msgs #:status "error"
                                            #:error-kind (transport-error-kind e)
                                            #:ms (ms-since started))
                        (raise e))])
       ((openai-llm-stream #:endpoint url #:model mdl #:api-key key
                           #:temperature temp #:on-content tap #:response-format rf) msgs))
     (define text (get-output-string acc))
     ;; the provider's own count is not available on this wire, so the row's
     ;; `tokens_used` is the estimate the caller is metered on — the same number,
     ;; so the log cannot disagree with the ledger
     (define tokens (estimate-tokens prompt-text text))
     (log-model-request! #:executor executor #:transport "stream" #:model mdl #:endpoint url
                         #:messages msgs #:tokens tokens #:status "ok" #:ms (ms-since started))
     (values tokens text)]))
