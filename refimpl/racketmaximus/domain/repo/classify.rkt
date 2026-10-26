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
         CLASSIFY-FIELDS DECIDED-SOURCE MAX-RATIONALE
         labels-problem rules-problem backends-problem decided-problem
         label-names classify-rules classify-llm classify classify-decided
         confidence->string
         ;; issue #87 req 6: the evaluation harness's pure half
         EVAL-FIELD EVAL-FIELDS expected-problem classify-attempt eval-report)

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
;; `#:llm-text` is what the MODEL is shown, where `#:text` is what the RULES are
;; matched against (issue #91 requirement 2). They are the same string unless the
;; caller asked for redaction: a rule is deterministic, local and never leaves the
;; process, so matching it on tokens buys nothing and costs correctness — a rule
;; keyed on an account-number prefix would match `<ID_1>` and nothing else. It
;; defaults to `#:text`, so every existing caller is unchanged.
(define (classify labels
                  #:text [text ""] #:content-type [ct ""] #:key [key ""]
                  #:rules [rules '()] #:backends [backends CLASSIFY-BACKENDS]
                  #:llm-text [llm-text #f]
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
       (define-values (r t) (classify-llm labels (or llm-text text) #:chat chat))
       (values r (+ tokens t))])))

;; CLS-8: LAY-4 attribute values are STRINGS, so the confidence is stored as one —
;; to two decimals, fixed, because `?attr=doc_type_confidence:0.90` is an equality
;; filter and a value whose spelling varies with the model's precision cannot be
;; filtered on at all.
(define (confidence->string c)
  (real->decimal-string (exact->inexact c) 2))

;; ---- CLS-15/16: a type a PERSON decided ------------------------------------------------
;; Slice 2, the review hook. A low-confidence classification parks the run on a
;; `review` step (LAY-1), and the decision has to be able to land on the document —
;; otherwise the queue drains and the wrong type is still asserted, which CLS-11's
;; attributes-first order makes certain rather than likely.
;;
;; THE PERSON IS HELD TO THE SAME LABEL SET AS THE MODEL (CLS-5 applied to a
;; human). A reviewer types the corrected label into a checklist answer — answers
;; are free strings, by LAY-1's design — so "Invoice", "invoices" and a trailing
;; space are all one keystroke away, and every one of them is a type no trigger
;; will ever match. Refusing it by name is the only answer that leaves the
;; reviewer able to fix it; coercing to the nearest label would quietly assert
;; something nobody chose.
(define DECIDED-SOURCE "review")
(define MAX-RATIONALE 500)

;; An EMPTY label is the withdrawal, and it is a deliberate second meaning rather
;; than a separate argument. A rejection means "this is none of these kinds", and
;; CLS-6 already settled that there is no `doc_type = "unknown"`: the only honest
;; record of "nobody could tell" is the absence of an assertion. LAY-4 clears an
;; attribute by merging an empty value, so the withdrawal is the same write as the
;; recording with nothing in it.
(define (decided-problem labels label)
  (define names (label-names labels))
  (cond
    [(not (string? label)) "the decided type must be a string"]
    [(string=? label "") #f]                      ; the withdrawal
    [(not (member label names))
     (format (string-append
              "'~a' is not one of the types this run offered (~a) — a type outside the set is one "
              "no trigger and no `?attr=` filter will ever match, so it is refused rather than "
              "corrected to the nearest name. Answer with a name exactly as it is spelled here.")
             label (string-join names ", "))]
    [else #f]))

;; The result a decision produces, in the shape every backend answers in — so
;; doc-tools.rkt writes it through the one recording path and cannot grow a second
;; one. CONFIDENCE 1.0: a person looked at the document and said what it is, which
;; is the strongest answer this platform can hold. The backend's own guess and its
;; confidence are not lost — they are the previous version of the classification
;; record, which is where CLS-11 put the history.
(define (classify-decided labels label #:verdict [verdict "revise"] #:rationale [rationale ""])
  (define p (decided-problem labels label))
  (when p (error 'doc_set_type "~a" p))
  (define why
    (let ([r (string-trim (if (string? rationale) rationale ""))])
      (cond [(string=? label "") (format "withdrawn on review (~a)~a" verdict
                                         (if (string=? r "") "" (format ": ~a" r)))]
            [(string=? r "") (format "decided on review (~a)" verdict)]
            [else (format "decided on review (~a): ~a" verdict r)])))
  (hasheq 'label label
          'confidence 1.0
          'source DECIDED-SOURCE
          'rationale (if (> (string-length why) MAX-RATIONALE)
                         (substring why 0 MAX-RATIONALE)
                         why)))

;; ---- CLS-29…33: the evaluation harness (issue #87 req 6) --------------------------------
;; "Given a labelled fixture set, report accuracy per label and per backend." The
;; SCORING lives here, with the rest of the classifier and pure of the repository,
;; so every arithmetic rule below is testable with a list of hashes and no
;; database, no model and no document. doc-tools.rkt owns the walk that produces
;; the rows.
;;
;; CLS-29: THE GROUND TRUTH IS AN OBJECT ATTRIBUTE, `doc_type_expected`, and the
;; fixture set is "every document under a prefix that carries one". The
;; alternative — a manifest of (object id, label) pairs passed to the call — makes
;; the fixture set a file somebody has to keep in step with the repository, where
;; an attribute makes it a thing the team curates in place, grows one document at
;; a time, and can list with `?attr=doc_type_expected:invoice` for free. It is the
;; same vocabulary the classifier's own answer lands in (CLS-7), one namespace
;; along.
(define EVAL-FIELD 'doc_type_expected)
(define EVAL-FIELDS
  (list (hasheq 'key "doc_type_expected" 'label "Expected document type (evaluation)")))

;; A FIXTURE'S OWN LABEL IS HELD TO THE LABEL SET, which is CLS-5 and CLS-15
;; pointed at the third party who can get it wrong. "Invoice", "invoces" or a
;; trailing space is one keystroke away, and a fixture labelled that way is a
;; document the classifier can never agree with — so an accuracy figure computed
;; over it blames the classifier for somebody's typing. Such a fixture is REPORTED
;; and EXCLUDED, never counted as a miss and never silently dropped.
(define (expected-problem labels label)
  (define names (label-names labels))
  (cond
    [(not (string? label)) "the expected type must be a string"]
    [(not (member label names))
     (format (string-append
              "'~a' is not one of the labels being evaluated (~a). A fixture labelled with a type "
              "outside the set is one no backend can ever agree with, so it is excluded from the "
              "counts rather than scored as a miss.")
             label (string-join names ", "))]
    [else #f]))

;; ---- one backend, one document ---------------------------------------------------------
;; CLS-30: A BACKEND THAT DECLINES IS `abstained`, NOT WRONG, and the whole report
;; turns on the distinction. The rules backend is DESIGNED to answer only when a
;; rule matched (CLS-1: it is first in the chain because it is certain when it
;; speaks), so scoring silence as an error would make a precise rule set look
;; worse the more careful it was, and would send an operator to loosen exactly the
;; rules that are carrying the load. Accuracy is therefore reported over what a
;; backend ANSWERED and `coverage` over the fixture set — two numbers, because
;; either alone is misleading: a backend that answers one document perfectly is
;; 100% accurate and useless.
;;
;; An `error` is a THIRD outcome and is not folded into abstention: a model that
;; refused twenty of twenty-five fixtures is the finding, and a report calling
;; that "abstained" would read as a cautious backend rather than a broken one.
;; THE FIELD IS `outcome`, NOT `status`, AND THE NAME WAS NOT FREE. A row of this
;; report ends up nested inside a workflow run's JSON, and the smoke reads a run's
;; state with `grep -oP '"status":"\K[^"]+' | head -1` — so a `status` here became
;; the FIRST one in the document and every run read as "answered". That is the trap
;; `ocr-smoke.sh` already records ("match the RUN's status, not a substring"), paid
;; from the other side: the field a nested structure chooses can break a reader of
;; the structure around it. `wait_run` parses JSON now as well, but the name is also
;; simply the better one — a classification has an outcome, not an HTTP status.
;; -> (values outcome tokens)
(define (classify-attempt backend labels
                          #:text [text ""] #:content-type [ct ""] #:key [key ""]
                          #:rules [rules '()] #:chat [chat #f])
  (define (answered r t) (values (hash-set r 'outcome "answered") t))
  (cond
    [(string=? backend "rules")
     (define r (classify-rules rules #:text text #:content-type ct #:key key))
     (if r
         (answered r 0)
         (values (hasheq 'outcome "abstained" 'reason "no rule matched") 0))]
    [else
     (cond
       [(not chat) (values (hasheq 'outcome "error" 'reason "the llm backend needs a model seam") 0)]
       ;; `classify-llm` refuses an empty document by name, which for an
       ;; evaluation is an abstention about THIS backend rather than a fault: a
       ;; photograph has no text and the model was never reachable for it. The
       ;; rules backend can still answer it on a content type, which is the
       ;; asymmetry CLS-9 built and the one this report exists to measure.
       [(string=? (string-trim text) "")
        (values (hasheq 'outcome "abstained" 'reason "the document has no text for the model to read") 0)]
       [else
        ;; the tokens a FAILED attempt spent are still spent, so they are carried
        ;; out of the handler rather than lost with the exception — an evaluation
        ;; that under-reported its own cost would be the one place this platform
        ;; measured the budget wrongly on purpose
        (define spent 0)
        (define (count! t) (set! spent (+ spent t)) t)
        (with-handlers ([exn:fail?
                         (lambda (e)
                           (values (hasheq 'outcome "error" 'reason (exn-message e)) spent))])
          (define-values (r t)
            (classify-llm labels text
                          #:chat (lambda (prompt #:system [sys #f])
                                   (define-values (reply tk) (chat prompt #:system sys))
                                   (values reply (count! tk)))))
          (answered r t))])]))

;; ---- the chain's own answer, derived ---------------------------------------------------
;; CLS-31: the chain is REPORTED AND COSTS NOTHING. What production runs is the
;; chain (CLS-1), so a report of the backends alone leaves the operator to compose
;; the answer in their head — and the composition is exactly "the first backend
;; that answered", which is already in hand. No second pass and no extra model
;; request: a `chain` row computed from the per-backend outcomes is the same answer
;; `classify` would have given, by construction rather than by a second
;; implementation of the rule.
(define (chain-outcome backends answers)
  (or (for/or ([b (in-list backends)])
        (define a (hash-ref answers (string->symbol b) #f))
        (and a (equal? (hash-ref a 'outcome) "answered") (hash-set a 'backend b)))
      ;; nothing answered: the chain would have raised (CLS-6). The reason names
      ;; the LAST backend's, which is the one an operator reads first.
      (let ([last-a (for/last ([b (in-list backends)]) (hash-ref answers (string->symbol b) #f))])
        (hasheq 'outcome (if (and last-a (equal? (hash-ref last-a 'outcome) "error")) "error" "abstained")
                'reason (if last-a (hash-ref last-a 'reason "") "no backend was asked")))))

;; ---- the tally ------------------------------------------------------------------------
;; A ratio over an EMPTY denominator is `null`, never 0. Zero reads as "it got
;; everything wrong" where the truth is "it was never asked", and the two have
;; opposite remedies — the same objection that keeps `interval_seconds` off a
;; daily schedule and a withdrawn `worker_state` off a stale executor.
(define (round3 x) (/ (round (* 1000.0 (exact->inexact x))) 1000))

;; `(* 1000.0 0)` is an EXACT 0 in Racket — multiplying an inexact by exact zero
;; gives exact zero — so a ratio of nothing-out-of-something came back as `0`
;; where every other figure in the same column is a decimal. Both are legal
;; jsexprs, which is why nothing failed; a report whose numbers change type with
;; their value is one a reader has to second-guess. `exact->inexact` first.
(define (ratio3 num den)
  (if (zero? den) 'null (round3 (/ num den))))

(define (mean-conf outcomes)
  (if (null? outcomes)
      'null
      (round3 (/ (for/sum ([o (in-list outcomes)]) (hash-ref o 'confidence 0)) (length outcomes)))))

;; One backend's figures over the rows, including the per-label breakdown.
;; EVERY LABEL IN THE SET GETS A ROW, including one with no fixture at all: a type
;; nobody wrote a fixture for is a hole in the fixture set, and an evaluation that
;; silently omitted it would report a clean sheet for a label it never tested.
(define (backend-report name labels rows)
  (define names (label-names labels))
  (define outs (for/list ([r (in-list rows)]) (hash-ref (hash-ref r 'answers) (string->symbol name) #f)))
  (define (outcome-is? o s) (and o (equal? (hash-ref o 'outcome) s)))
  (define (correct? r o) (and (outcome-is? o "answered") (equal? (hash-ref o 'label) (hash-ref r 'expected))))
  (define answered (for/list ([o (in-list outs)] #:when (outcome-is? o "answered")) o))
  (define correct (for/list ([r (in-list rows)] [o (in-list outs)] #:when (correct? r o)) o))
  (define wrong (for/list ([r (in-list rows)] [o (in-list outs)]
                           #:when (and (outcome-is? o "answered") (not (correct? r o))))
                  o))
  (hasheq 'backend name
          'fixtures (length rows)
          'answered (length answered)
          'correct (length correct)
          'wrong (length wrong)
          'abstained (for/sum ([o (in-list outs)]) (if (outcome-is? o "abstained") 1 0))
          'errors (for/sum ([o (in-list outs)]) (if (outcome-is? o "error") 1 0))
          ;; accuracy over what it answered, coverage over the fixture set — CLS-30
          'accuracy (ratio3 (length correct) (length answered))
          'coverage (ratio3 (length answered) (length rows))
          ;; CLS-32: the two means are what CALIBRATE the review hook's one knob.
          ;; `classify-review-extract` parks a run below `min_confidence` (CLS-13),
          ;; and a threshold is only worth setting when wrong answers arrive less
          ;; confidently than right ones. If both means sit at 0.9 the knob cannot
          ;; separate them, and that is a fact about the backend an accuracy figure
          ;; cannot express.
          'mean_confidence_correct (mean-conf correct)
          'mean_confidence_wrong (mean-conf wrong)
          'labels
          (for/list ([l (in-list names)])
            (define mine (for/list ([r (in-list rows)] [o (in-list outs)]
                                    #:when (equal? (hash-ref r 'expected) l))
                           (cons r o)))
            (define l-correct (for/list ([p (in-list mine)] #:when (correct? (car p) (cdr p))) p))
            (define l-wrong (for/list ([p (in-list mine)]
                                       #:when (and (outcome-is? (cdr p) "answered")
                                                   (not (correct? (car p) (cdr p)))))
                              p))
            (hasheq 'label l
                    'fixtures (length mine)
                    'correct (length l-correct)
                    'wrong (length l-wrong)
                    'abstained (for/sum ([p (in-list mine)]) (if (outcome-is? (cdr p) "abstained") 1 0))
                    'errors (for/sum ([p (in-list mine)]) (if (outcome-is? (cdr p) "error") 1 0))
                    'accuracy (ratio3 (length l-correct) (+ (length l-correct) (length l-wrong)))
                    ;; what it was mistaken FOR, which is the actionable half: a
                    ;; rule set that reads every invoice as a letter needs a
                    ;; different fix from one that reads them as photographs
                    'confused_with
                    (for/fold ([h (hasheq)]) ([p (in-list l-wrong)])
                      (define got (string->symbol (hash-ref (cdr p) 'label)))
                      (hash-set h got (add1 (hash-ref h got 0))))))))

;; -> the whole report. `backends` is the order asked for; the derived `chain` row
;; comes last, because it is a conclusion about the rows above it.
;;
;; A row's `answers` is keyed by the backend name AS A SYMBOL, because the report
;; is a tool result and therefore a jsexpr — `jsexpr->string` refuses a string key,
;; which is how the first version of this failed, three steps away in the engine.
(define (eval-report labels backends rows)
  (define rows*
    (for/list ([r (in-list rows)])
      (hash-set r 'answers (hash-set (hash-ref r 'answers) 'chain
                                     (chain-outcome backends (hash-ref r 'answers))))))
  (hasheq 'fixtures (length rows*)
          'labels (label-names labels)
          'backends (for/list ([b (in-list (append backends (list "chain")))])
                      (backend-report b labels rows*))
          'rows rows*))
