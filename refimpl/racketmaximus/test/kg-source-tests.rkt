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
         racket/string racket/list racket/file json
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
    (check-false (kg-source-id? bad)))
  ;; building one refuses the two inputs that would produce an id no read can resolve,
  ;; because an unparseable id is a document that silently contributes nothing
  (for ([bad '("" "RCNT" "rc nt" "rcnt:sub" 7 #f)])
    (check-exn #rx"not a source name" (lambda () (kg-source-id bad "d1"))))
  (for ([bad '("" 7 #f (list 1))])
    (check-exn #rx"non-empty string" (lambda () (kg-source-id "rcnt" bad)))))

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

;; ---- the drain cannot be starved by an already-extracted page --------------------------------
(test-case "a page whose contents are all extracted does not starve the documents behind it"
  (define conn (fresh))
  (define-values (uid tid) (bootstrap! conn #:username "alice"))
  (define alice (user-principal conn uid tid))
  ;; three documents, the first two already extracted for the version the source reports
  (define docs (for/hash ([i (in-range 3)])
                 (values (format "d~a" i) (hasheq 'version "v1" 'text "Acme Robotics hired."))))
  (for ([i (in-range 2)])
    (note-doc! conn tid (kg-source-id "rcnt" (format "d~a" i)) "v1"))
  (with-source "rcnt"
               (hasheq 'list (lambda (c p team limit)
                               (define ks (sort (hash-keys docs) string<?))
                               (if (> (length ks) limit) (take ks limit) ks))
                       'see (lambda (c p team doc) (hasheq 'key doc))
                       'version (lambda (c p team doc) "v1")
                       'text (lambda (c p team doc) "Acme Robotics hired."))
               (lambda ()
                 ;; a window of one would see d0, find it extracted, and answer nothing
                 (check-equal? (kg-list-unextracted conn alice #:limit 1)
                               (list (kg-source-id "rcnt" "d2"))))))

;; ---- no source can starve another ----------------------------------------------------------
(test-case "two registered sources both get served, whatever the name order"
  (define conn (fresh))
  (define-values (uid tid) (bootstrap! conn #:username "alice"))
  (define alice (user-principal conn uid tid))
  (define (source-of prefix howmany)
    (hasheq
     'list (lambda (c p team limit)
             (define ids (for/list ([i (in-range howmany)]) (format "~a-~a" prefix i)))
             (if (> (length ids) limit) (take ids limit) ids))
     'see (lambda (c p team doc) (hasheq 'key doc))
     'version (lambda (c p team doc) "v1")
     'text (lambda (c p team doc) "Acme Robotics hired.")))
  (register-extraction-source! "aaa" (source-of "a" 20))
  (register-extraction-source! "zzz" (source-of "z" 20))
  (dynamic-wind
   void
   (lambda ()
     (define got (kg-list-unextracted conn alice #:limit 4))
     (check-equal? (length got) 4)
     (check-true (for/or ([x (in-list got)]) (string-prefix? x "kg-src:zzz:"))
                 "the later name is served even though the earlier one had enough to fill the batch"))
   (lambda ()
     (unregister-extraction-source! "aaa")
     (unregister-extraction-source! "zzz"))))

;; ---- whole documents: the window is a size, not a limit --------------------------------------
(test-case "window-split covers the document exactly, and never answers an empty window"
  ;; empty text is refused before this is reached, so the guarantee is about non-empty text
  (for ([n '(1 2 7 12000)] [text (list "a" "ab\ncd" (make-string 30 #\x) (make-string 3 #\n))])
    (define ws (window-split text (max 1 n)))
    (check-equal? (apply string-append ws) text "the windows rejoin to the document")
    (for ([w (in-list ws)]) (check-true (> (string-length w) 0) "no window is empty")))
  (define long (string-append (make-string 9000 #\a) "\n" (make-string 9000 #\b)))
  (check-equal? (map string-length (window-split long 12000)) '(9001 9000)
                "the cut lands on the line break rather than mid-word")
  (check-equal? (map string-length (window-split (make-string 20000 #\c) 12000)) '(12000 8000)
                "with no line break the window is full"))

(test-case "a document longer than one window is read whole, one model call per window"
  ;; every window must carry the phrase, because a snippet is validated against its OWN window
  (define text (apply string-append (make-list 400 "Acme Robotics hired Ada Lovelace.\n")))
  ;; the reply differs per window so the merge has something to dedup
  (define calls (box 0))
  (define (reply prompt #:system [s #f])
    (set-box! calls (add1 (unbox calls)))
    (values (jsexpr->string
             (hasheq 'entities (list (hasheq 'type "organization" 'name "Acme Robotics"
                                             'description "" 'snippet "Acme Robotics"))
                     'relations '()))
            5))
  (define-values (x tokens windows truncated?)
    (extract-document text #:chat reply #:window 4000))
  (check-equal? windows 4 "one call per window, not one call per document")
  (check-equal? (unbox calls) 4)
  (check-equal? tokens 20 "the token total is every window's")
  (check-false truncated?)
  ;; four windows named the same organization, and the graph gets ONE entity
  (check-equal? (length (hash-ref x 'entities)) 1 "the merge dedups on the same key kg-upsert! uses"))

(test-case "the window bound is reported rather than hidden"
  (define text (make-string 50000 #\z))
  (define (reply prompt #:system [s #f])
    (values (jsexpr->string (hasheq 'entities '() 'relations '())) 1))
  (define-values (x tokens windows truncated?)
    (extract-document text #:chat reply #:window 1000 #:max-windows 3))
  (check-equal? windows 3)
  (check-true truncated? "a document past the bound says so instead of under-reading silently"))

(test-case "the merge keeps the first snippet and the longest description"
  (define e1 (hasheq 'type "organization" 'name "Acme Robotics Inc" 'description "a company" 'snippet "first"))
  (define e2 (hasheq 'type "organization" 'name "ACME robotics" 'description "a much longer description" 'snippet "second"))
  (define merged (merge-extractions (list (hasheq 'entities (list e1) 'relations '())
                                          (hasheq 'entities (list e2) 'relations '()))))
  (check-equal? (length (hash-ref merged 'entities)) 1)
  (check-equal? (hash-ref (car (hash-ref merged 'entities)) 'snippet) "first")
  (check-equal? (hash-ref (car (hash-ref merged 'entities)) 'description) "a much longer description"))

(test-case "a source may declare its own window, and anything else falls back to the default"
  (check-equal? (source-window "nosuch" #f #f #f "d1" 12000) 12000
                "an unregistered source answers the default rather than raising")
  (register-extraction-source! "big"
                               (hasheq 'list (lambda (c p t l) '())
                                       'see (lambda (c p t d) (hasheq 'key d))
                                       'version (lambda (c p t d) "v1")
                                       'text (lambda (c p t d) "x")
                                       'window (lambda (c p t d) 40000)))
  (register-extraction-source! "bad"
                               (hasheq 'list (lambda (c p t l) '())
                                       'see (lambda (c p t d) (hasheq 'key d))
                                       'version (lambda (c p t d) "v1")
                                       'text (lambda (c p t d) "x")
                                       'window (lambda (c p t d) -5)))
  (dynamic-wind
   void
   (lambda ()
     (check-equal? (source-window "big" #f #f #f "d1" 12000) 40000)
     (check-equal? (source-window "bad" #f #f #f "d1" 12000) 12000
                   "a nonsense window is the default, not a crash"))
   (lambda ()
     (unregister-extraction-source! "big")
     (unregister-extraction-source! "bad"))))

;; ---- one source document, two teams: neither may destroy the other -------------------------
(test-case "a source document readable by two teams is extracted once for each, and neither loses the other's facts"
  (define conn (fresh))
  (define-values (uid1 tid1) (bootstrap! conn #:username "alice"))
  (define alice (user-principal conn uid1 tid1))
  (define org (query-value conn "SELECT org_id FROM teams WHERE id = ?" tid1))
  (define tid2 (create-team! conn #:name "second" #:slug "second" #:org org))
  (define bob-id (create-user! conn #:username "bob" #:password "pw-fixture-3"))
  (add-member! conn #:user bob-id #:team tid2 #:role "member")
  (define bob (user-principal conn bob-id tid2))
  (define tid3 (create-team! conn #:name "third" #:slug "third" #:org org))
  (define carol-id (create-user! conn #:username "carol" #:password "pw-fixture-4"))
  (add-member! conn #:user carol-id #:team tid3 #:role "member")
  (define carol (user-principal conn carol-id tid3))
  (define id (kg-source-id "rcnt" "shared"))
  (define empty-id (kg-source-id "rcnt" "empty"))
  (define (extraction name) (hasheq 'entities (list (hasheq 'type "organization" 'name name 'snippet "x"))
                                    'relations '()))
  ;; THE SOURCE MUST BE REGISTERED BEFORE ANY READ, because a mention on a source id is only
  ;; visible while its source is; that is the fail-closed direction the design wants.
  (with-source "rcnt"
    (hasheq 'list (lambda (c p t l) '("shared" "empty"))
            'see (lambda (c p t d) (hasheq 'key d))
            'version (lambda (c p t d) "v1")
            'text (lambda (c p t d) "x"))
    (lambda ()
      ;; team one extracts it, then team two extracts the SAME document id at the same version
      (kg-upsert! conn tid1 id "v1" (extraction "Acme One"))
      (kg-upsert! conn tid2 id "v1" (extraction "Acme Two"))
      (check-equal? (map (lambda (e) (hash-ref e 'name)) (kg-find conn alice "Acme")) '("Acme One")
                    "the second team's write did not delete the first team's facts")
      (check-equal? (map (lambda (e) (hash-ref e 'name)) (kg-find conn bob "Acme")) '("Acme Two"))
      ;; and the lister agrees per team, which is the question that decides a re-extraction
      (check-equal? (kg-list-unextracted conn alice) (list empty-id))
      (check-equal? (kg-list-unextracted conn bob) (list empty-id))
      (check-equal? (kg-list-unextracted conn carol) (list id empty-id)
                    "a team that has not extracted it is still offered it")
      ;; an extraction that found nothing is the one case the shared marker answers for everyone,
      ;; because the same text yields nothing for anybody and a per-team retry could never differ
      (kg-upsert! conn tid1 empty-id "v1" (hasheq 'entities '() 'relations '()))
      (check-equal? (kg-list-unextracted conn alice) '())
      (check-equal? (kg-list-unextracted conn bob) '())
      (check-equal? (kg-list-unextracted conn carol) (list id)
                    "and the non-empty one is still this team's to do"))))

(test-case "a declared window is clamped to the platform's range in both directions"
  (register-extraction-source! "wide"
    (hasheq 'list (lambda (c p t l) '()) 'see (lambda (c p t d) (hasheq 'key d))
            'version (lambda (c p t d) "v1") 'text (lambda (c p t d) "x")
            'window (lambda (c p t d) 10000000)))
  (register-extraction-source! "tiny"
    (hasheq 'list (lambda (c p t l) '()) 'see (lambda (c p t d) (hasheq 'key d))
            'version (lambda (c p t d) "v1") 'text (lambda (c p t d) "x")
            'window (lambda (c p t d) 5)))
  (dynamic-wind void
    (lambda ()
      (check-equal? (source-window "wide" #f #f #f "d" 12000) 12000
                    "an oversized window is the default, not a ten-megabyte prompt")
      (check-equal? (source-window "tiny" #f #f #f "d" 12000) 12000
                    "an undersized window would split mid-sentence, so it is the default too"))
    (lambda () (unregister-extraction-source! "wide") (unregister-extraction-source! "tiny"))))

(test-case "a junk id from a source cannot fail the lister"
  (define conn (fresh))
  (define-values (uid tid) (bootstrap! conn #:username "alice"))
  (define alice (user-principal conn uid tid))
  (with-source "rcnt"
    (hasheq 'list (lambda (c p t l) (list "" "ok-1" #f 7 ""))
            'see (lambda (c p t d) (hasheq 'key d))
            'version (lambda (c p t d) "v1")
            'text (lambda (c p t d) "x"))
    (lambda ()
      (check-equal? (kg-list-unextracted conn alice) (list (kg-source-id "rcnt" "ok-1"))
                    "the empty and non-string ids are dropped rather than raised"))))

(test-case "forgetting works from a request, and is refused only when another plugin is the caller"
  (define conn (fresh))
  ;; registered as a plugin, which is the only time an identity exists
  (parameterize ([current-plugin 'plugin-a])
    (register-extraction-source! "theirs"
      (hasheq 'list (lambda (c p t l) '()) 'see (lambda (c p t d) (hasheq 'key d))
              'version (lambda (c p t d) "v1") 'text (lambda (c p t d) "x"))))
  (dynamic-wind void
    (lambda ()
      ;; A DELETE HANDLER RUNS WITH NO PLUGIN IDENTITY, and that is the shape the guide documents.
      ;; It must work, or the seam's only write hook never does.
      (check-not-exn (lambda () (kg-source-forget! conn "theirs" "d1")))
      ;; with an identity bound, a different plugin is refused
      (parameterize ([current-plugin 'plugin-b])
        (check-exn #rx"does not own the extraction source"
                   (lambda () (kg-source-forget! conn "theirs" "d1"))))
      (parameterize ([current-plugin 'plugin-a])
        (check-not-exn (lambda () (kg-source-forget! conn "theirs" "d1")))))
    (lambda () (unregister-extraction-source! "theirs"))))

(test-case "forgetting a document shared by two teams prunes both teams' orphans"
  (define conn (fresh))
  (define-values (uid1 tid1) (bootstrap! conn #:username "alice"))
  (define org (query-value conn "SELECT org_id FROM teams WHERE id = ?" tid1))
  (define tid2 (create-team! conn #:name "second" #:slug "second" #:org org))
  (define id (kg-source-id "rcnt" "shared2"))
  (define (extraction name) (hasheq 'entities (list (hasheq 'type "organization" 'name name 'snippet "x"))
                                    'relations '()))
  (with-source "rcnt"
    (hasheq 'list (lambda (c p t l) '()) 'see (lambda (c p t d) (hasheq 'key d))
            'version (lambda (c p t d) "v1") 'text (lambda (c p t d) "x"))
    (lambda ()
      (kg-upsert! conn tid1 id "v1" (extraction "Orphan One"))
      (kg-upsert! conn tid2 id "v1" (extraction "Orphan Two"))
      (check-equal? (query-value conn "SELECT COUNT(*) FROM kg_entities WHERE name IN ('Orphan One','Orphan Two')") 2)
      (parameterize ([current-plugin #f])
        (kg-source-forget! conn "rcnt" "shared2"))))
  ;; both teams' entities are gone, not only the one whose mention a LIMIT 1 happened to return
  (check-equal? (query-value conn "SELECT COUNT(*) FROM kg_entities WHERE team_id IN (?, ?) AND name LIKE 'Orphan%'" tid1 tid2)
                0
                "every team that held a fact was pruned"))
