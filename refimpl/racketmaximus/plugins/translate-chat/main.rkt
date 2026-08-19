#lang racket/base

;; plugins/translate-chat/main.rkt — the first plugin to ship a WORKFLOW, not just
;; tools. It is a deliberate exercise of the engine rather than a useful product:
;;
;;   1. chat_message   one real model turn, in the user's own language
;;   2. to_all         fan out: translate that reply to es / nl / is  (3 jobs)
;;   3. back_home      fan out: translate each of those BACK to ${principal.locale}
;;
;; What it is actually testing: a plugin-registered tool used as a workflow step, a
;; step whose output feeds two later steps, two chained `map` fan-outs where the
;; second maps over the first's results, the profile language as a binding, and —
;; when a step is made to fail — a run that stops immediately and hands the reason
;; back to whoever started it.
;;
;; The round trip is meant to be lossy. Comparing the three returns against the
;; original is the point: it is a translation-quality smoke test you can read.

(require racket/string
         json
         "../../domain/apps/translate.rkt"      ; translate!
         "../../domain/ai/executor.rkt"         ; run-chat, model-configured?
         "../../domain/authz/authz.rkt"         ; require-perm, principal-user-id, user-locale
         "../../domain/flow/dsl.rkt")           ; define-workflow

(provide tools workflows)

;; ---- helpers ----------------------------------------------------------------
(define (arg args k [d ""])
  (define v (hash-ref args k d))
  (cond [(eq? v 'null) d] [(string? v) v] [else (format "~a" v)]))

(define (schema name desc props required)
  (hasheq 'type "function"
          'function (hasheq 'name name 'description desc
                            'parameters (hasheq 'type "object" 'properties props 'required required))))

;; ---- tools ------------------------------------------------------------------
;; One chat turn. This is "the custom chat window's" server side: the message the
;; user typed goes to the model in their own language, and the reply is what the
;; rest of the workflow chews on.
(define chat-message-schema
  (schema "chat_message" "Send one chat message to the model and return its reply."
          (hasheq 'text (hasheq 'type "string" 'description "What the user said"))
          '("text")))

(define (chat-message conn p args)
  (unless (model-configured?)
    ;; Without this the platform's uppercase-echo fallback answers, the workflow
    ;; goes green, and the demo proves nothing. Fail loudly instead.
    (error 'translate-chat "no model configured — set TELEMACHUS_MODEL_URL"))
  (require-perm conn p "chat:use")
  (define locale (user-locale conn (principal-user-id p)))
  (define-values (reply _tokens)
    (run-chat (arg args 'text)
              #:system (string-append "You are a friendly assistant. Reply in " (lang-label locale)
                                      ", in two sentences at most. Plain prose, no lists, no preamble.")))
  reply)

(define translate-text-schema
  (schema "translate_text" "Translate text into a target language."
          (hasheq 'text   (hasheq 'type "string" 'description "The text to translate")
                  'target (hasheq 'type "string" 'description "Target language code, e.g. es, nl, is")
                  'source (hasheq 'type "string" 'description "Source language code, or auto"))
          '("text" "target")))

(define (translate-text conn p args)
  (unless (model-configured?)
    (error 'translate-chat "no model configured — set TELEMACHUS_MODEL_URL"))
  (define text (arg args 'text))
  (when (string=? (string-trim text) "")
    (error 'translate-chat "nothing to translate — the previous step produced no text"))
  (define-values (tr _tokens)
    (translate! conn p #:text text #:target-lang (arg args 'target "en")
                #:source-lang (arg args 'source "auto")))
  (hash-ref tr 'result))

(define tools
  (list (list "chat_message"   chat-message-schema   "chat:use" chat-message)
        (list "translate_text" translate-text-schema "chat:use" translate-text)))

;; ---- the workflow -----------------------------------------------------------
;; Written in Racket, checked when this module compiles, and shipped as the spec
;; the macro emits — a deployer can read it at GET /api/workflows/translate-chat
;; without reading any of the above.
(define-workflow translate-chat
  #:name "Translate Chat Workflow"
  #:description "Chat once, fan the reply out to Spanish, Dutch and Icelandic, then bring each back."
  #:input ([message string])
  #:max-steps 20

  (step chat (tool chat_message #:text (in message)))

  (step to_all (map #:over (list "es" "nl" "is")
                    (tool translate_text #:text (out chat result) #:target (item) #:source (locale))
                    #:retry 1))

  (step back_home (map #:over (out to_all results)
                       (tool translate_text #:text (item result) #:target (locale))
                       #:retry 1)
        #:end))

(define workflows (list translate-chat))
