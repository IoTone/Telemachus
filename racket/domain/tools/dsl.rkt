#lang racket/base

;; domain/tools/dsl.rkt — a `define-tool` DSL that emits OpenAI-compatible
;; function tool schemas.
;;
;; The "gets better in Racket" piece: instead of a long hand-maintained list of
;; nested dicts, a tool is a declaration —
;;
;;   (define-tool grep
;;     #:description "Search file contents…"
;;     (pattern string #:description "Regular expression to search for")
;;     (path    string #:optional #:description "Directory or file (optional)")
;;     (max_results integer #:optional #:description "Max matches (optional)"))
;;
;; — and the macro produces the exact JSON the LLM sees. Required-by-default;
;; #:optional drops a param from "required". #:enum and #:items supported.
;; Arrays of OBJECTS use #:items-of with nested param specs (same conventions):
;;
;;   (checklist_items array #:optional
;;     #:items-of ((text string #:description "The to-do item text")
;;                 (done boolean #:optional #:description "Checked off?"))
;;     #:description "Checklist items …")

(require json
         (for-syntax racket/base syntax/parse))

(provide define-tool tool->jsexpr all-tool-schemas reset-tools! tool-ref)

;; ---- registry --------------------------------------------------------------
(define *tools* (box '()))                       ; list of (cons name jsexpr), reversed
(define (reset-tools!) (set-box! *tools* '()))
(define (register! name jsx) (set-box! *tools* (cons (cons name jsx) (unbox *tools*))) jsx)
(define (all-tool-schemas) (map cdr (reverse (unbox *tools*))))
(define (tool-ref name)                          ; fetch one tool's jsexpr by name
  (cond [(assoc name (unbox *tools*)) => cdr] [else #f]))

;; ---- runtime builders ------------------------------------------------------
;; a param is (list name-string property-jsexpr required?)
;; #:items is either a type symbol (array of scalars) or a ready jsexpr spec
;; (array of objects, built by object-spec from #:items-of).
(define (param name type #:description [desc #f] #:required? [req? #t]
               #:enum [enum #f] #:items [items #f])
  ;; `_` as the type omits the "type" key (e.g. an intentionally-untyped value);
  ;; a missing description omits that key too.
  (define h0 (let ([base (if (eq? type '_) (hasheq) (hasheq 'type (symbol->string type)))])
               (if desc (hash-set base 'description desc) base)))
  (define h1 (if enum  (hash-set h0 'enum enum) h0))
  (define h2 (cond [(symbol? items) (hash-set h1 'items (hasheq 'type (symbol->string items)))]
                   [items           (hash-set h1 'items items)]
                   [else h1]))
  (list (symbol->string name) h2 req?))

;; an object schema from a list of params — the items spec for object arrays
(define (object-spec params)
  (hasheq 'type "object"
          'properties (for/hasheq ([p (in-list params)])
                        (values (string->symbol (car p)) (cadr p)))
          'required (for/list ([p (in-list params)] #:when (caddr p)) (car p))))

(define (tool->jsexpr name desc params)
  (hasheq 'type "function"
          'function
          (hasheq 'name (symbol->string name)
                  'description desc
                  'parameters
                  (hasheq 'type "object"
                          'properties (for/hasheq ([p (in-list params)])
                                        (values (string->symbol (car p)) (cadr p)))
                          'required (for/list ([p (in-list params)] #:when (caddr p)) (car p))))))

;; ---- the macro -------------------------------------------------------------
(begin-for-syntax
  (define-syntax-class tparam
    #:attributes (rt)
    (pattern (pid:id ptype:id
              (~alt (~optional (~seq #:description d:str))
                    (~optional (~seq #:enum (e:str ...)))
                    (~optional (~seq #:items it:id))
                    (~optional (~seq #:items-of (sub:tparam ...)))   ; array of objects
                    (~optional (~and #:optional opt))) ...)
      #:attr rt
      #`(param 'pid 'ptype
               #:description #,(if (attribute d) #'d #'#f)
               #:required? #,(if (attribute opt) #'#f #'#t)
               #:enum #,(if (attribute e) #'(list e ...) #'#f)
               #:items #,(cond [(attribute it) #'(quote it)]
                               [(attribute sub) #'(object-spec (list sub.rt ...))]
                               [else #'#f])))))

(define-syntax (define-tool stx)
  (syntax-parse stx
    [(_ tname:id
        (~optional (~seq #:description td:str) #:defaults ([td #'""]))
        p:tparam ...)
     ;; expand to a definition (not a bare expression, which `racket file.rkt`
     ;; would print) — binds `tname` to its schema and registers it.
     #'(define tname (register! 'tname (tool->jsexpr 'tname td (list p.rt ...))))]))
