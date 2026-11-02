#lang racket/base

;; domain/agent/run.rkt — the agent flow: wire the pure run-agent spine to a real
;; model (tool-calling) and the plugin tool registry. Emits events (assistant
;; text, tool call, tool result, done) for streaming.
;;
;; Tools come from the registry (registry.rkt); the model is only offered the
;; team's ENABLED tools, and dispatch re-checks enablement + per-tool RBAC.

(require "artifact.rkt" racket/string
         json
         (only-in racket/list partition)
         "loop.rkt"                     ; run-agent, assistant-msg, agent-result (+accessors)
         "../tools/convert.rkt"         ; tool-block struct
         "registry.rkt"                 ; tool-by-name, tool-enabled?, agent-tool-schemas, tool-*
         "tools.rkt"                    ; side effect: registers the built-in tools
         "../authz/authz.rkt"           ; can?, exn:fail:forbidden, principal-*
         "../ai/executor.rkt"           ; model-exchange, response-tokens, model-configured?,
                                        ; max-input-chars/model-context — #231's budget
         "../exec/federation.rkt")      ; executor-exists? — is a name a push backend?
(require (only-in "../ai/content.rkt" content->text))

(provide run-agent-flow agent-configured? make-exec parse-agent-response dispatch-tool
         ;; exported FOR test/agent-tools-tests.rkt: every caller of the flow
         ;; needs a live model, so the fitting rule is only reachable directly.
         ;; An export with a test behind it is not an over-wide export (#110 r4).
         fit-tools tool-schema-name withheld-tools-message CORE-TOOLS)

(define SYSTEM
  (string-append
   "You are Telemachus, a concise team assistant. Use the provided tools to act on "
   "the user's request — create or update notes, list notes, or report AI usage. Prefer "
   "calling a tool over guessing. After the tools run, reply with a short natural-language summary."))

(define (agent-configured?) (model-configured?))

;; THE PROSE ABOVE NAMES FOUR TOOLS, SO THOSE FOUR ARE OFFERED FIRST. A system
;; prompt that instructs a model to use a tool it was not given is the failure
;; this whole section is about, and it is the state the demo instance was in:
;; seven document-pipeline tools filled 7,662 of the 7,680-character budget and
;; every one of these four was withheld. Keep this list and that sentence in
;; step; `test/agent-tools-tests.rkt` asserts each one is registered and each one
;; survives the shipped budget, so dropping one here fails rather than drifting.
(define CORE-TOOLS '("create_note" "update_note" "list_notes" "get_usage"))

;; ---- THE TOOL LIST HAS TO FIT THE WINDOW, AND IT DID NOT ---------------------
;;
;; Reported from outside: the agent tab's own shipped example prompt — "create a
;; private note titled Q3 goals … then list my notes" — created SIX notes, the
;; first correct and five degenerate, two of them with no body at all. The model
;; was not at fault and neither was the parser; both were measured.
;;
;; WHAT WAS WRONG IS THAT THE PROMPT WAS FULL BEFORE THE USER TYPED ANYTHING.
;; `enabled-tool-schemas` offers every registered tool, which on this build is
;; 24 of them at **21,538 characters** of JSON schema — roughly 5,600 tokens
;; into ollama's 4,096-token default window. Measured against the live model:
;;
;;     tools offered   schema chars   prompt_tokens   what came back
;;     4 (the notes
;;        and usage)          1,130             408   one correct create + list
;;     24 (all of them)      22,599           4,095   "the tools provided do not
;;                                                     include functionality for
;;                                                     creating notes" — while
;;                                                     calling create_note
;;
;; Past the window the prompt is discarded OLDEST FIRST, and the oldest message
;; is the system prompt; next is the user's instruction. So the model is left
;; holding a tool list with no task, invents a plausible call from the tool
;; NAMES, is handed a result it cannot relate to anything, and calls again. The
;; live `model_requests` rows for the reported run read `prompt_tokens` 4,095 on
;; every one of six rounds while the MESSAGES were 356 characters.
;;
;; THE REMEDY IS TO OFFER WHAT FITS AND SAY WHAT DID NOT. Refusing the whole run
;; would be defensible and is the wrong trade: an instance on the documented
;; default would have no agent at all, where four tools in the window is a
;; working agent. Silently dropping tools is the other wrong trade — so the
;; names of what was withheld ride on the run's own `done` event and the console
;; says them. It is `truncated`'s posture (CLS-27, VEC-29) and
;; `content_search: false`'s: report what did not run, keep what did.
;;
;; THE ORDER DECIDES WHAT SURVIVES, AND IT USED TO BE AN ACCIDENT. This paragraph
;; said "the registry's, which puts the built-ins first" — and the registry's
;; order is MODULE INSTANTIATION order, so what came first was whatever
;; `server/main.rkt` happened to require first. On the demo instance that was
;; doc-tools, and the arithmetic is exact: doc_text 473 + doc_classify 3,140 +
;; doc_list_unclassified 750 + doc_classify_eval 2,369 + repo_list_unindexed 331
;; + repo_extract_text 270 + repo_embed_chunks 329 = **7,662 of 7,680**, so the
;; next tool of any size was refused and the four the system prompt names came
;; 14th to 17th. Nothing failed; the agent simply had none of its own tools.
;;
;; So `CORE-TOOLS` goes first by NAME, and everything else keeps registry order,
;; which for plugins is load order and is the only meaningful order there is —
;; still not sorted, because sorting by name would be arbitrary and sorting by
;; size would permanently exclude whichever essential tool is fattest. A tool
;; whose schema does not fit the remaining budget is SKIPPED rather than ending
;; the walk, so one fat schema (`doc_classify` is 3,140 characters by itself)
;; cannot shut out the small ones behind it.
;;
;; AND THE LIST IS SHORTER NOW BECAUSE HALF OF IT WAS NEVER THE AGENT'S.
;; `#:agent? #f` (registry.rkt) keeps the drain listers, their map children and
;; the evaluation harness off this surface entirely — ten tools and 6,423
;; characters that no person asks for in a sentence. That is the fix; this budget
;; walk is the backstop behind it.
;;
;; THE BUDGET IS HALF THE WINDOW'S CHARACTERS — `max-input-chars`, #231's one
;; number, reused rather than re-derived. What the other half pays for is the
;; system prompt, the user's text, the transcript (which GROWS every round as
;; tool results are fed back) and the completion. An operator who needs a tool
;; this budget excludes has the lever already: `tool_settings` disables the ones
;; a team does not use, per team, and what is left then fits.
(define (tool-schema-name sch)
  (with-handlers ([exn:fail? (lambda (_) "?")])
    (hash-ref (hash-ref sch 'function (hasheq)) 'name "?")))

;; -> (values kept withheld-names)
(define (fit-tools schemas [budget (max-input-chars)] #:first [first-names CORE-TOOLS])
  (define-values (head tail)
    (partition (lambda (sch) (and (member (tool-schema-name sch) first-names) #t)) schemas))
  (let loop ([rest (append head tail)] [left budget] [kept '()] [out '()])
    (cond
      [(null? rest) (values (reverse kept) (reverse out))]
      [else
       (define sch (car rest))
       (define cost (string-length (jsexpr->string sch)))
       (if (<= cost left)
           (loop (cdr rest) (- left cost) (cons sch kept) out)
           (loop (cdr rest) left kept (cons (tool-schema-name sch) out)))])))

(define (withheld-tools-message withheld)
  (format (string-append
           "~a tool(s) were not offered to the model because the whole tool list does not fit"
           " its context window (~a tokens): ~a. Disable the tools this team does not need"
           " (Usage > Tools), or raise the window on the model server itself (for ollama,"
           " OLLAMA_CONTEXT_LENGTH) and set TMACH_MODEL_CONTEXT to match.")
          (length withheld) (model-context) (string-join withheld ", ")))

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
  (define-values (tools withheld) (fit-tools (agent-tool-schemas conn (principal-team-id p))))
  (unless (null? withheld)
    (on-event (hasheq 'type "tools_withheld" 'names withheld
                      'message (withheld-tools-message withheld))))
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
                    'tools_offered (length tools)
                    ;; QUOTA-3's rule: the key says something only when there is
                    ;; something to say, so an instance whose whole tool list
                    ;; fits carries no `tools_withheld` at all.
                    'tools_withheld withheld
                    'status (symbol->string (agent-result-status result))))
  (values result (unbox usage)))
