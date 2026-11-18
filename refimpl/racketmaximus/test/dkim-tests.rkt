#lang racket/base

;; test/dkim-tests.rkt — the signature that makes DMARC alignment possible.
;;
;; THE PROOF IS A REAL VERIFICATION, not a reading of the code: the test signs a
;; message, then hands the signature, the public key and the signing input to
;; `openssl dgst -verify` and requires "Verified OK". That is the only way to
;; establish that the canonicalization the signer applies is the canonicalization a
;; receiver will apply, which is the whole of DKIM.
;;
;; The body hash is checked separately and independently, because a signature over
;; the wrong body hash verifies perfectly and still fails at the receiver.
;;
;;   raco test test/dkim-tests.rkt

(require rackunit racket/string racket/port racket/file racket/system
         net/base64 sha2-kit
         "../domain/mail/dkim.rkt"
         "../domain/mail/transport.rkt")

(define OPENSSL (find-executable-path "openssl"))

(define (tmpdir) (make-temporary-file "tmach-dkim-test-~a" 'directory))

;; -> (values private-pem public-pem). 2048 bits, because a 1024-bit key is
;; refused by most receivers and a 4096-bit one makes the test slow for no gain.
(define (keypair dir)
  (define priv (build-path dir "priv.pem"))
  (define pub (build-path dir "pub.pem"))
  (define (run . args)
    (define-values (p out in err) (apply subprocess #f #f #f OPENSSL args))
    (close-output-port in)
    (define o (port->string out)) (define e (port->string err))
    (subprocess-wait p)
    (unless (equal? (subprocess-status p) 0) (error 'test "openssl ~a: ~a" args e))
    o)
  (run "genrsa" "-out" (path->string priv) "2048")
  (run "rsa" "-in" (path->string priv) "-pubout" "-out" (path->string pub))
  (values (file->string priv) (file->string pub)))

;; A message as `compose-message` builds one: the header block ends with a blank
;; line, and the body is a list of lines.
(define HDR
  (string-append "From: TMach <tmach@example.test>\r\n"
                 "To: supplier@example.test\r\n"
                 "Date: Mon, 17 Nov 2026 10:00:00 +0000\r\n"
                 "Subject: Document request: the label artwork\r\n"
                 "Message-ID: <abc123@example.test>\r\n"
                 "\r\n"))

(define BODY (list "aGVsbG8sIHRoaXMgaXMgYSBiYXNlNjQgYm9keQ==" "c2Vjb25kIGxpbmU="))

(define (b64->bytes s) (base64-decode (string->bytes/utf-8 s)))

;; ---- the signature verifies ---------------------------------------------------
(test-case "a signed message verifies with openssl against the public key"
  (define dir (tmpdir))
  (define-values (priv pub) (keypair dir))
  (define-values (input unsigned) (dkim-signing-input HDR BODY "example.test" "tmach"))
  (define value (dkim-sign-header HDR BODY #:domain "example.test" #:selector "tmach" #:key priv))
  ;; the value is the unsigned header with the signature appended, so the b= tag
  ;; is the tail of it
  (check-true (string-prefix? value unsigned))
  (define sig-b64 (substring value (string-length unsigned) (string-length value)))
  (define sig (build-path dir "sig.bin"))
  (call-with-output-file sig #:exists 'replace (lambda (o) (write-bytes (b64->bytes sig-b64) o)))
  (define in (build-path dir "input.txt"))
  (call-with-output-file in #:exists 'replace (lambda (o) (write-bytes (string->bytes/utf-8 input) o)))
  (define-values (p out inp err)
    (subprocess #f #f #f OPENSSL "dgst" "-sha256" "-verify" (path->string (build-path dir "pub.pem"))
                "-signature" (path->string sig) (path->string in)))
  (close-output-port inp)
  (define o (port->string out)) (define e (port->string err))
  (subprocess-wait p)
  (check-equal? (subprocess-status p) 0 (string-append "openssl refused the signature: " e))
  (check-true (string-contains? o "Verified OK"))
  (delete-directory/files dir))

;; ---- the body hash is the body's own ------------------------------------------
(test-case "the body hash is sha256 of the canonical body, computed independently"
  (define canonical (string-append (string-join BODY "\r\n") "\r\n"))
  (define expected (bytes->string/utf-8
                    (base64-encode (sha256 (string->bytes/utf-8 canonical)) "")))
  (check-equal? (dkim-body-hash BODY) expected)
  ;; a changed body changes the hash, which is the property the receiver relies on
  (check-false (equal? (dkim-body-hash (list "dGFtcGVyZWQ=")) (dkim-body-hash BODY)))
  ;; trailing empty lines are dropped, so a relay that adds one does not break it
  (check-equal? (dkim-body-hash (append BODY (list "" ""))) (dkim-body-hash BODY))
  ;; trailing whitespace on a line is stripped
  (check-equal? (dkim-body-hash (list "abc  ")) (dkim-body-hash (list "abc"))))

;; ---- canonicalization ---------------------------------------------------------
(test-case "relaxed header canonicalization lowercases, unfolds and collapses"
  (check-equal? (dkim-relaxed-header "Subject" "  a   b  ") "subject:a b")
  (check-equal? (dkim-relaxed-header "To" "a@b.test,\r\n\tc@d.test") "to:a@b.test, c@d.test"))

(test-case "the signing input covers the five headers and the signature itself"
  (define-values (input unsigned) (dkim-signing-input HDR BODY "example.test" "tmach"))
  (check-true (string-prefix? input "from:TMach <tmach@example.test>\r\n"))
  (check-true (string-contains? input "subject:Document request: the label artwork\r\n"))
  (check-true (string-contains? input "message-id:<abc123@example.test>\r\n"))
  ;; the DKIM-Signature header is the LAST line and carries no trailing CRLF, which
  ;; is what a verifier recomputes
  (check-true (string-suffix? input (dkim-relaxed-header "DKIM-Signature" unsigned)))
  (check-false (string-suffix? input "\r\n"))
  (check-true (string-contains? unsigned "b="))
  (check-true (string-suffix? unsigned "b=") "the b= tag is empty in the signed form"))

(test-case "a message missing a covered header is refused rather than signed"
  (define dir (tmpdir))
  (define-values (priv pub) (keypair dir))
  (define no-subject
    (string-append "From: a@b.test\r\nTo: c@d.test\r\nDate: Mon, 17 Nov 2026 10:00:00 +0000\r\n"
                   "Message-ID: <x@b.test>\r\n\r\n"))
  (check-exn exn:fail?
             (lambda () (dkim-sign-header no-subject BODY #:domain "b.test" #:selector "s" #:key priv)))
  (delete-directory/files dir))

;; ---- the configuration --------------------------------------------------------
;; THE KEY IS AN ARGUMENT AND THERE IS NO SECOND PLACE IT COULD COME FROM: asking
;; the transport hash for it is what made signing inert on every real transport
;; while every test of the signer passed.
(test-case "signing is configured only when a selector is stored and a key is handed in"
  (check-false (dkim-configured? #f "-----BEGIN PRIVATE KEY-----"))
  (check-false (dkim-configured? (hasheq 'dkim_selector "s") #f))
  (check-false (dkim-configured? (hasheq 'dkim_selector "s" 'dkim_key "-----BEGIN PRIVATE KEY-----") #f)
               "a key in the transport hash is not a key: the read never carries one")
  (check-false (dkim-configured? (hasheq 'has_dkim_key #t) "-----BEGIN PRIVATE KEY-----"))
  (check-true (dkim-configured? (hasheq 'dkim_selector "s") "-----BEGIN PRIVATE KEY-----")))

;; RFC 6376 5.4: a field named once in `h=` is canonicalized from the BOTTOM of
;; the header block, so the signature covers the last instance. Signing the top one
;; would leave a duplicated Subject free to be changed after the fact.
(test-case "a header that appears twice is signed from the last instance"
  (define two-subjects
    (string-append "From: a@b.test\r\n"
                   "Subject: the real one\r\n"
                   "To: c@d.test\r\n"
                   "Date: Mon, 17 Nov 2026 10:00:00 +0000\r\n"
                   "Subject: what a relay added\r\n"
                   "Message-ID: <x@b.test>\r\n\r\n"))
  (define-values (input unsigned) (dkim-signing-input two-subjects BODY "b.test" "s"))
  (check-true (string-contains? input "subject:what a relay added\r\n"))
  (check-false (string-contains? input "subject:the real one\r\n")))

(test-case "the transport refuses a key that is not a PEM, and a selector that is not a label"
  (check-true (and (transport-problem (hasheq 'host "h.test" 'port 587 'from_address "a@b.test"
                                              'dkim_key "not a key"))
                   #t))
  (check-true (and (transport-problem (hasheq 'host "h.test" 'port 587 'from_address "a@b.test"
                                              'dkim_selector "has.a.dot"))
                   #t))
  (check-false (transport-problem (hasheq 'host "h.test" 'port 587 'from_address "a@b.test"
                                          'dkim_selector "tmach"
                                          'dkim_key "-----BEGIN PRIVATE KEY-----\nxx\n-----END PRIVATE KEY-----"))))

;; ---- the published record -----------------------------------------------------
(test-case "the DNS record is the public key with the armour removed"
  (define dir (tmpdir))
  (define-values (priv pub) (keypair dir))
  (define rec (dkim-public-record priv #:selector "tmach" #:domain "example.test"))
  (check-true (string-prefix? rec "tmach._domainkey.example.test. IN TXT \"v=DKIM1; k=rsa; p="))
  (check-false (string-contains? rec "-----") "the PEM armour is not part of the record")
  (delete-directory/files dir))
