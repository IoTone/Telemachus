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
