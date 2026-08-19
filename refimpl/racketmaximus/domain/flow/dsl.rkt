#lang racket/base

;; domain/flow/dsl.rkt — `define-workflow`, the authoring surface (WF-1).
;;
;; The move is the one `domain/tools/dsl.rkt` already makes for tools: a macro
;; whose OUTPUT is the plain-data document the rest of the system consumes.
;; Nothing downstream knows this macro exists — the interpreter, the database, the
;; API and the diagram all see the spec, and a hand-written JSON file is
;; indistinguishable from a macro-generated one. That is what makes the spec, and
;; not this file, the contract.
;;
;;   (define-workflow triage-lead
;;     #:description "Score an inbound lead and route it"
;;     #:input ([lead_id string])
;;     (step fetch  (tool get_lead #:id (in lead_id)))
;;     (step gate   (choice (gt (out fetch rating) 3) #:then notify #:else archive))
;;     (step notify (tool create_note #:title "Hot lead" #:body (out fetch summary)) #:end)
;;     (step archive (tool archive_lead #:id (in lead_id))))
;;
;; A fan-out runs one tool per item, with (item) and (index) bound:
;;
;;     (step to_all (map #:over (list "es" "nl" "is")
;;                       (tool translate_text #:text (out chat result) #:target (item))))
;;     (step back   (map #:over (out to_all results)
;;                       (tool translate_text #:text (item result) #:target (locale))))
;;
;; Checked while the module is compiled: duplicate step ids, `#:next` / `#:then` /
;; `#:else` / `(out …)` naming a step that was never declared, unknown predicate
;; operators and their arity, unknown input types. Everything else — and every
;; rule the format has — is checked by `validate-spec`, which runs on the emitted
;; document at module instantiation. The macro has NO private fast path into the
;; runtime; if it did, the two definitions of "valid" would drift.

(require (for-syntax racket/base racket/string syntax/parse)
         json
         "spec.rkt")

(provide define-workflow)

(begin-for-syntax
  (define PREDICATES '(eq ne lt gt contains exists empty))
  (define ARITY (hash 'eq 2 'ne 2 'lt 2 'gt 2 'contains 2 'exists 1 'empty 1))
  (define INPUT-TYPES '(string number boolean object array))

  (define (id->string s) (symbol->string (syntax-e s)))

  (define (check-step! who s ids)
    (unless (member (syntax-e s) ids)
      (raise-syntax-error 'define-workflow
                          (format "~a names step '~a', which is not declared in this workflow"
                                  who (syntax-e s))
                          s)))

  ;; a DSL value → the JSON value the spec holds (a reference string, or a literal)
  (define (value->js v ids)
    (syntax-parse v
      #:datum-literals (in out run-id team-id user-id locale item index)
      [(in n:id) (datum->syntax v (format "${input.~a}" (id->string #'n)))]
      [(item p:id ...)
       (define path (map id->string (syntax->list #'(p ...))))
       (datum->syntax v (format "${item~a}" (if (null? path) "" (string-append "." (string-join path ".")))))]
      [(index)  (datum->syntax v "${index}")]
      [(locale) (datum->syntax v "${principal.locale}")]
      [(out s:id p:id ...)
       (check-step! "(out …)" #'s ids)
       (define path (map id->string (syntax->list #'(p ...))))
       (datum->syntax v (format "${steps.~a.output~a}" (id->string #'s)
                                (if (null? path) "" (string-append "." (string-join path ".")))))]
      [(run-id)   (datum->syntax v "${run.id}")]
      [(team-id)  (datum->syntax v "${principal.team_id}")]
      [(user-id)  (datum->syntax v "${principal.user_id}")]
      [x:str #'x]
      [x:number #'x]
      [x:boolean #'x]
      [_ (raise-syntax-error 'define-workflow
                             "not a workflow value — use a literal, (in name), (out step path …), (item path …), (index), (locale), (run-id), (team-id) or (user-id)"
                             v)]))

  ;; a tool call, as the JSON object a step or a map template holds
  (define (tool->js tname kws vals ids)
    (define withs
      (for/list ([kw (in-list kws)] [v (in-list vals)])
        #`(cons '#,(string->symbol (keyword->string (syntax-e kw))) #,(value->js v ids))))
    #`(hasheq 'uses #,(string-append "tool:" (id->string tname))
              'with (make-immutable-hasheq (list #,@withs))))

  (define (pred->js p ids)
    (syntax-parse p
      [(op:id arg ...)
       (define o (syntax-e #'op))
       (unless (memq o PREDICATES)
         (raise-syntax-error 'define-workflow
                             (format "unknown predicate '~a' — the frozen set is ~a" o
                                     (string-join (map symbol->string PREDICATES) ", "))
                             #'op))
       (define args (syntax->list #'(arg ...)))
       (unless (= (length args) (hash-ref ARITY o))
         (raise-syntax-error 'define-workflow
                             (format "predicate '~a' takes ~a operand(s), got ~a" o (hash-ref ARITY o) (length args))
                             p))
       #`(hasheq '#,(syntax-e #'op) (list #,@(for/list ([a (in-list args)]) (value->js a ids))))]
      [_ (raise-syntax-error 'define-workflow "a `choice` needs a predicate like (gt (out step field) 3)" p)]))

  ;; one (step …) form → the JSON step object
  (define (step->js s ids)
    (syntax-parse s
      #:datum-literals (step tool choice map)
      ;; (step <id> (tool <name> #:k v …) [#:next <id> | #:end] [#:retry n])
      [(step sid:id (tool tname:id (~seq k:keyword kv) ...)
             (~alt (~optional (~seq #:next nxt:id))
                   (~optional (~and #:end endflag))
                   (~optional (~seq #:retry r:exact-nonnegative-integer))) ...)
       (when (attribute nxt) (check-step! "#:next" #'nxt ids))
       (define withs
         (for/list ([kw (in-list (syntax->list #'(k ...)))] [v (in-list (syntax->list #'(kv ...)))])
           #`(cons '#,(string->symbol (keyword->string (syntax-e kw))) #,(value->js v ids))))
       #`(let* ([h (hasheq 'id #,(id->string #'sid)
                           'uses #,(string-append "tool:" (id->string #'tname))
                           'with (make-immutable-hasheq (list #,@withs)))]
                [h #,(if (attribute nxt) #`(hash-set h 'next #,(id->string #'nxt)) #'h)]
                [h #,(if (attribute endflag) #'(hash-set h 'end #t) #'h)]
                [h #,(if (attribute r) #`(hash-set h 'retry (hasheq 'max #,#'r)) #'h)])
           h)]
      ;; (step <id> (map #:over <items> (tool <name> #:k v …) [#:retry n]) [#:next <id> | #:end])
      [(step sid:id (map (~seq #:over ovr) (tool tname:id (~seq k:keyword kv) ...)
                         (~optional (~seq #:retry tr:exact-nonnegative-integer)))
             (~alt (~optional (~seq #:next nxt:id))
                   (~optional (~and #:end endflag))) ...)
       (when (attribute nxt) (check-step! "#:next" #'nxt ids))
       (define items
         (syntax-parse #'ovr
           #:datum-literals (list)
           [(list x:str ...) #'(list x ...)]
           [other (value->js #'other ids)]))
       #`(let* ([tmpl #,(tool->js #'tname (syntax->list #'(k ...)) (syntax->list #'(kv ...)) ids)]
                [tmpl #,(if (attribute tr) #`(hash-set tmpl 'retry (hasheq 'max #,#'tr)) #'tmpl)]
                [h (hasheq 'id #,(id->string #'sid) 'uses "map" 'over #,items 'step tmpl)]
                [h #,(if (attribute nxt) #`(hash-set h 'next #,(id->string #'nxt)) #'h)]
                [h #,(if (attribute endflag) #'(hash-set h 'end #t) #'h)])
           h)]
      ;; (step <id> (choice <pred> #:then <id> [#:else <id>]))
      [(step sid:id (choice pred (~seq #:then thn:id) (~optional (~seq #:else els:id))))
       (check-step! "#:then" #'thn ids)
       (when (attribute els) (check-step! "#:else" #'els ids))
       #`(let* ([h (hasheq 'id #,(id->string #'sid) 'uses "choice"
                           'when #,(pred->js #'pred ids)
                           'then #,(id->string #'thn))]
                [h #,(if (attribute els) #`(hash-set h 'else #,(id->string #'els)) #'h)])
           h)]
      [_ (raise-syntax-error 'define-workflow
                             "a step is (step <id> (tool <name> #:k v …) …) or (step <id> (choice <pred> #:then <id> …))"
                             s)])))

(define-syntax (define-workflow stx)
  (syntax-parse stx
    #:datum-literals (step)
    [(_ wname:id
        (~alt (~optional (~seq #:name nm:str))
              (~optional (~seq #:description desc:str))
              (~optional (~seq #:version ver:exact-positive-integer))
              (~optional (~seq #:max-steps ms:exact-positive-integer))
              (~optional (~seq #:start st:id))
              (~optional (~seq #:input ([iname:id itype:id] ...)))) ...
        (step sid:id body ...) ...)
     (define ids (map syntax-e (syntax->list #'(sid ...))))
     ;; duplicate ids are caught here rather than by the validator, so the error
     ;; points at the source line instead of at a generated document
     (let loop ([seen '()] [rest (syntax->list #'(sid ...))])
       (unless (null? rest)
         (when (member (syntax-e (car rest)) seen)
           (raise-syntax-error 'define-workflow
                               (format "duplicate step id '~a'" (syntax-e (car rest))) (car rest)))
         (loop (cons (syntax-e (car rest)) seen) (cdr rest))))
     (when (attribute st) (check-step! "#:start" #'st ids))
     (when (attribute iname)
       (for ([t (in-list (syntax->list #'(itype ...)))])
         (unless (memq (syntax-e t) INPUT-TYPES)
           (raise-syntax-error 'define-workflow
                               (format "input type must be one of ~a"
                                       (string-join (map symbol->string INPUT-TYPES) ", ")) t))))
     (define steps
       (for/list ([s (in-list (syntax->list #'((step sid body ...) ...)))]) (step->js s ids)))
     (define inputs
       (if (attribute iname)
           (for/list ([n (in-list (syntax->list #'(iname ...)))]
                      [t (in-list (syntax->list #'(itype ...)))])
             #`(cons '#,(syntax-e n) #,(symbol->string (syntax-e t))))
           '()))
     ;; a definition, not a bare expression, so `racket file.rkt` doesn't print it
     #`(define wname
         (validate-spec
          (let* ([h (hasheq 'spec SPEC-FORMAT-VERSION
                            'slug #,(symbol->string (syntax-e #'wname))
                            'version #,(if (attribute ver) #'ver #'1)
                            'steps (list #,@steps))]
                 [h #,(if (attribute nm)   #'(hash-set h 'name nm)         #'h)]
                 [h #,(if (attribute desc) #'(hash-set h 'description desc) #'h)]
                 [h #,(if (attribute ms)   #'(hash-set h 'max_steps ms)     #'h)]
                 [h #,(if (attribute st)   #`(hash-set h 'start #,(symbol->string (syntax-e #'st))) #'h)]
                 [h #,(if (attribute iname)
                          #`(hash-set h 'input (make-immutable-hasheq (list #,@inputs)))
                          #'h)])
            h)))]))
