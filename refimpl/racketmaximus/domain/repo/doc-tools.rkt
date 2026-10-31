#lang racket/base

;; domain/repo/doc-tools.rkt — the four tools a document pipeline is made of
;; (slice 57, DWF-4…6). Registered at module level like index-tools.rkt, so
;; requiring this module is all it takes for a workflow — or the agent — to see them.
;;
;;   doc_text            (object, version?)            -> the document's text
;;   doc_classify        (object, labels, rules?, …)    -> one label, or refused
;;   doc_list_unclassified (prefix?)                  -> the ids a backfill should classify
;;   doc_classify_eval   (labels, prefix?, …)        -> accuracy per label and per backend
;;   doc_redact          (object, detectors?, terms?)  -> the text with identifiers tokenised
;;   doc_set_type        (object, labels, label, …)     -> the type a PERSON decided
;;   doc_extract_fields  (text, schema, object?, …)    -> fields that VALIDATE, or refused
;;   doc_render          (template, data, object?, …)  -> a filled form, as a document
;;                       …with format "pdf" and engine "weasyprint" for a branded,
;;                       paged document out of the template's own HTML and CSS
;;   doc_fill_form       (object, values, flatten?, …) -> a PDF form filled in place
;;   doc_translate       (object, locale, …)           -> the document in a language
;;
;; Every output is a REPOSITORY DOCUMENT beside its source (DWF-4): versioned by
;; key, so a re-run supersedes rather than duplicates; owned by the run's principal;
;; taking the source's visibility and live grants at creation through
;; `repo-inherit!` (DSH-5); and carrying a `repo_derivations` row naming the source
;; version, the run and the step. "Where did this form come from" is a click.
;;
;; The model is INJECTED (`current-doc-chat`), the way translate! takes #:chat, so
;; the refuse-on-mismatch path is testable with a scripted reply. The default
;; refuses to run without a configured model: the platform's uppercase-echo
;; fallback would fail every schema anyway, and "no model" is the message an
;; operator needs, not "the reply was not JSON".
;;
;; Output keys, so a listing reads as a family:
;;   inbox/acme.pdf                the source
;;   inbox/acme.pdf.classification.json  the type that was decided, and by what
;;   inbox/acme.pdf.extracted.json fields
;;   inbox/acme.pdf.form.md        the filled form (extension = the template's)
;;   inbox/acme.pdf.filled.pdf     the same PDF with its AcroForm fields filled in
;;   inbox/acme.pdf.form.ja.md     its translation (locale before the extension)
;;   inbox/acme.ja.txt             a translation of the SOURCE (text out of a PDF)

(require db-kit/portable
         racket/string racket/list racket/port racket/file racket/system
         file/unzip file/zip
         json
         "../tools/dsl.rkt"
         "../tools/jsonschema.rkt"
         "../agent/registry.rkt"
         "../agent/artifact.rkt"
         "../authz/authz.rkt"
         "../orgs/orgs.rkt"           ; tenant-quota-record!
         "../ai/executor.rkt"         ; run-chat, model-configured?
         (only-in "../ai/content.rkt" outer-json)
         "../ai/roles.rkt"            ; the team's utility executor (KG-7)
         ;; #163: the label-vector cache. It takes a connection and no principal,
         ;; so the metering is this module's — see `embed-seams`.
         (only-in "../ai/embedstore.rkt" label-vectors)
         ;; #91 req 4: the label this document carries, bound for the one gate
         ;; the three transports share. SENSITIVITY-KEY is the attribute key.
         (only-in "../ai/egress.rkt" current-egress-document)
         (only-in "../ai/sensitivity.rkt" SENSITIVITY-KEY)
         "../apps/translate.rkt"      ; translate!
         "repo.rkt"
         "classify.rkt"
         "redact.rkt"
         "redactions.rkt"
         ;; #88 req 2: the AcroForm engine. Pure of the repository, like
         ;; classify.rkt — it takes and answers bytes, so `can?`, derivation and
         ;; provenance stay here.
         "pdfform.rkt"
         ;; #88 req 1: the HTML/CSS paged-media engine, same shape — it takes
         ;; HTML and already-resolved assets, because only a caller holds a
         ;; principal and `repo-open` is where `can?` answers.
         "htmlpdf.rkt"
         ;; #88 req 3: a filled DOCX, converted by LibreOffice. Opt-in, off by
         ;; default and absent from the shipped image.
         "docxpdf.rkt"
         "extract.rkt")

(provide current-doc-chat current-doc-embed
         ;; #189 step 4: the chunk-vector write path is the SECOND asker of the
         ;; embedding meter, so it leaves this module rather than being spelled
         ;; again there. EMB-6's rule is one decision — an embedding bills
         ;; `ai.embeddings.total` and `ai.requests`, never the completion budget
         ;; — and two copies of it is `executor-can-run?`'s drift, where the
         ;; second copy is the one nobody notices has stopped agreeing.
         meter-embed!
         ;; #91 req 4: exported FOR the test, which is what makes "the label
         ;; really is read off the document's own attributes" a check rather than
         ;; a claim (#110 r4's rule — an export with a test behind it is not an
         ;; over-wide export).
         document-egress
         extract-fields render-template render-docx docx-prepare
         render-pdf pdf-toolchain
         DOCX-TYPE PDF-TYPE)

;; ---- the model seam --------------------------------------------------------------
;; (chat prompt #:system sys) -> (values reply tokens). Temperature 0: extraction and
;; translation want the likeliest reading, not a creative one.
(define (default-chat prompt #:system [sys #f])
  ;; KG-7: bulk work goes to the team's `utility` executor when one is set
  (define ex (current-utility-executor))
  (unless (or ex (model-configured?))
    (error 'doc-tools "no model configured — set TMACH_MODEL_URL, or a utility executor in Model roles"))
  (run-chat prompt #:system sys #:temperature 0 #:executor ex))

(define current-doc-chat (make-parameter default-chat))

;; ---- the embedding seam (#163) ---------------------------------------------------
;; Its own parameter beside `current-doc-chat`, for the reason `embed-exchange`
;; is its own function: an embedding model is a different model on a different
;; endpoint, so a test that scripts the chat seam says nothing about this one and
;; must not accidentally satisfy it.
;;
;; (listof string) -> (values (listof vector) input-tokens)
(define (default-embed texts)
  (define-values (vs toks _u _m) (embed-exchange texts #:who 'doc-tools))
  (values vs toks))

(define current-doc-embed (make-parameter default-embed))

;; EMB-6: AN EMBEDDING BILLS ITS OWN DIMENSION. `ai.tokens.total` counts a
;; completion; an embedding has an input count and no output at all — JUDGE-10's
;; shape, where `output_tokens` is always 0 and the answer was a dimension of its
;; own rather than a number folded into somebody else's budget. Folding them
;; would also make a nearest-label classification silently eat the budget the
;; `llm` backend needs, which is the one it is there to avoid spending.
;;
;; `ai.requests` is charged too, exactly as the chat meter does: the dimension
;; counts calls to a model and this is one.
(define (meter-embed! conn p tokens)
  (tenant-quota-record! conn p "ai.requests" 1)
  (when (and (number? tokens) (> tokens 0))
    (tenant-quota-record! conn p "ai.embeddings.total" tokens)))

;; The two closures `classify` takes. They are built HERE because this is where
;; the connection and the principal are — `classify.rkt` reaches no database and
;; `embedstore.rkt` takes no principal, so metering can only happen at this seam.
(define (embed-seams conn p team-id)
  (define embed (current-doc-embed))
  (values
   ;; the document, embedded on every call: there is nothing to cache, since the
   ;; text is this document's and is classified once
   (lambda (text)
     (define-values (vs toks) (embed (list text)))
     (meter-embed! conn p toks)
     (car vs))
   ;; the labels, embedded once and cached per team (EMB-7/EMB-8)
   (lambda (labels)
     (define-values (h toks)
       (label-vectors conn team-id labels (embed-model)
                      #:embed (lambda (texts) (embed texts))))
     ;; a fully cached label set spends nothing, so it bills nothing — the rules
     ;; backend's rule, and the reason CLS-1's control asserts on `ai.requests`
     (when (> toks 0) (meter-embed! conn p toks))
     h)))

;; ---- the model, and what this document is (RED-27) -------------------------------
;; ONE BINDER, FOUR ASKERS. Every tool here that sends a document's text to a
;; model does it inside this, which parameterizes two things at once: the team's
;; `utility` executor (KG-7, which all four already did, one copy each) and the
;; document whose text is about to travel — its `sensitivity` label and whether
;; requirement 2 minimised the text. The gate itself is in `executor.rkt`, at the
;; three places a request actually leaves the process (RED-26); this is what
;; gives it something to decide about.
;;
;; The forgetting therefore happens HERE, at a function a new tool has to call on
;; purpose, rather than at a check it has to remember to copy — which is the
;; argument `record-type!` and `repo-fields-declare!` both make, and the one
;; `executor-can-run?`'s drift is the counter-example to. A tool that sends text
;; with no document at all (`doc_extract_fields` given `text` and no `object`,
;; or `POST /api/ai/chat` with a free prompt) carries no label and is outside
;; this policy — requirement 4 governs documents, and this is stated rather than
;; implied: any tool can be handed content it read elsewhere, which is the same
;; line #83 had to draw about what sealing can promise.
(define (document-egress src red)
  (and (hash? src)
       (hasheq 'label (let ([v (hash-ref (hash-ref src 'attributes (hasheq))
                                         (string->symbol SENSITIVITY-KEY) #f)])
                        (and (string? v) (not (string=? (string-trim v) "")) v))
               ;; whether the TEXT in this request was minimised, which is the
               ;; half of the policy the allowlist is about
               'redacted (and red #t)
               'object (hash-ref src 'id #f)
               'key (hash-ref src 'key #f)
               ;; the DOCUMENT's team and org, never the caller's acting team:
               ;; the audit entry belongs in the trail of the team whose document
               ;; was about to be sent (the `#:team-id` shape, yet again), and
               ;; the policy is the owning company's
               'team (let ([v (hash-ref src 'team_id #f)]) (and (string? v) v))
               'org (let ([v (hash-ref src 'org_id #f)]) (and (string? v) v)))))

(define (call-with-document-egress conn p src red thunk)
  (parameterize ([current-utility-executor
                  (model-role-executor conn (principal-team-id p) "utility")]
                 [current-egress-document (document-egress src red)])
    (thunk)))

(define-syntax-rule (with-document-egress (conn p src red) body ...)
  (call-with-document-egress conn p src red (lambda () body ...)))

;; the flow engine bills the JOB's tokens_used, and a tool's result is nested under
;; `result` where the scheduler does not look — so an AI tool meters itself, at
;; both tiers, the way the chat endpoint does
(define (meter! conn p tokens)
  (tenant-quota-record! conn p "ai.requests" 1)
  (tenant-quota-record! conn p "ai.tokens.total" tokens))

;; ---- helpers ---------------------------------------------------------------------
(define (arg args k [d ""])
  (define v (hash-ref args k d))
  (cond [(eq? v 'null) d] [(string? v) v] [(not v) d] [else (format "~a" v)]))

(define (opt-arg args k)
  (define v (arg args k ""))
  (and (not (string=? v "")) v))

;; a document by id, or by key within the caller's team — a trigger's `template`
;; is usually a key someone typed
(define (doc-ref conn p ref)
  (or (repo-get conn p ref)
      (repo-get conn p ref #:by-key (principal-team-id p))))

(define (read-doc-bytes conn p id #:version [version #f])
  (define-values (o in) (repo-open conn p id #:version version))
  (unless in (error 'doc-tools "no such document: ~a" id))
  (define bs (dynamic-wind void (lambda () (port->bytes in)) (lambda () (close-input-port in))))
  (values o bs))

(define (text-type? ct)
  (or (string-prefix? ct "text/")
      (member ct '("application/json" "application/xml" "application/x-yaml"))))

(define (ext-of key)
  (define m (regexp-match #px"\\.([A-Za-z0-9]+)$" key))
  (and m (cadr m)))

(define (strip-ext key)
  (define e (ext-of key))
  (if e (substring key 0 (- (string-length key) (string-length e) 1)) key))

(define (basename key) (last (string-split key "/" #:trim? #f)))

;; Write a derived document beside its source and make it the source's sibling in
;; every sense: same visibility from the first byte (never a window where a private
;; invoice's fields are team-visible), the source's live grants, a derivation row.
(define (derive! conn p src #:key key #:bytes bs #:content-type ct
                 #:run [run-id #f] #:step [step-id #f])
  ;; The ORDER — visibility at the put, grants and the derivation row after —
  ;; moved to `repo-derive!` in repo.rkt when the feeds plugin became its second
  ;; asker (#114 slice 6). One rule, two askers; the comment above used to be
  ;; the only thing keeping them the same.
  (repo-derive! conn p src #:key key #:bytes bs #:content-type ct
                #:run run-id #:step step-id))

;; every pipeline output is an ARTIFACT (slice 64): the model sees one line, the
;; console a card, and a workflow step still binds (out step result object_id)
(define (obj-summary o #:summary [summary ""] #:extra [extra (hasheq)])
  (artifact #:kind "document" #:title (hash-ref o 'key) #:summary summary
            #:content-type (hash-ref o 'content_type) #:object-id (hash-ref o 'id) #:version-id (hash-ref o 'version_id)
            #:extra (for/fold ([h (hasheq 'object_id (hash-ref o 'id) 'version_id (hash-ref o 'version_id)
                                          'key (hash-ref o 'key) 'version (hash-ref o 'version))])
                              ([(k v) (in-hash extra)])
                      (hash-set h k v))))

;; ---- doc_text --------------------------------------------------------------------
(define-tool doc_text
  #:description "Return the text of a repository document (PDF, DOCX, HTML, Markdown, plain text). The first step of any document pipeline; it does not depend on the search index having run."
  (object string #:description "The repository object id")
  (version string #:optional #:description "A specific version id (default: the current version)"))

(define (doc-text conn p args)
  (define id (arg args 'object))
  (define version (opt-arg args 'version))
  (define-values (o in) (repo-open conn p id #:version version))
  (unless in (error 'doc_text "no such document: ~a" id))
  (define-values (text reason spans)
    (dynamic-wind void
                  (lambda () (extract-text/spans in (hash-ref o 'content_type)))
                  (lambda () (close-input-port in))))
  (cond
    [text
     ;; the search index gets the text for free when this is the current version,
     ;; and its provenance with it (LAY-5)
     (unless version (repo-text-upsert! conn id (hash-ref o 'version_id) text #:spans spans))
     text]
    [(eq? reason 'missing-tool)
     (error 'doc_text "pdftotext is not installed — PDF text extraction needs poppler-utils")]
    ;; the pipeline's most common real failure, and it used to arrive as an empty
    ;; document the model was asked to extract fields from
    [(eq? reason 'needs-ocr)
     (error 'doc_text
            "~a has no text layer — it is a scan, and needs OCR before the pipeline can read it"
            (hash-ref o 'key))]
    ;; unlike indexing, a pipeline on a document it cannot read FAILS: the person
    ;; who uploaded it is waiting for fields, and silence would look like success
    [else (error 'doc_text "cannot read ~a as ~a (~a)" (hash-ref o 'key) (hash-ref o 'content_type) reason)]))

;; ---- doc_extract_fields ----------------------------------------------------------
(define-tool doc_extract_fields
  #:description "Extract structured fields from a document's text against a JSON schema. The model's reply is validated and REFUSED if it does not conform — a missing required field, a wrong type, an invented key. With `object`, the fields are also written beside the source as <key>.extracted.json."
  (text string #:description "The document's text")
  (schema object #:description "A JSON schema the extracted object must conform to")
  (object string #:optional #:description "The source document's object id — write the fields as a derived document beside it")
  (redact boolean #:optional
          #:description "Build the model request from REDACTED text: identifiers are replaced with stable tokens before the prompt is composed, and the answer is put back before anything is stored")
  (redact_detectors array #:items string #:optional
                    #:description "Which detectors to run when redact is true: \"email\", \"date\", \"id_number\", \"dictionary\", \"phone\" (default: all but dictionary)")
  (redact_terms array #:items string #:optional
                #:description "Literal names or phrases for the dictionary detector — not patterns")
  (run string #:optional #:description "The workflow run id, for provenance")
  (step string #:optional #:description "The workflow step id, for provenance"))

(define EXTRACT-SYSTEM
  (string-append
   "You extract structured data from a document. Reply with ONLY one JSON object that "
   "conforms to the JSON schema the user gives you. Use exactly the keys the schema "
   "defines and no others. Numbers are JSON numbers, never strings. Dates are ISO-8601 "
   "strings. If the document does not contain a value and the schema allows null, use "
   "null. No prose, no explanation, no markdown fences."))

;; the outermost {…} of the reply is read by `outer-json`, shared with the chat
;; response-format check (domain/ai/content.rkt) so "what counts as the model's
;; JSON" has one answer on this platform.

;; text × schema -> (values fields tokens), or raises. Pure of the repository so the
;; refusal rules are testable with a scripted reply.
(define (extract-fields text schema #:chat [chat (current-doc-chat)]
                        ;; requirement 2. The prompt is built from `text` AS
                        ;; GIVEN — redaction happens in the handler, where the
                        ;; args are — and `put-back` is applied to the model's
                        ;; object BEFORE it is validated. Before, because the
                        ;; schema is the CALLER's and describes real values: a
                        ;; `pattern` or a `maxLength` on a name would refuse
                        ;; `<PERSON_1>`, and the refusal would quote the token.
                        #:put-back [put-back #f])
  (unless (hash? schema) (error 'doc_extract_fields "schema must be a JSON object"))
  (when (string=? (string-trim text) "")
    (error 'doc_extract_fields "nothing to extract from — the document has no text"))
  (define prompt (jsexpr->string (hasheq 'schema schema 'document text)))
  (define-values (reply tokens) (chat prompt #:system EXTRACT-SYSTEM))
  (define j0 (outer-json (format "~a" reply)))
  (unless (hash? j0)
    (error 'doc_extract_fields "extraction refused: the model did not return a JSON object"))
  (define-values (j unknown) (if put-back (put-back j0) (values j0 '())))
  (define problems (validate-json schema j))
  (unless (null? problems)
    (error 'doc_extract_fields "extraction refused: ~a" (string-join problems "; ")))
  (values j tokens unknown))

(define (doc-extract-fields conn p args)
  (require-perm conn p "chat:use")
  (define schema (hash-ref args 'schema #f))
  (define-values (sent put-back red) (apply-redaction 'doc_extract_fields args (arg args 'text)))
  ;; RED-27: the source is resolved BEFORE the model call, not after it. It used
  ;; to be read only to derive the output document from; the label on it is now
  ;; what decides whether the call may be made at all, and a check after the POST
  ;; is a report rather than a policy (RED-20's line, one requirement on).
  (define src (let ([id (opt-arg args 'object)]) (and id (doc-ref conn p id))))
  (define-values (fields tokens unknown)
    (with-document-egress (conn p src red)
      (extract-fields sent schema #:put-back put-back)))
  (meter! conn p tokens)
  (cond
    [src
     ;; `<key>.extracted.json` stays the FIELDS and nothing else: a downstream
     ;; `doc_render` binds it whole (`(out fields result fields)`), so a
     ;; provenance block inside it would arrive in somebody's filled form. The
     ;; redaction block rides on the tool RESULT, which is where a workflow reads
     ;; provenance from already.
     (define o (derive! conn p src
                        #:key (string-append (hash-ref src 'key) ".extracted.json")
                        #:bytes (jsexpr->bytes fields) #:content-type "application/json"
                        #:run (opt-arg args 'run) #:step (opt-arg args 'step)))
     (hash-set* (obj-summary o #:summary (format "~a extracted field(s)" (hash-count fields)))
                'fields fields 'tokens_used tokens
                'redaction (redaction-info red unknown))]
    [else (hasheq 'fields fields 'tokens_used tokens
                  'redaction (redaction-info red unknown))]))

;; The three `redact*` ARGUMENT DECLARATIONS are repeated in each of the three
;; tools below, and that is the DSL's doing rather than a choice: `define-tool`
;; reads its parameter specs as literals to build a JSON schema, so a macro cannot
;; splice them in. The LOGIC is shared — `apply-redaction` in redact.rkt, which
;; the chat endpoint calls too — and that is the half that can go wrong.

;; ---- doc_classify ----------------------------------------------------------------
;; Issue #87 slice 1. The rules, the label set and the model's refusals live in
;; `classify.rkt`, pure of the repository; what is here is the document, the
;; attributes and the derived record — the three things a classification has to
;; touch that a string cannot.
(define-tool doc_classify
  #:description "Decide which KIND of document this is, from a label set the caller gives: one label plus a confidence and a one-line rationale. Deterministic keyword/content-type rules are tried first and the model second; `backends` reorders them and may also name `embed`, a nearest-label embedding backend that needs an embedding endpoint configured and is not in the default chain. The answer is written onto the document as doc_type / doc_type_confidence / doc_type_source, so a later step — or a trigger — can choose a schema by type, and kept beside it as <key>.classification.json."
  (object string #:description "The repository object id")
  (labels array
          #:items-of ((name string #:description "The label, a slug: lower-case letters, digits, '-' or '_'")
                      (description string #:optional #:description "What this kind of document is, for the model")
                      (examples array #:items string #:optional #:description "Short example phrases typical of it"))
          #:description "The document types to choose between — one of these, and nothing else, can be the answer")
  (text string #:optional #:description "The document's text (default: extracted from the document; a scan with no text layer can still match a content-type rule)")
  (rules array
         #:items-of ((label string #:description "Which label this rule assigns")
                     (content_type string #:optional #:description "An exact content type, or a prefix ending in '/' such as \"image/\"")
                     (key_suffix string #:optional #:description "The document's key ends with this, e.g. \".pdf\"")
                     (all array #:items string #:optional #:description "Every one of these phrases appears in the text")
                     (any array #:items string #:optional #:description "At least one of these phrases appears")
                     (none array #:items string #:optional #:description "None of these phrases appears"))
         #:optional
         #:description "Deterministic rules, tried in order; the first that matches decides. Phrases, not regular expressions, and a rule needs at least one condition")
  (backends array #:items string #:optional #:description "Backend order: \"rules\", \"llm\" (default: rules then llm)")
  (redact boolean #:optional
          #:description "Build the model request from REDACTED text: identifiers are replaced with stable tokens before the prompt is composed, and the answer is put back before anything is stored")
  (redact_detectors array #:items string #:optional
                    #:description "Which detectors to run when redact is true: \"email\", \"date\", \"id_number\", \"dictionary\", \"phone\" (default: all but dictionary)")
  (redact_terms array #:items string #:optional
                #:description "Literal names or phrases for the dictionary detector — not patterns")
  (run string #:optional #:description "The workflow run id, for provenance")
  (step string #:optional #:description "The workflow step id, for provenance"))

;; CLS-9: A DOCUMENT THIS PLATFORM CANNOT READ IS STILL CLASSIFIABLE. `doc_text`
;; raises for a scan, a missing pdftotext and an unreadable file, and rightly so —
;; somebody is waiting for fields. Here the whole point of a content-type rule is
;; the photograph and the scan, so the text is best-effort and an unreadable
;; document simply has none. The model backend then refuses by name ("no text, and
;; no rule matched"), which is the honest version of the same failure.
(define (best-effort-text conn p src)
  (with-handlers ([(lambda (_) #t) (lambda (_) "")])
    (doc-text conn p (hasheq 'object (hash-ref src 'id)))))

;; ---- the ONE place a type lands on a document --------------------------------------
;; Shared by `doc_classify` (a backend decided) and `doc_set_type` (a person did),
;; because the ORDER of the two writes is a rule and not an implementation detail,
;; and two copies of a rule is `executor-can-run?`'s drift — the argument
;; `repo-fields-declare!` already made for the field declaration one line below.
;;
;; THE ATTRIBUTES GO FIRST and the record second (CLS-11). The attributes are the
;; assertion a trigger acts on; the record is provenance ABOUT that assertion.
;; Written the other way round, a refused attribute write would leave a document
;; beside the source saying the type was decided when nothing had recorded it.
;;
;; An empty `label` WITHDRAWS the type (CLS-16): LAY-4 clears an attribute by
;; merging an empty value, so a rejection is the same write with nothing in it.
;; The record is still written — "nobody could tell, and here is who said so" is
;; exactly the thing a later reader needs, and the version list is where CLS-11
;; put that history.
(define (record-type! conn p src result #:who who #:extra [extra (hasheq)]
                      #:run [run #f] #:step [step #f])
  (define key (hash-ref src 'key))
  (define label (hash-ref result 'label))
  (define withdrawn? (equal? label ""))
  ;; FEED-20's rule through the shared declaration: the three fields are added to
  ;; the team's definitions additively, or LAY-4 refuses the attribute write
  (define decl (repo-fields-declare! conn (hash-ref src 'team_id) CLASSIFY-FIELDS
                                     #:subject "a document type's fields"
                                     #:advice "Remove an object field the team no longer uses."))
  (when (string? decl)
    (raise-user-error who "declaring the document-type fields: ~a" decl))
  (define updated
    (repo-set-attributes! conn p (hash-ref src 'id)
                          (hasheq 'doc_type label
                                  'doc_type_confidence (if withdrawn? "" (confidence->string (hash-ref result 'confidence)))
                                  'doc_type_source (if withdrawn? "" (hash-ref result 'source)))))
  (when (eq? updated 'forbidden)
    (error who "forbidden: files:write on ~a — a shared document's type is its owner's to record" key))
  (when (or (symbol? updated) (string? updated))
    (error who "recording the type on ~a: ~a" key updated))
  (define record
    (hash-set* extra
               'label label
               'withdrawn withdrawn?
               'confidence (hash-ref result 'confidence)
               'source (hash-ref result 'source)
               'rationale (hash-ref result 'rationale "")
               'object_id (hash-ref src 'id)
               'version_id (hash-ref src 'version_id)
               'content_type (hash-ref src 'content_type)))
  (derive! conn p src
           #:key (string-append key ".classification.json")
           #:bytes (jsexpr->bytes record) #:content-type "application/json"
           #:run run #:step step))

(define (doc-classify conn p args)
  (define (refuse s) (raise-user-error 'doc_classify "~a" s))
  (define labels (hash-ref args 'labels #f))
  (define rules (let ([r (hash-ref args 'rules '())]) (if (or (eq? r 'null) (not r)) '() r)))
  (define backends (let ([b (hash-ref args 'backends #f)])
                     (if (or (not b) (eq? b 'null) (null? b)) CLASSIFY-BACKENDS-DEFAULT b)))
  (cond [(labels-problem labels) => refuse])
  (cond [(backends-problem backends) => refuse])
  (cond [(rules-problem rules (label-names labels)) => refuse])
  ;; CLS-12: `chat:use` is demanded when the request NAMES the model backend, not
  ;; when the chain happens to reach it. A permission that depended on whether a
  ;; rule matched would admit a member for one document and refuse them for the
  ;; next, with nothing in either answer to say why.
  (when (member "llm" backends) (require-perm conn p "chat:use"))
  (define id (arg args 'object))
  (define src (doc-ref conn p id))
  (unless src (error 'doc_classify "no such document: ~a" id))
  (define key (hash-ref src 'key))
  (define full (or (opt-arg args 'text) (best-effort-text conn p src)))
  (define capped (if (> (string-length full) CLASSIFY-CAP) (substring full 0 CLASSIFY-CAP) full))
  ;; THE RULES RUN ON THE REAL TEXT AND THE MODEL SEES THE REDACTED TEXT, which is
  ;; the one place requirement 2 cannot simply swap the input. A rule is
  ;; deterministic, local and never leaves the process, so running it on tokens
  ;; buys nothing and costs correctness: `any: ["Dear"]` still works, but a rule
  ;; keyed on an account-number prefix matches `<ID_1>` and nothing else. The
  ;; model is the thing redaction is for.
  (define-values (sent put-back red)
    (if (member "llm" backends)
        (apply-redaction 'doc_classify args capped)
        ;; no model in the chain, so there is nothing to redact FROM — and
        ;; reporting `applied: true` for a classification no model ever saw would
        ;; be a record that claims a protection it did not need
        (values capped (lambda (j) (values j '())) #f)))
  (define-values (result tokens unknown)
    (with-document-egress (conn p src red)
      (define-values (embed-doc label-vecs)
        (if (member "embed" backends)
            (embed-seams conn p (hash-ref src 'team_id))
            (values #f #f)))
      (define-values (r t)
        (classify labels #:text capped #:content-type (hash-ref src 'content_type) #:key key
                  #:rules rules #:backends backends
                  #:llm-text sent
                  #:chat (current-doc-chat)
                  #:embed-doc embed-doc #:label-vectors label-vecs))
      ;; only the RATIONALE can carry a token: the label is held to the set by an
      ;; `enum` (CLS-5), so a token there is refused before it reaches this
      (define-values (why us) (put-back (hash-ref r 'rationale "")))
      (values (hash-set r 'rationale why) t us)))
  ;; a rules answer spent nothing, so it bills nothing — `meter!` would record a
  ;; model request that never happened
  (when (> tokens 0) (meter! conn p tokens))
  (define o (record-type! conn p src result
                          #:who 'doc_classify
                          #:extra (hasheq 'labels (label-names labels)
                                          'backends backends
                                          'text_chars (string-length capped)
                                          'truncated (> (string-length full) CLASSIFY-CAP)
                                          ;; requirement 2: the record says redaction was applied
                                          ;; and which detectors ran
                                          'redaction (redaction-info red unknown))
                          #:run (opt-arg args 'run) #:step (opt-arg args 'step)))
  (hash-set* (obj-summary o #:summary (format "~a (~a, confidence ~a)"
                                              (hash-ref result 'label) (hash-ref result 'source)
                                              (confidence->string (hash-ref result 'confidence))))
             'label (hash-ref result 'label)
             'confidence (hash-ref result 'confidence)
             'source (hash-ref result 'source)
             'rationale (hash-ref result 'rationale "")
             'redaction (redaction-info red unknown)
             'tokens_used tokens))

;; ---- doc_list_unclassified: the backfill's input (issue #87 req 5, CLS-24…28) ----
;; Requirement 5 is "batch mode for backfilling existing prefixes", and the answer
;; is the shape `doc-indexer` already established: a tool that finds what has not
;; been done and a `map` that fans out over it (CLS-24). A `batch: true` mode on
;; `doc_classify` would be one tool call doing unbounded work — no per-document
;; retry, no cancel granularity, and a step output that is a list of N results
;; nothing can route on — where `map` is the engine's own fan-out primitive and
;; costs no new machinery at all.
;;
;; "UNCLASSIFIED" IS THE ABSENCE OF `doc_type`, NOT A TABLE (CLS-25). The marker
;; is the thing the backfill writes, so a finished run followed by another run
;; does nothing, a re-upload does not make a document eligible again (its type is
;; still asserted), and no migration was needed for any of it. `repo_text`'s
;; version-keyed row is the indexer's equivalent; here the assertion is about the
;; document, not about a particular set of bytes.

;; A batch is smaller than the indexer's 40 because EVERY DOCUMENT HERE MAY BE A
;; MODEL REQUEST. The shipped `ai.requests` default is 200/day, so a full batch is
;; an eighth of a team's day and 40 would make five runs exhaust it — the trap
;; CLAUDE.md records under "it worked and then stopped". A rules-only backfill
;; (`backends: ["rules"]`) costs nothing and is the way to drain a large backlog.
(define CLASSIFY-BATCH 25)
;; The scan is bounded separately, because a team whose backlog is already
;; classified would otherwise walk every object it has to answer "nothing to do".
(define CLASSIFY-SCAN 1000)
(define SCAN-PAGE 100)

(provide CLASSIFY-BATCH CLASSIFY-SCAN)   ; the tests pin both caps

(define-tool doc_list_unclassified
  #:description "List repository documents under a key prefix that have no document type yet — the input to a classification backfill. Returns object ids, capped at a batch; run the backfill again to continue. A document that already carries doc_type is skipped, which is what makes a re-run free, and the outputs other runs derived are never listed."
  (prefix string #:optional #:description "Only documents whose key starts with this (default: every document in the team)")
  (run string #:optional #:description "The workflow run id, for provenance")
  (step string #:optional #:description "The workflow step id, for provenance"))

;; ---- the scan, once, for both askers ------------------------------------------------
;; IT KEEPS PAGING PAST A PAGE THAT YIELDED NOTHING, and that is the one thing this
;; loop is for (CLS-27). `repo-list` applies `can?` per row AFTER the SQL LIMIT and
;; each caller's own filter rejects most of what is left, so a page can
;; legitimately contribute nothing while hundreds of documents wait behind it — a
;; scan that stopped there would report "nothing to do" and the operator would
;; believe it. The end of the window is `repo-count`, which is the same window
;; without the filter, and the only thing that can tell a short page from the last
;; one.
;;
;; ONE COPY, TWO ASKERS: the backfill's lister (req 5) and the evaluation's fixture
;; set (req 6). Requirement 6 was written with a second loop of its own first, and
;; that is `executor-can-run?`'s drift in miniature — two copies of the termination
;; rule, one of them with no test behind it. `page->kept` is where they differ and
;; is the only thing they do not share; the two caps and `truncated`'s two meanings
;; are the platform's.
;;
;; -> (values kept total scanned truncated?)
(define (scan-objects conn p prefix page->kept #:batch batch)
  (define total (repo-count conn p #:prefix prefix))
  (let loop ([offset 0] [acc '()] [scanned 0])
    (define page (repo-list conn p #:prefix prefix #:limit SCAN-PAGE #:offset offset))
    (define acc* (append acc (page->kept page)))
    (define offset* (+ offset SCAN-PAGE))
    (define scanned* (+ scanned (length page)))
    (cond
      [(or (>= (length acc*) batch)          ; a full batch
           (>= offset* total)                ; the end of the window
           (>= offset* CLASSIFY-SCAN))       ; the scan ceiling
       (values (if (> (length acc*) batch) (take acc* batch) acc*)
               total scanned*
               ;; "there is more — run it again", which is true on BOTH ways of
               ;; stopping: the window still has rows in it, or this page found
               ;; more than a batch and the surplus was dropped. Reporting only the
               ;; first would say `truncated: false` to an operator whose last page
               ;; held thirty documents and whose batch kept twenty-five.
               ;;
               ;; It is deliberately not a count of what remains: answering that
               ;; means scanning the whole team under `can?`, which is the work
               ;; itself, and a number that cost as much as the batch is worth
               ;; nothing. FLEET-2's `unclaimable` reports the same pair for the
               ;; same reason.
               (or (> (length acc*) batch) (< offset* total)))]
      [else (loop offset* acc* scanned*)])))

;; A DERIVED DOCUMENT IS NEVER LISTED (CLS-26). `doc_classify` writes
;; `<key>.classification.json` beside its source, and that record has no
;; `doc_type` of its own — so without this the next run would fan out over the
;; records the last one wrote, classify them, write records about THOSE, and
;; never converge. The indexer's `extractable?` filter is the same guard against
;; the same shape. The test is the derivation row rather than a key suffix:
;; `.extracted.json`, the filled forms and the translations are all somebody's
;; output too, and a suffix list would have to be kept in step with six tools.
(define (derived-ids conn ids)
  (cond
    [(null? ids) (hasheq)]
    [else
     (define qs (string-join (for/list ([_ (in-list ids)]) "?") ","))
     (for/hash ([r (in-list (apply query-rows conn
                                   (string-append "SELECT DISTINCT object_id FROM repo_derivations "
                                                  "WHERE object_id IN (" qs ")")
                                   ids))])
       (values (vector-ref r 0) #t))]))

;; The scan pages through `repo-list`, the authorized listing, rather than a WHERE
;; clause of its own: visibility lives in one place (repo.rkt's own rule) and a
;; backfill can only ever reach what its starter could read. `scan-objects` above
;; owns the loop and the two caps; what is here is the one page filter.
(define (list-unclassified conn p args)
  (require-perm conn p "files:read")
  (define prefix (arg args 'prefix))
  (define-values (kept total scanned truncated?)
    (scan-objects conn p prefix #:batch CLASSIFY-BATCH
                  (lambda (page)
                    (define unclassified
                      (for/list ([o (in-list page)]
                                 #:unless (hash-has-key? (hash-ref o 'attributes (hasheq)) 'doc_type))
                        o))
                    (define derived
                      (derived-ids conn (for/list ([o (in-list unclassified)]) (hash-ref o 'id))))
                    (for/list ([o (in-list unclassified)]
                               #:unless (hash-ref derived (hash-ref o 'id) #f))
                      (hash-ref o 'id)))))
  (hasheq 'ids kept
          'count (length kept)
          'prefix prefix
          'objects total
          'scanned scanned
               ;; "there is more — run the backfill again", which is true on BOTH
               ;; ways of stopping: the window still has rows in it, or this page
               ;; found more than a batch and the surplus was dropped. Reporting
               ;; only the first would say `truncated: false` to an operator whose
               ;; last page held thirty documents and whose batch kept twenty-five.
               ;;
               ;; It is deliberately not a count of what remains: answering that
               ;; means scanning the whole team under `can?`, which is the work
               ;; itself, and a number that cost as much as the batch is worth
               ;; nothing. FLEET-2's `unclaimable` reports the same pair for the
               ;; same reason.
          'truncated truncated?))

;; ---- doc_classify_eval: how good is the classifier? (issue #87 req 6, CLS-29…33) --
;; Requirement 6 is "given a labelled fixture set, report accuracy per label and
;; per backend". The scoring is in classify.rkt, pure; what is here is the walk
;; over the team's own documents, the per-document text, and the budget.
;;
;; CLS-33: IT WRITES NOTHING, AND THAT IS THE DECISION THE WHOLE TOOL TURNS ON.
;; `doc_classify` records a type on the document (CLS-11) and that is right for a
;; classification; an evaluation is a MEASUREMENT of the classifier, and three
;; separate things go wrong the moment it writes. It would overwrite the type on a
;; document a run had already classified, so measuring would destroy what was
;; measured. It would move `doc_type`, which since CLS-23 WAKES A TRIGGER — so
;; evaluating a fixture set would start pipelines over the fixtures. And its
;; second run would be scoring its own first run's output. So no attributes, no
;; `<key>.classification.json`, no derived document, and the permission is
;; `files:read` rather than `files:write`: an evaluation is a read of the
;; repository that happens to spend model budget.
;;
;; There is no report DOCUMENT either, for a smaller reason: a derived document
;; needs a source to derive FROM (derive!'s rule, DSH-5), and a report is about a
;; set rather than about any one of its members. A measurement of a moment belongs
;; in the answer; the fixture set is what persists.
(define EVAL-BATCH 25)

(provide EVAL-BATCH)                     ; the test pins the cap

(define-tool doc_classify_eval
  #:description "Measure the classifier against a labelled fixture set: the documents under a key prefix that carry a doc_type_expected attribute. Reports accuracy and coverage per backend AND per label, what each label was confused for, and the mean confidence of right and wrong answers — the figure that tells you whether a review threshold can separate them. Each backend is run SEPARATELY, so rules and llm are compared rather than chained, and the chain's own answer is reported beside them. Writes nothing: no type is recorded and no trigger fires."
  (labels array
          #:items-of ((name string #:description "The label, a slug: lower-case letters, digits, '-' or '_'")
                      (description string #:optional #:description "What this kind of document is, for the model")
                      (examples array #:items string #:optional #:description "Short example phrases typical of it"))
          #:description "The document types being evaluated — a fixture expecting anything else is excluded and reported")
  (prefix string #:optional #:description "Only documents whose key starts with this (default: every document in the team)")
  (rules array
         #:items-of ((label string #:description "Which label this rule assigns")
                     (content_type string #:optional #:description "An exact content type, or a prefix ending in '/' such as \"image/\"")
                     (key_suffix string #:optional #:description "The document's key ends with this, e.g. \".pdf\"")
                     (all array #:items string #:optional #:description "Every one of these phrases appears in the text")
                     (any array #:items string #:optional #:description "At least one of these phrases appears")
                     (none array #:items string #:optional #:description "None of these phrases appears"))
         #:optional
         #:description "The rule set to evaluate — the same rules the pipeline would run")
  (backends array #:items string #:optional #:description "Which backends to measure, each on its own: \"rules\", \"llm\" (default: both)")
  (run string #:optional #:description "The workflow run id, for provenance")
  (step string #:optional #:description "The workflow step id, for provenance"))

;; The fixture set is `scan-objects` with one predicate: an object carrying a
;; non-empty `doc_type_expected`. A DERIVED DOCUMENT NEEDS NO FILTER HERE, unlike
;; the backfill's: a fixture is defined by an attribute somebody wrote on purpose,
;; and nothing derives one.
(define (eval-fixtures conn p prefix)
  (scan-objects conn p prefix #:batch EVAL-BATCH
                (lambda (page)
                  (for*/list ([o (in-list page)]
                              [want (in-value (hash-ref (hash-ref o 'attributes (hasheq)) EVAL-FIELD #f))]
                              #:when (and (string? want) (not (string=? want ""))))
                    (cons o want)))))

(define (doc-classify-eval conn p args)
  (define (refuse s) (raise-user-error 'doc_classify_eval "~a" s))
  (require-perm conn p "files:read")
  (define labels (hash-ref args 'labels #f))
  (define rules (let ([r (hash-ref args 'rules '())]) (if (or (eq? r 'null) (not r)) '() r)))
  (define backends (let ([b (hash-ref args 'backends #f)])
                     (if (or (not b) (eq? b 'null) (null? b)) CLASSIFY-BACKENDS-DEFAULT b)))
  (cond [(labels-problem labels) => refuse])
  (cond [(backends-problem backends) => refuse])
  (cond [(rules-problem rules (label-names labels)) => refuse])
  ;; CLS-12's rule, unchanged: the permission follows what the request NAMES, not
  ;; what the run happens to reach
  (when (member "llm" backends) (require-perm conn p "chat:use"))
  ;; the field is declared additively, the way `record-type!` declares the other
  ;; three (FEED-20's rule): without it LAY-4 refuses the attribute and NOBODY
  ;; COULD LABEL A FIXTURE AT ALL, so the harness would answer "no fixtures" for
  ;; a reason the operator cannot act on. Declaring is not asserting — no
  ;; document is touched.
  (define decl (repo-fields-declare! conn (principal-team-id p) EVAL-FIELDS
                                     #:subject "the evaluation's expected-type field"
                                     #:advice "Remove an object field the team no longer uses."))
  (when (string? decl)
    (raise-user-error 'doc_classify_eval "declaring ~a: ~a" EVAL-FIELD decl))
  (define prefix (arg args 'prefix))
  (define-values (fixtures objects scanned truncated?) (eval-fixtures conn p prefix))
  (define chat (current-doc-chat))
  (define tokens (box 0))
  (define excluded '())
  (define rows
    ;; RED-27: BOUND PER FIXTURE, not once around the fold, because the label is
    ;; a property of each document — binding the first one's for all of them
    ;; would govern a labelled fixture by an unlabelled one's answer. The
    ;; evaluation redacts nothing (CLS-33: it writes nothing and measures the
    ;; backends as production runs them), so a labelled fixture is unredacted
    ;; text and the policy applies to it. A refusal lands as that backend's
    ;; `error` outcome for that one document — CLS-30's third outcome, carrying
    ;; the reason — so one governed fixture does not cost the whole report.
    (let ()
      (for/fold ([acc '()] #:result (reverse acc)) ([f (in-list fixtures)])
        (define o (car f))
        (define want (cdr f))
        (define problem (expected-problem labels want))
        (cond
          [problem
           (set! excluded (cons (hasheq 'object_id (hash-ref o 'id) 'key (hash-ref o 'key)
                                        'expected want 'problem problem)
                                excluded))
           acc]
          [else
           ;; THE TEXT IS READ ONCE AND SHARED BY EVERY BACKEND. Extracting per
           ;; backend would be the same work twice — and worse, it would let two
           ;; backends be compared on two different readings of the document,
           ;; which is the one thing a comparison must not do.
           (define full (best-effort-text conn p o))
           (define text (if (> (string-length full) CLASSIFY-CAP) (substring full 0 CLASSIFY-CAP) full))
           (define answers
             (for/hash ([b (in-list backends)])
               (define-values (out t)
                 (with-document-egress (conn p o #f)
                   (classify-attempt b labels #:text text
                                     #:content-type (hash-ref o 'content_type "")
                                     #:key (hash-ref o 'key)
                                     #:rules rules #:chat chat)))
               (set-box! tokens (+ (unbox tokens) t))
               (values (string->symbol b) out)))
           (cons (hasheq 'object_id (hash-ref o 'id)
                         'key (hash-ref o 'key)
                         'expected want
                         'text_chars (string-length text)
                         'answers answers)
                 acc)]))))
  ;; a rules-only evaluation spent nothing and bills nothing, the CLS-1 rule
  (when (> (unbox tokens) 0) (meter! conn p (unbox tokens)))
  (hash-set* (eval-report labels backends rows)
             'prefix prefix
             'objects objects
             'scanned scanned
             ;; the backfill's pair, for the backfill's reason: there is more
             ;; window, or this scan found more fixtures than one batch
             'truncated truncated?
             'excluded (reverse excluded)
             'tokens_used (unbox tokens)))

;; ---- doc_redact: what the model is NOT told (issue #91 req 1, RED-1…9) -----------
;; A workflow could send a document's text to a model and there was no step that
;; MINIMISED it. This one replaces the identifiers with stable tokens and keeps
;; the map back in a sealed row; requirement 2 is the half that builds a prompt
;; from the result and puts the values back, and is not this slice.
;;
;; RED-8: THE REDACTED TEXT IS A DOCUMENT, not a field on a response. It is the
;; artifact a person has to be able to READ before they trust the step — "show me
;; what you would have sent" is the only way to audit a redaction — and it is
;; what requirement 2's steps will take as their input. So it lands beside the
;; source as `<key>.redacted.txt` through `derive!`, which means private from its
;; first byte with the source's own grants (DWF-4) and a `repo_derivations` row
;; saying which run made it.
(define-tool doc_redact
  #:description "Replace the identifiers in a document's text with stable tokens — <PERSON_1>, <DATE_2>, <ID_3> — so a model request can be built from what is left. Detectors are named, not written by the caller: email, date, id_number, dictionary (terms you supply) and phone. Writes the redacted text beside the source as <key>.redacted.txt and keeps the map from token back to value in a sealed row that no endpoint returns. Reports counts per detector, so under-redaction is visible."
  (object string #:description "The repository object id")
  (detectors array #:items string #:optional
             #:description "Which detectors to run: \"email\", \"date\", \"id_number\", \"dictionary\", \"phone\" (default: all but dictionary, which needs terms)")
  (terms array #:items string #:optional
         #:description "Literal names or phrases the dictionary detector should replace — not patterns")
  (text string #:optional #:description "The text to redact (default: extracted from the document)")
  (run string #:optional #:description "The workflow run id, for provenance")
  (step string #:optional #:description "The workflow step id, for provenance"))

(define (doc-redact conn p args)
  (define (refuse s) (raise-user-error 'doc_redact "~a" s))
  (define detectors
    (let ([d (hash-ref args 'detectors #f)])
      (if (or (not d) (eq? d 'null) (null? d))
          ;; `dictionary` is out of the default because it does nothing without
          ;; terms, and a detector that silently found nothing is the under-
          ;; redaction requirement 5 exists to make visible
          (remove "dictionary" DETECTORS)
          d)))
  (define terms (let ([t (hash-ref args 'terms '())]) (if (or (eq? t 'null) (not t)) '() t)))
  (cond [(detectors-problem detectors) => refuse])
  (cond [(terms-problem terms) => refuse])
  (when (and (member "dictionary" detectors) (null? terms))
    (refuse "the dictionary detector was asked for and no terms were given — it would redact nothing, which reads in the report as a document with no names in it"))
  (define id (arg args 'object))
  (define src (doc-ref conn p id))
  (unless src (error 'doc_redact "no such document: ~a" id))
  (define key (hash-ref src 'key))
  ;; `doc_text` and not `best-effort-text`: a document whose text cannot be read
  ;; must NOT come back as an empty redaction. `doc_classify` can classify a
  ;; photograph from its content type (CLS-9) and this cannot — a redaction of
  ;; nothing is a document that reads as safe to send, which is the one answer
  ;; this step must never give. `doc_text` refuses by name, including the scan
  ;; that needs OCR.
  (define full (or (opt-arg args 'text) (doc-text conn p (hasheq 'object (hash-ref src 'id)))))
  ;; RED-4: a document already containing a token-shaped string is refused
  (when (token-shaped? full)
    (refuse (format (string-append
                     "~a already contains text shaped like a redaction token (<CLASS_n>), so a "
                     "token minted here could not be told from it — and putting values back would "
                     "then write an identifier where the document never had one. Redact a copy with "
                     "that text removed, or pass `text` with it removed.")
                    key)))
  (define-values (redacted token-map counts) (redact full #:detectors detectors #:terms terms))
  (define report (redaction-counts detectors counts))
  ;; The DOCUMENT first and the row second, which is CLS-11's order for the same
  ;; reason read the other way round: the row is the only copy of the map, so a
  ;; row written before a refused `derive!` would leave a map to a redaction
  ;; nobody can see, while a document written before a refused row leaves exactly
  ;; what it says — redacted text, with the values gone.
  (define o (derive! conn p src
                     #:key (string-append key ".redacted.txt")
                     #:bytes (string->bytes/utf-8 redacted)
                     #:content-type "text/plain"
                     #:run (opt-arg args 'run) #:step (opt-arg args 'step)))
  (define rid (redaction-record! conn p src
                                 #:detectors detectors #:counts report
                                 #:map token-map #:redacted (hash-ref o 'id)))
  (hash-set* (obj-summary o #:summary (format "~a replaced, ~a detector(s)"
                                              (length token-map) (length detectors)))
             'redaction_id rid
             'detectors detectors
             'counts report
             'replaced (length token-map)
             ;; the TOKENS and never the values: this is a tool result, so it
             ;; reaches a workflow step's stored output, the agent's transcript
             ;; and a console pane. The map is the sealed row's, and RED-6 says
             ;; nothing serves it.
             'tokens (for/list ([kv (in-list token-map)]) (car kv))
             'chars (string-length redacted)))

;; ---- doc_render ------------------------------------------------------------------
(define-tool doc_render
  #:description "Fill a form template (a Markdown, HTML or DOCX document in the repository) with data: {{field}}, {{a.b}}, and {{#each items}}…{{/each}} with {{this}} / {{@index}} inside (in a DOCX, a table row that is only {{#each items}} opens a per-item row block). Writes the result beside the source as <key>.form.<ext>, or as <key>.form.pdf when format is \"pdf\" (a Markdown or HTML template, converted with pandoc and tectonic)."
  (template string #:description "The template document's object id or key")
  (data object #:description "The data to fill in, e.g. the extracted fields")
  (format string #:optional #:description "Output format: the template's own (default) or \"pdf\" — Markdown and HTML templates only")
  (engine string #:optional #:enum ("latex" "weasyprint" "libreoffice")
          #:description "Which PDF engine, when format is \"pdf\": \"latex\" (the default — pandoc and tectonic, good for text-heavy documents), \"weasyprint\", which renders the HTML template's own CSS including @page margins, running headers and footers, and \"Page X of Y\", or \"libreoffice\", which converts a filled DOCX template. The HTML engine needs an HTML template and can inline a repository document as an image with `src=\"repo:<object id>\"`; the LibreOffice engine needs a DOCX template, is off unless soffice is on the server's PATH, and refuses a template that declares an external reference.")
  (pdf_variant string #:optional #:enum ("pdf/a-2b")
               #:description "Ask the HTML engine for an archival PDF: \"pdf/a-2b\". A raster image makes the output non-conformant (the engine marks images Interpolate true, which PDF/A forbids) — use an SVG logo.")
  (object string #:optional #:description "The source document's object id — the form is written beside it (default: beside the template)")
  (run string #:optional #:description "The workflow run id, for provenance")
  (step string #:optional #:description "The workflow step id, for provenance"))

(define (html-escape s)
  (regexp-replaces s '((#rx"&" "\\&amp;") (#rx"<" "\\&lt;") (#rx">" "\\&gt;") (#rx"\"" "\\&quot;"))))

(define (value->text v)
  (cond [(string? v) v]
        [(eq? v 'null) ""]
        [(boolean? v) (if v "true" "false")]
        [(and (number? v) (integer? v)) (number->string (inexact->exact v))]
        [(number? v) (number->string v)]
        [else (jsexpr->string v)]))

;; the scope chain: innermost first; a name resolves in the first scope that has it
(define (scope-ref scopes path)
  (define segs (string-split path "."))
  (let loop ([ss scopes])
    (cond
      [(null? ss) 'missing]
      [else
       (define v (descend (car ss) segs))
       (if (eq? v 'missing) (loop (cdr ss)) v)])))

(define (descend v segs)
  (cond
    [(null? segs) v]
    [(hash? v)
     (define k (string->symbol (car segs)))
     (if (hash-has-key? v k) (descend (hash-ref v k) (cdr segs)) 'missing)]
    [(and (list? v) (regexp-match? #px"^[0-9]+$" (car segs)))
     (define i (string->number (car segs)))
     (if (< i (length v)) (descend (list-ref v i) (cdr segs)) 'missing)]
    [else 'missing]))

;; {{…}} tokens; text between them is literal
(define TAG-RX #px"\\{\\{\\s*([^}]*?)\\s*\\}\\}")

;; template × data -> string. A placeholder the data cannot satisfy is an ERROR, not
;; a blank: a form with an empty "Total" that looks finished is the failure DWF-5
;; exists to prevent. Escape strings when the template is HTML.
(define (render-template tmpl data #:escape? [escape? #f])
  (define (show v) (let ([s (value->text v)]) (if (and escape? (string? v)) (html-escape s) s)))
  ;; tokens: a flat list of literal strings and (list 'tag "body")
  (define tokens
    (let loop ([pos 0] [acc '()])
      (define m (regexp-match-positions TAG-RX tmpl pos))
      (cond
        [(not m) (reverse (cons (substring tmpl pos) acc))]
        [else
         (define whole (car m)) (define body (cadr m))
         (loop (cdr whole)
               (cons (list 'tag (substring tmpl (car body) (cdr body)))
                     (cons (substring tmpl pos (car whole)) acc)))])))
  ;; the index of the {{/each}} that closes the block starting at toks[0], with
  ;; nested {{#each}} blocks counted
  (define (block-end toks)
    (let loop ([i 0] [depth 0] [ts toks])
      (cond
        [(null? ts) (error 'doc_render "template has an unclosed {{#each}}")]
        [(string? (car ts)) (loop (add1 i) depth (cdr ts))]
        [else
         (define body (cadr (car ts)))
         (cond
           [(string-prefix? body "#each ") (loop (add1 i) (add1 depth) (cdr ts))]
           [(string=? body "/each") (if (zero? depth) i (loop (add1 i) (sub1 depth) (cdr ts)))]
           [else (loop (add1 i) depth (cdr ts))])])))
  (define (render toks scopes)
    (let loop ([toks toks] [out '()])
      (cond
        [(null? toks) (apply string-append (reverse out))]
        [(string? (car toks)) (loop (cdr toks) (cons (car toks) out))]
        [else
         (define body (cadr (car toks)))
         (cond
           [(string=? body "/each") (error 'doc_render "template has a stray {{/each}}")]
           [(string-prefix? body "#each ")
            (define path (string-trim (substring body 6)))
            (define items (scope-ref scopes path))
            (when (eq? items 'missing)
              (error 'doc_render "template references {{#each ~a}} but the data has no ~a" path path))
            (unless (list? items)
              ;; the TYPE, never the value (#186, SEC-7): `items` is whatever the
              ;; caller's `data` bound at that path, which under the pipeline is
              ;; an extracted field — document content, and the renderer's
              ;; refusal is stored in a step's sealed `error` and printed to the
              ;; log. Naming the path tells the caller where to look; naming the
              ;; type tells them what was wrong; the value tells them nothing
              ;; they do not already have.
              (error 'doc_render "template's {{#each ~a}} needs an array, got ~a"
                     path (type-of items)))
            (define end (block-end (cdr toks)))
            (define block (take (cdr toks) end))
            (define rendered
              (apply string-append
                     (for/list ([it (in-list items)] [i (in-naturals)])
                       (render block (cons (hasheq 'this it '@index i)
                                           (cons (if (hash? it) it (hasheq)) scopes))))))
            (loop (drop (cdr toks) (add1 end)) (cons rendered out))]
           [(string=? body "this") (loop (cdr toks) (cons (show (scope-ref scopes "this")) out))]
           [else
            (define v (scope-ref scopes body))
            (when (eq? v 'missing)
              (error 'doc_render "template references {{~a}} but the data has no ~a" body body))
            (loop (cdr toks) (cons (show v) out))])])))
  (render tokens (list data)))

;; ---- DOCX (DWF-6, step 5) --------------------------------------------------------
;; A .docx is a zip whose word/document.xml carries the text. The template's
;; paragraphs carry the same {{placeholders}} as a Markdown one; two things make
;; that harder than it sounds and are handled in docx-prepare:
;;
;;   1. Word SPLITS a placeholder across runs as soon as the author pauses,
;;      corrects a letter, or the spell-checker looks at it:
;;        <w:r><w:t>{{ven</w:t></w:r><w:r><w:t>dor}}</w:t></w:r>
;;      Every tag between a {{ and its }} is dropped, so the placeholder is one
;;      run again (with the formatting of its first character — good enough).
;;   2. Line items want a TABLE ROW per item. A row whose only text is
;;      {{#each items}} opens a block and a row whose only text is {{/each}} closes
;;      it; the rows between are the per-item template. The marker rows are
;;      removed and the markers kept as text, which turns the whole thing into
;;      the generic {{#each}} the renderer already knows.
;;
;; Values are XML-escaped. A newline in a value does not become a line break in
;; Word; that is a v2 concern, like images and DOCX-native tables of contents.
(define DOCX-TYPE "application/vnd.openxmlformats-officedocument.wordprocessingml.document")

(define (docx-prepare xml)
  ;; (1) re-join split braces and split placeholder bodies until nothing changes
  (define (join s)
    (let* ([s (regexp-replace* #px"\\{(?:<[^>]+>)+\\{" s "{{")]
           [s (regexp-replace* #px"\\}(?:<[^>]+>)+\\}" s "}}")]
           [s (regexp-replace* #px"(\\{\\{[^{}<]*)(?:<[^>]+>)+([^{}<]*)" s "\\1\\2")])
      s))
  (define joined (let loop ([s xml]) (define n (join s)) (if (string=? n s) s (loop n))))
  ;; (2) table-row blocks: a row that is only a marker becomes the marker
  (define (row-text row) (string-trim (regexp-replace* #px"<[^>]+>" row "")))
  (regexp-replace* #px"<w:tr\\b(?:(?!</w:tr>).)*</w:tr>" joined
                   (lambda (row)
                     (define txt (row-text row))
                     (cond [(regexp-match? #px"^\\{\\{#each [^}]+\\}\\}$" txt) txt]
                           [(string=? txt "{{/each}}") txt]
                           [else row]))))

;; template bytes × data -> the filled .docx as bytes
(define (render-docx tbytes data)
  (define dir (make-temporary-file "telemachus-docx-~a" 'directory))
  (dynamic-wind
    void
    (lambda ()
      (with-handlers ([exn:fail? (lambda (e) (error 'doc_render "the template is not a .docx (not a zip: ~a)" (exn-message e)))])
        (unzip (open-input-bytes tbytes) (make-filesystem-entry-reader #:dest dir #:exists 'replace)))
      (define doc (build-path dir "word" "document.xml"))
      (unless (file-exists? doc) (error 'doc_render "the template is not a .docx (no word/document.xml)"))
      (define xml (file->string doc))
      (define filled (render-template (docx-prepare xml) data #:escape? #t))
      (call-with-output-file doc (lambda (out) (write-string filled out)) #:exists 'truncate)
      (define out-path (build-path dir "out.docx.zip"))
      (parameterize ([current-directory dir])
        (apply zip out-path
               (for/list ([e (in-list (directory-list dir))]
                          #:unless (equal? (path->string e) "out.docx.zip"))
                 e)))
      (file->bytes out-path))
    (lambda () (delete-directory/files dir #:must-exist? #f))))

;; ---- PDF output (DWF-6, slice 68) ------------------------------------------------
;; A filled Markdown or HTML form becomes a PDF through pandoc, with tectonic as
;; the TeX engine — the same two tools the developer e-book is built with, and
;; both on the packaged server's PATH (nix/telemachus.nix). Nothing is rendered
;; in-process: the template is filled first, exactly as for the text formats, and
;; only the finished text is handed to pandoc. A DOCX template is refused rather
;; than converted — LibreOffice is not a dependency this platform takes on.
;;
;; The toolchain is looked up at call time, not at load, so a box without it
;; still boots and every other format keeps working; the failure is a named
;; error on the one call that asked for a PDF. tectonic fetches TeX packages on
;; its first run and caches them under the server's HOME (~/.cache/Tectonic) —
;; a fresh box needs the network once, or a pre-warmed cache.
(define PDF-TYPE "application/pdf")

;; -> (cons pandoc-path tectonic-path) or #f
(define (pdf-toolchain)
  (define pandoc (find-executable-path "pandoc"))
  (define tectonic (find-executable-path "tectonic"))
  (and pandoc tectonic (cons pandoc tectonic)))

(define (render-pdf text #:html? [html? #f] #:toolchain [tc (pdf-toolchain)])
  (unless tc
    (error 'doc_render "PDF output needs pandoc and tectonic on the server's PATH — the packaged wrapper carries both; a bare `racket server/main.rkt` needs them installed"))
  (define dir (make-temporary-file "form-pdf-~a" 'directory))
  (dynamic-wind
    void
    (lambda ()
      (define in (build-path dir (if html? "form.html" "form.md")))
      (define out (build-path dir "form.pdf"))
      (call-with-output-file in (lambda (o) (write-string text o)))
      (define log (open-output-string))
      (define code
        (parameterize ([current-output-port log] [current-error-port log] [current-directory dir])
          (system*/exit-code (car tc)
                             (string-append "--pdf-engine=" (path->string (cdr tc)))
                             "--from" (if html? "html" "markdown")
                             "--variable" "geometry:margin=2.5cm"
                             "-o" (path->string out) (path->string in))))
      (unless (and (zero? code) (file-exists? out))
        (error 'doc_render "PDF conversion failed (pandoc exit ~a): ~a" code
               (string-trim (let ([s (get-output-string log)]) (if (> (string-length s) 800) (substring s (- (string-length s) 800)) s)))))
      (file->bytes out))
    (lambda () (delete-directory/files dir #:must-exist? #f))))

(define (doc-render conn p args)
  (define tref (arg args 'template))
  (define data (hash-ref args 'data #f))
  (unless (hash? data) (error 'doc_render "data must be a JSON object"))
  (define fmt (let ([f (opt-arg args 'format)]) (and f (string-downcase (string-trim f)))))
  (unless (member fmt '(#f "pdf"))
    (error 'doc_render "unknown format ~s — leave it out for the template's own format, or \"pdf\"" fmt))
  (define pdf? (equal? fmt "pdf"))
  (define tmpl-obj (doc-ref conn p tref))
  (unless tmpl-obj (error 'doc_render "no such template: ~a" tref))
  (define-values (_t tbytes) (read-doc-bytes conn p (hash-ref tmpl-obj 'id)))
  (define ct (hash-ref tmpl-obj 'content_type))
  (define docx? (or (string=? ct DOCX-TYPE) (equal? (ext-of (hash-ref tmpl-obj 'key)) "docx")))
  ;; A DOCX template could not become a PDF at all until #88 req 3; the refusal
  ;; stays the DEFAULT, because LibreOffice is not a dependency this platform
  ;; takes on — `engine: "libreoffice"` is how an integrator who installed it
  ;; says so. The message names the way through rather than just the wall.
  (when (and pdf? docx? (not (equal? (let ([e (opt-arg args 'engine)]) (and e (string-downcase (string-trim e)))) "libreoffice")))
    (error 'doc_render "a DOCX template is converted to PDF only by the libreoffice engine — pass engine \"libreoffice\" (and have soffice on the server's PATH), or use a Markdown or HTML template"))
  (define html? (string-prefix? ct "text/html"))
  ;; #88 req 1. `latex` is what `format: "pdf"` has meant since DWF-6, so it
  ;; stays the default and an existing caller keeps the renderer it has — the
  ;; second engine is an addition, not a change.
  (define engine (let ([e (opt-arg args 'engine)]) (and e (string-downcase (string-trim e)))))
  (unless (member engine (cons #f RENDER-ENGINES))
    (error 'doc_render "unknown engine ~s — it offers: ~a" engine (string-join RENDER-ENGINES ", ")))
  (define weasy? (equal? engine "weasyprint"))
  (define office? (equal? engine "libreoffice"))
  (define variant (let ([v (opt-arg args 'pdf_variant)]) (and v (string-downcase (string-trim v)))))
  (when (and engine (not pdf?))
    (error 'doc_render "engine applies to format \"pdf\" only — leave format out for the template's own format"))
  (when (and variant (not weasy?))
    (error 'doc_render "pdf_variant is the HTML engine's — pass engine \"weasyprint\" to ask for an archival PDF"))
  ;; The HTML engine needs an HTML template, and that is the point rather than a
  ;; gap: what it adds over the LaTeX path is the template's OWN CSS — @page
  ;; margins, a running header, "Page X of Y" — and a Markdown template carries
  ;; none. Converting Markdown to HTML first would hand the caller a document
  ;; whose paged media somebody else invented.
  (when (and weasy? (not html?))
    (error 'doc_render "the weasyprint engine needs an HTML template (this one is ~a) — its whole point is the template's own @page CSS, which a Markdown template does not carry" ct))
  ;; …and the LibreOffice engine needs a DOCX, for the mirror-image reason: what
  ;; it converts is a Word document, and it is here so that a template an office
  ;; produced can become a PDF without being rewritten in something else.
  (when (and office? (not docx?))
    (error 'doc_render "the libreoffice engine needs a DOCX template (this one is ~a)" ct))
  (define out-bytes
    (cond
      ;; The DOCX is filled exactly as it always was, and only the FINISHED
      ;; document is handed to the converter — the same order `render-pdf` uses
      ;; for pandoc, and what keeps the template language one implementation.
      [(and docx? office?) (docx->pdf (render-docx tbytes data) #:who 'doc_render)]
      [docx? (render-docx tbytes data)]
      [else
       (define filled (render-template (bytes->string/utf-8 tbytes #\?) data #:escape? html?))
       (cond
         [weasy?
          ;; Each referenced document is read AS THE CALLER, so `can?` decides
          ;; whether a template may inline it — a template is data, and a
          ;; template that could reach any object by id would be a way past the
          ;; repository's own gate. A document the caller cannot read is
          ;; indistinguishable from one that does not exist, as everywhere else.
          (define refs (html-pdf-object-refs filled))
          (define assets
            (for/hash ([id (in-list refs)])
              (define-values (o bs)
                (with-handlers ([exn:fail? (lambda (e)
                                             (error 'doc_render "the template references repo:~a, which is not a document you can read" id))])
                  (read-doc-bytes conn p id)))
              (values id (cons (hash-ref o 'content_type) bs))))
          (render-html-pdf filled #:assets assets #:variant variant #:who 'doc_render)]
         [pdf? (render-pdf filled #:html? html?)]
         [else (string->bytes/utf-8 filled)])]))
  (define src (let ([id (opt-arg args 'object)]) (if id (doc-ref conn p id) tmpl-obj)))
  (unless src (error 'doc_render "no such document: ~a" (opt-arg args 'object)))
  (define ext (cond [pdf? "pdf"] [else (or (ext-of (hash-ref tmpl-obj 'key)) (if docx? "docx" "md"))]))
  (define o (derive! conn p src
                     #:key (string-append (hash-ref src 'key) ".form." ext)
                     #:bytes out-bytes #:content-type (cond [pdf? PDF-TYPE] [docx? DOCX-TYPE] [else ct])
                     #:run (opt-arg args 'run) #:step (opt-arg args 'step)))
  (obj-summary o
               #:summary (string-append "filled from " (hash-ref tmpl-obj 'key)
                                        (cond [weasy? " as PDF (HTML engine)"]
                                              [office? " as PDF (LibreOffice)"]
                                              [pdf? " as PDF"] [else ""]))
               #:extra (if pdf?
                           (hasheq 'engine (or engine "latex")
                                   'pdf_variant (or variant 'null))
                           (hasheq))))

;; ---- doc_fill_form (#88 req 2) ---------------------------------------------------
;; The other half of "render a form", and the half with no workaround: `doc_render`
;; fills a TEMPLATE somebody wrote, this fills a PDF somebody ELSE wrote and sent.
;; The engine is pdfform.rkt; everything this function adds is the repository —
;; `can?` on the source through `read-doc-bytes`, and the filled document derived
;; beside it so "which form produced this" is a click (DWF-4).
(define-tool doc_fill_form
  #:description "Fill the AcroForm fields of a PDF in the repository from a JSON object of field names to values, and write the result beside it as <key>.filled.pdf. A text field takes a string, a checkbox true or false, and a radio group, combo box or list box one of its own options. Field names that the form does not carry are REPORTED in `unmatched` (every name wrong is refused instead). With flatten true the fields are drawn into the page and the document is no longer editable."
  (object string #:description "The form document's object id — a PDF carrying AcroForm fields")
  (values object #:description "Field name to value, e.g. {\"applicant\": \"Arun Patel\", \"urgent\": true}")
  (flatten boolean #:optional #:description "Draw the filled fields into the page content and remove them, so the result cannot be edited (needs qpdf)")
  (run string #:optional #:description "The workflow run id, for provenance")
  (step string #:optional #:description "The workflow step id, for provenance"))

(define (doc-fill-form conn p args)
  (define id (arg args 'object))
  (define vals (hash-ref args 'values #f))
  (unless (hash? vals) (error 'doc_fill_form "values must be a JSON object of field names to values"))
  (define flatten? (and (eq? (hash-ref args 'flatten #f) #t) #t))
  (define-values (src bs) (read-doc-bytes conn p id))
  ;; A form is a PDF. Refusing by content type rather than letting the engine
  ;; report "no AcroForm fields" is the difference between "this is the wrong
  ;; document" and "this document has no form" — two different mistakes.
  (define ct (hash-ref src 'content_type))
  (unless (or (string=? ct PDF-TYPE) (equal? (ext-of (hash-ref src 'key)) "pdf"))
    (error 'doc_fill_form "~a is ~a, not a PDF — only a PDF carries AcroForm fields" (hash-ref src 'key) ct))
  (define-values (out unmatched)
    (pdf-form-fill bs vals #:flatten? flatten? #:who 'doc_fill_form))
  (define o (derive! conn p src
                     #:key (string-append (hash-ref src 'key) ".filled.pdf")
                     #:bytes out #:content-type PDF-TYPE
                     #:run (opt-arg args 'run) #:step (opt-arg args 'step)))
  (obj-summary o
               #:summary (string-append "form filled" (if flatten? " and flattened" "")
                                        (if (null? unmatched)
                                            ""
                                            (format ", ~a field(s) not on the form" (length unmatched))))
               #:extra (hasheq 'unmatched unmatched 'flattened flatten?)))

;; ---- doc_translate ---------------------------------------------------------------
(define-tool doc_translate
  #:description "Translate a repository document into a language, applying the team glossary, and write the result beside it (the locale goes before the extension: report.md -> report.ja.md; a PDF's text becomes report.ja.txt)."
  (object string #:description "The document's object id")
  (locale string #:description "Target language code, e.g. ja, nl, es-419")
    (redact boolean #:optional
          #:description "Build the model request from REDACTED text: identifiers are replaced with stable tokens before the prompt is composed, and the answer is put back before anything is stored")
  (redact_detectors array #:items string #:optional
                    #:description "Which detectors to run when redact is true: \"email\", \"date\", \"id_number\", \"dictionary\", \"phone\" (default: all but dictionary)")
  (redact_terms array #:items string #:optional
                #:description "Literal names or phrases for the dictionary detector — not patterns")
(run string #:optional #:description "The workflow run id, for provenance")
  (step string #:optional #:description "The workflow step id, for provenance"))

;; one model call per document; a 200k-character extraction would not fit any local
;; model's window, and silently translating the first N characters is the kind of
;; "looks finished" the whole slice refuses
(define TRANSLATE-CAP 40000)

(define (doc-translate conn p args)
  (require-perm conn p "chat:use")
  (define id (arg args 'object))
  (define locale (arg args 'locale))
  (when (string=? locale "") (error 'doc_translate "locale is required"))
  (define src (doc-ref conn p id))
  (unless src (error 'doc_translate "no such document: ~a" id))
  (define ct (hash-ref src 'content_type))
  (define text
    (cond
      [(text-type? ct)
       (define-values (_o bs) (read-doc-bytes conn p (hash-ref src 'id)))
       (bytes->string/utf-8 bs #\?)]
      [else (doc-text conn p (hasheq 'object (hash-ref src 'id)))]))
  (when (string=? (string-trim text) "")
    (error 'doc_translate "nothing to translate — ~a has no text" (hash-ref src 'key)))
  (when (> (string-length text) TRANSLATE-CAP)
    (error 'doc_translate "~a is too long to translate in one call (~a characters, cap ~a)"
           (hash-ref src 'key) (string-length text) TRANSLATE-CAP))
  (define chat (current-doc-chat))
  (define-values (sent put-back red) (apply-redaction 'doc_translate args text))
  (define-values (tr tokens)
    (with-document-egress (conn p src red)
      (translate! conn p #:text sent #:target-lang locale
                  #:chat (lambda (t sys) (chat t #:system sys)))))
  (meter! conn p tokens)
  ;; `translations.source_text` and `.result_text` therefore hold the REDACTED
  ;; pair when redaction was asked for — that row is what crossed the wire, which
  ;; is strictly less content at rest than before and is the honest record of the
  ;; request. The DOCUMENT below is the rehydrated translation, which is what a
  ;; reader wants; the two deliberately differ, and the tool result says so.
  (define-values (translated unknown) (put-back (hash-ref tr 'result)))
  (define key (hash-ref src 'key))
  (define-values (out-key out-ct)
    (if (text-type? ct)
        (values (string-append (strip-ext key) "." locale (let ([e (ext-of key)]) (if e (string-append "." e) "")))
                ct)
        (values (string-append (strip-ext key) "." locale ".txt") "text/plain")))
  (define o (derive! conn p src #:key out-key
                     #:bytes (string->bytes/utf-8 translated) #:content-type out-ct
                     #:run (opt-arg args 'run) #:step (opt-arg args 'step)))
  (hash-set* (obj-summary o #:summary (string-append "translated into " locale))
             'locale locale
             'redaction (redaction-info red unknown)
             'tokens_used tokens))

;; ---- doc_set_type ----------------------------------------------------------------
;; Issue #87 slice 2, the other half of the review hook (req 4). A `review` step
;; parks the run on a person; this is how that person's decision reaches the
;; document. It is a SEPARATE TOOL from `doc_classify` rather than a mode of it,
;; because the two answer different questions — "what kind of document is this"
;; needs a backend, a budget and `chat:use`, while "record what was decided" needs
;; none of them and must work on a team with no model at all. Folding them would
;; also mean a request that names a label and a backend list, where only one of
;; them can be honoured.
(define-tool doc_set_type
  #:description "Record the document type a PERSON decided, after a review. The label is held to the same label set the classification offered, so a type no trigger could match is refused rather than stored. An EMPTY label withdraws the type — the honest record of a rejection, since there is no doc_type of \"unknown\". Writes doc_type / doc_type_confidence / doc_type_source with source \"review\" and confidence 1.00, and versions <key>.classification.json beside the document so the backend's original guess stays in its history."
  (object string #:description "The repository object id")
  (labels array
          #:items-of ((name string #:description "The label, a slug: lower-case letters, digits, '-' or '_'")
                      (description string #:optional #:description "What this kind of document is")
                      (examples array #:items string #:optional #:description "Short example phrases typical of it"))
          #:description "The label set the decision was made against — the same one doc_classify was given")
  (label string #:description "The type that was decided, spelled exactly as in the label set; empty to withdraw the type")
  (verdict string #:optional #:description "The review verdict this came from: approve, revise or reject")
  (rationale string #:optional #:description "Why, in the reviewer's own words — kept in the record, not in the attributes")
  (review string #:optional #:description "The review id, for provenance")
  (run string #:optional #:description "The workflow run id, for provenance")
  (step string #:optional #:description "The workflow step id, for provenance"))

(define (doc-set-type conn p args)
  (define (refuse s) (raise-user-error 'doc_set_type "~a" s))
  (define labels (hash-ref args 'labels #f))
  (cond [(labels-problem labels) => refuse])
  (define label (string-trim (arg args 'label)))
  (cond [(decided-problem labels label) => refuse])
  (define id (arg args 'object))
  (define src (doc-ref conn p id))
  (unless src (error 'doc_set_type "no such document: ~a" id))
  (define verdict (or (opt-arg args 'verdict) "revise"))
  (define result (classify-decided labels label
                                   #:verdict verdict
                                   #:rationale (or (opt-arg args 'rationale) "")))
  (define o (record-type! conn p src result
                          #:who 'doc_set_type
                          #:extra (let* ([h (hasheq 'labels (label-names labels)
                                                    'decided_by (principal-user-id p)
                                                    'verdict verdict)]
                                         [h (let ([r (opt-arg args 'review)])
                                              (if r (hash-set h 'review_id r) h))])
                                    h)
                          #:run (opt-arg args 'run) #:step (opt-arg args 'step)))
  (hash-set* (obj-summary o #:summary (if (string=? label "")
                                          (format "type withdrawn on review (~a)" verdict)
                                          (format "~a (review)" label)))
             'label label
             'withdrawn (string=? label "")
             'confidence (hash-ref result 'confidence)
             'source (hash-ref result 'source)
             'rationale (hash-ref result 'rationale "")
             'verdict verdict))

;; ---- registration ----------------------------------------------------------------
;; files:write on every one that writes; the two AI tools ALSO require chat:use in
;; their handlers, because a tool has one permission string and both apply
(register-tool! "doc_text"           doc_text           "files:read"  doc-text)
(register-tool! "doc_classify"       doc_classify       "files:write" doc-classify)
(register-tool! "doc_list_unclassified" doc_list_unclassified "files:read" list-unclassified)
;; req 6: an evaluation READS the repository and writes nothing (CLS-33)
(register-tool! "doc_classify_eval"  doc_classify_eval  "files:read"  doc-classify-eval)
(register-tool! "doc_redact"         doc_redact         "files:write" doc-redact)
(register-tool! "doc_set_type"       doc_set_type       "files:write" doc-set-type)
(register-tool! "doc_extract_fields" doc_extract_fields "files:write" doc-extract-fields)
(register-tool! "doc_render"         doc_render         "files:write" doc-render)
(register-tool! "doc_fill_form"      doc_fill_form      "files:write" doc-fill-form)
(register-tool! "doc_translate"      doc_translate      "files:write" doc-translate)
