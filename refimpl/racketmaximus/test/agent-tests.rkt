#lang racket/base

;; test/agent-tests.rkt — agent mode: native tool-call parsing + RBAC-checked
;; dispatch. The model round-trip needs a live model; here we pin the pure parser
;; and the exec dispatcher.  raco test test/agent-tests.rkt

(require rackunit db-kit/portable json
         db-kit/migrate
         "../domain/db/migrations.rkt"
         "db-fixture.rkt"
         "../domain/authz/authz.rkt"
         "../domain/agent/loop.rkt"       ; assistant-msg accessors
         "../domain/agent/run.rkt"        ; parse-agent-response, make-exec, fit-tools, CORE-TOOLS
         "../domain/agent/registry.rkt"   ; set-tool-enabled!, tool-settings-for
         "../domain/tools/convert.rkt")   ; tool-block

(define (fresh) (define c (fresh-db #:migrate? #f)) (migrate! c all-migrations) c)

(test-case "parse-agent-response: content + native tool_calls"
  (define resp
    (hasheq 'choices
            (list (hasheq 'message
                          (hasheq 'content 'null
                                  'tool_calls
                                  (list (hasheq 'id "call_1"
                                                'function (hasheq 'name "create_note"
                                                                  'arguments "{\"title\":\"T\",\"body\":\"B\"}"))))))))
  (define m (parse-agent-response resp))
  (check-equal? (assistant-msg-text m) "")
  (check-equal? (map tool-block-type (assistant-msg-tool-blocks m)) '("create_note"))
  (check-equal? (tool-block-content (car (assistant-msg-tool-blocks m))) "{\"title\":\"T\",\"body\":\"B\"}")
  (check-equal? (hash-ref (car (assistant-msg-raw-calls m)) 'id) "call_1"))

(test-case "make-exec: create_note, list_notes, RBAC denial, event emission"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice"))
  (define bob (create-user! c #:username "bob"))
  (add-member! c #:user bob #:team tid #:role "viewer")     ; viewer: no tools:invoke
  (define events '())
  (define (ev e) (set! events (cons e events)))
  (define exec (make-exec c (user-principal c uid tid) ev))
  (check-true (regexp-match? #rx"Created note"
                             (exec (tool-block "create_note" "{\"title\":\"Hello\",\"body\":\"World\",\"visibility\":\"private\"}"))))
  (check-true (regexp-match? #rx"Hello" (exec (tool-block "list_notes" "{}"))))
  (check-true (>= (length events) 4))                        ; tool + tool_result per call
  ;; a viewer can't invoke tools at all
  (define exec2 (make-exec c (user-principal c bob tid) ev))
  (check-true (regexp-match? #rx"Permission denied"
                             (exec2 (tool-block "create_note" "{\"title\":\"x\",\"body\":\"y\"}")))))

(test-case "tool activation: disabling a tool blocks dispatch, re-enabling restores"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice"))
  (define exec (make-exec c (user-principal c uid tid) (lambda (_) (void))))
  (check-true (regexp-match? #rx"Created note" (exec (tool-block "create_note" "{\"title\":\"A\",\"body\":\"B\"}"))))
  ;; registry lists the tool as enabled by default
  (check-true (for/or ([t (in-list (tool-settings-for c tid))])
                (and (string=? (hash-ref t 'name) "create_note") (hash-ref t 'enabled))))
  (set-tool-enabled! c tid "create_note" #f)
  (check-true (regexp-match? #rx"disabled" (exec (tool-block "create_note" "{\"title\":\"C\",\"body\":\"D\"}"))))
  (set-tool-enabled! c tid "create_note" #t)
  (check-true (regexp-match? #rx"Created note" (exec (tool-block "create_note" "{\"title\":\"E\",\"body\":\"F\"}")))))

;; ---- the tool list has to fit the window -------------------------------------
;;
;; Reported from outside: the agent tab's own shipped example prompt created SIX
;; notes, the first correct and five degenerate. Measured against the live model,
;; the cause was that the 24 registered tools are 21,538 characters of JSON
;; schema — about 5,600 tokens into ollama's 4,096-token default — so the prompt
;; was already full before the user's text was added, and what gets discarded is
;; the system prompt and the instruction. See the block above `fit-tools`.
(test-case "#231's shape in the agent: the tool list is fitted, and what went is NAMED"
  (define (sch name chars)
    (hasheq 'type "function"
            'function (hasheq 'name name 'description (make-string chars #\x))))
  (define all (list (sch "create_note" 100) (sch "fat" 5000) (sch "list_notes" 100)))
  (define-values (kept out) (fit-tools all 1000))
  ;; IN REGISTRY ORDER, and a schema that does not fit is SKIPPED rather than
  ;; ending the walk — one fat tool early must not shut out the small ones
  ;; behind it (`doc_classify` is 3,140 characters by itself).
  (check-equal? (map tool-schema-name kept) '("create_note" "list_notes"))
  (check-equal? out '("fat") "what was withheld is named, never dropped silently")
  ;; THE BUDGET IS REAL: everything fits when there is room for it, so an
  ;; instance with a window big enough is untouched by any of this.
  (let-values ([(k2 o2) (fit-tools all 100000)])
    (check-equal? (length k2) 3)
    (check-equal? o2 '()))
  ;; …and nothing fits when there is no room, which must still not raise: an
  ;; agent with no tools is a chat, and that is better than a 500.
  (let-values ([(k3 o3) (fit-tools all 10)])
    (check-equal? k3 '())
    (check-equal? (length o3) 3))
  ;; The message names the count, the window and the two remedies — the per-team
  ;; tool switch an operator already has, and the server's own window.
  (define m (withheld-tools-message '("fat")))
  (check-true (regexp-match? #rx"fat" m))
  (check-true (regexp-match? #rx"OLLAMA_CONTEXT_LENGTH" m))
  (check-true (regexp-match? #rx"TMACH_MODEL_CONTEXT" m)))

;; ---- A WORKFLOW TOOL IS NOT A CONVERSATIONAL TOOL ----------------------------
;;
;; Reported from outside: "Agent currently fails: 27 tool(s) were not offered …",
;; and the 27 included `create_note`, `update_note`, `list_notes` and `get_usage`
;; — every tool the agent's own system prompt instructs it to use. The budget
;; walk above was working exactly as written; what was wrong is that it was fed
;; the whole registry in MODULE INSTANTIATION order, so what survived was
;; whatever `server/main.rkt` happened to require first.
;;
;; The arithmetic off the reported instance, against the measured schema sizes:
;; doc_text 473 + doc_classify 3,140 + doc_list_unclassified 750 +
;; doc_classify_eval 2,369 + repo_list_unindexed 331 + repo_extract_text 270 +
;; repo_embed_chunks 329 = 7,662 of a 7,680-character budget. The next tool of
;; any size was refused, and the agent's own four came 14th to 17th.
(require (only-in "../domain/repo/index-tools.rkt")
         (only-in "../domain/repo/embed-tools.rkt")
         (only-in "../domain/repo/retrieve-tools.rkt")
         (only-in "../domain/repo/voice-tools.rkt")
         (only-in "../domain/repo/doc-tools.rkt")
         (only-in "../domain/kg/kg-tools.rkt")
         (only-in "../domain/ai/executor.rkt" max-input-chars model-context))

;; THE HOSTILE ORDER IS PASSED IN RATHER THAN ARRANGED, because a test cannot
;; control module instantiation order from inside one module — and that is the
;; point: the fix must not depend on the order at all.
(test-case "the tools the system prompt NAMES survive, whatever order they arrive in"
  (define (sch name chars)
    (hasheq 'type "function"
            'function (hasheq 'name name 'description (make-string chars #\x))))
  ;; the reported instance's own shape: the fat pipeline schemas first, the
  ;; agent's own four last.
  (define hostile
    (append (list (sch "doc_classify" 3140) (sch "doc_classify_eval" 2369)
                  (sch "doc_set_type" 1796) (sch "doc_render" 2090))
            (for/list ([n (in-list CORE-TOOLS)]) (sch n 300))))
  (define-values (kept withheld) (fit-tools hostile 7680))
  (for ([n (in-list CORE-TOOLS)])
    (check-true (and (member n (map tool-schema-name kept)) #t)
                (format "~a is named by the system prompt and must be offered" n))
    (check-false (member n withheld)))
  ;; and the fat ones are what gave way, which is the whole trade
  (check-true (> (length withheld) 0) "something had to go — it must not be a core tool"))

(test-case "a workflow tool is registered and dispatchable, and never offered to the agent"
  ;; `agent?` is not a permission and not the per-team switch: the tool is still
  ;; in the registry, still documented, still callable by a workflow step.
  (for ([n (in-list '("repo_list_unindexed" "repo_extract_text"
                      "repo_list_unembedded" "repo_embed_chunks"
                      "voice_list_untranscribed" "doc_transcribe"
                      "kg_list_unextracted" "kg_extract"
                      "doc_list_unclassified" "doc_classify_eval"
                      "doc_classify" "doc_set_type" "doc_extract_fields"
                      "doc_render" "doc_fill_form"))])
    (define t (tool-by-name n))
    (check-true (tool? t) (format "~a must still be registered" n))
    (check-false (tool-agent? t) (format "~a is a workflow tool, not a conversational one" n)))
  ;; …and the ones a person really does ask for in a sentence are kept
  (for ([n (in-list '("create_note" "update_note" "list_notes" "get_usage"
                      "doc_text" "doc_redact" "doc_translate"
                      "repo_retrieve" "kg_query"))])
    (define t (tool-by-name n))
    (check-true (tool? t) (format "~a must be registered" n))
    (check-true (tool-agent? t) (format "~a is conversational and must be offered" n))))

;; THE GATE: a new agent-facing tool whose schema does not fit fails HERE rather
;; than silently pushing somebody else's tool out of the window on a box running
;; ollama's documented default. The remedy when it fails is `#:agent? #f` if the
;; tool's required arguments are spec-authored, and a smaller schema if not.
;;
;; ITS SCOPE IS THE CORE TOOLS, and that is deliberate: no plugin is loaded here,
;; so what this pins is that the platform's own surface leaves room rather than
;; filling the window by itself. A plugin's tools legitimately contend for what is
;; left — measured with all eleven shipped plugins loaded, 13 of 15 agent-facing
;; tools are offered — and the levers for that are the budget walk, which NAMES
;; what went, the per-team `tool_settings` switch, and a plugin declaring
;; `agent?` #f for a tool only its own workflow calls.
(test-case "the whole agent-facing surface fits the shipped window"
  (define agentable (filter tool-agent? (all-tools)))
  (define-values (kept withheld) (fit-tools (map tool-schema agentable)))
  (check-equal? withheld '()
                (format "~a of ~a chars does not fit ~a (window ~a tokens)"
                        withheld
                        (for/sum ([t agentable]) (string-length (jsexpr->string (tool-schema t))))
                        (max-input-chars) (model-context)))
  (check-equal? (length kept) (length agentable)))

(test-case "#:agent? defaults to #t, so a plugin's tool keeps appearing"
  (register-tool! "probe_plugin_tool"
                  (hasheq 'type "function" 'function (hasheq 'name "probe_plugin_tool"))
                  "notes:read" (lambda (c p a) "ok") #:source "probe")
  (check-true (tool-agent? (tool-by-name "probe_plugin_tool"))))
