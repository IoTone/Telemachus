#lang racket/base

;; test/audit-tests.rkt — audit-log surfacing.  raco test test/audit-tests.rkt

(require rackunit racket/list db-kit/portable
         db-kit/migrate
         "../domain/db/migrations.rkt"
         "db-fixture.rkt"
         "../domain/authz/authz.rkt")

(define (fresh) (define c (fresh-db #:migrate? #f)) (migrate! c all-migrations) c)

(test-case "audit-list returns recent team events, newest first"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice"))     ; writes a 'bootstrap' entry
  (audit! c #:action "note.create" #:actor-type "user" #:actor-id uid #:team-id tid
          #:resource-type "notes" #:resource-id "n1")
  (define es (audit-list c tid))
  (check-true (>= (length es) 2))
  (check-true (for/or ([e (in-list es)]) (equal? (hash-ref e 'action) "bootstrap")))
  (check-true (for/or ([e (in-list es)])                           ; note.create carried its resource
                (and (equal? (hash-ref e 'action) "note.create") (equal? (hash-ref e 'resource_id) "n1"))))
  ;; another team's events are not visible
  (define other (create-team! c #:name "Other" #:slug "other"))
  (check-equal? (length (audit-list c other)) 0))

;; ---- ordering inside one second (issue #47) ----------------------------------

(test-case "entries written in the same second come back newest first"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice"))
  ;; ten in a row: on SQLite these all land in the same `at` second, which is
  ;; exactly the case that used to come back in UUID order — a review decision
  ;; could read before the assessment that caused it
  (for ([i (in-range 10)])
    (audit! c #:action (format "test.event.~a" i) #:team-id tid #:actor-type "user" #:actor-id uid))
  (define actions (map (lambda (e) (hash-ref e 'action)) (audit-list c tid)))
  (check-equal? (take actions 10)
                (for/list ([i (in-range 9 -1 -1)]) (format "test.event.~a" i))
                "newest first, in the order they were written")
  ;; the ordering key is stored, not derived at read time
  ;; bootstrap writes one of its own, so this is the ten plus it
  (define us (query-list c "SELECT at_us FROM audit_log WHERE team_id = ? ORDER BY at_us" tid))
  (check-equal? (length us) 11)
  (check-true (andmap number? us))
  (check-true (apply < us) "strictly increasing, so a burst inside one tick still orders")
  (disconnect c))
