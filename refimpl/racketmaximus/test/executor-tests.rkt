#lang racket/base

;; test/executor-tests.rkt — slice 7: the local-model executor (fallback + parsing).
;; The real HTTP path needs a running model; here we pin the fallback and the pure
;; response parser.  raco test test/executor-tests.rkt

(require rackunit "../domain/ai/executor.rkt")

(test-case "executor: simulated fallback when no model configured"
  (check-false (model-configured?))                     ; TELEMACHUS_MODEL_URL unset in tests
  (define-values (reply tokens) (run-chat "hello world"))
  (check-equal? reply "HELLO WORLD")
  (check-true (> tokens 0)))

(test-case "executor: parse OpenAI-compatible response (reply + usage tokens)"
  (define resp (hasheq 'choices (list (hasheq 'message (hasheq 'role "assistant" 'content "Hi there")))
                       'usage (hasheq 'total_tokens 42)))
  (define-values (reply tokens) (parse-chat-response resp))
  (check-equal? reply "Hi there")
  (check-equal? tokens 42))

(test-case "executor: parse tolerates missing usage / empty choices"
  (define-values (r1 t1) (parse-chat-response (hasheq 'choices (list (hasheq 'message (hasheq 'content "x"))))))
  (check-equal? r1 "x")
  (check-false t1)
  (define-values (r2 t2) (parse-chat-response (hasheq)))
  (check-equal? r2 "")
  (check-false t2))

(test-case "executor: token estimate"
  (check-equal? (estimate-tokens "12345678") 2)
  (check-true (>= (estimate-tokens "") 1)))
