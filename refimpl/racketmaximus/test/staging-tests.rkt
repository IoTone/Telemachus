#lang racket/base

;; test/staging-tests.rkt — an upload assembled from parts (#192 slice 2).
;;   raco test test/staging-tests.rkt
;;   DATABASE_URL=postgres://… raco test test/staging-tests.rkt
;;
;; The table operations, not the routes: `server/api/staged.rkt` is a translation
;; layer and the HTTP half is `server-smoke.sh`'s. What is tested here is every
;; rule the module decides — the retry replacing, the quota charge and its
;; refund, the ascending assembly, the team scope and the part ceiling.
;;
;; THE S3 LISTENER'S OWN SUITES ARE THE OTHER HALF OF THIS SLICE'S PROOF.
;; `staging.rkt` is an EXTRACTION: `op-upload-part` and friends delegate to it
;; now, so `test/upload-reap-tests.rkt` and `test/s3-smoke.sh` passing unchanged
;; is what says the move was behaviour-preserving. That is the characterisation
;; argument #110 r7 makes — the tests were written before the extraction, against
;; the behaviour as it stood.

(require rackunit db-kit/portable db-kit/migrate
         racket/file racket/port racket/list
         "../domain/db/migrations.rkt"
         "db-fixture.rkt"
         "../domain/authz/authz.rkt"
         "../domain/repo/blobs.rkt"
         (only-in "../domain/repo/repo.rkt" repo-open repo-put! set-put-hook!
                  STORAGE-DIMENSION)
         (only-in "../domain/quota/quota.rkt" quota-used set-limit!)
         (only-in "../domain/repo/blobs.rkt" blob-exists?)
         (only-in sha2-kit sha256-hex)
         "../domain/repo/staging.rkt")

(define BLOB-ROOT (make-temporary-file "telemachus-staging-~a" 'directory))
(current-blob-root BLOB-ROOT)

(define (fresh)
  (define conn (fresh-db #:migrate? #f))
  (migrate! conn all-migrations)
  conn)

(define (seed!)
  (define conn (fresh))
  (define-values (uid tid) (bootstrap! conn #:username "alice"))
  (values conn (user-principal conn uid tid) tid))

(define (part! conn up n str)
  (staging-put-part! conn up n (open-input-bytes (string->bytes/utf-8 str))))

(define (text-of conn p id)
  (define-values (o in) (repo-open conn p id))
  (dynamic-wind void (lambda () (port->string in)) (lambda () (close-input-port in))))

;; =============================================================================

(test-case "1. parts are assembled in ASCENDING order, through the ordinary repo-put!"
  (define-values (conn p tid) (seed!))
  (define uid (staging-begin! conn p "voice/long.mp3" "audio/mpeg"))
  (define up (staging-row conn p uid))
  ;; TWELVE parts, staged in a SCRAMBLED order, and that is not decoration: with
  ;; three the first version of this case passed against `(hash-keys have)` with
  ;; no sort at all, because Racket's hash order happened to be ascending for
  ;; three small integer keys. `canonical-json`'s trap, in a test — the control
  ;; reported no bite and the assertion was the weak half.
  (define letters (list "a" "b" "c" "d" "e" "f" "g" "h" "i" "j" "k" "l"))
  (for ([n (in-list '(7 1 12 4 9 2 11 5 8 3 10 6))])
    (part! conn up n (list-ref letters (sub1 n))))
  (define o (staging-complete! conn p up))
  (check-equal? (text-of conn p (hash-ref o 'id)) "abcdefghijkl"
                "STG-6: the writer produced them in time order, so ascending IS the order")
  ;; HOW FAR THAT GOES, AND IT IS NOT ALL THE WAY. Removing the `sort` from the
  ;; default order fails NOTHING — tried with three parts and again with twelve
  ;; scrambled ones — because Racket's `hash-keys` on small integer keys happens
  ;; to come back ascending for a hash this size. VEC-13's unpinnable pin, the
  ;; third time this shape appears in these suites: a reason to write the sort
  ;; down rather than a reason it is redundant, since the hash's order is not a
  ;; documented property and a different key set would not have it.
  ;;
  ;; What IS pinned is that an EXPLICIT order is honoured, which is the S3
  ;; surface's case and the only one where the order is somebody's choice.
  (define uid2 (staging-begin! conn p "voice/rev.mp3" "audio/mpeg"))
  (define up2 (staging-row conn p uid2))
  (part! conn up2 1 "one") (part! conn up2 2 "two") (part! conn up2 3 "three")
  (define o2 (staging-complete! conn p up2 '(3 1 2)))
  (check-equal? (text-of conn p (hash-ref o2 'id)) "threeonetwo"
                "the caller's own order, which is not the ascending one")
  (check-equal? (hash-ref o 'key) "voice/long.mp3")
  (check-equal? (hash-ref o 'content_type) "audio/mpeg")
  ;; and the upload is gone, not left behind as a tombstone
  (check-false (staging-row conn p uid))
  (close-db! conn))

(test-case "2. a retried part REPLACES, which is the whole reason they are numbered"
  (define-values (conn p tid) (seed!))
  (define uid (staging-begin! conn p "a.bin" "application/octet-stream"))
  (define up (staging-row conn p uid))
  (part! conn up 1 "first-attempt")
  (part! conn up 2 "-tail")
  (check-equal? (length (staging-parts conn uid)) 2)
  ;; the same number again: a chunk whose request failed costs that chunk, not
  ;; the recording
  (part! conn up 1 "SECOND")
  (check-equal? (length (staging-parts conn uid)) 2 "replaced, not duplicated")
  (define o (staging-complete! conn p up))
  (check-equal? (text-of conn p (hash-ref o 'id)) "SECOND-tail")
  (close-db! conn))

(test-case "3. S3-8's charge and refund, through the one place an upload stops existing"
  (define-values (conn p tid) (seed!))
  (define uid (staging-begin! conn p "a.bin" "application/octet-stream"))
  (define up (staging-row conn p uid))
  (check-equal? (quota-used conn "team" tid STORAGE-DIMENSION "total") 0
                "beginning an upload costs one row and no bytes")
  (part! conn up 1 "0123456789")
  (check-equal? (quota-used conn "team" tid STORAGE-DIMENSION "total") 10
                "charged ON ARRIVAL — charging only at Complete leaves the quota walkable")
  ;; a REPLACEMENT charges the delta, not the whole part again
  (part! conn up 1 "01234567890123456789")
  (check-equal? (quota-used conn "team" tid STORAGE-DIMENSION "total") 20)
  (part! conn up 2 "xyz")
  (check-equal? (quota-used conn "team" tid STORAGE-DIMENSION "total") 23)
  ;; abort refunds the lot
  (staging-drop! conn up)
  (check-equal? (quota-used conn "team" tid STORAGE-DIMENSION "total") 0)
  (close-db! conn))

(test-case "4. …and at Complete the steady state is exactly a single-shot PUT's"
  ;; The refund lands AFTER `repo-put!` has charged the assembled object, so what
  ;; the team holds afterwards is the object and nothing else. Asserted against a
  ;; direct PUT of the same bytes rather than against a number, because the
  ;; number is the point only if it matches.
  (define-values (conn p tid) (seed!))
  (define uid (staging-begin! conn p "staged.bin" "application/octet-stream"))
  (define up (staging-row conn p uid))
  (part! conn up 1 "hello ")
  (part! conn up 2 "world")
  (staging-complete! conn p up)
  (define staged-usage (quota-used conn "team" tid STORAGE-DIMENSION "total"))
  (define-values (conn2 p2 tid2) (seed!))
  (repo-put! conn2 p2 #:key "direct.bin" #:port (open-input-bytes #"hello world")
             #:content-type "application/octet-stream")
  (check-equal? staged-usage (quota-used conn2 "team" tid2 STORAGE-DIMENSION "total")
                "11 bytes either way — the staged parts left nothing behind")
  (close-db! conn) (close-db! conn2))

(test-case "5. a part refused on quota leaves no row and no bytes charged"
  (define-values (conn p tid) (seed!))
  (set-limit! conn "team" tid STORAGE-DIMENSION 8 #:window "total")
  (define uid (staging-begin! conn p "a.bin" "application/octet-stream"))
  (define up (staging-row conn p uid))
  (part! conn up 1 "12345")
  (check-exn #px"storage quota exceeded" (lambda () (part! conn up 2 "678901234")))
  (check-equal? (length (staging-parts conn uid)) 1 "the refused part is not a row")
  (check-equal? (quota-used conn "team" tid STORAGE-DIMENSION "total") 5
                "…and its bytes were never charged")
  ;; AND THE STAGED BLOB IS GONE FROM THE STORE, which the quota figure cannot
  ;; say: the charge happens AFTER the admission check, so removing the release
  ;; leaves the number right and the bytes leaked — the control reported no bite
  ;; until this line existed. Nothing else would ever collect them: #122's sweep
  ;; reads `repo_blob_staging`, and a part is not recorded there.
  (define org (hash-ref (staging-row conn p uid) 'org_id))
  (check-false (blob-exists? org (sha256-hex (string->bytes/utf-8 "678901234")))
               "a refused part's bytes are released, not left in the store")
  (close-db! conn))

(test-case "6. an upload is scoped to the caller's own TEAM"
  ;; An upload id is instance-global, so the team clause is what stops one team's
  ;; id reaching another's row — `org-team-resolve`'s lesson, and the reason the
  ;; lookup is one function rather than one per surface.
  (define-values (conn p tid) (seed!))
  (define uid (staging-begin! conn p "a.bin" "application/octet-stream"))
  (define other (create-team! conn #:name "Other" #:slug "other"))
  (define bob (create-user! conn #:username "bob" #:password "pw"))
  (add-member! conn #:team other #:user bob #:role "owner")
  (define pb (user-principal conn bob other))
  (check-false (staging-row conn pb uid) "another team's upload id is a miss")
  (check-true (and (staging-row conn p uid) #t))
  (close-db! conn))

(test-case "7. the refusals: no parts, a gap in the numbering, a bad number"
  (define-values (conn p tid) (seed!))
  (define uid (staging-begin! conn p "a.bin" "application/octet-stream"))
  (define up (staging-row conn p uid))
  (check-exn #px"no parts were uploaded" (lambda () (staging-complete! conn p up)))
  (part! conn up 1 "x")
  (check-exn #px"part 2 was never uploaded"
             (lambda () (staging-complete! conn p up '(1 2)))
             "a named order with a hole is refused, which is the S3 surface's case")
  (check-exn #px"positive part number" (lambda () (part! conn up 0 "x")))
  (check-exn #px"positive part number" (lambda () (part! conn up -1 "x")))
  ;; …and ascending assembly over what IS there still works
  (check-true (hash? (staging-complete! conn p up)))
  (close-db! conn))

(test-case "8. STG-2: the part COUNT is bounded, and a replacement is exempt"
  ;; `max-upload-bytes` caps one part and nothing caps their number, which is the
  ;; hole S3-8's charge-on-arrival closed for BYTES. Ten thousand 1-byte parts is
  ;; a cheap way to make Complete chain ten thousand ports.
  (define-values (conn p tid) (seed!))
  (define uid (staging-begin! conn p "a.bin" "application/octet-stream"))
  (define up (staging-row conn p uid))
  ;; filling to the ceiling honestly would be 10,000 round trips, so the rows are
  ;; seeded directly — the rule under test is the COUNT, not the staging
  (for ([n (in-range 1 (add1 STAGING-MAX-PARTS))])
    (query-exec conn
      (string-append "INSERT INTO repo_upload_parts "
                     "(id, upload_id, part_number, digest, size, created_epoch) "
                     "VALUES (?, ?, ?, ?, ?, ?)")
      (format "pt~a" n) uid n "deadbeef" 0 (current-seconds)))
  (check-exn #px"which is the limit" (lambda () (part! conn up 99999 "x"))
             "a NEW part past the ceiling is refused")
  ;; a retry of an existing number adds no row, so it must still be allowed —
  ;; otherwise a client that reaches the ceiling can no longer recover a chunk
  (check-true (let-values ([(d s) (part! conn up 1 "x")]) (= s 1))
              "a REPLACEMENT is exempt")
  (close-db! conn))

(test-case "9. a part is bounded in bytes by the front door's own ceiling"
  ;; `max-upload-bytes` — the same cap `PUT /api/repo/<key>` enforces, which is
  ;; why a long recording is chunks rather than one body.
  (define-values (conn p tid) (seed!))
  (define uid (staging-begin! conn p "a.bin" "application/octet-stream"))
  (define up (staging-row conn p uid))
  (check-exn #px"too large|exceed"
             (lambda ()
               (staging-put-part! conn up 1 (open-input-bytes (make-bytes (* 33 1024 1024) 65)))))
  (close-db! conn))

(test-case "9b. STG-4: an invalid key is refused at BEGIN, before anything is sent"
  ;; `repo-put!` validates the key too and would refuse at COMPLETE — after the
  ;; client had uploaded the whole recording, which for a long voice note is
  ;; minutes of somebody's time and a storage charge that then has to be
  ;; refunded. No unit case covered this until a control reported no bite.
  (define-values (conn p tid) (seed!))
  (check-exn #px"invalid key"
             (lambda () (staging-begin! conn p "../escape" "application/octet-stream")))
  (check-exn #px"invalid key"
             (lambda () (staging-begin! conn p "" "application/octet-stream")))
  (check-true (string? (staging-begin! conn p "ok/fine.mp3" "audio/mpeg")))
  (close-db! conn))

(test-case "10. beginning one needs files:write"
  (define-values (conn p tid) (seed!))
  (define viewer (create-user! conn #:username "vera" #:password "pw"))
  (add-member! conn #:team tid #:user viewer #:role "viewer")
  (define pv (user-principal conn viewer tid))
  (check-exn #px"files:write"
             (lambda () (staging-begin! conn pv "a.bin" "application/octet-stream")))
  ;; …and that is the SAME check `repo-put!` makes on its first line, so a staged
  ;; write and a single-shot PUT admit exactly the same callers — which is why
  ;; the route is role-scoped and `route-perm-gate-tests.rkt` exempts it by name.
  (check-exn #px"files:write"
             (lambda () (repo-put! conn pv #:key "a.bin" #:port (open-input-bytes #"x"))))
  (close-db! conn))

(test-case "11. the completed object fires the put hook, as a single-shot PUT does"
  ;; Which is what makes a finished recording reach `transcribe-documents`'
  ;; trigger: `staging-complete!` writes through `repo-put!` rather than around
  ;; it, so versioning, the quota, the audit entry and the trigger seam are all
  ;; the ordinary ones.
  (define-values (conn p tid) (seed!))
  (define seen (box '()))
  ;; the hook is called with keyword arguments, so a rest-arg lambda does not
  ;; accept it — `make-keyword-procedure` is the shape, which CLAUDE.md records
  ;; from the chunker's own test helper
  (set-put-hook! (make-keyword-procedure
                  (lambda (kws kw-args . rest)
                    (set-box! seen (cons rest (unbox seen))))))
  (dynamic-wind
    void
    (lambda ()
      (define uid (staging-begin! conn p "voice/a.mp3" "audio/mpeg"))
      (define up (staging-row conn p uid))
      (part! conn up 1 "bytes")
      (staging-complete! conn p up)
      (check-equal? (length (unbox seen)) 1 "the hook fired exactly once, at Complete"))
    (lambda () (set-put-hook! #f)))
  (close-db! conn))
