#lang racket/base

;; test/audit-chain-tests.rkt — issue #84 r3: the chain and the export.
;;
;;   raco test test/audit-chain-tests.rkt
;;   DATABASE_URL="postgres://…" raco test test/audit-chain-tests.rkt
;;
;; #84's acceptance criterion is stated as a scale: "the hash chain verifies
;; after 10k events and fails verification if one row is altered." Both halves
;; are here, and the second is the one that matters — a chain that verifies but
;; cannot NOTICE is the shape of mistake this whole area invites.

(require rackunit db-kit/portable
         racket/port racket/list racket/string json
         db-kit/migrate
         "../domain/db/migrations.rkt"
         "db-fixture.rkt"
         "../domain/authz/authz.rkt"
         "../domain/audit/chain.rkt")

(define (fresh)
  (define conn (fresh-db #:migrate? #f))
  (migrate! conn all-migrations)
  conn)

;; Entries written directly, because what is under test is the CHAIN over
;; entries, not any particular feature that writes them.
(define (write-entries! conn n #:team [team "t1"] #:org [org "o1"])
  (for ([i (in-range n)])
    (audit! conn #:action "repo.read" #:actor-type "user" #:actor-id "u1"
            #:team-id team #:org-id org #:resource-type "repo"
            #:resource-id (format "obj-~a" i) #:result "ok"
            #:ip "203.0.113.5" #:user-agent "curl/8" #:request-id (format "req-~a" i)
            #:meta (format "{\"via\":\"api\",\"n\":~a}" i))))

;; ---- 1. the window, stated rather than hidden -----------------------------------
(test-case "an entry is unsealed until the sweep runs, and the status says so"
  (define conn (fresh))
  (write-entries! conn 3)
  ;; NOT sealed at insert: r6 caps a read at one indexed insert, and linking at
  ;; insert time would also FORK under two concurrent writers.
  (define before (audit-chain-status conn "o1"))
  (check-equal? (hash-ref before 'sealed) 0)
  (check-equal? (hash-ref before 'unsealed) 3 "the window is real and is reported")
  (check-equal? (hash-ref before 'head) 'null)

  (check-equal? (audit-chain-seal! conn) 3 "the sweep links them")
  (define after (audit-chain-status conn "o1"))
  (check-equal? (hash-ref after 'sealed) 3)
  (check-equal? (hash-ref after 'unsealed) 0)
  (check-true (string? (hash-ref after 'head)))

  ;; idempotent: safe on a timer, and safe to run twice
  (check-equal? (audit-chain-seal! conn) 0)
  (check-equal? (hash-ref (audit-chain-status conn "o1") 'head) (hash-ref after 'head)
                "a second sweep does not rewrite what it already linked")
  (close-db! conn))

;; ---- 2. the acceptance criterion, at its stated scale ---------------------------
(test-case "the chain verifies after 10k events"
  (define conn (fresh))
  (write-entries! conn 10000)
  (check-equal? (audit-chain-seal! conn #:limit 20000) 10000)
  (define v (audit-chain-verify conn "o1"))
  (check-true (hash-ref v 'ok) (format "~a" v))
  (check-equal? (hash-ref v 'checked) 10000)
  (check-equal? (hash-ref v 'broken_at) 'null)
  (close-db! conn))

;; ---- 3. …and fails if one row is altered ----------------------------------------
;; Three separate tamperings, because they are different attacks and a chain can
;; catch one and miss another:
;;   a) a field edited in place
;;   b) an entry DELETED from the middle — nothing in the row is wrong, the
;;      sequence is
;;   c) `chain_prev` rewritten to skip a deleted predecessor, which is what
;;      somebody who understood the scheme would try, and which a verify that
;;      only recomputed the HASH would accept
(test-case "a row altered in place breaks the chain, and the break is NAMED"
  (define conn (fresh))
  (write-entries! conn 50)
  (void (audit-chain-seal! conn))
  (define victim (query-value conn
    "SELECT id FROM audit_log WHERE resource_id = 'obj-20'"))
  ;; the result flipped from denied to ok is the edit somebody would actually make
  (query-exec conn "UPDATE audit_log SET result = 'ok-edited' WHERE id = ?" victim)
  (define v (audit-chain-verify conn "o1" #:seal? #f))
  (check-false (hash-ref v 'ok))
  (check-equal? (hash-ref v 'broken_at) victim "the FIRST broken entry is named")
  (check-equal? (hash-ref v 'checked) 20 "…and how far the chain was intact")
  (close-db! conn))

(test-case "an entry removed from the MIDDLE breaks the chain"
  (define conn (fresh))
  (write-entries! conn 30)
  (void (audit-chain-seal! conn))
  (define victim (query-value conn "SELECT id FROM audit_log WHERE resource_id = 'obj-10'"))
  (define next-id (query-value conn
    "SELECT id FROM audit_log WHERE resource_id = 'obj-11'"))
  (query-exec conn "DELETE FROM audit_log WHERE id = ?" victim)
  (define v (audit-chain-verify conn "o1" #:seal? #f))
  (check-false (hash-ref v 'ok) "a deletion leaves every surviving row internally valid")
  (check-equal? (hash-ref v 'broken_at) next-id
                "the break is the entry whose predecessor is gone")
  (close-db! conn))

(test-case "rewriting chain_prev to skip the deleted row does NOT repair it"
  (define conn (fresh))
  (write-entries! conn 20)
  (void (audit-chain-seal! conn))
  (define ids (query-list conn
    (string-append "SELECT id FROM audit_log WHERE org_id = 'o1' ORDER BY at_us ASC")))
  (define before-victim (list-ref ids 4))
  (define victim (list-ref ids 5))
  (define after-victim (list-ref ids 6))
  (define prev-hash (query-value conn "SELECT chain_hash FROM audit_log WHERE id = ?" before-victim))
  (query-exec conn "DELETE FROM audit_log WHERE id = ?" victim)
  ;; the repair somebody who understood the scheme would attempt: point the
  ;; survivor at the row before the one they removed
  (query-exec conn "UPDATE audit_log SET chain_prev = ? WHERE id = ?" prev-hash after-victim)
  (define v (audit-chain-verify conn "o1" #:seal? #f))
  (check-false (hash-ref v 'ok)
               (string-append "the link was made consistent but the HASH still covers the old"
                              " predecessor — which is why the verify checks both halves"))
  (check-equal? (hash-ref v 'broken_at) after-victim)
  (close-db! conn))

;; ---- 4. the chain is PER ORG ----------------------------------------------------
(test-case "one org's history cannot invalidate another's"
  (define conn (fresh))
  (write-entries! conn 10 #:team "t1" #:org "o1")
  (write-entries! conn 10 #:team "t2" #:org "o2")
  (void (audit-chain-seal! conn))
  (check-true (hash-ref (audit-chain-verify conn "o1" #:seal? #f) 'ok))
  (check-true (hash-ref (audit-chain-verify conn "o2" #:seal? #f) 'ok))
  ;; break o1
  (query-exec conn "UPDATE audit_log SET action = 'x' WHERE org_id = 'o1' AND resource_id = 'obj-3'")
  (check-false (hash-ref (audit-chain-verify conn "o1" #:seal? #f) 'ok))
  (check-true (hash-ref (audit-chain-verify conn "o2" #:seal? #f) 'ok)
              "o2's chain is its own — the isolation boundary the org gate already draws")
  (close-db! conn))

(test-case "an entry with NO org is chained too, in its own bucket"
  (define conn (fresh))
  ;; a single-tenant instance's entries, and instance-level events anywhere
  (audit! conn #:action "user.login" #:actor-type "user" #:actor-id "u1" #:team-id "t1")
  (audit! conn #:action "user.login" #:actor-type "user" #:actor-id "u2" #:team-id "t1")
  (check-equal? (audit-chain-seal! conn) 2
                "an unchained entry with no org would otherwise be deletable without trace")
  (define v (audit-chain-verify conn "-" #:seal? #f))
  (check-true (hash-ref v 'ok))
  (check-equal? (hash-ref v 'checked) 2)
  (close-db! conn))

;; ---- 5. the export --------------------------------------------------------------
(test-case "the export is JSONL, carries the chain, and honours the date range"
  (define conn (fresh))
  (write-entries! conn 5)
  (void (audit-chain-seal! conn))
  (define out (open-output-string))
  (define n (audit-export-jsonl conn "o1" out))
  (check-equal? n 5)
  (define lines (filter (lambda (l) (not (string=? l ""))) (string-split (get-output-string out) "\n")))
  (check-equal? (length lines) 5 "one entry per LINE, so it streams and appends")
  ;; every line is independently parseable, which is the whole point of the format
  (define parsed (map (lambda (l) (read-json (open-input-string l))) lines))
  (check-true (andmap hash? parsed))
  ;; THE CHAIN FIELDS ARE IN THE EXPORT: a copy kept elsewhere can be verified
  ;; against itself, which is the nearest thing to the external anchor this
  ;; design is missing.
  (check-true (andmap (lambda (h) (string? (hash-ref h 'chain_hash #f))) parsed))
  (check-equal? (hash-ref (car parsed) 'chain_prev) 'null "the first entry has no predecessor")
  (check-equal? (hash-ref (cadr parsed) 'chain_prev) (hash-ref (car parsed) 'chain_hash)
                "…and each later one names the one before it")
  ;; ordered oldest-first, which is the order a verifier needs
  (check-equal? (map (lambda (h) (hash-ref h 'resource_id)) parsed)
                '("obj-0" "obj-1" "obj-2" "obj-3" "obj-4"))
  ;; meta is carried VERBATIM, as the stored string: parsing and re-emitting it
  ;; would reorder its keys and the digest covers the stored bytes
  (check-true (string? (hash-ref (car parsed) 'meta)))

  ;; the range filters on at_us, the ordering key — not the TEXT `at`, whose
  ;; format differs by dialect
  (define cut (hash-ref (caddr parsed) 'at_us))
  (define out2 (open-output-string))
  (check-equal? (audit-export-jsonl conn "o1" out2 #:from cut) 3
                "from is inclusive, on the microsecond ordering key")
  (define out3 (open-output-string))
  (check-equal? (audit-export-jsonl conn "o1" out3 #:to cut) 3 "…and so is to")
  (close-db! conn))

(test-case "the export seals first, so an exported tail is never unprotected"
  (define conn (fresh))
  (write-entries! conn 4)
  ;; deliberately NOT sealed by hand
  (define out (open-output-string))
  (check-equal? (audit-export-jsonl conn "o1" out) 4)
  (define parsed (map (lambda (l) (read-json (open-input-string l)))
                      (filter (lambda (l) (not (string=? l "")))
                              (string-split (get-output-string out) "\n"))))
  (check-true (andmap (lambda (h) (string? (hash-ref h 'chain_hash #f)))
                      parsed)
              "every exported entry carries a chain hash, or the copy is unverifiable")
  (close-db! conn))
