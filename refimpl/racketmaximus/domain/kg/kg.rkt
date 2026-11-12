#lang racket/base

;; domain/kg/kg.rkt — the knowledge graph (slice 61, KG-1…7): entities and the
;; relations between them, extracted from the team's documents, every fact
;; traceable to the document and version it came from.
;;
;; Nothing enters the graph without a source. That one rule is what makes the
;; rest fall out:
;;   - AUTHORIZATION IS INHERITED, never assigned (KG-3): a fact is visible to a
;;     principal iff at least one of its mentions is on an object they `can?`
;;     read; mentions are filtered per row, so a private document's snippet stays
;;     private even when the team can see the fact through another document.
;;   - STALENESS IS INHERITED: a new version re-extracts and supersedes; the
;;     mentions of the old version go, and an entity or relation left with no
;;     mention is pruned. The graph never says what the documents no longer say.
;;   - DELETING A DOCUMENT DELETES ITS MENTIONS, on repo-delete!'s hook; same pruning.
;;
;; Dedup is (team, type, name_norm) only — no cross-type merging in v1 (KG-4).
;; Types are an open vocabulary with a starter set (KG-1); predicates are the
;; extractor's own words, lower_snake_cased.

(require db-kit/portable
         racket/string racket/list
         "../db/id.rkt"
         "../authz/authz.rkt"
         "../repo/repo.rkt"
         "../db/nulls.rkt")

(provide STARTER-TYPES normalize-name normalize-predicate
         kg-upsert! kg-mark-extracted! kg-list-unextracted
         kg-entity kg-find kg-neighbourhood kg-stats
         kg-entities-on kg-graph KG-GRAPH-CAP)

(define STARTER-TYPES '("person" "organization" "product" "place" "event" "concept"))

;; "Acme Robotics", "ACME  robotics" and "Acme Robotics Inc." are one organization
(define SUFFIXES '("inc" "inc." "ltd" "ltd." "llc" "corp" "corp." "co" "co." "gmbh" "plc" "sa" "bv" "ag"))
(define (normalize-name s)
  (define words (string-split (string-downcase (string-trim s))))
  (define trimmed
    (let loop ([ws (reverse words)])
      (cond [(and (pair? ws) (pair? (cdr ws)) (member (car ws) SUFFIXES)) (loop (cdr ws))]
            [else (reverse ws)])))
  (string-join trimmed " "))

(define (normalize-predicate s)
  (define t (string-downcase (string-trim s)))
  (define u (regexp-replace* #px"[^a-z0-9]+" t "_"))
  (string-trim u "_"))


;; ---- write path ------------------------------------------------------------------------
(define (entity-id! conn team type name description)
  (define norm (normalize-name name))
  (define existing (query-maybe-value conn
    "SELECT id FROM kg_entities WHERE team_id = ? AND type = ? AND name_norm = ?" team type norm))
  (cond
    [existing
     ;; a description is kept once known; a later, longer one wins
     (when (and (string? description) (not (string=? description ""))
                (let ([d (query-value conn "SELECT COALESCE(description, '') FROM kg_entities WHERE id = ?" existing)])
                  (> (string-length description) (string-length d))))
       (query-exec conn "UPDATE kg_entities SET description = ? WHERE id = ?" description existing))
     existing]
    [else
     (define id (new-id))
     (query-exec conn
       "INSERT INTO kg_entities (id, team_id, type, name, name_norm, description) VALUES (?, ?, ?, ?, ?, ?)"
       id team type (string-trim name) norm (or description ""))
     id]))

(define (relation-id! conn team subject predicate object)
  (or (query-maybe-value conn
        "SELECT id FROM kg_relations WHERE team_id = ? AND subject_id = ? AND predicate = ? AND object_id = ?"
        team subject predicate object)
      (let ([id (new-id)])
        (query-exec conn
          "INSERT INTO kg_relations (id, team_id, subject_id, predicate, object_id) VALUES (?, ?, ?, ?, ?)"
          id team subject predicate object)
        id)))

;; entities and relations with no mention left are garbage: the graph is a VIEW
;; over the documents, and the mentions table is the join that makes that true
(define (prune! conn team)
  (query-exec conn
    (string-append "DELETE FROM kg_relations WHERE team_id = ? AND id NOT IN "
                   "(SELECT relation_id FROM kg_mentions WHERE relation_id IS NOT NULL)") team)
  (query-exec conn
    (string-append "DELETE FROM kg_entities WHERE team_id = ? AND id NOT IN "
                   "(SELECT entity_id FROM kg_mentions WHERE entity_id IS NOT NULL) "
                   "AND id NOT IN (SELECT subject_id FROM kg_relations) "
                   "AND id NOT IN (SELECT object_id FROM kg_relations)") team))

;; extraction: {entities: [{type name description snippet}], relations: [{subject predicate object snippet}]}
;; — already validated by the tool. Supersedes whatever an earlier version of the
;; same object asserted.
(define (kg-upsert! conn team object-id version-id extraction)
  (query-exec conn "DELETE FROM kg_mentions WHERE object_id = ?" object-id)
  (define ids (make-hash))     ; name_norm -> entity id, for this extraction's relations
  (for ([e (in-list (hash-ref extraction 'entities '()))])
    (define type (normalize-predicate (hash-ref e 'type "concept")))
    (define name (hash-ref e 'name))
    (define id (entity-id! conn team (if (string=? type "") "concept" type) name (hash-ref e 'description "")))
    (hash-set! ids (normalize-name name) id)
    (query-exec conn
      "INSERT INTO kg_mentions (id, team_id, entity_id, object_id, version_id, snippet) VALUES (?, ?, ?, ?, ?, ?)"
      (new-id) team id object-id version-id (hash-ref e 'snippet "")))
  (for ([r (in-list (hash-ref extraction 'relations '()))])
    (define s (hash-ref ids (normalize-name (hash-ref r 'subject)) #f))
    (define o (hash-ref ids (normalize-name (hash-ref r 'object)) #f))
    (when (and s o (not (equal? s o)))
      (define rid (relation-id! conn team s (normalize-predicate (hash-ref r 'predicate)) o))
      (query-exec conn
        "INSERT INTO kg_mentions (id, team_id, relation_id, object_id, version_id, snippet) VALUES (?, ?, ?, ?, ?, ?)"
        (new-id) team rid object-id version-id (hash-ref r 'snippet ""))))
  (kg-mark-extracted! conn team object-id version-id
                      (length (hash-ref extraction 'entities '())) (length (hash-ref extraction 'relations '())))
  (prune! conn team))

;; the marker that makes "unextracted" answerable: a document with no entities in
;; it would otherwise be listed forever
(define (kg-mark-extracted! conn team object-id version-id n-entities n-relations)
  (query-exec conn "DELETE FROM kg_extractions WHERE object_id = ?" object-id)
  (query-exec conn
    "INSERT INTO kg_extractions (object_id, team_id, version_id, entities, relations) VALUES (?, ?, ?, ?, ?)"
    object-id team version-id n-entities n-relations))

(define (kg-forget! conn object-id)
  (define team (query-maybe-value conn "SELECT team_id FROM kg_mentions WHERE object_id = ? LIMIT 1" object-id))
  (query-exec conn "DELETE FROM kg_mentions WHERE object_id = ?" object-id)
  (query-exec conn "DELETE FROM kg_extractions WHERE object_id = ?" object-id)
  (when (and team (not (sql-null? team))) (prune! conn team)))

;; objects whose CURRENT version has text in the index but no extraction for
;; that version — never-extracted and re-written-since both, keyed to the version
;;
;; TWO FILTERS THIS LISTER DID NOT HAVE, AND BOTH HAD ALREADY BEEN FIXED ONCE
;; IN ITS SIBLING. It selected by `o.team_id` alone and excluded nothing.
;;
;; #235 — A COLLEAGUE'S PRIVATE DOCUMENT WAS LISTED INTO A RUN THAT COULD NOT
;; READ IT. `kg_extract` then raises `forbidden: files:read`, which fails the
;; step and the run, so `index-knowledge` was unusable for anyone but the owner
;; on any team holding one private document — and what that looks like is a
;; broken extractor rather than a permission. #189 step 4 found and fixed exactly
;; this in `repo_list_unindexed` and added `repo-readable?` as "the ONE predicate
;; both listers ask"; this is the third lister and was never pointed at it.
;;
;; WHY IT WAS NOT NOTICED, which is the same reason the first one took a slice to
;; find: THE LISTER ONLY OFFERS WHAT IS UNEXTRACTED, so once the owner has run
;; the workflow the private document stops being listed and the fault
;; disappears. A regression test needs a private document created AFTER an
;; earlier run — "exactly-once hides every later mistake", in a lister.
;;
;; #234 — AND IT WAS ASKED TO EXTRACT ENTITIES FROM THE PIPELINE'S OWN OUTPUT.
;; Measured on the demo: thirteen documents of which nine were derived, every
;; child refused by `validate-extraction`, **2 entities from 13 documents** and a
;; red run. The refusals were CORRECT — KG-3 admits nothing without a verbatim
;; snippet — and the "entities" were phrases out of the renderer's own
;; boilerplate (`TMach document pipeline`), so the subsystem was doing its job on
;; input it should never have been given, at one metered model request each.
;; CLS-26 made this exclusion for the classification backfill and its test is a
;; derivation row, never a key suffix; `REPO-NOT-DERIVED` is that test.
;;
;; THE DERIVED EXCLUSION IS IN SQL AND THE READABILITY FILTER CANNOT BE, and the
;; asymmetry is worth stating because it is not a style choice. `can?` is Racket,
;; so readability narrows the ANSWER after the `LIMIT`; the derivation test
;; narrows the WINDOW. That matters for a drain somebody runs until it finds
;; nothing: nine derived documents in a window of forty would otherwise consume
;; nine slots and, past the batch, a page could come back empty with real
;; documents waiting behind it. What remains is the residual the sibling lister
;; also carries — an unreadable document still occupies a slot — and it is
;; bounded by the same batch.
(define (kg-list-unextracted conn p #:limit [lim 40])
  (require-perm conn p "files:read")
  (define rows (query-rows conn
    (string-append
     "SELECT o.id FROM repo_objects o "
     "JOIN repo_text t ON t.object_id = o.id AND t.version_id = o.current_version_id "
     "LEFT JOIN kg_extractions x ON x.object_id = o.id AND x.version_id = o.current_version_id "
     "WHERE o.team_id = ? AND o.deleted_at IS NULL AND x.object_id IS NULL AND t.content <> '' "
     "AND " REPO-NOT-DERIVED " "
     "ORDER BY o.updated_at ASC LIMIT ?")
    (principal-team-id p) lim))
  (for/list ([r (in-list rows)]
             #:when (repo-readable? conn p (vector-ref r 0)))
    (vector-ref r 0)))

;; ---- read path: the mention rule ---------------------------------------------------------
(define (readable-object conn p object-id)
  (with-handlers ([exn:fail:forbidden? (lambda (_) #f)]) (repo-get conn p object-id)))

;; the mentions of an entity or relation the caller may see, with the source key
(define (mentions-for conn p #:entity [eid #f] #:relation [rid #f])
  (define rows
    (query-rows conn
      (string-append "SELECT m.id, m.object_id, m.version_id, m.snippet, m.extracted_at FROM kg_mentions m "
                     (if eid "WHERE m.entity_id = ? " "WHERE m.relation_id = ? ")
                     "ORDER BY m.extracted_at DESC, m.id")
      (or eid rid)))
  (define seen (make-hash))
  (for*/list ([r (in-list rows)]
              [o (in-value (hash-ref! seen (vector-ref r 1) (lambda () (readable-object conn p (vector-ref r 1)))))]
              #:when o)
    (hasheq 'id (vector-ref r 0) 'object_id (vector-ref r 1) 'version_id (vector-ref r 2)
            'key (hash-ref o 'key) 'snippet (vector-ref r 3) 'extracted_at (format "~a" (vector-ref r 4)))))

(define (visible? conn p #:entity [eid #f] #:relation [rid #f])
  (pair? (mentions-for conn p #:entity eid #:relation rid)))

(define (entity-row conn id)
  (query-maybe-row conn "SELECT id, team_id, type, name, description, first_seen_at FROM kg_entities WHERE id = ?" id))

(define (row->entity r)
  (hasheq 'id (vector-ref r 0) 'team_id (vector-ref r 1) 'type (vector-ref r 2) 'name (vector-ref r 3)
          'description (let ([d (vector-ref r 4)]) (if (sql-null? d) "" d))
          'first_seen_at (format "~a" (vector-ref r 5))))

;; one entity, its relations (each with its own readable mentions) and its mentions.
;; #f when it does not exist OR the caller can see no mention of it — the two are
;; indistinguishable on purpose.
(define (kg-entity conn p id)
  (require-perm conn p "files:read")
  (define r (entity-row conn id))
  (and r
       (equal? (vector-ref r 1) (principal-team-id p))
       (let ([mentions (mentions-for conn p #:entity id)])
         (and (pair? mentions)
              (let ()
                (define e (row->entity r))
                (define rels
                  (for*/list ([rr (in-list (query-rows conn
                                  (string-append "SELECT r.id, r.subject_id, r.predicate, r.object_id, "
                                                 "s.name, s.type, o.name, o.type FROM kg_relations r "
                                                 "JOIN kg_entities s ON s.id = r.subject_id "
                                                 "JOIN kg_entities o ON o.id = r.object_id "
                                                 "WHERE r.subject_id = ? OR r.object_id = ? ORDER BY r.predicate, s.name, o.name")
                                  id id))]
                              [ms (in-value (mentions-for conn p #:relation (vector-ref rr 0)))]
                              #:when (pair? ms))
                    (hasheq 'id (vector-ref rr 0) 'subject_id (vector-ref rr 1) 'predicate (vector-ref rr 2)
                            'object_id (vector-ref rr 3)
                            'subject (vector-ref rr 4) 'subject_type (vector-ref rr 5)
                            'object (vector-ref rr 6) 'object_type (vector-ref rr 7)
                            'direction (if (equal? (vector-ref rr 1) id) "out" "in")
                            'mentions ms)))
                (hash-set* e 'relations rels 'mentions mentions))))))

;; entities by name (substring, case-insensitive) and optionally type, each with
;; at least one readable mention; the count of readable mentions rides along
(define (kg-find conn p q #:type [type #f] #:limit [lim 50])
  (require-perm conn p "files:read")
  (define rows
    (if type
        (query-rows conn
          (string-append "SELECT id, team_id, type, name, description, first_seen_at FROM kg_entities "
                         "WHERE team_id = ? AND type = ? AND name_norm LIKE ? ORDER BY name LIMIT ?")
          (principal-team-id p) type (string-append "%" (normalize-name q) "%") (* 4 lim))
        (query-rows conn
          (string-append "SELECT id, team_id, type, name, description, first_seen_at FROM kg_entities "
                         "WHERE team_id = ? AND name_norm LIKE ? ORDER BY name LIMIT ?")
          (principal-team-id p) (string-append "%" (normalize-name q) "%") (* 4 lim))))
  (take-at-most
   (for*/list ([r (in-list rows)]
               [ms (in-value (mentions-for conn p #:entity (vector-ref r 0)))]
               #:when (pair? ms))
     (hash-set* (row->entity r) 'mention_count (length ms)
                'relation_count (query-value conn "SELECT COUNT(*) FROM kg_relations WHERE subject_id = ? OR object_id = ?"
                                             (vector-ref r 0) (vector-ref r 0))))
   lim))

(define (take-at-most l n) (if (> (length l) n) (take l n) l))

;; the neighbourhood within `hops` (≤ 2) of an entity, for the agent tool: a list
;; of (entity, relations) the caller may see, with citations
(define (kg-neighbourhood conn p id #:hops [hops 1])
  (define h (min 2 (max 0 hops)))
  (define start (kg-entity conn p id))
  (cond
    [(not start) #f]
    [else
     (define seen (make-hash))
     (hash-set! seen id start)
     (let loop ([frontier (list start)] [depth 0])
       (when (< depth h)
         (define next
           (for*/list ([e (in-list frontier)]
                       [r (in-list (hash-ref e 'relations))]
                       [other (in-value (if (equal? (hash-ref r 'direction) "out") (hash-ref r 'object_id) (hash-ref r 'subject_id)))]
                       #:unless (hash-has-key? seen other)
                       [oe (in-value (kg-entity conn p other))]
                       #:when oe)
             (hash-set! seen other oe)
             oe))
         (loop next (add1 depth))))
     (sort (hash-values seen) string<? #:key (lambda (e) (hash-ref e 'name)))]))

;; ---- #191 slice 3: what one document says, and a drawable neighbourhood --------------

;; The entities ONE document mentions, for the Research tab's "what did this
;; page tell us". Under KG-3 an entity is visible iff it has a mention on an
;; object the caller can read — and every row here has one by construction,
;; because the object IS readable and the mention is on it. So the readability
;; of THIS object is the whole check, and it is made once rather than per row.
;;
;; `#f` for an object the caller cannot read or that does not exist: one answer,
;; `repo-get`'s collapse, so this read is not an existence oracle on an id.
;; `extracted` says whether the CURRENT version has been through the graph drain
;; — an empty list means "nothing found" only when it is true, and "not read
;; yet" otherwise, and those have different remedies (CLS-27's line).
(define (kg-entities-on conn p object-id)
  (require-perm conn p "files:read")
  (define o (readable-object conn p object-id))
  (and o
       (let ()
         (define rows
           (query-rows conn
             (string-append "SELECT e.id, e.type, e.name, COUNT(*) FROM kg_mentions m "
                            "JOIN kg_entities e ON e.id = m.entity_id "
                            "WHERE m.object_id = ? AND e.team_id = ? "
                            "GROUP BY e.id, e.type, e.name ORDER BY e.name, e.id")
             object-id (principal-team-id p)))
         (define extracted?
           (and (query-maybe-value conn
                  (string-append "SELECT 1 FROM kg_extractions x JOIN repo_objects o "
                                 "ON o.id = x.object_id AND x.version_id = o.current_version_id "
                                 "WHERE x.object_id = ?")
                  object-id)
                #t))
         (hasheq 'object_id object-id
                 'extracted extracted?
                 'entities (for/list ([r (in-list rows)])
                             (hasheq 'id (vector-ref r 0) 'type (vector-ref r 1) 'name (vector-ref r 2)
                                     'mention_count (let ([n (vector-ref r 3)]) (if (exact-integer? n) n (string->number (format "~a" n))))))))))

;; A neighbourhood as NODES and EDGES, for a picture (RG-9). `kg-neighbourhood`
;; above answers a list of whole entities for the agent tool; a drawing needs the
;; edges between them and, above all, a BOUND — a well-connected entity at two
;; hops is the whole team's graph, and RG-9's argument is that no layout makes
;; that readable. So the walk stops at `cap` nodes and SAYS so.
;;
;; 🔑 EVERYTHING ABOUT THE ORDER IS DETERMINISTIC, because the drawing's layout
;; is seeded and a seeded layout over an arbitrary node order is still an
;; arbitrary picture (ORG-13's lesson). The frontier is walked in (name, id)
;; order and each entity's neighbours are taken in (name, id) order, so the same
;; graph gives the same node list on every instance — and which nodes a cap
;; drops is decided by that order rather than by random relation ids.
;;
;; Visibility is `kg-entity`'s, asked per node: a relation is drawn only when
;; `kg-entity` returned it (it has a readable mention) AND both its ends are
;; nodes the caller may see. Nothing here re-derives the mention rule.
(define KG-GRAPH-CAP 40)
(define (kg-graph conn p id #:hops [hops 1] #:cap [cap KG-GRAPH-CAP])
  (define h (min 2 (max 1 (if (exact-integer? hops) hops 1))))
  (define start (kg-entity conn p id))
  (and start
       (let ()
         (define seen (make-hash))          ; id -> entity
         (hash-set! seen id start)
         (define order (list id))           ; reversed walk order
         (define truncated #f)
         (define (by-name a b)
           (or (string<? (car a) (car b))
               (and (string=? (car a) (car b)) (string<? (cdr a) (cdr b)))))
         (let loop ([frontier (list start)] [depth 0])
           (when (and (< depth h) (pair? frontier) (not truncated))
             (define next '())
             (for ([e (in-list (sort frontier by-name
                                     #:key (lambda (e) (cons (hash-ref e 'name) (hash-ref e 'id)))))]
                   #:break truncated)
               (define cands
                 (sort (remove-duplicates
                        (for/list ([r (in-list (hash-ref e 'relations))])
                          (if (equal? (hash-ref r 'direction) "out")
                              (cons (hash-ref r 'object) (hash-ref r 'object_id))
                              (cons (hash-ref r 'subject) (hash-ref r 'subject_id)))))
                       by-name))
               (for ([c (in-list cands)] #:unless (hash-has-key? seen (cdr c)) #:break truncated)
                 (define oe (kg-entity conn p (cdr c)))
                 (when oe
                   (cond
                     [(>= (hash-count seen) cap) (set! truncated #t)]
                     [else (hash-set! seen (cdr c) oe)
                           (set! order (cons (cdr c) order))
                           (set! next (cons oe next))]))))
             (loop next (add1 depth))))
         (define edges
           (let ([acc (make-hash)])
             (for* ([e (in-hash-values seen)]
                    [r (in-list (hash-ref e 'relations))]
                    #:when (and (hash-has-key? seen (hash-ref r 'subject_id))
                                (hash-has-key? seen (hash-ref r 'object_id))))
               (hash-set! acc (hash-ref r 'id)
                          (hasheq 'id (hash-ref r 'id) 'from (hash-ref r 'subject_id)
                                  'to (hash-ref r 'object_id) 'predicate (hash-ref r 'predicate)
                                  'key (list (hash-ref r 'subject) (hash-ref r 'predicate)
                                             (hash-ref r 'object) (hash-ref r 'id)))))
             (for/list ([x (in-list (sort (hash-values acc)
                                          (lambda (a b)
                                            (let loop ([a (hash-ref a 'key)] [b (hash-ref b 'key)])
                                              (cond [(null? a) #f]
                                                    [(string<? (car a) (car b)) #t]
                                                    [(string=? (car a) (car b)) (loop (cdr a) (cdr b))]
                                                    [else #f])))))])
               (hash-remove x 'key))))
         (hasheq 'focus id
                 'hops h
                 'cap cap
                 'truncated truncated
                 'nodes (for/list ([nid (in-list (reverse order))])
                          (define e (hash-ref seen nid))
                          (hasheq 'id nid 'name (hash-ref e 'name) 'type (hash-ref e 'type)
                                  'focus (equal? nid id)
                                  'mention_count (length (hash-ref e 'mentions))))
                 'edges edges))))

(define (kg-stats conn p)
  (require-perm conn p "files:read")
  (define team (principal-team-id p))
  (hasheq 'entities (query-value conn "SELECT COUNT(*) FROM kg_entities WHERE team_id = ?" team)
          'relations (query-value conn "SELECT COUNT(*) FROM kg_relations WHERE team_id = ?" team)
          'documents (query-value conn "SELECT COUNT(*) FROM kg_extractions WHERE team_id = ?" team)
          'unextracted (length (kg-list-unextracted conn p #:limit 1000))))

;; a deleted document takes its facts with it
(set-delete-hook! (lambda (conn object-id) (kg-forget! conn object-id)))
