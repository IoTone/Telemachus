#lang racket/base

;; test/content-encryption-tests.rkt — issue #83: document-derived content at rest.
;;
;; THE ACCEPTANCE CRITERION IS THE TEST: "a dump taken after processing a fixture
;; contains no fixture text". So these cases read the raw column and scan the whole
;; row, rather than asking the API whether it encrypted — which would be asking the
;; thing under test to grade itself.
;;
;; What has to hold:
;;   1. OFF by default: the column holds plaintext, and content search works. This
;;      matters more than the encryption case — the switch must be inert when unset
;;   2. ON: the column holds no fixture text, and the API still reads it back
;;   3. a row sealed while ON still opens after the switch is turned OFF, or
;;      flipping it back would lose every document's text
;;   4. the AAD binds the row: a ciphertext moved to another object does NOT open
;;   5. search SAYS content matching is unavailable rather than silently missing
;;
;;   raco test test/content-encryption-tests.rkt

(require rackunit db-kit/portable racket/string racket/port racket/file
         db-kit/migrate
         "../domain/db/migrations.rkt"
         "db-fixture.rkt"
         "../domain/authz/authz.rkt"
         "../domain/db/id.rkt"
         "../domain/repo/blobs.rkt"
         "../domain/repo/extract.rkt"
         "../config.rkt")

(define BLOB-ROOT (make-temporary-file "telemachus-enc-~a" 'directory))
(current-blob-root BLOB-ROOT)

(define (fresh) (define c (fresh-db #:migrate? #f)) (migrate! c all-migrations) c)

(define SECRET "The claimant's NHS number is 943-476-5919.")

;; The whole row as the database holds it — the closest a test gets to `pg_dump`
;; without shelling out, and it catches a value that leaked into a column nobody
;; thought about.
(define (raw-row c oid)
  (format "~a" (query-rows c "SELECT * FROM repo_text WHERE object_id = ?" oid)))

(define (with-env name value thunk)
  (define saved (getenv name))
  (dynamic-wind (lambda () (putenv name value))
                thunk
                (lambda () (putenv name (or saved "")))))

;; ---- 1. OFF by default ----------------------------------------------------------
(test-case "unset, nothing changes: the column is plaintext and reads back"
  (define c (fresh))
  (define oid (new-id))
  (check-false (content-encryption-enabled?) "the switch must be off unless asked for")
  (repo-text-upsert! c oid "v1" SECRET #:spans (list (hasheq 'start 0 'end 3 'page 1 'bbox '(1 2 3 4))))
  (check-equal? (repo-text-for c oid) SECRET)
  (check-true (string-contains? (raw-row c oid) "943-476-5919")
              "with the switch off the text IS in the row — which is the status quo")
  (check-equal? (length (repo-spans-for c oid)) 1)
  (close-db! c))

;; ---- 2/3/4. ON --------------------------------------------------------------------
(test-case "on, the row holds no fixture text, and it still reads back"
  (define c (fresh))
  (define oid (new-id))
  (with-env "TMACH_SECRET_KEY" (make-string 64 #\a)
    (lambda ()
      (with-env "TMACH_ENCRYPT_CONTENT" "1"
        (lambda ()
          (check-true (content-encryption-enabled?))
          (repo-text-upsert! c oid "v1" SECRET
                             #:spans (list (hasheq 'start 0 'end 3 'page 7 'bbox '(9 9 9 9))))
          ;; THE ACCEPTANCE CRITERION, read off the raw row
          (define raw (raw-row c oid))
          (check-false (string-contains? raw "943-476-5919")
                       "the NHS number must not appear anywhere in the row")
          (check-false (string-contains? raw "claimant")
                       "nor any other word of the fixture")
          ;; the spans are sealed too — a bbox list is a map of where the words are
          (check-false (string-contains? raw "\"page\":7")
                       "the page structure is derived content and is sealed as well")
          (check-true (string-contains? raw "enc:v1:")
                      "…and what IS there is the documented sealed form")
          ;; …and the API still works
          (check-equal? (repo-text-for c oid) SECRET)
          (check-equal? (hash-ref (car (repo-spans-for c oid)) 'page) 7)))))
  ;; 3. the switch going OFF must not lose what was sealed while it was on. The
  ;;    key is still present; only the switch changed.
  (with-env "TMACH_SECRET_KEY" (make-string 64 #\a)
    (lambda ()
      (check-false (content-encryption-enabled?))
      (check-equal? (repo-text-for c oid) SECRET
                    "a row sealed while the switch was on must open after it is off")))
  (close-db! c))

(test-case "the AAD binds the ciphertext to its row"
  (define c (fresh))
  (define a (new-id))
  (define b (new-id))
  (with-env "TMACH_SECRET_KEY" (make-string 64 #\b)
    (lambda ()
      (with-env "TMACH_ENCRYPT_CONTENT" "1"
        (lambda ()
          (repo-text-upsert! c a "v1" SECRET)
          (repo-text-upsert! c b "v1" "something else entirely")
          ;; move A's ciphertext into B's row, as a tampering or a bad restore would
          (define a-cipher (query-value c "SELECT content FROM repo_text WHERE object_id = ?" a))
          (query-exec c "UPDATE repo_text SET content = ? WHERE object_id = ?" a-cipher b)
          ;; …and it must not open there: the AAD is "<table>.<column>:<row-id>"
          (check-exn exn:fail?
                     (lambda () (repo-text-for c b))
                     "a ciphertext moved between rows must NOT decrypt")
          ;; A's own row is unaffected
          (check-equal? (repo-text-for c a) SECRET)))))
  (close-db! c))

;; ---- r4: logs and error paths must not quote document text ----------------------
;; The requirement asks for "a test that greps captured logs for fixture content
;; during failing jobs". The failure that matters is the one encryption introduces:
;; a row that will NOT open. An exception carrying the ciphertext, the key id, or
;; worse the plaintext, puts the thing in the log that the column was sealed to
;; keep out of the database.
(test-case "a row that cannot be unsealed fails without quoting content or key material"
  (define c (fresh))
  (define oid (new-id))
  (with-env "TMACH_SECRET_KEY" (make-string 64 #\c)
    (lambda ()
      (with-env "TMACH_ENCRYPT_CONTENT" "1"
        (lambda () (repo-text-upsert! c oid "v1" SECRET)))))
  ;; a DIFFERENT key: the row is now unreadable, which is the real operational
  ;; failure (a rotated key, a restored dump) rather than a contrived one
  (define captured
    (with-env "TMACH_SECRET_KEY" (make-string 64 #\d)
      (lambda ()
        (define out (open-output-string))
        (parameterize ([current-error-port out])
          (with-handlers ([exn:fail? (lambda (e) (displayln (exn-message e) out))])
            (repo-text-for c oid)))
        (get-output-string out))))
  (check-true (> (string-length captured) 0) "it must fail loudly, not return nothing")
  (check-false (string-contains? captured "943-476-5919")
               "the message must not contain the plaintext")
  (check-false (string-contains? captured "claimant")
               "nor any of its words")
  ;; …nor the key material or the ciphertext, which a naive "here is the value I
  ;; could not read" message would include
  (check-false (string-contains? captured (make-string 64 #\c)) "no key material")
  (check-false (string-contains? captured "enc:v1:") "no ciphertext echoed back")
  (close-db! c))
