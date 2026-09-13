#lang racket/base

;; domain/repo/triggers.rkt — upload triggers (slice 58, DWF-1…3): a team-scoped
;; subscription, "when a document matching this lands, run that workflow with it".
;;
;; Requiring this module installs the subscriber on repo-put!'s post-write seam.
;; A match ENQUEUES a run — flow-run-start! writes the run row and queues its
;; first step as a scheduler job — so the upload returns as fast as it does
;; today and the run inherits quota admission, cancellation, the org gate and
;; durability across a restart. Five hundred scans are five hundred queued runs
;; under the governor's cap, not a five-hundred-way fan-out against the model.
;;
;; The run executes AS THE UPLOADER (DWF-2): whoever repo-put! ran as — a person
;; in the console, or the S3 key's user with the key's scopes. A key issued with
;; the default files:* scopes cannot start a workflow; issue it with
;; "workflows:run" (and "workflows:read") for a prefix that is meant to fire.
;; The failure is recorded on the trigger, never raised into the upload.

(require db-kit/portable
         racket/string racket/list
         json
         "../db/id.rkt"
         "../authz/authz.rkt"
         "../flow/run.rkt"
         "repo.rkt")

(provide trigger-create! trigger-list trigger-get trigger-update! trigger-delete!
         trigger-fires trigger-matches? fire-triggers!
         object-processing)

(define (nz x) (if (sql-null? x) 'null x))
(define (bool x) (and (number? x) (not (zero? x))))

(define TSELECT
  (string-append "SELECT id, team_id, workflow_slug, enabled, match_prefix, match_types, input, "
                 "fire_on_derived, created_by, created_at, updated_at FROM doc_triggers"))

(define (row->trigger r)
  (hasheq 'id (vector-ref r 0) 'team_id (vector-ref r 1) 'workflow_slug (vector-ref r 2)
          'enabled (bool (vector-ref r 3))
          'match_prefix (vector-ref r 4) 'match_types (vector-ref r 5)
          'input (with-handlers ([exn:fail? (lambda (_) (hasheq))])
                   (let ([j (string->jsexpr (vector-ref r 6))]) (if (hash? j) j (hasheq))))
          'fire_on_derived (bool (vector-ref r 7))
          'created_by (nz (vector-ref r 8))
          'created_at (format "~a" (vector-ref r 9)) 'updated_at (format "~a" (vector-ref r 10))))

(define (trigger-row conn id)
  (query-maybe-row conn (string-append TSELECT " WHERE id = ?") id))

;; a trigger is a team resource: reading it is workflows:read, changing it
;; workflows:write, both team-scoped and both behind the org gate
(define (trigger-resource t)
  (hasheq 'resource_type "doc_triggers" 'resource_id (hash-ref t 'id)
          'team_id (hash-ref t 'team_id) 'owner_user_id (hash-ref t 'created_by) 'visibility "team"))

;; ---- validation --------------------------------------------------------------------
(define (check-prefix! prefix)
  (unless (string? prefix) (raise-user-error 'triggers "match_prefix must be a string"))
  (when (regexp-match? #px"[\u0000-\u001F\u007F\\\\]" prefix)
    (raise-user-error 'triggers "match_prefix contains control characters"))
  (when (string-prefix? prefix "/") (raise-user-error 'triggers "match_prefix must not start with /")))

(define (normalize-types v)
  (cond
    [(or (not v) (eq? v 'null)) ""]
    [(string? v) (string-join (filter (lambda (s) (not (string=? s ""))) (map string-trim (string-split v ","))) ",")]
    [(and (list? v) (andmap string? v)) (normalize-types (string-join v ","))]
    [else (raise-user-error 'triggers "match_types must be a comma-separated string or an array of strings")]))

(define (check-workflow! conn p slug)
  (unless (and (string? slug) (not (string=? (string-trim slug) "")))
    (raise-user-error 'triggers "workflow_slug is required"))
  (unless (flow-def-by-slug conn p slug)
    (raise-user-error 'triggers "workflow '~a' is not published in this team" slug)))

;; ---- CRUD ----------------------------------------------------------------------------
(define (trigger-create! conn p #:workflow slug #:prefix [prefix ""] #:types [types ""]
                         #:input [input (hasheq)] #:fire-on-derived? [derived? #f] #:enabled? [enabled? #t])
  (require-perm conn p "workflows:write")
  (check-workflow! conn p slug)
  (check-prefix! prefix)
  (unless (hash? input) (raise-user-error 'triggers "input must be a JSON object"))
  (define id (new-id))
  (query-exec conn
    (string-append "INSERT INTO doc_triggers (id, team_id, workflow_slug, enabled, match_prefix, match_types, "
                   "input, fire_on_derived, created_by) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)")
    id (principal-team-id p) slug (if enabled? 1 0) prefix (normalize-types types)
    (jsexpr->string input) (if derived? 1 0) (principal-user-id p))
  (audit! conn #:action "doc.trigger.create" #:actor-type "user" #:actor-id (principal-user-id p)
          #:team-id (principal-team-id p) #:resource-type "doc_triggers" #:resource-id id
          #:meta (jsexpr->string (hasheq 'workflow slug 'prefix prefix)))
  (row->trigger (trigger-row conn id)))

(define (trigger-list conn p)
  (require-perm conn p "workflows:read")
  (for/list ([r (in-list (query-rows conn (string-append TSELECT " WHERE team_id = ? ORDER BY created_at ASC, id ASC")
                                     (principal-team-id p)))])
    (row->trigger r)))

(define (trigger-get conn p id)
  (define r (trigger-row conn id))
  (and r (let ([t (row->trigger r)])
           (require-perm conn p "workflows:read" #:resource (trigger-resource t))
           t)))

;; fields absent from `changes` are left alone
(define (trigger-update! conn p id changes)
  (define t (trigger-get conn p id))
  (and t
       (let ()
         (require-perm conn p "workflows:write" #:resource (trigger-resource t))
         (define (want k) (hash-ref changes k 'absent))
         (define slug (let ([v (want 'workflow_slug)]) (if (eq? v 'absent) (hash-ref t 'workflow_slug) v)))
         (define prefix (let ([v (want 'match_prefix)]) (if (eq? v 'absent) (hash-ref t 'match_prefix) v)))
         (define types (let ([v (want 'match_types)]) (if (eq? v 'absent) (hash-ref t 'match_types) (normalize-types v))))
         (define input (let ([v (want 'input)]) (if (eq? v 'absent) (hash-ref t 'input) v)))
         (define enabled? (let ([v (want 'enabled)]) (if (eq? v 'absent) (hash-ref t 'enabled) (and v (not (eq? v 'null))))))
         (define derived? (let ([v (want 'fire_on_derived)]) (if (eq? v 'absent) (hash-ref t 'fire_on_derived) (and v (not (eq? v 'null))))))
         (unless (equal? slug (hash-ref t 'workflow_slug)) (check-workflow! conn p slug))
         (check-prefix! prefix)
         (unless (hash? input) (raise-user-error 'triggers "input must be a JSON object"))
         (query-exec conn
           (string-append "UPDATE doc_triggers SET workflow_slug = ?, enabled = ?, match_prefix = ?, match_types = ?, "
                          "input = ?, fire_on_derived = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ?")
           slug (if enabled? 1 0) prefix types (jsexpr->string input) (if derived? 1 0) id)
         (audit! conn #:action "doc.trigger.update" #:actor-type "user" #:actor-id (principal-user-id p)
                 #:team-id (hash-ref t 'team_id) #:resource-type "doc_triggers" #:resource-id id
                 #:meta (jsexpr->string (hasheq 'enabled enabled?)))
         (row->trigger (trigger-row conn id)))))

;; the fire history goes with it — the runs it started are ordinary runs and stay
(define (trigger-delete! conn p id)
  (define t (trigger-get conn p id))
  (and t
       (let ()
         (require-perm conn p "workflows:write" #:resource (trigger-resource t))
         (query-exec conn "DELETE FROM doc_trigger_fires WHERE trigger_id = ?" id)
         (query-exec conn "DELETE FROM doc_triggers WHERE id = ?" id)
         (audit! conn #:action "doc.trigger.delete" #:actor-type "user" #:actor-id (principal-user-id p)
                 #:team-id (hash-ref t 'team_id) #:resource-type "doc_triggers" #:resource-id id)
         #t)))

;; what a trigger did, newest first: which version, which run, or why not
(define (trigger-fires conn p id #:limit [lim 50])
  (define t (trigger-get conn p id))
  (and t
       (for/list ([r (in-list (query-rows conn
              (string-append "SELECT f.version_id, f.object_id, f.run_id, f.error, f.fired_at, o.key "
                             "FROM doc_trigger_fires f LEFT JOIN repo_objects o ON o.id = f.object_id "
                             "WHERE f.trigger_id = ? ORDER BY f.fired_ms DESC, f.version_id DESC LIMIT ?")
              id lim))])
         (hasheq 'version_id (vector-ref r 0) 'object_id (vector-ref r 1)
                 'run_id (nz (vector-ref r 2)) 'error (nz (vector-ref r 3))
                 'fired_at (format "~a" (vector-ref r 4)) 'key (nz (vector-ref r 5))))))

;; ---- matching ------------------------------------------------------------------------
(define (type-matches? pattern ct)
  (or (string=? pattern ct)
      (and (string-suffix? pattern "/*")
           (string-prefix? ct (substring pattern 0 (sub1 (string-length pattern)))))))

(define (trigger-matches? t obj)
  (define prefix (hash-ref t 'match_prefix ""))
  (define types (let ([s (hash-ref t 'match_types "")])
                  (if (string=? s "") '() (string-split s ","))))
  (and (string-prefix? (hash-ref obj 'key) prefix)
       (or (null? types)
           (for/or ([pat (in-list types)]) (type-matches? (string-trim pat) (hash-ref obj 'content_type))))))

;; ---- the seam ------------------------------------------------------------------------
(define (derived-object? conn obj)
  (positive? (query-value conn "SELECT COUNT(*) FROM repo_derivations WHERE object_id = ?" (hash-ref obj 'id))))

;; Is this object the output of a run THIS trigger started? An opted-in trigger
;; fires on other pipelines' outputs (index every extracted JSON, say), never on
;; its own: a pipeline whose output matches its own trigger would otherwise run
;; itself forever, and "the operator opted in" is no consolation at 3 a.m. One
;; level is enough — every derived document names the run that made it, and every
;; run a trigger started is in its fire history.
;;
;; `derived?` is what the writer said: #t, or the id of the run writing it. The
;; run id matters because the derivation row is written AFTER repo-put! returns —
;; at the seam it does not exist yet, so a fresh output is recognized by the run
;; id the tool passed, and a re-upload of an old output by the rows it has.
(define (own-descendant? conn t obj derived?)
  (or (and (string? derived?)
           (positive? (query-value conn
             "SELECT COUNT(*) FROM doc_trigger_fires WHERE trigger_id = ? AND run_id = ?"
             (hash-ref t 'id) derived?)))
      (positive? (query-value conn
        (string-append "SELECT COUNT(*) FROM repo_derivations d "
                       "JOIN doc_trigger_fires f ON f.run_id = d.run_id "
                       "WHERE d.object_id = ? AND f.trigger_id = ?")
        (hash-ref obj 'id) (hash-ref t 'id)))))

;; the run's input: the arrival, plus the trigger's own configuration. The arrival
;; WINS on a clash — a trigger's input can carry a schema or a template, never
;; redirect the run at a different document.
(define (run-input t obj)
  (for/fold ([h (hash-ref t 'input (hasheq))])
            ([(k v) (in-hash (hasheq 'object_id (hash-ref obj 'id) 'version_id (hash-ref obj 'version_id)
                                     'key (hash-ref obj 'key) 'content_type (hash-ref obj 'content_type)))])
    (hash-set h k v)))

(define (fire-one! conn p t obj)
  (define tid (hash-ref t 'id))
  (define vid (hash-ref obj 'version_id))
  ;; exactly once per version (DWF-3): the row is claimed BEFORE the run starts
  (unless (query-maybe-value conn "SELECT 1 FROM doc_trigger_fires WHERE trigger_id = ? AND version_id = ?" tid vid)
    (query-exec conn "INSERT INTO doc_trigger_fires (trigger_id, version_id, object_id, fired_ms) VALUES (?, ?, ?, ?)"
                tid vid (hash-ref obj 'id) (inexact->exact (floor (current-inexact-milliseconds))))
    (with-handlers ([exn:fail?
                     (lambda (e)
                       (query-exec conn "UPDATE doc_trigger_fires SET error = ? WHERE trigger_id = ? AND version_id = ?"
                                   (exn-message e) tid vid)
                       (audit! conn #:action "doc.trigger.error" #:actor-type "user" #:actor-id (principal-user-id p)
                               #:team-id (hash-ref obj 'team_id) #:resource-type "doc_triggers" #:resource-id tid
                               #:result "error"
                               #:meta (jsexpr->string (hasheq 'key (hash-ref obj 'key) 'error (exn-message e)))))])
      ;; say the useful thing first: an S3 key issued with the default files:*
      ;; scopes cannot start a workflow, and "forbidden: workflows:read" from the
      ;; lookup below would not tell an operator which scope to add
      (unless (can? conn p "workflows:run")
        (error 'triggers "the uploader cannot start a workflow — the credential needs the workflows:run (and workflows:read) scope"))
      (define def (flow-def-by-slug conn p (hash-ref t 'workflow_slug)))
      (unless def (error 'triggers "workflow '~a' is not published in this team" (hash-ref t 'workflow_slug)))
      (define run (flow-run-start! conn p def #:input (run-input t obj)))
      (query-exec conn "UPDATE doc_trigger_fires SET run_id = ? WHERE trigger_id = ? AND version_id = ?"
                  (hash-ref run 'id) tid vid)
      (audit! conn #:action "doc.trigger.fire" #:actor-type "user" #:actor-id (principal-user-id p)
              #:team-id (hash-ref obj 'team_id) #:resource-type "doc_triggers" #:resource-id tid
              #:meta (jsexpr->string (hasheq 'key (hash-ref obj 'key) 'run_id (hash-ref run 'id)))))))

;; the subscriber. Never raises: an upload that landed has landed, whatever the
;; triggers make of it.
(define (fire-triggers! conn p obj #:derived? [derived? #f])
  (with-handlers ([exn:fail? (lambda (e) (void))])
    (define rows (query-rows conn (string-append TSELECT " WHERE team_id = ? AND enabled = 1 ORDER BY created_at ASC")
                             (hash-ref obj 'team_id)))
    (when (pair? rows)
      (define derived (or (and derived? #t) (derived-object? conn obj)))
      (for ([r (in-list rows)])
        (define t (row->trigger r))
        (when (and (trigger-matches? t obj)
                   (or (not derived)
                       (and (hash-ref t 'fire_on_derived) (not (own-descendant? conn t obj derived?)))))
          (fire-one! conn p t obj))))))

;; ---- "Processed by" (DWF step 4) ---------------------------------------------------
;; Everything a document has been through, for the panel on it: what was derived
;; FROM it (with the run and step), what it was derived from, and every run that
;; touched it — started by hand with it as input, started by a trigger on it, or
;; the run that wrote it. Each row is authorized on its own: a derived document the
;; caller cannot read is left out, and so is a run they cannot see.
(define (object-processing conn p id)
  (define o (repo-get conn p id))
  (and o
       (let ()
         (define (readable-object oid)
           (with-handlers ([exn:fail:forbidden? (lambda (_) #f)]) (repo-get conn p oid)))
         (define derived
           (for*/list ([r (in-list (query-rows conn
                            (string-append "SELECT d.object_id, d.run_id, d.step_id, d.created_at "
                                           "FROM repo_derivations d JOIN repo_objects o ON o.id = d.object_id "
                                           "WHERE d.source_object_id = ? AND o.deleted_at IS NULL "
                                           "ORDER BY d.created_at DESC") id))]
                       [d (in-value (readable-object (vector-ref r 0)))]
                       #:when d)
             (hasheq 'object_id (hash-ref d 'id) 'key (hash-ref d 'key) 'content_type (hash-ref d 'content_type)
                     'version (hash-ref d 'version) 'visibility (hash-ref d 'visibility)
                     'run_id (nz (vector-ref r 1)) 'step_id (nz (vector-ref r 2))
                     'created_at (format "~a" (vector-ref r 3)))))
         (define derived-from
           (for*/list ([d (in-list (repo-derivations conn p id))]
                       [src (in-value (readable-object (hash-ref d 'source_object_id)))])
             (hash-set* d 'key (if src (hash-ref src 'key) 'null))))
         (define run-ids
           (remove-duplicates
            (append (for/list ([d (in-list derived)] #:when (string? (hash-ref d 'run_id))) (hash-ref d 'run_id))
                    (for/list ([d (in-list derived-from)] #:when (string? (hash-ref d 'run_id))) (hash-ref d 'run_id))
                    (query-list conn "SELECT run_id FROM doc_trigger_fires WHERE object_id = ? AND run_id IS NOT NULL" id)
                    ;; a run started by hand names the document in its input; the JSON
                    ;; is written without spaces, so the pair is one substring
                    (query-list conn "SELECT id FROM workflow_runs WHERE team_id = ? AND input LIKE ?"
                                (hash-ref o 'team_id)
                                (string-append "%\"object_id\":\"" id "\"%")))))
         (define runs
           (sort
            (for*/list ([rid (in-list run-ids)]
                        [run (in-value (with-handlers ([exn:fail:forbidden? (lambda (_) #f)])
                                         (flow-run-get conn p rid)))]
                        #:when run)
              (hasheq 'id (hash-ref run 'id) 'slug (hash-ref run 'slug) 'status (hash-ref run 'status)
                      'user_id (hash-ref run 'user_id) 'error (hash-ref run 'error)
                      'created_at (format "~a" (hash-ref run 'created_at))
                      'finished_at (let ([f (hash-ref run 'finished_at)]) (if (eq? f 'null) 'null (format "~a" f)))
                      ;; how it was started: which trigger, if any
                      'trigger_id (nz (or (query-maybe-value conn
                                            "SELECT trigger_id FROM doc_trigger_fires WHERE run_id = ?" (hash-ref run 'id))
                                          sql-null))))
            string>? #:key (lambda (r) (hash-ref r 'created_at))))
         (hasheq 'object_id id 'derived derived 'derived_from derived-from 'runs runs))))

(set-put-hook! fire-triggers!)
