#lang racket/base

;; domain/fields/fields.rkt — the operator-authored field vocabulary, shared.
;;
;; `required` / `digits` / `minlength` / `maxlength`, and deliberately NOT a
;; regex. The rules are written by an administrator and run against input the
;; administrator does not control, so a regex would be an admin-authored program
;; evaluated on attacker-chosen input — the same call the workflow binding
;; sublanguage makes by staying free of arithmetic and eval.
;;
;; It lives here rather than in the beta funnel because the document repository
;; needs the same vocabulary for team-defined object metadata (LAY-4), and two
;; implementations of one vocabulary drift. `domain/beta/beta.rkt` re-exports it,
;; so the funnel's callers are unchanged.
;;
;; `field-problem` returns #f or (list reason label limit) — a REASON rather than
;; a sentence, because the caller localizes it: the refusal names the field's
;; localized label, which means the experience is localized before it is
;; validated.

(require racket/string)

;; `field-key?` is exported for a SECOND asker: a trigger that matches on object
;; metadata (issue #87 req 3b) validates the keys in its condition, and deriving
;; the key vocabulary twice is `executor-can-run?`'s drift — the same argument that
;; brought `field-problem` here from beta.rkt in the first place.
(provide field-problem field-def-problem field-key?)

(define (field-key? k)
  (and (string? k) (regexp-match? #px"^[a-z][a-z0-9_]{0,39}$" k)))

;; Is a FIELD DEFINITION well formed? (The values are checked by field-problem.)
;; Unknown keys are refused rather than dropped: a rule that does nothing is how
;; an operator concludes the validation is broken.
(define FIELD-KEYS '(key label required digits minlength maxlength help))
(define (field-def-problem f)
  (cond
    [(not (hash? f)) "each field must be an object"]
    [(not (field-key? (hash-ref f 'key #f)))
     "a field needs a 'key' of 1-40 lower-case letters, digits or underscores, starting with a letter"]
    [(not (and (string? (hash-ref f 'label #f)) (not (string=? (hash-ref f 'label "") ""))))
     (format "field '~a' needs a non-empty label" (hash-ref f 'key ""))]
    [(for/or ([k (in-hash-keys f)]) (and (not (memq k FIELD-KEYS)) k))
     => (lambda (k) (format "field '~a': unknown setting '~a'" (hash-ref f 'key "") k))]
    [(not (boolean? (hash-ref f 'required #f))) (format "field '~a': 'required' must be a boolean" (hash-ref f 'key ""))]
    [(not (boolean? (hash-ref f 'digits #f))) (format "field '~a': 'digits' must be a boolean" (hash-ref f 'key ""))]
    [else #f]))

(define (field-problem fields body-ref)
  (for/or ([f (in-list fields)])
    (define k (hash-ref f 'key ""))
    (define label (let ([l (hash-ref f 'label #f)]) (if (and (string? l) (not (string=? l ""))) l k)))
    (define v (body-ref k))
    ;; Accept 13 and "13" alike. A hand-written TELEMACHUS_ONBOARDING_FILE will
    ;; sooner or later quote a number, and silently ignoring the constraint is a
    ;; far worse failure than accepting it.
    (define (num key)
      (define n (hash-ref f key #f))
      (define i (cond [(exact-integer? n) n]
                      [(and (string? n) (regexp-match? #px"^[0-9]+$" n)) (string->number n)]
                      [else #f]))
      (and i (positive? i) i))
    (cond
      [(string=? v "")
       ;; an empty optional field is simply not answered — never an error
       (and (eq? (hash-ref f 'required #f) #t) (list 'required label #f))]
      [(and (eq? (hash-ref f 'digits #f) #t)
            (not (regexp-match? #px"^[0-9]+$" v)))
       (list 'digits label #f)]
      [(and (num 'minlength) (< (string-length v) (num 'minlength)))
       (list 'too-short label (num 'minlength))]
      [(and (num 'maxlength) (> (string-length v) (num 'maxlength)))
       (list 'too-long label (num 'maxlength))]
      [else #f])))
