#lang racket/base

;; test/classify-tests.rkt — issue #87 slice 1: what KIND of document is this?
;;   raco test test/classify-tests.rkt
;;
;; Five layers, in the shape doc-pipeline-tests.rkt established:
;;   1. the rule matcher and the three validators as PURE functions — no db, no
;;      socket, no model, because that is the whole reason classify.rkt is pure
;;      of the repository
;;   2. the model backend's REFUSALS, with a scripted reply: CLS-5's promise is
;;      that a label outside the set never becomes a document type
;;   3. the tool, against a real database: the attributes, the declared fields,
;;      the derived record, a re-run, an unreadable document, and the billing
;;   4. the write ORDER — a refused attribute write leaves no record claiming it
;;      succeeded
;;   5. the acceptance criterion, through the real engine: a mixed inbox routed
;;      by type to a schema per type

(require rackunit db-kit/portable
         racket/port racket/string racket/file racket/list
         json
         db-kit/migrate
         "../domain/db/migrations.rkt"
         "db-fixture.rkt"
         "../domain/authz/authz.rkt"
         "../domain/quota/quota.rkt"
         "../domain/repo/blobs.rkt"
         "../domain/repo/repo.rkt"
         "../domain/repo/classify.rkt"
         "../domain/repo/doc-tools.rkt"        ; registers the tools
         "../domain/agent/registry.rkt"
         "../domain/agent/tools.rkt"              ; the rest of the catalog
         "../domain/sched/scheduler.rkt"
         "../domain/flow/run.rkt"
         (prefix-in pipeline: "../plugins/doc-pipeline/main.rkt"))

(define BLOB-ROOT (make-temporary-file "telemachus-classify-blobs-~a" 'directory))
(current-blob-root BLOB-ROOT)

(define (fresh)
  (define conn (fresh-db #:migrate? #f))
  (migrate! conn all-migrations)
  conn)

(define LABELS
  (list (hasheq 'name "invoice" 'description "a bill for goods or services"
                'examples '("total due" "invoice number"))
        (hasheq 'name "letter" 'description "correspondence addressed to a person")
        (hasheq 'name "photo" 'description "a photograph of a site or an asset")))

(define NAMES '("invoice" "letter" "photo"))

(define RULES
  (list (hasheq 'label "photo" 'content_type "image/")
        (hasheq 'label "invoice" 'all '("Invoice") 'any '("Total due" "Amount due") 'none '("DRAFT"))
        (hasheq 'label "letter" 'any '("Dear"))))

(define INVOICE-TEXT "INVOICE 4471\nAcme Corp\nWidgets 1000\nTotal due 1250.50")

;; ---- 1. the rule matcher ------------------------------------------------------------
(test-case "a rule matches on phrases, content type and key suffix — case-insensitively"
  ;; the phrases are spelled with different case from the text on purpose: a rule
  ;; is typed by a person and the document is somebody else's
  (define r (classify-rules RULES #:text INVOICE-TEXT #:content-type "text/plain" #:key "inbox/a.txt"))
  (check-equal? (hash-ref r 'label) "invoice")
  (check-equal? (hash-ref r 'source) "rules")
  ;; CLS-3: a deterministic rule has no degrees — the match IS the confidence
  (check-equal? (hash-ref r 'confidence) 1.0)
  (check-true (string-contains? (hash-ref r 'rationale) "rule 2 of 3"))

  ;; `none` vetoes
  (check-false (classify-rules RULES #:text (string-append INVOICE-TEXT "\nDRAFT — do not pay")
                               #:content-type "text/plain" #:key "a.txt"))
  ;; `all` is every phrase
  (check-false (classify-rules (list (hasheq 'label "invoice" 'all '("Invoice" "purchase order")))
                               #:text INVOICE-TEXT))
  ;; `any` is one of them
  (check-equal? (hash-ref (classify-rules RULES #:text "Dear Mr Smith,\n\nWe write to…") 'label) "letter")

  ;; a content type matches exactly, or by prefix when the rule's value ends in `/`
  (check-equal? (hash-ref (classify-rules RULES #:content-type "image/jpeg" #:text "") 'label) "photo")
  (check-false (classify-rules (list (hasheq 'label "photo" 'content_type "image/png"))
                               #:content-type "image/jpeg" #:text ""))
  (check-equal? (hash-ref (classify-rules (list (hasheq 'label "photo" 'content_type "image/PNG"))
                                          #:content-type "image/png" #:text "") 'label)
                "photo")
  ;; a key suffix
  (check-equal? (hash-ref (classify-rules (list (hasheq 'label "photo" 'key_suffix ".JPG"))
                                          #:key "site/front.jpg" #:text "") 'label)
                "photo")
  (check-false (classify-rules (list (hasheq 'label "photo" 'key_suffix ".jpg")) #:key "site/front.png"))

  ;; nothing matched is #f, not a guess
  (check-false (classify-rules RULES #:text "A quarterly report." #:content-type "text/plain" #:key "r.txt")))

(test-case "CLS-4: the FIRST matching rule decides, in list order"
  ;; both rules match this document; the earlier one is the answer, and a version
  ;; that scanned to the end or took the most specific match would answer "letter"
  (define rs (list (hasheq 'label "invoice" 'any '("Invoice"))
                   (hasheq 'label "letter" 'any '("Dear"))))
  (check-equal? (hash-ref (classify-rules rs #:text "Dear Sir\n\nInvoice attached.") 'label) "invoice")
  (check-equal? (hash-ref (classify-rules (reverse rs) #:text "Dear Sir\n\nInvoice attached.") 'label) "letter"))

;; ---- 2. the validators --------------------------------------------------------------
(test-case "a label set is validated, and a name is a slug"
  (check-false (labels-problem LABELS))
  (check-equal? (label-names LABELS) NAMES)
  (check-regexp-match #rx"must be an array" (labels-problem "invoice,letter"))
  (check-regexp-match #rx"at least one label" (labels-problem '()))
  ;; a name is a slug because it is BOTH an enum value the model must reproduce
  ;; and the stored attribute a trigger matches on by equality — "Invoice" and
  ;; "invoice" would be two document types nothing could reconcile
  (check-regexp-match #rx"lower-case" (labels-problem (list (hasheq 'name "Invoice"))))
  (check-regexp-match #rx"lower-case" (labels-problem (list (hasheq 'name "an invoice"))))
  (check-regexp-match #rx"lower-case" (labels-problem (list (hasheq 'name ""))))
  (check-regexp-match #rx"share a name"
                      (labels-problem (list (hasheq 'name "invoice") (hasheq 'name "invoice"))))
  ;; an unknown setting is refused rather than dropped: a setting that does
  ;; nothing is how an operator concludes the classification is broken
  (check-regexp-match #rx"unknown setting 'weight'"
                      (labels-problem (list (hasheq 'name "invoice" 'weight 2))))
  (check-regexp-match #rx"'examples' must be an array of strings"
                      (labels-problem (list (hasheq 'name "invoice" 'examples '(1 2))))))

(test-case "a rule is validated against the label set, and must carry a condition"
  (check-false (rules-problem RULES NAMES))
  (check-false (rules-problem '() NAMES))
  (check-regexp-match #rx"'receipt' is not one of the labels"
                      (rules-problem (list (hasheq 'label "receipt" 'any '("x"))) NAMES))
  (check-regexp-match #rx"unknown setting 'regex'"
                      (rules-problem (list (hasheq 'label "invoice" 'regex "^INV")) NAMES))
  ;; CLS-4: a rule with no condition matches every document and makes every rule
  ;; after it dead code while still reading as configuration
  (check-regexp-match #rx"no condition"
                      (rules-problem (list (hasheq 'label "invoice")) NAMES))
  (check-regexp-match #rx"an empty phrase"
                      (rules-problem (list (hasheq 'label "invoice" 'any '(""))) NAMES))
  (check-regexp-match #rx"longer than 200"
                      (rules-problem (list (hasheq 'label "invoice" 'all (list (make-string 201 #\x)))) NAMES))
  (check-regexp-match #rx"at most 20 phrases"
                      (rules-problem (list (hasheq 'label "invoice"
                                                   'any (for/list ([i 21]) (format "p~a" i)))) NAMES))
  (check-regexp-match #rx"at most 100 rules"
                      (rules-problem (for/list ([i 101]) (hasheq 'label "invoice" 'any '("x"))) NAMES)))

(test-case "the backend list is closed, and the embedding backend is named as unbuilt"
  (check-false (backends-problem '("rules" "llm")))
  (check-false (backends-problem '("llm")))
  (check-regexp-match #rx"at least one backend" (backends-problem '()))
  (check-regexp-match #rx"named twice" (backends-problem '("llm" "llm")))
  ;; requirement 2c asks for an embedding nearest-label backend; this build has no
  ;; embedding wire at all, so the refusal SAYS so rather than pretending the flag
  ;; is a typo
  (define p (backends-problem '("embeddings")))
  (check-regexp-match #rx"unknown backend 'embeddings'" p)
  (check-regexp-match #rx"no embedding wire" p))

;; ---- 3. the model backend's refusals ------------------------------------------------
(define (replying . replies)
  (define left (box replies))
  (lambda (prompt #:system [sys #f])
    (define r (unbox left))
    (set-box! left (if (null? (cdr r)) r (cdr r)))
    (values (car r) 11)))

(test-case "CLS-5: the reply is held to the label set, and a refusal is retried once"
  (define (with . replies)
    (classify-llm LABELS INVOICE-TEXT #:chat (apply replying replies)))

  (let-values ([(r t) (with (jsexpr->string (hasheq 'label "invoice" 'confidence 0.91 'rationale "a total due")))])
    (check-equal? (hash-ref r 'label) "invoice")
    (check-equal? (hash-ref r 'confidence) 0.91)
    (check-equal? (hash-ref r 'source) "llm")
    (check-equal? t 11))
  ;; a fence or a sentence around the object still parses — `outer-json`, shared
  ;; with the chat response-format check
  (let-values ([(r _t) (with "Sure:\n```json\n{\"label\":\"letter\",\"confidence\":0.4}\n```")])
    (check-equal? (hash-ref r 'label) "letter")
    (check-equal? (hash-ref r 'rationale) ""))
  ;; a label outside the set is REFUSED — never coerced to the nearest one, and
  ;; never quietly stored as "unknown"
  (check-exn #rx"classification refused: .*not one of the allowed values"
             (lambda () (with (jsexpr->string (hasheq 'label "receipt" 'confidence 0.9)))))
  (check-exn #rx"classification refused: .*expected number, got string"
             (lambda () (with (jsexpr->string (hasheq 'label "invoice" 'confidence "high")))))
  (check-exn #rx"classification refused: .*more than the maximum 1"
             (lambda () (with (jsexpr->string (hasheq 'label "invoice" 'confidence 4)))))
  (check-exn #rx"classification refused: .*missing required field 'confidence'"
             (lambda () (with (jsexpr->string (hasheq 'label "invoice")))))
  ;; the schema is CLOSED, so an invented key is refused the way an extraction's is
  (check-exn #rx"classification refused: .*unexpected field 'labels'"
             (lambda () (with (jsexpr->string (hasheq 'label "invoice" 'confidence 0.5 'labels '("a"))))))
  (check-exn #rx"classification refused: .*did not return a JSON object"
             (lambda () (with "I think it is an invoice.")))

  ;; the retry: a bad first reply and a good second one succeeds, and bills both
  (let-values ([(r t) (with "no idea" (jsexpr->string (hasheq 'label "invoice" 'confidence 0.7)))])
    (check-equal? (hash-ref r 'label) "invoice")
    (check-equal? t 22 "a retried classification bills both calls"))

  ;; and with no text the model is not asked at all
  (check-exn #rx"nothing to classify"
             (lambda () (classify-llm LABELS "   " #:chat (lambda (p #:system [s #f]) (values "{}" 1))))))

(test-case "the chain: rules first, and nothing answering is a refusal"
  ;; a rules answer never reaches the model — asserted by giving it NO model seam
  (let-values ([(r t) (classify LABELS #:text INVOICE-TEXT #:content-type "text/plain"
                                #:key "a.txt" #:rules RULES #:backends '("rules"))])
    (check-equal? (hash-ref r 'label) "invoice")
    (check-equal? t 0 "a rules answer spends no tokens"))
  ;; the order is the caller's: asked for the model only, the matching rule is
  ;; never consulted
  (let-values ([(r _t) (classify LABELS #:text INVOICE-TEXT #:rules RULES #:backends '("llm")
                                 #:chat (replying (jsexpr->string (hasheq 'label "letter" 'confidence 0.3))))])
    (check-equal? (hash-ref r 'label) "letter"))
  ;; CLS-6: no backend answered, so there is no type. It is a refusal naming what
  ;; was asked — never a stored `doc_type` of "unknown", which a trigger would
  ;; then act on as though somebody had asserted it
  (check-exn #rx"no backend could classify inbox/r.txt \\(tried rules\\)"
             (lambda () (classify LABELS #:text "A quarterly report." #:key "inbox/r.txt"
                                  #:rules RULES #:backends '("rules")))))

(test-case "CLS-8: the stored confidence is two decimals, fixed"
  ;; `?attr=` is an equality filter, so a value whose spelling follows the model's
  ;; precision could not be filtered on at all
  (check-equal? (confidence->string 1.0) "1.00")
  (check-equal? (confidence->string 0.9) "0.90")
  (check-equal? (confidence->string 0.916666) "0.92")
  (check-equal? (confidence->string 0) "0.00"))

;; ---- 4. the tool, against a real database -------------------------------------------
(define (call! conn p args)
  ((tool-handler (tool-by-name "doc_classify")) conn p args))

(test-case "the tool writes the type onto the document, declares the fields, and keeps a record"
  (define conn (fresh))
  (define-values (uid tid) (bootstrap! conn #:username "alice"))
  (define alice (user-principal conn uid tid))
  (define (up! key bytes ct) (repo-put! conn alice #:key key #:port (open-input-bytes bytes)
                                        #:content-type ct #:filename key #:visibility "team"))
  (define inv (up! "inbox/acme.txt" (string->bytes/utf-8 INVOICE-TEXT) "text/plain"))

  ;; the team defines no object fields yet, which is the normal case — LAY-4 would
  ;; refuse the attribute write, so the tool declares them first
  (check-equal? (repo-fields conn tid) '())
  (define out (call! conn alice (hasheq 'object (hash-ref inv 'id) 'labels LABELS
                                        'rules RULES 'backends '("rules"))))
  (check-equal? (hash-ref out 'label) "invoice")
  (check-equal? (hash-ref out 'source) "rules")
  (check-equal? (hash-ref out 'tokens_used) 0)

  (define keys (for/list ([f (in-list (repo-fields conn tid))]) (hash-ref f 'key)))
  (check-equal? (sort keys string<?) '("doc_type" "doc_type_confidence" "doc_type_source"))

  (define o (repo-get conn alice (hash-ref inv 'id)))
  (define attrs (hash-ref o 'attributes))
  (check-equal? (hash-ref attrs 'doc_type) "invoice")
  (check-equal? (hash-ref attrs 'doc_type_confidence) "1.00")
  (check-equal? (hash-ref attrs 'doc_type_source) "rules")
  ;; LAY-4's own filter now finds the document by its type — which is the point of
  ;; writing the answer there rather than only into a record
  (check-equal? (map (lambda (x) (hash-ref x 'id))
                     (repo-list conn alice #:attrs '(("doc_type" . "invoice"))))
                (list (hash-ref inv 'id)))

  ;; CLS-11: the record beside the source says WHICH label set, WHICH backend and
  ;; WHICH version, none of which the three attributes can carry
  (define rec-obj (repo-get conn alice "inbox/acme.txt.classification.json" #:by-key tid))
  (check-true (and rec-obj #t) "the classification record is beside the source")
  (define-values (_ro rin) (repo-open conn alice (hash-ref rec-obj 'id)))
  (define rec (string->jsexpr (port->string rin)))
  (close-input-port rin)
  (check-equal? (hash-ref rec 'label) "invoice")
  (check-equal? (hash-ref rec 'labels) NAMES)
  (check-equal? (hash-ref rec 'backends) '("rules"))
  (check-equal? (hash-ref rec 'version_id) (hash-ref inv 'version_id))
  (check-false (hash-ref rec 'truncated))
  (check-equal? (hash-ref rec 'text_chars) (string-length INVOICE-TEXT))

  ;; a re-classification VERSIONS the same key rather than littering
  (define out2 (parameterize ([current-doc-chat
                               (replying (jsexpr->string (hasheq 'label "letter" 'confidence 0.55
                                                                 'rationale "reads as a letter")))])
                 (call! conn alice (hasheq 'object (hash-ref inv 'id) 'labels LABELS
                                           'backends '("llm")))))
  (check-equal? (hash-ref out2 'source) "llm")
  (check-equal? (hash-ref out2 'tokens_used) 11)
  (define rec2 (repo-get conn alice "inbox/acme.txt.classification.json" #:by-key tid))
  (check-equal? (hash-ref rec2 'id) (hash-ref rec-obj 'id) "the same object")
  (check-equal? (hash-ref rec2 'version) 2 "a second version of it")
  ;; the attributes followed the new decision
  (define attrs2 (hash-ref (repo-get conn alice (hash-ref inv 'id)) 'attributes))
  (check-equal? (hash-ref attrs2 'doc_type) "letter")
  (check-equal? (hash-ref attrs2 'doc_type_confidence) "0.55")
  ;; the model call was billed at both tiers — and the RULES call was not, which
  ;; is what the request count proves: a classification no model answered must
  ;; not appear in the ledger as a model request
  (check-equal? (quota-used conn "team" tid "ai.tokens.total" "total") 11)
  (check-equal? (quota-used conn "team" tid "ai.requests" "total") 1)

  ;; CLS-9: a document this platform cannot read is still classifiable, because a
  ;; content-type rule is exactly what the photograph and the scan need
  (define scan (up! "inbox/scan.bin" #"\x00\x01\x02not text" "application/octet-stream"))
  (define sout (call! conn alice
                      (hasheq 'object (hash-ref scan 'id) 'labels LABELS
                              'rules (list (hasheq 'label "photo" 'content_type "application/octet-stream"))
                              'backends '("rules"))))
  (check-equal? (hash-ref sout 'label) "photo")
  ;; …and with only the model to ask, the same document is a named refusal rather
  ;; than a model call on an empty string
  (check-exn #rx"nothing to classify"
             (lambda () (call! conn alice (hasheq 'object (hash-ref scan 'id) 'labels LABELS
                                                  'backends '("llm")))))

  ;; the validators are reached through the tool too, as a 400 and not a 500
  (check-exn #rx"not one of the labels"
             (lambda () (call! conn alice (hasheq 'object (hash-ref inv 'id) 'labels LABELS
                                                  'rules (list (hasheq 'label "receipt" 'any '("x")))))))
  (check-exn #rx"no such document"
             (lambda () (call! conn alice (hasheq 'object "nope" 'labels LABELS 'backends '("rules")
                                                  'rules RULES)))))

(test-case "CLS-10: the model sees the opening, and the record says how much"
  (define conn (fresh))
  (define-values (uid tid) (bootstrap! conn #:username "alice"))
  (define alice (user-principal conn uid tid))
  (define long (string-append "Dear Sir" (make-string (* 3 CLASSIFY-CAP) #\x)))
  (define o (repo-put! conn alice #:key "inbox/long.txt" #:port (open-input-bytes (string->bytes/utf-8 long))
                       #:content-type "text/plain" #:filename "long.txt" #:visibility "team"))
  (define seen (box 0))
  (define out
    (parameterize ([current-doc-chat
                    (lambda (prompt #:system [sys #f])
                      (set-box! seen (string-length prompt))
                      (values (jsexpr->string (hasheq 'label "letter" 'confidence 0.8)) 3))])
      (call! conn alice (hasheq 'object (hash-ref o 'id) 'labels LABELS 'backends '("llm")))))
  (check-equal? (hash-ref out 'label) "letter")
  (check-true (< (unbox seen) (* 2 CLASSIFY-CAP)) "the whole document was not sent")
  (define rec (repo-get conn alice "inbox/long.txt.classification.json" #:by-key tid))
  (define-values (_r rin) (repo-open conn alice (hash-ref rec 'id)))
  (define r (string->jsexpr (port->string rin)))
  (close-input-port rin)
  (check-equal? (hash-ref r 'text_chars) CLASSIFY-CAP)
  (check-true (hash-ref r 'truncated) "and the record says the text was cut"))

(test-case "the attributes go first: a write nobody may make leaves no record claiming it did"
  ;; A viewer of a shared document may READ it and may not assert what it is.
  ;; Written the other way round, the record beside the source would say the type
  ;; had been decided while nothing had recorded it — which is what "Processed by"
  ;; would then render.
  (define conn (fresh))
  (define-values (uid tid) (bootstrap! conn #:username "alice"))
  (define alice (user-principal conn uid tid))
  (define bob-id (create-user! conn #:username "bob" #:password "pw"))
  (add-member! conn #:user bob-id #:team tid #:role "member")
  (define bob (user-principal conn bob-id tid))
  (define inv (repo-put! conn alice #:key "inbox/private.txt"
                         #:port (open-input-bytes (string->bytes/utf-8 INVOICE-TEXT))
                         #:content-type "text/plain" #:filename "private.txt" #:visibility "private"))
  (repo-share! conn alice (hash-ref inv 'id) #:user bob-id)   ; view, so files:read only
  (check-exn #rx"forbidden: files:write"
             (lambda () (call! conn bob (hasheq 'object (hash-ref inv 'id) 'labels LABELS
                                                'rules RULES 'backends '("rules")))))
  (check-false (repo-get conn alice "inbox/private.txt.classification.json" #:by-key tid)
               "no record was written for a decision that was refused")
  ;; and the owner's own run still works, which is what makes the refusal about
  ;; the person rather than about the document
  (check-equal? (hash-ref (call! conn alice (hasheq 'object (hash-ref inv 'id) 'labels LABELS
                                                    'rules RULES 'backends '("rules")))
                          'label)
                "invoice"))

;; ---- 5. the acceptance criterion: the whole thing through the real engine -----------
(test-case "doc_classify -> the schema for THAT type -> doc_text -> doc_extract_fields"
  (define conn (fresh))
  (define-values (uid tid) (bootstrap! conn #:username "alice"))
  (define alice (user-principal conn uid tid))
  (register-plugin-workflow! "doc-pipeline" (cadr pipeline:workflows))
  (define def (flow-def-by-slug conn alice "classify-and-extract"))
  (check-true (and def #t) "the plugin workflow materialized")

  (define (up! key text ct)
    (repo-put! conn alice #:key key #:port (open-input-bytes (string->bytes/utf-8 text))
               #:content-type ct #:filename key #:visibility "team"))
  (define inv    (up! "mixed/a.txt" INVOICE-TEXT "text/plain"))
  (define letter (up! "mixed/b.txt" "Dear Ms Smith,\n\nYour tenancy begins on 2026-11-01.\n\nYours,\nAcme" "text/plain"))
  (define photo  (up! "mixed/c.jpg" "not really a jpeg" "image/jpeg"))

  (define SCHEMAS
    (hasheq 'invoice (hasheq 'type "object" 'required '("total")
                             'properties (hasheq 'total (hasheq 'type "number")))
            'letter  (hasheq 'type "object" 'required '("addressee")
                             'properties (hasheq 'addressee (hasheq 'type "string")))))

  ;; the model answers the EXTRACTION prompts only — every classification here is
  ;; a rule, which is the point of trying them first
  (define (model fields)
    (lambda (prompt #:system [sys #f])
      (cond [(and sys (string-contains? sys "extract structured data")) (values fields 9)]
            [else (error 'test "the model was asked to classify, and a rule should have")])))

  (define (run! obj fields)
    (define r (parameterize ([current-doc-chat (model fields)])
                (define run (flow-run-start! conn alice def
                                             #:input (hasheq 'object_id (hash-ref obj 'id)
                                                             'labels LABELS 'rules RULES
                                                             'schemas SCHEMAS)))
                (let loop ([n 0]) (when (and (< n 60) (process-one! conn)) (loop (add1 n))))
                (flow-run-get conn alice (hash-ref run 'id))))
    (check-equal? (hash-ref r 'status) "done" (format "the run finished (error: ~a)" (hash-ref r 'error)))
    r)

  (define (type-of obj) (hash-ref (hash-ref (repo-get conn alice (hash-ref obj 'id)) 'attributes) 'doc_type #f))
  (define (steps-of r) (map (lambda (s) (hash-ref s 'step_id)) (hash-ref r 'steps)))

  (define r1 (run! inv (jsexpr->string (hasheq 'total 1250.5))))
  (check-equal? (type-of inv) "invoice")
  (check-true (and (member "invoice_fields" (steps-of r1)) #t) "routed to the invoice schema")
  (check-false (member "letter_fields" (steps-of r1)))
  (check-true (and (repo-get conn alice "mixed/a.txt.extracted.json" #:by-key tid) #t))

  (define r2 (run! letter (jsexpr->string (hasheq 'addressee "Ms Smith"))))
  (check-equal? (type-of letter) "letter")
  (check-true (and (member "letter_fields" (steps-of r2)) #t) "routed to the letter schema")
  (check-false (member "invoice_fields" (steps-of r2)))

  ;; a photograph is classified and left alone — it has no fields, and the run
  ;; ENDS rather than extracting against a schema that is not there
  (define r3 (run! photo "{}"))
  (check-equal? (type-of photo) "photo")
  (check-false (member "invoice_fields" (steps-of r3)))
  (check-false (member "letter_fields" (steps-of r3)))
  (check-false (repo-get conn alice "mixed/c.jpg.extracted.json" #:by-key tid)
               "nothing was extracted from the photograph")
  ;; …but its type is on the document, so LAY-4's filter finds all three kinds
  (for ([want '("invoice" "letter" "photo")])
    (check-equal? (length (repo-list conn alice #:prefix "mixed/"
                                     #:attrs (list (cons "doc_type" want))))
                  1 (format "exactly one ~a" want))))
