#lang racket/base

;; test/agent-tests.rkt — agent mode: native tool-call parsing + RBAC-checked
;; dispatch. The model round-trip needs a live model; here we pin the pure parser
;; and the exec dispatcher.  raco test test/agent-tests.rkt

(require rackunit
         db
         db-kit/migrate
         "../domain/db/migrations.rkt"
         "../domain/authz/authz.rkt"
         "../domain/agent/loop.rkt"       ; assistant-msg accessors
         "../domain/agent/run.rkt"        ; parse-agent-response, make-exec
         "../domain/tools/convert.rkt")   ; tool-block

(define (fresh) (define c (sqlite3-connect #:database 'memory)) (migrate! c all-migrations) c)

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
