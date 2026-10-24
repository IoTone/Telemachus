#lang racket/base

;; domain/repo/classify.rkt — what KIND of document is this? (issue #87 slice 1,
;; decisions CLS-1…12).
;;
;; A trigger matches on a key prefix and a content type (triggers.rkt), so an
;; integrator receiving letters, invoices, forms, photographs and reports under
;; one prefix had no way to choose a schema before extracting fields. This is the
;; step that assigns a type.
;;
;; The module is PURE OF THE REPOSITORY, like `extract-fields` beside it: a rule
;; set is matched against a string, a label set against a scripted reply, and
;; every refusal is therefore testable with no database, no socket and no model.
;; doc-tools.rkt owns the tool, the attribute write and the derived document.
;;
;; THE BACKENDS ARE A CHAIN, NOT A CHOICE (CLS-1): `backends` is an ordered list
;; and the first that answers wins. Rules run first by default because they cost
;; nothing, spend no tokens and give the same answer every time; the model is
;; what the operator falls back to for the documents no rule describes.

(require racket/string racket/list racket/format
         json
         "../tools/jsonschema.rkt"
         (only-in "../ai/content.rkt" outer-json))

(provide CLASSIFY-CAP CLASSIFY-BACKENDS MAX-LABELS MAX-RULES MAX-PHRASES
         CLASSIFY-FIELDS
         labels-problem rules-problem backends-problem
         label-names classify-rules classify-llm classify
         confidence->string)

;; ---- CLS-10: the model sees the opening, not the archive -----------------------------
;; A document's TYPE is evident from its first page — a letterhead, a title, an
;; invoice number — so truncating is the right answer here, where it is the wrong
;; answer for `doc_translate` (which refuses a document over its cap rather than
;; returning half a translation). The asymmetry is deliberate: a truncated
;; classification is still a classification of that document; half a translation
;; is a document that lies about being finished. The result reports how many
;; characters were read, so nobody has to infer it.
(define CLASSIFY-CAP 8000)

(define CLASSIFY-BACKENDS '("rules" "llm"))
(define MAX-LABELS 50)
(define MAX-RULES 100)
(define MAX-PHRASES 20)
(define MAX-PHRASE-LENGTH 200)

;; ---- CLS-7: the three fields the result lands in --------------------------------------
;; The issue asks for `doc.type`, `doc.type.confidence` and `doc.type.source`, and
;; a DOT IS NOT A LEGAL ATTRIBUTE KEY: LAY-4's `field-key?` is
;; `^[a-z][a-z0-9_]{0,39}$`, a vocabulary the object metadata, the beta funnel and
;; every `?attr=` filter share. Loosening it for three keys would change what a
;; key is everywhere, so the keys are spelled with underscores. Namespaced
;; `doc_type*` for FEED-20's reason — they are declared on the team additively and
;; must not collide with a field the team defined for itself.
(define CLASSIFY-FIELDS
  (list (hasheq 'key "doc_type"            'label "Document type")
        (hasheq 'key "doc_type_confidence" 'label "Type confidence")
        (hasheq 'key "doc_type_source"     'label "Type decided by")))

;; ---- the label set --------------------------------------------------------------------
;; A name is a SLUG, because it is both an enum value the model must reproduce
;; exactly and the stored attribute value a trigger will later match on by
;; equality. "Invoice" and "invoice" would be two document types, and nothing
;; downstream could tell they were meant to be one.
(define (label-name? s)
  (and (string? s) (regexp-match? #px"^[a-z0-9][a-z0-9_-]{0,39}$" s)))

(define LABEL-KEYS '(name description examples))

(define (label-problem l)
  (cond
    [(not (hash? l)) "each label must be an object"]
    [(not (label-name? (hash-ref l 'name #f)))
     "a label needs a 'name' of 1-40 lower-case letters, digits, '-' or '_'"]
    [(for/or ([k (in-hash-keys l)]) (and (not (memq k LABEL-KEYS)) k))
     => (lambda (k) (format "label '~a': unknown setting '~a'" (hash-ref l 'name "") k))]
    [(not (let ([d (hash-ref l 'description "")]) (or (string? d) (eq? d 'null))))
     (format "label '~a': 'description' must be a string" (hash-ref l 'name ""))]
    [(not (let ([e (hash-ref l 'examples '())])
            (and (list? e) (andmap string? e))))
     (format "label '~a': 'examples' must be an array of strings" (hash-ref l 'name ""))]
    [else #f]))

(define (labels-problem labels)
  (cond
    [(not (list? labels)) "labels must be an array"]
    [(null? labels) "at least one label is needed"]
    [(> (length labels) MAX-LABELS) (format "at most ~a labels" MAX-LABELS)]
    [(for/or ([l (in-list labels)]) (label-problem l)) => values]
    [(let ([ns (label-names labels)])
       (and (not (= (length ns) (length (remove-duplicates ns)))) "two labels share a name"))
     => values]
    [else #f]))

(define (label-names labels)
  (for/list ([l (in-list labels)]) (hash-ref l 'name "")))

;; ---- CLS-2: the rules backend, and why it has NO REGEX --------------------------------
;; The requirement says "regex/keyword/MIME/page-count rules". It is keywords
;; here, and that is the same call `domain/fields/fields.rkt` made for the funnel's
;; validation vocabulary and `domain/flow/bind.rkt` made for the workflow binding
;; sublanguage: a rule is written by an ADMINISTRATOR and run against the text of
;; a document the administrator does not control. An operator-authored regexp
;; evaluated on attacker-chosen input is a denial of service with the operator's
;; own configuration as the weapon — catastrophic backtracking over a 200,000
;; character extraction, on the upload path, with nothing to blame but a rule
;; somebody wrote to be helpful. A phrase cannot backtrack.
;;
;; (`doc_extract_fields`'s schema does support `pattern`, and that is not the same
;; thing: it runs against the MODEL's reply, which this platform asked for and
;; bounded, and jsonschema.rkt already wraps it in a handler so a bad pattern
;; never refuses.)
;;
;; Page count is not here either, and deliberately: no extractor reports it.
;; `extract-text/spans` answers text and spans, and inventing a page count from
;; the span list would be a number nothing measured.
(define RULE-KEYS '(label content_type key_suffix all any none))

(define (phrases-problem rule k)
  (define v (hash-ref rule k '()))
  (cond
    [(not (and (list? v) (andmap string? v)))
     (format "rule for '~a': '~a' must be an array of strings" (hash-ref rule 'label "") k)]
    [(> (length v) MAX-PHRASES)
     (format "rule for '~a': at most ~a phrases in '~a'" (hash-ref rule 'label "") MAX-PHRASES k)]
    [(for/or ([s (in-list v)]) (string=? (string-trim s) ""))
     (format "rule for '~a': an empty phrase in '~a'" (hash-ref rule 'label "") k)]
    [(for/or ([s (in-list v)]) (> (string-length s) MAX-PHRASE-LENGTH))
     (format "rule for '~a': a phrase in '~a' is longer than ~a characters"
             (hash-ref rule 'label "") k MAX-PHRASE-LENGTH)]
    [else #f]))

(define (rule-problem rule names)
  (cond
    [(not (hash? rule)) "each rule must be an object"]
    [(not (member (hash-ref rule 'label "") names))
     (format "rule label '~a' is not one of the labels" (hash-ref rule 'label ""))]
    [(for/or ([k (in-hash-keys rule)]) (and (not (memq k RULE-KEYS)) k))
     => (lambda (k) (format "rule for '~a': unknown setting '~a'" (hash-ref rule 'label "") k))]
    [(not (let ([ct (hash-ref rule 'content_type "")]) (string? ct)))
     (format "rule for '~a': 'content_type' must be a string" (hash-ref rule 'label ""))]
    [(not (let ([s (hash-ref rule 'key_suffix "")]) (string? s)))
     (format "rule for '~a': 'key_suffix' must be a string" (hash-ref rule 'label ""))]
    [(for/or ([k (in-list '(all any none))]) (phrases-problem rule k)) => values]
    ;; CLS-4: a rule with no condition matches EVERY document, which makes every
    ;; rule after it dead code while looking like configuration. Refused, not
    ;; tolerated — the same reason an unknown setting is refused rather than
    ;; dropped. A deliberate catch-all is a rule whose one condition every
    ;; document satisfies (`"content_type": ""` is not one: an omitted condition
    ;; is not a condition), or it is the model backend, which always answers.
    [(and (string=? (hash-ref rule 'content_type "") "")
          (string=? (hash-ref rule 'key_suffix "") "")
          (null? (hash-ref rule 'all '()))
          (null? (hash-ref rule 'any '()))
          (null? (hash-ref rule 'none '())))
     (format "rule for '~a' has no condition — it would match every document"
             (hash-ref rule 'label ""))]
    [else #f]))

(define (rules-problem rules names)
  (cond
    [(not (list? rules)) "rules must be an array"]
    [(> (length rules) MAX-RULES) (format "at most ~a rules" MAX-RULES)]
    [(for/or ([r (in-list rules)]) (rule-problem r names)) => values]
    [else #f]))

(define (backends-problem backends)
  (cond
    [(not (and (list? backends) (andmap string? backends))) "backends must be an array of strings"]
    [(null? backends) "at least one backend is needed"]
    [(for/or ([b (in-list backends)]) (and (not (member b CLASSIFY-BACKENDS)) b))
     => (lambda (b)
          (format (string-append
                   "unknown backend '~a' — this build classifies with ~a. An embedding "
                   "nearest-label backend is not built: the platform has no embedding "
                   "wire, store or meter, so it is its own slice rather than a flag here.")
                  b (string-join CLASSIFY-BACKENDS " and ")))]
    [(not (= (length backends) (length (remove-duplicates backends)))) "a backend is named twice"]
    [else #f]))

;; ---- matching -------------------------------------------------------------------------
(define (contains-ci? hay needle)
  (string-contains? (string-downcase hay) (string-downcase needle)))

;; A content type matches exactly, or by prefix when the rule's value ends in `/`
;; (`"image/"` is every photograph). Nothing else — a glob would be a pattern
;; language, which is what CLS-2 is about.
(define (ct-matches? want have)
  (or (string=? want "")
      (if (string-suffix? want "/")
          (string-prefix? (string-downcase have) (string-downcase want))
          (string=? (string-downcase want) (string-downcase have)))))

(define (rule-matches? rule text ct key)
  (and (ct-matches? (hash-ref rule 'content_type "") ct)
       (let ([sfx (hash-ref rule 'key_suffix "")])
         (or (string=? sfx "") (string-suffix? (string-downcase key) (string-downcase sfx))))
       (for/and ([s (in-list (hash-ref rule 'all '()))]) (contains-ci? text s))
       (let ([any (hash-ref rule 'any '())])
         (or (null? any) (for/or ([s (in-list any)]) (contains-ci? text s))))
       (for/and ([s (in-list (hash-ref rule 'none '()))]) (not (contains-ci? text s)))))

;; CLS-3: A RULE MATCH IS THE CONFIDENCE. The requirement says the rules backend
;; "short-circuits when confident", and a deterministic rule has no degrees: it
;; matched or it did not. Attaching 0.85 to it would be a number nothing computed,
;; which is how a reader comes to believe the wrong thing — the same objection
;; that keeps `interval_seconds` off a daily schedule's read.
;;
;; CLS-4: first match wins, in list order, like the route table. The rationale
;; names the rule's position, because "why did this become an invoice" is a
;; question about one line of configuration.
;; -> a result hash, or #f when no rule matched.
(define (classify-rules rules #:text [text ""] #:content-type [ct ""] #:key [key ""])
  (for/or ([r (in-list rules)] [i (in-naturals 1)])
    (and (rule-matches? r text ct key)
         (hasheq 'label (hash-ref r 'label)
                 'confidence 1.0
                 'source "rules"
                 'rationale (format "rule ~a of ~a matched" i (length rules))))))

;; ---- the model backend ----------------------------------------------------------------
;; CLS-5: the reply is held to the label set by the SAME validator DWF-5's
;; extraction uses, with the names as an `enum`. A label outside the set is a
;; refusal naming the path — never coerced to the nearest label and never
;; silently recorded as "unknown", because a document type nobody asserted is
;; exactly what a trigger would then act on.
(define (classify-schema names)
  (hasheq 'type "object"
          'required '("label" "confidence")
          'properties
          (hasheq 'label (hasheq 'type "string" 'enum names)
                  'confidence (hasheq 'type "number" 'minimum 0 'maximum 1)
                  'rationale (hasheq 'type "string" 'maxLength 500))))

(define CLASSIFY-SYSTEM
  (string-append
   "You classify a document into exactly ONE of the labels the user gives you. Reply "
   "with ONLY one JSON object: {\"label\": <one of the label names, verbatim>, "
   "\"confidence\": <a number from 0 to 1>, \"rationale\": <one short sentence>}. Use a "
   "label name exactly as given — never a variant, never a new one. The confidence is "
   "how sure you are, and a low number is a useful answer: say 0.3 rather than guessing "
   "confidently. No prose, no explanation, no markdown fences."))

(define (labels->prompt labels text)
  (jsexpr->string
   (hasheq 'labels (for/list ([l (in-list labels)])
                     (define d (hash-ref l 'description ""))
                     (define e (hash-ref l 'examples '()))
                     (let* ([h (hasheq 'name (hash-ref l 'name))]
                            [h (if (and (string? d) (not (string=? d ""))) (hash-set h 'description d) h)]
                            [h (if (pair? e) (hash-set h 'examples e) h)])
                       h))
            'document text)))

;; -> (values result tokens), or raises. The refusal is retried ONCE, the
;; pipeline's rule: a 7B model that answered with a fence or an invented label
;; usually gets it right when told so, and a second attempt is cheaper than a
;; failed run.
(define (classify-llm labels text #:chat chat)
  (when (string=? (string-trim text) "")
    (error 'doc_classify "nothing to classify — the document has no text, and no rule matched its type"))
  (define names (label-names labels))
  (define schema (classify-schema names))
  (define prompt (labels->prompt labels text))
  (define (attempt sys)
    (define-values (reply tokens) (chat prompt #:system sys))
    (define j (outer-json (format "~a" reply)))
    (cond
      [(not (hash? j)) (values #f tokens "the model did not return a JSON object")]
      [else
       (define problems (validate-json schema j))
       (if (null? problems)
           (values j tokens #f)
           (values #f tokens (string-join problems "; ")))]))
  (define-values (j1 t1 p1) (attempt CLASSIFY-SYSTEM))
  (cond
    [j1 (values (normalize-llm j1) t1)]
    [else
     (define-values (j2 t2 p2)
       (attempt (string-append CLASSIFY-SYSTEM
                               " Your previous reply was refused: " p1
                               ". The label must be one of: " (string-join names ", ") ".")))
     (cond
       [j2 (values (normalize-llm j2) (+ t1 t2))]
       [else (error 'doc_classify "classification refused: ~a" p2)])]))

(define (normalize-llm j)
  (hasheq 'label (hash-ref j 'label)
          'confidence (exact->inexact (hash-ref j 'confidence))
          'source "llm"
          'rationale (let ([r (hash-ref j 'rationale "")]) (if (string? r) r ""))))

;; ---- the chain ------------------------------------------------------------------------
;; CLS-6: when no backend answers, this REFUSES. It does not write
;; `doc_type = "unknown"`: a stored type is an assertion a trigger acts on, and
;; "nobody could tell" is not one. The message names the backends that were asked,
;; because the remedy is a rule or a model, and the operator is one field away
;; from either.
;; -> (values result tokens)
(define (classify labels
                  #:text [text ""] #:content-type [ct ""] #:key [key ""]
                  #:rules [rules '()] #:backends [backends CLASSIFY-BACKENDS]
                  #:chat [chat #f])
  (let loop ([bs backends] [tokens 0])
    (cond
      [(null? bs)
       (error 'doc_classify
              "no backend could classify ~a (tried ~a) — add a rule for it, or a model backend"
              (if (string=? key "") "the document" key) (string-join backends ", "))]
      [(string=? (car bs) "rules")
       (define r (classify-rules rules #:text text #:content-type ct #:key key))
       (if r (values r tokens) (loop (cdr bs) tokens))]
      [else
       (unless chat (error 'doc_classify "the llm backend needs a model seam"))
       (define-values (r t) (classify-llm labels text #:chat chat))
       (values r (+ tokens t))])))

;; CLS-8: LAY-4 attribute values are STRINGS, so the confidence is stored as one —
;; to two decimals, fixed, because `?attr=doc_type_confidence:0.90` is an equality
;; filter and a value whose spelling varies with the model's precision cannot be
;; filtered on at all.
(define (confidence->string c)
  (real->decimal-string (exact->inexact c) 2))
