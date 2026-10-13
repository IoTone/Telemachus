#lang racket/base

;; domain/agent/run.rkt — the agent flow: wire the pure run-agent spine to a real
;; model (tool-calling) and the plugin tool registry. Emits events (assistant
;; text, tool call, tool result, done) for streaming.
;;
;; Tools come from the registry (registry.rkt); the model is only offered the
;; team's ENABLED tools, and dispatch re-checks enablement + per-tool RBAC.

(require "artifact.rkt" racket/string
         json
         "loop.rkt"                     ; run-agent, assistant-msg, agent-result (+accessors)
         "../tools/convert.rkt"         ; tool-block struct
         "registry.rkt"                 ; tool-by-name, tool-enabled?, enabled-tool-schemas, tool-*
         "tools.rkt"                    ; side effect: registers the built-in tools
         "../authz/authz.rkt"           ; can?, exn:fail:forbidden, principal-*
         "../ai/executor.rkt"           ; model-exchange, response-tokens, model-configured?
         "../exec/federation.rkt")      ; executor-exists? — is a name a push backend?
(require (only-in "../ai/content.rkt" content->text))

(provide run-agent-flow agent-configured? make-exec parse-agent-response dispatch-tool)

(define SYSTEM
  (string-append
   "You are Telemachus, a concise team assistant. Use the provided tools to act on "
   "the user's request — create or update notes, list notes, or report AI usage. Prefer "
   "calling a tool over guessing. After the tools run, reply with a short natural-language summary."))

(define (agent-configured?) (model-configured?))

;; ---- native model adapter (tool-calling) ------------------------------------
;; The request itself goes through model-exchange, so this module no longer builds
;; headers, a body or an HTTP call of its own — that duplication is why routing and
;; real token accounting never reached the agent. What stays here is the PARSER,
;; which is deliberately more permissive than llm.rkt's: it accepts any registered
;; tool name, where function-call->tool-block drops anything outside `tool-tags`.
;; Folding the two together would silently disable every plugin tool.
(define (raw-call id name args)
  (hasheq 'id id 'type "function" 'function (hasheq 'name name 'arguments args)))

(define (parse-agent-response resp)
  (define choices (hash-ref resp 'choices '()))
  (define msg (if (pair? choices) (hash-ref (car choices) 'message (hasheq)) (hasheq)))
  (define tcs (let ([t (hash-ref msg 'tool_calls '())]) (if (list? t) t '())))
  ;; content PARTS are read, not silently emptied (issue #18); unreadable content
  ;; is an error only when the turn carries no tool calls either
  (define content
    (let-values ([(text problem) (content->text (hash-ref msg 'content 'null))])
      (when (and problem (null? tcs))
        (error 'agent "the model's reply could not be read as text: ~a" problem))
      text))
  (define pairs
    (for/list ([tc (in-list tcs)] [i (in-naturals)])
      (define fn (hash-ref tc 'function (hasheq)))
      (define name (hash-ref fn 'name ""))
      (define args (let ([a (hash-ref fn 'arguments "{}")]) (if (string? a) a (jsexpr->string a))))
      (cons (tool-block name args)
            (raw-call (let ([id (hash-ref tc 'id #f)]) (if (string? id) id (format "call_~a" i))) name args))))
  (assistant-msg content (map car pairs) (map cdr pairs)))

;; #:temperature 0 — tool SELECTION should be deterministic; at the provider
;; default small local models pick tools flakily. `usage` accumulates the
;; provider's own token counts across rounds, which is what the endpoint meters
;; now instead of estimating from the prompt length.
(define (make-llm tools executor usage)
  (lambda (messages)
    (define-values (resp _url _mdl)
      (model-exchange messages #:extras (hasheq 'tools tools 'tool_choice "auto")
                      #:temperature 0 #:executor executor #:who 'agent
                      ;; the agent IS tool calling — a backend that cannot do it
                      ;; produces a turn with no tool calls and a plausible
                      ;; sentence, which looks like the model declining rather
                      ;; than like a misconfiguration
                      #:needs '(tools)))
    (let ([t (response-tokens resp)]) (when t (set-box! usage (+ (unbox usage) t))))
    (parse-agent-response resp)))

;; ---- dispatch (registry + enablement + RBAC) --------------------------------
(define (parse-args s)
  (with-handlers ([exn:fail? (lambda (_) (hasheq))])
    (let ([j (string->jsexpr s)]) (if (hash? j) j (hasheq)))))

(define (dispatch-tool conn p name args)
  (with-handlers ([exn:fail:forbidden?
                   (lambda (e) (format "Permission denied: ~a" (exn:fail:forbidden-permission e)))]
                  [exn:fail? (lambda (e) (format "Error: ~a" (exn-message e)))])
    (define t (tool-by-name name))
    (cond
      [(not t) (format "Unknown tool: ~a" name)]
      [(not (tool-enabled? conn (principal-team-id p) name)) (format "Tool '~a' is disabled" name)]
      [(not (can? conn p "tools:invoke")) "Permission denied: tools:invoke"]
      [(and (tool-perm t) (not (can? conn p (tool-perm t)))) (format "Permission denied: ~a" (tool-perm t))]
      [else
       ;; The agent transcript needs text, but a handler may return structured data
       ;; for the WORKFLOW engine's benefit (a `map #:over` needs a real array —
       ;; see repo_list_unindexed). Stringify at this boundary, not in the handler,
       ;; so one handler serves both surfaces.
       (define r ((tool-handler t) conn p args))
       (cond [(string? r) r]
             ;; an artifact names a thing; the model gets the name, not the payload
             [(artifact? r) (artifact->text r)]
             [else (jsexpr->string r)])])))

;; the raw handler result, for the console's event — text for the model, the
;; artifact (if any) beside it for a card
(define (dispatch-tool/artifact conn p name args)
  (define t (tool-by-name name))
  (define ok? (and t (tool-enabled? conn (principal-team-id p) name)
                   (can? conn p "tools:invoke") (or (not (tool-perm t)) (can? conn p (tool-perm t)))))
  (cond
    [(not ok?) (values (dispatch-tool conn p name args) #f)]
    [else
     (define r (with-handlers ([exn:fail? (lambda (e) (format "Error: ~a" (exn-message e)))])
                 ((tool-handler t) conn p args)))
     (cond [(string? r) (values r #f)]
           [(artifact? r) (values (artifact->text r) (artifact-of r))]
           [else (values (jsexpr->string r) #f)])]))

(define (make-exec conn p on-event)
  (lambda (tb)
    (define name (tool-block-type tb))
    (define args (parse-args (tool-block-content tb)))
    (on-event (hasheq 'type "tool" 'name name 'args args))
    (define-values (result art) (dispatch-tool/artifact conn p name args))
    (on-event (if art
                  (hasheq 'type "tool_result" 'name name 'result result 'artifact art)
                  (hasheq 'type "tool_result" 'name name 'result result)))
    result))

;; ---- the flow ---------------------------------------------------------------
(define (last-assistant-text result)
  (let loop ([tx (reverse (agent-result-transcript result))])
    (cond [(null? tx) ""]
          [(and (eq? (car (car tx)) 'assistant) (not (string=? (caddr (car tx)) ""))) (caddr (car tx))]
          [else (loop (cdr tx))])))

;; -> (values agent-result tokens-used)
;;
;; #:executor routes the whole loop to a named PUSH backend. A pull executor is
;; refused by name: its wire is infer.chat, which carries a reply and a token
;; count — not tool calls — so routing a tool-using turn there would silently
;; drop every tool.
(define (run-agent-flow conn p user-text on-event #:max-rounds [max-rounds 6] #:executor [executor #f])
  (when (and executor (not (executor-exists? executor)))
    (error 'agent
           (string-append "the agent runs on a push backend; ~a is not one. A pull executor "
                          "answers infer.chat, which carries a reply rather than tool calls.")
           executor))
  (define tools (enabled-tool-schemas conn (principal-team-id p)))
  (define usage (box 0))
  (define base-llm (make-llm tools executor usage))
  (define llm
    (lambda (msgs)
      (define m (base-llm msgs))
      (define txt (assistant-msg-text m))
      (when (and txt (not (string=? txt ""))) (on-event (hasheq 'type "assistant" 'text txt)))
      m))
  (define result (run-agent (list (hasheq 'role "system" 'content SYSTEM)
                                   (hasheq 'role "user" 'content user-text))
                            #:llm llm #:exec (make-exec conn p on-event) #:max-rounds max-rounds))
  (on-event (hasheq 'type "done" 'reply (last-assistant-text result)
                    'rounds (agent-result-rounds result)
                    'tokens_used (unbox usage)
                    'status (symbol->string (agent-result-status result))))
  (values result (unbox usage)))
