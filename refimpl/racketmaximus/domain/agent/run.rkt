#lang racket/base

;; domain/agent/run.rkt — the agent flow: wire the pure run-agent spine to a real
;; model (tool-calling) and a real, RBAC-checked tool dispatcher. Emits events
;; (assistant text, tool call, tool result, done) so the server can stream them.
;;
;; Model tool_calls are parsed natively here (name + raw JSON args) — we do NOT
;; go through the Odysseus-catalog converter; the agent's own tool set drives it.

(require racket/string
         json
         "loop.rkt"                     ; run-agent, assistant-msg, agent-result (+accessors)
         "../tools/convert.rkt"         ; tool-block struct
         "tools.rkt"                    ; agent-tool-schemas, tool-permission
         "../authz/authz.rkt"           ; can?, exn:fail:forbidden, principal-*
         "../notes/notes.rkt"           ; handlers
         "../quota/quota.rkt"           ; get_usage
         "../ai/executor.rkt")          ; model-url/name/key, model-configured?
(require (only-in "llm.rkt" http-post-json))

(provide run-agent-flow agent-configured? make-exec parse-agent-response)

(define SYSTEM
  (string-append
   "You are Telemachus, a concise team assistant. Use the provided tools to act on "
   "the user's request — create notes, list notes, or report AI usage. Prefer calling "
   "a tool over guessing. After the tools run, reply with a short natural-language summary."))

(define (agent-configured?) (model-configured?))

;; ---- native model adapter (tool-calling) ------------------------------------
(define wire-keys '(role content name tool_call_id tool_calls))
(define (sanitize msgs)
  (for/list ([m (in-list msgs)])
    (for/fold ([h (hasheq)]) ([k (in-list wire-keys)])
      (if (hash-has-key? m k) (hash-set h k (hash-ref m k)) h))))

(define (raw-call id name args)
  (hasheq 'id id 'type "function" 'function (hasheq 'name name 'arguments args)))

;; OpenAI-compatible response → assistant-msg with tool-blocks (type=name,
;; content=raw JSON args) and the aligned raw tool_call objects.
(define (parse-agent-response resp)
  (define choices (hash-ref resp 'choices '()))
  (define msg (if (pair? choices) (hash-ref (car choices) 'message (hasheq)) (hasheq)))
  (define content (let ([c (hash-ref msg 'content 'null)]) (if (string? c) c "")))
  (define tcs (let ([t (hash-ref msg 'tool_calls '())]) (if (list? t) t '())))
  (define pairs
    (for/list ([tc (in-list tcs)] [i (in-naturals)])
      (define fn (hash-ref tc 'function (hasheq)))
      (define name (hash-ref fn 'name ""))
      (define args (let ([a (hash-ref fn 'arguments "{}")]) (if (string? a) a (jsexpr->string a))))
      (cons (tool-block name args)
            (raw-call (let ([id (hash-ref tc 'id #f)]) (if (string? id) id (format "call_~a" i))) name args))))
  (assistant-msg content (map car pairs) (map cdr pairs)))

(define (make-llm tools)
  (define headers
    (append (list "Content-Type: application/json")
            (if (model-key) (list (string-append "Authorization: Bearer " (model-key))) '())))
  (lambda (messages)
    (define body (hasheq 'model (model-name) 'messages (sanitize messages)
                         'tools tools 'tool_choice "auto" 'temperature 0 'stream #f))
    (define-values (code resp) (http-post-json (model-url) body headers))
    (unless (= code 200) (error 'agent "model endpoint returned HTTP ~a" code))
    (parse-agent-response resp)))

;; ---- tool dispatch (RBAC-checked) -------------------------------------------
(define (jget h k [d ""]) (let ([v (hash-ref h (string->symbol k) d)]) (if (eq? v 'null) d v)))
(define (parse-args s)
  (with-handlers ([exn:fail? (lambda (_) (hasheq))])
    (let ([j (string->jsexpr s)]) (if (hash? j) j (hasheq)))))

;; make-exec : conn × principal × (event -> void) -> (tool-block -> result-string)
(define (make-exec conn p on-event)
  (lambda (tb)
    (define name (tool-block-type tb))
    (define args (parse-args (tool-block-content tb)))
    (on-event (hasheq 'type "tool" 'name name 'args args))
    (define result
      (with-handlers ([exn:fail:forbidden?
                       (lambda (e) (format "Permission denied: ~a" (exn:fail:forbidden-permission e)))]
                      [exn:fail? (lambda (e) (format "Error: ~a" (exn-message e)))])
        (define perm (hash-ref tool-permission name #f))
        (cond
          [(not (can? conn p "tools:invoke")) "Permission denied: tools:invoke"]
          [(and perm (not (can? conn p perm))) (format "Permission denied: ~a" perm)]
          [else
           (case name
             [("create_note")
              (define vis (let ([v (jget args "visibility" "team")]) (if (string=? v "") "team" v)))
              (define n (notes-create conn p #:title (jget args "title") #:body (jget args "body") #:visibility vis))
              (format "Created note \"~a\" (~a), id ~a" (hash-ref n 'title) (hash-ref n 'visibility) (hash-ref n 'id))]
             [("list_notes")
              (define ns (notes-list conn p))
              (if (null? ns) "You have no notes."
                  (string-join (for/list ([n (in-list ns)]) (format "- ~a [~a]" (hash-ref n 'title) (hash-ref n 'visibility))) "\n"))]
             [("get_usage")
              (string-join
               (for/list ([d (in-list '("ai.tokens.total" "ai.requests"))])
                 (define q (quota-check conn "team" (principal-team-id p) d 0))
                 (format "~a: ~a/~a used" d (hash-ref q 'used) (hash-ref q 'limit))) "; ")]
             [else (format "Unknown tool: ~a" name)])])))
    (on-event (hasheq 'type "tool_result" 'name name 'result result))
    result))

;; ---- the flow ---------------------------------------------------------------
(define (last-assistant-text result)
  (let loop ([tx (reverse (agent-result-transcript result))])
    (cond [(null? tx) ""]
          [(and (eq? (car (car tx)) 'assistant) (not (string=? (caddr (car tx)) ""))) (caddr (car tx))]
          [else (loop (cdr tx))])))

(define (run-agent-flow conn p user-text on-event #:max-rounds [max-rounds 6])
  (define tools (agent-tool-schemas))
  (define base-llm (make-llm tools))
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
                    'status (symbol->string (agent-result-status result))))
  result)
