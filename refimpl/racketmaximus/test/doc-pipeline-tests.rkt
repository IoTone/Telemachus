#lang racket/base

;; test/doc-pipeline-tests.rkt — slice 57: uploads processed by a workflow.
;;   raco test test/doc-pipeline-tests.rkt
;;
;; Three layers, deliberately separate:
;;   1. the JSON-schema validator and the template renderer, as pure functions
;;   2. doc_extract_fields' REFUSAL rules, with a scripted model reply — the DWF-5
;;      promise is that a wrong extraction never looks finished
;;   3. the WHOLE PIPELINE through the real engine: upload -> process-upload via
;;      the scheduler's claim path -> four derived documents beside the source,
;;      each with the source's visibility and grants, each with provenance

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
         "../domain/tools/jsonschema.rkt"
         "../domain/repo/doc-tools.rkt"          ; registers the tools
         "../domain/agent/tools.rkt"             ; the rest of the catalog
         "../domain/sched/scheduler.rkt"
         "../domain/flow/run.rkt"
         (prefix-in pipeline: "../plugins/doc-pipeline/main.rkt"))

;; ---- fixtures -----------------------------------------------------------------
(define BLOB-ROOT (make-temporary-file "telemachus-pipeline-blobs-~a" 'directory))
(current-blob-root BLOB-ROOT)

(define (fresh)
  (define conn (fresh-db #:migrate? #f))
  (migrate! conn all-migrations)
  conn)

(define (drain! conn [limit 300])
  (let loop ([n 0]) (when (and (< n limit) (process-one! conn)) (loop (add1 n)))))

(define (read-back conn p id)
  (define-values (o in) (repo-open conn p id))
  (and in (let ([bs (port->bytes in)]) (close-input-port in) bs)))

;; a scripted model: extraction prompts carry the schema, translation prompts a
;; translator system prompt. Replies are what the test says they are.
(define (scripted #:fields fields-reply #:translate [tr-reply "TRANSLATED"])
  (lambda (prompt #:system [sys #f])
    (cond
      [(and sys (string-contains? sys "extract structured data")) (values fields-reply 42)]
      [(and sys (string-contains? sys "translator"))
       (define tgt (let ([m (regexp-match #px"into ([A-Za-z ]+?)[. ]" sys)]) (if m (cadr m) "?")))
       (values (string-append tr-reply " [" tgt "] " prompt) 7)]
      [else (values "MOCK" 1)])))

(define INVOICE-SCHEMA
  (hasheq 'type "object"
          'required '("vendor" "total" "items")
          'properties (hasheq 'vendor (hasheq 'type "string")
                              'date (hasheq 'type '("string" "null"))
                              'total (hasheq 'type "number" 'minimum 0)
                              'items (hasheq 'type "array" 'minItems 1
                                             'items (hasheq 'type "object"
                                                            'required '("description" "amount")
                                                            'properties (hasheq 'description (hasheq 'type "string")
                                                                                'amount (hasheq 'type "number")))))))

(define GOOD-FIELDS
  (hasheq 'vendor "Acme Corp" 'date "2026-09-01" 'total 1250.5
          'items (list (hasheq 'description "Widgets" 'amount 1000)
                       (hasheq 'description "Shipping" 'amount 250.5))))

;; ---- 1a. the schema validator ---------------------------------------------------
(test-case "jsonschema: types, required, closed objects, arrays, ranges"
  (check-true (json-valid? INVOICE-SCHEMA GOOD-FIELDS))
  (check-true (json-valid? INVOICE-SCHEMA (hash-set GOOD-FIELDS 'date 'null)) "a nullable type accepts null")
  (define (problems v) (validate-json INVOICE-SCHEMA v))
  (check-match (problems (hash-remove GOOD-FIELDS 'total)) (list (regexp #rx"missing required field 'total'")))
  (check-match (problems (hash-set GOOD-FIELDS 'total "1250.5")) (list (regexp #rx"\\$\\.total: expected number, got string")))
  (check-match (problems (hash-set GOOD-FIELDS 'notes "made up")) (list (regexp #rx"unexpected field 'notes'")))   ; CLOSED unless it says otherwise
  (check-match (problems (hash-set GOOD-FIELDS 'total -1)) (list (regexp #rx"less than the minimum 0")))
  (check-match (problems (hash-set GOOD-FIELDS 'items '())) (list (regexp #rx"fewer than 1 items")))
  (check-match (problems (hash-set GOOD-FIELDS 'items (list (hasheq 'description "x"))))
               (list (regexp #rx"\\$\\.items\\[0\\]: missing required field 'amount'")))
  (check-match (problems "not an object") (list (regexp #rx"expected object, got string")))
  (check-match (problems 'null) (list (regexp #rx"expected object, got null")))
  ;; integers are numbers; 3.0 is an integer
  (check-true (json-valid? (hasheq 'type "integer") 3))
  (check-true (json-valid? (hasheq 'type "integer") 3.0))
  (check-false (json-valid? (hasheq 'type "integer") 3.5))
  (check-true (json-valid? (hasheq 'type "number") 3))
  ;; enum, pattern, lengths, open objects, boolean schemas
  (check-false (json-valid? (hasheq 'enum '("a" "b")) "c"))
  (check-true  (json-valid? (hasheq 'type "string" 'pattern "^[0-9]{4}-[0-9]{2}$") "2026-09"))
  (check-false (json-valid? (hasheq 'type "string" 'pattern "^[0-9]{4}-[0-9]{2}$") "Sept 2026"))
  (check-false (json-valid? (hasheq 'type "string" 'maxLength 3) "abcd"))
  (check-true  (json-valid? (hasheq 'type "object" 'additionalProperties #t) (hasheq 'anything "goes")))
  (check-false (json-valid? (hasheq 'type "object" 'additionalProperties (hasheq 'type "number")) (hasheq 'x "no")))
  (check-true  (json-valid? #t 'null))
  (check-false (json-valid? #f 'null)))

;; ---- 1b. the template renderer --------------------------------------------------
(test-case "render-template: fields, paths, each blocks, escaping, strictness"
  (define data (hasheq 'vendor "Acme <Corp>" 'total 1250.5 'approved #t 'n 3
                       'buyer (hasheq 'name "Zoë")
                       'items (list (hasheq 'description "Widgets" 'amount 1000)
                                    (hasheq 'description "Shipping" 'amount 250.5))
                       'tags '("a" "b")))
  (check-equal? (render-template "Vendor: {{vendor}} / {{ buyer.name }} / {{total}} / {{approved}} / {{n}}" data)
                "Vendor: Acme <Corp> / Zoë / 1250.5 / true / 3")
  (check-equal? (render-template "<b>{{vendor}}</b>" data #:escape? #t) "<b>Acme &lt;Corp&gt;</b>"
                "HTML templates escape values")
  (check-equal? (render-template "{{#each items}}- {{description}}: {{amount}} ({{@index}})\n{{/each}}end" data)
                "- Widgets: 1000 (0)\n- Shipping: 250.5 (1)\nend")
  (check-equal? (render-template "[{{#each tags}}{{this}},{{/each}}]" data) "[a,b,]")
  (check-equal? (render-template "{{#each items}}{{description}} for {{vendor}};{{/each}}" data)
                "Widgets for Acme <Corp>;Shipping for Acme <Corp>;" "the outer scope is visible inside a block")
  (check-equal? (render-template "x{{#each none}}never{{/each}}y" (hasheq 'none '())) "xy")
  (check-equal? (render-template "{{#each a}}{{#each b}}{{this}}{{/each}}|{{/each}}"
                                 (hasheq 'a (list (hasheq 'b '(1 2)) (hasheq 'b '(3)))))
                "12|3|" "blocks nest")
  ;; strict: a placeholder the data cannot satisfy is an error, never a blank
  (check-exn #rx"template references {{missing}} but the data has no missing"
             (lambda () (render-template "{{vendor}} {{missing}}" data)))
  (check-exn #rx"needs an array" (lambda () (render-template "{{#each vendor}}{{/each}}" data)))
  (check-exn #rx"unclosed" (lambda () (render-template "{{#each items}}x" data)))
  (check-exn #rx"stray" (lambda () (render-template "x{{/each}}" data))))

;; ---- 2. extraction refuses what does not conform ----------------------------------
(test-case "extract-fields: conforming JSON is accepted, everything else is refused"
  (define (with reply) (extract-fields "Invoice from Acme…" INVOICE-SCHEMA
                                       #:chat (lambda (p #:system [s #f]) (values reply 5))))
  (let-values ([(fields tokens) (with (jsexpr->string GOOD-FIELDS))])
    (check-equal? (hash-ref fields 'vendor) "Acme Corp")
    (check-equal? tokens 5))
  ;; a fence or a sentence around the object still parses
  (let-values ([(fields _t) (with (string-append "Here you go:\n```json\n" (jsexpr->string GOOD-FIELDS) "\n```"))])
    (check-equal? (hash-ref fields 'total) 1250.5))
  (check-exn #rx"did not return a JSON object" (lambda () (with "I cannot find an invoice.")))
  (check-exn #rx"extraction refused: .*missing required field 'vendor'"
             (lambda () (with (jsexpr->string (hash-remove GOOD-FIELDS 'vendor)))))
  (check-exn #rx"extraction refused: .*expected number, got string"
             (lambda () (with (jsexpr->string (hash-set GOOD-FIELDS 'total "1,250.50")))))
  (check-exn #rx"extraction refused: .*unexpected field 'currency'"
             (lambda () (with (jsexpr->string (hash-set GOOD-FIELDS 'currency "USD")))))
  (check-exn #rx"nothing to extract" (lambda () (extract-fields "  " INVOICE-SCHEMA #:chat (lambda (p #:system [s #f]) (values "{}" 1)))))
  (check-exn #rx"schema must be a JSON object" (lambda () (extract-fields "x" "not a schema" #:chat (lambda (p #:system [s #f]) (values "{}" 1))))))

;; ---- 3. the pipeline, end to end ---------------------------------------------------
(test-case "upload -> process-upload -> four derived documents with provenance, visibility and grants"
  (define conn (fresh))
  (define-values (uid tid) (bootstrap! conn #:username "alice"))
  (define alice (user-principal conn uid tid))
  (define bob-id (create-user! conn #:username "bob" #:password "pw"))
  (add-member! conn #:user bob-id #:team tid #:role "member")
  (define bob (user-principal conn bob-id tid))
  (define carol-id (create-user! conn #:username "carol" #:password "pw"))
  (add-member! conn #:user carol-id #:team tid #:role "member")
  (define carol (user-principal conn carol-id tid))

  (register-plugin-workflow! "doc-pipeline" (car pipeline:workflows))
  (define def (flow-def-by-slug conn alice "process-upload"))
  (check-true (and def #t) "the plugin workflow materialized")

  (define (up! p key bytes ct #:vis [vis "team"])
    (repo-put! conn p #:key key #:port (open-input-bytes bytes)
               #:content-type ct #:filename key #:visibility vis))
  ;; a PRIVATE invoice, shared with bob (view) — carol must see none of what follows
  (define invoice (up! alice "inbox/acme.txt" #"INVOICE\nAcme Corp\nWidgets 1000\nShipping 250.50\nTotal 1250.50" "text/plain" #:vis "private"))
  (repo-share! conn alice (hash-ref invoice 'id) #:user bob-id)
  (up! alice "templates/approval.md"
       #"# Purchase approval\n\nVendor: {{vendor}}\nTotal: {{total}}\n\n{{#each items}}- {{description}}: {{amount}}\n{{/each}}"
       "text/markdown")

  (define (run! p input)
    (define run (flow-run-start! conn p def #:input input))
    (drain! conn)
    (flow-run-get conn p (hash-ref run 'id)))
  (define (by-key p key) (repo-get conn p key #:by-key tid))
  (define (derivation-of p key)
    (define o (by-key p key))
    (and o (let ([d (repo-derivations conn p (hash-ref o 'id))]) (and (pair? d) (car d)))))

  (define (tokens-used) (quota-used conn "team" tid "ai.tokens.total" "total"))
  (define used-before (tokens-used))

  ;; --- the happy path: text -> fields -> form -> ja + nl ---
  (define done
    (parameterize ([current-doc-chat (scripted #:fields (jsexpr->string GOOD-FIELDS))])
      (run! alice (hasheq 'object_id (hash-ref invoice 'id) 'schema INVOICE-SCHEMA
                          'template "templates/approval.md" 'locales '("ja" "nl")))))
  (check-equal? (hash-ref done 'status) "done" (format "the run finished (error: ~a)" (hash-ref done 'error)))
  (define step-ids (map (lambda (s) (hash-ref s 'step_id)) (hash-ref done 'steps)))
  (check-true (and (member "form" step-ids) #t) "the template was present, so the form step ran")
  (check-false (member "translate_source" step-ids) "…and the source-translation branch did not")

  ;; four documents beside the source, keys as documented
  (define fields-doc (by-key alice "inbox/acme.txt.extracted.json"))
  (define form-doc   (by-key alice "inbox/acme.txt.form.md"))
  (define ja-doc     (by-key alice "inbox/acme.txt.form.ja.md"))
  (define nl-doc     (by-key alice "inbox/acme.txt.form.nl.md"))
  (for ([d (list fields-doc form-doc ja-doc nl-doc)] [n '("fields" "form" "ja" "nl")])
    (check-true (and d #t) (format "the ~a document exists" n))
    (check-equal? (hash-ref d 'visibility) "private" (format "the ~a document took the source's visibility" n))
    (check-equal? (hash-ref d 'owner_user_id) uid "owned by the run's principal"))
  (check-equal? (string->jsexpr (bytes->string/utf-8 (read-back conn alice (hash-ref fields-doc 'id))))
                GOOD-FIELDS "the fields document holds exactly the validated object")
  (check-equal? (bytes->string/utf-8 (read-back conn alice (hash-ref form-doc 'id)))
                "# Purchase approval\n\nVendor: Acme Corp\nTotal: 1250.5\n\n- Widgets: 1000\n- Shipping: 250.5\n"
                "the form is the template filled with the fields")
  (check-true (regexp-match? #rx"^TRANSLATED \\[Japanese\\] # Purchase approval"
                             (bytes->string/utf-8 (read-back conn alice (hash-ref ja-doc 'id))))
              "the translation is of the FORM, into the item's locale")
  (check-equal? (hash-ref fields-doc 'content_type) "application/json")
  (check-equal? (hash-ref ja-doc 'content_type) "text/markdown")

  ;; grants came along: bob (view on the invoice) reads every output; carol none
  (for ([d (list fields-doc form-doc ja-doc nl-doc)])
    (check-true (and (read-back conn bob (hash-ref d 'id)) #t) "bob's grant was inherited")
    (check-exn exn:fail:forbidden? (lambda () (repo-get conn carol (hash-ref d 'id))) "carol has no grant"))

  ;; provenance: each output names the source version, the run and its step
  (define run-id (hash-ref done 'id))
  (for ([key '("inbox/acme.txt.extracted.json" "inbox/acme.txt.form.ja.md")]
        [step '("fields" "translate")])
    (define d (derivation-of alice key))
    (check-true (and d #t) (format "~a has a derivation row" key))
    (check-equal? (hash-ref d 'run_id) run-id)
    (check-equal? (hash-ref d 'step_id) step))
  (check-equal? (hash-ref (derivation-of alice "inbox/acme.txt.extracted.json") 'source_object_id) (hash-ref invoice 'id)
                "the fields derive from the invoice")
  (check-equal? (hash-ref (derivation-of alice "inbox/acme.txt.form.ja.md") 'source_object_id) (hash-ref form-doc 'id)
                "the translation derives from the FORM, not the invoice")
  (check-equal? (hash-ref (derivation-of alice "inbox/acme.txt.form.md") 'source_version_id) (hash-ref invoice 'version_id))
  (check-equal? (repo-derivations conn alice (hash-ref invoice 'id)) '() "the source derives from nothing")

  ;; AI spend was metered: one extraction (42) + two translations (7 each)
  (check-equal? (- (tokens-used) used-before) 56
                "the tools meter ai.tokens.total themselves")

  ;; --- re-running supersedes: the same keys get a new version, no duplicates ---
  (define again
    (parameterize ([current-doc-chat (scripted #:fields (jsexpr->string GOOD-FIELDS))])
      (run! alice (hasheq 'object_id (hash-ref invoice 'id) 'schema INVOICE-SCHEMA
                          'template "templates/approval.md" 'locales '("ja")))))
  (check-equal? (hash-ref again 'status) "done")
  (check-equal? (hash-ref (by-key alice "inbox/acme.txt.form.md") 'version) 2 "a re-run writes version 2 of the form")
  (check-equal? (length (repo-derivations conn alice (hash-ref form-doc 'id))) 2 "…and a second derivation row")

  ;; --- no template: the SOURCE is translated; no locales: stop after the form ---
  (define src-only
    (parameterize ([current-doc-chat (scripted #:fields (jsexpr->string GOOD-FIELDS))])
      (run! alice (hasheq 'object_id (hash-ref invoice 'id) 'schema INVOICE-SCHEMA
                          'template "" 'locales '("nl")))))
  (check-equal? (hash-ref src-only 'status) "done" (format "(error: ~a)" (hash-ref src-only 'error)))
  (define src-nl (by-key alice "inbox/acme.nl.txt"))
  (check-true (and src-nl #t) "the source's translation sits beside it, locale before the extension")
  (check-true (regexp-match? #rx"^TRANSLATED \\[Dutch\\] INVOICE" (bytes->string/utf-8 (read-back conn alice (hash-ref src-nl 'id)))))
  (check-false (member "form" (map (lambda (s) (hash-ref s 'step_id)) (hash-ref src-only 'steps))) "no template, no form step")
  (define form-only
    (parameterize ([current-doc-chat (scripted #:fields (jsexpr->string GOOD-FIELDS))])
      (run! alice (hasheq 'object_id (hash-ref invoice 'id) 'schema INVOICE-SCHEMA
                          'template "templates/approval.md" 'locales '()))))
  (check-equal? (hash-ref form-only 'status) "done" "an empty locales list is a fan-out over nothing")

  ;; --- a non-conforming extraction FAILS the run, after one retry, writing nothing ---
  (define other (up! alice "inbox/other.txt" #"some memo" "text/plain"))
  (define calls (box 0))
  (define failed
    (parameterize ([current-doc-chat
                    (lambda (prompt #:system [sys #f])
                      (set-box! calls (add1 (unbox calls)))
                      (values (jsexpr->string (hash-set GOOD-FIELDS 'total "lots")) 3))])
      (run! alice (hasheq 'object_id (hash-ref other 'id) 'schema INVOICE-SCHEMA
                          'template "templates/approval.md" 'locales '("ja")))))
  (check-equal? (hash-ref failed 'status) "error")
  (check-true (regexp-match? #rx"extraction refused: .*expected number, got string" (hash-ref failed 'error))
              "the run says why")
  (check-equal? (unbox calls) 2 "the fields step was retried exactly once")
  (check-false (by-key alice "inbox/other.txt.extracted.json") "a refused extraction writes nothing")
  (check-false (by-key alice "inbox/other.txt.form.md") "…and nothing downstream ran")

  ;; --- the declared inputs are required: a run without a schema is refused at start ---
  (check-exn #rx"input 'schema' is required"
             (lambda () (flow-run-start! conn alice def #:input (hasheq 'object_id (hash-ref invoice 'id)
                                                                        'template "" 'locales '()))))

  ;; --- a missing template is the tool's error, not a blank form ---
  (define no-tmpl
    (parameterize ([current-doc-chat (scripted #:fields (jsexpr->string GOOD-FIELDS))])
      (run! alice (hasheq 'object_id (hash-ref invoice 'id) 'schema INVOICE-SCHEMA
                          'template "templates/nope.md" 'locales '()))))
  (check-equal? (hash-ref no-tmpl 'status) "error")
  (check-true (regexp-match? #rx"no such template" (hash-ref no-tmpl 'error)))

  ;; --- bob (a viewer of the invoice) can run the pipeline, but cannot write beside
  ;; alice's private document: the outputs are HIS documents, private, derived from hers ---
  (define bobs
    (parameterize ([current-doc-chat (scripted #:fields (jsexpr->string GOOD-FIELDS))])
      (run! bob (hasheq 'object_id (hash-ref invoice 'id) 'schema INVOICE-SCHEMA
                        'template "" 'locales '()))))
  ;; the fields document's key already exists and is alice's private object — an
  ;; overwrite by bob is refused, so his run fails cleanly rather than clobbering
  (check-equal? (hash-ref bobs 'status) "error")
  (check-true (regexp-match? #rx"forbidden: files:write" (hash-ref bobs 'error))
              "a viewer cannot overwrite the owner's derived document")
  (disconnect conn))

;; without a configured model, the default seam refuses loudly rather than letting
;; the uppercase-echo fallback fail every schema with a misleading message
(check-exn #rx"no model configured"
           (lambda () (extract-fields "text" (hasheq 'type "object"))))
