#lang racket/base

;; test/note-tidying-tests.rkt — the Notes tab's two tidying lists: notes with no
;; link either way, and links that point at nothing.
;;
;;   raco test test/note-tidying-tests.rkt
;;   DATABASE_URL="postgres://…" raco test test/note-tidying-tests.rkt
;;
;; The lists are read off the graph's own scan and resolved through the reader's
;; own index, so what matters here is what each reader is told: a colleague's
;; private note must look exactly like a note that does not exist.

(require rackunit db-kit/portable racket/list
         db-kit/migrate
         "../domain/db/migrations.rkt"
         "db-fixture.rkt"
         "../domain/authz/authz.rkt"
         "../domain/notes/notes.rkt")

(define (fresh) (define c (fresh-db #:migrate? #f)) (migrate! c all-migrations) c)
(define (setup)
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "root"))
  (values c (user-principal c uid tid) tid))
(define (member-of c team username)
  (define u (create-user! c #:username username #:password "pw-fixture-1"))
  (add-member! c #:user u #:team team #:role "member")
  (user-principal c u team))
(define (org c p title body #:visibility [vis "team"])
  (hash-ref (notes-create c p #:title title #:body body
                          #:format "org" #:visibility vis) 'id))
(define (md c p title body #:visibility [vis "team"])
  (hash-ref (notes-create c p #:title title #:body body #:visibility vis) 'id))

(define (unlinked-titles T)
  (sort (map (lambda (n) (hash-ref n 'title)) (hash-ref T 'unlinked)) string<?))
(define (broken-of T)
  (sort (map (lambda (b) (list (hash-ref b 'title) (hash-ref b 'target) (hash-ref b 'reason)))
             (hash-ref T 'broken))
        (lambda (a b) (string<? (apply string-append a) (apply string-append b)))))

(test-case "a note is unlinked when it links to no note and no note links to it"
  (define-values (c p tid) (setup))
  (org c p "Alpha" "see [[Beta]]")
  (org c p "Beta" "nothing here")
  (md c p "Gamma" "a markdown note that links [[Alpha]]")
  (org c p "Delta" "alone")
  (define T (note-tidying c p))
  (check-equal? (unlinked-titles T) '("Delta"))
  (check-equal? (hash-ref T 'unlinked_total) 1)
  (check-equal? (hash-ref T 'notes) 4)
  (check-false (hash-ref T 'truncated))
  (check-equal? (hash-ref T 'broken) '()))

(test-case "a link to itself does not connect a note to anything"
  (define-values (c p tid) (setup))
  (org c p "Solo" "I mention [[Solo]]")
  (define T (note-tidying c p))
  (check-equal? (unlinked-titles T) '("Solo"))
  (check-equal? (hash-ref T 'broken) '()))

(test-case "a broken link is listed with its note, its target and why"
  (define-values (c p tid) (setup))
  (org c p "Plan" "see [[No such note]] and [[Twin]]")
  (org c p "Twin" "first")
  (org c p "Twin" "second")
  (define T (note-tidying c p))
  (check-equal? (broken-of T)
                '(("Plan" "No such note" "missing") ("Plan" "Twin" "ambiguous")))
  (check-equal? (hash-ref T 'broken_total) 2)
  ;; neither link reaches a note, so all three are unlinked
  (check-equal? (unlinked-titles T) '("Plan" "Twin" "Twin")))

(test-case "a source link does not connect notes, and a dead one is broken"
  (define-values (c p tid) (setup))
  (md c p "Cites" "from [[doc:reports/gone.md]]")
  (define T (note-tidying c p))
  (check-equal? (unlinked-titles T) '("Cites"))
  (check-equal? (broken-of T) '(("Cites" "doc:reports/gone.md" "missing"))))

(test-case "a colleague's private note reads exactly like one that does not exist"
  (define-values (c owner tid) (setup))
  (define bob (member-of c tid "bob"))
  (org c owner "Secret plan" "points at [[Public]]" #:visibility "private")
  (org c owner "Public" "open to the team")
  (org c bob "Bob A" "see [[Secret plan]]")
  (org c bob "Bob B" "see [[Never written]]")
  (define T (note-tidying c bob))
  ;; the two links get the SAME answer, which is the property: bob cannot tell
  ;; a private note from a missing one
  (define reasons
    (for/list ([b (in-list (hash-ref T 'broken))]) (hash-ref b 'reason)))
  (check-equal? reasons '("missing" "missing"))
  (check-equal? (sort (map (lambda (b) (hash-ref b 'target)) (hash-ref T 'broken)) string<?)
                '("Never written" "Secret plan"))
  ;; the private note is not listed, and its link to Public counts for nothing
  (check-equal? (unlinked-titles T) '("Bob A" "Bob B" "Public"))
  (check-equal? (hash-ref T 'notes) 3)
  ;; the owner sees the edge, so Public and the private note are both linked
  (define O (note-tidying c owner))
  (check-equal? (unlinked-titles O) '("Bob B"))
  (check-equal? (broken-of O) '(("Bob B" "Never written" "missing"))))

(test-case "each list is cut at the maximum and the total says how many there are"
  (define-values (c p tid) (setup))
  (for ([i (in-range (+ NOTE-TIDY-MAX 5))])
    (md c p (format "note ~a" i) "plain"))
  (define T (note-tidying c p))
  (check-equal? (length (hash-ref T 'unlinked)) NOTE-TIDY-MAX)
  (check-equal? (hash-ref T 'unlinked_total) (+ NOTE-TIDY-MAX 5)))

(test-case "when the scan fills, the unlinked list is withdrawn rather than guessed"
  (define-values (c p tid) (setup))
  (define a (org c p "Hub" "see [[Missing one]]"))
  (org c p "Quiet" "alone")
  ;; fill the scan with rows no body produced; the read is bounded at 2,000
  (call-with-transaction c
    (lambda ()
      (for ([i (in-range 2000)])
        (query-exec c
          (string-append "INSERT INTO note_links (id, src_note_id, team_id, raw_target, "
                         "target_fold, label, ord) VALUES (?, ?, ?, ?, ?, ?, ?)")
          (format "filler-~a" i) a tid (format "ghost ~a" i) (format "ghost ~a" i)
          "" (+ i 10)))))
  (define T (note-tidying c p))
  (check-true (hash-ref T 'truncated))
  (check-equal? (hash-ref T 'unlinked) 'null)
  (check-equal? (hash-ref T 'unlinked_total) 'null)
  (check-equal? (length (hash-ref T 'broken)) NOTE-TIDY-MAX)
  (check-equal? (hash-ref T 'broken_total) 2000))
