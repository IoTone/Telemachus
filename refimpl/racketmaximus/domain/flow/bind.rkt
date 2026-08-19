#lang racket/base

;; domain/flow/bind.rkt — the workflow binding sublanguage (WF-2), deliberately
;; frozen. This is the part of the spec that decides whether the format stays a
;; declaration or rots into a bad programming language, so the grammar is fixed
;; here in the first commit and the escape hatch is "call a tool":
;;
;;   references only   ${input.x}  ${steps.<id>.output.<path>}
;;                     ${run.id}   ${principal.team_id}  ${principal.user_id}
;;                     ${principal.locale}                  — the profile language
;;                     ${item} ${item.<path>} ${index}      — INSIDE a `map` only,
;;                       which the spec validator enforces; the grammar here just
;;                       says what the shapes are.
;;   predicates        eq ne lt gt contains exists empty
;;   no arithmetic, no string functions, NO EVALUATION OF ANY KIND.
;;
;; A string that is *exactly* one reference resolves to the referenced value with
;; its type intact; a reference embedded in surrounding text interpolates to a
;; string. Everything a workflow cannot express here is a tool call — which is
;; typed, permissioned, testable and auditable, and is a better answer than
;; growing an expression language nobody chose to build.

(require racket/string racket/list json)

(provide ref-segments valid-ref? ref-step-id ref-root item-ref?
         binding-refs whole-binding
         resolve-value resolve-hash make-context
         predicate-keys predicate? eval-predicate)

;; ---- reference syntax --------------------------------------------------------
(define BINDING-RX #px"\\$\\{([^{}]*)\\}")
(define WHOLE-RX   #px"^\\$\\{([^{}]*)\\}$")

;; every ${…} body inside a string, in order
(define (binding-refs s)
  (if (string? s)
      (for/list ([m (in-list (regexp-match* BINDING-RX s #:match-select values))]) (cadr m))
      '()))

;; the body, when the whole string is one reference (so the value keeps its type)
(define (whole-binding s)
  (and (string? s) (let ([m (regexp-match WHOLE-RX s)]) (and m (cadr m)))))

(define (ref-segments body) (string-split (string-trim body) "."))

;; Is this a reference the grammar admits? Shape only — whether the step exists is
;; the spec validator's job (it holds the step list); whether the value exists at
;; run time is the interpreter's.
(define (valid-ref? body)
  (define segs (ref-segments body))
  (and (pair? segs)
       (case (car segs)
         [("run")       (equal? segs '("run" "id"))]
         [("principal") (or (equal? segs '("principal" "team_id"))
                            (equal? segs '("principal" "user_id"))
                            (equal? segs '("principal" "locale")))]
         [("item")      #t]                       ; ${item} or ${item.<path>}
         [("index")     (equal? segs '("index"))]
         [("input")     (>= (length segs) 2)]
         [("steps")     (and (>= (length segs) 3) (equal? (caddr segs) "output"))]
         [else #f])))

;; the step a `steps.<id>.output…` reference depends on, else #f
(define (ref-root body) (let ([s (ref-segments body)]) (and (pair? s) (car s))))

;; does this string reach for the loop variables? only legal inside a `map`
(define (item-ref? s)
  (for/or ([b (in-list (binding-refs s))]) (and (member (ref-root b) '("item" "index")) #t)))

(define (ref-step-id body)
  (define segs (ref-segments body))
  (and (>= (length segs) 3) (equal? (car segs) "steps") (cadr segs)))

;; ---- resolution --------------------------------------------------------------
;; One nested jsexpr, so a reference is just a path walk — no per-root special
;; cases, which is why the grammar above stays this small.
(define (make-context #:input [input (hasheq)] #:outputs [outputs (hasheq)]
                      #:run-id [run-id ""] #:team-id [team-id ""] #:user-id [user-id ""]
                      #:locale [locale "en"] #:item [item 'none] #:index [index 'none])
  (define base
    (hasheq 'input input
            'steps (for/hasheq ([(k v) (in-hash outputs)]) (values k (hasheq 'output v)))
            'run (hasheq 'id run-id)
            'principal (hasheq 'team_id team-id 'user_id user-id 'locale locale)))
  (let* ([h (if (eq? item 'none)  base (hash-set base 'item item))]
         [h (if (eq? index 'none) h    (hash-set h 'index index))])
    h))

(define (descend v segs)
  (cond
    [(null? segs) v]
    [(hash? v) (descend (hash-ref v (string->symbol (car segs)) 'null) (cdr segs))]
    [(and (list? v) (regexp-match #px"^[0-9]+$" (car segs)))
     (define i (string->number (car segs)))
     (descend (if (< i (length v)) (list-ref v i) 'null) (cdr segs))]
    [else 'null]))

(define (lookup ctx body) (descend ctx (ref-segments body)))

;; jsexpr → the text it contributes to an interpolated string
(define (as-text v)
  (cond [(string? v) v]
        [(eq? v 'null) ""]
        [(boolean? v) (if v "true" "false")]
        [(number? v) (number->string v)]
        [else (jsexpr->string v)]))

(define (resolve-value v ctx)
  (cond
    [(string? v)
     (define whole (whole-binding v))
     (cond
       [whole (lookup ctx whole)]                       ; type preserved
       [(null? (binding-refs v)) v]
       [else (regexp-replace* BINDING-RX v              ; interpolated → string
                              (lambda (_ body) (as-text (lookup ctx body))))])]
    [(hash? v) (for/hasheq ([(k x) (in-hash v)]) (values k (resolve-value x ctx)))]
    [(list? v) (for/list ([x (in-list v)]) (resolve-value x ctx))]
    [else v]))

(define (resolve-hash h ctx)
  (if (hash? h) (for/hasheq ([(k v) (in-hash h)]) (values k (resolve-value v ctx))) (hasheq)))

;; ---- predicates --------------------------------------------------------------
(define predicate-keys '(eq ne lt gt contains exists empty))
(define arity (hash 'eq 2 'ne 2 'lt 2 'gt 2 'contains 2 'exists 1 'empty 1))

;; exactly one key from the frozen set, with a list of the right length
(define (predicate? p)
  (and (hash? p)
       (= (hash-count p) 1)
       (let ([k (car (hash-keys p))])
         (and (memq k predicate-keys)
              (let ([args (hash-ref p k)])
                (and (list? args) (= (length args) (hash-ref arity k))))))))

(define (blank? v)
  (or (eq? v 'null) (equal? v "") (null? v)
      (and (hash? v) (zero? (hash-count v)))))

(define (compare who a b num str)
  (cond [(and (real? a) (real? b)) (num a b)]
        [(and (string? a) (string? b)) (str a b)]
        [else (error 'flow "~a: incomparable operands (~a, ~a)" who (as-text a) (as-text b))]))

(define (eval-predicate p ctx)
  (define k (car (hash-keys p)))
  (define args (for/list ([a (in-list (hash-ref p k))]) (resolve-value a ctx)))
  (case k
    [(eq) (equal? (first args) (second args))]
    [(ne) (not (equal? (first args) (second args)))]
    [(lt) (compare 'lt (first args) (second args) < string<?)]
    [(gt) (compare 'gt (first args) (second args) > string>?)]
    [(contains)
     (define hay (first args)) (define needle (second args))
     (cond [(and (string? hay) (string? needle)) (string-contains? hay needle)]
           [(list? hay) (and (member needle hay) #t)]
           [else #f])]
    [(exists) (not (eq? (first args) 'null))]
    [(empty) (blank? (first args))]
    [else #f]))
