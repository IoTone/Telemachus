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
         "kg.rkt")

(provide validate-extraction extract-knowledge LIST-BATCH EXTRACT-TEXT-CAP)

(define LIST-BATCH 40)
;; a 7B model's window; the first ~12k characters of a document carry its named things
(define EXTRACT-TEXT-CAP 12000)

(define-tool kg_list_unextracted
  #:description "List repository documents whose text has not been extracted into the knowledge graph yet (or is stale after an overwrite). Returns object ids, capped at a batch; run the index-knowledge workflow again to continue.")

(define-tool kg_extract
  #:description "Extract entities (people, organizations, products, places, events, concepts) and the relations between them from one repository document into the knowledge graph, every mention with a verbatim snippet. Refuses a reply that does not validate."
  (object string #:description "The repository object id"))

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

;; text -> (values extraction tokens), or raises. Pure of the repository.
(define (extract-knowledge text #:chat [chat (current-doc-chat)])
  (when (string=? (string-trim text) "") (error 'kg_extract "nothing to extract from — the document has no text"))
  (define capped (if (> (string-length text) EXTRACT-TEXT-CAP) (substring text 0 EXTRACT-TEXT-CAP) text))
  (define-values (reply tokens) (chat (jsexpr->string (hasheq 'document capped)) #:system EXTRACT-SYSTEM))
  (define j (outer-json (format "~a" reply)))
  (define problems (validate-extraction j capped))
  (unless (null? problems)
    (error 'kg_extract "extraction refused: ~a" (string-join problems "; ")))
  (values j tokens))

(define (meter! conn p tokens)
  (tenant-quota-record! conn p "ai.requests" 1)
  (tenant-quota-record! conn p "ai.tokens.total" tokens))

(define (list-unextracted conn p args)
  (kg-list-unextracted conn p #:limit LIST-BATCH))

(define (extract-one conn p args)
  (require-perm conn p "chat:use")
  (define id (let ([v (hash-ref args 'object "")]) (if (string? v) v (format "~a" v))))
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
     (define-values (extraction tokens) (extract-knowledge text))
     (meter! conn p tokens)
     (kg-upsert! conn (hash-ref o 'team_id) id (hash-ref o 'version_id) extraction)
     (hasheq 'object_id id 'key (hash-ref o 'key)
             'entities (length (hash-ref extraction 'entities '()))
             'relations (length (hash-ref extraction 'relations '()))
             'tokens_used tokens)]))

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

(register-tool! "kg_list_unextracted" kg_list_unextracted "files:read" list-unextracted)
(register-tool! "kg_extract" kg_extract "files:read" extract-one)
(register-tool! "kg_query" kg_query "files:read" query)
