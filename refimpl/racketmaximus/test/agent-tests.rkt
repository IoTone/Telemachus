#lang racket/base

;; test/agent-tests.rkt — agent mode: native tool-call parsing + RBAC-checked
;; dispatch. The model round-trip needs a live model; here we pin the pure parser
;; and the exec dispatcher.  raco test test/agent-tests.rkt

(require rackunit db-kit/portable
         db-kit/migrate
         "../domain/db/migrations.rkt"
         "db-fixture.rkt"
         "../domain/authz/authz.rkt"
         "../domain/agent/loop.rkt"       ; assistant-msg accessors
         "../domain/agent/run.rkt"        ; parse-agent-response, make-exec
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
