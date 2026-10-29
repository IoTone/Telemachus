#lang racket/base

;; test/chunksearch-tests.rkt — #189 step 5: the nearest-chunk read.
;;   raco test test/chunksearch-tests.rkt
;;   DATABASE_URL=postgres://… raco test test/chunksearch-tests.rkt
;;
;; WHAT THIS FILE CAN AND CANNOT ESTABLISH, said first because the distinction is
;; the whole reason step 5 could be built before the GPU rig's driver upgrade.
;;
;; It CAN establish everything about the read that is a property of the code: that
;; the nearest vector is the one that comes back, that the window cannot reach
;; another team, another model, a superseded version or a deleted document, that
;; `can?` is applied per row and a colleague's private chunk is withheld without
;; costing a readable one its place, that a row of a foreign width is counted
;; rather than fatal, and that the offsets a hit carries resolve through
;; `spans-covering` to the place the text was read.
;;
;; It CANNOT establish that the read retrieves the RIGHT chunk for a question
;; asked in English or Japanese. That is step 3's calibration — the chunk size and
;; the overlap, provisional at 1,024 characters and 154 — and it needs a live
;; `nomic-embed-text`, in both languages, which is the same measurement
;; `EMBED-MARGIN-SCALE` (#163) is waiting on. The vectors here are synthetic and
;; chosen so the ANSWER is arithmetic rather than semantics: a query that IS one
;; chunk's vector must score 1.0 against it, whatever a real embedder would have
;; produced for the text.

(require rackunit db-kit/portable racket/port racket/file racket/flonum racket/list
         db-kit/migrate
         "../domain/db/migrations.rkt"
         "db-fixture.rkt"
         "../domain/authz/authz.rkt"
         "../domain/authz/secretbox.rkt"
         "../domain/repo/blobs.rkt"
         "../domain/repo/repo.rkt"
         "../domain/repo/extract.rkt"
         "../domain/ai/vectors.rkt"
         "../domain/ai/chunk.rkt"
         "../domain/ai/chunkstore.rkt"
         "../domain/ai/chunksearch.rkt")

(define BLOB-ROOT (make-temporary-file "telemachus-chunksearch-~a" 'directory))
(current-blob-root BLOB-ROOT)

(define (fresh)
  (define conn (fresh-db #:migrate? #f))
  (migrate! conn all-migrations)
  conn)

;; ENVN-2's gate: the variable NAME is a value, never a `getenv` literal.
(define KEY-VAR "TMACH_SECRET_KEY")
(define CONTENT-VAR "TMACH_ENCRYPT_CONTENT")
(define KEY (make-string 64 #\a))

(define (with-env* pairs thunk)
  (define saved (for/list ([kv (in-list pairs)]) (cons (car kv) (getenv (car kv)))))
  (dynamic-wind
    (lambda () (for ([kv (in-list pairs)]) (putenv (car kv) (or (cdr kv) ""))))
    thunk
    (lambda () (for ([kv (in-list saved)]) (putenv (car kv) (or (cdr kv) ""))) (void))))

(define MODEL "nomic-embed-text")

;; A vector of `n` components whose direction depends on `seed`, as a Racket
;; vector of reals — what `embedding-vectors` answers. Deliberately not round:
;; the store truncates to float32, so a fixture built on 0.5 would pass against a
;; broken pack.
(define (fake-embedding seed [n 8])
  (for/vector ([i (in-range n)]) (sin (+ seed (* 0.37 i)))))

(define (chunks-of text) (let-values ([(cs _t) (chunk-text text)]) cs))

;; one team, one principal, one document with `n` chunks embedded under MODEL.
;; Chunk i's vector is `(fake-embedding i)`, so "the nearest chunk to
;; (fake-embedding 2)" has an arithmetic answer.
(define (seed-doc conn p #:key [key "notes/a.md"] #:visibility [vis "team"]
                  #:text [text (make-string 3000 #\x)] #:model [model MODEL]
                  #:width [width 8] #:spans [spans '()])
  (define o (repo-put! conn p #:key key #:port (open-input-bytes (string->bytes/utf-8 text))
                       #:content-type "text/markdown" #:filename "a.md" #:visibility vis))
  (define cs (chunks-of text))
  (repo-text-upsert! conn (hash-ref o 'id) (hash-ref o 'version_id) text #:spans spans)
  (chunks-replace! conn (hash-ref o 'id) (hash-ref o 'version_id) model cs
                   (for/list ([(c i) (in-indexed cs)]) (fake-embedding (* 1.0 i) width)))
  (values o cs))

;; ---- 1. the nearest chunk is the nearest ---------------------------------------
(test-case "a query that IS one chunk's vector scores 1.0 against it and comes first"
  (define conn (fresh))
  (define-values (uid tid) (bootstrap! conn #:username "alice"))
  (define p (user-principal conn uid tid))
  (define-values (o cs) (seed-doc conn p))
  (check > (length cs) 2 "the fixture must produce several chunks for a ranking to mean anything")
  (define rep (chunks-nearest conn p (fake-embedding 2.0) MODEL #:k 3))
  (define hits (hash-ref rep 'hits))
  (check-equal? (length hits) 3)
  ;; chunk 2 is the one whose vector the query is
  (check-equal? (hash-ref (car hits) 'index) 2)
  (check-= (hash-ref (car hits) 'score) 1.0 1e-5)
  ;; and the ranking really is descending, not insertion order
  (check-true (apply >= (for/list ([h (in-list hits)]) (hash-ref h 'score)))
              "the hits are not in descending score order")
  (check-equal? (hash-ref rep 'skipped) 0)
  (check-equal? (hash-ref rep 'withheld) 0)
  (check-false (hash-ref rep 'truncated))
  (check-equal? (hash-ref rep 'scanned) (length cs))
  (close-db! conn))

;; ---- 2. the citation -----------------------------------------------------------
(test-case "a hit's offsets resolve through spans-covering to where the text was read"
  ;; CHUNK-1's whole claim, which is what makes a hit citable with no new code:
  ;; a chunk's offsets and `repo_text.spans` index the SAME string, so the one
  ;; resolves into the other. This is the assertion that would fail if a future
  ;; chunker grew a coordinate system of its own.
  (define conn (fresh))
  (define-values (uid tid) (bootstrap! conn #:username "alice"))
  (define p (user-principal conn uid tid))
  (define text (string-append (make-string 1500 #\a) (make-string 1500 #\b)))
  ;; two "pages", split where the text is
  (define spans (list (hasheq 'start 0 'end 1500 'page 1 'bbox (list 0 0 10 10))
                      (hasheq 'start 1500 'end 3000 'page 2 'bbox (list 0 0 10 10))))
  (define-values (o cs) (seed-doc conn p #:text text #:spans spans))
  ;; aim at the LAST chunk, which starts well into the second page
  (define last-i (sub1 (length cs)))
  (define rep (chunks-nearest conn p (fake-embedding (* 1.0 last-i)) MODEL #:k 1))
  (define h (car (hash-ref rep 'hits)))
  (check-equal? (hash-ref h 'index) last-i)
  (check-equal? (hash-ref h 'object_id) (hash-ref o 'id))
  (check-equal? (hash-ref h 'key) "notes/a.md")
  ;; the offsets are the chunker's own, so they are the stored chunk's
  (define stored (list-ref (chunks-for conn (hash-ref o 'id) (hash-ref o 'version_id)) last-i))
  (check-equal? (hash-ref h 'start) (hash-ref stored 'start))
  (check-equal? (hash-ref h 'end) (hash-ref stored 'end))
  ;; …and they resolve, through the REAL function, to the page the chunk starts on
  (define covering (spans-covering (repo-spans-for conn (hash-ref o 'id)) (hash-ref h 'start)))
  (check-equal? (length covering) 1)
  (check-equal? (hash-ref (car covering) 'page) 2)
  (close-db! conn))

;; ---- 3. the model filter -------------------------------------------------------
(test-case "vectors of another model are not compared, and are not merely ranked low"
  ;; VEC-20/EMB-8: a dot product between two unrelated coordinate systems is a
  ;; NUMBER, so mixing checkpoints answers confidently and nobody can tell. The
  ;; filter is in SQL, so the foreign rows are not even decoded — which is why the
  ;; assertion is on `scanned`, not only on the hits.
  (define conn (fresh))
  (define-values (uid tid) (bootstrap! conn #:username "alice"))
  (define p (user-principal conn uid tid))
  (define-values (o cs) (seed-doc conn p #:model "other-checkpoint"))
  (define rep (chunks-nearest conn p (fake-embedding 2.0) MODEL #:k 3))
  (check-equal? (hash-ref rep 'hits) '())
  (check-equal? (hash-ref rep 'scanned) 0 "the other model's rows entered the window")
  (check-equal? (hash-ref rep 'skipped) 0 "a filtered row must not be counted as skipped")
  ;; and the same store answers under its own model name
  (define rep2 (chunks-nearest conn p (fake-embedding 2.0) "other-checkpoint" #:k 3))
  (check-equal? (length (hash-ref rep2 'hits)) 3)
  (check-equal? (hash-ref (car (hash-ref rep2 'hits)) 'model) "other-checkpoint"
                "a hit must report the model it was compared under")
  (close-db! conn))

;; ---- 4. a superseded version ---------------------------------------------------
(test-case "a superseded version's vectors are UNREACHABLE, not merely stale"
  ;; VEC-18 arriving in the read's join. A re-upload does not clear the old rows
  ;; (`vector-store.md` says so deliberately — clearing them would throw away a
  ;; usable index the moment somebody fixed a typo), so the join on
  ;; `o.current_version_id` is the ONLY thing standing between a query and vectors
  ;; of bytes nobody can see any more.
  (define conn (fresh))
  (define-values (uid tid) (bootstrap! conn #:username "alice"))
  (define p (user-principal conn uid tid))
  (define-values (o cs) (seed-doc conn p))
  (define v1 (hash-ref o 'version_id))
  ;; a new version of the same object, with no embed run after it
  (define o2 (repo-put! conn p #:key "notes/a.md" #:port (open-input-bytes #"different bytes")
                        #:content-type "text/markdown" #:filename "a.md" #:visibility "team"))
  (check-not-equal? (hash-ref o2 'version_id) v1)
  (check-equal? (query-value conn "SELECT COUNT(*) FROM repo_chunks") (length cs)
                "the fixture must leave the OLD version's rows in place")
  (define rep (chunks-nearest conn p (fake-embedding 2.0) MODEL #:k 3))
  (check-equal? (hash-ref rep 'hits) '())
  (check-equal? (hash-ref rep 'scanned) 0)
  (close-db! conn))

;; ---- 5. the team window --------------------------------------------------------
(test-case "another team's chunks are never in the window"
  (define conn (fresh))
  (define-values (uid tid) (bootstrap! conn #:username "alice"))
  (define p (user-principal conn uid tid))
  (define-values (o cs) (seed-doc conn p))
  ;; a second team, with a principal who is a member of it and not of alice's
  (define other (create-team! conn #:name "Other" #:slug "other"))
  (define carol (create-user! conn #:username "carol" #:password "pw"))
  (add-member! conn #:team other #:user carol #:role "owner")
  (define pc (user-principal conn carol other))
  (define rep (chunks-nearest conn pc (fake-embedding 2.0) MODEL #:k 3))
  (check-equal? (hash-ref rep 'hits) '())
  (check-equal? (hash-ref rep 'scanned) 0 "another team's rows entered the window")
  (close-db! conn))

;; ---- 6. a deleted document -----------------------------------------------------
(test-case "a tombstoned document's chunks are out of the window, by the clause and not by luck"
  ;; `repo-delete!` clears `repo_chunks` itself (step 4), so no code path produces
  ;; the state this guards — which is what makes it defence in depth and why the
  ;; row is tombstoned BY HAND here. The feed queue's team clause needed the same
  ;; treatment for the same reason.
  (define conn (fresh))
  (define-values (uid tid) (bootstrap! conn #:username "alice"))
  (define p (user-principal conn uid tid))
  (define-values (o cs) (seed-doc conn p))
  (query-exec conn "UPDATE repo_objects SET deleted_at = ? WHERE id = ?"
              "2026-10-29 00:00:00" (hash-ref o 'id))
  (define rep (chunks-nearest conn p (fake-embedding 2.0) MODEL #:k 3))
  (check-equal? (hash-ref rep 'hits) '())
  (check-equal? (hash-ref rep 'scanned) 0)
  (close-db! conn))

;; ---- 7. can? per row, and the headroom -----------------------------------------
(test-case "a colleague's PRIVATE chunk is withheld and does not cost a readable one its place"
  ;; THE CASE THIS MODULE EXISTS TO GET RIGHT. Step 4 found the shape one slice
  ;; ago from the other side: `repo_list_unindexed` selected by `team_id` alone and
  ;; handed a member the id of a colleague's private document, which the next step
  ;; then refused. Here the private document is the BEST match, so taking exactly
  ;; `k` from the scan and filtering afterwards would answer nothing at all — the
  ;; recall hole `AUTHZ-HEADROOM` exists to push out.
  (define conn (fresh))
  (define-values (uid tid) (bootstrap! conn #:username "alice"))
  (define pa (user-principal conn uid tid))
  (define bob (create-user! conn #:username "bob" #:password "pw"))
  (add-member! conn #:team tid #:user bob #:role "member")
  (define pb (user-principal conn bob tid))
  ;; alice's PRIVATE document, whose only chunk is an exact match for the query
  (define secret (repo-put! conn pa #:key "hr/secret.md" #:port (open-input-bytes #"secret")
                            #:content-type "text/markdown" #:filename "s.md"
                            #:visibility "private"))
  (define scs (chunks-of "secret"))
  (check-equal? (length scs) 1)
  (chunks-replace! conn (hash-ref secret 'id) (hash-ref secret 'version_id) MODEL scs
                   (list (fake-embedding 99.0)))
  ;; and a team-visible document whose chunks are all less close to it
  (define-values (o cs) (seed-doc conn pa #:key "notes/a.md" #:visibility "team"))
  ;; alice sees her own private chunk first
  (define ra (chunks-nearest conn pa (fake-embedding 99.0) MODEL #:k 1))
  (check-equal? (hash-ref (car (hash-ref ra 'hits)) 'key) "hr/secret.md")
  (check-equal? (hash-ref ra 'withheld) 0)
  ;; bob does not — and still gets a hit, from the document he may read
  (define rb (chunks-nearest conn pb (fake-embedding 99.0) MODEL #:k 1))
  (check-equal? (length (hash-ref rb 'hits)) 1
                "the private chunk ranked first and took the whole answer with it")
  (check-equal? (hash-ref (car (hash-ref rb 'hits)) 'key) "notes/a.md")
  (check-equal? (hash-ref rb 'withheld) 1 "the withheld count must say a candidate was dropped")
  ;; nothing in a hit, for either of them, names a document the asker cannot read
  (for ([h (in-list (hash-ref rb 'hits))])
    (check-not-equal? (hash-ref h 'object_id) (hash-ref secret 'id)))
  (close-db! conn))

;; ---- 8. a row of another width -------------------------------------------------
(test-case "a row of another width is skipped and COUNTED, never fatal"
  ;; VEC-15: by read time such a row survived a model change, so it is a survivor
  ;; rather than a surprise and must not take somebody's query down — and a scan
  ;; that silently returned fewer results would be a recall problem nobody could
  ;; see. The two documents carry the SAME model name on purpose: that is the only
  ;; way the width check is reached, since `chunks-replace!` refuses two widths
  ;; within one set.
  (define conn (fresh))
  (define-values (uid tid) (bootstrap! conn #:username "alice"))
  (define p (user-principal conn uid tid))
  (define-values (o8 cs8) (seed-doc conn p #:key "notes/a.md" #:width 8))
  (define-values (o16 cs16) (seed-doc conn p #:key "notes/b.md" #:width 16
                                      #:text (make-string 2500 #\y)))
  (define rep (chunks-nearest conn p (fake-embedding 2.0 8) MODEL #:k 20))
  (check-equal? (hash-ref rep 'scanned) (+ (length cs8) (length cs16)))
  (check-equal? (hash-ref rep 'skipped) (length cs16)
                "the 16-component rows were not counted as skipped")
  (check-equal? (length (hash-ref rep 'hits)) (length cs8))
  (for ([h (in-list (hash-ref rep 'hits))])
    (check-equal? (hash-ref h 'object_id) (hash-ref o8 'id)))
  (close-db! conn))

;; ---- 9. a directionless query --------------------------------------------------
(test-case "a query with no direction is refused by name, not scored as the worst match"
  ;; VEC-31. An embedder answers a zero vector for empty input, and scoring one
  ;; would compare 0.0 against everything and report the whole corpus as equally
  ;; bad — a claim, where the honest answer is that the question had no direction.
  (define conn (fresh))
  (define-values (uid tid) (bootstrap! conn #:username "alice"))
  (define p (user-principal conn uid tid))
  (define-values (o cs) (seed-doc conn p))
  (check-exn #rx"no direction"
             (lambda () (chunks-nearest conn p (make-vector 8 0.0) MODEL #:k 3)))
  (check-exn #rx"no direction"
             (lambda () (chunks-nearest conn p (vector 1.0 +nan.0 0.0 0.0 0.0 0.0 0.0 0.0)
                                        MODEL #:k 3)))
  (close-db! conn))

;; ---- 10. truncated, both ways --------------------------------------------------
(test-case "truncated reports the window filling AND the headroom running out"
  ;; CLS-27's rule: a flag that is only ever true one way tells an operator
  ;; nothing. The two stopping conditions have different remedies — the first is
  ;; "this team is past the scale this design says to revisit at", the second is
  ;; "ask for fewer, or you may not read what is nearest".
  (define conn (fresh))
  (define-values (uid tid) (bootstrap! conn #:username "alice"))
  (define pa (user-principal conn uid tid))
  (define-values (o cs) (seed-doc conn pa))
  ;; (a) the window filled: there are chunks that were never compared
  (define filled (chunks-nearest conn pa (fake-embedding 2.0) MODEL #:k 1 #:scan 1))
  (check-equal? (hash-ref filled 'scanned) 1)
  (check-true (hash-ref filled 'truncated) "a filled window must say so")
  ;; …and it is NOT reported when the window had room to spare
  (define roomy (chunks-nearest conn pa (fake-embedding 2.0) MODEL #:k 1 #:scan 1000))
  (check-false (hash-ref roomy 'truncated))
  ;; (b) the headroom ran out: every candidate was weighed and `can?` left fewer
  ;; than were asked for, so readable chunks may sit below it
  (define bob (create-user! conn #:username "bob" #:password "pw"))
  (add-member! conn #:team tid #:user bob #:role "member")
  (define pb (user-principal conn bob tid))
  (query-exec conn "UPDATE repo_objects SET visibility = 'private' WHERE id = ?" (hash-ref o 'id))
  (define starved (chunks-nearest conn pb (fake-embedding 2.0) MODEL #:k 2 #:scan 1000))
  (check-equal? (hash-ref starved 'hits) '())
  (check > (hash-ref starved 'withheld) 0)
  (check-true (hash-ref starved 'truncated)
              "the headroom was exhausted with fewer hits than asked for and the report denied it")
  ;; and an honestly-empty corpus is NOT truncated — nothing was withheld
  (define empty (chunks-nearest conn pa (fake-embedding 2.0) "no-such-model" #:k 2))
  (check-equal? (hash-ref empty 'hits) '())
  (check-false (hash-ref empty 'truncated)
               "an empty answer with nothing withheld must not read as truncated")
  (close-db! conn))

;; ---- 11. the sealed column, on the read path -----------------------------------
(test-case "the read unseals, so a sealed instance ranks identically to a plain one"
  ;; the unseal is unconditional (ENC's rule: a row sealed while the switch was on
  ;; must open after it is off), so the interesting assertion is that the SCORES
  ;; are the same — a read that silently failed to unseal would not raise, it would
  ;; compare ciphertext and rank nonsense.
  (define conn (fresh))
  (define-values (uid tid) (bootstrap! conn #:username "alice"))
  (define p (user-principal conn uid tid))
  (with-env* (list (cons KEY-VAR KEY) (cons CONTENT-VAR "1"))
    (lambda ()
      (define-values (o cs) (seed-doc conn p))
      ;; the column really is sealed
      (define raw (query-value conn "SELECT vector FROM repo_chunks LIMIT 1"))
      (check-true (wrapped-bytes? raw) "the fixture did not seal the column")
      (define rep (chunks-nearest conn p (fake-embedding 2.0) MODEL #:k 2))
      (check-equal? (hash-ref (car (hash-ref rep 'hits)) 'index) 2)
      (check-= (hash-ref (car (hash-ref rep 'hits)) 'score) 1.0 1e-5)
      (check-equal? (hash-ref rep 'skipped) 0)))
  (close-db! conn))

;; ---- 12. the permission --------------------------------------------------------
(test-case "the read requires files:read, before any row is touched"
  (define conn (fresh))
  (define-values (uid tid) (bootstrap! conn #:username "alice"))
  (define p (user-principal conn uid tid))
  (define-values (o cs) (seed-doc conn p))
  ;; a principal acting for a team they hold no role in has no permissions at all
  (define other (create-team! conn #:name "Other" #:slug "other2"))
  (define dave (create-user! conn #:username "dave" #:password "pw"))
  (define pd (user-principal conn dave other))
  (check-exn #rx"files:read"
             (lambda () (chunks-nearest conn pd (fake-embedding 2.0) MODEL #:k 3)))
  (close-db! conn))

;; ---- 13. k ---------------------------------------------------------------------
(test-case "k bounds the hits and is validated"
  (define conn (fresh))
  (define-values (uid tid) (bootstrap! conn #:username "alice"))
  (define p (user-principal conn uid tid))
  (define-values (o cs) (seed-doc conn p))
  (check-equal? (length (hash-ref (chunks-nearest conn p (fake-embedding 0.0) MODEL #:k 1) 'hits)) 1)
  (check-equal? (length (hash-ref (chunks-nearest conn p (fake-embedding 0.0) MODEL #:k 2) 'hits)) 2)
  ;; asking for more than exist answers what exists, and is not truncated
  (define all (chunks-nearest conn p (fake-embedding 0.0) MODEL #:k 500))
  (check-equal? (length (hash-ref all 'hits)) (length cs))
  (check-false (hash-ref all 'truncated))
  (check-exn #rx"positive integer"
             (lambda () (chunks-nearest conn p (fake-embedding 0.0) MODEL #:k 0)))
  (close-db! conn))

;; ---- 14. which chunks a cut keeps ----------------------------------------------
(test-case "a window that has to cut keeps the newest document, and a PREFIX of it"
  ;; VEC-30, and this case exists because a positive control found that removing
  ;; the whole `ORDER BY` failed nothing: thirteen cases asked what a scan ANSWERS
  ;; and none asked which rows it looked at. Both halves matter and neither is
  ;; cosmetic — the stale half is the recall decision, and the prefix half is
  ;; because every chunk of one write shares a `created_epoch`, so within a
  ;; document the tiebreak decides the entire cut.
  (define conn (fresh))
  (define-values (uid tid) (bootstrap! conn #:username "alice"))
  (define p (user-principal conn uid tid))
  (define-values (old-o old-cs) (seed-doc conn p #:key "notes/old.md"))
  (define-values (new-o new-cs) (seed-doc conn p #:key "notes/new.md"
                                          #:text (make-string 3200 #\y)))
  ;; age the first document's rows, which is the only way to break the tie between
  ;; two writes made in the same second
  (query-exec conn "UPDATE repo_chunks SET created_epoch = 1 WHERE object_id = ?"
              (hash-ref old-o 'id))
  ;; a window one chunk short of the newer document: every row compared is its own
  (define cut (chunks-nearest conn p (fake-embedding 0.0) MODEL
                              #:k 50 #:scan (sub1 (length new-cs))))
  (check-equal? (hash-ref cut 'scanned) (sub1 (length new-cs)))
  (check-true (hash-ref cut 'truncated))
  (for ([h (in-list (hash-ref cut 'hits))])
    (check-equal? (hash-ref h 'object_id) (hash-ref new-o 'id)
                  "the cut reached the STALER document's chunks"))
  ;; …and it is the newer document's PREFIX, not a scatter: indices 0..n-2
  (check-equal? (sort (for/list ([h (in-list (hash-ref cut 'hits))]) (hash-ref h 'index)) <)
                (for/list ([i (in-range (sub1 (length new-cs)))]) i)
                "the cut kept a random subset of the document rather than its prefix")
  (close-db! conn))
