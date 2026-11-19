#lang racket/base

;; test/kg-source-tests.rkt — the plugin extraction source (domain/kg/sources.rkt).
;;   raco test test/kg-source-tests.rkt
;;
;; What this has to prove, because the mention rule is a security property and this seam is
;; the first way an object id can name something the repository does not hold:
;;
;;   1. an id built by `kg-source-id` parses back to the same pair, and a repository id never
;;      parses as a source id, in both directions
;;   2. the lister offers a source's documents, does not offer one again once it has been
;;      extracted for the version the source reported, and offers it again when the version
;;      moves
;;   3. visibility is asked of the source, with the team the mention was RECORDED for, so a
;;      fact recorded for one team is invisible to a reader of another
;;   4. a source that raises leaves the read answering; a source that offers what its own
;;      `see` refuses contributes nothing to the run
;;   5. the registration rules: a second owner is refused, re-registering your own is fine, a
;;      name outside the grammar is refused
;;   6. extraction refuses a document whose version the source cannot name, and records
;;      extracted-with-nothing for a version whose text is empty, so it is not listed for ever
;;   7. the batch is one budget across both arms
;;   8. forgetting through the wrapper removes the mentions and prunes the entity they alone
;;      held up
;;
;; The registry is process-global, so every case that registers unregisters in a
;; `dynamic-wind`. A source left registered by a suite is the failure mode this file exists to
;; avoid, which is also why `unregister-extraction-source!` is exported.

(require rackunit db-kit/portable
         racket/string racket/list racket/file
         db-kit/migrate
         "../domain/db/migrations.rkt"
         "../domain/db/id.rkt"
         "db-fixture.rkt"
         "../domain/authz/authz.rkt"
         "../domain/repo/blobs.rkt"
         "../domain/repo/repo.rkt"
         "../domain/repo/extract.rkt"
         "../domain/kg/kg.rkt"
         "../domain/kg/kg-tools.rkt"
         "../domain/kg/sources.rkt"
         "../domain/agent/registry.rkt"
         "../domain/sched/scheduler.rkt")

(define BLOB-ROOT (make-temporary-file "telemachus-kg-src-blobs-~a" 'directory))
(current-blob-root BLOB-ROOT)

(define (fresh)
  (define conn (fresh-db #:migrate? #f))
  (migrate! conn all-migrations)
  conn)

;; ---- a source that pretends to be a plugin ------------------------------------------------
;; `docs` is doc-id -> (hasheq 'version <string> 'text <string>); `deny` is the set of ids its
;; `see` refuses even though `list` still offers them, which is the case the lister must not
;; trust. `boom` makes `see` raise, for the swallow case.
(define (make-source docs #:deny [deny '()] #:boom? [boom? #f] #:seen [seen (box '())])
  (hasheq
   'list (lambda (conn p team limit)
           (define ks (sort (hash-keys docs) string<?))
           (if (> (length ks) limit) (take ks limit) ks))
   'see (lambda (conn p team id)
          (set-box! seen (cons (list team id) (unbox seen)))
          (when boom? (error 'boom "the source raised"))
          (define d (hash-ref docs id #f))
          (and d (not (member id deny)) (hasheq 'key (string-append "src:" id))))
   'version (lambda (conn p team id) (hash-ref (hash-ref docs id #f) 'version #f))
   'text (lambda (conn p team id) (hash-ref (hash-ref docs id #f) 'text ""))))

(define (with-source name src thunk)
  (register-extraction-source! name src)
  (dynamic-wind void thunk (lambda () (unregister-extraction-source! name))))

;; ---- 1. the encoded id -------------------------------------------------------------------
(test-case "a source id round-trips, and no repository id can be one"
  (define id (kg-source-id "rcnt" "doc-1"))
  (check-equal? id "kg-src:rcnt:doc-1")
  (check-true (kg-source-id? id))
  (check-equal? (kg-source-id-split id) (cons "rcnt" "doc-1"))
  ;; the doc id may hold anything, including the separator, and the split takes the FIRST colon
  (check-equal? (kg-source-id-split (kg-source-id "rcnt" "a:b:c")) (cons "rcnt" "a:b:c"))
  (check-equal? (kg-source-id-split (kg-source-id "rcnt" "with space\nand newline"))
                (cons "rcnt" "with space\nand newline"))
  ;; a repository id is a UUIDv4: hex and dashes, so it cannot begin with the prefix
  (for ([_ 200])
    (define u (new-id))
    (check-false (kg-source-id? u))
    (check-false (kg-source-id-split u)))
  ;; and the prefix is not enough on its own
  (for ([bad '("kg-src:" "kg-src:rcnt" "kg-src::doc" "kg-src:Upper:doc" "xkg-src:rcnt:doc" "")])
    (check-false (kg-source-id? bad))))

;; ---- 5. registration ---------------------------------------------------------------------
(test-case "a name outside the grammar is refused, naming the pattern"
  (for ([bad '("" "RCNT" "rc nt" "rcnt:sub" "1rcnt" (string-append "a" (make-string 80 #\b)) #f 7)])
    (check-exn #rx"source name must match" (lambda () (register-extraction-source! bad (make-source (hasheq))))))
  (check-exn #rx"must be a procedure" (lambda () (register-extraction-source! "rcnt" (hasheq))))
  (check-exn #rx"see must be a procedure"
             (lambda () (register-extraction-source! "rcnt" (hash-remove (make-source (hasheq)) 'see)))))

(test-case "a second owner is refused and the message names the owner; your own re-registration replaces"
  (unregister-extraction-source! "rcnt")
  (define src (make-source (hasheq)))
  (register-extraction-source! "rcnt" src)
  (parameterize ([current-plugin 'plugin-a])
    (check-equal? (register-extraction-source! "rcnt" src) "rcnt")
    (check-equal? (extraction-sources) '("rcnt")))
  (parameterize ([current-plugin 'plugin-b])
    (check-exn #rx"already claimed by plugin plugin-a"
               (lambda () (register-extraction-source! "rcnt" src))))
  (unregister-extraction-source! "rcnt")
  (check-equal? (extraction-sources) '()))

;; ---- 2. the lister -----------------------------------------------------------------------
(define (note-doc! conn team id version)
  (kg-upsert! conn team id version
              (hasheq 'entities (list (hasheq 'type "organization" 'name "Acme Robotics"
                                              'snippet "Acme Robotics hired"))
                      'relations '())))

(define (mentioned-versions conn p name)
  (for*/list ([e (in-list (kg-find conn p name))]
              [ent (in-value (kg-entity conn p (hash-ref e 'id)))]
              #:when ent
              [m (in-list (hash-ref ent 'mentions))])
    (hash-ref m 'version_id)))

(test-case "a source document is listed until it is extracted for the version it reported, then again when the version moves"
  (define conn (fresh))
  (define-values (uid tid) (bootstrap! conn #:username "alice"))
  (define alice (user-principal conn uid tid))
  (define id (kg-source-id "rcnt" "d1"))
  (define ver (box "v1"))
  (with-source "rcnt"
               (hasheq 'list (lambda (c p team limit) '("d1"))
                       'see (lambda (c p team doc) (hasheq 'key "src:d1"))
                       'version (lambda (c p team doc) (unbox ver))
                       'text (lambda (c p team doc) "Acme Robotics hired Ada Lovelace."))
               (lambda ()
                 (check-equal? (kg-list-unextracted conn alice) (list id))
                 (note-doc! conn tid id "v1")
                 (check-equal? (kg-list-unextracted conn alice) '())
                 (set-box! ver "v2")
                 (check-equal? (kg-list-unextracted conn alice) (list id)
                               "a moved version is offered again")
                 (check-equal? (mentioned-versions conn alice "Acme Robotics") '("v1")
                               "the new version has not been extracted yet"))))


;; ---- 3. the mention rule over a source ---------------------------------------------------
(test-case "a fact on a source document is visible to a reader the source admits and invisible to one it refuses"
  (define conn (fresh))
  (define-values (uid tid) (bootstrap! conn #:username "alice"))
  (define alice (user-principal conn uid tid))
  (define bob-id (create-user! conn #:username "bob" #:password "pw-fixture-1"))
  (add-member! conn #:user bob-id #:team tid #:role "member")
  (define bob (user-principal conn bob-id tid))
  (define docs (hasheq "d1" (hasheq 'version "v1" 'text "Acme Robotics hired Ada Lovelace.")))
  (define seen (box '()))
  ;; the source admits alice and refuses bob, and both are in the SAME team, so the only
  ;; difference between the two answers is what the source says
  (with-source "rcnt"
               (hasheq 'list (lambda (c p team limit) '("d1"))
                       'see (lambda (c p team id)
                              (set-box! seen (cons (list team id) (unbox seen)))
                              (and (equal? (principal-user-id p) uid) (hasheq 'key "src:d1")))
                       'version (lambda (c p team id) "v1")
                       'text (lambda (c p team id) (hash-ref docs "d1" 'text)))
               (lambda ()
                 (define id (kg-source-id "rcnt" "d1"))
                 (kg-upsert! conn tid id "v1"
                             (hasheq 'entities (list (hasheq 'type "organization" 'name "Acme Robotics"
                                                             'snippet "Acme Robotics hired"))
                                     'relations '()))
                 (define found (kg-find conn alice "Acme"))
                 (check-equal? (length found) 1 "the source admitted alice, so the entity is visible")
                 (define ent-id (hash-ref (car found) 'id))
                 (check-true (and (kg-entity conn alice ent-id) #t) "alice reads the entity")
                 (check-false (kg-entity conn bob ent-id) "bob is refused, so every route answers nothing")
                 ;; the question was asked with the team the mention was recorded for
                 (check-true (for/or ([s (in-list (unbox seen))]) (equal? (car s) tid))))))

(test-case "a fact recorded for one team is invisible to a reader of another, whatever the source answers"
  (define conn (fresh))
  (define-values (uid1 tid1) (bootstrap! conn #:username "alice"))
  (define alice (user-principal conn uid1 tid1))
  ;; a second team, and a reader in it
  (define tid2 (create-team! conn #:name "other" #:slug "other"
                             #:org (query-value conn "SELECT org_id FROM teams WHERE id = ?" tid1)))
  (define carol-id (create-user! conn #:username "carol" #:password "pw-fixture-2"))
  (add-member! conn #:user carol-id #:team tid2 #:role "member")
  (define carol (user-principal conn carol-id tid2))
  (with-source "rcnt"
               ;; a source that admits EVERYBODY for EVERY team, which is the hostile case
               (hasheq 'list (lambda (c p team limit) '("d1"))
                       'see (lambda (c p team id) (hasheq 'key "src:d1"))
                       'version (lambda (c p team id) "v1")
                       'text (lambda (c p team id) "Acme Robotics hired Ada Lovelace."))
               (lambda ()
                 (define id (kg-source-id "rcnt" "d1"))
                 (kg-upsert! conn tid1 id "v1"
                             (hasheq 'entities (list (hasheq 'type "organization" 'name "Acme Robotics"
                                                             'snippet "Acme Robotics hired"))
                                     'relations '()))
                 (define ent-id (hash-ref (car (kg-find conn alice "Acme")) 'id))
                 (check-true (and (kg-entity conn alice ent-id) #t))
                 (check-false (kg-entity conn carol ent-id)
                              "the entity's team is checked before any mention is weighed"))))

(test-case "a source that raises leaves the read answering, and the other source still supplies"
  (define conn (fresh))
  (define-values (uid tid) (bootstrap! conn #:username "alice"))
  (define alice (user-principal conn uid tid))
  (define good (kg-source-id "good" "d1"))
  (define bad (kg-source-id "bad" "d1"))
  (register-extraction-source! "good"
                               (hasheq 'list (lambda (c p team limit) '("d1"))
                                       'see (lambda (c p team id) (hasheq 'key "good"))
                                       'version (lambda (c p team id) "v1")
                                       'text (lambda (c p team id) "x")))
  (register-extraction-source! "bad"
                               (hasheq 'list (lambda (c p team limit) '("d1"))
                                       'see (lambda (c p team id) (error 'boom "raised"))
                                       'version (lambda (c p team id) "v1")
                                       'text (lambda (c p team id) "x")))
  (dynamic-wind
   void
   (lambda ()
     (kg-upsert! conn tid good "v1"
                 (hasheq 'entities (list (hasheq 'type "organization" 'name "Acme Robotics" 'snippet "x"))
                         'relations '()))
     ;; writing the bad mention directly, which is what a source's extraction would have done
     (query-exec conn "INSERT INTO kg_mentions (id, team_id, entity_id, object_id, version_id, snippet) SELECT ?, team_id, entity_id, ?, version_id, '' FROM kg_mentions WHERE object_id = ? LIMIT 1"
                  (new-id) bad good)
     (define found (kg-find conn alice "Acme"))
     (check-equal? (length found) 1 "the entity is visible through the good source")
     (define ent (kg-entity conn alice (hash-ref (car found) 'id)))
     (check-true (and ent #t) "the read answers rather than raising")
     (check-equal? (length (hash-ref ent 'mentions)) 1 "the raising source's mention is dropped"))
   (lambda ()
     (unregister-extraction-source! "good")
     (unregister-extraction-source! "bad"))))

(test-case "a source that offers what its own see refuses contributes nothing, so the run has nothing to fail on"
  (define conn (fresh))
  (define-values (uid tid) (bootstrap! conn #:username "alice"))
  (define alice (user-principal conn uid tid))
  (with-source "rcnt"
               (make-source (hasheq "d1" (hasheq 'version "v1" 'text "x")) #:deny '("d1"))
               (lambda () (check-equal? (kg-list-unextracted conn alice) '()))))

;; ---- 6. extraction through the tool -------------------------------------------------------
(test-case "extraction refuses a version the source cannot name, and records nothing"
  (define conn (fresh))
  (define-values (uid tid) (bootstrap! conn #:username "alice"))
  (define alice (user-principal conn uid tid))
  (with-source "rcnt"
               (hasheq 'list (lambda (c p team limit) '("d1"))
                       'see (lambda (c p team id) (hasheq 'key "src:d1"))
                       'version (lambda (c p team id) #f)
                       'text (lambda (c p team id) "Acme Robotics hired Ada Lovelace."))
               (lambda ()
                 (check-exn #rx"cannot name this document's version"
                            (lambda () ((tool-handler (tool-by-name "kg_extract")) conn alice
                                        (hasheq 'object (kg-source-id "rcnt" "d1")))))
                 (check-equal? (query-value conn "SELECT COUNT(*) FROM kg_extractions WHERE object_id = ?"
                                            (kg-source-id "rcnt" "d1"))
                               0))))

(test-case "extraction of an empty text records extracted-with-nothing for that version"
  (define conn (fresh))
  (define-values (uid tid) (bootstrap! conn #:username "alice"))
  (define alice (user-principal conn uid tid))
  (define id (kg-source-id "rcnt" "d1"))
  (with-source "rcnt"
               (hasheq 'list (lambda (c p team limit) '("d1"))
                       'see (lambda (c p team id) (hasheq 'key "src:d1"))
                       'version (lambda (c p team id) "v1")
                       'text (lambda (c p team id) ""))
               (lambda ()
                 (define answer ((tool-handler (tool-by-name "kg_extract")) conn alice (hasheq 'object id)))
                 (check-regexp-match #rx"skipped" answer)
                 (check-equal? (query-value conn "SELECT version_id FROM kg_extractions WHERE object_id = ?" id) "v1")
                 (check-equal? (kg-list-unextracted conn alice) '() "not listed again for this version"))))

;; ---- 7. kg-entities-on -------------------------------------------------------------------
(test-case "kg-entities-on says extracted false when the version moved and true when it matches"
  (define conn (fresh))
  (define-values (uid tid) (bootstrap! conn #:username "alice"))
  (define alice (user-principal conn uid tid))
  (define id (kg-source-id "rcnt" "d1"))
  (define ver (box "v1"))
  (with-source "rcnt"
               (hasheq 'list (lambda (c p team limit) '("d1"))
                       'see (lambda (c p team id) (hasheq 'key "src:d1"))
                       'version (lambda (c p team id) (unbox ver))
                       'text (lambda (c p team id) "Acme Robotics hired Ada Lovelace."))
               (lambda ()
                 (kg-upsert! conn tid id "v1"
                             (hasheq 'entities (list (hasheq 'type "organization" 'name "Acme Robotics"
                                                             'snippet "Acme Robotics hired"))
                                     'relations '()))
                 (check-true (hash-ref (kg-entities-on conn alice id) 'extracted))
                 (set-box! ver "v2")
                 (check-false (hash-ref (kg-entities-on conn alice id) 'extracted))
                 ;; and the caller's own team is what the source is asked about
                 (check-false (kg-entities-on conn alice (kg-source-id "nosuch" "d1"))))))

;; ---- 8. forgetting -----------------------------------------------------------------------
(test-case "the forget wrapper removes the mentions and prunes the entity they alone held up"
  (define conn (fresh))
  (define-values (uid tid) (bootstrap! conn #:username "alice"))
  (define alice (user-principal conn uid tid))
  (define id (kg-source-id "rcnt" "d1"))
  (with-source "rcnt"
               (hasheq 'list (lambda (c p team limit) '("d1"))
                       'see (lambda (c p team id) (hasheq 'key "src:d1"))
                       'version (lambda (c p team id) "v1")
                       'text (lambda (c p team id) "Acme Robotics hired Ada Lovelace."))
               (lambda ()
                 (kg-upsert! conn tid id "v1"
                             (hasheq 'entities (list (hasheq 'type "organization" 'name "Acme Only Corp"
                                                             'snippet "Acme Robotics hired"))
                                     'relations '()))
                 (check-equal? (length (kg-find conn alice "Acme Only")) 1)
                 (kg-source-forget! conn "rcnt" "d1")
                 (check-equal? (kg-find conn alice "Acme Only") '()
                               "the entity was held up by that one mention, so it is pruned"))))

;; ---- 7. one budget across both arms ------------------------------------------------------
(test-case "the batch is one budget across both arms, never more than the limit"
  (define conn (fresh))
  (define-values (uid tid) (bootstrap! conn #:username "alice"))
  (define alice (user-principal conn uid tid))
  ;; five repository documents with text and no extraction
  (for ([i (in-range 5)])
    (define o (repo-put! conn alice #:key (format "r/~a.txt" i)
                         #:port (open-input-bytes (string->bytes/utf-8 "Acme Robotics hired Ada Lovelace."))
                         #:content-type "text/plain" #:filename (format "r~a.txt" i)))
    (repo-text-upsert! conn (hash-ref o 'id) (hash-ref o 'version_id) "Acme Robotics hired Ada Lovelace."))
  (with-source "rcnt"
               (make-source (for/hash ([i (in-range 5)])
                              (values (format "s~a" i) (hasheq 'version "v1" 'text "x"))))
               (lambda ()
                 (check-equal? (length (kg-list-unextracted conn alice #:limit 3)) 3)
                 (check-equal? (length (kg-list-unextracted conn alice #:limit 7)) 7)
                 (check-equal? (length (kg-list-unextracted conn alice #:limit 100)) 10))))
