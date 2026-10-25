#lang racket/base

;; test/doc-triggers-tests.rkt — slice 58: uploads that TRIGGER a workflow (DWF-1…3).
;;   raco test test/doc-triggers-tests.rkt
;;
;; What this has to prove:
;;   1. the seam is inside repo-put!: a matching upload starts a run, as the uploader
;;   2. exactly once per version; a new version fires again; disabled fires never
;;   3. a pipeline's OWN OUTPUT does not re-trigger the pipeline (unless opted in)
;;   4. an uploader whose key cannot run workflows leaves an ERROR on the trigger,
;;      and the upload still lands
;;   5. the CRUD refuses what would never fire (an unpublished workflow)

(require rackunit db-kit/portable
         racket/port racket/string racket/file racket/list
         json
         db-kit/migrate
         "../domain/db/migrations.rkt"
         "db-fixture.rkt"
         "../domain/authz/authz.rkt"
         "../domain/repo/blobs.rkt"
         "../domain/repo/repo.rkt"
         "../domain/repo/doc-tools.rkt"          ; registers the tools
         "../domain/repo/triggers.rkt"           ; installs the seam
         "../domain/agent/registry.rkt"
         "../domain/agent/tools.rkt"
         "../domain/sched/scheduler.rkt"
         "../domain/flow/run.rkt"
         (prefix-in pipeline: "../plugins/doc-pipeline/main.rkt"))

(define BLOB-ROOT (make-temporary-file "telemachus-trigger-blobs-~a" 'directory))
(current-blob-root BLOB-ROOT)

(define (fresh)
  (define conn (fresh-db #:migrate? #f))
  (migrate! conn all-migrations)
  conn)

(define (drain! conn [limit 300])
  (let loop ([n 0]) (when (and (< n limit) (process-one! conn)) (loop (add1 n)))))

(define FIELDS (hasheq 'title "Acme invoice" 'summary "widgets and shipping"))
(define SCHEMA (hasheq 'type "object" 'required '("title" "summary")
                       'properties (hasheq 'title (hasheq 'type "string") 'summary (hasheq 'type "string"))))
(define (scripted prompt #:system [sys #f])
  (cond [(and sys (string-contains? sys "extract structured data")) (values (jsexpr->string FIELDS) 10)]
        [(and sys (string-contains? sys "translator")) (values (string-append "TR " prompt) 3)]
        [else (values "MOCK" 1)]))

(test-case "matching is prefix + content type, with a type wildcard"
  (define (t #:prefix [pre ""] #:types [ty ""]) (hasheq 'match_prefix pre 'match_types ty))
  (define (o key ct) (hasheq 'key key 'content_type ct))
  (check-true  (trigger-matches? (t) (o "anything.bin" "application/octet-stream")) "empty = any")
  (check-true  (trigger-matches? (t #:prefix "inbox/") (o "inbox/a.pdf" "application/pdf")))
  (check-false (trigger-matches? (t #:prefix "inbox/") (o "outbox/a.pdf" "application/pdf")))
  (check-true  (trigger-matches? (t #:types "application/pdf,text/plain") (o "x" "text/plain")))
  (check-false (trigger-matches? (t #:types "application/pdf") (o "x" "text/plain")))
  (check-true  (trigger-matches? (t #:types "image/*") (o "x" "image/png")) "type/* matches the family")
  (check-false (trigger-matches? (t #:types "image/*") (o "x" "text/plain"))))

(test-case "an upload into a triggered prefix runs the pipeline as the uploader, exactly once per version"
  (define conn (fresh))
  (define-values (uid tid) (bootstrap! conn #:username "alice"))
  (define alice (user-principal conn uid tid))
  (define bob-id (create-user! conn #:username "bob" #:password "pw"))
  (add-member! conn #:user bob-id #:team tid #:role "member")
  (define bob (user-principal conn bob-id tid))
  (register-plugin-workflow! "doc-pipeline" (car pipeline:workflows))

  (define (up! p key bytes #:ct [ct "text/plain"] #:vis [vis "team"])
    (repo-put! conn p #:key key #:port (open-input-bytes bytes) #:content-type ct #:filename key #:visibility vis))
  (define (by-key key) (repo-get conn alice key #:by-key tid))
  (define (fires t) (trigger-fires conn alice (hash-ref t 'id)))
  (define (runs) (flow-runs conn alice))

  ;; the CRUD refuses what would never fire
  (check-exn #rx"not published in this team"
             (lambda () (trigger-create! conn alice #:workflow "no-such-workflow" #:prefix "inbox/")))
  (check-exn #rx"must not start with /"
             (lambda () (trigger-create! conn alice #:workflow "process-upload" #:prefix "/inbox/")))
  (check-exn exn:fail:forbidden?
             (lambda () (trigger-create! conn bob #:workflow "process-upload" #:prefix "inbox/"))
             "a member (no workflows:write) cannot create a trigger")

  (define t (trigger-create! conn alice #:workflow "process-upload" #:prefix "inbox/"
                             #:types "text/plain, application/pdf"
                             #:input (hasheq 'schema SCHEMA 'template "" 'locales '("nl"))))
  (check-equal? (hash-ref t 'match_types) "text/plain,application/pdf" "types are normalized")
  (check-equal? (length (trigger-list conn bob)) 1 "a member can see the team's triggers")

  ;; nothing has fired yet; a non-matching upload changes nothing
  (up! alice "outbox/ignored.txt" #"nothing here")
  (up! alice "inbox/photo.png" #"\x89PNG" #:ct "image/png")
  (check-equal? (fires t) '() "prefix and type both have to match")
  (check-equal? (runs) '())

  ;; bob uploads a matching document: the run is BOB'S, and it completes through the engine
  (define doc
    (parameterize ([current-doc-chat scripted])
      (define o (up! bob "inbox/acme.txt" #"INVOICE Acme widgets"))
      (drain! conn)
      o))
  (define f (fires t))
  (check-equal? (length f) 1 "one fire")
  (check-equal? (hash-ref (car f) 'version_id) (hash-ref doc 'version_id))
  (check-equal? (hash-ref (car f) 'key) "inbox/acme.txt")
  (check-equal? (hash-ref (car f) 'error) 'null)
  (define run (flow-run-get conn alice (hash-ref (car f) 'run_id)))
  (check-equal? (hash-ref run 'status) "done" (format "the triggered run finished (error: ~a)" (hash-ref run 'error)))
  (check-equal? (hash-ref run 'user_id) bob-id "the run executes as the UPLOADER (DWF-2)")
  (define in (hash-ref run 'input))
  (check-equal? (hash-ref in 'object_id) (hash-ref doc 'id) "the arrival is the run's input…")
  (check-equal? (hash-ref in 'key) "inbox/acme.txt")
  (check-equal? (hash-ref in 'content_type) "text/plain")
  (check-equal? (hash-ref in 'locales) '("nl") "…merged with the trigger's own configuration")
  (check-equal? (hash-ref in 'template) "")
  ;; the outputs landed beside the source, owned by bob
  (define fields (by-key "inbox/acme.txt.extracted.json"))
  (check-true (and fields #t))
  (check-equal? (hash-ref fields 'owner_user_id) bob-id)
  (check-true (and (by-key "inbox/acme.nl.txt") #t) "no template, so the source was translated")

  ;; DWF-3: the pipeline wrote inbox/acme.txt.extracted.json and inbox/acme.nl.txt —
  ;; both match the trigger's prefix and type, and neither may re-fire it
  (check-equal? (length (fires t)) 1 "derived documents did not re-trigger the pipeline")
  (check-equal? (length (runs)) 1)

  ;; exactly once: the seam on the SAME version is a no-op
  (fire-triggers! conn bob doc)
  (check-equal? (length (fires t)) 1 "the same version does not fire twice")
  ;; a new version fires again
  (define doc2
    (parameterize ([current-doc-chat scripted])
      (define o (up! bob "inbox/acme.txt" #"INVOICE Acme widgets, revised"))
      (drain! conn)
      o))
  (check-equal? (length (fires t)) 2 "a re-upload is a new version and fires again")
  (check-equal? (hash-ref (car (fires t)) 'version_id) (hash-ref doc2 'version_id) "newest first")
  (check-equal? (hash-ref (by-key "inbox/acme.txt.extracted.json") 'version) 2 "…and superseded its output")

  ;; disabled: nothing
  (trigger-update! conn alice (hash-ref t 'id) (hasheq 'enabled #f))
  (up! alice "inbox/quiet.txt" #"shh")
  (check-equal? (length (fires t)) 2 "a disabled trigger is silent")
  (trigger-update! conn alice (hash-ref t 'id) (hasheq 'enabled #t))

  ;; opting in to derived documents: a second trigger on the extracted JSON
  (define t2 (trigger-create! conn alice #:workflow "process-upload" #:prefix "inbox/" #:types "application/json"
                              #:fire-on-derived? #t
                              #:input (hasheq 'schema SCHEMA 'template "" 'locales '())))
  (parameterize ([current-doc-chat scripted])
    (up! alice "inbox/third.txt" #"a third document")
    (drain! conn))
  (check-equal? (length (fires t2)) 1 "the opted-in trigger fired on the pipeline's JSON output")
  (check-equal? (hash-ref (car (fires t2)) 'key) "inbox/third.txt.extracted.json")
  ;; …and its OWN output (inbox/third.txt.extracted.json.extracted.json) matches it
  ;; too, and must not fire it: an opted-in trigger fires on other pipelines'
  ;; outputs, never on its own, or it runs forever
  (check-true (and (by-key "inbox/third.txt.extracted.json.extracted.json") #t) "t2's run wrote its output")
  (check-equal? (length (fires t2)) 1 "…which did not fire t2 again")
  (check-equal? (length (fires t)) 3 "t fired once for third.txt and never for the derived JSON")

  ;; an uploader whose token cannot run workflows: the upload lands, the fire records why
  (define-values (raw _tid) (issue-token! conn #:user bob-id #:team tid #:scopes '("files:read" "files:write")))
  (define scoped (resolve-token conn raw))
  (define before (length (runs)))
  (define narrow (up! scoped "inbox/from-a-key.txt" #"uploaded with a files-only key"))
  (check-true (and narrow #t) "the upload succeeded")
  (define nf (car (fires t)))
  (check-equal? (hash-ref nf 'key) "inbox/from-a-key.txt")
  (check-equal? (hash-ref nf 'run_id) 'null "no run was started")
  (check-true (regexp-match? #rx"workflows:run" (hash-ref nf 'error)) "…and the trigger's history says why")
  ;; …and the AUDIT entry does NOT repeat it (#83 r4). The fire row above is the
  ;; one home for the message, and #59 purges it; the audit log is deliberately
  ;; kept through an erasure (DEL-7), so a tool message quoting a document used to
  ;; outlive every other copy of it there. The entry carries ids a reader can join
  ;; under access control, which is #84 r2's rule, and no prose.
  (let ([meta (query-value conn (string-append "SELECT meta FROM audit_log WHERE action = 'doc.trigger.error' "
                                               "ORDER BY at DESC, at_us DESC LIMIT 1"))])
    (check-false (regexp-match? #rx"workflows:run" meta)
                 (format "the failure message reached the audit log: ~a" meta))
    (check-true (regexp-match? #rx"version_id" meta) "…while still naming what it happened to"))
  (check-equal? (length (runs)) before)
  ;; the same key WITH the scope fires
  (define-values (raw2 _tid2) (issue-token! conn #:user bob-id #:team tid
                                            #:scopes '("files:read" "files:write" "workflows:read" "workflows:run")))
  (parameterize ([current-doc-chat scripted])
    (up! (resolve-token conn raw2) "inbox/from-a-key.txt" #"second version, wider key")
    (drain! conn))
  (check-equal? (hash-ref (car (fires t)) 'error) 'null)
  (check-not-equal? (hash-ref (car (fires t)) 'run_id) 'null "a key with workflows:run starts the run")

  ;; delete takes the history with it; runs stay
  (define n-runs (length (runs)))
  (check-true (trigger-delete! conn alice (hash-ref t 'id)))
  (check-false (trigger-get conn alice (hash-ref t 'id)))
  (check-equal? (length (runs)) n-runs "the runs a trigger started are ordinary runs and remain")
  (disconnect conn))

;; ---- issue #87 req 3b: a trigger that matches on object METADATA (CLS-19…23) -------
;; Slices 1 and 2 record a document's type; this is the half that makes the type
;; actionable. The hard part is not the matching — it is that a metadata condition
;; cannot be evaluated at the moment a document arrives, because nothing has
;; classified it yet, so the feature needs a SECOND seam and that seam has to be
;; bounded.

(test-case "CLS-19: matching on attributes is equality, and every named one must hold"
  (define (t attrs #:prefix [pre ""]) (hasheq 'match_prefix pre 'match_types "" 'match_attrs attrs))
  (define (o attrs #:key [key "inbox/a.txt"]) (hasheq 'key key 'content_type "text/plain" 'attributes attrs))
  (check-true (trigger-matches? (t (hasheq)) (o (hasheq))) "no condition = any, as before")
  (check-true (trigger-matches? (t (hasheq 'doc_type "invoice")) (o (hasheq 'doc_type "invoice"))))
  (check-false (trigger-matches? (t (hasheq 'doc_type "invoice")) (o (hasheq 'doc_type "letter"))))
  ;; an ABSENT attribute never matches, which is exactly what makes `doc_type`
  ;; usable before anything has classified the document: at upload the condition
  ;; is simply false, and the trigger waits for the second seam
  (check-false (trigger-matches? (t (hasheq 'doc_type "invoice")) (o (hasheq))))
  ;; equality, not a prefix and not a glob — the condition is operator-authored
  ;; and runs on the write path of every document the team stores
  (check-false (trigger-matches? (t (hasheq 'doc_type "inv")) (o (hasheq 'doc_type "invoice"))))
  ;; ALL of them: an AND, so adding a condition can only narrow
  (check-true (trigger-matches? (t (hasheq 'doc_type "invoice" 'project "levee"))
                                (o (hasheq 'doc_type "invoice" 'project "levee" 'status "open"))))
  (check-false (trigger-matches? (t (hasheq 'doc_type "invoice" 'project "levee"))
                                 (o (hasheq 'doc_type "invoice"))))
  ;; and it composes with what was already there rather than replacing it
  (check-false (trigger-matches? (t (hasheq 'doc_type "invoice") #:prefix "inbox/")
                                 (o (hasheq 'doc_type "invoice") #:key "outbox/a.txt"))))

(test-case "a condition that could never match is refused at the write"
  (define conn (fresh))
  (define-values (uid tid) (bootstrap! conn #:username "alice"))
  (define alice (user-principal conn uid tid))
  (register-plugin-workflow! "doc-pipeline" (car pipeline:workflows))
  (define (mk attrs) (trigger-create! conn alice #:workflow "process-upload" #:attrs attrs))
  (check-true (hash? (mk (hasheq 'doc_type "invoice"))))
  ;; LAY-4 values ARE strings, so a number or a boolean here is a condition that
  ;; can never hold. Refused rather than coerced: a trigger that silently never
  ;; fires is the hardest thing on this surface to diagnose.
  (check-exn #rx"must be a string" (lambda () (mk (hasheq 'doc_type 3))))
  (check-exn #rx"must be a string" (lambda () (mk (hasheq 'doc_type #t))))
  ;; an empty value is "not set", which is not a thing to match ON
  (check-exn #rx"is empty" (lambda () (mk (hasheq 'doc_type ""))))
  ;; the key vocabulary is LAY-4's, through LAY-4's own predicate — a dot is not a
  ;; legal attribute key, which is the whole reason CLS-7 spells these with
  ;; underscores, and a condition naming `doc.type` would never fire
  (check-exn #rx"not a valid attribute key" (lambda () (mk (hasheq '|doc.type| "invoice"))))
  (check-exn #rx"not a valid attribute key" (lambda () (mk (hasheq 'Doc_Type "invoice"))))
  (check-exn #rx"JSON object" (lambda () (trigger-create! conn alice #:workflow "process-upload"
                                                          #:attrs "doc_type:invoice")))
  (check-exn #rx"at most 10"
             (lambda () (mk (for/hasheq ([i (in-range 11)])
                              (values (string->symbol (format "k~a" i)) "v")))))
  ;; …and the same validation on the way through an update, or a trigger could
  ;; reach a state a create would have refused
  (define t (mk (hasheq 'doc_type "letter")))
  (check-exn #rx"must be a string"
             (lambda () (trigger-update! conn alice (hash-ref t 'id) (hasheq 'match_attrs (hasheq 'doc_type 1)))))
  (check-equal? (hash-ref (trigger-get conn alice (hash-ref t 'id)) 'match_attrs) (hasheq 'doc_type "letter"))
  ;; clearing it is how you go back to firing on arrival alone
  (check-equal? (hash-ref (trigger-update! conn alice (hash-ref t 'id) (hasheq 'match_attrs 'null)) 'match_attrs)
                (hasheq)))

(test-case "CLS-20: the type a tool records is what fires the trigger"
  ;; The acceptance shape for requirement 3: classify a document, and a pipeline
  ;; for THAT kind of document starts by itself. Nothing about the upload could
  ;; have said so — at `repo-put!` the document had no type.
  (define conn (fresh))
  (define-values (uid tid) (bootstrap! conn #:username "alice"))
  (define alice (user-principal conn uid tid))
  (register-plugin-workflow! "doc-pipeline" (car pipeline:workflows))
  (define t (trigger-create! conn alice #:workflow "process-upload"
                             #:attrs (hasheq 'doc_type "invoice")
                             #:input (hasheq 'schema SCHEMA 'template "" 'locales '())))
  ;; a trigger with no condition, to prove the arrival itself fired nothing
  (define obj (repo-put! conn alice #:key "mixed/a.txt"
                         #:port (open-input-bytes #"INVOICE 4471\nTotal due 1250.50")
                         #:content-type "text/plain" #:filename "a.txt" #:visibility "team"))
  (check-equal? (trigger-fires conn alice (hash-ref t 'id)) '()
                "the upload fired nothing: the document had no type yet")

  ;; now classify it, with a rule — no model, so this is deterministic
  (parameterize ([current-doc-chat scripted])
    ((tool-handler (tool-by-name "doc_classify")) conn alice
     (hasheq 'object (hash-ref obj 'id) 'backends '("rules")
             'labels (list (hasheq 'name "invoice") (hasheq 'name "letter"))
             'rules (list (hasheq 'label "invoice" 'any '("Total due"))))))

  (define fires (trigger-fires conn alice (hash-ref t 'id)))
  (check-equal? (length fires) 1 "recording the type fired the trigger")
  (check-equal? (hash-ref (car fires) 'object_id) (hash-ref obj 'id))
  (check-equal? (hash-ref (car fires) 'error) 'null)
  (check-true (string? (hash-ref (car fires) 'run_id)) "and it started a run")

  ;; and the run really ran the pipeline the type chose
  (parameterize ([current-doc-chat scripted]) (drain! conn))
  (check-equal? (query-value conn "SELECT status FROM workflow_runs WHERE id = ?" (hash-ref (car fires) 'run_id))
                "done")
  (check-true (and (repo-get conn alice "mixed/a.txt.extracted.json" #:by-key tid) #t)
              "the fields were extracted by a run nobody started by hand")

  ;; CLS-21: exactly-once is still per (trigger, version), which is what BOUNDS
  ;; the loop this seam introduces — re-recording the same type on the same
  ;; version cannot start a second run.
  (repo-set-attributes! conn alice (hash-ref obj 'id) (hasheq 'doc_type "invoice"))
  (check-equal? (length (trigger-fires conn alice (hash-ref t 'id))) 1 "no second fire for the same version")
  ;; a correction to a type the trigger does not want does not fire it either
  (repo-set-attributes! conn alice (hash-ref obj 'id) (hasheq 'doc_type "letter"))
  (check-equal? (length (trigger-fires conn alice (hash-ref t 'id))) 1))

(test-case "CLS-23: a trigger that names no attributes is untouched by the new seam"
  ;; the compatibility guarantee. Every trigger anybody has configured matches on
  ;; a prefix and a content type, both FIXED for the life of a version — so
  ;; firing them on an attribute edit would be a behaviour change for every
  ;; existing deployment, and somebody correcting a typo in a `project` field
  ;; would start pipelines.
  (define conn (fresh))
  (define-values (uid tid) (bootstrap! conn #:username "alice"))
  (define alice (user-principal conn uid tid))
  (register-plugin-workflow! "doc-pipeline" (car pipeline:workflows))
  (define plain (trigger-create! conn alice #:workflow "process-upload" #:prefix "edited/"
                                 #:input (hasheq 'schema SCHEMA 'template "" 'locales '())))
  (repo-fields-set! conn tid (list (hasheq 'key "project" 'label "Project")
                                   (hasheq 'key "doc_type" 'label "Type")))
  (define obj (repo-put! conn alice #:key "edited/a.txt" #:port (open-input-bytes #"x")
                         #:content-type "text/plain" #:filename "a.txt" #:visibility "team"))
  (check-equal? (length (trigger-fires conn alice (hash-ref plain 'id))) 1 "the arrival fired it, as always")
  ;; a new version would fire again; an attribute edit must not
  (repo-set-attributes! conn alice (hash-ref obj 'id) (hasheq 'project "levee"))
  (check-equal? (length (trigger-fires conn alice (hash-ref plain 'id))) 1
                "editing metadata did not fire a trigger that does not mention metadata")

  ;; and a trigger that DOES name attributes only wakes for the attributes it
  ;; names — setting `project` must not fire one waiting on `doc_type`, even while
  ;; its condition happens to hold
  (define typed (trigger-create! conn alice #:workflow "process-upload"
                                 #:attrs (hasheq 'doc_type "invoice")
                                 #:input (hasheq 'schema SCHEMA 'template "" 'locales '())))
  (repo-set-attributes! conn alice (hash-ref obj 'id) (hasheq 'doc_type "invoice"))
  (check-equal? (length (trigger-fires conn alice (hash-ref typed 'id))) 1)
  (define obj2 (repo-put! conn alice #:key "edited/b.txt" #:port (open-input-bytes #"y")
                          #:content-type "text/plain" #:filename "b.txt" #:visibility "team"))
  (repo-set-attributes! conn alice (hash-ref obj2 'id) (hasheq 'doc_type "invoice"))
  (check-equal? (length (trigger-fires conn alice (hash-ref typed 'id))) 2)
  (repo-set-attributes! conn alice (hash-ref obj2 'id) (hasheq 'project "levee"))
  (check-equal? (length (trigger-fires conn alice (hash-ref typed 'id))) 2
                "an unrelated attribute did not wake it")
  ;; a write that changes NOTHING fires nothing: the seam reports the keys it
  ;; moved, not the keys it was handed
  (define obj3 (repo-put! conn alice #:key "edited/c.txt" #:port (open-input-bytes #"z")
                          #:content-type "text/plain" #:filename "c.txt" #:visibility "team"))
  (repo-set-attributes! conn alice (hash-ref obj3 'id) (hasheq 'doc_type "letter"))
  (check-equal? (length (trigger-fires conn alice (hash-ref typed 'id))) 2)
  (repo-set-attributes! conn alice (hash-ref obj3 'id) (hasheq 'doc_type "invoice"))
  (check-equal? (length (trigger-fires conn alice (hash-ref typed 'id))) 3)
  (repo-set-attributes! conn alice (hash-ref obj3 'id) (hasheq 'doc_type "invoice"))
  (check-equal? (length (trigger-fires conn alice (hash-ref typed 'id))) 3 "idempotent re-write, no fire"))

(test-case "a DERIVED document's metadata obeys fire_on_derived, as its arrival does"
  (define conn (fresh))
  (define-values (uid tid) (bootstrap! conn #:username "alice"))
  (define alice (user-principal conn uid tid))
  (register-plugin-workflow! "doc-pipeline" (car pipeline:workflows))
  (repo-fields-set! conn tid (list (hasheq 'key "doc_type" 'label "Type")))
  (define src (repo-put! conn alice #:key "src/a.txt" #:port (open-input-bytes #"x")
                         #:content-type "text/plain" #:filename "a.txt" #:visibility "team"))
  (define out (repo-put! conn alice #:key "src/a.txt.extracted.json" #:port (open-input-bytes #"{}")
                         #:content-type "application/json" #:filename "a.json" #:visibility "team"))
  (repo-inherit! conn alice #:source (hash-ref src 'id) #:target (hash-ref out 'id))
  (define off (trigger-create! conn alice #:workflow "process-upload"
                               #:attrs (hasheq 'doc_type "invoice")
                               #:input (hasheq 'schema SCHEMA 'template "" 'locales '())))
  (repo-set-attributes! conn alice (hash-ref out 'id) (hasheq 'doc_type "invoice"))
  (check-equal? (trigger-fires conn alice (hash-ref off 'id)) '()
                "a derived document's type does not fire a trigger that is not opted in")
  (define on (trigger-create! conn alice #:workflow "process-upload"
                              #:attrs (hasheq 'doc_type "invoice") #:fire-on-derived? #t
                              #:input (hasheq 'schema SCHEMA 'template "" 'locales '())))
  (repo-set-attributes! conn alice (hash-ref out 'id) (hasheq 'doc_type "letter"))
  (repo-set-attributes! conn alice (hash-ref out 'id) (hasheq 'doc_type "invoice"))
  (check-equal? (length (trigger-fires conn alice (hash-ref on 'id))) 1 "…and does fire one that is"))

(test-case "a trigger is not a backfill: it wakes for the attributes it NAMES, and only when they move"
  ;; The two assertions in the case above cannot see this, and the controls are
  ;; what showed me: once a trigger has fired on a version, exactly-once hides
  ;; every later mistake about WHEN it would have fired. So this trigger is
  ;; created AFTER the type is already on the document — the one state in which
  ;; the seam's own conditions are the only thing deciding.
  (define conn (fresh))
  (define-values (uid tid) (bootstrap! conn #:username "alice"))
  (define alice (user-principal conn uid tid))
  (register-plugin-workflow! "doc-pipeline" (car pipeline:workflows))
  (repo-fields-set! conn tid (list (hasheq 'key "doc_type" 'label "Type")
                                   (hasheq 'key "project" 'label "Project")))
  (define obj (repo-put! conn alice #:key "late/a.txt" #:port (open-input-bytes #"x")
                         #:content-type "text/plain" #:filename "a.txt" #:visibility "team"))
  (repo-set-attributes! conn alice (hash-ref obj 'id) (hasheq 'doc_type "invoice"))

  (define late (trigger-create! conn alice #:workflow "process-upload"
                                #:attrs (hasheq 'doc_type "invoice")
                                #:input (hasheq 'schema SCHEMA 'template "" 'locales '())))
  (check-equal? (trigger-fires conn alice (hash-ref late 'id)) '()
                "creating it does not fire it on documents that already match — that is req 5's backfill")

  ;; an UNRELATED attribute moves. The condition holds, and it held a moment ago
  ;; too, so there is no news here — firing would make every metadata edit in the
  ;; team a pipeline start.
  (repo-set-attributes! conn alice (hash-ref obj 'id) (hasheq 'project "levee"))
  (check-equal? (trigger-fires conn alice (hash-ref late 'id)) '()
                "editing `project` did not wake a trigger watching `doc_type`")

  ;; the SAME value written again moves nothing, so there is nothing to report
  (repo-set-attributes! conn alice (hash-ref obj 'id) (hasheq 'doc_type "invoice"))
  (check-equal? (trigger-fires conn alice (hash-ref late 'id)) '()
                "and re-writing the same type is not a change")

  ;; …but a real transition is, even back to a value the document held before
  (repo-set-attributes! conn alice (hash-ref obj 'id) (hasheq 'doc_type "letter"))
  (check-equal? (trigger-fires conn alice (hash-ref late 'id)) '())
  (repo-set-attributes! conn alice (hash-ref obj 'id) (hasheq 'doc_type "invoice"))
  (check-equal? (length (trigger-fires conn alice (hash-ref late 'id))) 1
                "the type became `invoice`, which is the event this trigger is for"))
