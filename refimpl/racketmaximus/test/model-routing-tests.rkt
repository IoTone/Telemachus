#lang racket/base

;; #128 job 2: operator-facing variables are read through ONE accessor,
;; which tries TMACH_<name> and falls back to TELEMACHUS_<name>.
(require (only-in "../config.rkt" tmach-env))

;; test/model-routing-tests.rkt — ONE way to reach a model, and ONE registry of
;; named backends.
;;
;; Before this, three code paths built a model request. The agent built its own,
;; so slice 66's pull executors and slice 67's model roles never applied to it and
;; it metered an ESTIMATE because it discarded the provider's `usage`. And the
;; registry a push call resolves through is in memory, filled from executors.json
;; at boot and from the executors table only at CREATE time — so an API-created
;; push executor silently stopped being a backend after a restart, while
;; executor-known? still said it existed.
;;
;;   raco test test/model-routing-tests.rkt

(require rackunit db-kit/portable
         racket/tcp racket/list json
         db-kit/migrate
         "../domain/db/migrations.rkt"
         "db-fixture.rkt"
         "../domain/authz/authz.rkt"
         "../domain/exec/federation.rkt"
         "../domain/exec/pull.rkt"
         "../domain/ai/executor.rkt"
         "../domain/agent/run.rkt")

(define (fresh) (define c (fresh-db #:migrate? #f)) (migrate! c all-migrations) c)

;; ---- a real endpoint that answers whatever the test hands it ----------------
(define (serve! port replies)   ; replies : (listof string) — one per request
  (define l (tcp-listen port 4 #t "127.0.0.1"))
  (define left (box replies))
  (define (read-request! in)
    (define len
      (let loop ([len 0])
        (define line (read-line in 'any))
        (cond [(or (eof-object? line) (string=? line "")) len]
              [(regexp-match #px"(?i:^content-length:[ ]*([0-9]+))" line)
               => (lambda (m) (loop (string->number (cadr m))))]
              [else (loop len)])))
    (when (> len 0) (read-bytes len in)))
  (define acceptor
    (thread (lambda ()
              (let loop ()
                (define-values (in out) (tcp-accept l))
                (thread (lambda ()
                          (with-handlers ([exn:fail? void])
                            (read-request! in)
                            (define body (if (pair? (unbox left)) (car (unbox left)) "{}"))
                            (when (pair? (unbox left)) (set-box! left (cdr (unbox left))))
                            (define b (string->bytes/utf-8 body))
                            (fprintf out "HTTP/1.1 200 STATUS\r\nContent-Type: application/json\r\nContent-Length: ~a\r\nConnection: close\r\n\r\n"
                                     (bytes-length b))
                            (write-bytes b out) (flush-output out) (close-output-port out))))
                (loop)))))
  (values (lambda () (kill-thread acceptor) (tcp-close l))))

(define (text-reply s tokens)
  (format "{\"choices\":[{\"message\":{\"role\":\"assistant\",\"content\":~a}}],\"usage\":{\"total_tokens\":~a}}"
          (jsexpr->string s) tokens))

;; ---- step 2: one way in, and no silent fallback -----------------------------
(test-case "a named executor that is no push backend is refused, not served locally"
  ;; the worst shape: the local model answers while the response still names the
  ;; executor the caller asked for
  (check-exn #rx"not a push backend"
             (lambda () (model-exchange (list (hasheq 'role "user" 'content "hi"))
                                        #:executor "ghost-box")))
  (check-exn #rx"is not available"
             (lambda () (run-chat "hi" #:executor "ghost-box"))))

(test-case "with no model and no executor, run-chat still gives the simulated echo"
  ;; the demo path must survive the refusal above
  (define-values (reply tokens) (run-chat "hello"))
  (check-equal? reply "HELLO")
  (check-true (> tokens 0)))

(test-case "issue #64: the echo is ANSWERABLE — one seam, asked by two callers"
  ;; The echo keeps the platform demoable and stays. Being SILENT about it was
  ;; the defect: a caller got a plausible-looking reply from a model that was
  ;; never called. `chat-simulated?` reads the same `backend` decision run-chat
  ;; makes, so the endpoint explaining and the call deciding cannot drift.
  (check-true (chat-simulated?) "no model, no executor — the echo answers")
  ;; A NAMED executor is never simulated: either a pull worker answers it, or
  ;; run-chat refuses it by name (the case above). It must never report as an
  ;; echo, which would send an operator looking for a missing model instead of a
  ;; missing backend.
  (check-false (chat-simulated? "ghost-box"))
  ;; …and with a push backend registered there is a real endpoint behind it
  (register-executor! "sim-probe" #:url "http://127.0.0.1:1/v1/chat/completions" #:model "m")
  (check-false (chat-simulated? "sim-probe"))
  ;; it is PURE: the job listing's hold reason taught us an endpoint will call
  ;; this on every read, so asking twice must not change anything
  (check-true (chat-simulated?)))

(test-case "the AGENT is routable, and meters the provider's own token counts"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "root"))
  (define p (user-principal c uid tid))
  (define stop! (serve! 8941 (list (text-reply "done" 11))))
  (register-executor! "agent-box" #:url "http://127.0.0.1:8941/v1/chat/completions"
                      #:model "agent-model" #:source 'config)
  (define evs (box '()))
  (define-values (result tokens)
    (run-agent-flow c p "say done" (lambda (ev) (set-box! evs (cons ev (unbox evs))))
                    #:executor "agent-box"))
  (check-equal? tokens 11 "the usage the endpoint reported, not an estimate from the prompt")
  (define done (for/or ([e (in-list (unbox evs))]) (and (equal? (hash-ref e 'type #f) "done") e)))
  (check-equal? (hash-ref done 'reply) "done")
  (check-equal? (hash-ref done 'tokens_used) 11)
  (unregister-executor! "agent-box")
  (stop!)
  (disconnect c))

(test-case "the agent refuses a pull executor by name — that wire carries no tool calls"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "root"))
  (define p (user-principal c uid tid))
  (define-values (ex _tok) (executor-create! c p #:name "puller" #:mode "pull"))
  (check-exn #rx"runs on a push backend"
             (lambda () (run-agent-flow c p "hi" void #:executor "puller")))
  (disconnect c))

(test-case "#173: the fleet cannot stream, and cannot run the agent, and says so"
  ;; Both would otherwise be SILENT MISROUTES, which is the one shape this
  ;; module refuses everywhere else. `backend` answers the local model for any
  ;; name it does not own, so a fleet request that fell through would be served
  ;; by this box while the response named `@fleet`.
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "root"))
  (define p (user-principal c uid tid))
  (check-exn #rx"the fleet cannot stream"
             (lambda () (run-chat-stream "hi" void #:executor "@fleet")))
  ;; the agent's wire (infer.chat) carries a reply, not tool calls — the same
  ;; refusal a named pull executor gets, for the same reason
  (check-exn #rx"runs on a push backend"
             (lambda () (run-agent-flow c p "hi" void #:executor "@fleet")))
  (disconnect c))

;; ---- step 3: one registry ---------------------------------------------------
(test-case "a push executor created through the API survives a restart"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "root"))
  (define p (user-principal c uid tid))
  (define-values (ex _t)
    (executor-create! c p #:name "db-box" #:mode "push"
                      #:url "http://127.0.0.1:8942/v1/chat/completions" #:model "db-model" #:key "sk-db"))
  (check-equal? (executor-config "db-box") (list "http://127.0.0.1:8942/v1/chat/completions" "db-model" "sk-db"))
  (check-equal? (executor-source "db-box") 'db)
  ;; a restart: the process forgets the registry and re-reads it
  (unregister-executor! "db-box")
  (check-false (executor-config "db-box") "this is the state a restart used to leave behind")
  (define-values (loaded skipped) (load-push-executors! c))
  (check-equal? loaded '("db-box"))
  (check-equal? skipped 0)
  (check-equal? (executor-config "db-box") (list "http://127.0.0.1:8942/v1/chat/completions" "db-model" "sk-db")
                "the sealed key is unsealed back into the registry")
  (unregister-executor! "db-box")
  (disconnect c))

(test-case "retiring a push executor stops it serving immediately"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "root"))
  (define p (user-principal c uid tid))
  (define-values (ex _t)
    (executor-create! c p #:name "doomed" #:mode "push" #:url "http://127.0.0.1:8943/v1" #:model "m"))
  (check-true (executor-exists? "doomed"))
  (executor-retire! c p (hash-ref ex 'id))
  (check-false (executor-exists? "doomed") "the row alone left it taking traffic until the next restart")
  ;; and it is not resurrected by a later boot
  (define-values (loaded skipped) (load-push-executors! c))
  (check-equal? loaded '())
  (disconnect c))

(test-case "executors.json owns its names: a create that would shadow one is refused"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "root"))
  (define p (user-principal c uid tid))
  (register-executor! "from-file" #:url "http://127.0.0.1:8944/v1" #:model "file-model" #:source 'config)
  (check-exn #rx"executors.json already defines"
             (lambda () (executor-create! c p #:name "from-file" #:mode "push"
                                          #:url "http://127.0.0.1:8945/v1")))
  ;; and the file still owns it
  (check-equal? (cadr (executor-config "from-file")) "file-model")
  (unregister-executor! "from-file")
  (disconnect c))

(test-case "a database row that clashes with executors.json is SKIPPED and counted"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "root"))
  (define p (user-principal c uid tid))
  ;; created first, so the row exists; the file then claims the name at boot
  (define-values (ex _t)
    (executor-create! c p #:name "clash" #:mode "push" #:url "http://127.0.0.1:8946/v1" #:model "db-model"))
  (unregister-executor! "clash")
  (register-executor! "clash" #:url "http://127.0.0.1:8947/v1" #:model "file-model" #:source 'config)
  (define msgs (box '()))
  (define-values (loaded skipped) (load-push-executors! c #:log (lambda (s) (set-box! msgs (cons s (unbox msgs))))))
  (check-equal? loaded '())
  (check-equal? skipped 1)
  (check-true (regexp-match? #rx"executors.json already defines" (car (unbox msgs))))
  (check-equal? (cadr (executor-config "clash")) "file-model" "the file wins, and says so")
  (unregister-executor! "clash")
  (disconnect c))

(test-case "the listing says where each registration came from, and never leaks keys"
  (register-executor! "shown" #:url "http://x/v1" #:model "m" #:key "sk-secret" #:source 'db)
  (define row (for/or ([e (in-list (list-executors))]) (and (equal? (hash-ref e 'name) "shown") e)))
  (check-equal? (hash-ref row 'source) "db")
  (check-false (hash-has-key? row 'key))
  (unregister-executor! "shown"))

;; ---- LAY-9: what a backend can actually do -------------------------------------
;; Japanese models of a given size lead on general benchmarks and lag specifically
;; on function-calling (Nejumi Leaderboard4), which is exactly what the agent and
;; the schema-extraction pipeline depend on. Discovering that as a provider 400
;; three layers down is the failure this replaces.

(test-case "an undeclared capability is UNKNOWN, and unknown is allowed"
  ;; nothing that works today may start failing because nobody filled in a field
  (register-executor! "quiet" #:url "http://127.0.0.1:8949/v1" #:model "m" #:source 'config)
  (check-false (capability-refusal "quiet" '(tools json_schema)))
  (check-equal? (executor-caps "quiet") (hasheq))
  (unregister-executor! "quiet"))

(test-case "a backend that declares it cannot tool-call is refused BY NAME"
  (register-executor! "no-tools" #:url "http://127.0.0.1:8949/v1" #:model "jp-7b" #:source 'config
                      #:caps (hasheq 'tools #f 'json_schema #t))
  (check-true (regexp-match? #rx"cannot do tools" (capability-refusal "no-tools" '(tools))))
  (check-false (capability-refusal "no-tools" '(json_schema)) "what it CAN do is not refused")
  ;; and the refusal happens before the request leaves the process
  (check-exn #rx"cannot do tools"
             (lambda () (model-exchange (list (hasheq 'role "user" 'content "hi"))
                                        #:executor "no-tools" #:needs '(tools))))
  (unregister-executor! "no-tools"))

(test-case "run-chat asks for json_schema only when a format was requested"
  (register-executor! "no-schema" #:url "http://127.0.0.1:8949/v1" #:model "m" #:source 'config
                      #:caps (hasheq 'json_schema #f))
  (check-exn #rx"cannot do json_schema"
             (lambda () (run-chat "hi" #:executor "no-schema"
                                  #:response-format (hasheq 'type "json_object"))))
  ;; a plain chat needs nothing of it, so the declaration is irrelevant and the
  ;; call proceeds to fail on the unreachable endpoint instead
  (check-exn #rx"unreachable|HTTP|timed out"
             (lambda () (run-chat "hi" #:executor "no-schema")))
  (unregister-executor! "no-schema"))

(test-case "the LOCAL model can declare its capabilities too — the path most calls take"
  ;; the named backends keep a document on their row; the env-configured model has
  ;; no row, and without this the operator who most needs the warning gets none
  (define old (tmach-env "MODEL_CAPS"))
  (putenv "TMACH_MODEL_CAPS" "tools=false,json_schema=true")
  (check-exn #rx"declares it cannot do tools"
             (lambda () (model-exchange (list (hasheq 'role "user" 'content "hi")) #:needs '(tools))))
  (check-equal? (hash-ref (model-info) 'capabilities) (hasheq 'tools #f 'json_schema #t))
  (putenv "TMACH_MODEL_CAPS" "")
  (check-equal? (hash-ref (model-info) 'capabilities) (hasheq) "unset is unknown, not false")
  (void (if old (putenv "TMACH_MODEL_CAPS" old) (putenv "TMACH_MODEL_CAPS" ""))))

(test-case "the listing carries the capability document, and still never leaks a key"
  (register-executor! "shown2" #:url "http://x/v1" #:model "m" #:key "sk-secret" #:source 'db
                      #:caps (hasheq 'tools #t))
  (define row (for/or ([e (in-list (list-executors))]) (and (equal? (hash-ref e 'name) "shown2") e)))
  (check-equal? (hash-ref row 'capabilities) (hasheq 'tools #t))
  (check-false (hash-has-key? row 'key))
  (unregister-executor! "shown2"))
