#lang racket/base

;; test/classify-eval-tests.rkt — issue #87 requirement 6: "given a labelled
;; fixture set, report accuracy per label and per backend" (decisions CLS-29…33).
;;   raco test test/classify-eval-tests.rkt
;;
;; Three layers, as the backfill's suite has:
;;   1. the SCORING, pure — the arithmetic that makes the report mean what it says,
;;      with no database, no model and no document anywhere near it
;;   2. the walk, against a real database: what counts as a fixture, what is
;;      excluded, what `can?` hides, and the one thing this tool must never do
;;   3. the requirement, through the real engine: two backends measured against
;;      each other over a mixed fixture set

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
         "../domain/repo/doc-tools.rkt"        ; registers the tools, exports EVAL-BATCH
         "../domain/agent/registry.rkt"
         "../domain/agent/tools.rkt"
         "../domain/quota/quota.rkt"           ; quota-used, for the metering case
         "../domain/sched/scheduler.rkt"
         "../domain/flow/run.rkt"
         (prefix-in pipeline: "../plugins/doc-pipeline/main.rkt"))

(define BLOB-ROOT (make-temporary-file "telemachus-eval-blobs-~a" 'directory))
(current-blob-root BLOB-ROOT)

(define (fresh)
  (define conn (fresh-db #:migrate? #f))
  (migrate! conn all-migrations)
  conn)

;; LAY-4 refuses an undefined attribute key, so a case that labels a fixture by
;; hand declares the field first — exactly as the tool does on its own first run.
;; Without it `repo-set-attributes!` answers a STRING rather than raising and the
;; case passes for the wrong reason, which is the trap req 5's suite paid for.
(define (fresh/declared)
  (define conn (fresh))
  (define-values (uid tid) (bootstrap! conn #:username "alice"))
  (check-false (string? (repo-fields-declare! conn tid EVAL-FIELDS)))
  (values conn tid (user-principal conn uid tid)))

(define LABELS
  (list (hasheq 'name "invoice" 'description "a bill for goods or services")
        (hasheq 'name "letter" 'description "correspondence addressed to a person")
        (hasheq 'name "photo" 'description "a photograph of a site or an asset")))

;; a rule set with a DELIBERATE hole: nothing describes a letter, so the rules
;; backend abstains on every one of them. That is the shape the report has to be
;; able to express — a precise backend with poor coverage — and scoring those
;; abstentions as errors is the mistake CLS-30 is about.
(define RULES
  (list (hasheq 'label "photo" 'content_type "image/")
        (hasheq 'label "invoice" 'any '("Invoice" "Total due"))))

(define INVOICE-TEXT "INVOICE 4471\nAcme Corp\nTotal due 1250.50")
(define LETTER-TEXT "Dear Ms Smith,\n\nYour tenancy begins on 2026-11-01.\n\nAcme")

(define (up! conn p key text ct [vis "team"])
  (repo-put! conn p #:key key #:port (open-input-bytes (string->bytes/utf-8 text))
             #:content-type ct #:filename key #:visibility vis))

;; label a fixture — the ground truth, which is an ordinary attribute write
(define (expect! conn p o label)
  (define r (repo-set-attributes! conn p (hash-ref o 'id) (hasheq 'doc_type_expected label)))
  (check-true (hash? r) (format "labelling ~a as ~a: ~a" (hash-ref o 'key) label r))
  o)

(define (eval! conn p #:prefix [prefix ""] #:backends [backends '("rules")]
               #:labels [labels LABELS] #:rules [rules RULES])
  ((tool-handler (tool-by-name "doc_classify_eval")) conn p
   (hasheq 'prefix prefix 'labels labels 'rules rules 'backends backends)))

;; the report's own accessors, so a case reads as the question it is asking
(define (backend-row r name)
  (findf (lambda (b) (equal? (hash-ref b 'backend) name)) (hash-ref r 'backends)))
(define (label-row b name)
  (findf (lambda (l) (equal? (hash-ref l 'label) name)) (hash-ref b 'labels)))

;; a model that answers with a fixed label, and counts how often it was asked
(define (scripted label #:confidence [c 0.8] #:tokens [tk 11])
  (define calls (box 0))
  (values (lambda (prompt #:system [sys #f])
            (set-box! calls (add1 (unbox calls)))
            (values (jsexpr->string (hasheq 'label label 'confidence c 'rationale "scripted"))
                    tk))
          calls))

;; ---- 1. the scoring, pure ---------------------------------------------------------
;; `answers` is keyed by SYMBOLS: the report is a tool result, so it has to be a
;; jsexpr, and `jsexpr->string` refuses a string key.
(define (row expected answers) (hasheq 'object_id "o" 'key "k" 'expected expected 'answers answers))
(define (answered label [c 0.9]) (hasheq 'outcome "answered" 'label label 'confidence c 'source "x" 'rationale ""))
(define (abstained) (hasheq 'outcome "abstained" 'reason "no rule matched"))
(define (errored) (hasheq 'outcome "error" 'reason "boom"))

(test-case "CLS-30: accuracy is over what a backend ANSWERED, coverage over the set"
  ;; three invoices: one right, one wrong, one it declined to judge. A backend
  ;; that abstains is not wrong — so accuracy is 1 of 2, not 1 of 3 — and the
  ;; thing that stops 50% from reading as "good enough" is the coverage beside it.
  (define r (eval-report LABELS '("rules")
                         (list (row "invoice" (hasheq 'rules (answered "invoice")))
                               (row "invoice" (hasheq 'rules (answered "letter")))
                               (row "invoice" (hasheq 'rules (abstained))))))
  (define b (backend-row r "rules"))
  (check-equal? (hash-ref b 'fixtures) 3)
  (check-equal? (hash-ref b 'answered) 2)
  (check-equal? (hash-ref b 'correct) 1)
  (check-equal? (hash-ref b 'wrong) 1)
  (check-equal? (hash-ref b 'abstained) 1)
  (check-equal? (hash-ref b 'errors) 0)
  (check-equal? (hash-ref b 'accuracy) 0.5 "1 correct of 2 answered")
  (check-equal? (hash-ref b 'coverage) (/ (round (* 1000.0 2/3)) 1000) "2 answered of 3 fixtures")
  ;; and an error is its OWN outcome: a model refusing twenty of twenty-five
  ;; fixtures is the finding, where "abstained" would read as a cautious backend
  (define r2 (eval-report LABELS '("llm") (list (row "invoice" (hasheq 'llm (errored))))))
  (define b2 (backend-row r2 "llm"))
  (check-equal? (hash-ref b2 'errors) 1)
  (check-equal? (hash-ref b2 'abstained) 0)
  (check-equal? (hash-ref b2 'answered) 0))

(test-case "a ratio with nothing in the denominator is null, never 0"
  ;; 0 reads as "it got everything wrong" where the truth is "it was never
  ;; asked", and the two have opposite remedies.
  (define r (eval-report LABELS '("rules") (list (row "invoice" (hasheq 'rules (abstained))))))
  (define b (backend-row r "rules"))
  (check-equal? (hash-ref b 'accuracy) 'null "it answered nothing, so it has no accuracy")
  (check-equal? (hash-ref b 'coverage) 0.0 "but its coverage really is zero")
  (check-equal? (hash-ref b 'mean_confidence_correct) 'null)
  (check-equal? (hash-ref b 'mean_confidence_wrong) 'null)
  ;; and with no fixtures at all, coverage has no denominator either
  (check-equal? (hash-ref (backend-row (eval-report LABELS '("rules") '()) "rules") 'coverage) 'null))

(test-case "per label: the breakdown, the confusion, and the label nobody tested"
  (define r (eval-report LABELS '("rules")
                         (list (row "invoice" (hasheq 'rules (answered "invoice")))
                               (row "letter"  (hasheq 'rules (answered "invoice")))
                               (row "letter"  (hasheq 'rules (answered "invoice")))
                               (row "letter"  (hasheq 'rules (abstained))))))
  (define b (backend-row r "rules"))
  (check-equal? (hash-ref (label-row b "invoice") 'correct) 1)
  (check-equal? (hash-ref (label-row b "invoice") 'accuracy) 1.0)
  (define lt (label-row b "letter"))
  (check-equal? (hash-ref lt 'fixtures) 3)
  (check-equal? (hash-ref lt 'wrong) 2)
  (check-equal? (hash-ref lt 'abstained) 1)
  (check-equal? (hash-ref lt 'accuracy) 0.0 "it answered twice about a letter and was wrong twice")
  (check-equal? (hash-ref lt 'confused_with) (hasheq 'invoice 2)
                "what it was mistaken FOR is the actionable half")
  ;; EVERY label in the set gets a row. A type nobody wrote a fixture for is a
  ;; hole in the fixture set, and omitting it would report a clean sheet for a
  ;; label that was never tested.
  (define ph (label-row b "photo"))
  (check-true (and ph #t) "the untested label is still reported")
  (check-equal? (hash-ref ph 'fixtures) 0)
  (check-equal? (hash-ref ph 'accuracy) 'null))

(test-case "CLS-31: the chain's answer is DERIVED, and costs no second pass"
  ;; what production runs is the chain, so the report says what it would have
  ;; answered — composed from the per-backend outcomes rather than measured again.
  (define r (eval-report LABELS '("rules" "llm")
                         (list ;; rules answered: the chain stops there, right or not
                               (row "invoice" (hasheq 'rules (answered "invoice")
                                                      'llm (answered "letter")))
                               ;; rules abstained: the chain is the model's answer
                               (row "letter" (hasheq 'rules (abstained)
                                                     'llm (answered "letter")))
                               ;; neither: the chain would have refused (CLS-6)
                               (row "photo" (hasheq 'rules (abstained)
                                                    'llm (errored)))))
  )
  (define ch (backend-row r "chain"))
  (check-equal? (hash-ref ch 'correct) 2)
  (check-equal? (hash-ref ch 'wrong) 0)
  (check-equal? (hash-ref ch 'errors) 1 "nothing answered the photograph")
  (check-equal? (hash-ref ch 'coverage) (/ (round (* 1000.0 2/3)) 1000))
  ;; AND THE CHAIN BEAT BOTH OF ITS PARTS, which is the figure an operator could
  ;; not have worked out from either column: rules answered one of three and was
  ;; right, the model answered two and was right about one — it would have called
  ;; the invoice a letter — and because rules go first, the chain got both.
  (check-equal? (hash-ref (backend-row r "rules") 'correct) 1)
  (check-equal? (hash-ref (backend-row r "rules") 'abstained) 2)
  (check-equal? (hash-ref (backend-row r "llm") 'correct) 1)
  (check-equal? (hash-ref (backend-row r "llm") 'wrong) 1)
  ;; the chain comes LAST, because it is a conclusion about the rows above it
  (check-equal? (hash-ref (last (hash-ref r 'backends)) 'backend) "chain"))

(test-case "CLS-32: the two confidence means, which are what calibrate a review threshold"
  ;; `classify-review-extract` parks a run below `min_confidence`, and that knob
  ;; is only worth setting when wrong answers arrive less confidently than right
  ;; ones. Here they do not — both means are 0.9 — and that is a fact about the
  ;; backend no accuracy figure can express.
  (define r (eval-report LABELS '("llm")
                         (list (row "invoice" (hasheq 'llm (answered "invoice" 0.9)))
                               (row "letter"  (hasheq 'llm (answered "invoice" 0.9)))
                               (row "letter"  (hasheq 'llm (answered "invoice" 0.5))))))
  (define b (backend-row r "llm"))
  (check-equal? (hash-ref b 'mean_confidence_correct) 0.9)
  (check-equal? (hash-ref b 'mean_confidence_wrong) 0.7 "0.9 and 0.5"))

(test-case "CLS-29: a fixture labelled outside the set is refused by name"
  (check-false (expected-problem LABELS "invoice"))
  (define p (expected-problem LABELS "Invoice"))
  (check-true (string? p) "a capitalised label is not the label")
  (check-true (string-contains? p "invoice, letter, photo") "the refusal lists the set")
  (check-true (string? (expected-problem LABELS "")) "and empty is not a withdrawal here")
  ;; `decided-problem` DOES accept the empty string, because for a reviewer it is
  ;; the withdrawal (CLS-16). A fixture has no such meaning, and sharing the
  ;; function would have made an unlabelled document into a fixture expecting
  ;; nothing.
  (check-false (decided-problem LABELS "")))

;; ---- 2. the walk ------------------------------------------------------------------
(test-case "CLS-29: the fixture set is the documents carrying an expected type"
  (define conn (fresh))
  (define-values (uid tid) (bootstrap! conn #:username "alice"))
  (define alice (user-principal conn uid tid))
  ;; the field is declared BY THE TOOL, additively — so the very first thing this
  ;; case does is prove an operator can label a fixture after one run and not
  ;; before, which is why the declaration is there at all
  (check-false (hash-has-key? (for/hash ([f (in-list (repo-fields conn tid))])
                                (values (hash-ref f 'key) #t))
                              "doc_type_expected"))
  (check-equal? (hash-ref (eval! conn alice) 'fixtures) 0 "nothing is labelled yet")
  (check-true (for/or ([f (in-list (repo-fields conn tid))])
                (equal? (hash-ref f 'key) "doc_type_expected"))
              "the run declared the field, so fixtures can now be labelled")

  (define inv (expect! conn alice (up! conn alice "fix/a.txt" INVOICE-TEXT "text/plain") "invoice"))
  (define let1 (expect! conn alice (up! conn alice "fix/b.txt" LETTER-TEXT "text/plain") "letter"))
  (define plain (up! conn alice "fix/c.txt" INVOICE-TEXT "text/plain"))        ; not a fixture
  (define out (expect! conn alice (up! conn alice "other/d.txt" INVOICE-TEXT "text/plain") "invoice"))

  (define r (eval! conn alice #:prefix "fix/"))
  (check-equal? (hash-ref r 'fixtures) 2 "an unlabelled document is not a fixture")
  (check-equal? (hash-ref r 'objects) 3 "the prefix bounds the window")
  (check-false (hash-ref r 'truncated))
  (check-equal? (sort (for/list ([w (in-list (hash-ref r 'rows))]) (hash-ref w 'key)) string<?)
                (list "fix/a.txt" "fix/b.txt"))
  (check-equal? (hash-ref (eval! conn alice) 'fixtures) 3 "an empty prefix is the whole team")
  ;; the rule set describes invoices and photographs and NOT letters, which is the
  ;; hole this fixture set exists to find
  (define b (backend-row r "rules"))
  (check-equal? (hash-ref b 'correct) 1)
  (check-equal? (hash-ref b 'abstained) 1)
  (check-equal? (hash-ref b 'accuracy) 1.0 "it was right about everything it answered")
  (check-equal? (hash-ref b 'coverage) 0.5 "…and it answered half the set"))

(test-case "CLS-33: an evaluation WRITES NOTHING"
  ;; The decision the whole tool turns on. It would otherwise overwrite the type
  ;; on a document a run had already classified — measuring by destroying what was
  ;; measured — fire a metadata trigger (CLS-23) on every fixture, and score its
  ;; own output on the second run.
  (define-values (conn tid alice) (fresh/declared))
  ;; THE TEAM ALREADY CLASSIFIES DOCUMENTS, and the case is worthless without
  ;; that. LAY-4 refuses an undefined attribute key and `repo-set-attributes!`
  ;; answers a STRING rather than raising, so on a team with no `doc_type` field a
  ;; version of this tool that DID write the type would have its write silently
  ;; refused and this case would pass — which is exactly what the positive control
  ;; found. Declaring the classifier's own fields makes it the team where such a
  ;; write would land. Req 5's suite paid for the same shape from the other side.
  (check-false (string? (repo-fields-declare! conn tid CLASSIFY-FIELDS)))
  (define inv (expect! conn alice (up! conn alice "fix/a.txt" INVOICE-TEXT "text/plain") "invoice"))
  (define objects-before (repo-count conn alice))
  (define versions-before (length (repo-versions conn alice (hash-ref inv 'id))))

  (define r (eval! conn alice #:prefix "fix/"))
  (check-equal? (hash-ref (backend-row r "rules") 'correct) 1 "it did measure something")

  (define attrs (hash-ref (repo-get conn alice (hash-ref inv 'id)) 'attributes))
  (check-false (hash-has-key? attrs 'doc_type) "no type was recorded")
  (check-false (hash-has-key? attrs 'doc_type_source))
  (check-equal? (hash-ref attrs 'doc_type_expected) "invoice" "the ground truth is untouched")
  (check-equal? (repo-count conn alice) objects-before
                "no classification record, and no report document either")
  (check-equal? (length (repo-versions conn alice (hash-ref inv 'id))) versions-before)
  (check-equal? (query-value conn "SELECT COUNT(*) FROM repo_derivations") 0)
  ;; which is also why the tool is `files:read`
  (check-equal? (tool-perm (tool-by-name "doc_classify_eval")) "files:read"))

(test-case "CLS-29: a fixture the label set cannot contain is EXCLUDED, not scored"
  ;; Counting it as a miss would blame the classifier for somebody's typing.
  (define-values (conn tid alice) (fresh/declared))
  (expect! conn alice (up! conn alice "fix/a.txt" INVOICE-TEXT "text/plain") "invoice")
  ;; declared by the first run above, so this write lands — and it is a type no
  ;; backend can ever agree with
  (expect! conn alice (up! conn alice "fix/b.txt" INVOICE-TEXT "text/plain") "Invoice")

  (define r (eval! conn alice #:prefix "fix/"))
  (check-equal? (hash-ref r 'fixtures) 1 "only the well-labelled one was scored")
  (check-equal? (length (hash-ref r 'excluded)) 1)
  (define x (car (hash-ref r 'excluded)))
  (check-equal? (hash-ref x 'key) "fix/b.txt")
  (check-equal? (hash-ref x 'expected) "Invoice")
  (check-true (string-contains? (hash-ref x 'problem) "excluded from the counts"))
  (check-equal? (hash-ref (backend-row r "rules") 'accuracy) 1.0
                "the typo did not cost the rule set a point"))

(test-case "the fixtures a caller may not read are not in their evaluation"
  (define-values (conn tid alice) (fresh/declared))
  (define bob-id (create-user! conn #:username "bob" #:password "pw"))
  (add-member! conn #:user bob-id #:team tid #:role "member")
  (define bob (user-principal conn bob-id tid))
  (expect! conn alice (up! conn alice "fix/a.txt" INVOICE-TEXT "text/plain" "private") "invoice")
  (expect! conn alice (up! conn alice "fix/b.txt" INVOICE-TEXT "text/plain") "invoice")
  (define r (eval! conn bob #:prefix "fix/"))
  (check-equal? (hash-ref r 'fixtures) 1 "the private fixture is not his to measure against")
  (check-equal? (hash-ref r 'objects) 2 "while the window is the same window"))

(test-case "the batch cap, and the surplus is reported"
  (define-values (conn tid alice) (fresh/declared))
  (for ([i (in-range (+ EVAL-BATCH 4))])
    (expect! conn alice
             (up! conn alice (format "fix/~a.txt" (+ 100 i)) INVOICE-TEXT "text/plain")
             "invoice"))
  (define r (eval! conn alice #:prefix "fix/"))
  (check-equal? (hash-ref r 'fixtures) EVAL-BATCH)
  (check-equal? (hash-ref r 'objects) (+ EVAL-BATCH 4))
  (check-true (hash-ref r 'truncated)
              "an evaluation over a batch of a fixture set says so — the figure is about the batch"))

(test-case "CLS-30: a model that raises is an error; a document with no text is an abstention"
  ;; The asymmetry CLS-9 built, now measured: a photograph has no text, so the
  ;; model was never reachable for it, while a content-type rule answers it
  ;; without reading a byte. That difference is what the report exists to show.
  (define-values (conn tid alice) (fresh/declared))
  (expect! conn alice (up! conn alice "fix/c.jpg" "not really a jpeg" "image/jpeg") "photo")
  (expect! conn alice (up! conn alice "fix/a.txt" INVOICE-TEXT "text/plain") "invoice")

  (define r (parameterize ([current-doc-chat
                            (lambda (prompt #:system [sys #f]) (error 'test "the model is down"))])
              (eval! conn alice #:prefix "fix/" #:backends '("rules" "llm"))))
  (define rules (backend-row r "rules"))
  (check-equal? (hash-ref rules 'correct) 2 "rules answered both, including the photograph")
  (define llm (backend-row r "llm"))
  (check-equal? (hash-ref llm 'abstained) 1 "there was nothing for it to read in the photograph")
  (check-equal? (hash-ref llm 'errors) 1 "and it was asked about the invoice and failed")
  (check-equal? (hash-ref llm 'answered) 0)
  ;; the chain is still right about both, because rules answered first
  (check-equal? (hash-ref (backend-row r "chain") 'correct) 2))

(test-case "the tokens an evaluation spends are metered; a rules-only one spends none"
  (define-values (conn tid alice) (fresh/declared))
  (expect! conn alice (up! conn alice "fix/b.txt" LETTER-TEXT "text/plain") "letter")

  (check-equal? (hash-ref (eval! conn alice #:prefix "fix/") 'tokens_used) 0)
  (check-equal? (quota-used conn "team" tid "ai.tokens.total" "total") 0)

  (define-values (chat calls) (scripted "letter" #:tokens 11))
  (define r (parameterize ([current-doc-chat chat])
              (eval! conn alice #:prefix "fix/" #:backends '("llm"))))
  (check-equal? (unbox calls) 1 "one fixture, one request")
  (check-equal? (hash-ref r 'tokens_used) 11)
  (check-equal? (quota-used conn "team" tid "ai.tokens.total" "total") 11)
  (check-equal? (hash-ref (backend-row r "llm") 'correct) 1))

(test-case "the text is read ONCE and shared by every backend"
  ;; Two backends compared on two different readings of the same document is the
  ;; one thing a comparison must not do — and the extraction is the expensive part.
  (define-values (conn tid alice) (fresh/declared))
  (expect! conn alice (up! conn alice "fix/a.txt" INVOICE-TEXT "text/plain") "invoice")
  (define-values (chat calls) (scripted "invoice"))
  (define r (parameterize ([current-doc-chat chat])
              (eval! conn alice #:prefix "fix/" #:backends '("rules" "llm"))))
  (define w (car (hash-ref r 'rows)))
  (check-equal? (hash-ref w 'text_chars) (string-length INVOICE-TEXT)
                "the row says what was read, once, for both backends")
  (check-equal? (hash-ref (backend-row r "rules") 'correct) 1)
  (check-equal? (hash-ref (backend-row r "llm") 'correct) 1))

;; ---- 3. the requirement, through the real engine ----------------------------------
(test-case "requirement 6: two backends measured against each other over a fixture set"
  (define-values (conn tid alice) (fresh/declared))
  (register-plugin-workflow!
   "doc-pipeline"
   (findf (lambda (w) (equal? (hash-ref w 'slug) "classify-eval")) pipeline:workflows))
  (define def (flow-def-by-slug conn alice "classify-eval"))
  (check-true (and def #t) "the plugin workflow materialized")

  (check-false (string? (repo-fields-declare! conn tid EVAL-FIELDS)))
  (expect! conn alice (up! conn alice "fix/a.txt" INVOICE-TEXT "text/plain") "invoice")
  (expect! conn alice (up! conn alice "fix/b.txt" LETTER-TEXT "text/plain") "letter")
  (expect! conn alice (up! conn alice "fix/c.jpg" "not really a jpeg" "image/jpeg") "photo")
  (expect! conn alice (up! conn alice "elsewhere/d.txt" INVOICE-TEXT "text/plain") "invoice")

  (define (measure! backends)
    (define run (flow-run-start! conn alice def
                                 #:input (hasheq 'prefix "fix/" 'labels LABELS
                                                 'rules RULES 'backends backends)))
    (let loop ([n 0]) (when (and (< n 20) (process-one! conn)) (loop (add1 n))))
    (define r (flow-run-get conn alice (hash-ref run 'id)))
    (check-equal? (hash-ref r 'status) "done"
                  (format "the evaluation finished (error: ~a)" (hash-ref r 'error)))
    (define step (findf (lambda (s) (equal? (hash-ref s 'step_id) "measure")) (hash-ref r 'steps)))
    (hash-ref (hash-ref step 'output) 'result))

  ;; the rules set alone: right about what it knows, blind to letters
  (define r1 (parameterize ([current-doc-chat
                             (lambda (prompt #:system [sys #f])
                               (error 'test "the model was asked in a rules-only evaluation"))])
               (measure! '("rules"))))
  (check-equal? (hash-ref r1 'fixtures) 3 "the prefix bounded the fixture set")
  (define b1 (backend-row r1 "rules"))
  (check-equal? (hash-ref b1 'accuracy) 1.0)
  (check-equal? (hash-ref b1 'coverage) (/ (round (* 1000.0 2/3)) 1000))
  (check-equal? (hash-ref (label-row b1 "letter") 'abstained) 1
                "and the report names the label no rule describes")

  ;; the model alone, scripted to answer "invoice" for everything it can read:
  ;; right about the invoice, wrong about the letter, and unreachable for the photo
  (define-values (chat calls) (scripted "invoice"))
  (define r2 (parameterize ([current-doc-chat chat]) (measure! '("llm"))))
  (define b2 (backend-row r2 "llm"))
  (check-equal? (unbox calls) 2 "it was asked about the two documents that have text")
  (check-equal? (hash-ref b2 'correct) 1)
  (check-equal? (hash-ref b2 'wrong) 1)
  (check-equal? (hash-ref b2 'abstained) 1)
  (check-equal? (hash-ref b2 'accuracy) 0.5)
  (check-equal? (hash-ref (label-row b2 "letter") 'confused_with) (hasheq 'invoice 1))

  ;; and nothing either run touched was written — the whole fixture set is still
  ;; exactly a fixture set
  (for ([k '("fix/a.txt" "fix/b.txt" "fix/c.jpg")])
    (define o (repo-get conn alice k #:by-key tid))
    (check-false (hash-has-key? (hash-ref o 'attributes) 'doc_type)
                 (format "~a was measured and not classified" k)))
  (check-equal? (query-value conn "SELECT COUNT(*) FROM repo_derivations") 0))
