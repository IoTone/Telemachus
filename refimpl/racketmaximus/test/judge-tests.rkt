#lang racket/base

;; test/judge-tests.rkt — the typed-judgment seam (JUDGE-8), no server, no laya.
;;   raco test test/judge-tests.rkt
;;
;; What has to hold:
;;   1. `judge` enqueues a judge.typed job whose payload is the composed bytes,
;;      a worker completes it, and the caller gets the verdict — values AND the
;;      received bytes
;;   2. the kind's #:validate holds the WORKER to its half (shape), and the
;;      seam holds the verdict to the REQUEST (the full check) — two different
;;      failures, each named
;;   3. the dispatch is audited under the job's team (JUDGE-4)

(require rackunit db-kit/portable
         racket/list json
         db-kit/migrate
         "../domain/db/migrations.rkt"
         "db-fixture.rkt"
         "../domain/authz/authz.rkt"
         "../domain/sched/scheduler.rkt"
         "../domain/exec/pull.rkt"
         "../domain/judge/wire.rkt"
         "../domain/judge/judge.rkt")

(define (fresh) (define c (fresh-db #:migrate? #f)) (migrate! c all-migrations) c)
(register-judge-kind!)

(define QS
  (list (cons "team"   (judge-choice "Who should handle this?"
                                     (list (cons "billing" #f) (cons "technical" #f))))
        (cons "refund" (judge-noul "Does the customer ask for money back?"
                                   "asks for money back" "no money is mentioned"))))

;; the double answers like laya does: every question in the claimed request,
;; with its own type — plus fields we never asked for
(define (answer-request request-json)
  (define req (string->jsexpr request-json))
  (jsexpr->string
   (hasheq 'model "aac6fef/laya-mlx@20aed81 float16"
           'usage (hasheq 'input_tokens 99 'output_tokens 0)
           'answers
           (for/hasheq ([(name q) (in-hash (hash-ref req 'questions))])
             (values name
                     (case (hash-ref q 'type)
                       [("choice") (hasheq 'type "choice" 'confidence 0.7
                                           'choice (symbol->string (car (hash-keys (hash-ref q 'criteria))))
                                           'order (map symbol->string (hash-keys (hash-ref q 'criteria))))]
                       [("score") (hasheq 'type "score" 'score 1.0 'confidence 0.5)]
                       [else (hasheq 'type "noul" 'noul 0.9 'confidence 0.9 'action "refund")]))))))

;; a worker thread that claims ONE judge.typed job and completes it with VERDICT-OF
(define (one-shot-worker c ex verdict-of)
  (thread (lambda ()
            (let loop ([n 0])
              (define job (worker-claim! c ex #:kinds (list JUDGE-KIND)))
              (cond [job (worker-complete! c ex (hash-ref job 'id)
                                           (hasheq 'verdict_json
                                                   (verdict-of (hash-ref (hash-ref job 'payload) 'request_json)))
                                           #:token (hash-ref job 'claim_token))]
                    [(< n 400) (sleep 0.05) (loop (add1 n))])))))

(test-case "judge: composed bytes out, a worker's verdict back, values AND bytes"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice"))
  (define alice (user-principal c uid tid))
  (define-values (ex tok) (executor-create! c alice #:name "mac" #:model "laya"))
  (void (one-shot-worker c ex answer-request))
  (define-values (v vjson) (judge c #:team tid #:user uid
                                  #:state "I was billed twice." #:questions QS))
  ;; the parsed verdict and the received bytes agree — vjson IS what was stored
  (check-equal? (string->jsexpr vjson) v)
  (check-equal? (hash-ref (hash-ref (hash-ref v 'answers) 'refund) 'noul) 0.9)
  (check-true (string? (hash-ref v 'model)))
  ;; the job row holds both halves of JUDGE-13: request_json in the payload,
  ;; verdict_json in the result, byte for byte
  (define row (query-row c "SELECT payload, result FROM jobs WHERE team_id = ?" tid))
  (check-true (string? (hash-ref (string->jsexpr (vector-ref row 0)) 'request_json)))
  (check-equal? (hash-ref (string->jsexpr (vector-ref row 1)) 'verdict_json) vjson)
  ;; and the dispatch was audited, under the team, naming the job (JUDGE-4)
  (define jid (query-value c "SELECT id FROM jobs WHERE team_id = ?" tid))
  (check-equal? (query-value c (string-append "SELECT COUNT(*) FROM audit_log WHERE "
                                              "action = 'judge.dispatched' AND team_id = ? AND resource_id = ?")
                             tid jid)
                1)
  (disconnect c))

(test-case "the kind's #:validate is the worker's half: a shapeless verdict fails the JOB by name"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice"))
  (define alice (user-principal c uid tid))
  (define-values (ex tok) (executor-create! c alice #:name "mac" #:model "laya"))
  ;; a verdict with no checkpoint: the shape check refuses it at /complete
  (void (one-shot-worker c ex (lambda (_rq) (jsexpr->string (hasheq 'answers (hasheq))))))
  (check-exn #rx"names no checkpoint"
             (lambda () (judge c #:team tid #:user uid #:state "s" #:questions QS)))
  (check-equal? (query-value c "SELECT status FROM jobs WHERE team_id = ?" tid) "error")
  (disconnect c))

(test-case "the seam's half: a well-shaped verdict that does not answer THIS request is refused by path"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice"))
  (define alice (user-principal c uid tid))
  (define-values (ex tok) (executor-create! c alice #:name "mac" #:model "laya"))
  ;; shape-valid (model + answers), but one question is missing: #:validate
  ;; passes it — the worker cannot be failed over a request it never saw in the
  ;; result — and the SEAM refuses it with the path
  (void (one-shot-worker c ex
         (lambda (rq)
           (define full (string->jsexpr (answer-request rq)))
           (jsexpr->string (hash-set full 'answers
                                     (hash-remove (hash-ref full 'answers) 'refund))))))
  (check-exn #rx"\\$\\.answers\\.refund: the question was not answered"
             (lambda () (judge c #:team tid #:user uid #:state "s" #:questions QS)))
  (disconnect c))

(test-case "judgments-in-result: the biller's count (JUDGE-10)"
  ;; a judge result bills one per question ANSWERED; anything else answers #f,
  ;; so every other kind's result is untouched by the judgments meter
  (check-equal? (judgments-in-result
                 (hasheq 'verdict_json "{\"model\":\"m\",\"answers\":{\"a\":{},\"b\":{}}}"))
                2)
  (check-false (judgments-in-result (hasheq 'reply "hi" 'tokens_used 3)))
  (check-false (judgments-in-result (hasheq 'verdict_json "not json")))
  (check-false (judgments-in-result "not a hash")))

(test-case "a completed judgment reaches the ONE biller both claim paths share"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice"))
  (define alice (user-principal c uid tid))
  (define-values (ex tok) (executor-create! c alice #:name "mac" #:model "laya"))
  (define billed (box #f))
  ;; dynamic-wind, the FLEET-4 lesson: a raise anywhere in here must not leak a
  ;; test biller into every later test in the file
  (dynamic-wind
    (lambda () (set-record!! (lambda (conn team result)
                               (set-box! billed (judgments-in-result result)))))
    (lambda ()
      (void (one-shot-worker c ex answer-request))
      (define-values (v vjson) (judge c #:team tid #:user uid #:state "s" #:questions QS))
      (void v vjson))
    (lambda () (set-record!! (lambda (conn team result) (void)))))
  (check-equal? (unbox billed) 2 "one per question answered")
  (disconnect c))

(test-case "judge-result-problem: the worker's contract, named"
  (check-equal? (judge-result-problem "nope") "result must be an object")
  (check-equal? (judge-result-problem (hasheq)) "result.verdict_json must be a string (the verdict AS RECEIVED)")
  (check-equal? (judge-result-problem (hasheq 'verdict_json "{")) "result.verdict_json is not a JSON object")
  (check-equal? (judge-result-problem (hasheq 'verdict_json "{\"answers\":{}}"))
                "result.verdict_json: the verdict names no checkpoint (model)")
  (check-equal? (judge-result-problem (hasheq 'verdict_json "{\"model\":\"m\"}"))
                "result.verdict_json: answers must be an object")
  (check-false (judge-result-problem (hasheq 'verdict_json "{\"model\":\"m\",\"answers\":{}}"))))
