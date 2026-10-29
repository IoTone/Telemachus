#lang racket/base

;; test/chunkstore-tests.rkt — #189 step 4: the chunk-vector table, the sealed
;; binary column, and the write path.
;;   raco test test/chunkstore-tests.rkt
;;
;; THE CENTRAL PROPERTY IS THE ROUND TRIP, because this is the FIRST binary
;; column in the schema. Everything else here — the AAD, the wholesale replace,
;; the version keying — has a precedent somewhere in this tree that can be read
;; across. "A packed float32 vector comes back out of the database byte-identical
;; and still a unit vector" has none: before this column the largest thing stored
;; as bytes anywhere was nothing at all, and the failure mode is not an exception
;; but a vector of plausible numbers that retrieves the wrong chunk for ever.
;;
;; `DATABASE_URL=postgres://… raco test test/chunkstore-tests.rkt` runs every one
;; of these against PostgreSQL, which is the half that matters most: the column is
;; `BLOB` on SQLite and `BYTEA` on PostgreSQL, and the round trip is the thing a
;; branch on a type name can get silently wrong.

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
         "../domain/ai/chunkstore.rkt")

(define BLOB-ROOT (make-temporary-file "telemachus-chunkstore-~a" 'directory))
(current-blob-root BLOB-ROOT)

(define (fresh)
  (define conn (fresh-db #:migrate? #f))
  (migrate! conn all-migrations)
  conn)

;; `content-encryption-tests`' shape: the NAME is an argument, so no `getenv`
;; here is spelled with a literal — ENVN-2's gate, which is what forbids a second
;; home for an operator variable's name.
(define KEY-VAR "TMACH_SECRET_KEY")
(define CONTENT-VAR "TMACH_ENCRYPT_CONTENT")

(define (with-env* pairs thunk)
  (define saved (for/list ([kv (in-list pairs)]) (cons (car kv) (getenv (car kv)))))
  (dynamic-wind
    (lambda () (for ([kv (in-list pairs)]) (putenv (car kv) (or (cdr kv) ""))))
    thunk
    (lambda () (for ([kv (in-list saved)]) (putenv (car kv) (or (cdr kv) ""))) (void))))

(define (with-key key content? thunk)
  (with-env* (list (cons KEY-VAR key) (cons CONTENT-VAR (and content? "1"))) thunk))

(define KEY (make-string 64 #\a))

;; a 768-component vector, as an embedder answers one: a Racket vector of reals.
;; The values are deliberately not round — a float32 store truncates, so a test
;; built on 0.5 and 0.25 would pass against a broken pack.
(define (fake-embedding seed [n 768])
  (for/vector ([i (in-range n)]) (sin (+ seed (* 0.001 i)))))

(define (chunks-of text) (let-values ([(cs _t) (chunk-text text)]) cs))

;; `flvector` has no `list->flvector`, which is the kind of thing a test finds
(define (->fl* v)
  (define out (make-flvector (vector-length v)))
  (for ([i (in-range (vector-length v))])
    (flvector-set! out i (real->double-flonum (vector-ref v i))))
  out)

;; ---- 1. the round trip ---------------------------------------------------------
(test-case "a stored vector comes back byte-identical, unit, and in chunk order"
  (define conn (fresh))
  (define cs (chunks-of (make-string 3000 #\x)))
  (check > (length cs) 1 "the fixture must produce several chunks to test the ordering")
  (define vs (for/list ([(c i) (in-indexed cs)]) (fake-embedding (* 1.0 i))))
  (define n (chunks-replace! conn "obj1" "ver1" "nomic-embed-text" cs vs))
  (check-equal? n (length cs))
  (define back (chunks-for conn "obj1" "ver1"))
  (check-equal? (length back) (length cs))
  ;; the order is `idx`, not insertion luck
  (check-equal? (for/list ([r (in-list back)]) (hash-ref r 'index))
                (for/list ([c (in-list cs)]) (hash-ref c 'index)))
  ;; the bytes are what `vec-pack` of the NORMALIZED vector is — the invariant the
  ;; read depends on (VEC-11: for unit vectors the cosine IS the inner product)
  (for ([r (in-list back)] [v (in-list vs)])
    (define want (vec-pack (vec-normalize (->fl* v))))
    (check-equal? (hash-ref r 'vector) want "the stored bytes are not the packed unit vector")
    (check-true (vec-unit? (vec-unpack (hash-ref r 'vector)))
                "a stored row must decode to a unit vector"))
  (close-db! conn))

(test-case "the offsets stored are the chunker's own, which are repo_text.spans' coordinates"
  (define conn (fresh))
  (define text (string-append (make-string 1500 #\a) ". " (make-string 1500 #\b)))
  (define cs (chunks-of text))
  (chunks-replace! conn "obj1" "ver1" "m" cs (for/list ([c cs]) (fake-embedding 1.0 8)))
  (define back (chunk-rows-for conn "obj1" "ver1"))
  ;; CHUNK-1 is the whole reason step 5 can cite a hit with no new code: the
  ;; offsets must survive the store unchanged, and each one must still name the
  ;; substring the chunker cut.
  (for ([r (in-list back)] [c (in-list cs)])
    (check-equal? (hash-ref r 'start) (hash-ref c 'start))
    (check-equal? (hash-ref r 'end) (hash-ref c 'end))
    (check-equal? (substring text (hash-ref r 'start) (hash-ref r 'end))
                  (hash-ref c 'text)
                  "a stored offset pair no longer names its own chunk"))
  (close-db! conn))

;; ---- 2. the seal, BOTH directions ---------------------------------------------
(test-case "with a key and the content switch on, the raw column is sealed bytes"
  (with-key KEY #t
    (lambda ()
      (define conn (fresh))
      (define cs (chunks-of "a short document about octopuses."))
      (chunks-replace! conn "obj1" "ver1" "m" cs (for/list ([c cs]) (fake-embedding 2.0 16)))
      (define raw (query-value conn "SELECT vector FROM repo_chunks WHERE object_id = ?" "obj1"))
      (check-true (bytes? raw) "the column must read back as bytes on this dialect")
      (check-true (wrapped-bytes? raw) "the vector is NOT sealed with a key and the switch on")
      ;; …and it still opens
      (check-true (vec-unit? (vec-unpack (hash-ref (car (chunks-for conn "obj1" "ver1")) 'vector))))
      (close-db! conn))))

(test-case "with a key and the content switch OFF it is NOT sealed — the gate is the switch"
  (with-key KEY #f
    (lambda ()
      (define conn (fresh))
      (define cs (chunks-of "a short document about octopuses."))
      (chunks-replace! conn "obj1" "ver1" "m" cs (for/list ([c cs]) (fake-embedding 2.0 16)))
      (define raw (query-value conn "SELECT vector FROM repo_chunks WHERE object_id = ?" "obj1"))
      ;; ENC-24 / VEC-3: a document vector is CONTENT, so it waits to be asked —
      ;; where a credential (ENC-23) seals on a key alone. Both directions are
      ;; pinned or the fix is indistinguishable from sealing everything.
      (check-false (wrapped-bytes? raw)
                   "a content column must not seal on a key alone — that is #:credential's rule")
      (check-true (vec-unit? (vec-unpack (hash-ref (car (chunks-for conn "obj1" "ver1")) 'vector))))
      (close-db! conn))))

(test-case "the AAD is the row's own id, built by hand"
  (with-key KEY #t
    (lambda ()
      (define conn (fresh))
      (define cs (chunks-of "octopuses are cephalopods."))
      (chunks-replace! conn "obj1" "ver1" "m" cs (for/list ([c cs]) (fake-embedding 3.0 16)))
      (define r (query-row conn "SELECT id, vector FROM repo_chunks WHERE object_id = ?" "obj1"))
      (define id (vector-ref r 0))
      (define raw (vector-ref r 1))
      ;; `sealed-column-tests`' case-2 rule: a test where BOTH sides are generated
      ;; can pass while both were changed together. The context string is spelled
      ;; here, by hand, as the compatibility surface it is.
      (define by-hand (secret-unwrap/bytes (string-append "repo_chunks.vector:" id) raw))
      (check-equal? by-hand (unseal-chunk-vector id raw))
      ;; …and a ciphertext moved to ANOTHER chunk's row does not open, which is
      ;; the entire purpose of binding it to the id
      (check-exn exn:fail?
                 (lambda () (secret-unwrap/bytes "repo_chunks.vector:somebody-else" raw))
                 "a sealed vector opened under another row's AAD")
      (close-db! conn))))

;; ---- 3. the write's own rules --------------------------------------------------
(test-case "a set is replaced WHOLESALE — a shorter re-write leaves no stragglers"
  (define conn (fresh))
  (define long (chunks-of (make-string 4000 #\x)))
  (chunks-replace! conn "obj1" "ver1" "m" long (for/list ([c long]) (fake-embedding 1.0 8)))
  (check > (length long) 2)
  (define short (chunks-of "one little chunk."))
  (chunks-replace! conn "obj1" "ver1" "m" short (for/list ([c short]) (fake-embedding 1.0 8)))
  ;; VEC-21: the unit of correctness is "the vectors of this version". A set
  ;; written over a longer one must not leave chunk 3 of last week's text behind,
  ;; with a matching model and a matching width and offsets into a string that has
  ;; changed — nothing downstream could detect that.
  (check-equal? (length (chunk-rows-for conn "obj1" "ver1")) (length short))
  (check-equal? (query-value conn "SELECT COUNT(*) FROM repo_chunks WHERE object_id = ?" "obj1")
                (length short))
  (close-db! conn))

(test-case "a re-embed for a NEW version removes the old version's rows"
  (define conn (fresh))
  (define cs (chunks-of "octopuses are cephalopods."))
  (chunks-replace! conn "obj1" "verA" "m" cs (for/list ([c cs]) (fake-embedding 1.0 8)))
  (check-equal? (length (chunk-rows-for conn "obj1" "verA")) (length cs))
  (chunks-replace! conn "obj1" "verB" "m" cs (for/list ([c cs]) (fake-embedding 2.0 8)))
  (check-equal? (chunk-rows-for conn "obj1" "verA") '()
                "the superseded version's vectors are still stored")
  (check-equal? (length (chunk-rows-for conn "obj1" "verB")) (length cs))
  (close-db! conn))

(test-case "a vector with no direction is refused, not stored"
  (define conn (fresh))
  (define cs (chunks-of "octopuses are cephalopods."))
  ;; VEC-22. An embedder really does answer a zero vector for empty input, and a
  ;; stored zero would compare 0.0 against every query — the WORST match, which is
  ;; a claim where "this chunk could not be embedded" is the truth.
  (check-exn #rx"no direction"
             (lambda () (chunks-replace! conn "obj1" "ver1" "m" cs
                                         (list (make-vector 8 0.0)))))
  (check-equal? (query-value conn "SELECT COUNT(*) FROM repo_chunks") 0
                "a refused write left rows behind")
  (close-db! conn))

(test-case "the pairing must be exact, and two widths in one set is refused"
  (define conn (fresh))
  (define cs (chunks-of (make-string 3000 #\x)))
  (check > (length cs) 1)
  (check-exn #rx"vector"
             (lambda () (chunks-replace! conn "obj1" "ver1" "m" cs (list (fake-embedding 1.0 8))))
             "a short vector list was accepted — the pairing is the caller's and must be checked")
  (define two-widths
    (for/list ([(c i) (in-indexed cs)]) (fake-embedding 1.0 (if (zero? i) 8 16))))
  (check-exn #rx"widths"
             (lambda () (chunks-replace! conn "obj1" "ver1" "m" cs two-widths))
             "vectors of two widths in one document were accepted")
  (check-equal? (query-value conn "SELECT COUNT(*) FROM repo_chunks") 0)
  (close-db! conn))

(test-case "a failure DURING the inserts leaves the previous set intact"
  (define conn (fresh))
  (define cs (chunks-of (make-string 3000 #\x)))
  (check > (length cs) 1)
  (chunks-replace! conn "obj1" "ver1" "m" cs (for/list ([c cs]) (fake-embedding 1.0 8)))
  (define before (chunk-rows-for conn "obj1" "ver1"))
  ;; Two chunks claiming one `idx` — a caller bug, and the one failure that
  ;; happens AFTER the delete rather than before it, because `repo_chunks_chunk`
  ;; (VEC-19's natural key) refuses the second insert. It is what the transaction
  ;; is for: the validation above all runs before a row is touched, so the
  ;; validate-before-delete ORDER is what protects every other refusal here and
  ;; this is the only case that reaches the inserts at all.
  (define dup (list (hash-set (car cs) 'index 0) (hash-set (cadr cs) 'index 0)))
  (check-exn exn:fail?
             (lambda () (chunks-replace! conn "obj1" "ver1" "m" dup
                                         (list (fake-embedding 1.0 8) (fake-embedding 2.0 8)))))
  (check-equal? (chunk-rows-for conn "obj1" "ver1") before
                "a failure mid-insert left a MIXTURE — half this version's vectors and half the last")
  (close-db! conn))

(test-case "a refused write does not destroy the set that was already there"
  (define conn (fresh))
  (define cs (chunks-of "octopuses are cephalopods."))
  (chunks-replace! conn "obj1" "ver1" "m" cs (for/list ([c cs]) (fake-embedding 1.0 8)))
  (define before (chunk-rows-for conn "obj1" "ver1"))
  (check-exn exn:fail? (lambda () (chunks-replace! conn "obj1" "ver1" "m" cs
                                                   (list (make-vector 8 0.0)))))
  ;; WHAT PROTECTS THIS CASE IS THE ORDER, NOT THE TRANSACTION, and a positive
  ;; control is what established the difference: every validation in
  ;; `chunks-replace!` runs before the DELETE, so with the transaction removed
  ;; this still passed. The case above is the one that reaches the inserts.
  (check-equal? (chunk-rows-for conn "obj1" "ver1") before
                "a failed replace destroyed the previous set")
  (close-db! conn))

;; ---- 4. what the store can answer ---------------------------------------------
(test-case "the model a version's vectors are of, and nothing when there are none"
  (define conn (fresh))
  (check-false (chunks-model-for conn "obj1" "ver1"))
  (define cs (chunks-of "octopuses."))
  (chunks-replace! conn "obj1" "ver1" "nomic-embed-text" cs (list (fake-embedding 1.0 8)))
  ;; EMB-8: vectors from two checkpoints are not comparable and mixing them does
  ;; not raise. The column is how a read filters them out in SQL.
  (check-equal? (chunks-model-for conn "obj1" "ver1") "nomic-embed-text")
  (close-db! conn))

(test-case "the team's chunk count is team-scoped and ignores a deleted document"
  (define conn (fresh))
  (define-values (uid tid) (bootstrap! conn #:username "alice"))
  (define p (user-principal conn uid tid))
  (define o (repo-put! conn p #:key "notes/a.md" #:port (open-input-bytes #"octopuses")
                       #:content-type "text/markdown" #:filename "a.md" #:visibility "team"))
  (define cs (chunks-of "octopuses are cephalopods."))
  (chunks-replace! conn (hash-ref o 'id) (hash-ref o 'version_id) "m" cs
                   (for/list ([c cs]) (fake-embedding 1.0 8)))
  (check-equal? (chunks-count conn tid) (length cs))
  (check-equal? (chunks-count conn "some-other-team") 0 "the count is not team-scoped")
  ;; `vector-store.md`'s revisit threshold is per TEAM, so the number an operator
  ;; reads has to mean "this team's live documents" — a deleted document's rows are
  ;; cleared by `repo-delete!` and would otherwise still be counted toward it.
  (repo-delete! conn p (hash-ref o 'id))
  (check-equal? (chunks-count conn tid) 0)
  (check-equal? (query-value conn "SELECT COUNT(*) FROM repo_chunks") 0
                "deleting a document left its chunk vectors behind")
  (close-db! conn))

(test-case "wrapped-bytes-key-id names the key that sealed a row, and #f for a plain one"
  ;; the accessor exists for `telemachus-secrets rewrap`, whose idempotence on a
  ;; binary column cannot be a text prefix test. Without it the CLI re-seals every
  ;; vector on every run and "rewrapped 0 secret(s)" becomes unreachable.
  (with-key KEY #t
    (lambda ()
      (define sealed (secret-wrap/bytes "repo_chunks.vector:x" (bytes 0 1 2 255)))
      (check-equal? (wrapped-bytes-key-id sealed) (secret-key-id))
      (check-false (wrapped-bytes-key-id (bytes 0 1 2 255)))))
  (void))
