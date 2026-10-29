#lang racket/base

;; test/requestlog-tests.rkt — issue #91 requirement 3: the model-request log
;; (decisions RED-15…23).
;;   raco test test/requestlog-tests.rkt
;;
;; Three layers, and the first is where the interesting rules are:
;;   1. PURE — where a backend is (RED-21), what it declares (RED-20), the
;;      refusal, and the digest (RED-18). No database, no socket.
;;   2. the row — that a request, a failure and a REFUSAL are each recorded, and
;;      that the vocabularies are enforced rather than merely declared.
;;   3. the requirement — through the real `run-chat`, against a stub executor,
;;      asserting one at a time that the prompt is in NO column of the row.

(require rackunit db-kit/portable db-kit/migrate
         racket/string racket/list
         "../domain/db/migrations.rkt"
         "db-fixture.rkt"
         "../domain/authz/authz.rkt"
         "../domain/exec/federation.rkt"
         "../domain/ai/egress.rkt"
         "../domain/ai/requestlog.rkt"
         "../domain/ai/executor.rkt"
         (only-in "../domain/agent/llm.rkt" exn:fail:model-retryable))

(define (fresh) (define c (fresh-db #:migrate? #f)) (migrate! c all-migrations) c)

;; `putenv` answers #t, and `test-case` hands its body's last value back — which
;; prints as a stray value in the suite's output. Restore through this.
(define (setenv! k v) (putenv k v) (void))

(define (team-of c)
  (seed-builtin-roles! c)
  (define t (create-team! c #:name "Req Log" #:slug "reqlog"))
  (define u (create-user! c #:username "rl" #:password "pw"))
  (add-member! c #:user u #:team t #:role "owner")
  (values t u (user-principal c u t)))

;; ---- 1. where a backend is (RED-21) ----------------------------------------

(test-case "an endpoint on this box is not hosted, and anything else is"
  ;; The policy exists for text that CROSSES THE NETWORK, so a single-box
  ;; instance talking to ollama on loopback must fall outside it entirely — or
  ;; turning the switch on would refuse the ordinary deployment.
  (check-false (endpoint-hosted? "http://127.0.0.1:11434/v1/chat/completions"))
  (check-false (endpoint-hosted? "http://localhost:11434/v1/chat/completions"))
  (check-false (endpoint-hosted? "http://[::1]:11434/v1/chat/completions"))
  (check-true  (endpoint-hosted? "https://api.example.com/v1/chat/completions"))
  ;; peer.rkt's own rule: "10.x is internal" is an assumption about somebody
  ;; else's network, so a private-looking address is still off this box.
  (check-true  (endpoint-hosted? "http://10.1.2.3:8000/v1/chat/completions"))
  ;; an endpoint nobody can parse fails toward the STRICTER answer: the policy is
  ;; for the backends nobody can place, so an unreadable one must not be
  ;; exempted by its own unreadability
  (check-true  (endpoint-hosted? "not a url at all"))
  (check-true  (endpoint-hosted? #f)))

(test-case "the stored endpoint is the host, never the key or the query"
  ;; FEED-6's rule. This string goes in a row a reviewer reads.
  (check-equal? (endpoint-host "https://api.example.com/v1/chat?key=sekrit") "api.example.com")
  (check-equal? (endpoint-host "https://u:p@api.example.com/v1/chat") "api.example.com")
  (check-false (endpoint-host "")))

;; ---- 2. the declaration (RED-20) -------------------------------------------

(test-case "content logging: local, declared, and the absence reported as its own value"
  (register-executor! "lo"   #:url "http://127.0.0.1:9/v1" #:caps (hasheq))
  (register-executor! "far"  #:url "https://api.example.com/v1" #:caps (hasheq))
  (register-executor! "far2" #:url "https://api.example.com/v1"
                      #:caps (hasheq 'no_content_logging #t))
  ;; nothing left the box, so there is nothing to declare
  (check-equal? (content-logging-of "lo" "http://127.0.0.1:9/v1") "local")
  ;; the ABSENCE is the thing being reported, so it is its own value rather than
  ;; the permissive "unknown" an absent LAY-9 capability means elsewhere
  (check-equal? (content-logging-of "far" "https://api.example.com/v1") "undeclared")
  (check-equal? (content-logging-of "far2" "https://api.example.com/v1") "declared-none")
  ;; the declaration does not make a hosted backend local, and does not survive
  ;; being written as something other than a boolean true
  (register-executor! "far3" #:url "https://api.example.com/v1"
                      #:caps (hasheq 'no_content_logging "yes"))
  (check-equal? (content-logging-of "far3" "https://api.example.com/v1") "undeclared")
  (unregister-executor! "lo") (unregister-executor! "far")
  (unregister-executor! "far2") (unregister-executor! "far3"))

(test-case "the requirement is OFF unless configured, and then refuses by name"
  (register-executor! "far" #:url "https://api.example.com/v1" #:caps (hasheq))
  (register-executor! "ok"  #:url "https://api.example.com/v1"
                      #:caps (hasheq 'no_content_logging #t))
  ;; unset: an upgrade must not start refusing calls on instances that work
  ;; today, so the undeclared hosted backend is allowed and the ROW is what
  ;; carries the gap
  (setenv! "TMACH_REQUIRE_NO_CONTENT_LOGGING" "")
  (check-false (require-no-content-logging?))
  (check-false (content-logging-refusal "far" "https://api.example.com/v1"))
  (setenv! "TMACH_REQUIRE_NO_CONTENT_LOGGING" "1")
  (check-true (require-no-content-logging?))
  (define bad (content-logging-refusal "far" "https://api.example.com/v1"))
  (check-true (string? bad))
  (check-true (string-contains? bad "far"))
  (check-true (string-contains? bad "no_content_logging"))
  ;; a backend that HAS declared passes, and so does loopback — the switch is
  ;; about content leaving the box, not about paperwork for its own sake
  (check-false (content-logging-refusal "ok" "https://api.example.com/v1"))
  (check-false (content-logging-refusal #f "http://127.0.0.1:11434/v1"))
  (setenv! "TMACH_REQUIRE_NO_CONTENT_LOGGING" "")
  (unregister-executor! "far") (unregister-executor! "ok"))

;; ---- 3. the digest (RED-18) ------------------------------------------------

(test-case "the digest is keyed by the instance, and says which it is"
  (define key "d0d0cafe00000000000000000000000000000000000000000000000000000001")
  (setenv! "TMACH_SECRET_KEY" "")
  (define-values (h0 a0 k0) (model-request-digest "Arun Patel"))
  ;; with no key it is a plain SHA-256 and REPORTS that: an instance in the
  ;; documented plaintext posture still gets a digest it can compare with
  ;; itself, and a digest that silently changed meaning with the environment
  ;; would be worse than one that says which it is
  (check-equal? a0 "sha256")
  (check-false k0)
  (check-equal? (string-length h0) 64)
  (setenv! "TMACH_SECRET_KEY" key)
  (define-values (h1 a1 k1) (model-request-digest "Arun Patel"))
  (check-equal? a1 "hmac-sha256")
  (check-true (string? k1))
  ;; THE POINT OF THE SLICE: a bare hash of a short prompt is reversible from a
  ;; word list, so the digest an instance stores must not be the one anybody
  ;; else can compute for the same name.
  (check-not-equal? h0 h1)
  ;; and it is still a digest: the same text twice gives the same answer, which
  ;; is what makes "was this text sent" answerable at all
  (define-values (h2 _a2 _k2) (model-request-digest "Arun Patel"))
  (check-equal? h1 h2)
  (define-values (h3 _a3 _k3) (model-request-digest "Arun Patell"))
  (check-not-equal? h1 h3)
  (setenv! "TMACH_SECRET_KEY" ""))

;; ---- 4. the row ------------------------------------------------------------

(define (rows c) (query-rows c "SELECT * FROM model_requests"))

(define (log-one! c p #:status [status "ok"] #:kind [kind #f]
                  #:executor [executor #f] #:endpoint [endpoint #f]
                  #:messages [msgs (list (hasheq 'role "user" 'content "hello"))]
                  #:tokens [tokens 12])
  (model-request-record! c #:team (principal-team-id p) #:user (principal-user-id p)
                         #:executor executor #:transport "push" #:model "m"
                         #:endpoint endpoint #:messages msgs #:tokens tokens
                         #:status status #:error-kind kind #:ms 3))

(test-case "a request, a failure and a REFUSAL are each a row"
  (define c (fresh))
  (define-values (t u p) (team-of c))
  (log-one! c p #:status "ok")
  (log-one! c p #:status "error" #:kind "http")
  ;; RED-19: the row is what the request WAS. The refusals are the rows somebody
  ;; auditing a hosted backend came to read, and a log that recorded only
  ;; successes would agree with every happy path.
  (log-one! c p #:status "refused" #:kind "policy" #:tokens #f)
  (define got (model-requests-for c p))
  (check-equal? (length got) 3)
  (check-equal? (sort (map (lambda (r) (hash-ref r 'status)) got) string<?)
                '("error" "ok" "refused"))
  (close-db! c))

(test-case "the closed vocabularies are ENFORCED, not merely declared"
  ;; #113's shape, closed at the writer rather than by a source scan: this
  ;; function's caller already swallows a failure, so a raise here cannot cost
  ;; anybody their answer.
  (define c (fresh))
  (define-values (t u p) (team-of c))
  (check-exn #rx"not one of" (lambda () (log-one! c p #:status "sent")))
  (check-exn #rx"not one of" (lambda () (log-one! c p #:status "error" #:kind "exploded")))
  ;; and the legal ones all pass, in both directions
  (for ([s (in-list REQUEST-STATUSES)]) (log-one! c p #:status s #:kind #f))
  (for ([k (in-list ERROR-KINDS)]) (log-one! c p #:status "error" #:kind k))
  (check-equal? (length (rows c)) (+ (length REQUEST-STATUSES) (length ERROR-KINDS)))
  (close-db! c))

(test-case "the row carries where it went and what that backend declared"
  (define c (fresh))
  (define-values (t u p) (team-of c))
  (register-executor! "far" #:url "https://api.example.com/v1" #:caps (hasheq))
  (log-one! c p #:executor "far" #:endpoint "https://api.example.com/v1?key=sekrit")
  (log-one! c p #:endpoint "http://127.0.0.1:11434/v1/chat/completions")
  (define got (model-requests-for c p))
  (define far (findf (lambda (r) (equal? (hash-ref r 'executor) "far")) got))
  (define loc (findf (lambda (r) (eq? (hash-ref r 'executor) 'null)) got))
  (check-true (hash-ref far 'hosted))
  (check-equal? (hash-ref far 'content_logging) "undeclared")
  ;; the key is not in the stored endpoint
  (check-equal? (hash-ref far 'endpoint) "api.example.com")
  (check-false (hash-ref loc 'hosted))
  (check-equal? (hash-ref loc 'content_logging) "local")
  (unregister-executor! "far")
  (close-db! c))

(test-case "reading the log needs audit:read, which a plain member does not hold"
  ;; RED-22: the digest is information about CONTENT, so a member of the team
  ;; does not get it — #84's rule, where who-read a document sits behind
  ;; files:manage because it is information about people.
  (define c (fresh))
  (define-values (t u p) (team-of c))
  (log-one! c p)
  (define m (create-user! c #:username "mem" #:password "pw"))
  (add-member! c #:user m #:team t #:role "member")
  (define mp (user-principal c m t))
  (check-exn #rx"audit:read" (lambda () (model-requests-for c mp)))
  (check-equal? (length (model-requests-for c p)) 1)
  (close-db! c))

(test-case "a filter and a page, and the filter cannot widen the team"
  (define c (fresh))
  (define-values (t u p) (team-of c))
  (for ([i (in-range 4)]) (log-one! c p #:executor "a"))
  (for ([i (in-range 2)]) (log-one! c p #:executor "b"))
  ;; another team's rows are never in the answer, whatever the filter says
  (define t2 (create-team! c #:name "Other" #:slug "other"))
  (define u2 (create-user! c #:username "oth" #:password "pw"))
  (add-member! c #:user u2 #:team t2 #:role "owner")
  (define p2 (user-principal c u2 t2))
  (log-one! c p2 #:executor "a")
  (check-equal? (length (model-requests-for c p #:executor "a")) 4)
  (check-equal? (length (model-requests-for c p #:executor "b")) 2)
  (check-equal? (length (model-requests-for c p)) 6)
  (check-equal? (length (model-requests-for c p #:limit 2)) 2)
  (check-equal? (length (model-requests-for c p2)) 1)
  (close-db! c))

;; ---- 5. the requirement, through run-chat ----------------------------------

(define NEEDLE "Arun Patel of 44 Mill Lane, born 1986-02-11")

(test-case "a real model call is logged, and the prompt is in NO column of it"
  ;; RED-23, and #83's lesson twice over: the scan beat the enumeration. Asserted
  ;; over every column of the row rather than over the three I would have thought
  ;; to name.
  (define c (fresh))
  (define-values (t u p) (team-of c))
  ;; the logger seam, as server/main.rkt installs it
  (set-box! model-request-logger
    (lambda (#:executor e #:transport tr #:model m #:endpoint u* #:messages msgs
             #:tokens tok #:status st #:error-kind ek #:http-status hs #:operation [op "chat"] #:ms ms)
      (model-request-record! c #:team (principal-team-id p) #:user (principal-user-id p)
                             #:executor e #:transport tr #:model m #:endpoint u*
                             #:messages msgs #:tokens tok #:status st
                             #:error-kind ek #:http-status hs #:operation op #:ms ms)))
  ;; a stub PULL executor: the content leaves by the job row, which is one of the
  ;; two paths `model-exchange` does not carry (RED-16)
  (set-box! pull-router (lambda (name msgs temp rf) (cons "ACK" 77)))
  (define-values (reply tokens) (run-chat NEEDLE #:executor "stub"))
  (check-equal? reply "ACK")
  (check-equal? tokens 77)
  (define r (car (rows c)))
  (for ([v (in-vector r)])
    (when (string? v)
      (check-false (string-contains? v "Arun")
                   (format "a column of model_requests contains the prompt: ~s" v))
      (check-false (string-contains? v "Mill Lane")
                   (format "a column of model_requests contains the prompt: ~s" v))
      (check-false (string-contains? v "1986")
                   (format "a column of model_requests contains the prompt: ~s" v))))
  ;; and it IS the request: the row says which path carried it and what it cost,
  ;; or the absence above would be satisfied by logging nothing at all
  (define got (car (model-requests-for c p)))
  (check-equal? (hash-ref got 'transport) "pull")
  (check-equal? (hash-ref got 'status) "ok")
  (check-equal? (hash-ref got 'tokens_used) 77)
  (check-equal? (hash-ref got 'messages) 1)
  (check-equal? (hash-ref got 'prompt_chars) (string-length NEEDLE))
  ;; the digest is the one thing that stands for the content, and it is the
  ;; digest OF the content — which is what makes the column usable as evidence
  (define-values (hex _a _k) (model-request-digest NEEDLE))
  (check-equal? (hash-ref got 'prompt_digest) hex)
  (set-box! pull-router (lambda (name msgs temp rf) #f))
  (set-box! model-request-logger
    (lambda (#:executor e #:transport tr #:model m #:endpoint u* #:messages msgs
             #:tokens tok #:status st #:error-kind ek #:http-status hs #:operation [op "chat"] #:ms ms) (void)))
  (close-db! c))

(test-case "a pull executor with no declaration is refused, and the refusal is the row"
  ;; the issue's second acceptance line, for requirement 3's half of it: a call
  ;; the platform would not make is still a thing that happened.
  (define c (fresh))
  (define-values (t u p) (team-of c))
  (set-box! model-request-logger
    (lambda (#:executor e #:transport tr #:model m #:endpoint u* #:messages msgs
             #:tokens tok #:status st #:error-kind ek #:http-status hs #:operation [op "chat"] #:ms ms)
      (model-request-record! c #:team (principal-team-id p) #:user (principal-user-id p)
                             #:executor e #:transport tr #:model m #:endpoint u*
                             #:messages msgs #:tokens tok #:status st
                             #:error-kind ek #:http-status hs #:operation op #:ms ms)))
  (define asked (box #f))
  (set-box! pull-router (lambda (name msgs temp rf) (set-box! asked #t) (cons "ACK" 1)))
  (setenv! "TMACH_REQUIRE_NO_CONTENT_LOGGING" "1")
  (check-exn #rx"no_content_logging" (lambda () (run-chat NEEDLE #:executor "stub")))
  ;; THE REFUSAL HAPPENS BEFORE THE CONTENT MOVES. A check that fired after the
  ;; dispatch would be a report, not a policy — so this assertion, not the
  ;; exception, is the one that matters.
  (check-false (unbox asked))
  (define got (car (model-requests-for c p)))
  (check-equal? (hash-ref got 'status) "refused")
  (check-equal? (hash-ref got 'error_kind) "policy")
  (check-equal? (hash-ref got 'tokens_used) 'null)
  (setenv! "TMACH_REQUIRE_NO_CONTENT_LOGGING" "")
  (set-box! pull-router (lambda (name msgs temp rf) #f))
  (set-box! model-request-logger
    (lambda (#:executor e #:transport tr #:model m #:endpoint u* #:messages msgs
             #:tokens tok #:status st #:error-kind ek #:http-status hs #:operation [op "chat"] #:ms ms) (void)))
  (close-db! c))

(test-case "the SIMULATED echo is not logged, because nothing left the process"
  ;; A row for it would make the log answer "yes, this was sent" about a call
  ;; that was never made — the worst thing a log of this kind can do.
  (define c (fresh))
  (define-values (t u p) (team-of c))
  (set-box! model-request-logger
    (lambda (#:executor e #:transport tr #:model m #:endpoint u* #:messages msgs
             #:tokens tok #:status st #:error-kind ek #:http-status hs #:operation [op "chat"] #:ms ms)
      (model-request-record! c #:team (principal-team-id p) #:user (principal-user-id p)
                             #:executor e #:transport tr #:model m #:endpoint u*
                             #:messages msgs #:tokens tok #:status st
                             #:error-kind ek #:http-status hs #:operation op #:ms ms)))
  (setenv! "TMACH_MODEL_URL" "")
  (define-values (reply _tokens) (run-chat "hello"))
  (check-equal? reply "HELLO")
  (check-equal? (length (rows c)) 0)
  (set-box! model-request-logger
    (lambda (#:executor e #:transport tr #:model m #:endpoint u* #:messages msgs
             #:tokens tok #:status st #:error-kind ek #:http-status hs #:operation [op "chat"] #:ms ms) (void)))
  (close-db! c))

(test-case "every error kind the vocabulary declares is one something produces"
  ;; #113's shape inside this slice's own vocabulary: `timeout` and
  ;; `unreachable` were declared and nothing produced them until the classifier
  ;; read `llm.rkt`'s own reason, which is the seam PULL-14 already branches on.
  ;; A stalled stream maps to `timeout` deliberately — the remedy is the same,
  ;; and a fifth label for it would be a distinction with no reader.
  (define (kind reason)
    (transport-error-kind
     (exn:fail:model-retryable "boom" (current-continuation-marks) reason)))
  (check-equal? (kind 'timeout) "timeout")
  (check-equal? (kind 'idle) "timeout")
  (check-equal? (kind 'network) "unreachable")
  (check-equal? (kind 'malformed) "transport")
  ;; an exception that is not the model's own is still a transport failure, not
  ;; a guess at one of the named causes
  (check-equal? (transport-error-kind (make-exn:fail "x" (current-continuation-marks)))
                "transport")
  ;; and the classifier can only ever answer with a declared label
  (for ([r (in-list '(timeout idle network malformed other #f))])
    (check-true (and (member (kind r) ERROR-KINDS) #t))))

(test-case "a model endpoint nothing is listening on is logged as unreachable"
  ;; the classifier, wired: a real socket, refused immediately, through the real
  ;; `model-exchange`. Without this the mapping above is a table nothing reads.
  (define c (fresh))
  (define-values (t u p) (team-of c))
  (set-box! model-request-logger
    (lambda (#:executor e #:transport tr #:model m #:endpoint u* #:messages msgs
             #:tokens tok #:status st #:error-kind ek #:http-status hs #:operation [op "chat"] #:ms ms)
      (model-request-record! c #:team (principal-team-id p) #:user (principal-user-id p)
                             #:executor e #:transport tr #:model m #:endpoint u*
                             #:messages msgs #:tokens tok #:status st
                             #:error-kind ek #:http-status hs #:operation op #:ms ms)))
  ;; port 1 on loopback: nothing listens, and the refusal is immediate
  (setenv! "TMACH_MODEL_URL" "http://127.0.0.1:1/v1/chat/completions")
  (setenv! "TMACH_MODEL_RETRIES" "1")
  (check-exn exn:fail? (lambda () (run-chat "hello")))
  (define got (car (model-requests-for c p)))
  (check-equal? (hash-ref got 'status) "error")
  (check-equal? (hash-ref got 'error_kind) "unreachable")
  (check-equal? (hash-ref got 'transport) "push")
  ;; a loopback backend is NOT hosted, which is what keeps the ordinary
  ;; single-box instance out of the no-content-logging policy
  (check-false (hash-ref got 'hosted))
  (check-equal? (hash-ref got 'content_logging) "local")
  (check-equal? (hash-ref got 'endpoint) "127.0.0.1")
  (setenv! "TMACH_MODEL_URL" "")
  (setenv! "TMACH_MODEL_RETRIES" "")
  (set-box! model-request-logger
    (lambda (#:executor e #:transport tr #:model m #:endpoint u* #:messages msgs
             #:tokens tok #:status st #:error-kind ek #:http-status hs #:operation [op "chat"] #:ms ms) (void)))
  (close-db! c))

(test-case "a logger that raises does not fail the model call"
  ;; RED-17, the trigger seam's rule: an unwritable log is an operational
  ;; problem and losing somebody's answer is theirs.
  (set-box! model-request-logger
    (lambda (#:executor e #:transport tr #:model m #:endpoint u* #:messages msgs
             #:tokens tok #:status st #:error-kind ek #:http-status hs #:operation [op "chat"] #:ms ms)
      (error 'logger "the log is on fire")))
  (set-box! pull-router (lambda (name msgs temp rf) (cons "ACK" 5)))
  (define-values (reply tokens) (run-chat "hello" #:executor "stub"))
  (check-equal? reply "ACK")
  (set-box! pull-router (lambda (name msgs temp rf) #f))
  (set-box! model-request-logger
    (lambda (#:executor e #:transport tr #:model m #:endpoint u* #:messages msgs
             #:tokens tok #:status st #:error-kind ek #:http-status hs #:operation [op "chat"] #:ms ms) (void))))

(test-case "…but it swallows a FAILURE, not everything: a break must pass through"
  ;; The handler is `exn:fail?` rather than a catch-all, and that matters: the
  ;; model deadline shuts its request's custodian down and the shutdown drain
  ;; stops the server with a break, so a logger that caught either would turn a
  ;; stop into a hang. A bare `raise` stands in for those here — it is what a
  ;; catch-all catches and `exn:fail?` does not.
  (set-box! model-request-logger
    (lambda (#:executor e #:transport tr #:model m #:endpoint u* #:messages msgs
             #:tokens tok #:status st #:error-kind ek #:http-status hs #:operation [op "chat"] #:ms ms)
      (raise 'stop-everything)))
  (set-box! pull-router (lambda (name msgs temp rf) (cons "ACK" 5)))
  (check-equal? (with-handlers ([symbol? (lambda (v) v)])
                  (let-values ([(r _t) (run-chat "hello" #:executor "stub")]) r))
                'stop-everything)
  (set-box! pull-router (lambda (name msgs temp rf) #f))
  (set-box! model-request-logger
    (lambda (#:executor e #:transport tr #:model m #:endpoint u* #:messages msgs
             #:tokens tok #:status st #:error-kind ek #:http-status hs #:operation [op "chat"] #:ms ms) (void))))
