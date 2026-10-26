#lang racket/base

;; test/classify-backfill-tests.rkt — issue #87 requirement 5: batch mode for
;; backfilling existing prefixes (decisions CLS-24…28).
;;   raco test test/classify-backfill-tests.rkt
;;
;; Three layers:
;;   1. the lister, against a real database: what it finds, what it skips, what it
;;      reports, and the two caps
;;   2. the scan itself — the page that contributes nothing, which is the one thing
;;      the paging loop exists for, and the only case a short-circuiting lister
;;      gets wrong while looking correct
;;   3. the requirement, through the real engine: a mixed prefix backfilled with
;;      rules alone, and a re-run that classifies nothing

(require rackunit db-kit/portable
         racket/port racket/string racket/file racket/list
         json
         db-kit/migrate
         "../domain/db/migrations.rkt"
         "db-fixture.rkt"
         "../domain/authz/authz.rkt"
         "../domain/repo/blobs.rkt"
         "../domain/repo/repo.rkt"
         "../domain/repo/classify.rkt"
         "../domain/repo/doc-tools.rkt"        ; registers the tools, exports the caps
         "../domain/agent/registry.rkt"
         "../domain/agent/tools.rkt"
         "../domain/sched/scheduler.rkt"
         "../domain/flow/run.rkt"
         (prefix-in pipeline: "../plugins/doc-pipeline/main.rkt"))

(define BLOB-ROOT (make-temporary-file "telemachus-backfill-blobs-~a" 'directory))
(current-blob-root BLOB-ROOT)

(define (fresh)
  (define conn (fresh-db #:migrate? #f))
  (migrate! conn all-migrations)
  conn)

(define LABELS
  (list (hasheq 'name "invoice" 'description "a bill for goods or services")
        (hasheq 'name "letter" 'description "correspondence addressed to a person")
        (hasheq 'name "photo" 'description "a photograph of a site or an asset")))

(define RULES
  (list (hasheq 'label "photo" 'content_type "image/")
        (hasheq 'label "invoice" 'any '("Invoice" "Total due"))
        (hasheq 'label "letter" 'any '("Dear"))))

(define INVOICE-TEXT "INVOICE 4471\nAcme Corp\nTotal due 1250.50")
(define LETTER-TEXT "Dear Ms Smith,\n\nYour tenancy begins on 2026-11-01.\n\nAcme")

(define (list! conn p [prefix ""])
  ((tool-handler (tool-by-name "doc_list_unclassified")) conn p (hasheq 'prefix prefix)))

(define (classify! conn p obj #:backends [backends '("rules")])
  ((tool-handler (tool-by-name "doc_classify")) conn p
   (hasheq 'object (hash-ref obj 'id) 'labels LABELS 'rules RULES 'backends backends)))

;; a three-digit key so the SQL `ORDER BY key` and the loop agree about order
(define (~r3 i) (string-append (if (< i 100) (if (< i 10) "00" "0") "") (number->string i)))

(define (up! conn p key text ct [vis "team"])
  (repo-put! conn p #:key key #:port (open-input-bytes (string->bytes/utf-8 text))
             #:content-type ct #:filename key #:visibility vis))

;; ---- 1. the lister ---------------------------------------------------------------
(test-case "CLS-25: unclassified means the absence of doc_type, so a re-run is free"
  (define conn (fresh))
  (define-values (uid tid) (bootstrap! conn #:username "alice"))
  (define alice (user-principal conn uid tid))
  (define inv (up! conn alice "inbox/a.txt" INVOICE-TEXT "text/plain"))
  (define let1 (up! conn alice "inbox/b.txt" LETTER-TEXT "text/plain"))
  (define out (up! conn alice "other/c.txt" LETTER-TEXT "text/plain"))

  (define r (list! conn alice "inbox/"))
  (check-equal? (sort (hash-ref r 'ids) string<?)
                (sort (list (hash-ref inv 'id) (hash-ref let1 'id)) string<?))
  (check-equal? (hash-ref r 'count) 2)
  (check-equal? (hash-ref r 'objects) 2 "the prefix bounds the window")
  (check-false (hash-ref r 'truncated))
  ;; an empty prefix is the whole team, deliberately — unlike `DELETE
  ;; /api/repo?prefix=`, which refuses one because it destroys. A backfill is
  ;; additive and re-runnable, and "classify everything" is a legitimate ask.
  (check-equal? (hash-ref (list! conn alice "") 'count) 3)

  ;; classify one, and it drops out of the listing — the marker is what the
  ;; backfill wrote, so progress needs no table of its own
  (check-equal? (hash-ref (classify! conn alice inv) 'label) "invoice")
  (check-equal? (hash-ref (list! conn alice "inbox/") 'ids) (list (hash-ref let1 'id)))

  ;; and WITHDRAWING the type makes it eligible again. That is the documented way
  ;; to reclassify after changing the label set: there is no `force`, because the
  ;; absence of `doc_type` is the only progress marker there is and a forced run
  ;; would re-do its own first batch for ever.
  (repo-set-attributes! conn alice (hash-ref inv 'id) (hasheq 'doc_type ""))
  (check-equal? (hash-ref (list! conn alice "inbox/") 'count) 2))

(test-case "CLS-26: the records a run derived are never listed"
  ;; Without this the next backfill classifies the classifications, writes records
  ;; about THOSE, and never converges.
  (define conn (fresh))
  (define-values (uid tid) (bootstrap! conn #:username "alice"))
  (define alice (user-principal conn uid tid))
  (define inv (up! conn alice "inbox/a.txt" INVOICE-TEXT "text/plain"))
  (classify! conn alice inv)
  ;; the record really is there, and really has no type of its own
  (define rec (repo-get conn alice "inbox/a.txt.classification.json" #:by-key tid))
  (check-true (and rec #t) "the classification record was written")
  (check-false (hash-has-key? (hash-ref rec 'attributes) 'doc_type))
  (define r (list! conn alice "inbox/"))
  (check-equal? (hash-ref r 'ids) '() "nothing is left to classify")
  (check-equal? (hash-ref r 'objects) 2 "…though the window holds the record too"))

(test-case "the listing is the caller's own: a colleague's private document is not in it"
  (define conn (fresh))
  (define-values (uid tid) (bootstrap! conn #:username "alice"))
  (define alice (user-principal conn uid tid))
  (define bob-id (create-user! conn #:username "bob" #:password "pw"))
  (add-member! conn #:user bob-id #:team tid #:role "member")
  (define bob (user-principal conn bob-id tid))
  (up! conn alice "inbox/a.txt" INVOICE-TEXT "text/plain" "private")
  (define shared (up! conn alice "inbox/b.txt" LETTER-TEXT "text/plain"))
  (check-equal? (hash-ref (list! conn bob "inbox/") 'ids) (list (hash-ref shared 'id)))
  ;; `objects` is the window and does not filter — that is what lets the scan tell
  ;; a short page from the last page, and it is stated rather than implied
  (check-equal? (hash-ref (list! conn bob "inbox/") 'objects) 2))

(test-case "a batch is capped, and the surplus is REPORTED rather than lost"
  (define conn (fresh))
  (define-values (uid tid) (bootstrap! conn #:username "alice"))
  (define alice (user-principal conn uid tid))
  (for ([i (in-range (+ CLASSIFY-BATCH 5))])
    (up! conn alice (format "inbox/~a.txt" (~r3 i)) INVOICE-TEXT "text/plain"))
  (define r (list! conn alice "inbox/"))
  (check-equal? (hash-ref r 'count) CLASSIFY-BATCH)
  (check-equal? (hash-ref r 'objects) (+ CLASSIFY-BATCH 5))
  ;; The scan reached the end of the window AND dropped five ids. A `truncated`
  ;; that only reported the first would tell this operator they were finished.
  (check-true (hash-ref r 'truncated)))

;; ---- 2. the page that contributes nothing ----------------------------------------
(test-case "CLS-27: the scan keeps paging past a page that yielded no ids"
  ;; `repo-list` pages the SQL window and then filters per row, and this batch also
  ;; skips anything already classified — so the first page can contribute zero ids
  ;; while documents wait behind it. A lister that stopped at the first empty page
  ;; would report "nothing to do", and an operator would believe it.
  (define conn (fresh))
  (define-values (uid tid) (bootstrap! conn #:username "alice"))
  (define alice (user-principal conn uid tid))
  ;; LAY-4 refuses an undefined attribute key, so the three fields are declared
  ;; the way `record-type!` declares them — without this the writes below are
  ;; refused and the case passes for the wrong reason
  (check-false (string? (repo-fields-declare! conn tid CLASSIFY-FIELDS)))
  ;; a full page of ALREADY-CLASSIFIED documents, first in key order…
  (for ([i (in-range 100)])
    (define o (up! conn alice (format "inbox/a~a.txt" (~r3 i)) INVOICE-TEXT "text/plain"))
    (check-true (hash? (repo-set-attributes! conn alice (hash-ref o 'id)
                                             (hasheq 'doc_type "invoice")))))
  ;; …and the one that still needs doing, behind them
  (define late (up! conn alice "inbox/zz.txt" LETTER-TEXT "text/plain"))
  (define r (list! conn alice "inbox/"))
  (check-equal? (hash-ref r 'ids) (list (hash-ref late 'id))
                "the document behind a full page of finished ones was found")
  (check-equal? (hash-ref r 'objects) 101)
  (check-equal? (hash-ref r 'scanned) 101)
  (check-false (hash-ref r 'truncated)))

(test-case "CLS-27: and past a page `can?` emptied — which is what repo-count is for"
  ;; The sibling case above is about the batch's own filter; this one is about the
  ;; authorization filter `repo-list` applies AFTER the SQL LIMIT. A whole page of
  ;; a colleague's private documents comes back as nothing, and the naive test for
  ;; the end of the window — "this page was short" — cannot tell that from the last
  ;; page. `repo-count` is the same window without the filter, which is the only
  ;; thing that can.
  (define conn (fresh))
  (define-values (uid tid) (bootstrap! conn #:username "alice"))
  (define alice (user-principal conn uid tid))
  (define bob-id (create-user! conn #:username "bob" #:password "pw"))
  (add-member! conn #:user bob-id #:team tid #:role "member")
  (define bob (user-principal conn bob-id tid))
  (for ([i (in-range 100)])
    (up! conn alice (format "inbox/a~a.txt" (~r3 i)) INVOICE-TEXT "text/plain" "private"))
  (define late (up! conn alice "inbox/zz.txt" LETTER-TEXT "text/plain"))
  (define r (list! conn bob "inbox/"))
  (check-equal? (hash-ref r 'ids) (list (hash-ref late 'id))
                "the one document bob may see was found behind a page he may not")
  (check-equal? (hash-ref r 'scanned) 1 "…and only one row ever reached the batch")
  (check-equal? (hash-ref r 'objects) 101))

;; ---- 3. the requirement, through the real engine ----------------------------------
(test-case "requirement 5: a mixed prefix is backfilled, and the re-run does nothing"
  (define conn (fresh))
  (define-values (uid tid) (bootstrap! conn #:username "alice"))
  (define alice (user-principal conn uid tid))
  (register-plugin-workflow! "doc-pipeline" (last pipeline:workflows))
  (define def (flow-def-by-slug conn alice "classify-backfill"))
  (check-true (and def #t) "the plugin workflow materialized")

  (define inv    (up! conn alice "mixed/a.txt" INVOICE-TEXT "text/plain"))
  (define letter (up! conn alice "mixed/b.txt" LETTER-TEXT "text/plain"))
  (define photo  (up! conn alice "mixed/c.jpg" "not really a jpeg" "image/jpeg"))
  (define other  (up! conn alice "elsewhere/d.txt" INVOICE-TEXT "text/plain"))

  (define (backfill! prefix)
    (define run (flow-run-start! conn alice def
                                 #:input (hasheq 'prefix prefix 'labels LABELS
                                                 'rules RULES 'backends '("rules"))))
    (let loop ([n 0]) (when (and (< n 80) (process-one! conn)) (loop (add1 n))))
    (define r (flow-run-get conn alice (hash-ref run 'id)))
    (check-equal? (hash-ref r 'status) "done"
                  (format "the backfill finished (error: ~a)" (hash-ref r 'error)))
    r)

  (define (type-of o)
    (hash-ref (hash-ref (repo-get conn alice (hash-ref o 'id)) 'attributes) 'doc_type #f))

  ;; the model is never reached: every classification here is a rule, which is what
  ;; makes a backfill over a backlog affordable
  (define r1 (parameterize ([current-doc-chat
                             (lambda (prompt #:system [sys #f])
                               (error 'test "the model was asked to classify in a rules-only backfill"))])
               (backfill! "mixed/")))
  (check-equal? (type-of inv) "invoice")
  (check-equal? (type-of letter) "letter")
  (check-equal? (type-of photo) "photo" "a document this platform cannot read is still classified")
  (check-false (type-of other) "the prefix bounded the backfill")

  ;; one child step per document, and the records landed beside their sources
  (define children (filter (lambda (s) (string-prefix? (hash-ref s 'step_id) "classify#"))
                           (hash-ref r1 'steps)))
  (check-equal? (length children) 3)
  (for ([k '("mixed/a.txt.classification.json" "mixed/b.txt.classification.json"
             "mixed/c.jpg.classification.json")])
    (check-true (and (repo-get conn alice k #:by-key tid) #t) (format "~a was written" k)))

  ;; and the re-run is free: nothing to find, so the fan-out has no children
  (define r2 (backfill! "mixed/"))
  (define find2 (findf (lambda (s) (equal? (hash-ref s 'step_id) "find")) (hash-ref r2 'steps)))
  (check-equal? (hash-ref (hash-ref (hash-ref find2 'output) 'result) 'count) 0)
  (check-equal? (length (filter (lambda (s) (string-prefix? (hash-ref s 'step_id) "classify#"))
                                (hash-ref r2 'steps)))
                0 "a finished backfill run again classifies nothing"))
