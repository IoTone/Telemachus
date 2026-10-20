#lang racket/base

;; test/audit-read-tests.rkt — issue #84: who read a document, when, from where.
;;
;;   raco test test/audit-read-tests.rkt
;;   DATABASE_URL="postgres://…" raco test test/audit-read-tests.rkt
;;
;; What has to be proved, and in this order, because the later cases are
;; meaningless if the first one is not true:
;;
;;   1. a read is recorded AT ALL, with the fields r2 names
;;   2. a REFUSED read is recorded, with the same shape (r4) — the event an
;;      auditor is actually looking for
;;   3. the ONE SEAM claim: a read through a DIFFERENT door is recorded too,
;;      without that door having been taught to audit. This is the claim the
;;      whole design rests on, so it is tested rather than asserted in a comment.
;;   4. presign issuance and redemption are two events (the acceptance criterion)
;;   5. the key is NOT in the record (r2), and the ids that replace it resolve
;;   6. who may READ the record is narrower than who may read the document

(require rackunit db-kit/portable
         racket/file racket/port racket/list racket/string
         db-kit/migrate
         "../domain/db/migrations.rkt"
         "db-fixture.rkt"
         "../domain/authz/authz.rkt"
         "../domain/repo/blobs.rkt"
         "../domain/repo/repo.rkt"
         "../domain/audit/reads.rkt")

(define BLOB-ROOT (make-temporary-file "telemachus-auditread-~a" 'directory))
(current-blob-root BLOB-ROOT)

(define (fresh)
  (define conn (fresh-db #:migrate? #f))
  (migrate! conn all-migrations)
  conn)

(define (owner-of conn)
  (define-values (u team)
    (bootstrap! conn #:username "root" #:org-name "Acme" #:org-slug "acme"
                #:team-name "Engineering" #:team-slug "engineering"))
  (values (user-principal conn u team) team u))

(define (member-of conn team username #:role [role "member"])
  (define u (create-user! conn #:username username #:password "pw"))
  (add-member! conn #:user u #:team team #:role role)
  (values (user-principal conn u team) u))

(define (put! conn p key bytes #:vis [vis "team"])
  (repo-put! conn p #:key key #:port (open-input-bytes bytes)
             #:content-type "text/plain" #:filename "f" #:visibility vis))

;; the raw rows, so a case can assert on the COLUMNS and not only on what a
;; projection chose to report
;; No conditional clause and no optional parameter: building SQL by
;; concatenation while passing a fixed argument list is how a clause and its
;; parameter come apart (it did here, on the first run), and this read wants
;; every entry anyway.
(define (entries conn)
  (for/list ([r (in-list (query-rows conn
      (string-append "SELECT action, actor_type, actor_id, team_id, org_id, result, "
                     "client_ip, user_agent, request_id, meta, resource_id "
                     "FROM audit_log WHERE action LIKE 'repo.read%' OR action LIKE 'repo.presign%' "
                     "ORDER BY at_us ASC")))])
    (define (nz x) (if (sql-null? x) #f x))
    (hasheq 'action (vector-ref r 0) 'actor_type (nz (vector-ref r 1))
            'actor_id (nz (vector-ref r 2)) 'team_id (nz (vector-ref r 3))
            'org_id (nz (vector-ref r 4)) 'result (nz (vector-ref r 5))
            'ip (nz (vector-ref r 6)) 'ua (nz (vector-ref r 7))
            'request_id (nz (vector-ref r 8)) 'meta (or (nz (vector-ref r 9)) "")
            'resource_id (nz (vector-ref r 10)))))

(define (read-back conn p id)
  (define-values (o in) (repo-open conn p id))
  (and in (let ([b (port->bytes in)]) (close-input-port in) b)))

(define (drain-read! conn p id)
  (define-values (o in) (repo-open conn p id))
  (when in (void (port->bytes in)) (close-input-port in))
  o)

;; ---- 1. a read is recorded, with r2's fields ------------------------------------
(test-case "a read is recorded with actor, team, org, object, version and the client"
  (define conn (fresh))
  (define-values (owner team uid) (owner-of conn))
  (define o (put! conn owner "report.txt" #"the body"))
  (check-equal? (entries conn) '() "nothing is recorded by WRITING a document here")

  ;; through the API door, with a client in front of it
  (with-read-context (read-context "api" "203.0.113.7" "curl/8.4" "req-1" #f #f #f)
    (lambda () (drain-read! conn owner (hash-ref o 'id))))

  (define es (entries conn))
  (check-equal? (length es) 1 "exactly one entry per read — r6's one indexed insert")
  (define e (car es))
  (check-equal? (hash-ref e 'action) "repo.read")
  (check-equal? (hash-ref e 'result) "ok")
  (check-equal? (hash-ref e 'actor_type) "user")
  (check-equal? (hash-ref e 'actor_id) uid)
  (check-equal? (hash-ref e 'team_id) team)
  (check-true (string? (hash-ref e 'org_id)) "the org is on the entry, not left to a join")
  (check-equal? (hash-ref e 'resource_id) (hash-ref o 'id))
  (check-equal? (hash-ref e 'ip) "203.0.113.7")
  (check-equal? (hash-ref e 'ua) "curl/8.4")
  (check-equal? (hash-ref e 'request_id) "req-1")
  (check-true (string-contains? (hash-ref e 'meta) "\"via\":\"api\""))
  (check-true (string-contains? (hash-ref e 'meta) (hash-ref o 'version_id))
              "the VERSION read, which for a history read is not the current one")
  (close-db! conn))

;; ---- 2. r4: a refused read is recorded, with the same shape ---------------------
(test-case "a REFUSED read is recorded, and names the permission"
  (define conn (fresh))
  (define-values (owner team uid) (owner-of conn))
  (define-values (alice _a) (member-of conn team "alice"))
  (define-values (bob bob-id) (member-of conn team "bob"))
  (define priv (put! conn alice "private.txt" #"sshh" #:vis "private"))

  ;; private is private from a colleague — and from an admin (DSH-2)
  (check-exn exn:fail:forbidden?
             (lambda ()
               (with-read-context (read-context "api" "198.51.100.9" "Mozilla/5.0" "req-2" #f #f #f)
                 (lambda () (repo-open conn bob (hash-ref priv 'id))))))

  (define es (entries conn))
  (check-equal? (length es) 1)
  (define e (car es))
  (check-equal? (hash-ref e 'result) "denied" "the refusal is the event an auditor wants")
  (check-equal? (hash-ref e 'actor_id) bob-id "…and it names WHO was refused")
  (check-equal? (hash-ref e 'ip) "198.51.100.9")
  (check-true (string-contains? (hash-ref e 'meta) "files:read")
              "…and what they lacked")
  ;; the refusal still RAISES unchanged: auditing must not swallow the exception
  (check-exn exn:fail:forbidden?
             (lambda () (repo-open conn bob (hash-ref priv 'id))))
  (close-db! conn))

;; ---- 3. THE ONE-SEAM CLAIM -------------------------------------------------------
;; The design rests on "every door arrives at repo-open, so the audit is written
;; once". A comment saying so is not evidence. These two reads go through doors
;; that were never taught to audit anything — the context is all they set — and
;; both must appear, with the door named and the actor overridden where the
;; reader is a machine rather than a person.
(test-case "a read through any door is recorded, and the door is named"
  (define conn (fresh))
  (define-values (owner team uid) (owner-of conn))
  (define o (put! conn owner "shared.txt" #"bytes"))

  (with-read-context (read-context "worker" #f #f "job-9" #f "executor" "ex-1")
    (lambda () (drain-read! conn owner (hash-ref o 'id))))
  (with-read-context (read-context "run" #f #f "run-7" #f "run" "run-7")
    (lambda () (drain-read! conn owner (hash-ref o 'id))))
  ;; a path that sets NO context at all is still recorded — as "internal", which
  ;; is honest. Guessing "api" would put a client in the record that never existed.
  (drain-read! conn owner (hash-ref o 'id))

  (define es (entries conn))
  (check-equal? (length es) 3)
  (check-equal? (for/list ([e (in-list es)])
                  (cond [(string-contains? (hash-ref e 'meta) "\"via\":\"worker\"") 'worker]
                        [(string-contains? (hash-ref e 'meta) "\"via\":\"run\"") 'run]
                        [(string-contains? (hash-ref e 'meta) "\"via\":\"internal\"") 'internal]
                        [else 'other]))
                '(worker run internal))
  ;; the actor is the MACHINE where one asked, while the principal still decided
  (check-equal? (hash-ref (car es) 'actor_type) "executor")
  (check-equal? (hash-ref (car es) 'actor_id) "ex-1")
  (check-equal? (hash-ref (cadr es) 'actor_type) "run")
  ;; and with no override it is the person again
  (check-equal? (hash-ref (caddr es) 'actor_type) "user")
  (check-equal? (hash-ref (caddr es) 'actor_id) uid)
  (close-db! conn))

;; ---- 4. the acceptance criterion: issuance and redemption are two events --------
(test-case "presign issuance and redemption are distinct events with distinct clients"
  (define conn (fresh))
  (define-values (owner team uid) (owner-of conn))
  (define o (put! conn owner "invoice.pdf" #"%PDF-1.4"))

  ;; the link is minted by the owner, at the console
  (with-read-context (read-context "api" "203.0.113.7" "console" "req-mint" #f #f #f)
    (lambda () (audit-presign-issued! conn owner o #:expires-in 900)))
  ;; …and followed by whoever was given it, from somewhere else entirely, with no
  ;; bearer token: the S3 listener's own door, which `presigned-auth` detects
  (with-read-context (read-context "presign" "192.0.2.44" "Safari/17" "req-follow" #f #f #f)
    (lambda () (drain-read! conn owner (hash-ref o 'id))))

  (define es (entries conn))
  (check-equal? (map (lambda (e) (hash-ref e 'action)) es)
                '("repo.presign.issued" "repo.presign.redeemed")
                "two actions, so a reader need not know that via=presign is the second")
  (check-equal? (hash-ref (car es) 'ip) "203.0.113.7")
  (check-equal? (hash-ref (cadr es) 'ip) "192.0.2.44" "the REDEEMING client's address")
  (check-true (string-contains? (hash-ref (car es) 'meta) "\"expires_in\":900")
              "an outstanding link is worth auditing because of its expiry")
  ;; distinct timestamps, which the criterion names: at_us never repeats in a
  ;; process (issue #47), so two events in the same second still order
  (define us (query-list conn (string-append "SELECT at_us FROM audit_log WHERE action LIKE 'repo.presign%' "
                                             "ORDER BY at_us ASC")))
  (check-equal? (length (remove-duplicates us)) 2 "distinct timestamps")
  (close-db! conn))

;; ---- 5. r2: the key is not in the record ----------------------------------------
(test-case "the record carries ids, never the object key"
  (define conn (fresh))
  (define-values (owner team uid) (owner-of conn))
  ;; a key of exactly the kind r2 is about: operator-authored, and carrying a name
  (define o (put! conn owner "inbox/tanaka-hiroshi/claim-4417.txt" #"body"))
  (drain-read! conn owner (hash-ref o 'id))
  (define e (car (entries conn)))
  (check-false (string-contains? (hash-ref e 'meta) "tanaka")
               "an object key routinely carries personal data; the entry must not")
  ;; …and the ids that replace it RESOLVE, or the rule would have cost the record
  ;; its usefulness rather than only its risk
  (check-equal? (query-value conn "SELECT key FROM repo_objects WHERE id = ?" (hash-ref e 'resource_id))
                "inbox/tanaka-hiroshi/claim-4417.txt"
                "the key is joinable from the id, under that table's own access control")
  (close-db! conn))

;; ---- 6. who may read the record -------------------------------------------------
(test-case "reading WHO looked needs files:manage, not files:read"
  (define conn (fresh))
  (define-values (owner team uid) (owner-of conn))
  (define-values (alice _a) (member-of conn team "alice"))
  (define o (put! conn owner "team.txt" #"bytes"))
  (drain-read! conn owner (hash-ref o 'id))

  ;; alice may READ the document — it is team-visible
  (check-equal? (read-back conn alice (hash-ref o 'id)) #"bytes")
  ;; …and may NOT enumerate who else has opened it
  (check-exn exn:fail:forbidden?
             (lambda () (object-reads conn alice o #:resource (obj->resource o))))
  ;; the owner may
  (define rs (object-reads conn owner o #:resource (obj->resource o)))
  (check-true (>= (length rs) 2) "alice's read is in the record too")
  (check-equal? (hash-ref (car rs) 'action) "repo.read")
  (close-db! conn))

