#lang racket/base

;; domain/ai/chunksearch.rkt — the nearest-chunk read (#189 step 5, decisions
;; VEC‑26…32).
;;
;; `docs/design/vector-store.md`'s build plan, step 5 verbatim: "a nearest-chunk
;; query, team-scoped in SQL, `can?` per row after the scan, returning the
;; chunk's offsets so the caller can cite it." Everything it needs has been on
;; disk since step 4 — `vec-nearest` and the stored form (step 1), the sealed
;; column and its unseal (step 4), and `spans-covering` for the citation
;; (CHUNK‑1) — so this module composes and decides and computes no arithmetic of
;; its own.
;;
;; IT IS A SEPARATE MODULE FROM `chunkstore.rkt` BECAUSE OF WHAT THAT ONE
;; PROMISES. Its header says it is handed a connection and an object id and is
;; never handed a principal, which is VEC‑17's rule and the blob store's — a
;; layer with no authorization cannot get it wrong. This read is the opposite
;; kind of thing: `can?` is the whole of its difficulty, so putting it beside the
;; write would make that promise false for the module as a whole.
;;
;; NOTHING CALLS IT YET. Step 6 is the retrieval tool and `?semantic=` on search,
;; where #183 and #191 pick it up; #110 r4's rule is that an export in `domain/`
;; with no consumer is a claim the next reader must assume is load-bearing, and
;; its stated exception is an export with a test behind it. This has one.
;;
;; VEC‑32 — WHAT A HIT DELIBERATELY DOES NOT CARRY IS THE CHUNK'S TEXT. The store holds
;; offsets and a vector and no text at all (VEC‑21's row), so text means reading
;; `repo_text` and taking a substring — which is the retrieval TOOL's job, needs
;; `repo-text-for`, and belongs where the model-facing result is composed. A hit
;; carries where to read, which is what makes it citable.

(require db-kit/portable racket/flonum
         (only-in "../authz/authz.rkt" require-perm principal-team-id)
         (only-in "../repo/repo.rkt" repo-readable?)
         (only-in "vectors.rkt" vec-normalize vec-nearest)
         (only-in "chunkstore.rkt" unseal-chunk-vector))

(provide chunks-nearest NEAREST-SCAN NEAREST-K AUTHZ-HEADROOM)

;; ---- the two bounds ----------------------------------------------------------
;;
;; VEC‑26 — THE WINDOW CAP AND THE REVISIT THRESHOLD ARE THE SAME NUMBER, ON
;; PURPOSE. `vector-store.md`'s "When to revisit" says to look again "when a
;; single team's chunk count passes 50,000", and the measured scan at that scale
;; is ~390 ms of arithmetic. So a team whose window TRUNCATES is a team that has
;; already crossed the line where this design says to reconsider the whole
;; approach — which makes `truncated` the signal to revisit rather than a routine
;; condition to be tuned around. A cap chosen independently of that threshold
;; would have been a second number saying the same thing, and they would drift.
(define NEAREST-SCAN 50000)

(define NEAREST-K 10)

;; VEC‑28 — HOW MANY CANDIDATES ARE SCORED PER HIT ASKED FOR, and this is the one
;; approximation in the module. See `chunks-nearest` for why it exists at all.
(define AUTHZ-HEADROOM 4)

;; ---- the read ----------------------------------------------------------------
;;
;; VEC‑27 — THE WINDOW JOINS `o.current_version_id`, WHICH IS WHAT MAKES A
;; SUPERSEDED VERSION'S VECTORS UNREACHABLE RATHER THAN MERELY STALE (VEC‑18),
;; and it filters `c.model` IN SQL (VEC‑20/EMB‑8): vectors from two checkpoints
;; are not comparable, and a dot product between two unrelated coordinate systems
;; is a NUMBER, so mixing them answers confidently and nobody can tell. Filtering
;; in Racket instead would be correct and would decode every foreign row to throw
;; it away.
;;
;; VEC‑30 — THE ORDER IS `created_epoch DESC`, SO A WINDOW THAT HAS TO CUT CUTS
;; THE STALEST, AND CUTS A DOCUMENT'S TAIL RATHER THAN A RANDOM SUBSET OF IT.
;; A bare `LIMIT` with no `ORDER BY` is an arbitrary, engine-dependent cut, which
;; is a recall problem that cannot be reproduced; and the clock is a portable
;; epoch integer rather than `repo_objects.updated_at`, which is TEXT
;; `CURRENT_TIMESTAMP` and differs by dialect — the trap migrations 0038…0041
;; each name.
;;
;; THE TIEBREAK IS `object_id, idx` AND THAT IS NOT COSMETIC. Every chunk of one
;; `chunks-replace!` is stamped with the same `current-seconds`, so within a
;; document `created_epoch` ties for ALL of them and the tiebreak decides the
;; whole cut. Breaking it on `c.id` — the obvious choice, and what this was
;; first written as — orders by `chk_<ms>_<random>`, so a truncated window takes
;; a scatter of a document's chunks; on `idx` it takes a PREFIX, which is both
;; reproducible and the half of a document a reader is likelier to be asking
;; about.
;;
;; HOW FAR THE TEST GOES, AND IT IS NOT ALL THE WAY. `created_epoch DESC` is
;; established: removing it fails `chunksearch-tests`' last case on BOTH dialects,
;; and the case exists because the first thirteen all asked what a scan ANSWERS
;; and none asked which rows it looked at. Removing the whole `ORDER BY` fails
;; NOTHING — four runs on SQLite and three on PostgreSQL — because for that
;; fixture both planners happen to return the newer document's rows first. That is
;; exactly the reason to write the key down rather than a reason the key is
;; redundant: an order that holds because two query planners agree today is
;; VEC‑13's unpinnable pin, where the test can catch the key being INVERTED and
;; cannot catch it being absent. The `idx` half is weaker still: `chk_<ms>_…` is
;; near-monotonic within one write, so `c.id` is accidentally almost a prefix
;; order and substituting it fails nothing either. Stated here because the next
;; reader will run that control and should know it was run.
;;
;; Answers ONE hash rather than several values, because `(void (f …))` on a
;; multi-value function is an arity error and this file's own neighbours have
;; cost four runs to that shape (`vec-nearest` is the most recent).
(define (chunks-nearest conn p query model
                        #:k [k NEAREST-K]
                        #:scan [scan NEAREST-SCAN])
  (require-perm conn p "files:read")
  (unless (exact-positive-integer? k)
    (error 'chunks-nearest "k must be a positive integer, given ~e" k))
  ;; VEC‑31 — THE QUERY IS NORMALIZED HERE AND A DIRECTIONLESS ONE IS REFUSED.
  ;; `vec-dot` is only a similarity when BOTH sides are unit (VEC‑12); the stored
  ;; side is unit by the write's own invariant (VEC‑22), so the query is the half
  ;; left to establish. A zero or NaN vector answers #f from `vec-normalize`, and
  ;; scoring it would compare 0.0 against everything and report the whole corpus
  ;; as equally bad — a claim, where the honest answer is that the question had
  ;; no direction. An embedder really does answer one for empty input.
  (define q (vec-normalize (->flvector query)))
  (unless q
    (error 'chunks-nearest
           (string-append "the query embedded to a vector with no direction (all zeros, or a "
                          "NaN component) — an embedder answers one for empty input, so the "
                          "query text is the thing to look at")))
  (define rows
    (query-rows conn
      (string-append
       "SELECT c.id, c.object_id, c.version_id, c.idx, c.start_off, c.end_off, o.key, c.vector "
       "FROM repo_chunks c "
       "JOIN repo_objects o ON o.id = c.object_id AND o.current_version_id = c.version_id "
       "WHERE o.team_id = ? AND o.deleted_at IS NULL AND c.model = ? "
       "ORDER BY c.created_epoch DESC, c.object_id ASC, c.idx ASC LIMIT ?")
      (principal-team-id p) model scan))
  ;; `vec-nearest` is handed (key . bytes) and knows nothing about who asked
  ;; (VEC‑17). The key is the whole row, so the winners carry their offsets with
  ;; them and nothing has to be looked up again.
  (define-values (scored skipped)
    (vec-nearest q
                 (for/list ([r (in-list rows)])
                   (cons r (unseal-chunk-vector (vector-ref r 0) (vector-ref r 7))))
                 (* k AUTHZ-HEADROOM)))
  ;; VEC‑28 — `can?` PER ROW AFTER THE SCAN, IN SCORE ORDER, MEMOIZED BY OBJECT.
  ;;
  ;; The memo is what makes this affordable rather than clever: a document is many
  ;; chunks, so the number of `repo-readable?` calls is the number of distinct
  ;; DOCUMENTS among the candidates and not the number of candidates — an ordinary
  ;; business document is ~9 chunks, so 40 candidates is nearer 5 queries than 40.
  ;;
  ;; AND THE HEADROOM IS WHY THIS IS AN APPROXIMATION, which is worth stating
  ;; plainly because the exact version is reachable and was measured against.
  ;; Taking exactly `k` from the scan and then filtering has a real recall hole:
  ;; if the top ten chunks all belong to a colleague's PRIVATE document the query
  ;; answers nothing, while readable chunk eleven was a good match — which is the
  ;; shape step 4 just found in `repo_list_unindexed`, where a window selected by
  ;; `team_id` alone handed out what the next step could not read. The exact fix
  ;; is to authorize every row in the window BEFORE the arithmetic, and that costs
  ;; one `repo-readable?` per distinct document in the team: at ten thousand
  ;; documents it is ten thousand queries on a query path, which is seconds. So
  ;; the scan keeps `k × AUTHZ-HEADROOM` candidates and the hole is pushed out
  ;; four-fold rather than closed, and when the headroom is exhausted with fewer
  ;; than `k` survivors the report SAYS SO instead of implying there was nothing
  ;; more — `truncated`'s second meaning, CLS‑27's rule that a flag which is only
  ;; ever true one way tells an operator nothing.
  (define readable (make-hash))
  (define (ok? object-id)
    (hash-ref! readable object-id (lambda () (repo-readable? conn p object-id))))
  (let loop ([cand scored] [hits '()] [n 0] [withheld 0])
    (cond
      [(or (null? cand) (>= n k))
       (hasheq 'hits (reverse hits)
               'scanned (length rows)
               'skipped skipped
               'withheld withheld
               ;; VEC‑29 — BOTH WAYS OF STOPPING: the window filled, so chunks
               ;; exist that were never compared; or every candidate was weighed
               ;; and `can?` left fewer than were asked for, so readable chunks
               ;; may sit below the headroom. A flag that is only ever true one
               ;; way tells an operator nothing (CLS‑27), and the two have
               ;; different remedies.
               'truncated (or (>= (length rows) scan)
                              (and (null? cand) (< n k) (> withheld 0))))]
      [else
       (define r (car (car cand)))
       (define score (cdr (car cand)))
       (define object-id (vector-ref r 1))
       (cond
         [(ok? object-id)
          (loop (cdr cand)
                (cons (hasheq 'chunk_id (vector-ref r 0)
                              'object_id object-id
                              'version_id (vector-ref r 2)
                              'key (vector-ref r 6)
                              'index (vector-ref r 3)
                              'start (vector-ref r 4)
                              'end (vector-ref r 5)
                              'model model
                              'score score)
                      hits)
                (add1 n) withheld)]
         [else (loop (cdr cand) hits n (add1 withheld))])])))

;; The caller's query arrives as whatever `embedding-vectors` produced — a Racket
;; `vector` of reals — and the arithmetic wants an `flvector`. `flvector` has no
;; `list->flvector`, which cost a compile in step 4.
(define (->flvector v)
  (cond
    [(flvector? v) v]
    [(vector? v)
     (define n (vector-length v))
     (define out (make-flvector n))
     (for ([i (in-range n)]) (flvector-set! out i (real->double-flonum (vector-ref v i))))
     out]
    [(list? v) (->flvector (list->vector v))]
    [else (error 'chunks-nearest "not a vector of numbers: ~e" v)]))
