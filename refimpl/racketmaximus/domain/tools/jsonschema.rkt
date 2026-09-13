#lang racket/base

;; domain/tools/jsonschema.rkt — a small JSON Schema validator for extraction
;; output (slice 57, DWF-5).
;;
;; A pipeline asks the model for JSON and REFUSES anything that does not conform:
;; a missing required field, a string where a number was asked for, an invented
;; key. This is the Localization Manager's placeholder guard applied to data — an
;; extraction that looks finished and is wrong is worse than a failed step.
;;
;; Deliberately a subset. What is here: type (incl. a list of types), properties,
;; required, additionalProperties, items, enum, minimum/maximum, minLength/maxLength,
;; minItems/maxItems, pattern. What is NOT: $ref, allOf/anyOf/oneOf, formats,
;; dependencies. A schema that uses an unsupported keyword is not an error — the
;; keyword is ignored — but "type" is always enforced, so a document can never be
;; accepted on the strength of a keyword this validator does not understand.
;;
;; ONE DIFFERENCE FROM THE STANDARD, ON PURPOSE: an object schema that says
;; nothing about `additionalProperties` is CLOSED here (extra keys are refused),
;; where JSON Schema's default is open. The whole point of an extraction schema is
;; to say what the data is; a model that adds a `notes` field it made up must not
;; pass. Say `"additionalProperties": true` to open an object.

(require racket/list racket/string)

(provide validate-json json-valid?)

;; -> a list of problem strings, empty when the value conforms
(define (validate-json schema v)
  (reverse (check schema v "$" '())))

(define (json-valid? schema v) (null? (validate-json schema v)))

;; the JSON type name of a jsexpr, as a schema would spell it
(define (type-of v)
  (cond [(eq? v 'null) "null"]
        [(boolean? v) "boolean"]
        [(string? v) "string"]
        [(and (number? v) (exact-integer? v)) "integer"]
        [(and (number? v) (real? v) (integer? v)) "integer"]   ; 3.0 counts as an integer
        [(number? v) "number"]
        [(list? v) "array"]
        [(hash? v) "object"]
        [else "unknown"]))

(define (type-matches? want v)
  (define have (type-of v))
  (or (string=? want have)
      (and (string=? want "number") (string=? have "integer"))))

(define (problem acc path fmt . args)
  (cons (string-append path ": " (apply format fmt args)) acc))

(define (key->string k) (if (symbol? k) (symbol->string k) (format "~a" k)))

(define (check schema v path acc)
  (cond
    ;; a boolean schema: true accepts anything, false nothing
    [(eq? schema #t) acc]
    [(eq? schema #f) (problem acc path "no value is allowed here")]
    [(not (hash? schema)) (problem acc path "schema is not an object")]
    [else
     (define types (let ([t (hash-ref schema 'type #f)])
                     (cond [(string? t) (list t)] [(list? t) t] [else #f])))
     (define acc1
       (if (and types (not (for/or ([t (in-list types)]) (type-matches? t v))))
           (problem acc path "expected ~a, got ~a" (string-join types " or ") (type-of v))
           acc))
     ;; a type mismatch is the whole story for this node — checking string
     ;; length on a number would only add noise
     (cond
       [(not (eq? acc1 acc)) acc1]
       [else
        (let* ([acc (check-enum schema v path acc)]
               [acc (if (hash? v) (check-object schema v path acc) acc)]
               [acc (if (list? v) (check-array schema v path acc) acc)]
               [acc (if (string? v) (check-string schema v path acc) acc)]
               [acc (if (number? v) (check-number schema v path acc) acc)])
          acc)])]))

(define (check-enum schema v path acc)
  (define e (hash-ref schema 'enum #f))
  (if (and (list? e) (not (member v e)))
      (problem acc path "value is not one of the allowed values")
      acc))

(define (check-object schema v path acc)
  (define props (let ([p (hash-ref schema 'properties #f)]) (if (hash? p) p (hasheq))))
  (define required (let ([r (hash-ref schema 'required #f)]) (if (list? r) r '())))
  (define extra (hash-ref schema 'additionalProperties #f))   ; #f = closed (see header)
  (define acc1
    (for/fold ([acc acc]) ([r (in-list required)])
      (define k (string->symbol (key->string r)))
      (if (hash-has-key? v k) acc (problem acc path "missing required field '~a'" (key->string r)))))
  (define acc2
    (for/fold ([acc acc1]) ([(k sub) (in-hash props)])
      (define kk (string->symbol (key->string k)))
      (if (hash-has-key? v kk)
          (check sub (hash-ref v kk) (string-append path "." (key->string k)) acc)
          acc)))
  (for/fold ([acc acc2]) ([(k val) (in-hash v)])
    (cond
      [(hash-has-key? props k) acc]
      [(hash-has-key? props (string->symbol (key->string k))) acc]
      [(eq? extra #t) acc]
      [(hash? extra) (check extra val (string-append path "." (key->string k)) acc)]
      [else (problem acc path "unexpected field '~a'" (key->string k))])))

(define (check-array schema v path acc)
  (define items (hash-ref schema 'items #f))
  (define mn (hash-ref schema 'minItems #f))
  (define mx (hash-ref schema 'maxItems #f))
  (let* ([acc (if (and (real? mn) (< (length v) mn)) (problem acc path "fewer than ~a items" mn) acc)]
         [acc (if (and (real? mx) (> (length v) mx)) (problem acc path "more than ~a items" mx) acc)])
    (if items
        (for/fold ([acc acc]) ([x (in-list v)] [i (in-naturals)])
          (check items x (format "~a[~a]" path i) acc))
        acc)))

(define (check-string schema v path acc)
  (define mn (hash-ref schema 'minLength #f))
  (define mx (hash-ref schema 'maxLength #f))
  (define pat (hash-ref schema 'pattern #f))
  (let* ([acc (if (and (real? mn) (< (string-length v) mn)) (problem acc path "shorter than ~a characters" mn) acc)]
         [acc (if (and (real? mx) (> (string-length v) mx)) (problem acc path "longer than ~a characters" mx) acc)]
         [acc (if (and (string? pat)
                       (not (with-handlers ([exn:fail? (lambda (_) #t)])   ; a bad pattern never refuses
                              (regexp-match? (pregexp pat) v))))
                  (problem acc path "does not match pattern ~s" pat)
                  acc)])
    acc))

(define (check-number schema v path acc)
  (define mn (hash-ref schema 'minimum #f))
  (define mx (hash-ref schema 'maximum #f))
  (let* ([acc (if (and (real? mn) (< v mn)) (problem acc path "less than the minimum ~a" mn) acc)]
         [acc (if (and (real? mx) (> v mx)) (problem acc path "more than the maximum ~a" mx) acc)])
    acc))
