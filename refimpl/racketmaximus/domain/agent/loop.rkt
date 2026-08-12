#lang racket/base

;; domain/agent/loop.rkt — the agent loop's *control spine*, as a pure driver.
;;
;; A full agent loop is large (prompt assembly, endpoint detection, retrieval,
;; LLM/tool I/O), but the actual state machine is small and universal:
;;
;;   each round: ask the model →
;;     • no tool calls  → the text is the final answer            → DONE
;;     • tool calls     → run them, feed results back, next round → CONTINUE
;;     • round cap hit                                            → MAX-ROUNDS
;;
;; Here that spine is a deterministic function with the two effects *injected*
;; (#:llm and #:exec), so it's testable without a model or real tools — and the
;; I/O adapter (real LLM client + tool executor) is the only impure part, kept
;; at the edges. Tool calls arrive as `tool-block`s (from domain/tools/convert).
;;
;; Provenance: the agent-loop / tool-execution *patterns* here descend from
;; opencode (MIT). See ../../../../ACKNOWLEDGMENTS.md.

(require racket/match
         racket/string
         "../tools/convert.rkt"      ; tool-block, tool-block-type/content
         "prompt-security.rkt")      ; untrusted-context-message

(provide (struct-out assistant-msg)
         (struct-out agent-result)
         run-agent)

;; what an #:llm turn yields: the model's text, the tool calls it requested
;; (as tool-blocks for #:exec), and the *raw* OpenAI tool_call objects aligned
;; 1:1 with tool-blocks — so the loop can echo them back in the real protocol
;; (assistant.tool_calls + role:"tool" with tool_call_id). Strict chat templates
;; (e.g. local qwen via ollama) require this; lenient ones (gpt-4o) don't, but
;; sending it is correct for both. raw-calls may be '() (e.g. in unit tests),
;; in which case the loop falls back to a flattened user turn.
(struct assistant-msg (text tool-blocks raw-calls) #:transparent)

;; how the loop ended. status: 'done | 'max-rounds
;; transcript: list of events, oldest first —
;;   (list 'assistant round text) | (list 'tools round (list (type . result) ...))
(struct agent-result (status rounds transcript) #:transparent)

;; run-agent : (listof message) -> agent-result
;;   #:llm  (messages) -> assistant-msg          [injected effect]
;;   #:exec (tool-block) -> string (result text) [injected effect]
(define (run-agent initial-messages
                   #:llm llm
                   #:exec exec
                   #:max-rounds [max-rounds 50])
  (let loop ([messages initial-messages] [round 1] [transcript '()])
    (cond
      [(> round max-rounds)
       (agent-result 'max-rounds (sub1 round) (reverse transcript))]
      [else
       (define msg (llm messages))
       (define tx (cons (list 'assistant round (assistant-msg-text msg)) transcript))
       (match (assistant-msg-tool-blocks msg)
         ['()  ; no tool calls — model's text is the final answer
          (agent-result 'done round (reverse tx))]
         [blocks
          (define results
            (for/list ([b (in-list blocks)])
              (cons (tool-block-type b) (exec b))))
          (define raw (assistant-msg-raw-calls msg))
          ;; Real OpenAI protocol when we have raw tool_calls aligned with the
          ;; results; otherwise the legacy flattened user turn (keeps the spine
          ;; usable without an OpenAI-shaped llm, e.g. in tests).
          (define follow-ups
            (if (and (pair? raw) (= (length raw) (length results)))
                (cons (hasheq 'role "assistant" 'content (assistant-msg-text msg)
                              'tool_calls raw)
                      (for/list ([rc (in-list raw)] [r (in-list results)])
                        (hasheq 'role "tool"
                                'tool_call_id (hash-ref rc 'id "call_0")
                                'content (cdr r))))
                ;; The non-native (prompted) path feeds tool output back as a
                ;; user turn — wrapped as untrusted data so prompt-injection
                ;; inside a tool result (fetched page, file read, MCP/email body)
                ;; is treated as data, not instructions. The security model
                ;; requires tool output go through the untrusted-context wrapper;
                ;; the native path above is covered by the tool-role protocol.
                (list (hasheq 'role "assistant" 'content (assistant-msg-text msg))
                      (untrusted-context-message "tool execution results"
                                                 (results->text results)))))
          (loop (append messages follow-ups)
                (add1 round)
                (cons (list 'tools round results) tx))])])))

;; Render tool results back into a user turn the model reads next round.
(define (results->text results)
  (string-join
   (for/list ([r (in-list results)]) (format "[~a]\n~a" (car r) (cdr r)))
   "\n\n"))
