#lang racket/base

;; domain/kg/kg-tools.rkt — the three knowledge-graph tools (slice 61).
;;
;;   kg_list_unextracted   what the index-knowledge workflow should look at next
;;   kg_extract            one document -> {entities, relations}, STRICTLY validated
;;   kg_query              the agent's "what do we know about X", with citations
;;
;; Registered at module level like the indexing and pipeline tools. The model is
;; the same seam the document pipeline uses (`current-doc-chat`), so one scripted
;; reply serves every test and one configured model serves production. Without a
;; model the extractor refuses loudly rather than letting the uppercase-echo
;; fallback fail validation with a misleading message.
;;
;; VALIDATION IS THE PROVENANCE (KG design, "Extraction pipeline"): a mention's
;; snippet must be a verbatim substring of the text the tool was given; an entity
;; needs a non-empty name; a relation may only join entities named in the same
;; reply. Anything else is refused whole — a bad fact that looks finished is worse
;; than a missing one. This is the Localization Manager's placeholder guard and
;; the pipeline's schema guard, applied a third time.

(require db-kit/portable
         racket/string racket/list
         json
         "../tools/dsl.rkt"
         "../agent/registry.rkt"
         "../authz/authz.rkt"
         "../orgs/orgs.rkt"
         "../repo/repo.rkt"
         "../repo/extract.rkt"
         "../repo/doc-tools.rkt"          ; current-doc-chat
         "../ai/roles.rkt"                ; the team's utility executor
         "kg.rkt"
         ;; the plugin-source seam: an id from a registered source is read, versioned and
         ;; texted through that source rather than through the repository
         "sources.rkt")

(provide validate-extraction extract-knowledge extract-document window-split merge-extractions
         LIST-BATCH EXTRACT-TEXT-CAP)

(define LIST-BATCH 40)
;; THE SIZE OF ONE MODEL CALL, NOT THE SIZE OF ONE DOCUMENT. It was both until 2026-11-19: a
;; document longer than this was cut here and everything past the cut never entered the graph.
;; That does not read as "we did not read it", it reads as "the graph disagrees with the
;; document", and the facts that go missing are exactly the ones in the back half — annexes,
;; specification tables, the second half of a filing. `extract-document` below keeps this as the
;; window and reads the whole document.
(define EXTRACT-TEXT-CAP 12000)
;; HOW MANY WINDOWS ONE DOCUMENT MAY COST, because each window is a metered model call and the
;; ceiling has to be a number somebody chose rather than whatever a large document happens to
;; imply. 24 windows is about 288k characters at the default size. When a document exceeds it the
;; read is marked truncated, so the answer says so instead of quietly under-reading.
(define EXTRACT-MAX-WINDOWS 24)

(define-tool kg_list_unextracted
  #:description "List the documents whose text has not been extracted into the knowledge graph yet (or is stale after an overwrite). A document is a repository object or one a plugin source lends to the graph. Returns ids, capped at a batch; run the index-knowledge workflow again to continue.")

(define-tool kg_extract
  #:description "Extract entities (people, organizations, products, places, events, concepts) and the relations between them from one document into the knowledge graph, every mention with a verbatim snippet. A long document is read in windows of about 12,000 characters, up to a per-document limit that the answer reports. Refuses a reply that does not validate."
  (object string #:description "The document id, from the repository or from a plugin source"))

(define-tool kg_query
  #:description "What the team's documents say about an entity: its relations and the documents that mention it, with snippets. Give a name (or an entity id); hops 1 returns its neighbours, hops 2 their neighbours too."
  (name string #:description "An entity name (matched case-insensitively) or an entity id")
  (hops integer #:optional #:description "1 (default) or 2")
  (type string #:optional #:description "Restrict a name lookup to one entity type, e.g. organization"))

(define EXTRACT-SYSTEM
  (string-append
   "You extract a knowledge graph from a document. Reply with ONLY one JSON object of "
   "the shape {\"entities\": [{\"type\", \"name\", \"description\", \"snippet\"}], "
   "\"relations\": [{\"subject\", \"predicate\", \"object\", \"snippet\"}]}. Types are "
   "one of person, organization, product, place, event, concept, or another short "
   "lower-case noun if none fits. Predicates are short lower_snake_case verbs such "
   "as works_at, part_of, located_in, customer_of, depends_on, produces. A relation's "
   "subject and object must be entity names from the same reply. Every snippet is a "
   "VERBATIM excerpt of the document, copied exactly, of at most 200 characters, in "
   "which the entity or relation is stated. Name only what the document actually says. "
   "No prose, no markdown fences."))

(define (outer-json raw)
  (define a (for/first ([i (in-naturals)] [c (in-string raw)] #:when (char=? c #\{)) i))
  (define b (for/last  ([i (in-naturals)] [c (in-string raw)] #:when (char=? c #\})) i))
  (and a b (> b a)
       (with-handlers ([exn:fail? (lambda (_) #f)])
         (string->jsexpr (substring raw a (add1 b))))))

(define (str? v) (and (string? v) (not (string=? (string-trim v) ""))))

;; -> a list of problems, empty when the extraction is acceptable
(define (validate-extraction j text)
  (cond
    [(not (hash? j)) '("the reply is not a JSON object")]
    [else
     (define ents (hash-ref j 'entities 'missing))
     (define rels (hash-ref j 'relations '()))
     (define problems '())
     (define (bad! fmt . args) (set! problems (cons (apply format fmt args) problems)))
     (unless (list? ents) (bad! "entities must be an array"))
     (unless (list? rels) (bad! "relations must be an array"))
     (define names (make-hash))
     (when (list? ents)
       (for ([e (in-list ents)] [i (in-naturals)])
         (cond
           [(not (hash? e)) (bad! "entities[~a] is not an object" i)]
           [else
            (unless (str? (hash-ref e 'name #f)) (bad! "entities[~a] has no name" i))
            (unless (str? (hash-ref e 'type #f)) (bad! "entities[~a] has no type" i))
            (define sn (hash-ref e 'snippet #f))
            (cond [(not (str? sn)) (bad! "entities[~a] (~a) has no snippet" i (hash-ref e 'name "?"))]
                  [(not (string-contains? text sn)) (bad! "entities[~a] (~a): snippet is not verbatim from the document" i (hash-ref e 'name "?"))])
            (when (str? (hash-ref e 'name #f)) (hash-set! names (normalize-name (hash-ref e 'name)) #t))])))
     (when (list? rels)
       (for ([r (in-list rels)] [i (in-naturals)])
         (cond
           [(not (hash? r)) (bad! "relations[~a] is not an object" i)]
           [else
            (for ([k '(subject predicate object)])
              (unless (str? (hash-ref r k #f)) (bad! "relations[~a] has no ~a" i k)))
            (when (and (str? (hash-ref r 'subject #f)) (not (hash-ref names (normalize-name (hash-ref r 'subject)) #f)))
              (bad! "relations[~a]: subject ~s is not an entity in this reply" i (hash-ref r 'subject)))
            (when (and (str? (hash-ref r 'object #f)) (not (hash-ref names (normalize-name (hash-ref r 'object)) #f)))
              (bad! "relations[~a]: object ~s is not an entity in this reply" i (hash-ref r 'object)))
            (define sn (hash-ref r 'snippet #f))
            (cond [(not (str? sn)) (bad! "relations[~a] has no snippet" i)]
                  [(not (string-contains? text sn)) (bad! "relations[~a]: snippet is not verbatim from the document" i)])])))
     (reverse problems)]))

;; ---- whole documents: windows, and the merge that makes them one extraction --------------
;; A snippet must be verbatim in the text it was drawn from, so each window is validated
;; against ITS OWN text rather than against the document. That is what keeps validation honest
;; and it is why the merge below has to dedup rather than concatenate: the same organization is
;; named in several windows, with a different snippet each time.

;; split text into windows of at most `n` characters, cutting at a line break when one is far
;; enough into the window and at the full length otherwise, so a window is never empty and the
;; loop always makes progress
(define (window-split text n)
  (define size (max 1 (if (exact-integer? n) n (inexact->exact (truncate n)))))
  (let loop ([s text] [acc '()])
    (cond
      [(<= (string-length s) size) (reverse (cons s acc))]
      [else
       (define head (substring s 0 size))
       (define min-keep (quotient size 2))
       ;; scanning downward, so the FIRST match is the rightmost newline. `for/first` answers #f
       ;; when there is none, which a document with no line breaks at all hits.
       (define nl (for/first ([i (in-range (sub1 (string-length head)) 0 -1)]
                              #:when (char=? (string-ref head i) #\newline))
                     i))
       (define cut (if (and nl (> nl min-keep)) (add1 nl) (string-length head)))
       (loop (substring s cut) (cons (substring s 0 cut) acc))])))

;; one extraction from several: entities dedup on the same key `kg-upsert!` uses, and a relation
;; survives only if both its ends were named, which every per-window validation already made
;; true inside its own window.
(define (merge-extractions xs)
  (define ents (make-hash))          ; name_norm -> entity
  (define ent-order '())
  (define rels (make-hash))          ; subject|predicate|object -> relation
  (define rel-order '())
  (for ([x (in-list xs)])
    (for ([e (in-list (hash-ref x 'entities '()))])
      (define nm (normalize-name (hash-ref e 'name)))
      (cond
        [(hash-ref ents nm #f)
         ;; the first snippet wins because it is the earliest place in the document that names
         ;; the thing, and a longer description wins because it says more
         => (lambda (old)
              (define new-d (hash-ref e 'description ""))
              (when (> (string-length new-d) (string-length (hash-ref old 'description "")))
                (hash-set! ents nm (hash-set old 'description new-d))))]
        [else (hash-set! ents nm e) (set! ent-order (cons nm ent-order))]))
    (for ([r (in-list (hash-ref x 'relations '()))])
      (define k (string-append (normalize-name (hash-ref r 'subject)) "|"
                               (normalize-predicate (hash-ref r 'predicate)) "|"
                               (normalize-name (hash-ref r 'object))))
      (unless (hash-ref rels k #f)
        (hash-set! rels k r)
        (set! rel-order (cons k rel-order)))))
  (hasheq 'entities (for/list ([nm (in-list (reverse ent-order))]) (hash-ref ents nm))
          'relations (for/list ([k (in-list (reverse rel-order))]) (hash-ref rels k))))

;; text -> (values extraction tokens windows truncated?), or raises. Pure of the repository.
;;
;; THE DOCUMENT IS READ WHOLE. It is split into windows of `#:window` characters, each is
;; extracted and validated against itself, and the results are merged into ONE extraction. That
;; one merged value is the same single `kg-upsert!` a one-window document produces, because that
;; write replaces every mention of the object and its version rather than appending. So nothing
;; about the store, the version rule, the mention rule or the supersede rule changes here.
;;
;; `#:max-windows` bounds the cost, and `truncated?` is how a read says it stopped early.
(define (extract-document text
                          #:chat [chat (current-doc-chat)]
                          #:window [window EXTRACT-TEXT-CAP]
                          #:max-windows [max-windows EXTRACT-MAX-WINDOWS]
                          ;; called with each window's tokens AS THEY ARE SPENT, so a refusal on a
                          ;; later window cannot lose what the earlier ones cost. The tree already
                          ;; keeps this rule for translation: a refusal mid-document stores nothing
                          ;; and what was already spent IS recorded.
                          #:meter [meter #f])
  (when (string=? (string-trim text) "") (error 'kg_extract "nothing to extract from — the document has no text"))
  (define all (window-split text window))
  (define kept (if (> (length all) max-windows) (take all max-windows) all))
  (define results '())
  (define tokens 0)
  (for ([w (in-list kept)])
    ;; the cap is the window here, so a window is never itself cut
    (define-values (x t) (extract-knowledge w #:chat chat #:cap (max EXTRACT-TEXT-CAP (string-length w))))
    (when meter (meter t))
    (set! results (cons x results))
    (set! tokens (+ tokens t)))
  (values (merge-extractions (reverse results)) tokens (length kept) (> (length all) (length kept))))

;; one window -> (values extraction tokens), or raises. `#:cap` is the truncation length, which
;; `extract-document` passes as the window so a window is read whole.
(define (extract-knowledge text #:chat [chat (current-doc-chat)] #:cap [cap EXTRACT-TEXT-CAP])
  (when (string=? (string-trim text) "") (error 'kg_extract "nothing to extract from — the document has no text"))
  (define capped (if (> (string-length text) cap) (substring text 0 cap) text))
  (define-values (reply tokens) (chat (jsexpr->string (hasheq 'document capped)) #:system EXTRACT-SYSTEM))
  (define j (outer-json (format "~a" reply)))
  (define problems (validate-extraction j capped))
  (unless (null? problems)
    (error 'kg_extract "extraction refused: ~a" (string-join problems "; ")))
  (values j tokens))

;; a whole document is several model calls, so the request count is the window count and the
;; team's budget sees what it actually spent
(define (meter! conn p tokens [requests 1])
  (for ([_ (in-range (max 1 requests))]) (tenant-quota-record! conn p "ai.requests" 1))
  (tenant-quota-record! conn p "ai.tokens.total" tokens))

(define (list-unextracted conn p args)
  (kg-list-unextracted conn p #:limit LIST-BATCH))

(define (extract-one conn p args)
  (require-perm conn p "chat:use")
  (define id (let ([v (hash-ref args 'object "")]) (if (string? v) v (format "~a" v))))
  ;; AN ID FROM A PLUGIN SOURCE TAKES THIS ARM AND NEVER TOUCHES THE REPOSITORY. Two things are
  ;; ordered deliberately: the readability ask comes BEFORE the model call, so a caller who may
  ;; not read the document cannot spend the team's tokens to be told so afterwards; and a
  ;; source that cannot name a version is a refusal rather than a write, because a
  ;; `kg_extractions` row keyed on a version nothing can compare against would list the
  ;; document for ever.
  (cond
    [(kg-source-id? id)
     (define parts (kg-source-id-split id))
     (define team (principal-team-id p))
     ;; refused and missing are ONE answer, as they are for a repository document (KG-3)
     (define seen (and parts (source-see (car parts) conn p team (cdr parts))))
     (unless seen (error 'kg_extract "no such document: ~a" id))
     (define v (source-version (car parts) conn p team (cdr parts)))
     (unless v (error 'kg_extract "~a: the source cannot name this document's version" (car parts)))
     (define stext (or (source-text (car parts) conn p team (cdr parts)) ""))
     (cond
       [(string=? (string-trim stext) "")
        (kg-mark-extracted! conn team id v 0 0)
        (format "skipped ~a — the source returned no text for this version" (hash-ref seen 'key))]
       [else
        ;; the source may say how much goes into one model call; the document is still read
        ;; WHOLE, in windows of that size, because a document longer than one window used to be
        ;; cut and the facts past the cut never entered the graph
        (define window (source-window (car parts) conn p team (cdr parts) EXTRACT-TEXT-CAP))
        (define-values (extraction tokens windows truncated?)
          (parameterize ([current-utility-executor (model-role-executor conn team "utility")])
            (extract-document stext #:window window #:meter (lambda (t) (meter! conn p t)))))
        (kg-upsert! conn team id v extraction)
        (hasheq 'object_id id 'key (hash-ref seen 'key)
                'entities (length (hash-ref extraction 'entities '()))
                'relations (length (hash-ref extraction 'relations '()))
                'tokens_used tokens
                'windows windows
                'text_truncated truncated?)])]
    [else (extract-one-repo conn p id)]))

;; the repository arm, split out so the source arm is not two hundred lines of nesting. It is not
;; exported and its caller `extract-one` asks for `chat:use` before either arm runs, so this is
;; reached only by a caller that has already passed the permission.
(define (extract-one-repo conn p id)
  (define o (repo-get conn p id))
  (unless o (error 'kg_extract "no such document: ~a" id))
  (define text (let ([t (repo-text-for conn id)]) (if (or (not t) (sql-null? t)) "" t)))
  (cond
    ;; the indexing rule, kept: a document with no text records "nothing here" and
    ;; never wedges the run — the next run will not list it again for this version
    [(string=? (string-trim text) "")
     (kg-mark-extracted! conn (hash-ref o 'team_id) id (hash-ref o 'version_id) 0 0)
     (format "skipped ~a — no extracted text (run index-documents first)" (hash-ref o 'key))]
    [else
     ;; the repository arm reads a long document whole too, for the same reason and with the
     ;; same bound
     (define-values (extraction tokens windows truncated?)
       (parameterize ([current-utility-executor (model-role-executor conn (hash-ref o 'team_id) "utility")])   ; KG-7
         (extract-document text #:meter (lambda (t) (meter! conn p t)))))
     (kg-upsert! conn (hash-ref o 'team_id) id (hash-ref o 'version_id) extraction)
     (hasheq 'object_id id 'key (hash-ref o 'key)
             'entities (length (hash-ref extraction 'entities '()))
             'relations (length (hash-ref extraction 'relations '()))
             'tokens_used tokens
             'windows windows
             'text_truncated truncated?)]))

;; the agent's answer: plain text with citations, because that is what a model
;; can read back and what a person can check
(define (query conn p args)
  (define name (let ([v (hash-ref args 'name "")]) (if (string? v) v (format "~a" v))))
  (define hops (let ([h (hash-ref args 'hops 1)]) (if (and (number? h) (>= h 1)) (min 2 (inexact->exact (floor h))) 1)))
  (define type (let ([v (hash-ref args 'type #f)]) (and (string? v) (not (string=? v "")) v)))
  (define start
    (or (kg-entity conn p name)
        (let ([found (kg-find conn p name #:type type #:limit 1)]) (and (pair? found) (kg-entity conn p (hash-ref (car found) 'id))))))
  (cond
    [(not start) (format "Nothing in the team's documents mentions ~s." name)]
    [else
     (define hood (kg-neighbourhood conn p (hash-ref start 'id) #:hops hops))
     (define out (open-output-string))
     (for ([e (in-list hood)])
       (fprintf out "~a (~a)~a\n" (hash-ref e 'name) (hash-ref e 'type)
                (let ([d (hash-ref e 'description)]) (if (string=? d "") "" (string-append ": " d))))
       (for ([r (in-list (hash-ref e 'relations))])
         (fprintf out "  - ~a ~a ~a  [~a]\n" (hash-ref r 'subject) (hash-ref r 'predicate) (hash-ref r 'object)
                  (string-join (remove-duplicates (map (lambda (m) (hash-ref m 'key)) (hash-ref r 'mentions))) ", ")))
       (for ([m (in-list (hash-ref e 'mentions))])
         (fprintf out "  · ~a: \"~a\"\n" (hash-ref m 'key) (hash-ref m 'snippet))))
     (get-output-string out)]))

;; A DRAIN LISTER AND ITS MAP CHILD ARE WORKFLOW TOOLS (registry.rkt's `agent?`):
;; `index-knowledge` pages ids out of one and fans the other over them. Neither is
;; something a person asks for in a sentence. `kg_query` IS conversational and stays.
(register-tool! "kg_list_unextracted" kg_list_unextracted "files:read" list-unextracted
                #:agent? #f)
(register-tool! "kg_extract" kg_extract "files:read" extract-one #:agent? #f)
(register-tool! "kg_query" kg_query "files:read" query)
