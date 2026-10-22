#lang racket/base

;; domain/judge/wire.rkt — the typed-judgment wire (JUDGE-9 + JUDGE-13, issue #57).
;;
;; A judgment request is JEV's own `POST /v1/systemone` shape, which laya answers
;; locally: `{state, questions}` where `questions` is a JSON OBJECT of named
;; questions and a choice question's `criteria` is a JSON OBJECT of options.
;; Both are objects whose KEY ORDER is part of the question — measured on laya,
;; reordering the same options changed the pick for the same text (1 of 6
;; orderings agreed; one probability moved 0.54). That is a shape no jsexpr can
;; carry: `hasheq` has no key order, `jsexpr->string` would scramble it, and
;; `json-out`'s sort rule — right everywhere else — would be actively wrong here.
;;
;; So the request is COMPOSED BYTES (JUDGE-13): this module writes the request
;; JSON once, in the order the caller wrote, and every hop after that treats it
;; as a string. The job payload carries `request_json`; the worker forwards it
;; verbatim; the verdict is stored AS RECEIVED. Order preservation is a property
;; of construction, not of every hop's care — and the stored (request, verdict)
;; pair is byte-for-byte what crossed the wire, which is what LAY-11 chains and
;; an audit replays. Validation parses a COPY to check; the bytes that travel
;; are the bytes composed.
;;
;; The question constructors mirror poplog's `ts_noul` / `ts_choice` / `ts_score`
;; (packages/typesafe), the client this wire is pinned against:
;;
;;   noul    yes/no, criteria for each side, answered as a probability
;;   choice  named options, answered with the pick (an option's #f description
;;           goes out as JSON null — the wire allows a key that speaks for itself)
;;   score   an ordered rubric, lowest first, answered with a position on it
;;
;; The verdict validator is written against laya's served answer shape:
;;   {model, answers: {name: {type, noul|choice|score, confidence, ...}},
;;    usage: {input_tokens, output_tokens}}
;; and is OPEN to fields it does not know (probabilities, action, order, legend)
;; — the call JUDGE-6 made for the beta verdict, for the same reason: the answer
;; side may legitimately say more than we asked.

(require json racket/list racket/string)

(provide judge-noul judge-choice judge-score
         judge-request
         verdict-problem
         (struct-out jobj)     ; an ordered JSON object: a list of pairs that SAYS so
         ordered-json          ; the writer, exported for its tests
         ;; …and the question vocabulary, for the same reason READ-DOORS is:
         ;; test/vocabulary-tests.rkt makes "closed" true in both directions —
         ;; no constructor outside the list, no entry without one.
         QUESTION-TYPES)

(define QUESTION-TYPES '("noul" "choice" "score"))

;; ---- the ordered-object writer -------------------------------------------------
;;
;; An ordered object is `(jobj (list (cons key value) ...))` — a struct, not a
;; bare list of pairs, because a pair whose cdr is a list IS a list and the two
;; shapes would otherwise be told apart by luck. The struct says what it is. A
;; plain list is an array; scalars (strings, numbers, booleans, 'null) go
;; through jsexpr->string, so escaping is the json library's, not ours.
(struct jobj (pairs) #:transparent)

(define (ordered-json x)
  (cond
    [(jobj? x)
     (string-append
      "{"
      (string-join
       (for/list ([kv (in-list (jobj-pairs x))])
         (string-append (jsexpr->string (car kv)) ":" (ordered-json (cdr kv))))
       ",")
      "}")]
    [(list? x)
     (string-append "[" (string-join (map ordered-json x) ",") "]")]
    [else (jsexpr->string x)]))

;; ---- questions -----------------------------------------------------------------

(define (text! who name v)
  (unless (and (string? v) (not (string=? v "")))
    (raise-user-error who "~a must be a nonempty string" name)))

(define (judge-noul instructions crit-true crit-false)
  (text! 'judge-noul "instructions" instructions)
  (text! 'judge-noul "the true criterion" crit-true)
  (text! 'judge-noul "the false criterion" crit-false)
  (jobj (list (cons "type" "noul")
              (cons "instructions" instructions)
              (cons "criteria" (jobj (list (cons "true" crit-true)
                                           (cons "false" crit-false)))))))

;; options: a list of (cons key description), description #f for a key that
;; speaks for itself. The ORDER WRITTEN is the order sent — that is the point.
(define (judge-choice instructions options)
  (text! 'judge-choice "instructions" instructions)
  (unless (and (list? options) (pair? options)
               (andmap (lambda (o) (and (pair? o) (string? (car o))
                                        (not (string=? (car o) ""))
                                        (or (not (cdr o)) (string? (cdr o)))))
                       options))
    (raise-user-error 'judge-choice
                      "options must be a nonempty list of (key . description), description a string or #f"))
  (unless (= (length options) (length (remove-duplicates (map car options))))
    (raise-user-error 'judge-choice "option keys must be distinct"))
  (jobj (list (cons "type" "choice")
              (cons "instructions" instructions)
              (cons "criteria" (jobj (for/list ([o (in-list options)])
                                       (cons (car o) (or (cdr o) 'null))))))))

;; levels: the rubric, lowest first — an ARRAY, so order is JSON's own here
(define (judge-score instructions levels)
  (text! 'judge-score "instructions" instructions)
  (unless (and (list? levels) (pair? levels) (andmap string? levels))
    (raise-user-error 'judge-score "levels must be a nonempty list of strings, lowest first"))
  (jobj (list (cons "type" "score")
              (cons "instructions" instructions)
              (cons "criteria" levels))))

;; ---- the request ---------------------------------------------------------------
;;
;; questions: a list of (cons name question), each question from a constructor
;; above. The answer is the request as a STRING — composed once, never
;; re-serialized. The names are what the verdict's answers are keyed by.
(define (judge-request state questions)
  (unless (string? state) (raise-user-error 'judge-request "state must be a string"))
  (unless (and (list? questions) (pair? questions)
               (andmap (lambda (q) (and (pair? q) (string? (car q))
                                        (not (string=? (car q) ""))
                                        (jobj? (cdr q))))
                       questions))
    (raise-user-error 'judge-request "questions must be a nonempty list of (name . question)"))
  (unless (= (length questions) (length (remove-duplicates (map car questions))))
    (raise-user-error 'judge-request "question names must be distinct"))
  (ordered-json (jobj (list (cons "state" state)
                            (cons "questions" (jobj questions))))))

;; ---- the verdict ---------------------------------------------------------------
;;
;; `verdict-problem request-json verdict-json` answers #f when the verdict
;; answers the request, or ONE string naming the first problem and its path —
;; the shape a remote kind's #:validate wants (a bad verdict is the WORKER's
;; mistake and fails the job by name). It parses COPIES of both strings; the
;; strings themselves are what gets stored.
;;
;; Checks: the verdict is a JSON object carrying `model` (the checkpoint —
;; JUDGE-11: a judgment without one is unauditable) and `answers`; every
;; question asked is answered; each answer's `type` matches the question's and
;; carries its typed field (`noul`/`score` a number, `choice` one of the
;; question's own option keys). Anything beyond that is the model's to say.
(define (json-or-#f s)
  (and (string? s)
       (with-handlers ([exn:fail? (lambda (_) #f)]) (string->jsexpr s))))

(define (verdict-problem request-json verdict-json)
  (define req (json-or-#f request-json))
  (define v (json-or-#f verdict-json))
  (cond
    [(not (hash? req)) "the request is not a JSON object"]
    [(not (hash? v)) "the verdict is not a JSON object"]
    [(not (and (string? (hash-ref v 'model #f))
               (not (string=? (hash-ref v 'model) ""))))
     "$.model: the verdict names no checkpoint"]
    [(not (hash? (hash-ref v 'answers #f))) "$.answers: expected an object"]
    [else
     (define answers (hash-ref v 'answers))
     (for/or ([(name q) (in-hash (hash-ref req 'questions (hasheq)))])
       (define a (hash-ref answers name #f))
       (define qtype (and (hash? q) (hash-ref q 'type #f)))
       (define (path . tail) (apply string-append "$.answers." (symbol->string name) tail))
       (cond
         [(not a) (path ": the question was not answered")]
         [(not (hash? a)) (path ": expected an object")]
         [(not (equal? (hash-ref a 'type #f) qtype))
          (path ".type: expected " (format "~a, got ~a" qtype (hash-ref a 'type "nothing")))]
         [(and (equal? qtype "noul") (not (real? (hash-ref a 'noul #f))))
          (path ".noul: expected a number")]
         [(and (equal? qtype "score") (not (real? (hash-ref a 'score #f))))
          (path ".score: expected a number")]
         [(equal? qtype "choice")
          (define pick (hash-ref a 'choice #f))
          (define keys (let ([c (hash-ref q 'criteria #f)])
                         (if (hash? c) (map symbol->string (hash-keys c)) '())))
          (cond
            [(not (string? pick)) (path ".choice: expected a string")]
            [(not (member pick keys))
             (path ".choice: " (format "~s is not one of the question's options" pick))]
            [else #f])]
         [else #f]))]))
