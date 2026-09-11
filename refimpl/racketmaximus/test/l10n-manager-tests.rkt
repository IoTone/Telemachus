#lang racket/base

;; test/l10n-manager-tests.rkt — the Localization Manager's model (the flagship).
;;
;; What this has to prove:
;;   1. importing the catalogs is idempotent, and never walks a status backwards
;;   2. `missing` and `stale` are DERIVED — an English edit makes a translation
;;      stale with nothing rewriting a status
;;   3. a translator cannot approve their own string
;;   4. export is approved-only, so a draft can never reach the product
;;   5. coverage counts what it says it counts

(require rackunit db-kit/portable
         racket/list racket/string
         db-kit/migrate
         "../domain/db/migrations.rkt"
         "db-fixture.rkt"
         "../domain/i18n/catalog.rkt"
         "../domain/i18n/manager.rkt")

(define (fresh)
  (define conn (fresh-db #:migrate? #f))
  (migrate! conn all-migrations)
  conn)

(define (base . pairs)
  (make-catalog "en" #f
    (for/hash ([p (in-list pairs)])
      (values (car p) (cons (cdr p) (source-hash (cdr p)))))))

(define (target loc . triples)   ; (key text hash)
  (make-catalog loc "en"
    (for/hash ([t (in-list triples)])
      (values (first t) (cons (second t) (third t))))))

(define ALICE "user-alice")
(define BOB   "user-bob")

;; ---- import ------------------------------------------------------------------
(test-case "import adds the base and is idempotent"
  (define conn (fresh))
  (define b (base '("http.forbidden" . "Forbidden") '("http.ok" . "OK")))
  (define r1 (l10n-import! conn b '()))
  (check-equal? (hash-ref r1 'added) 2)
  (define r2 (l10n-import! conn b '()))
  (check-equal? (hash-ref r2 'added) 0 "a second import adds nothing")
  (check-equal? (hash-ref r2 'updated) 0 "and updates nothing")
  (close-db! conn))

(test-case "a shipped target catalog imports as approved"
  (define conn (fresh))
  (define b (base '("http.forbidden" . "Forbidden")))
  (define h (source-hash "Forbidden"))
  (l10n-import! conn b (list (target "ja" (list "http.forbidden" "権限がありません" h))))
  (define items (hash-ref (l10n-list conn "ja") 'items))
  (check-equal? (length items) 1)
  (check-equal? (hash-ref (car items) 'status) "approved"
                "already shipping, so already approved")
  (close-db! conn))

(test-case "import never overwrites a translation already in the database"
  (define conn (fresh))
  (define b (base '("http.forbidden" . "Forbidden")))
  (l10n-import! conn b '())
  (define mid (hash-ref (car (hash-ref (l10n-list conn "ja") 'items)) 'message_id))
  (l10n-submit! conn mid "ja" "わたしの訳" ALICE)
  ;; re-import with a DIFFERENT shipped string: the database wins
  (l10n-import! conn b (list (target "ja" (list "http.forbidden" "別の訳" (source-hash "Forbidden")))))
  (check-equal? (hash-ref (car (hash-ref (l10n-list conn "ja") 'items)) 'text) "わたしの訳")
  (close-db! conn))

;; ---- derived status ----------------------------------------------------------
(test-case "missing is the absence of a row, not a stored status"
  (define conn (fresh))
  (l10n-import! conn (base '("a.one" . "One") '("a.two" . "Two")) '())
  (define items (hash-ref (l10n-list conn "nl") 'items))
  (check-equal? (length items) 2)
  (check-true (andmap (lambda (h) (string=? (hash-ref h 'status) "missing")) items))
  (close-db! conn))

(test-case "editing the English makes an approved translation stale, with nothing rewriting it"
  (define conn (fresh))
  (l10n-import! conn (base '("a.one" . "One")) '())
  (define mid (hash-ref (car (hash-ref (l10n-list conn "nl") 'items)) 'message_id))
  (define t (l10n-submit! conn mid "nl" "Een" ALICE))
  (l10n-review! conn (hash-ref t 'id) 'approve BOB)
  (check-equal? (hash-ref (car (hash-ref (l10n-list conn "nl") 'items)) 'status) "approved")

  ;; the English moves — no UPDATE touches l10n_translations
  (l10n-import! conn (base '("a.one" . "One (edited)")) '())
  (check-equal? (hash-ref (car (hash-ref (l10n-list conn "nl") 'items)) 'status) "stale"
                "staleness falls out of the hash comparison")
  (close-db! conn))

(test-case "a key that vanishes is deprecated, never deleted"
  (define conn (fresh))
  (l10n-import! conn (base '("a.one" . "One") '("a.two" . "Two")) '())
  (define r (l10n-import! conn (base '("a.one" . "One")) '()))
  (check-equal? (hash-ref r 'deprecated) 1)
  (check-equal? (length (hash-ref (l10n-list conn "nl") 'items)) 1 "deprecated keys drop out of the list")
  (close-db! conn))

;; ---- review ------------------------------------------------------------------
(test-case "a translator cannot approve their own string"
  (define conn (fresh))
  (l10n-import! conn (base '("a.one" . "One")) '())
  (define mid (hash-ref (car (hash-ref (l10n-list conn "nl") 'items)) 'message_id))
  (define t (l10n-submit! conn mid "nl" "Een" ALICE))
  (check-exn exn:fail:user? (lambda () (l10n-review! conn (hash-ref t 'id) 'approve ALICE))
             "self-approval is refused in the model, not just hidden in the UI")
  (define done (l10n-review! conn (hash-ref t 'id) 'approve BOB))
  (check-equal? (hash-ref done 'status) "approved")
  (close-db! conn))

(test-case "a machine draft has no human author, so anyone may review it"
  (define conn (fresh))
  (l10n-import! conn (base '("a.one" . "One")) '())
  (define mid (hash-ref (car (hash-ref (l10n-list conn "nl") 'items)) 'message_id))
  (define t (l10n-submit! conn mid "nl" "Een" "" #:status "machine"))
  (check-equal? (hash-ref t 'status) "machine")
  (check-equal? (hash-ref (l10n-review! conn (hash-ref t 'id) 'approve ALICE) 'status) "approved")
  (close-db! conn))

(test-case "reject sends a string back to drafted and clears nothing else"
  (define conn (fresh))
  (l10n-import! conn (base '("a.one" . "One")) '())
  (define mid (hash-ref (car (hash-ref (l10n-list conn "nl") 'items)) 'message_id))
  (define t (l10n-submit! conn mid "nl" "Een" ALICE))
  (define back (l10n-review! conn (hash-ref t 'id) 'reject BOB))
  (check-equal? (hash-ref back 'status) "drafted")
  (check-equal? (hash-ref back 'text) "Een" "the work survives a rejection")
  (close-db! conn))

;; ---- export ------------------------------------------------------------------
(test-case "export is approved-only — a draft can never reach the product"
  (define conn (fresh))
  (l10n-import! conn (base '("a.one" . "One") '("a.two" . "Two")) '())
  (define items (hash-ref (l10n-list conn "nl") 'items))
  (define m1 (hash-ref (first items) 'message_id))
  (define m2 (hash-ref (second items) 'message_id))
  (define t1 (l10n-submit! conn m1 "nl" "Een" ALICE))
  (l10n-review! conn (hash-ref t1 'id) 'approve BOB)
  (l10n-submit! conn m2 "nl" "Twee" ALICE)          ; left needing review

  (define cat (l10n-export conn "nl"))
  (check-equal? (hash-count (catalog-messages cat)) 1)
  (check-true (and (catalog-ref cat "a.one") #t))
  (check-false (catalog-ref cat "a.two") "a string awaiting review is not exported")
  (close-db! conn))

(test-case "export round-trips through the catalog format the runtime reads"
  (define conn (fresh))
  (l10n-import! conn (base '("a.one" . "One")) '())
  (define mid (hash-ref (car (hash-ref (l10n-list conn "nl") 'items)) 'message_id))
  (define t (l10n-submit! conn mid "nl" "Een" ALICE))
  (l10n-review! conn (hash-ref t 'id) 'approve BOB)
  (define cat (l10n-export conn "nl"))
  (check-equal? (catalog-locale cat) "nl")
  (check-equal? (msg-text (catalog-ref cat "a.one")) "Een")
  (check-equal? (msg-hash (catalog-ref cat "a.one")) (source-hash "One")
                "the exported hash is the English it was written against")
  (close-db! conn))

;; ---- coverage ----------------------------------------------------------------
(test-case "coverage counts approved over the base, and splits by namespace"
  (define conn (fresh))
  (l10n-import! conn (base '("http.a" . "A") '("http.b" . "B") '("ui.c" . "C") '("ui.d" . "D")) '())
  (define items (hash-ref (l10n-list conn "nl") 'items))
  (define t (l10n-submit! conn (hash-ref (first items) 'message_id) "nl" "A!" ALICE))
  (l10n-review! conn (hash-ref t 'id) 'approve BOB)

  (define c (l10n-coverage conn "nl"))
  (check-equal? (hash-ref c 'total) 4)
  (check-equal? (hash-ref c 'approved) 1)
  (check-equal? (hash-ref c 'pct) 25.0)
  (check-equal? (hash-ref (hash-ref c 'by_status) 'missing) 3)
  (check-equal? (length (hash-ref c 'by_namespace)) 2 "http and ui")
  (close-db! conn))

(test-case "listing filters by derived status and by namespace"
  (define conn (fresh))
  (l10n-import! conn (base '("http.a" . "A") '("ui.c" . "C")) '())
  (check-equal? (length (hash-ref (l10n-list conn "nl" #:namespace "ui") 'items)) 1)
  (check-equal? (length (hash-ref (l10n-list conn "nl" #:status "missing") 'items)) 2)
  (check-equal? (length (hash-ref (l10n-list conn "nl" #:status "approved") 'items)) 0)
  (check-equal? (length (hash-ref (l10n-list conn "nl" #:q "ui.") 'items)) 1 "search hits the key")
  (close-db! conn))
