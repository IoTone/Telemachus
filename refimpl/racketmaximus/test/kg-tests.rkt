#lang racket/base

;; test/kg-tests.rkt — slice 61: the knowledge graph.
;;   raco test test/kg-tests.rkt
;;
;; What this has to prove:
;;   1. the MENTION RULE (KG-3): a fact is visible iff one of its mentions is on a
;;      document the caller can read, and a private document's snippet stays private
;;   2. extraction is REFUSED unless it validates — a snippet that is not verbatim,
;;      a relation to an entity not in the reply, a nameless entity
;;   3. a new version supersedes; deleting a document forgets its facts; orphans are pruned
;;   4. the whole pipeline through the engine: index -> index-knowledge -> search/query
;;   5. dedup by (type, normalized name)

(require rackunit db-kit/portable
         racket/port racket/string racket/file racket/list
         json
         db-kit/migrate
         "../domain/db/migrations.rkt"
         "db-fixture.rkt"
         "../domain/authz/authz.rkt"
         "../domain/repo/blobs.rkt"
         "../domain/repo/repo.rkt"
         "../domain/repo/extract.rkt"
         "../domain/repo/doc-tools.rkt"          ; current-doc-chat
         (only-in "../domain/repo/index-tools.rkt")   ; registers the indexing tools
         "../domain/kg/kg.rkt"
         "../domain/kg/kg-tools.rkt"
         "../domain/apps/search.rkt"
         "../domain/agent/registry.rkt"
         "../domain/agent/tools.rkt"
         "../domain/sched/scheduler.rkt"
         "../domain/flow/run.rkt"
         (prefix-in indexer: "../plugins/doc-indexer/main.rkt")
         (prefix-in kgp: "../plugins/knowledge-graph/main.rkt"))

(define BLOB-ROOT (make-temporary-file "telemachus-kg-blobs-~a" 'directory))
(current-blob-root BLOB-ROOT)

(define (fresh)
  (define conn (fresh-db #:migrate? #f))
  (migrate! conn all-migrations)
  conn)
(define (drain! conn [limit 300])
  (let loop ([n 0]) (when (and (< n limit) (process-one! conn)) (loop (add1 n)))))

(test-case "normalization: names dedup across case, whitespace and suffixes; predicates snake"
  (check-equal? (normalize-name "  Acme   Robotics Inc. ") "acme robotics")
  (check-equal? (normalize-name "ACME ROBOTICS") "acme robotics")
  (check-equal? (normalize-name "Inc") "inc" "a lone suffix is a name, not a suffix")
  (check-equal? (normalize-predicate "Works At") "works_at")
  (check-equal? (normalize-predicate " customer-of ") "customer_of"))

(define TEXT "Acme Robotics hired Ada Lovelace as chief engineer in 2026. Acme Robotics is a customer of Globex Media.")

(define (extraction #:entities [ents #f] #:relations [rels #f])
  (hasheq 'entities (or ents (list (hasheq 'type "organization" 'name "Acme Robotics" 'description "a robotics company" 'snippet "Acme Robotics hired Ada Lovelace")
                                   (hasheq 'type "person" 'name "Ada Lovelace" 'description "" 'snippet "Ada Lovelace as chief engineer")
                                   (hasheq 'type "organization" 'name "Globex Media" 'description "" 'snippet "customer of Globex Media")))
          'relations (or rels (list (hasheq 'subject "Ada Lovelace" 'predicate "works_at" 'object "Acme Robotics" 'snippet "hired Ada Lovelace as chief engineer")
                                    (hasheq 'subject "Acme Robotics" 'predicate "customer_of" 'object "Globex Media" 'snippet "is a customer of Globex Media")))))

(test-case "validation refuses what does not validate, and provenance is the snippet"
  (check-equal? (validate-extraction (extraction) TEXT) '())
  (check-match (validate-extraction "nope" TEXT) (list _))
  (check-match (validate-extraction (extraction #:entities (list (hasheq 'type "person" 'name "" 'snippet "Ada"))) TEXT)
               (list (regexp #rx"no name") _ ...))
  (check-match (validate-extraction (extraction #:entities (list (hasheq 'type "person" 'name "Ada Lovelace" 'snippet "Ada was hired in 2025"))) TEXT)
               (list (regexp #rx"not verbatim") _ ...))
  (check-match (validate-extraction (extraction #:relations (list (hasheq 'subject "Ada Lovelace" 'predicate "works_at" 'object "Initech" 'snippet "Acme Robotics"))) TEXT)
               (list (regexp #rx"object \"Initech\" is not an entity")))
  (check-match (validate-extraction (hasheq 'relations '()) TEXT) (list (regexp #rx"entities must be an array")))
  ;; through the model seam: a reply wrapped in prose still parses; garbage is refused
  (let-values ([(x tokens) (extract-knowledge TEXT #:chat (lambda (p #:system [s #f]) (values (string-append "Sure:\n" (jsexpr->string (extraction))) 9)))])
    (check-equal? (length (hash-ref x 'entities)) 3)
    (check-equal? tokens 9))
  (check-exn #rx"extraction refused" (lambda () (extract-knowledge TEXT #:chat (lambda (p #:system [s #f]) (values "I found nothing" 1)))))
  (check-exn #rx"extraction refused: .*not verbatim"
             (lambda () (extract-knowledge TEXT #:chat (lambda (p #:system [s #f])
                                                          (values (jsexpr->string (extraction #:entities (list (hasheq 'type "person" 'name "Ada Lovelace" 'snippet "made up")))) 1)))))
  (check-exn #rx"no model configured" (lambda () (extract-knowledge TEXT))))

(test-case "the mention rule, supersession, forgetting, dedup"
  (define conn (fresh))
  (define-values (uid tid) (bootstrap! conn #:username "alice"))
  (define alice (user-principal conn uid tid))
  (define bob-id (create-user! conn #:username "bob" #:password "pw"))
  (add-member! conn #:user bob-id #:team tid #:role "member")
  (define bob (user-principal conn bob-id tid))
  (define (up! p key text #:vis [vis "team"])
    (repo-put! conn p #:key key #:port (open-input-bytes (string->bytes/utf-8 text)) #:content-type "text/plain" #:filename key #:visibility vis))

  ;; a PRIVATE memo (alice's) and a TEAM report both mention Acme; only the memo mentions the salary
  (define memo (up! alice "hr/memo.txt" "Acme Robotics pays Ada Lovelace 90000." #:vis "private"))
  (define report (up! alice "reports/q3.txt" TEXT))
  (kg-upsert! conn tid (hash-ref memo 'id) (hash-ref memo 'version_id)
              (hasheq 'entities (list (hasheq 'type "organization" 'name "ACME robotics inc" 'snippet "Acme Robotics pays")
                                      (hasheq 'type "person" 'name "Ada Lovelace" 'snippet "Ada Lovelace 90000")
                                      (hasheq 'type "concept" 'name "Salary band" 'snippet "pays Ada Lovelace 90000"))
                      'relations (list (hasheq 'subject "Ada Lovelace" 'predicate "paid_by" 'object "ACME robotics inc" 'snippet "pays Ada Lovelace"))))
  (kg-upsert! conn tid (hash-ref report 'id) (hash-ref report 'version_id) (extraction))

  ;; dedup: "ACME robotics inc" and "Acme Robotics" are ONE organization
  (define acme (kg-find conn alice "acme"))
  (check-equal? (length acme) 1 "one Acme, whatever the spelling")
  (check-equal? (hash-ref (car acme) 'name) "ACME robotics inc" "the first spelling seen is the display name")
  (check-equal? (hash-ref (car acme) 'mention_count) 2)
  (define acme-id (hash-ref (car acme) 'id))

  ;; alice sees both mentions; bob sees only the report's (KG-3, per row)
  (define ea (kg-entity conn alice acme-id))
  (define eb (kg-entity conn bob acme-id))
  (check-equal? (length (hash-ref ea 'mentions)) 2)
  (check-equal? (length (hash-ref eb 'mentions)) 1 "bob does not see the private memo's mention")
  (check-equal? (hash-ref (car (hash-ref eb 'mentions)) 'key) "reports/q3.txt")
  ;; the relation asserted ONLY by the memo is invisible to bob; the report's relations are not
  (check-equal? (sort (map (lambda (r) (hash-ref r 'predicate)) (hash-ref ea 'relations)) string<?) '("customer_of" "paid_by" "works_at"))
  (check-equal? (sort (map (lambda (r) (hash-ref r 'predicate)) (hash-ref eb 'relations)) string<?) '("customer_of" "works_at")
                "a relation stated only in a private document is not shown to a colleague")
  ;; an entity mentioned ONLY in the private memo does not exist for bob
  (define salary (kg-find conn alice "salary"))
  (check-equal? (length salary) 1)
  (check-false (kg-entity conn bob (hash-ref (car salary) 'id)) "no readable mention — as if it were not there")
  (check-equal? (kg-find conn bob "salary") '())
  ;; search surfaces entities under the same rule
  (check-true (for/or ([h (in-list (search-all conn bob "acme"))]) (equal? (hash-ref h 'type) "entity")))
  (check-false (for/or ([h (in-list (search-all conn bob "salary"))]) (equal? (hash-ref h 'type) "entity")))
  (check-true (for/or ([h (in-list (search-all conn alice "salary"))]) (equal? (hash-ref h 'type) "entity")))

  ;; the neighbourhood, with citations
  (define hood (kg-neighbourhood conn bob acme-id #:hops 1))
  (check-equal? (sort (map (lambda (e) (hash-ref e 'name)) hood) string<?) '("ACME robotics inc" "Ada Lovelace" "Globex Media"))
  (define q ((tool-handler (tool-by-name "kg_query")) conn bob (hasheq 'name "acme robotics" 'hops 1)))
  (check-true (regexp-match? #rx"Ada Lovelace works_at ACME robotics inc  \\[reports/q3.txt\\]" q) "the agent's answer cites the document")
  (check-false (regexp-match? #rx"paid_by" q) "…and never a fact bob cannot read")
  (check-true (regexp-match? #rx"Nothing in the team's documents mentions" ((tool-handler (tool-by-name "kg_query")) conn bob (hasheq 'name "zeppelin"))))

  ;; a new VERSION supersedes: the report no longer mentions Globex
  (define report2 (up! alice "reports/q3.txt" "Acme Robotics hired Ada Lovelace as chief engineer."))
  (kg-upsert! conn tid (hash-ref report2 'id) (hash-ref report2 'version_id)
              (hasheq 'entities (list (hasheq 'type "organization" 'name "Acme Robotics" 'snippet "Acme Robotics hired")
                                      (hasheq 'type "person" 'name "Ada Lovelace" 'snippet "Ada Lovelace as chief engineer"))
                      'relations (list (hasheq 'subject "Ada Lovelace" 'predicate "works_at" 'object "Acme Robotics" 'snippet "hired Ada Lovelace"))))
  (check-equal? (kg-find conn alice "globex") '() "an entity the current documents no longer mention is pruned")
  (check-equal? (sort (map (lambda (r) (hash-ref r 'predicate)) (hash-ref (kg-entity conn alice acme-id) 'relations)) string<?)
                '("paid_by" "works_at"))
  ;; unextracted: the report's new version has no repo_text yet, so it is not listed; index it and it is
  (check-equal? (kg-list-unextracted conn alice) '())
  (repo-text-upsert! conn (hash-ref report2 'id) (hash-ref report2 'version_id) "fresh text")
  (check-equal? (kg-list-unextracted conn alice) '() "already extracted for this version")
  (define third (up! alice "notes/third.txt" "Initech ships widgets."))
  (repo-text-upsert! conn (hash-ref third 'id) (hash-ref third 'version_id) "Initech ships widgets.")
  (check-equal? (kg-list-unextracted conn alice) (list (hash-ref third 'id)) "indexed but not extracted")

  ;; deleting the memo forgets its facts: the salary band goes, the paid_by relation goes, Acme stays
  (repo-delete! conn alice (hash-ref memo 'id))
  (check-equal? (kg-find conn alice "salary") '())
  (check-equal? (map (lambda (r) (hash-ref r 'predicate)) (hash-ref (kg-entity conn alice acme-id) 'relations)) '("works_at"))
  (check-equal? (length (hash-ref (kg-entity conn alice acme-id) 'mentions)) 1)
  (disconnect conn))

(test-case "the pipeline: index-documents, then index-knowledge through the engine, with a scripted model"
  (define conn (fresh))
  (define-values (uid tid) (bootstrap! conn #:username "alice"))
  (define alice (user-principal conn uid tid))
  (register-plugin-workflow! "doc-indexer" (car indexer:workflows))
  (register-plugin-workflow! "knowledge-graph" (car kgp:workflows))
  (repo-put! conn alice #:key "reports/q3.md" #:port (open-input-bytes (string->bytes/utf-8 TEXT)) #:content-type "text/markdown" #:filename "q3.md")
  (repo-put! conn alice #:key "img/logo.png" #:port (open-input-bytes #"\x89PNG") #:content-type "image/png" #:filename "logo.png")
  (define calls (box 0))
  (define (chat prompt #:system [sys #f])
    (set-box! calls (add1 (unbox calls)))
    (values (jsexpr->string (extraction)) 21))
  ;; nothing to extract before indexing: kg_extract needs repo_text
  (define kgdef (flow-def-by-slug conn alice "index-knowledge"))
  (check-true (and kgdef #t))
  (define r0 (parameterize ([current-doc-chat chat]) (define r (flow-run-start! conn alice kgdef)) (drain! conn) (flow-run-get conn alice (hash-ref r 'id))))
  (check-equal? (hash-ref r0 'status) "done")
  (check-equal? (unbox calls) 0 "unindexed documents are not even attempted")
  ;; index, then extract
  (define idx (flow-run-start! conn alice (flow-def-by-slug conn alice "index-documents")))
  (drain! conn)
  (define r1 (parameterize ([current-doc-chat chat]) (define r (flow-run-start! conn alice kgdef)) (drain! conn) (flow-run-get conn alice (hash-ref r 'id))))
  (check-equal? (hash-ref r1 'status) "done" (format "(error: ~a)" (hash-ref r1 'error)))
  (check-equal? (unbox calls) 1 "one model call for the one text document; the image never reached the model")
  (check-equal? (length (kg-find conn alice "")) 3 "three entities")
  (check-equal? (hash-ref (kg-stats conn alice) 'relations) 2)
  ;; idempotent: a second run finds nothing
  (define r2 (parameterize ([current-doc-chat chat]) (define r (flow-run-start! conn alice kgdef)) (drain! conn) (flow-run-get conn alice (hash-ref r 'id))))
  (check-equal? (hash-ref r2 'status) "done")
  (check-equal? (unbox calls) 1 "nothing new, no model call")
  ;; a refused reply fails the step (after one retry) and stores nothing for that document
  (repo-put! conn alice #:key "reports/q4.md" #:port (open-input-bytes #"Q4: Initech bought Acme.") #:content-type "text/markdown" #:filename "q4.md")
  (flow-run-start! conn alice (flow-def-by-slug conn alice "index-documents")) (drain! conn)
  (define bad-calls (box 0))
  (define r3 (parameterize ([current-doc-chat (lambda (p #:system [s #f]) (set-box! bad-calls (add1 (unbox bad-calls))) (values "{\"entities\":[{\"type\":\"organization\",\"name\":\"Initech\",\"snippet\":\"never said\"}],\"relations\":[]}" 1))])
               (define r (flow-run-start! conn alice kgdef)) (drain! conn) (flow-run-get conn alice (hash-ref r 'id))))
  (check-equal? (hash-ref r3 'status) "error")
  (check-true (regexp-match? #rx"not verbatim" (hash-ref r3 'error)))
  (check-equal? (unbox bad-calls) 2 "retried once")
  (check-equal? (kg-find conn alice "initech") '() "nothing was stored from the refused reply")
  (disconnect conn))
