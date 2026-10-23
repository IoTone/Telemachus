#lang racket/base

;; test/anchor-tests.rkt — issue #66: the external anchor for both hash chains.
;;
;;   raco test test/anchor-tests.rkt
;;   DATABASE_URL="postgres://…" raco test test/anchor-tests.rkt
;;
;; THE CASE THAT MATTERS IS CASE 3. Both chains already detect a row altered in
;; place and a row removed from the middle; what neither detects is a rewrite by
;; somebody who can WRITE the table, because they recompute every link after the
;; row they changed and the chain verifies again. So the test that justifies this
;; whole slice performs exactly that attack — rewrite a row, re-seal the chain,
;; confirm `audit-chain-verify` says `ok` — and then shows the RETAINED receipt
;; catching it. A test that only checked that receipts verify would pass against
;; a feature that protects nothing.

(require rackunit db-kit/portable
         racket/port racket/list racket/string json
         db-kit/migrate
         "../domain/db/migrations.rkt"
         "db-fixture.rkt"
         "../domain/authz/authz.rkt"
         "../domain/audit/chain.rkt"
         "../domain/audit/anchor.rkt"
         (only-in "../domain/authz/signing.rkt" bytes->hex hex->bytes ed25519-public-key))

(define KEY "4ccd089b28ff96da9db6c346ec114e0f5b8a319f35aba624da8cf6ed4fb8a6fb")
(define OTHER-KEY "c5aa8df43f9f837bedb7442f31dcb7b166d38535076f094b85ce3a2e0b4458f7")
(define PUB (bytes->hex (ed25519-public-key (hex->bytes KEY))))

(define (with-key k thunk)
  (define old (getenv "TELEMACHUS_ANCHOR_KEY"))
  (dynamic-wind (lambda () (putenv "TELEMACHUS_ANCHOR_KEY" (or k "")))
                thunk
                ;; restored in a dynamic-wind: a failing check raises, and a key
                ;; leaking into a later test in this file is the trap FLEET-4's
                ;; `set-cap-for!` case documents.
                (lambda () (putenv "TELEMACHUS_ANCHOR_KEY" (or old "")))))

(define (fresh)
  (define conn (fresh-db #:migrate? #f))
  (migrate! conn all-migrations)
  conn)

(define (write-entries! conn n #:org [org "o1"] #:team [team "t1"])
  (for ([i (in-range n)])
    (audit! conn #:action "repo.read" #:actor-type "user" #:actor-id "u1"
            #:team-id team #:org-id org #:resource-type "repo"
            #:resource-id (format "obj-~a" i) #:result "ok"
            #:meta (format "{\"n\":~a}" i))))

;; a retained copy: exported to a string and read back as the retainer would,
;; never the in-memory hash the emitter returned. The artifact is what is under
;; test, and `payload` has to survive a round trip through JSON byte for byte or
;; no signature on it will ever check again.
(define (retain conn)
  (define out (open-output-string))
  (anchor-export-jsonl conn out)
  (for/list ([l (in-list (string-split (get-output-string out) "\n"))]
             #:unless (string=? (string-trim l) ""))
    (string->jsexpr l)))

;; ---- 1. emitting, and what a receipt covers ------------------------------------
(test-case "a receipt measures both chains and is signed"
  (with-key KEY (lambda ()
    (define conn (fresh))
    (write-entries! conn 5)
    (define r (anchor-emit! conn))
    (check-equal? (hash-ref r 'seq) 1 "the series starts at 1")
    (check-equal? (hash-ref r 'prev_hash) 'null "the first receipt has no predecessor")
    (check-equal? (hash-ref r 'public_key) PUB)
    (check-true (> (hash-ref r 'chains) 0) "it covers at least the audit chain")
    ;; ANCHOR-8: the heads are read AFTER a seal, so an honest instance can
    ;; verify itself afterwards. Emission is what sealed these.
    (check-equal? (hash-ref (audit-chain-status conn "o1") 'unsealed) 0
                  "emitting sealed the chain first")
    ;; the payload is an ordered LIST, never a hash — the stability trap
    (define payload (string->jsexpr (hash-ref r 'payload)))
    (check-true (list? payload))
    (check-equal? (list-ref payload 0) "telemachus.anchor.v1")
    (check-equal? (list-ref payload 2) 1 "the sequence is inside the signed bytes")
    ;; and a retained copy verifies against the published key
    (define v (anchor-verify-series (retain conn) #:public-key PUB))
    (check-true (hash-ref v 'ok))
    (check-true (hash-ref v 'verified))
    (check-equal? (hash-ref v 'checked) 1)
    (close-db! conn))))

;; ---- 2. the series is chained (ANCHOR-3) ---------------------------------------
(test-case "receipts link to their predecessor, and the series verifies"
  (with-key KEY (lambda ()
    (define conn (fresh))
    (write-entries! conn 2)
    (define r1 (anchor-emit! conn))
    (write-entries! conn 2)
    (define r2 (anchor-emit! conn))
    (write-entries! conn 2)
    (define r3 (anchor-emit! conn))
    (check-equal? (map (lambda (r) (hash-ref r 'seq)) (list r1 r2 r3)) '(1 2 3))
    (check-equal? (hash-ref r2 'prev_hash) (hash-ref r1 'hash))
    (check-equal? (hash-ref r3 'prev_hash) (hash-ref r2 'hash))
    (define v (anchor-verify-series (retain conn) #:public-key PUB))
    (check-true (hash-ref v 'ok))
    (check-equal? (hash-ref v 'checked) 3)
    (check-equal? (hash-ref v 'first_seq) 1)
    (check-equal? (hash-ref v 'last_seq) 3)
    (close-db! conn))))

;; ---- 3. THE CLAIM: a rewrite the chain cannot see, that the anchor can ----------
(test-case "a rewritten-and-resealed audit chain verifies internally and still fails against a retained receipt"
  (with-key KEY (lambda ()
    (define conn (fresh))
    (write-entries! conn 6)
    ;; the operator emits a receipt and retains it, off the box
    (void (anchor-emit! conn))
    (define retained (retain conn))
    (define head-then (hash-ref (audit-chain-status conn "o1") 'head))
    (check-true (hash-ref (anchor-verify-series retained #:public-key PUB) 'ok))

    ;; ---- the attack. Someone who can WRITE the table edits an entry and
    ;; relinks everything after it, which is precisely what AUD-10…16 and LAY-11
    ;; say they cannot detect.
    (query-exec conn "UPDATE audit_log SET action = 'repo.write' WHERE resource_id = 'obj-2'")
    (query-exec conn "UPDATE audit_log SET chain_prev = NULL, chain_hash = NULL")
    (void (audit-chain-seal! conn))

    ;; the internal chain is happy again — this is the gap, asserted rather than
    ;; assumed, because if it ever stopped being true this slice would be moot
    (check-true (hash-ref (audit-chain-verify conn "o1") 'ok)
                "the chain verifies after the rewrite: that is the gap #66 is about")
    (define head-now (hash-ref (audit-chain-status conn "o1") 'head))
    (check-false (equal? head-then head-now) "but the head moved")

    ;; ---- and the retained receipt catches it. The comparison is the operator's
    ;; own: the retained receipt names a head this instance no longer reports.
    (define claimed (list-ref (string->jsexpr (hash-ref (car retained) 'payload)) 6))
    (define audit-row (findf (lambda (row) (equal? (car row) "audit")) claimed))
    (check-equal? (list-ref audit-row 2) head-then)
    (check-false (equal? (list-ref audit-row 2) head-now)
                 "the retained receipt disagrees with the rewritten database")
    ;; the retained copy is still internally valid — it was never touched, which
    ;; is the whole point of it being somewhere else
    (check-true (hash-ref (anchor-verify-series retained #:public-key PUB) 'ok))
    (close-db! conn))))

;; ---- 4. suppression (ANCHOR-3's other half) ------------------------------------
(test-case "a gap in the retained series is detected"
  (with-key KEY (lambda ()
    (define conn (fresh))
    (write-entries! conn 2) (void (anchor-emit! conn))
    (write-entries! conn 2) (void (anchor-emit! conn))
    (write-entries! conn 2) (void (anchor-emit! conn))
    (define all (retain conn))
    (check-equal? (length all) 3)
    ;; the retainer holds 1 and 3: receipt 2 was never delivered
    (define gapped (list (first all) (third all)))
    (define v (anchor-verify-series gapped #:public-key PUB))
    (check-false (hash-ref v 'ok))
    (check-equal? (hash-ref v 'broken_at) 3)
    (check-true (regexp-match? #px"missing or were suppressed" (hash-ref v 'problem)))
    (close-db! conn))))

(test-case "deleting receipts and re-emitting reuses a sequence number, and that shows"
  (with-key KEY (lambda ()
    (define conn (fresh))
    (write-entries! conn 2)
    (define r1 (anchor-emit! conn))
    (write-entries! conn 2)
    (define r2 (anchor-emit! conn))
    (define retained (retain conn))
    ;; the writer destroys receipt 2 on the box and emits a fresh one over its
    ;; sequence number, now measuring the rewritten world
    (query-exec conn "DELETE FROM anchor_receipts WHERE seq = 2")
    (write-entries! conn 3)
    (define r2* (anchor-emit! conn))
    (check-equal? (hash-ref r2* 'seq) 2 "the sequence was reused")
    (check-false (equal? (hash-ref r2* 'hash) (hash-ref r2 'hash)))
    ;; the retainer notices because THEY hold the original seq 2
    (define onbox (retain conn))
    (define their-2 (findf (lambda (r) (= 2 (hash-ref r 'seq))) retained))
    (define box-2 (findf (lambda (r) (= 2 (hash-ref r 'seq))) onbox))
    (check-false (equal? (hash-ref their-2 'hash) (hash-ref box-2 'hash))
                 "two different receipts claim sequence 2")
    ;; and a series that splices both is refused rather than quietly accepted
    (define v (anchor-verify-series (list (first retained) their-2 box-2) #:public-key PUB))
    (check-false (hash-ref v 'ok))
    (close-db! conn))))

;; ---- 5. tampering with a retained receipt --------------------------------------
(test-case "an edited payload fails its signature"
  (with-key KEY (lambda ()
    (define conn (fresh))
    (write-entries! conn 3)
    (void (anchor-emit! conn))
    (define retained (retain conn))
    (define r (car retained))
    ;; a retainer (or anyone on the path) rewrites the measured head
    (define edited
      (hash-set r 'payload (regexp-replace #px"\"[0-9a-f]{64}\"" (hash-ref r 'payload)
                                           "\"0000000000000000000000000000000000000000000000000000000000000000\"")))
    (define v (anchor-verify-series (list edited) #:public-key PUB))
    (check-false (hash-ref v 'ok))
    (check-true (or (regexp-match? #px"hash does not match" (hash-ref v 'problem))
                    (regexp-match? #px"not signed by the expected key" (hash-ref v 'problem))))
    (close-db! conn))))

(test-case "a receipt signed by another key is refused when an expected key is given"
  (with-key OTHER-KEY (lambda ()
    (define conn (fresh))
    (write-entries! conn 3)
    (void (anchor-emit! conn))
    (define retained (retain conn))
    ;; internally consistent — it really is signed by the key it carries
    (define self (anchor-verify-series retained))
    (check-true (hash-ref self 'ok))
    (check-true (hash-ref self 'self_consistent))
    (check-false (hash-ref self 'verified)
                 "with no expected key, `verified` is NEVER true (ANCHOR-6)")
    ;; but it is not OUR series
    (define v (anchor-verify-series retained #:public-key PUB))
    (check-false (hash-ref v 'ok))
    (check-true (regexp-match? #px"not signed by the expected key" (hash-ref v 'problem)))
    (close-db! conn))))

;; ---- 6. ANCHOR-6: a self-carried key proves nothing, and the report says so -----
(test-case "self_consistent and verified are different answers"
  (with-key KEY (lambda ()
    (define conn (fresh))
    (write-entries! conn 2)
    (void (anchor-emit! conn))
    (define retained (retain conn))
    (define without (anchor-verify-series retained))
    (check-true (hash-ref without 'self_consistent))
    (check-false (hash-ref without 'verified))
    (check-equal? (hash-ref without 'signed_by) PUB "it reports WHICH key claims to have signed")
    (define with* (anchor-verify-series retained #:public-key PUB))
    (check-true (hash-ref with* 'verified))
    ;; an empty retained file is not a pass dressed up as one
    (define none (anchor-verify-series '()))
    (check-true (hash-ref none 'ok))
    (check-false (hash-ref none 'verified))
    (check-true (string? (hash-ref none 'note)) "it says that nothing was retained")
    (close-db! conn))))

;; ---- 7. off unless configured (ANCHOR-7) ----------------------------------------
(test-case "with no key, nothing is emitted and the refusal names the generator"
  (with-key #f (lambda ()
    (define conn (fresh))
    (write-entries! conn 2)
    (check-false (hash-ref (anchor-status conn) 'enabled))
    (check-equal? (hash-ref (anchor-status conn) 'public_key) 'null)
    (check-exn #px"keygen" (lambda () (anchor-emit! conn)))
    (check-equal? (anchor-receipt-count conn) 0)
    ;; and emitting did not half-happen
    (check-equal? (hash-ref (anchor-status conn) 'receipts) 0)
    (close-db! conn))))

;; ---- 8. the emission is audited, and the entry carries a team -------------------
(test-case "anchor.emitted is audited with the acting team, and carries no head"
  (with-key KEY (lambda ()
    (define conn (fresh))
    (write-entries! conn 2)
    (void (anchor-emit! conn #:actor-id "u9" #:team-id "t1"))
    ;; SEVENTH appearance of the #:team-id shape: `audit-list` filters
    ;; `WHERE team_id = ?`, so an entry without one is invisible to everybody.
    (define rows (audit-list conn "t1" #:limit 50))
    (define e (findf (lambda (r) (equal? (hash-ref r 'action) "anchor.emitted")) rows))
    (check-true (hash? e) "the entry is visible in the acting team's trail")
    ;; `audit-list` does not project `meta`, so the meta assertion reads the row.
    ;; The same shape as #59's note: asserting over an API that never carried the
    ;; field would pass for the wrong reason.
    (define meta (string->jsexpr
                  (query-value conn "SELECT meta FROM audit_log WHERE action = ?" "anchor.emitted")))
    (check-equal? (hash-ref meta 'seq) 1)
    (check-true (string? (hash-ref meta 'hash)))
    (close-db! conn))))


;; ---- 9. the predecessor link, on its own -----------------------------------------
;; The sequence can be intact while the LINK lies — which is what somebody who
;; understood the scheme would try, and is the half `audit-chain-verify` had to
;; add for the same reason.
(test-case "a receipt that names the wrong predecessor is refused"
  (with-key KEY (lambda ()
    (define conn (fresh))
    (write-entries! conn 2) (void (anchor-emit! conn))
    (write-entries! conn 2) (void (anchor-emit! conn))
    (define retained (retain conn))
    (define broken
      (list (first retained)
            (hash-set (second retained) 'prev_hash
                      "0000000000000000000000000000000000000000000000000000000000000000")))
    (define v (anchor-verify-series broken #:public-key PUB))
    (check-false (hash-ref v 'ok))
    (check-equal? (hash-ref v 'broken_at) 2)
    (check-true (regexp-match? #px"predecessor" (hash-ref v 'problem)))
    (close-db! conn))))

;; ---- 10. the receipt covers the REVIEW chain too (ANCHOR-2) -----------------------
;; One receipt, both chains. The decided review is inserted with raw SQL because
;; what is under test is `review-chain-heads` reading a chain, not the decision
;; path that writes one — and a hash is all this needs to find.
(test-case "a receipt carries a row per chain, review as well as audit"
  (with-key KEY (lambda ()
    (define conn (fresh))
    (write-entries! conn 2)
    (query-exec conn
      (string-append "INSERT INTO reviews (id, team_id, title, subject, checklist, status, "
                     "verdict, rationale, answers, requested_ms, decided_ms, hash) "
                     "VALUES (?, ?, ?, '{}', '[]', 'decided', 'approve', '', '{}', ?, ?, ?)")
      "rev1" "t1" "a decision" 1000 2000
      "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
    (define r (anchor-emit! conn))
    (define rows (list-ref (string->jsexpr (hash-ref r 'payload)) 6))
    (define kinds (map car rows))
    ;; `and … #t`: `member` answers the TAIL from the element onward, which is
    ;; truthy but is not #t, and `check-true` wants #t exactly.
    (check-true (and (member "audit" kinds) #t) "the audit chain is measured")
    (check-true (and (member "review" kinds) #t) "and so is the review chain, in the SAME receipt")
    (define rev (findf (lambda (row) (equal? (car row) "review")) rows))
    (check-equal? (list-ref rev 1) "t1" "scoped per team, as LAY-11's chain is")
    (check-equal? (list-ref rev 2)
                  "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
    (check-equal? (list-ref rev 3) 1 "and it says how many decisions it covers")
    (close-db! conn))))


;; ---- 11. truncation at the FRONT (found by the smoke, not by these tests) --------
;; A file that starts at seq 7 is a valid SUB-CHAIN — a retainer may have begun
;; later — so the verdict is `ok`. But a first receipt whose `prev_hash` is not
;; null PROVES an earlier receipt existed and is absent, which is evidence, and
;; the first version of this verifier threw that evidence away: it reported a
;; one-receipt file as a clean pass. `complete` is the answer, and the note says
;; what the file CANNOT settle.
(test-case "a series that does not reach its origin is ok but NOT complete"
  (with-key KEY (lambda ()
    (define conn (fresh))
    (write-entries! conn 2) (void (anchor-emit! conn))
    (write-entries! conn 2) (void (anchor-emit! conn))
    (write-entries! conn 2) (void (anchor-emit! conn))
    (define all (retain conn))
    ;; the whole series reaches the origin
    (define whole (anchor-verify-series all #:public-key PUB))
    (check-true (hash-ref whole 'ok))
    (check-true (hash-ref whole 'complete))
    (check-equal? (hash-ref whole 'note) 'null)
    ;; the retainer holds only 2 and 3
    (define tail-only (cdr all))
    (define v (anchor-verify-series tail-only #:public-key PUB))
    (check-true (hash-ref v 'ok) "a sub-chain is internally sound")
    (check-true (hash-ref v 'verified))
    (check-false (hash-ref v 'complete) "but it does not reach the origin")
    (check-equal? (hash-ref v 'first_seq) 2)
    (check-true (regexp-match? #px"names a predecessor it does not contain" (hash-ref v 'note)))
    ;; and it refuses to guess WHY — retention beginning later and suppression
    ;; look identical in a retained file, which is the honest limit
    (check-true (regexp-match? #px"cannot tell those apart" (hash-ref v 'note)))
    ;; a FAILURE still reports every field a caller prints — the CLI printed
    ;; last_seq unconditionally and a failure crashed it
    (define broken (anchor-verify-series (list (hash-set (car all) 'signature "00"))
                                         #:public-key PUB))
    (check-false (hash-ref broken 'ok))
    (for ([k (in-list '(checked broken_at problem verified self_consistent
                        signed_by instance_id first_seq last_seq complete))])
      (check-true (hash-has-key? broken k) (format "a failure reports ~a" k)))
    (close-db! conn))))

(printf "anchor tests: ok\n")
