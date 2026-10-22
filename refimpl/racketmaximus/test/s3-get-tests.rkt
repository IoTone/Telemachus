#lang racket/base

;; test/s3-get-tests.rkt — S3 GetObject, outcome by outcome (#110 r7).
;;
;; `op-get-object` is the deepest function in the tree (48 lines, nesting depth 8
;; by the measure in the r7 re-measurement) and had **no unit test at all**. Its
;; only coverage was one ranged GET in `test/s3-smoke.sh`, which needs the real
;; `aws` CLI and SKIPS without it — and CLAUDE.md already records the lesson that
;; "a skip was how that path went unexercised in the first place". Four of its six
;; outcomes had nothing checking them: HEAD, the 416, a suffix range, and a
;; version that does not exist.
;;
;; That is why r7 for this function is tests FIRST and the extraction second:
;; what the issue called a complexity hotspot is, more precisely, the riskiest
;; function in the tree with the least coverage. The failure mode is not an
;; exception — it is `aws s3 cp` writing a corrupt file and reporting success,
;; because a server that ignores Range returns the whole object for each of the
;; parallel ranged GETs.
;;
;; These are CHARACTERISATION tests: written against the behaviour as it is,
;; before touching it, so they say what the refactor must preserve.
;;
;;   raco test test/s3-get-tests.rkt

(require rackunit racket/file racket/port racket/string db-kit/portable
         db-kit/migrate
         "../domain/db/migrations.rkt"
         "db-fixture.rkt"
         "../domain/authz/authz.rkt"
         "../domain/repo/repo.rkt"
         "../domain/repo/blobs.rkt"
         (only-in "../domain/s3/server.rkt" op-get-object parse-range)
         (only-in web-kit/http1 http-res-code http-res-headers http-res-body
                  http-res-content-length))

(define (fresh) (define c (fresh-db #:migrate? #f)) (migrate! c all-migrations) c)
(define BODY (bytes->immutable-bytes (apply bytes (for/list ([i (in-range 1000)]) (modulo i 251)))))

(define (with-fixture proc)
  (define root (make-temporary-file "tmx-s3get-~a" 'directory))
  (dynamic-wind
   void
   (lambda ()
     (parameterize ([current-blob-root root])
       (define c (fresh))
       (define-values (uid tid) (bootstrap! c #:username "root" #:password "root-pass-1"))
       (define p (user-principal c uid tid))
       (void (repo-put! c p #:key "big.bin" #:content-type "application/octet-stream"
                        #:port (open-input-bytes BODY) #:filename "big.bin"))
       (proc c p)
       (disconnect c)))
   (lambda () (delete-directory/files root #:must-exist? #f))))

;; A body is EITHER bytes or a procedure that writes to a port, depending on the
;; arm — `s3-error` builds the XML eagerly, the streaming arms hand back a writer
;; so nothing is buffered. Worth knowing before touching either.
(define (body-bytes res)
  (define b (http-res-body res))
  (cond
    [(bytes? b) b]
    [(string? b) (string->bytes/utf-8 b)]
    [else (define o (open-output-bytes)) (b o) (get-output-bytes o)]))
(define (hdr res name)
  (define h (assoc name (http-res-headers res)))
  (and h (bytes->string/utf-8 (cdr h))))

;; ---- 1. the whole object ----------------------------------------------------
(test-case "a plain GET answers 200 with every byte, and the length matches"
  (with-fixture (lambda (c p)
    (define r (op-get-object c p "default" "big.bin" #f))
    (check-equal? (http-res-code r) 200)
    (check-equal? (http-res-content-length r) 1000)
    (check-equal? (body-bytes r) BODY "byte-identical, which is the product promise")
    (check-equal? (hdr r #"Content-Type") "application/octet-stream")
    ;; clients decide whether to attempt a ranged download from this
    (check-equal? (hdr r #"Accept-Ranges") "bytes"))))

;; ---- 2. HEAD ----------------------------------------------------------------
(test-case "HEAD answers 200 with the length and NO body"
  ;; untested before this file. A HEAD that streamed the object would be a
  ;; silent waste on every `aws s3 ls` of a large bucket.
  (with-fixture (lambda (c p)
    (define r (op-get-object c p "default" "big.bin" #t))
    (check-equal? (http-res-code r) 200)
    (check-equal? (http-res-content-length r) 1000 "the length is still reported")
    (check-equal? (body-bytes r) #"" "…and the body is empty")
    (check-equal? (hdr r #"Accept-Ranges") "bytes"))))

;; ---- 3. a satisfiable range -------------------------------------------------
(test-case "a range answers 206 with Content-Range and exactly those bytes"
  (with-fixture (lambda (c p)
    (define r (op-get-object c p "default" "big.bin" #f "bytes=100-199"))
    (check-equal? (http-res-code r) 206)
    (check-equal? (hdr r #"Content-Range") "bytes 100-199/1000")
    (check-equal? (http-res-content-length r) 100)
    (check-equal? (body-bytes r) (subbytes BODY 100 200)
                  "THE bug this guards: returning the whole object for each parallel
                   ranged GET produces a corrupt file the client calls a success"))))

(test-case "an open-ended range runs to the last byte"
  (with-fixture (lambda (c p)
    (define r (op-get-object c p "default" "big.bin" #f "bytes=990-"))
    (check-equal? (http-res-code r) 206)
    (check-equal? (hdr r #"Content-Range") "bytes 990-999/1000")
    (check-equal? (body-bytes r) (subbytes BODY 990 1000)))))

(test-case "a SUFFIX range answers the last N bytes"
  ;; untested before this file, and the arithmetic is the easiest to get wrong
  (with-fixture (lambda (c p)
    (define r (op-get-object c p "default" "big.bin" #f "bytes=-10"))
    (check-equal? (http-res-code r) 206)
    (check-equal? (hdr r #"Content-Range") "bytes 990-999/1000")
    (check-equal? (body-bytes r) (subbytes BODY 990 1000)))))

(test-case "an end past the object is clamped, not refused"
  (with-fixture (lambda (c p)
    (define r (op-get-object c p "default" "big.bin" #f "bytes=995-99999"))
    (check-equal? (http-res-code r) 206)
    (check-equal? (hdr r #"Content-Range") "bytes 995-999/1000")
    (check-equal? (body-bytes r) (subbytes BODY 995 1000)))))

;; ---- 4. an unsatisfiable range ---------------------------------------------
(test-case "a start past the end is 416, naming the size"
  ;; untested before this file
  (with-fixture (lambda (c p)
    (define r (op-get-object c p "default" "big.bin" #f "bytes=5000-6000"))
    (check-equal? (http-res-code r) 416)
    (check-true (string-contains? (bytes->string/utf-8 (body-bytes r)) "InvalidRange"))
    (check-true (string-contains? (bytes->string/utf-8 (body-bytes r)) "1000")
                "the message says what the object's size actually is"))))

(test-case "a malformed range is IGNORED, not refused — the whole object comes back"
  ;; deliberate and worth pinning: RFC 7233 says to ignore a Range header that is
  ;; not understood, and only `bytes=` ones that parse-and-fail are a 416. A
  ;; refactor that turned these into 416 would break any client sending a unit we
  ;; do not implement.
  (with-fixture (lambda (c p)
    (for ([h (in-list '("rubbish" "items=0-5" "bytes 0-5"))])
      (define r (op-get-object c p "default" "big.bin" #f h))
      (check-equal? (http-res-code r) 200 (format "~s must be ignored" h))
      (check-equal? (body-bytes r) BODY)))))

(test-case "…but an empty `bytes=-` IS a 416"
  ;; it parses as a bytes range and satisfies nothing, which is the other side of
  ;; the line above
  (with-fixture (lambda (c p)
    (check-equal? (http-res-code (op-get-object c p "default" "big.bin" #f "bytes=-")) 416))))

;; ---- 5. what is not there ---------------------------------------------------
(test-case "an unknown key is NoSuchKey"
  (with-fixture (lambda (c p)
    (define r (op-get-object c p "default" "nope.bin" #f))
    (check-equal? (http-res-code r) 404)
    (check-true (string-contains? (bytes->string/utf-8 (body-bytes r)) "NoSuchKey")))))

(test-case "a version that does not exist is NoSuchKey, not a crash"
  ;; untested before this file, and it is the arm most likely to be reached by a
  ;; client holding a stale version id
  (with-fixture (lambda (c p)
    (define r (op-get-object c p "default" "big.bin" #f #f "no-such-version"))
    (check-equal? (http-res-code r) 404)
    (check-true (string-contains? (bytes->string/utf-8 (body-bytes r)) "NoSuchKey")))))

;; ---- parse-range on its own -------------------------------------------------
;; the arithmetic, without a database in the way
(test-case "parse-range"
  (check-equal? (parse-range "bytes=0-9" 1000) '(0 . 9))
  (check-equal? (parse-range "bytes=100-199" 1000) '(100 . 199))
  (check-equal? (parse-range "bytes=990-" 1000) '(990 . 999) "open-ended")
  (check-equal? (parse-range "bytes=-10" 1000) '(990 . 999) "suffix")
  (check-equal? (parse-range "bytes=-5000" 1000) '(0 . 999) "a suffix longer than the object is the object")
  (check-equal? (parse-range "bytes=995-99999" 1000) '(995 . 999) "the end clamps")
  (check-equal? (parse-range " bytes=0-9 " 1000) '(0 . 9) "surrounding space is tolerated")
  (check-false (parse-range "bytes=1000-1001" 1000) "a start at or past the size")
  (check-false (parse-range "bytes=9-0" 1000) "end before start")
  (check-false (parse-range "bytes=-0" 1000) "a zero-length suffix")
  (check-false (parse-range "bytes=-" 1000) "no numbers at all")
  (check-false (parse-range "items=0-5" 1000) "another unit")
  (check-false (parse-range "rubbish" 1000))
  (check-false (parse-range #f 1000)))
