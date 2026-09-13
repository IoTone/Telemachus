#lang racket/base

;; domain/repo/doc-tools.rkt — the four tools a document pipeline is made of
;; (slice 57, DWF-4…6). Registered at module level like index-tools.rkt, so
;; requiring this module is all it takes for a workflow — or the agent — to see them.
;;
;;   doc_text            (object, version?)            -> the document's text
;;   doc_extract_fields  (text, schema, object?, …)    -> fields that VALIDATE, or refused
;;   doc_render          (template, data, object?, …)  -> a filled form, as a document
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
;;   inbox/acme.pdf.extracted.json fields
;;   inbox/acme.pdf.form.md        the filled form (extension = the template's)
;;   inbox/acme.pdf.form.ja.md     its translation (locale before the extension)
;;   inbox/acme.ja.txt             a translation of the SOURCE (text out of a PDF)

(require db-kit/portable
         racket/string racket/list racket/port
         json
         "../tools/dsl.rkt"
         "../tools/jsonschema.rkt"
         "../agent/registry.rkt"
         "../authz/authz.rkt"
         "../orgs/orgs.rkt"           ; tenant-quota-record!
         "../ai/executor.rkt"         ; run-chat, model-configured?
         "../apps/translate.rkt"      ; translate!
         "repo.rkt"
         "extract.rkt")

(provide current-doc-chat
         extract-fields render-template
         TRANSLATE-CAP)

;; ---- the model seam --------------------------------------------------------------
;; (chat prompt #:system sys) -> (values reply tokens). Temperature 0: extraction and
;; translation want the likeliest reading, not a creative one.
(define (default-chat prompt #:system [sys #f])
  (unless (model-configured?)
    (error 'doc-tools "no model configured — set TELEMACHUS_MODEL_URL"))
  (run-chat prompt #:system sys #:temperature 0))

(define current-doc-chat (make-parameter default-chat))

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
  (define o (repo-put! conn p #:key key #:port (open-input-bytes bs)
                       #:content-type ct #:filename (basename key)
                       #:visibility (hash-ref src 'visibility)
                       #:allow-empty? #t))
  (repo-inherit! conn p #:source (hash-ref src 'id) #:target (hash-ref o 'id)
                 #:run-id run-id #:step-id step-id))

(define (obj-summary o)
  (hasheq 'object_id (hash-ref o 'id) 'version_id (hash-ref o 'version_id)
          'key (hash-ref o 'key) 'version (hash-ref o 'version)))

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
  (define-values (text reason)
    (dynamic-wind void
                  (lambda () (extract-text in (hash-ref o 'content_type)))
                  (lambda () (close-input-port in))))
  (cond
    [text
     ;; the search index gets the text for free when this is the current version
     (unless version (repo-text-upsert! conn id (hash-ref o 'version_id) text))
     text]
    [(eq? reason 'missing-tool)
     (error 'doc_text "pdftotext is not installed — PDF text extraction needs poppler-utils")]
    ;; unlike indexing, a pipeline on a document it cannot read FAILS: the person
    ;; who uploaded it is waiting for fields, and silence would look like success
    [else (error 'doc_text "cannot read ~a as ~a (~a)" (hash-ref o 'key) (hash-ref o 'content_type) reason)]))

;; ---- doc_extract_fields ----------------------------------------------------------
(define-tool doc_extract_fields
  #:description "Extract structured fields from a document's text against a JSON schema. The model's reply is validated and REFUSED if it does not conform — a missing required field, a wrong type, an invented key. With `object`, the fields are also written beside the source as <key>.extracted.json."
  (text string #:description "The document's text")
  (schema object #:description "A JSON schema the extracted object must conform to")
  (object string #:optional #:description "The source document's object id — write the fields as a derived document beside it")
  (run string #:optional #:description "The workflow run id, for provenance")
  (step string #:optional #:description "The workflow step id, for provenance"))

(define EXTRACT-SYSTEM
  (string-append
   "You extract structured data from a document. Reply with ONLY one JSON object that "
   "conforms to the JSON schema the user gives you. Use exactly the keys the schema "
   "defines and no others. Numbers are JSON numbers, never strings. Dates are ISO-8601 "
   "strings. If the document does not contain a value and the schema allows null, use "
   "null. No prose, no explanation, no markdown fences."))

;; the outermost {…} of the reply, parsed — a model that wraps its JSON in a fence
;; or a sentence still gets read; one that returns no object at all is refused
(define (outer-json raw)
  (define a (for/first ([i (in-naturals)] [c (in-string raw)] #:when (char=? c #\{)) i))
  (define b (for/last  ([i (in-naturals)] [c (in-string raw)] #:when (char=? c #\})) i))
  (and a b (> b a)
       (with-handlers ([exn:fail? (lambda (_) #f)])
         (string->jsexpr (substring raw a (add1 b))))))

;; text × schema -> (values fields tokens), or raises. Pure of the repository so the
;; refusal rules are testable with a scripted reply.
(define (extract-fields text schema #:chat [chat (current-doc-chat)])
  (unless (hash? schema) (error 'doc_extract_fields "schema must be a JSON object"))
  (when (string=? (string-trim text) "")
    (error 'doc_extract_fields "nothing to extract from — the document has no text"))
  (define prompt (jsexpr->string (hasheq 'schema schema 'document text)))
  (define-values (reply tokens) (chat prompt #:system EXTRACT-SYSTEM))
  (define j (outer-json (format "~a" reply)))
  (unless (hash? j)
    (error 'doc_extract_fields "extraction refused: the model did not return a JSON object"))
  (define problems (validate-json schema j))
  (unless (null? problems)
    (error 'doc_extract_fields "extraction refused: ~a" (string-join problems "; ")))
  (values j tokens))

(define (doc-extract-fields conn p args)
  (require-perm conn p "chat:use")
  (define schema (hash-ref args 'schema #f))
  (define-values (fields tokens) (extract-fields (arg args 'text) schema))
  (meter! conn p tokens)
  (define src (let ([id (opt-arg args 'object)]) (and id (doc-ref conn p id))))
  (cond
    [src
     (define o (derive! conn p src
                        #:key (string-append (hash-ref src 'key) ".extracted.json")
                        #:bytes (jsexpr->bytes fields) #:content-type "application/json"
                        #:run (opt-arg args 'run) #:step (opt-arg args 'step)))
     (hash-set* (obj-summary o) 'fields fields 'tokens_used tokens)]
    [else (hasheq 'fields fields 'tokens_used tokens)]))

;; ---- doc_render ------------------------------------------------------------------
(define-tool doc_render
  #:description "Fill a form template (a Markdown or HTML document in the repository) with data: {{field}}, {{a.b}}, and {{#each items}}…{{/each}} with {{this}} / {{@index}} inside. Writes the result beside the source as <key>.form.<ext>."
  (template string #:description "The template document's object id or key")
  (data object #:description "The data to fill in, e.g. the extracted fields")
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
              (error 'doc_render "template's {{#each ~a}} needs an array, got ~a" path (value->text items)))
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

(define (doc-render conn p args)
  (define tref (arg args 'template))
  (define data (hash-ref args 'data #f))
  (unless (hash? data) (error 'doc_render "data must be a JSON object"))
  (define tmpl-obj (doc-ref conn p tref))
  (unless tmpl-obj (error 'doc_render "no such template: ~a" tref))
  (define-values (_t tbytes) (read-doc-bytes conn p (hash-ref tmpl-obj 'id)))
  (define ct (hash-ref tmpl-obj 'content_type))
  (define tmpl (bytes->string/utf-8 tbytes #\?))
  (define text (render-template tmpl data #:escape? (string-prefix? ct "text/html")))
  (define src (let ([id (opt-arg args 'object)]) (if id (doc-ref conn p id) tmpl-obj)))
  (unless src (error 'doc_render "no such document: ~a" (opt-arg args 'object)))
  (define ext (or (ext-of (hash-ref tmpl-obj 'key)) "md"))
  (define o (derive! conn p src
                     #:key (string-append (hash-ref src 'key) ".form." ext)
                     #:bytes (string->bytes/utf-8 text) #:content-type ct
                     #:run (opt-arg args 'run) #:step (opt-arg args 'step)))
  (obj-summary o))

;; ---- doc_translate ---------------------------------------------------------------
(define-tool doc_translate
  #:description "Translate a repository document into a language, applying the team glossary, and write the result beside it (the locale goes before the extension: report.md -> report.ja.md; a PDF's text becomes report.ja.txt)."
  (object string #:description "The document's object id")
  (locale string #:description "Target language code, e.g. ja, nl, es-419")
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
  (define-values (tr tokens)
    (translate! conn p #:text text #:target-lang locale
                #:chat (lambda (t sys) (chat t #:system sys))))
  (meter! conn p tokens)
  (define key (hash-ref src 'key))
  (define-values (out-key out-ct)
    (if (text-type? ct)
        (values (string-append (strip-ext key) "." locale (let ([e (ext-of key)]) (if e (string-append "." e) "")))
                ct)
        (values (string-append (strip-ext key) "." locale ".txt") "text/plain")))
  (define o (derive! conn p src #:key out-key
                     #:bytes (string->bytes/utf-8 (hash-ref tr 'result)) #:content-type out-ct
                     #:run (opt-arg args 'run) #:step (opt-arg args 'step)))
  (hash-set* (obj-summary o) 'locale locale 'tokens_used tokens))

;; ---- registration ----------------------------------------------------------------
;; files:write on every one that writes; the two AI tools ALSO require chat:use in
;; their handlers, because a tool has one permission string and both apply
(register-tool! "doc_text"           doc_text           "files:read"  doc-text)
(register-tool! "doc_extract_fields" doc_extract_fields "files:write" doc-extract-fields)
(register-tool! "doc_render"         doc_render         "files:write" doc-render)
(register-tool! "doc_translate"      doc_translate      "files:write" doc-translate)
