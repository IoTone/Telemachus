#lang racket/base

;; test/classify-review-tests.rkt — issue #87 slice 2: the review hook (req 4).
;;   raco test test/classify-review-tests.rkt
;;
;; The issue's SECOND acceptance criterion: "Low-confidence items appear in the
;; review queue and resume after a decision." Four layers, in the shape slice 1's
;; file established:
;;
;;   1. the decided-type rules as PURE functions — a person's label is held to the
;;      same label set as the model's (CLS-15), and an empty one withdraws (CLS-16)
;;   2. `doc_set_type` against a real database: the attributes, the record, the
;;      withdrawal, and who may make the assertion
;;   3. the gate — a CONFIDENT document must not park, which is the control that
;;      stops the whole hook from being "every run waits for a person"
;;   4. all three verdicts through the real engine, end to end: parked, decided,
;;      resumed, and routed to the schema for the type that was finally decided
;;
;; Every case here fails against a version without the slice, and the ones that
;; could pass vacuously say so at the assertion.

(require rackunit db-kit/portable
         racket/port racket/string racket/file racket/list
         json
         db-kit/migrate
         "../domain/db/migrations.rkt"
         "db-fixture.rkt"
         "../domain/authz/authz.rkt"
         "../domain/repo/blobs.rkt"
         "../domain/repo/repo.rkt"
         "../domain/repo/classify.rkt"
         "../domain/repo/doc-tools.rkt"        ; registers the tools
         "../domain/agent/registry.rkt"
         "../domain/agent/tools.rkt"
         "../domain/review/review.rkt"
         "../domain/sched/scheduler.rkt"
         "../domain/flow/run.rkt"
         (prefix-in pipeline: "../plugins/doc-pipeline/main.rkt"))

(define BLOB-ROOT (make-temporary-file "telemachus-clsreview-blobs-~a" 'directory))
(current-blob-root BLOB-ROOT)

(define (fresh)
  (define conn (fresh-db #:migrate? #f))
  (migrate! conn all-migrations)
  conn)

(define LABELS
  (list (hasheq 'name "invoice" 'description "a bill for goods or services")
        (hasheq 'name "letter" 'description "correspondence addressed to a person")
        (hasheq 'name "photo" 'description "a photograph of a site or an asset")))

(define NAMES '("invoice" "letter" "photo"))

(define LETTER-TEXT "Dear Ms Smith,\n\nYour tenancy begins on 2026-11-01.\n\nYours,\nAcme")

;; ---- 1. the decided-type rules, pure ------------------------------------------------
(test-case "CLS-15: a person's label is held to the same label set as the model's"
  (check-false (decided-problem LABELS "invoice"))
  (check-false (decided-problem LABELS ""))        ; the withdrawal

  ;; the three keystrokes a reviewer actually makes, each of which would otherwise
  ;; become a document type no trigger and no `?attr=` filter could ever match
  (for ([typo '("Invoice" "invoices" "receipt")])
    (define p (decided-problem LABELS typo))
    (check-true (string? p) (format "'~a' is refused" typo))
    ;; the message NAMES the set, because the reviewer is one keystroke from right
    (check-true (string-contains? p "invoice, letter, photo")
                "the refusal lists the types that were offered")
    ;; and it says it will not guess — coercing "Invoice" to "invoice" would
    ;; quietly assert something nobody chose
    (check-true (string-contains? p "rather than")))

  (check-regexp-match #rx"must be a string" (decided-problem LABELS 42)))

(test-case "CLS-16: a decision is confidence 1.0, source review, and carries why"
  (define r (classify-decided LABELS "letter" #:verdict "revise" #:rationale "a tenancy letter"))
  (check-equal? (hash-ref r 'label) "letter")
  ;; a person looked at the document; that is the strongest answer this platform
  ;; can hold, and it is what makes the queue drainable — a run whose confidence
  ;; stayed 0.42 would be offered for review again on the next pass
  (check-equal? (hash-ref r 'confidence) 1.0)
  (check-equal? (hash-ref r 'source) DECIDED-SOURCE)
  (check-equal? (hash-ref r 'source) "review")
  (check-true (string-contains? (hash-ref r 'rationale) "revise"))
  (check-true (string-contains? (hash-ref r 'rationale) "a tenancy letter"))

  ;; a withdrawal says so, with or without a rationale
  (check-true (string-contains? (hash-ref (classify-decided LABELS "" #:verdict "reject") 'rationale)
                                "withdrawn"))
  ;; no rationale is not an error — one is only required for revise and reject at
  ;; the REVIEW (LAY-1), and this tool may legitimately be called by hand
  (check-true (string-contains? (hash-ref (classify-decided LABELS "invoice") 'rationale) "review"))

  ;; a long rationale is cut rather than refused: it is provenance, not an
  ;; assertion, and losing the decision over its prose would be the worse failure
  (check-equal? (string-length (hash-ref (classify-decided LABELS "invoice"
                                                           #:rationale (make-string 2000 #\x))
                                         'rationale))
                MAX-RATIONALE)

  ;; the tool refuses rather than records, through the same validator
  (check-exn #rx"not one of the types" (lambda () (classify-decided LABELS "Invoice"))))

;; ---- 2. doc_set_type against a real database ----------------------------------------
(define (classify! conn p args) ((tool-handler (tool-by-name "doc_classify")) conn p args))
(define (set-type! conn p args) ((tool-handler (tool-by-name "doc_set_type")) conn p args))

(define (attrs-of conn p id) (hash-ref (repo-get conn p id) 'attributes))

(define (record-of conn p tid key)
  (define o (repo-get conn p key #:by-key tid))
  (and o
       (let-values ([(_o in) (repo-open conn p (hash-ref o 'id))])
         (define j (string->jsexpr (port->string in)))
         (close-input-port in)
         j)))

(test-case "doc_set_type records the type a person decided, over the backend's guess"
  (define conn (fresh))
  (define-values (uid tid) (bootstrap! conn #:username "alice"))
  (define alice (user-principal conn uid tid))
  (define doc (repo-put! conn alice #:key "inbox/b.txt"
                         #:port (open-input-bytes (string->bytes/utf-8 LETTER-TEXT))
                         #:content-type "text/plain" #:filename "b.txt" #:visibility "team"))

  ;; the model gets it wrong, and is not sure: exactly the case req 4 is about
  (parameterize ([current-doc-chat
                  (lambda (prompt #:system [sys #f])
                    (values (jsexpr->string (hasheq 'label "invoice" 'confidence 0.31
                                                    'rationale "a guess")) 7))])
    (classify! conn alice (hasheq 'object (hash-ref doc 'id) 'labels LABELS 'backends '("llm"))))
  (check-equal? (hash-ref (attrs-of conn alice (hash-ref doc 'id)) 'doc_type) "invoice")

  (define out (set-type! conn alice (hasheq 'object (hash-ref doc 'id) 'labels LABELS
                                            'label "letter" 'verdict "revise"
                                            'rationale "it is a tenancy letter"
                                            'review "rev-1")))
  (check-equal? (hash-ref out 'label) "letter")
  (check-equal? (hash-ref out 'source) "review")
  (check-false (hash-ref out 'withdrawn))

  (define a (attrs-of conn alice (hash-ref doc 'id)))
  (check-equal? (hash-ref a 'doc_type) "letter")
  (check-equal? (hash-ref a 'doc_type_confidence) "1.00")
  (check-equal? (hash-ref a 'doc_type_source) "review")
  ;; LAY-4's filter follows the correction, which is the whole point of writing
  ;; the decision to the attributes rather than only into a record
  (check-equal? (map (lambda (x) (hash-ref x 'id))
                     (repo-list conn alice #:attrs '(("doc_type" . "letter"))))
                (list (hash-ref doc 'id)))
  (check-equal? (repo-list conn alice #:attrs '(("doc_type" . "invoice"))) '())

  ;; CLS-11's rule: the SAME record key is versioned, so the backend's original
  ;; guess is still there to read — this is where the history lives, and a second
  ;; mechanism for it would be the thing to avoid
  (define rec-obj (repo-get conn alice "inbox/b.txt.classification.json" #:by-key tid))
  (check-equal? (hash-ref rec-obj 'version) 2 "the record was versioned, not duplicated")
  (define rec (record-of conn alice tid "inbox/b.txt.classification.json"))
  (check-equal? (hash-ref rec 'label) "letter")
  (check-equal? (hash-ref rec 'source) "review")
  (check-equal? (hash-ref rec 'verdict) "revise")
  (check-equal? (hash-ref rec 'review_id) "rev-1")
  (check-equal? (hash-ref rec 'decided_by) uid)
  (check-equal? (hash-ref rec 'labels) NAMES)
  (check-true (string-contains? (hash-ref rec 'rationale) "tenancy letter"))
  ;; version 1 of the same object still says what the model answered
  (define v1 (findf (lambda (v) (equal? (hash-ref v 'version) 1))
                    (repo-versions conn alice (hash-ref rec-obj 'id))))
  (check-true (and v1 #t) "the model's own guess is still the first version"))

(test-case "CLS-16: an empty label WITHDRAWS the type rather than storing \"unknown\""
  (define conn (fresh))
  (define-values (uid tid) (bootstrap! conn #:username "alice"))
  (define alice (user-principal conn uid tid))
  (define doc (repo-put! conn alice #:key "inbox/x.txt"
                         #:port (open-input-bytes #"a meeting agenda")
                         #:content-type "text/plain" #:filename "x.txt" #:visibility "team"))
  (set-type! conn alice (hasheq 'object (hash-ref doc 'id) 'labels LABELS 'label "letter"))
  (check-equal? (hash-ref (attrs-of conn alice (hash-ref doc 'id)) 'doc_type) "letter")

  (define out (set-type! conn alice (hasheq 'object (hash-ref doc 'id) 'labels LABELS
                                            'label "" 'verdict "reject"
                                            'rationale "none of these kinds")))
  (check-true (hash-ref out 'withdrawn))
  ;; all three keys are GONE — a trigger acts on an assertion, and "nobody could
  ;; tell" is not one (CLS-6). A stored "unknown" would be matched by a rule
  ;; somebody wrote for a real type.
  (define a (attrs-of conn alice (hash-ref doc 'id)))
  (check-false (hash-ref a 'doc_type #f))
  (check-false (hash-ref a 'doc_type_confidence #f))
  (check-false (hash-ref a 'doc_type_source #f))
  (check-equal? (repo-list conn alice #:attrs '(("doc_type" . "letter"))) '()
                "and the filter no longer finds it under the withdrawn type")

  ;; the RECORD is still written: who withdrew it, and why, is exactly what a
  ;; later reader needs, and the attributes cannot carry it
  (define rec (record-of conn alice tid "inbox/x.txt.classification.json"))
  (check-true (hash-ref rec 'withdrawn))
  (check-equal? (hash-ref rec 'label) "")
  (check-equal? (hash-ref rec 'verdict) "reject")
  (check-true (string-contains? (hash-ref rec 'rationale) "withdrawn")))

(test-case "the attributes go first here too: a refused write leaves no record"
  ;; the same rule slice 1 pinned for `doc_classify`, asserted for the second
  ;; asker — because the write order now lives in ONE function and a regression
  ;; there would silently affect both
  (define conn (fresh))
  (define-values (uid tid) (bootstrap! conn #:username "alice"))
  (define alice (user-principal conn uid tid))
  (define bob-id (create-user! conn #:username "bob" #:password "pw"))
  (add-member! conn #:user bob-id #:team tid #:role "member")
  (define bob (user-principal conn bob-id tid))
  (define doc (repo-put! conn alice #:key "inbox/p.txt"
                         #:port (open-input-bytes (string->bytes/utf-8 LETTER-TEXT))
                         #:content-type "text/plain" #:filename "p.txt" #:visibility "private"))
  (repo-share! conn alice (hash-ref doc 'id) #:user bob-id)      ; view: files:read only
  (check-exn #rx"forbidden: files:write"
             (lambda () (set-type! conn bob (hasheq 'object (hash-ref doc 'id)
                                                    'labels LABELS 'label "letter"))))
  (check-false (repo-get conn alice "inbox/p.txt.classification.json" #:by-key tid)
               "no record claims a type was decided")
  ;; a bad label never reaches the document at all
  (check-exn #rx"not one of the types"
             (lambda () (set-type! conn alice (hasheq 'object (hash-ref doc 'id)
                                                      'labels LABELS 'label "Letter"))))
  (check-false (hash-ref (attrs-of conn alice (hash-ref doc 'id)) 'doc_type #f))
  (check-exn #rx"no such document"
             (lambda () (set-type! conn alice (hasheq 'object "nope" 'labels LABELS 'label "letter")))))

;; ---- 3+4. the whole hook, through the real engine ------------------------------------
(define SCHEMAS
  (hasheq 'invoice (hasheq 'type "object" 'required '("total")
                           'properties (hasheq 'total (hasheq 'type "number")))
          'letter  (hasheq 'type "object" 'required '("addressee")
                           'properties (hasheq 'addressee (hasheq 'type "string")))))

;; one model double for every case: it classifies with the confidence the case
;; asks for and answers the extraction prompts, so a run that reaches extraction
;; really does extract rather than being short-circuited by the fixture
(define (model label confidence fields)
  (lambda (prompt #:system [sys #f])
    (cond
      [(and sys (string-contains? sys "extract structured data")) (values fields 9)]
      [(and sys (string-contains? sys "You classify a document"))
       (values (jsexpr->string (hasheq 'label label 'confidence confidence
                                       'rationale "the model's own reading")) 7)]
      [else (error 'test "an unexpected prompt: ~a" sys)])))

(define (drain! conn) (let loop ([n 0]) (when (and (< n 80) (process-one! conn)) (loop (add1 n)))))

(struct fix (conn uid tid alice def) #:transparent)

(define (setup!)
  (define conn (fresh))
  (define-values (uid tid) (bootstrap! conn #:username "alice"))
  (define alice (user-principal conn uid tid))
  ;; the third workflow in the plugin's list — named rather than indexed blindly,
  ;; because adding one to that list must not silently point this test elsewhere
  (define spec (findf (lambda (w) (equal? (hash-ref w 'slug) "classify-review-extract"))
                      pipeline:workflows))
  (check-true (and spec #t) "the plugin provides classify-review-extract")
  (register-plugin-workflow! "doc-pipeline" spec)
  (define def (flow-def-by-slug conn alice "classify-review-extract"))
  (check-true (and def #t) "and it materialized for the team")
  (fix conn uid tid alice def))

(define (upload! f key text ct)
  (repo-put! (fix-conn f) (fix-alice f) #:key key
             #:port (open-input-bytes (string->bytes/utf-8 text))
             #:content-type ct #:filename key #:visibility "team"))

(define (start! f obj #:min [min-conf 0.6] #:chat chat)
  (parameterize ([current-doc-chat chat])
    (define run (flow-run-start! (fix-conn f) (fix-alice f) (fix-def f)
                                 #:input (hasheq 'object_id (hash-ref obj 'id)
                                                 'labels LABELS 'rules '()
                                                 'schemas SCHEMAS
                                                 'min_confidence min-conf)))
    (drain! (fix-conn f))
    (flow-run-get (fix-conn f) (fix-alice f) (hash-ref run 'id))))

(define (decide! f rid verdict #:answers [answers (hasheq)] #:rationale [rationale ""] #:chat chat)
  (parameterize ([current-doc-chat chat])
    (define out (review-decide! (fix-conn f) (fix-alice f) rid verdict
                                #:rationale rationale #:answers answers))
    (check-true (hash? out) (format "the decision was accepted (got ~a)" out))
    (drain! (fix-conn f))
    out))

(define (steps-of r) (map (lambda (s) (hash-ref s 'step_id)) (hash-ref r 'steps)))
(define (type-of f obj) (hash-ref (attrs-of (fix-conn f) (fix-alice f) (hash-ref obj 'id)) 'doc_type #f))
(define (reload f run-id) (flow-run-get (fix-conn f) (fix-alice f) run-id))

(test-case "the gate: a CONFIDENT classification is not sent for review"
  ;; the control for the whole slice. Without it, "low-confidence items appear in
  ;; the review queue" would be satisfied by a hook that queued EVERY document,
  ;; which is the one outcome that would make the pipeline useless.
  (define f (setup!))
  (define doc (upload! f "rev/confident.txt" LETTER-TEXT "text/plain"))
  (define r (start! f doc #:chat (model "letter" 0.97 (jsexpr->string (hasheq 'addressee "Ms Smith")))))
  (check-equal? (hash-ref r 'status) "done" (format "error: ~a" (hash-ref r 'error)))
  (check-false (member "confirm" (steps-of r)) "no review step ran")
  (check-equal? (review-count-pending (fix-conn f) (fix-alice f)) 0 "nothing is waiting for a person")
  (check-equal? (type-of f doc) "letter")
  (check-equal? (hash-ref (attrs-of (fix-conn f) (fix-alice f) (hash-ref doc 'id)) 'doc_type_source)
                "llm" "and the source still names the backend that decided it")
  (check-true (and (member "letter_fields" (steps-of r)) #t) "it went straight to the letter schema"))

(test-case "req 4, REVISE: a low-confidence run parks, and the correction routes the extraction"
  (define f (setup!))
  (define conn (fix-conn f))
  (define doc (upload! f "rev/b.txt" LETTER-TEXT "text/plain"))

  ;; the model is unsure AND wrong — the case that makes the hook worth having
  (define chat (model "invoice" 0.42 (jsexpr->string (hasheq 'addressee "Ms Smith"))))
  (define r (start! f doc #:chat chat))
  (define rid (hash-ref r 'id))

  ;; parked: LAY-1's whole mechanism — the run is `waiting`, nothing is queued,
  ;; and no concurrency slot is held for however long the specialist takes
  (check-equal? (hash-ref r 'status) "waiting")
  (check-equal? (for/list ([j (in-list (list-jobs conn (fix-tid f)))]
                           #:when (member (hash-ref j 'status) '("queued" "running")))
                  (hash-ref j 'kind))
                '()
                "a parked run holds no job: LAY-1 parks instead of polling")

  ;; …and it is in the queue a person reads
  (define pending (review-list conn (fix-alice f) #:status "pending"))
  (check-equal? (length pending) 1)
  (define rev (car pending))
  (check-equal? (hash-ref rev 'run_id) rid)
  (check-equal? (hash-ref rev 'step_id) "confirm")
  (check-true (string-contains? (hash-ref rev 'title) "kind of document"))
  ;; the subject is what the classifier said, so the reviewer can see the guess
  ;; and its confidence rather than being asked to start from the document
  (check-equal? (hash-ref (hash-ref rev 'subject) 'label) "invoice")
  (check-equal? (hash-ref (hash-ref rev 'subject) 'confidence) 0.42)
  ;; LAY-3: the subject is model-produced, so it has no author and anyone holding
  ;; `reviews:decide` may decide it — a four-eyes review would be undecidable on a
  ;; team of one, which is the configuration this test runs in
  (check-false (hash-ref rev 'four_eyes))
  (check-equal? (hash-ref rev 'author_user_id) 'null)
  ;; the model's wrong guess IS on the document meanwhile, which is why the
  ;; decision has to be able to correct it rather than merely close the review
  (check-equal? (type-of f doc) "invoice")

  ;; the person decides
  (decide! f (hash-ref rev 'id) "revise"
           #:answers (hasheq 'doc_type "letter")
           #:rationale "a tenancy letter, not a bill"
           #:chat chat)

  (define r2 (reload f rid))
  (check-equal? (hash-ref r2 'status) "done" (format "the run resumed and finished (error: ~a)"
                                                     (hash-ref r2 'error)))
  (check-equal? (review-count-pending conn (fix-alice f)) 0)

  ;; the metadata followed the decision (req 4's "the decision updates the metadata")
  (define a (attrs-of conn (fix-alice f) (hash-ref doc 'id)))
  (check-equal? (hash-ref a 'doc_type) "letter")
  (check-equal? (hash-ref a 'doc_type_source) "review")
  (check-equal? (hash-ref a 'doc_type_confidence) "1.00")

  ;; …and the run resumed down the CORRECTED type's branch. This is the assertion
  ;; the second routing chain exists for: reading the label from `classify` would
  ;; have extracted against the invoice schema and refused on a letter.
  (define ss (steps-of r2))
  (check-true (and (member "correct" ss) #t))
  (check-true (and (member "letter_fields" ss) #t) "extracted against the LETTER schema")
  (check-false (member "invoice_fields" ss))
  (check-false (member "accept" ss))
  (check-true (and (repo-get conn (fix-alice f) "rev/b.txt.extracted.json" #:by-key (fix-tid f)) #t))

  ;; the document's record names the decision, which is what ties an assertion
  ;; about a document to the reviews chain (LAY-11) with no second mechanism
  (define rec (record-of conn (fix-alice f) (fix-tid f) "rev/b.txt.classification.json"))
  (check-equal? (hash-ref rec 'review_id) (hash-ref rev 'id))
  (check-equal? (hash-ref rec 'verdict) "revise")
  (check-equal? (hash-ref rec 'decided_by) (fix-uid f)))

(test-case "req 4, APPROVE: the answer stands, and a person is recorded as having confirmed it"
  (define f (setup!))
  (define conn (fix-conn f))
  (define doc (upload! f "rev/a.txt" "INVOICE 4471\nTotal due 1250.50" "text/plain"))
  (define chat (model "invoice" 0.5 (jsexpr->string (hasheq 'total 1250.5))))
  (define r (start! f doc #:chat chat))
  (check-equal? (hash-ref r 'status) "waiting")
  (define rev (car (review-list conn (fix-alice f) #:status "pending")))

  ;; no rationale, and no checklist answer: approving a right answer must not
  ;; demand prose (LAY-1's rule) and the correction field is optional for exactly
  ;; this branch
  (decide! f (hash-ref rev 'id) "approve" #:chat chat)

  (define r2 (reload f (hash-ref r 'id)))
  (check-equal? (hash-ref r2 'status) "done" (format "error: ~a" (hash-ref r2 'error)))
  (define a (attrs-of conn (fix-alice f) (hash-ref doc 'id)))
  (check-equal? (hash-ref a 'doc_type) "invoice" "the label did not change")
  ;; …but HOW it was decided did. Leaving `llm` and 0.50 would mean an approved
  ;; document was indistinguishable from one nobody had looked at, and a backfill
  ;; (req 5) or a trigger could not tell them apart.
  (check-equal? (hash-ref a 'doc_type_source) "review")
  (check-equal? (hash-ref a 'doc_type_confidence) "1.00")
  (define ss (steps-of r2))
  (check-true (and (member "accept" ss) #t))
  (check-false (member "correct" ss))
  (check-true (and (member "invoice_fields" ss) #t) "and it routed on the approved type"))

(test-case "req 4, REJECT: the type is withdrawn and the run ends"
  (define f (setup!))
  (define conn (fix-conn f))
  (define doc (upload! f "rev/c.txt" "Minutes of the site meeting, 14 October." "text/plain"))
  (define chat (model "letter" 0.2 "{}"))
  (define r (start! f doc #:chat chat))
  (check-equal? (hash-ref r 'status) "waiting")
  (check-equal? (type-of f doc) "letter" "the model's guess is on the document while it waits")
  (define rev (car (review-list conn (fix-alice f) #:status "pending")))

  (decide! f (hash-ref rev 'id) "reject" #:rationale "it is none of these kinds" #:chat chat)

  (define r2 (reload f (hash-ref r 'id)))
  (check-equal? (hash-ref r2 'status) "done" (format "error: ~a" (hash-ref r2 'error)))
  ;; the wrong assertion is GONE rather than left standing, which is the half a
  ;; hook that only closed the review would have missed
  (check-false (type-of f doc))
  (define ss (steps-of r2))
  (check-true (and (member "withdraw" ss) #t))
  (check-false (member "letter_fields" ss) "and nothing was extracted")
  (check-false (member "invoice_fields" ss))
  (check-false (repo-get conn (fix-alice f) "rev/c.txt.extracted.json" #:by-key (fix-tid f)))
  ;; the record is still there, saying who withdrew it and why
  (define rec (record-of conn (fix-alice f) (fix-tid f) "rev/c.txt.classification.json"))
  (check-true (hash-ref rec 'withdrawn))
  (check-true (string-contains? (hash-ref rec 'rationale) "none of these kinds")))

(test-case "a reviewer's typo is refused by the STEP, and the run says so"
  ;; the end of CLS-15: answers are free strings, so the only place a mis-spelled
  ;; type can be caught is the tool that records it. The run must FAIL rather than
  ;; store a type nothing matches — and the review stays decided, because the
  ;; decision was made; it is the recording that could not be done.
  (define f (setup!))
  (define conn (fix-conn f))
  (define doc (upload! f "rev/d.txt" LETTER-TEXT "text/plain"))
  (define chat (model "invoice" 0.42 "{}"))
  (define r (start! f doc #:chat chat))
  (define rev (car (review-list conn (fix-alice f) #:status "pending")))
  (decide! f (hash-ref rev 'id) "revise" #:answers (hasheq 'doc_type "Letter")
           #:rationale "a letter" #:chat chat)
  (define r2 (reload f (hash-ref r 'id)))
  (check-equal? (hash-ref r2 'status) "error")
  (check-true (string-contains? (hash-ref r2 'error) "not one of the types")
              "the failure names what was wrong with the answer")
  (check-true (string-contains? (hash-ref r2 'error) "invoice, letter, photo")
              "and what the reviewer should have said")
  (check-equal? (hash-ref (review-get conn (fix-alice f) (hash-ref rev 'id)) 'status) "decided"))
