#lang racket/base

;; test/retention-tests.rkt — retention rules on a schedule (#86 r3).
;;
;; This is where #83's "purge job payloads after N days" and #59's per-job lever
;; become ONE answer. The cases that matter most are the ones about NOT deleting:
;; a rule that runs unattended and deletes too much is unrecoverable, so the
;; safety properties are asserted before the functionality.
;;
;;   1. an unconfigured instance deletes NOTHING
;;   2. a version with no known age is NEVER stale — the bug that would have
;;      deleted every pre-existing document on the first instance to switch a
;;      policy on
;;   3. a legal hold vetoes a rule
;;   4. the layers TIGHTEN and never loosen, and say which one won
;;   5. 0 days is refused, and an unknown field is refused
;;   6. then: it actually deletes, and audits each one
;;
;;   raco test test/retention-tests.rkt

(require rackunit db-kit/portable racket/list racket/file
         db-kit/migrate
         "../domain/db/migrations.rkt"
         "db-fixture.rkt"
         "../domain/authz/authz.rkt"
         "../domain/db/id.rkt"
         "../domain/repo/blobs.rkt"
         "../domain/repo/repo.rkt"
         "../domain/sched/scheduler.rkt"
         "../domain/retention/retention.rkt")

(define BLOB-ROOT (make-temporary-file "telemachus-ret-~a" 'directory))
(current-blob-root BLOB-ROOT)

(define (fresh) (define c (fresh-db #:migrate? #f)) (migrate! c all-migrations) c)

(define (owner-of c)
  (define-values (u team)
    (bootstrap! c #:username "alice" #:org-name "Acme" #:org-slug "acme"
                #:team-name "Eng" #:team-slug "eng"))
  (values (user-principal c u team) team
          (query-maybe-value c "SELECT org_id FROM teams WHERE id = ?" team)))

(define (put! c p key bytes)
  (repo-put! c p #:key key #:port (open-input-bytes bytes)
             #:content-type "text/plain" #:filename "f" #:visibility #f))

(define DAY 86400)

;; ---- 1. nothing configured, nothing deleted -------------------------------------
(test-case "an unconfigured instance deletes NOTHING, however old the data"
  (define c (fresh))
  (define-values (p team org) (owner-of c))
  (define o (put! c p "old.txt" #"ancient"))
  ;; age it a decade
  (query-exec c "UPDATE repo_versions SET created_epoch = ? WHERE object_id = ?"
              (- (current-seconds) (* 3650 DAY)) (hash-ref o 'id))
  (define plan (retention-plan c team org))
  (check-equal? (hash-ref plan 'objects) '() "no policy means no plan")
  (check-equal? (hash-ref plan 'payloads) '())
  (define-values (d pu) (retention-sweep! c))
  (check-equal? d 0 "the sweep must not even look at a team with no policy")
  (check-true (and (repo-get c p (hash-ref o 'id)) #t) "…and the document is there")
  (close-db! c))

;; ---- 2. THE DANGEROUS ONE -------------------------------------------------------
(test-case "a version with NO KNOWN AGE is never stale"
  (define c (fresh))
  (define-values (p team org) (owner-of c))
  (define o (put! c p "legacy.txt" #"written before migration 0045"))
  ;; exactly what a row written before 0045 looks like: the column is NULL
  (query-exec c "UPDATE repo_versions SET created_epoch = NULL WHERE object_id = ?" (hash-ref o 'id))
  (retention-set! c 'instance "" (hasheq 'max_age_days 1))
  (define plan (retention-plan c team org))
  (check-equal? (hash-ref plan 'objects) '()
                (string-append "a NULL epoch must read as 'age unknown, exempt'. Reading it as 0"
                               " would make every pre-0045 document infinitely old, so the first"
                               " instance to configure a policy would delete everything it had."))
  ;; and once an age IS known, the same object is in scope
  (query-exec c "UPDATE repo_versions SET created_epoch = ? WHERE object_id = ?"
              (- (current-seconds) (* 5 DAY)) (hash-ref o 'id))
  (check-equal? (length (hash-ref (retention-plan c team org) 'objects)) 1
                "with a known age, the rule applies")
  (close-db! c))

;; ---- 3. the hold vetoes a rule ---------------------------------------------------
(test-case "a legal hold vetoes a retention rule, and the plan never promises it"
  (define c (fresh))
  (define-values (p team org) (owner-of c))
  (define keep (put! c p "under-litigation.txt" #"do not delete"))
  (define go (put! c p "ordinary.txt" #"fine to delete"))
  (for ([o (in-list (list keep go))])
    (query-exec c "UPDATE repo_versions SET created_epoch = ? WHERE object_id = ?"
                (- (current-seconds) (* 90 DAY)) (hash-ref o 'id)))
  (retention-set! c 'instance "" (hasheq 'max_age_days 30))
  ;; through the CHECKED entry point, so the test exercises the permission rule
  ;; and the audit alongside the flag
  (check-true (repo-legal-hold! c p (hash-ref keep 'id) #t))
  (check-true (> (query-value c "SELECT COUNT(*) FROM audit_log WHERE action = ?"
                              "repo.hold.placed") 0)
              "placing a hold is on the record")
  (check-true (exact-integer? (legal-hold-of c (hash-ref keep 'id))))

  (define plan (retention-plan c team org))
  (check-equal? (hash-ref plan 'objects) (list (hash-ref go 'id))
                "the held object is absent from the PLAN, not merely skipped later")
  (check-equal? (hash-ref plan 'held) 1 "…and the plan says how many are held")

  (define r (retention-apply! c p team org))
  (check-equal? (hash-ref r 'deleted) 1)
  (check-true (and (repo-get c p (hash-ref keep 'id)) #t) "the held document survives")
  (check-false (repo-get c p (hash-ref go 'id)) "the other does not")
  (close-db! c))

;; ---- 4. the layers ---------------------------------------------------------------
(test-case "the layers TIGHTEN, never loosen, and name which one won"
  (define c (fresh))
  (define-values (p team org) (owner-of c))
  (retention-set! c 'instance "" (hasheq 'max_age_days 90))
  (check-equal? (hash-ref (effective-retention c team org) 'max_age_days) 90)

  ;; an org may SHORTEN its own company's retention
  (retention-set! c 'org org (hasheq 'max_age_days 30))
  (check-equal? (hash-ref (effective-retention c team org) 'max_age_days) 30)
  (check-equal? (hash-ref (retention-sources c team org) 'max_age_days) "org")

  ;; …and a team may shorten further
  (retention-set! c 'team team (hasheq 'max_age_days 7))
  (check-equal? (hash-ref (effective-retention c team org) 'max_age_days) 7)
  (check-equal? (hash-ref (retention-sources c team org) 'max_age_days) "team")

  ;; but a team may NOT extend past its company's obligation
  (retention-set! c 'team team (hasheq 'max_age_days 365))
  (check-equal? (hash-ref (effective-retention c team org) 'max_age_days) 30
                "a team cannot keep data longer than its org allows")
  ;; null is the weakest value and loses to any number
  (retention-set! c 'team team (hasheq 'max_age_days 'null))
  (check-equal? (hash-ref (effective-retention c team org) 'max_age_days) 30)
  (close-db! c))

;; ---- 5. validation ----------------------------------------------------------------
(test-case "0 days is refused, and so is a field nobody defined"
  (define c (fresh))
  (check-true (string? (retention-problem (hasheq 'max_age_days 0)))
              "0 days would delete a document on arrival")
  (check-true (regexp-match? #px"at least 1 day" (retention-problem (hasheq 'max_age_days 0))))
  (check-true (string? (retention-problem (hasheq 'max_age_days -3))))
  (check-true (string? (retention-problem (hasheq 'keep_forever_please 10)))
              "an unknown field is refused, not dropped")
  (check-false (retention-problem (hasheq 'max_age_days 30 'purge_job_payloads_after_days 7)))
  (check-false (retention-problem (hasheq)) "an empty policy is valid — it is 'no rules'")
  ;; a corrupt stored document reads as NO RULES, because a deleting control must
  ;; fail closed
  (check-equal? (hash-ref (retention-ref c 'instance) 'max_age_days) 'null)
  (close-db! c))

;; ---- 6. and it does delete, and audits --------------------------------------------
(test-case "payload purging rides #59's lever, and each deletion is audited"
  (define c (fresh))
  (define-values (p team org) (owner-of c))
  (register-job-kind! "echo" (lambda (conn pp payload) (hasheq 'ok #t)))
  (define j (enqueue-job! c #:team team #:user (principal-user-id p) #:kind "echo"
                          #:payload (hasheq 'secret "RETAIN-ME-8831")))
  (void (process-one! c))
  (query-exec c "UPDATE jobs SET created_epoch = ? WHERE id = ?"
              (- (current-seconds) (* 30 DAY)) j)
  (retention-set! c 'team team (hasheq 'purge_job_payloads_after_days 7))

  (check-equal? (hash-ref (retention-plan c team org) 'payloads) (list j))
  (define r (retention-apply! c p team org))
  (check-equal? (hash-ref r 'purged) 1)
  (check-equal? (query-value c "SELECT payload FROM jobs WHERE id = ?" j) "{}")
  (check-true (exact-integer? (query-value c "SELECT purged_at FROM jobs WHERE id = ?" j))
              "it went through purge-job-content!, which is what sets purged_at")
  ;; the row stays accountable
  (check-equal? (query-value c "SELECT status FROM jobs WHERE id = ?" j) "done")
  ;; and the act is on the record
  (check-true (> (query-value c "SELECT COUNT(*) FROM audit_log WHERE action = ? AND team_id = ?"
                              "retention.purged" team) 0))
  ;; a second pass does nothing — purged_at excludes it
  (check-equal? (hash-ref (retention-plan c team org) 'payloads) '())
  (close-db! c))
