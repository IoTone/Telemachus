#lang racket/base

;; test/judge-wire-tests.rkt — the typed-judgment wire (JUDGE-9 + JUDGE-13).
;;   raco test test/judge-wire-tests.rkt
;;
;; What has to hold, with no server and no model:
;;   1. the writer emits object keys IN THE ORDER WRITTEN — the whole point
;;   2. the composed request is valid JSON and JEV's own /v1/systemone shape
;;   3. composing is deterministic: same input, same bytes
;;   4. the validator holds a verdict to the request it answers, by path,
;;      and is OPEN to fields it does not know

(require rackunit json racket/string
         "../domain/judge/wire.rkt")

;; ---- the ordered writer -------------------------------------------------------

(test-case "ordered-json writes keys in the order written, never sorted"
  (define j (ordered-json (jobj (list (cons "zebra" 1) (cons "apple" 2) (cons "mango" 3)))))
  (check-equal? j "{\"zebra\":1,\"apple\":2,\"mango\":3}")
  ;; and it is real JSON — the parse sees the same values
  (check-equal? (hash-ref (string->jsexpr j) 'zebra) 1))

(test-case "ordered-json: escaping is the json library's, arrays stay arrays, null is null"
  (check-equal? (ordered-json (jobj (list (cons "a\"b" "c\\d"))))
                "{\"a\\\"b\":\"c\\\\d\"}")
  (check-equal? (ordered-json (list "x" 1 #t 'null)) "[\"x\",1,true,null]")
  ;; a nested object nests; a pair whose value is a LIST is an object entry
  ;; with an array value, not a misread array (the trap the struct exists for)
  (check-equal? (ordered-json (jobj (list (cons "levels" (list "low" "high")))))
                "{\"levels\":[\"low\",\"high\"]}"))

;; ---- the questions and the request ---------------------------------------------

(define QS
  (list (cons "team"   (judge-choice "Who should handle this?"
                                     (list (cons "billing" #f)
                                           (cons "technical" "setup, bugs, outages")
                                           (cons "sales" #f))))
        (cons "refund" (judge-noul "Does the customer ask for money back?"
                                   "asks for a refund or chargeback"
                                   "no money is mentioned"))
        (cons "tone"   (judge-score "How upset is the writer?"
                                    (list "calm" "annoyed" "angry")))))

(define REQ (judge-request "I was billed twice. Please refund the duplicate." QS))

(test-case "judge-request composes JEV's own wire, options and questions in written order"
  ;; byte-level: the orders survive, which no jsexpr round trip could promise
  (check-true (string-contains? REQ "\"billing\":null,\"technical\":\"setup, bugs, outages\",\"sales\":null"))
  (define (at needle) (caar (regexp-match-positions (regexp-quote needle) REQ)))
  (check-true (< (at "\"team\"") (at "\"refund\"") (at "\"tone\"")))
  ;; and composing twice gives the same bytes — what JUDGE-13 stores and replays
  (check-equal? REQ (judge-request "I was billed twice. Please refund the duplicate." QS))
  ;; parsed, it is the documented shape
  (define r (string->jsexpr REQ))
  (check-equal? (hash-ref (hash-ref (hash-ref r 'questions) 'refund) 'type) "noul")
  (check-equal? (hash-ref (hash-ref (hash-ref (hash-ref r 'questions) 'refund) 'criteria) 'true)
                "asks for a refund or chargeback")
  (check-equal? (hash-ref (hash-ref (hash-ref r 'questions) 'tone) 'criteria)
                (list "calm" "annoyed" "angry")))

(test-case "the constructors refuse what the wire would mangle"
  (check-exn exn:fail:user? (lambda () (judge-noul "" "t" "f")))
  (check-exn exn:fail:user? (lambda () (judge-choice "pick" '())))
  (check-exn exn:fail:user? (lambda () (judge-choice "pick" (list (cons "a" #f) (cons "a" #f))))
             "duplicate option keys are two names for one slot")
  (check-exn exn:fail:user? (lambda () (judge-score "rate" '())))
  (check-exn exn:fail:user? (lambda () (judge-request "s" '())))
  (check-exn exn:fail:user?
             (lambda () (judge-request "s" (list (cons "q" (judge-noul "i" "t" "f"))
                                                 (cons "q" (judge-noul "i" "t" "f")))))
             "duplicate question names"))

;; ---- the verdict validator ------------------------------------------------------

(define (verdict #:model [model "aac6fef/laya-mlx@20aed81 float16"]
                 #:answers answers)
  (jsexpr->string (hasheq 'model model 'answers answers
                          'usage (hasheq 'input_tokens 100 'output_tokens 0))))

(define GOOD
  (verdict #:answers
           (hasheq 'team (hasheq 'type "choice" 'choice "billing" 'confidence 0.61
                                 ;; fields we did not ask for — the schema is OPEN
                                 'probabilities (hasheq 'billing 0.61 'technical 0.2 'sales 0.19)
                                 'order (list "billing" "technical" "sales")
                                 'action "route to billing")
                   'refund (hasheq 'type "noul" 'noul 0.93 'confidence 0.93)
                   'tone (hasheq 'type "score" 'score 1.0 'confidence 0.52
                                 'legend (list "calm" "annoyed" "angry")))))

(test-case "a laya-shaped verdict passes, extra fields and all"
  (check-false (verdict-problem REQ GOOD)))

(test-case "the validator names the first problem, by path"
  (define (prob v) (verdict-problem REQ v))
  (check-equal? (prob "not json") "the verdict is not a JSON object")
  (check-equal? (prob (jsexpr->string (hasheq 'answers (hasheq))))
                "$.model: the verdict names no checkpoint")
  (check-equal? (prob (verdict #:model "" #:answers (hasheq)))
                "$.model: the verdict names no checkpoint")
  (check-equal? (prob (jsexpr->string (hasheq 'model "m")))
                "$.answers: expected an object")
  ;; an unanswered question
  (define missing (prob (verdict #:answers
                                 (hasheq 'team (hasheq 'type "choice" 'choice "billing")
                                         'refund (hasheq 'type "noul" 'noul 0.9)))))
  (check-equal? missing "$.answers.tone: the question was not answered")
  ;; the wrong type for a question
  (check-equal? (prob (verdict #:answers
                               (hasheq 'team (hasheq 'type "noul" 'noul 0.5)
                                       'refund (hasheq 'type "noul" 'noul 0.9)
                                       'tone (hasheq 'type "score" 'score 1.0))))
                "$.answers.team.type: expected choice, got noul")
  ;; a typed field of the wrong shape — "0.93" the string is the JUDGE-6 lesson
  (check-equal? (prob (verdict #:answers
                               (hasheq 'team (hasheq 'type "choice" 'choice "billing")
                                       'refund (hasheq 'type "noul" 'noul "0.93")
                                       'tone (hasheq 'type "score" 'score 1.0))))
                "$.answers.refund.noul: expected a number")
  ;; a pick that is not one of the question's own options
  (check-equal? (prob (verdict #:answers
                               (hasheq 'team (hasheq 'type "choice" 'choice "legal")
                                       'refund (hasheq 'type "noul" 'noul 0.9)
                                       'tone (hasheq 'type "score" 'score 1.0))))
                "$.answers.team.choice: \"legal\" is not one of the question's options")
  ;; a request that itself will not parse is named as such, never a crash
  (check-equal? (verdict-problem "{" GOOD) "the request is not a JSON object"))
