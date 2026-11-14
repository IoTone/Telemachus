#lang racket/base

;; test/research-graph-tests.rkt — #191 slice 3: what an archived page told the
;; knowledge graph, and a neighbourhood a drawing can be made from.
;;
;;   raco test test/research-graph-tests.rkt
;;
;; Two reads, `kg-entities-on` and `kg-graph`, and both are about the mention
;; rule (KG-3) holding at a new door:
;;   1. a document's entities are shown only to somebody who may READ that
;;      document, and "cannot read" and "does not exist" are one answer;
;;   2. `extracted` separates "nothing found" from "not read yet";
;;   3. the graph draws a node or an edge only under the mention rule — a
;;      relation stated only in a colleague's private document is not drawn;
;;   4. the node order is deterministic (name order), so a cap drops the same
;;      nodes on every instance and says it did;
;;   5. `hops` is clamped to 1..2.

(require rackunit db-kit/portable
         racket/file racket/list
         db-kit/migrate
         "../domain/db/migrations.rkt"
         "db-fixture.rkt"
         "../domain/authz/authz.rkt"
         "../domain/repo/blobs.rkt"
         "../domain/repo/repo.rkt"
         "../domain/kg/kg.rkt")

(define BLOB-ROOT (make-temporary-file "telemachus-rgraph-~a" 'directory))
(current-blob-root BLOB-ROOT)

(define (fresh)
  (define c (fresh-db #:migrate? #f))
  (migrate! c all-migrations)
  c)

;; alice (the operator, owner) and bob (a plain member) on one team
(define (world)
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice"))
  (define alice (user-principal c uid tid))
  (define bob-id (create-user! c #:username "bob" #:password "pw"))
  (add-member! c #:user bob-id #:team tid #:role "member")
  (define bob (user-principal c bob-id tid))
  (define (up! p key text #:vis [vis "team"])
    (repo-put! c p #:key key #:port (open-input-bytes (string->bytes/utf-8 text))
               #:content-type "text/plain" #:filename key #:visibility vis))
  (values c tid alice bob up!))

(define (ent type name snippet) (hasheq 'type type 'name name 'description "" 'snippet snippet))
(define (rel s p o snippet) (hasheq 'subject s 'predicate p 'object o 'snippet snippet))
(define (names g) (map (lambda (n) (hash-ref n 'name)) (hash-ref g 'nodes)))
(define (preds g) (sort (map (lambda (e) (hash-ref e 'predicate)) (hash-ref g 'edges)) string<?))

(test-case "a page's entities are shown to whoever may read the page, and to nobody else"
  (define-values (c tid alice bob up!) (world))
  (define page (up! alice "research/example.com/levee-7.html" "Acme inspected Levee 7 for the Port"))
  (define memo (up! alice "hr/memo.txt" "Acme pays Ada" #:vis "private"))
  (kg-upsert! c tid (hash-ref page 'id) (hash-ref page 'version_id)
              (hasheq 'entities (list (ent "organization" "Port Authority" "for the Port")
                                      (ent "organization" "Acme" "Acme inspected")
                                      (ent "place" "Levee 7" "Levee 7"))
                      'relations '()))
  (kg-upsert! c tid (hash-ref memo 'id) (hash-ref memo 'version_id)
              (hasheq 'entities (list (ent "person" "Ada" "pays Ada")) 'relations '()))

  (define a (kg-entities-on c alice (hash-ref page 'id)))
  (check-equal? (map (lambda (e) (hash-ref e 'name)) (hash-ref a 'entities))
                '("Acme" "Levee 7" "Port Authority") "every entity on the page, in name order")
  (check-equal? (hash-ref (car (hash-ref a 'entities)) 'mention_count) 1)
  (check-equal? (hash-ref (kg-entities-on c bob (hash-ref page 'id)) 'entities)
                (hash-ref a 'entities) "a team-visible page shows a colleague the same")

  ;; the private memo: alice sees Ada, bob is told nothing — and nothing is the
  ;; SAME answer as an id that never existed, so this is not an existence oracle
  (check-equal? (map (lambda (e) (hash-ref e 'name)) (hash-ref (kg-entities-on c alice (hash-ref memo 'id)) 'entities))
                '("Ada"))
  (check-false (kg-entities-on c bob (hash-ref memo 'id)) "a page bob cannot read says nothing to him")
  (check-false (kg-entities-on c bob "no-such-object") "…exactly as a page that does not exist"))

(test-case "`extracted` separates nothing-found from not-read-yet, and follows the CURRENT version"
  (define-values (c tid alice bob up!) (world))
  (define page (up! alice "research/example.com/a.html" "nothing of note"))
  (define r0 (kg-entities-on c alice (hash-ref page 'id)))
  (check-equal? (hash-ref r0 'entities) '())
  (check-false (hash-ref r0 'extracted) "not read yet: the remedy is to run Index Knowledge")
  (kg-mark-extracted! c tid (hash-ref page 'id) (hash-ref page 'version_id) 0 0)
  (check-true (hash-ref (kg-entities-on c alice (hash-ref page 'id)) 'extracted)
              "read, and nothing in it: an empty list that means what it says")
  ;; a re-fetch is a new version of the same key, and that version is unread
  (define v2 (up! alice "research/example.com/a.html" "something new"))
  (check-equal? (hash-ref v2 'id) (hash-ref page 'id) "the same object")
  (check-false (hash-ref (kg-entities-on c alice (hash-ref page 'id)) 'extracted)
               "the marker was for the old version, so the new one is unread"))

(test-case "the graph draws only what the caller has a readable mention of"
  (define-values (c tid alice bob up!) (world))
  (define report (up! alice "reports/q3.txt" "report"))
  (define memo (up! alice "hr/memo.txt" "memo" #:vis "private"))
  (kg-upsert! c tid (hash-ref report 'id) (hash-ref report 'version_id)
              (hasheq 'entities (list (ent "organization" "Acme" "a") (ent "person" "Ada" "b")
                                      (ent "organization" "Globex" "c"))
                      'relations (list (rel "Ada" "works_at" "Acme" "s1")
                                       (rel "Acme" "customer_of" "Globex" "s2"))))
  (kg-upsert! c tid (hash-ref memo 'id) (hash-ref memo 'version_id)
              (hasheq 'entities (list (ent "organization" "Acme" "a") (ent "person" "Ada" "b")
                                      (ent "concept" "Salary band" "d"))
                      'relations (list (rel "Ada" "paid_by" "Acme" "s3")
                                       (rel "Acme" "sets" "Salary band" "s4"))))
  (define acme (hash-ref (car (kg-find c alice "acme")) 'id))

  (define ga (kg-graph c alice acme))
  (check-equal? (names ga) '("Acme" "Ada" "Globex" "Salary band")
                "the focus first, then its neighbours in name order")
  (check-true (hash-ref (car (hash-ref ga 'nodes)) 'focus))
  (check-equal? (preds ga) '("customer_of" "paid_by" "sets" "works_at"))

  (define gb (kg-graph c bob acme))
  (check-equal? (names gb) '("Acme" "Ada" "Globex")
                "an entity only a private document mentions is not drawn for a colleague")
  (check-equal? (preds gb) '("customer_of" "works_at")
                "…nor a relation only a private document states, even between two visible nodes")
  (for ([e (in-list (hash-ref gb 'edges))])
    (check-true (and (member (hash-ref e 'from) (map (lambda (n) (hash-ref n 'id)) (hash-ref gb 'nodes))) #t))
    (check-true (and (member (hash-ref e 'to) (map (lambda (n) (hash-ref n 'id)) (hash-ref gb 'nodes))) #t)))

  (define salary (hash-ref (car (kg-find c alice "salary")) 'id))
  (check-false (kg-graph c bob salary) "an entity bob has no readable mention of is a miss")
  (check-false (kg-graph c bob "no-such-entity") "…the same answer as one that does not exist"))

(test-case "the walk is bounded, deterministic, and says when it stopped"
  (define-values (c tid alice bob up!) (world))
  (define d (up! alice "hub.txt" "hub"))
  ;; a hub with eight neighbours, inserted in REVERSE name order so that the
  ;; insertion order and the name order disagree — a walk that followed row
  ;; order would keep the wrong ones
  (define spokes (for/list ([i (in-range 8 0 -1)]) (format "Spoke ~a" i)))
  (kg-upsert! c tid (hash-ref d 'id) (hash-ref d 'version_id)
              (hasheq 'entities (cons (ent "concept" "Hub" "h")
                                      (for/list ([s (in-list spokes)]) (ent "concept" s s)))
                      'relations (for/list ([s (in-list spokes)]) (rel "Hub" "links" s s))))
  (define hub (hash-ref (car (kg-find c alice "hub")) 'id))
  (define full (kg-graph c alice hub))
  (check-false (hash-ref full 'truncated))
  (check-equal? (length (hash-ref full 'nodes)) 9)

  (define small (kg-graph c alice hub #:cap 4))
  (check-true (hash-ref small 'truncated) "a cap that bit says so")
  (check-equal? (names small) '("Hub" "Spoke 1" "Spoke 2" "Spoke 3")
                "and it keeps the first neighbours BY NAME, not by insertion")
  (check-equal? (length (hash-ref small 'edges)) 3 "only edges between nodes that are drawn")
  (check-equal? (names (kg-graph c alice hub #:cap 4)) (names small) "the same answer twice"))

(test-case "hops: a second ring at 2, and a nonsense value clamped"
  (define-values (c tid alice bob up!) (world))
  (define d (up! alice "chain.txt" "chain"))
  (kg-upsert! c tid (hash-ref d 'id) (hash-ref d 'version_id)
              (hasheq 'entities (list (ent "concept" "A" "a") (ent "concept" "B" "b")
                                      (ent "concept" "C" "c") (ent "concept" "D" "d"))
                      'relations (list (rel "A" "next" "B" "x") (rel "B" "next" "C" "y")
                                       (rel "C" "next" "D" "z"))))
  (define a (hash-ref (car (kg-find c alice "a")) 'id))
  (check-equal? (names (kg-graph c alice a #:hops 1)) '("A" "B"))
  (check-equal? (names (kg-graph c alice a #:hops 2)) '("A" "B" "C"))
  (check-equal? (hash-ref (kg-graph c alice a #:hops 9) 'hops) 2 "clamped to two, never the whole graph")
  (check-equal? (hash-ref (kg-graph c alice a #:hops 0) 'hops) 1 "and never zero, which would draw one dot"))
