#lang racket/base

;; server/api/content.rkt — notes, documents, search and the knowledge graph
;;
;; Split out of main.rkt by #110 r3. The shared surface every handler here
;; needs — the pool, the request accessors, with-auth/with-mt, the response
;; constructors — is server/kit.rkt.

(provide ep-notes-create ep-notes-list ep-documents-create ep-documents-list
         ep-documents-get ep-documents-update ep-documents-delete
         ep-notes-get ep-notes-update ep-notes-delete ep-notes-share
         ep-search ep-kg-entities ep-kg-entity ep-kg-extract)

(require racket/string
         web-kit
         (only-in "../../config.rkt" content-encryption-enabled?)
         (only-in "../../domain/notes/notes.rkt" notes-create notes-delete notes-get notes-list notes-share notes-update)
         (only-in "../../domain/documents/documents.rkt" documents-create documents-delete documents-get documents-list documents-update)
         (only-in "../../domain/apps/search.rkt" search-all search-passages)
         (only-in "../../domain/kg/kg.rkt" STARTER-TYPES kg-entity kg-find kg-stats)
         (only-in "../../domain/flow/run.rkt" flow-def-by-slug flow-run-start!)
         (only-in "../../domain/i18n/i18n.rkt" t)
         "../kit.rkt")

;; ---- notes (ownable/shareable resource) -------------------------------------
(define (ep-notes-create req)
  (with-auth req (lambda (p)
    (define b (read-json-body req))
    (json-response (notes-create db-conn p #:title (hash-ref b 'title "")
                                 #:body (hash-ref b 'body "") #:visibility (hash-ref b 'visibility "team"))
                   #:code 201))))

(define (ep-notes-list req)
  (with-auth req (lambda (p) (json-response (hasheq 'notes (notes-list db-conn p #:scope (scope-of req)))))))

;; ---- documents (offset-paginated) -------------------------------------------
(define (ep-documents-create req)
  (with-auth req (lambda (p)
    (define b (read-json-body req))
    (json-response (documents-create db-conn p #:title (hash-ref b 'title "")
                                     #:content (hash-ref b 'content "") #:visibility (hash-ref b 'visibility "team"))
                   #:code 201))))
(define (ep-documents-list req)
  (with-auth req (lambda (p)
    (define off (or (string->number (query-param req 'offset "0")) 0))
    (json-response (documents-list db-conn p #:offset off)))))
(define (ep-documents-get req id)
  (with-auth req (lambda (p)
    (define d (documents-get db-conn p id))
    (if d (json-response d) (err "not found" 404)))))
(define (ep-documents-update req id)
  (with-auth req (lambda (p)
    (define b (read-json-body req))
    (define d (documents-update db-conn p id #:title (hash-ref b 'title #f)
                                #:content (hash-ref b 'content #f) #:visibility (hash-ref b 'visibility #f)))
    (if d (json-response d) (err "not found" 404)))))
(define (ep-documents-delete req id)
  (with-auth req (lambda (p)
    (if (documents-delete db-conn p id) (json-response (hasheq 'ok #t 'id id)) (err "not found" 404)))))

(define (ep-notes-get req id)
  (with-auth req (lambda (p)
    (define n (notes-get db-conn p id))
    (if n (json-response n) (err "not found" 404)))))

(define (ep-notes-update req id)
  (with-auth req (lambda (p)
    (define b (read-json-body req))
    (define n (notes-update db-conn p id #:title (hash-ref b 'title #f)
                            #:body (hash-ref b 'body #f) #:visibility (hash-ref b 'visibility #f)))
    (if n (json-response n) (err "not found" 404)))))

(define (ep-notes-delete req id)
  (with-auth req (lambda (p)
    (if (notes-delete db-conn p id) (json-response (hasheq 'deleted #t)) (err "not found" 404)))))

(define (ep-notes-share req id)
  (with-auth req (lambda (p)
    (define b (read-json-body req))
    (define target (hash-ref b 'user_id #f))
    (cond
      [(not target) (err "user_id required" 400)]
      [(notes-share db-conn p id #:user target #:permission (hash-ref b 'permission "notes:read"))
       (json-response (hasheq 'shared #t))]
      [else (err "not found" 404)]))))

(define (ep-search req)
  (with-auth req (lambda (p)
    (require-feature p "search")
    (define q (string-trim (query-param req 'q)))
    ;; `content_search` says whether document TEXT is being matched (issue #83).
    ;; With the extracted text sealed it cannot be, and a search that quietly
    ;; stopped looking inside documents would read as "we have no such document"
    ;; — the caller must be able to tell the two apart. Reported on every reply,
    ;; not only when off, so a client can branch on it without guessing.
    (define content? (not (content-encryption-enabled?)))
    ;; `?semantic=1` adds passages found by MEANING (#189 step 6). OFF by default
    ;; and that is not timidity: embedding the question is a model request, so
    ;; asking spends the team's `ai.requests` and `ai.embeddings.total`, where
    ;; every other kind of search here costs a `LIKE`. An opt-in flag is also what
    ;; keeps the console's existing search exactly as cheap as it was.
    ;;
    ;; `semantic` is reported on every reply that asked, and `semantic_reason`
    ;; only when it was asked and did not run — never when it ran and matched
    ;; nothing. **The semantic half is the first content search that survives
    ;; `TMACH_ENCRYPT_CONTENT`**: it compares vectors and reads the text back
    ;; through `repo-text-for`, which unseals, so on a sealed instance
    ;; `content_search` is false and this can still be true.
    (define semantic? (member (string-downcase (query-param req 'semantic)) '("1" "true" "yes")))
    (if (< (string-length q) 2)
         (json-response (hasheq 'query q 'results '() 'content_search content?))
         (let-values ([(passages reason)
                       (if semantic?
                           (search-passages db-conn p q)
                           (values '() #f))])
           (json-response
            (let ([base (hasheq 'query q 'content_search content?
                                'results (append passages
                                                 (search-all db-conn p q #:scope (scope-of req))))])
              (cond
                [(not semantic?) base]
                [reason (hash-set (hash-set base 'semantic #f) 'semantic_reason reason)]
                [else (hash-set base 'semantic #t)]))))))))

;; ---- knowledge graph (slice 61) --------------------------------------------------
;; Every read applies the mention rule inside domain/kg: an entity the caller can
;; see no mention of does not exist for them. Extraction is the index-knowledge
;; workflow, queued like any run.
(define (ep-kg-entities req)
  (with-auth req (lambda (p)
    (define q (query-param req 'q ""))
    (define type (let ([t (query-param req 'type "")]) (and (not (string=? t "")) t)))
    (json-response (hasheq 'entities (kg-find db-conn p q #:type type)
                           'stats (kg-stats db-conn p)
                           'types STARTER-TYPES)))))

(define (ep-kg-entity req id)
  (with-auth req (lambda (p)
    (define e (kg-entity db-conn p id))
    (if e (json-response e) (err "not found" 404)))))

(define (ep-kg-extract req)
  (with-auth req (lambda (p)
    (require-feature p "workflows")
    (define d (flow-def-by-slug db-conn p "index-knowledge"))
    (cond
      [(not d) (err "the knowledge-graph plugin is not loaded" 404)]
      [else (json-response (flow-run-start! db-conn p d) #:code 202)]))))
