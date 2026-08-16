#lang racket/base

;; test/federation-tests.rkt — the pluggable executor seam: registry + routing a
;; run-chat to a named backend (proved with a real echo endpoint that reports the
;; model it received).  raco test test/federation-tests.rkt

(require rackunit
         racket/runtime-path
         racket/tcp
         "../domain/exec/federation.rkt"
         "../domain/ai/executor.rkt")

(define-runtime-path mock-chat "mock-chat.rkt")

(test-case "registry: register / list / resolve / exists"
  (register-executor! "gpu-node" #:url "http://gpu:8000/v1/chat/completions" #:model "llama-70b" #:key "sk-x")
  (check-true (executor-exists? "gpu-node"))
  (check-false (executor-exists? "nope"))
  (check-equal? (executor-config "gpu-node") (list "http://gpu:8000/v1/chat/completions" "llama-70b" "sk-x"))
  (check-true (for/or ([e (in-list (list-executors))]) (equal? (hash-ref e 'name) "gpu-node")))
  ;; list never leaks keys
  (check-false (for/or ([e (in-list (list-executors))]) (hash-has-key? e 'key))))

(test-case "run-chat routes to a named executor (real endpoint reports the model)"
  (define p 8921)
  (define-values (proc o i e) (subprocess #f #f #f (find-executable-path "racket") (path->string mock-chat) (number->string p)))
  (let loop ([n 0])
    (define up (with-handlers ([exn:fail? (lambda (_) #f)])
                 (define-values (ci co) (tcp-connect "127.0.0.1" p))
                 (close-input-port ci) (close-output-port co) #t))
    (unless (or up (> n 200)) (sleep 0.05) (loop (add1 n))))
  (register-executor! "node-b" #:url (format "http://127.0.0.1:~a/v1/chat/completions" p) #:model "node-b-model")
  ;; routed to node-b → reply carries node-b's model name + usage from that node
  (define-values (reply tokens) (run-chat "ping" #:executor "node-b"))
  (check-equal? reply "[node-b-model] ping")
  (check-equal? tokens 42)
  ;; no executor + no env model → local simulated fallback (uppercase)
  (define-values (r2 _t2) (run-chat "hello"))
  (check-equal? r2 "HELLO")
  (subprocess-kill proc #t))
