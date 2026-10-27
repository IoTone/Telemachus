#lang racket/base

;; domain/audit/anchor.rkt — issue #66: an EXTERNAL anchor for the two hash
;; chains. Decisions ANCHOR-1…10 in docs/design/decisions.md.
;;
;; LAY-11 chains each review decision per team; AUD-10…16 chains each audit entry
;; per org. Both detect a row altered in place, a row removed from the middle and
;; a rewritten link, and NEITHER detects a rewrite by anyone who can WRITE the
;; table — they recompute every link after the row they changed. That is the
;; party an audit is most meant to defend against, which is why both modules stop
;; their claim there and point here.
;;
;; WHAT THIS IS: the platform EMITS a signed receipt; it never CALLS a notary
;; (ANCHOR-1). A timestamping authority would be a network dependency and a
;; disclosure, on a platform that is self-hosted, privacy-first and has to work
;; air-gapped — and it would be one mechanism per remote in the core. So the
;; artifact is produced here and WHERE IT IS RETAINED IS THE DEPLOYMENT'S
;; DECISION: a second instance, a git repository, a bucket in another account, a
;; mail archive, paper in a safe. That choice is the operator's, and issue #66
;; says it is the whole feature.
;;
;; THE TABLE IS NOT THE ANCHOR. `anchor_receipts` is in the same database as the
;; chains it measures, so whoever can rewrite those can delete from it too. It
;; exists so the sequence can be continued and so an operator can fetch what they
;; have not yet retained. The anchor is the copy somebody else is holding — and
;; nothing here can verify that somebody else kept it, which is why the read
;; reports what was EMITTED and never claims anything was retained.
;;
;; WHY THE SERIES IS ITSELF CHAINED (ANCHOR-3). Without it the feature is
;; defeated by not publishing: a writer who controls delivery stops emitting, and
;; a missing receipt is indistinguishable from a quiet instance. A strictly
;; increasing `seq` plus each receipt naming its predecessor's hash makes a GAP
;; visible without the server, and makes a reused seq carrying different heads —
;; what deleting rows here and re-emitting looks like — visible too. This is the
;; property the audit export, the nearest thing that already existed, lacks.
;;
;; WHAT IT DETECTS, AND WHAT IT DOES NOT. It detects a rewrite of either chain
;; after a receipt was retained, and suppression of receipts. It does NOT detect a
;; rewrite before the first receipt, or inside the window since the last one — the
;; anchor's resolution is its cadence. It does nothing at all if the retained copy
;; was never collected. And a HOST compromise still forges FUTURE receipts, since
;; the signing key is on the host; it cannot forge the ones already in somebody
;; else's hands. #19's DUMP-not-HOST line, one layer up.

(require db-kit/portable json racket/string
         (only-in sha2-kit sha256-hex)
         (only-in "../db/id.rkt" new-id uuid4)
         (only-in "../authz/authz.rkt" audit!)
         (only-in "../authz/signing.rkt"
                  anchor-key-seed anchor-signing-enabled? ed25519-public-key
                  ed25519-sign ed25519-verify? bytes->hex hex->bytes)
         (only-in "../settings/settings.rkt" setting-ref setting-set!)
         (only-in "./chain.rkt" audit-chain-heads)
         (only-in "../review/review.rkt" review-chain-heads))

(provide anchor-emit! anchor-receipts anchor-receipt-count anchor-status
         anchor-export-jsonl anchor-verify-series anchor-public-key-hex
         ANCHOR-VERSION)

(define ANCHOR-VERSION "telemachus.anchor.v1")

;; The instance's own name for its receipt series. It NAMES the series rather than
;; authenticating it — seq and prev_hash are what make a receipt hard to replay —
;; so a UUID minted once is enough, and it makes a retained artifact
;; self-describing when somebody is holding receipts from two instances.
(define (instance-id conn)
  (define doc (setting-ref conn "anchor-instance" #f))
  (cond
    [(and (hash? doc) (string? (hash-ref doc 'id #f))) (hash-ref doc 'id)]
    [else (hash-ref (setting-set! conn "anchor-instance" (hasheq 'id (uuid4))) 'id)]))

(define (anchor-public-key-hex)
  (define seed (anchor-key-seed))
  (and seed (bytes->hex (ed25519-public-key seed))))

;; ---- the signed payload (ANCHOR-10) -------------------------------------------
;; An ordered LIST, never a hash. `hasheq` iteration order is not stable across
;; processes, so a digest over a hash would disagree with itself on another
;; machine — the trap the docs generator's `json-out` sorts for, JUDGE-13's wire
;; refuses re-serialization for, and both existing chains are lists for.
;;
;; A field not in here could be changed without breaking the signature, so this
;; list IS the statement of what is protected. Adding one means bumping
;; ANCHOR-VERSION, which starts a new series rather than silently protecting less.
;;
;; Each chain row is a list too, in a fixed field order, for the same reason.
(define (chain-row->list r)
  (list (hash-ref r 'chain)
        (hash-ref r 'scope)
        (let ([h (hash-ref r 'head)]) (if (string? h) h ""))
        (hash-ref r 'entries)))

(define (receipt-payload iid seq prev emitted pubkey rows)
  (jsexpr->string
   (list ANCHOR-VERSION iid seq (or prev "") emitted pubkey
         (map chain-row->list rows))))

;; ---- emitting -----------------------------------------------------------------

(define (newest conn)
  (query-maybe-row conn
    "SELECT seq, hash FROM anchor_receipts ORDER BY seq DESC LIMIT 1"))

;; Take a measurement of both chains, sign it, record it. -> the receipt.
;;
;; The chain heads are read through `audit-chain-heads`, which SEALS FIRST
;; (ANCHOR-8): this chain is sealed by a sweep, so a head read mid-window is a
;; value the next sweep legitimately changes, and a receipt naming one would make
;; an honest instance fail its own later verification.
;;
;; TWO CONCURRENT EMISSIONS: the unique index on `seq` refuses the second, and
;; that is deliberate rather than retried. A forked sequence is the one thing this
;; design must not produce — the retainer could not tell a fork from a forgery —
;; and an emission is a daily sweep plus an occasional operator request, so losing
;; the race costs nothing and the next tick emits.
(define (anchor-emit! conn #:actor-id [actor-id #f] #:team-id [team-id #f])
  (define seed (anchor-key-seed))
  (unless seed
    (raise-user-error
     'anchor
     (string-append "no anchor key is configured, so a receipt cannot be signed. "
                    "Generate one with `racket cli/telemachus-anchor.rkt keygen` and set "
                    "TMACH_ANCHOR_KEY.")))
  (define pubkey (bytes->hex (ed25519-public-key seed)))
  (define iid (instance-id conn))
  (define rows (append (audit-chain-heads conn) (review-chain-heads conn)))
  (define prev-row (newest conn))
  (define prev-seq (if prev-row (vector-ref prev-row 0) 0))
  (define prev-hash (and prev-row (let ([h (vector-ref prev-row 1)])
                                    (and (not (sql-null? h)) h))))
  (define seq (add1 prev-seq))
  (define emitted (current-seconds))
  (define payload (receipt-payload iid seq prev-hash emitted pubkey rows))
  (define hash (sha256-hex (string->bytes/utf-8 payload)))
  (define sig (bytes->hex (ed25519-sign seed (string->bytes/utf-8 payload))))
  (define id (new-id))
  (query-exec conn
    (string-append "INSERT INTO anchor_receipts "
                   "(id, seq, prev_hash, hash, payload, signature, public_key, instance_id, "
                   " emitted_epoch, chains, created_by) "
                   "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)")
    id seq (or prev-hash sql-null) hash payload sig pubkey iid emitted (length rows)
    (or actor-id sql-null))
  ;; Taking a measurement of the log and sending it off the box is exactly the
  ;; event a later reader wants to find — `audit.exported` audits itself for the
  ;; same reason. The meta carries the sequence and the hash and no head: a head
  ;; is already in the receipt, and a copy here would be a second place to keep
  ;; it consistent.
  ;; sql-null, NOT 'null: `audit!` applies its 'null coercion to only four of
  ;; its eleven keywords (org-id, ip, user-agent, request-id), so 'null for
  ;; actor-id or team-id reaches the driver raw and fails with "cannot convert
  ;; given value to SQL type". A third variant of the audit! keyword trap, after
  ;; the missing #:team-id and #:resource-type-vs-#:target-*.
  (audit! conn #:action "anchor.emitted"
          #:actor-type (if actor-id "user" "system")
          #:actor-id (or actor-id sql-null)
          #:team-id (or team-id sql-null)
          #:resource-type "anchor_receipt" #:resource-id id
          #:result "ok"
          #:meta (jsexpr->string (hasheq 'seq seq 'hash hash 'chains (length rows))))
  (row->receipt
   (vector id seq (or prev-hash sql-null) hash payload sig pubkey iid emitted (length rows)
           (or actor-id sql-null))))

;; ---- reading ------------------------------------------------------------------

(define RSELECT
  (string-append "SELECT id, seq, prev_hash, hash, payload, signature, public_key, "
                 "instance_id, emitted_epoch, chains, created_by FROM anchor_receipts "))

(define (nzs v) (if (sql-null? v) 'null v))

(define (row->receipt r)
  (hasheq 'id (vector-ref r 0)
          'seq (vector-ref r 1)
          'prev_hash (nzs (vector-ref r 2))
          'hash (vector-ref r 3)
          ;; the exact bytes that were signed, carried VERBATIM. Parsing and
          ;; re-emitting would reorder nothing here (it is an array) but would
          ;; still re-encode numbers and escapes, and the signature covers the
          ;; stored bytes — so a re-serialized copy would not verify.
          'payload (vector-ref r 4)
          'signature (vector-ref r 5)
          'public_key (vector-ref r 6)
          'instance_id (vector-ref r 7)
          'emitted_epoch (vector-ref r 8)
          'chains (vector-ref r 9)
          'created_by (nzs (vector-ref r 10))))

(define (anchor-receipts conn #:limit [lim 100] #:since-seq [since #f])
  (define rows
    (if since
        (query-rows conn (string-append RSELECT "WHERE seq > ? ORDER BY seq ASC LIMIT ?") since lim)
        (query-rows conn (string-append RSELECT "ORDER BY seq DESC LIMIT ?") lim)))
  (map row->receipt rows))

(define (anchor-receipt-count conn)
  (query-value conn "SELECT COUNT(*) FROM anchor_receipts"))

;; What an operator can see from the box: whether anchoring is on, how far the
;; series has got, and when it last ran. It deliberately says nothing about
;; whether anything was RETAINED — the platform cannot know that, and a field
;; implying it is worse than no field (PULL-11e's rule about a withdrawn state).
(define (anchor-status conn)
  (define r (newest conn))
  (hasheq 'enabled (anchor-signing-enabled?)
          'public_key (or (anchor-public-key-hex) 'null)
          'instance_id (let ([doc (setting-ref conn "anchor-instance" #f)])
                         (if (and (hash? doc) (string? (hash-ref doc 'id #f)))
                             (hash-ref doc 'id) 'null))
          'receipts (anchor-receipt-count conn)
          'latest_seq (if r (vector-ref r 0) 'null)
          'latest_hash (if r (vector-ref r 1) 'null)
          'anchor_version ANCHOR-VERSION))

;; JSONL, newest LAST, so a retention system appends and the file reads in
;; sequence order — the shape `audit-export-jsonl` chose, for the same reason.
(define (anchor-export-jsonl conn out #:since-seq [since #f] #:limit [lim 10000])
  (define rows
    (if since
        (query-rows conn (string-append RSELECT "WHERE seq > ? ORDER BY seq ASC LIMIT ?") since lim)
        (query-rows conn (string-append RSELECT "ORDER BY seq ASC LIMIT ?") lim)))
  (for ([r (in-list rows)])
    (write-json (row->receipt r) out)
    (newline out))
  (length rows))

;; ---- verifying a retained series (ANCHOR-5/-6) ---------------------------------
;; Takes the receipts as jsexprs — from a retained FILE, with no database and no
;; server anywhere near it. That is the whole point: a verifier that asks the
;; instance whether the instance is honest is not a verifier.
;;
;; `expected-pubkey-hex` is what separates `self_consistent` from `verified`
;; (ANCHOR-6). A public key taken from the file it is being used to check proves
;; nothing — a forger supplies both — so without an expected key this reports
;; what it could check and declines to say "verified". Saying what was NOT checked
;; is the honest failure; implying a check that could not happen is not.
(define (anchor-verify-series receipts #:public-key [expected-pubkey-hex #f])
  (define expected (and expected-pubkey-hex
                        (with-handlers ([exn:fail? (lambda (_) #f)])
                          (hex->bytes (string-trim expected-pubkey-hex)))))
  ;; Every key the OK branch reports, so a caller can print one shape whichever
  ;; way the answer went — the CLI printed `last_seq` unconditionally and a
  ;; failure turned into `hash-ref: no value found for key`, i.e. a verdict
  ;; became a stack trace. The smoke found it; the unit tests had only ever
  ;; read `ok`, `broken_at` and `problem`.
  (define (fail seq problem [extra (hasheq)])
    (hash-union* (hasheq 'ok #f 'checked 0 'broken_at (or seq 'null) 'problem problem
                         'verified #f 'self_consistent #f
                         'signed_by 'null 'instance_id 'null
                         'first_seq 'null 'last_seq 'null 'complete #f)
                 extra))
  (cond
    [(and expected-pubkey-hex (not expected))
     (fail #f "the expected public key is not hex")]
    [(null? receipts) (hasheq 'ok #t 'checked 0 'broken_at 'null 'problem 'null
                              'verified #f 'self_consistent #t 'complete #f
                              'signed_by 'null 'instance_id 'null
                              'first_seq 'null 'last_seq 'null
                              'note "no receipts: nothing was retained, which this cannot distinguish from an instance that never emitted")]
    [else
     ;; Asked of the FIRST retained receipt, before the walk: it reaches the
     ;; origin only if it is seq 1 and names no predecessor.
     (define complete?
       (let* ([f (car receipts)]
              [ph (hash-ref f 'prev_hash #f)])
         (and (equal? (hash-ref f 'seq #f) 1)
              (or (not ph) (eq? ph 'null) (sql-null? ph)))))
     (let loop ([rs receipts] [prev #f] [n 0] [signed-by #f] [iid #f] [first-seq #f])
       (cond
         [(null? rs)
          ;; COMPLETE means this file reaches the ORIGIN of the series: seq 1,
          ;; with no predecessor named. A file that starts at seq 7 is a valid
          ;; sub-chain — a retainer may legitimately have begun later — so the
          ;; verdict stays `ok`, but a first receipt whose `prev_hash` is NOT
          ;; null PROVES an earlier receipt existed, and this file does not have
          ;; it. That is evidence, so it is reported rather than discarded;
          ;; what it cannot say is WHICH of "retention began later" and "the
          ;; earlier ones were suppressed" happened, and it says that too.
          (hasheq 'ok #t 'checked n 'broken_at 'null 'problem 'null
                  'verified (and expected #t) 'self_consistent #t
                  'complete complete?
                  'signed_by (or signed-by 'null) 'instance_id (or iid 'null)
                  'first_seq (or first-seq 'null)
                  'last_seq (if prev (hash-ref prev 'seq) 'null)
                  'note (if complete? 'null
                            (format (string-append
                                     "this file starts at receipt ~a, which names a predecessor it does not contain: "
                                     "~a earlier receipt(s) are absent. Either retention began later, or they were "
                                     "suppressed — a retained file cannot tell those apart, and the instance's own "
                                     "answer is not evidence here.")
                                    (or first-seq "?")
                                    (if (exact-integer? first-seq) (sub1 first-seq) "some"))))]
         [else
          (define r (car rs))
          (define (g k) (hash-ref r k #f))
          (define payload (g 'payload))
          (define problem (receipt-problem r prev expected iid))
          (cond
            [problem (fail (or (g 'seq) 'null) problem
                           (hasheq 'checked n
                                   'signed_by (or signed-by 'null)
                                   'instance_id (or iid 'null)
                                   'first_seq (or first-seq 'null)))]
            [else
             (loop (cdr rs) r (add1 n)
                   (or signed-by (g 'public_key))
                   (or iid (parsed-field payload 1))
                   (or first-seq (g 'seq)))])]))]))

(define (hash-union* a b) (for/fold ([h a]) ([(k v) (in-hash b)]) (hash-set h k v)))

;; The payload is the authority for everything the signature covers, so each
;; field is read back OUT of it and compared with the row that carried it: a
;; receipt whose convenience columns disagree with its own signed bytes is
;; exactly what a hand-edited file looks like.
(define (parsed-field payload i)
  (with-handlers ([exn:fail? (lambda (_) #f)])
    (define j (string->jsexpr payload))
    (and (list? j) (> (length j) i) (list-ref j i))))

(define (receipt-problem r prev expected iid)
  (define (g k) (hash-ref r k #f))
  (define payload (g 'payload))
  (define seq (g 'seq))
  (define sig (g 'signature))
  (define pk (g 'public_key))
  (cond
    [(not (string? payload)) "a receipt has no payload"]
    [(not (exact-integer? seq)) "a receipt has no sequence number"]
    [(not (string? sig)) "a receipt has no signature"]
    [(not (string? pk)) "a receipt names no public key"]
    [(not (equal? (parsed-field payload 0) ANCHOR-VERSION))
     (format "receipt ~a was made by another anchor version" seq)]
    ;; the hash is a convenience column; the payload is what was signed
    [(and (string? (g 'hash))
          (not (equal? (g 'hash) (sha256-hex (string->bytes/utf-8 payload)))))
     (format "receipt ~a's hash does not match its own payload" seq)]
    [(not (equal? (parsed-field payload 2) seq))
     (format "receipt ~a's sequence disagrees with its signed payload" seq)]
    [(and (string? pk) (not (equal? (parsed-field payload 5) pk)))
     (format "receipt ~a's public key disagrees with its signed payload" seq)]
    ;; THE SIGNATURE. Checked against the EXPECTED key when one was supplied,
    ;; and otherwise against the key the receipt carries — which proves only
    ;; internal consistency, and is why `verified` stays false in that case.
    [(not (let ([key (or expected (with-handlers ([exn:fail? (lambda (_) #f)])
                                    (hex->bytes pk)))]
                [sigb (with-handlers ([exn:fail? (lambda (_) #f)]) (hex->bytes sig))])
            (and key sigb (ed25519-verify? key (string->bytes/utf-8 payload) sigb))))
     (if expected
         (format "receipt ~a is not signed by the expected key" seq)
         (format "receipt ~a's signature does not check against the key it carries" seq))]
    [(and iid (not (equal? (parsed-field payload 1) iid)))
     (format "receipt ~a belongs to a different instance's series" seq)]
    ;; ---- the series itself (ANCHOR-3) ----
    [(and prev (not (= seq (add1 (hash-ref prev 'seq)))))
     (format "the series jumps from ~a to ~a: ~a receipt(s) are missing or were suppressed"
             (hash-ref prev 'seq) seq (- seq (hash-ref prev 'seq) 1))]
    [(and prev (not (equal? (g 'prev_hash) (hash-ref prev 'hash))))
     (format "receipt ~a does not name receipt ~a as its predecessor"
             seq (hash-ref prev 'seq))]
    [(and prev (not (equal? (parsed-field payload 3) (hash-ref prev 'hash))))
     (format "receipt ~a's signed predecessor is not receipt ~a" seq (hash-ref prev 'seq))]
    [else #f]))
