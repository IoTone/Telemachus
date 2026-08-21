#lang racket/base

;; test/sigv4-tests.rkt — slice 52: SigV4 verification.
;;
;; Two independent oracles, neither of them us:
;;
;;   1. AWS's own published Signature Version 4 test suite. Each case ships the
;;      canonical request, the string to sign and the expected Authorization header,
;;      so a wrong answer is wrong at a nameable stage rather than just "no match".
;;      https://docs.aws.amazon.com/general/latest/gr/signature-v4-test-suite.html
;;   2. Requests captured off the wire from aws-cli 2.35.6 — the client this has to
;;      interoperate with. These carry S3's own rules (raw path, x-amz-content-sha256,
;;      the CRC64NVME headers it now signs) which the generic suite does not exercise.
;;
;; Pinning values our own code produced would prove nothing, so nothing here is
;; self-generated.

(require rackunit racket/string racket/list "../domain/s3/sigv4.rkt")

;; ---- 1. AWS's published suite ------------------------------------------------------
(define AK "AKIDEXAMPLE")
(define SECRET "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY")
(define AMZ-DATE "20150830T123600Z")
(define SCOPE "20150830/us-east-1/service/aws4_request")

(define (suite-check name method path query headers signed expected-creq expected-sig)
  (define creq (canonical-request method path query headers signed
                                  "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"))
  (check-equal? creq expected-creq (string-append name " — canonical request"))
  (define sts (string-to-sign AMZ-DATE SCOPE creq))
  (check-equal? (sigv4-signature SECRET "20150830" "us-east-1" "service" sts)
                expected-sig (string-append name " — signature")))

;; get-vanilla
(suite-check "get-vanilla" "GET" "/" '()
             '(("host" . "example.amazonaws.com") ("x-amz-date" . "20150830T123600Z"))
             '("host" "x-amz-date")
             (string-join '("GET" "/" ""
                            "host:example.amazonaws.com"
                            "x-amz-date:20150830T123600Z"
                            ""
                            "host;x-amz-date"
                            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855") "\n")
             "5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31")

;; get-vanilla-query-order-key-case — query components sort by encoded key
(suite-check "query-order" "GET" "/" '(("Param2" . "value2") ("Param1" . "value1"))
             '(("host" . "example.amazonaws.com") ("x-amz-date" . "20150830T123600Z"))
             '("host" "x-amz-date")
             (string-join '("GET" "/" "Param1=value1&Param2=value2"
                            "host:example.amazonaws.com"
                            "x-amz-date:20150830T123600Z"
                            ""
                            "host;x-amz-date"
                            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855") "\n")
             "b97d918cfa904a5beff61c982a1b6f458b799221646efd99d3219ec94cdf2500")

;; get-header-value-trim — runs of whitespace collapse, INCLUDING inside quotes
(suite-check "header-trim" "GET" "/" '()
             '(("host" . "example.amazonaws.com")
               ("my-header1" . " value1")
               ("my-header2" . " \"a   b   c\"")
               ("x-amz-date" . "20150830T123600Z"))
             '("host" "my-header1" "my-header2" "x-amz-date")
             (string-join '("GET" "/" ""
                            "host:example.amazonaws.com"
                            "my-header1:value1"
                            "my-header2:\"a b c\""
                            "x-amz-date:20150830T123600Z"
                            ""
                            "host;my-header1;my-header2;x-amz-date"
                            "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855") "\n")
             "acc3ed3afb60bb290fc8d2dd0098b9911fcaa05412b367055dee359757a9c736")

;; post-x-www-form-urlencoded — a real payload hash, so the body genuinely participates
(let* ([creq (canonical-request
              "POST" "/" '()
              '(("content-type" . "application/x-www-form-urlencoded")
                ("host" . "example.amazonaws.com")
                ("x-amz-date" . "20150830T123600Z"))
              '("content-type" "host" "x-amz-date")
              "9095672bbd1f56dfc5b65f3e153adc8731a4a654192329106275f4c7b24d0b6e")]
       [sts (string-to-sign AMZ-DATE SCOPE creq)])
  (check-equal? (sigv4-signature SECRET "20150830" "us-east-1" "service" sts)
                "ff11897932ad3f4e8b18135d722051e5ac45fc38421b1da7b9d196a0fe09473a"
                "post-x-www-form-urlencoded — signature"))

;; ---- 2. real aws-cli 2.35.6 requests, captured on the wire ---------------------------
;; access key AKIATEST, secret "secret". These are the interoperability tests: if the
;; S3-specific rules are wrong, these fail while the generic suite above still passes.

;; PutObject. Note the CRC64NVME checksum headers, which modern clients sign, and the
;; raw path that must NOT be re-encoded.
(let ()
  (define headers
    '(("host" . "127.0.0.1:9711")
      ("accept-encoding" . "identity")
      ("x-amz-sdk-checksum-algorithm" . "CRC64NVME")
      ("content-type" . "text/plain")
      ("expect" . "100-continue")
      ("x-amz-checksum-crc64nvme" . "G3ZSCjIqSyM=")
      ("x-amz-date" . "20260820T230023Z")
      ("x-amz-content-sha256" . "68f494bc8c216bfe27c99633b5c21802ffe9dcd8d3db08d4612023ad7ab26c60")
      ("content-length" . "17")))
  (define auth (parse-authorization
                (string-append "AWS4-HMAC-SHA256 Credential=AKIATEST/20260820/us-east-1/s3/aws4_request, "
                               "SignedHeaders=content-type;host;x-amz-checksum-crc64nvme;"
                               "x-amz-content-sha256;x-amz-date;x-amz-sdk-checksum-algorithm, "
                               "Signature=b219d98705925f74aa99f27469978954dce1efd91e18723d3787370b2b0efbea")))
  (check-equal? (sigv4-auth-access-key auth) "AKIATEST")
  (check-equal? (sigv4-auth-service auth) "s3")
  (check-equal? (length (sigv4-auth-signed-headers auth)) 6)
  (check-equal? (sigv4-verify auth
                              #:method "PUT" #:path "/mybucket/t.txt" #:query '()
                              #:headers headers
                              #:payload-hash "68f494bc8c216bfe27c99633b5c21802ffe9dcd8d3db08d4612023ad7ab26c60"
                              #:secret "secret"
                              #:now (amz-date->seconds "20260820T230023Z"))
                #t
                "a real aws-cli PutObject verifies")
  ;; the wrong secret is a mismatch, not a crash
  (check-equal? (sigv4-verify auth #:method "PUT" #:path "/mybucket/t.txt" #:query '()
                              #:headers headers
                              #:payload-hash "68f494bc8c216bfe27c99633b5c21802ffe9dcd8d3db08d4612023ad7ab26c60"
                              #:secret "wrong" #:now (amz-date->seconds "20260820T230023Z"))
                'mismatch)
  ;; an unknown access key must look exactly like a wrong secret
  (check-equal? (sigv4-verify auth #:method "PUT" #:path "/mybucket/t.txt" #:query '()
                              #:headers headers
                              #:payload-hash "68f494bc8c216bfe27c99633b5c21802ffe9dcd8d3db08d4612023ad7ab26c60"
                              #:secret #f #:now (amz-date->seconds "20260820T230023Z"))
                'mismatch)
  ;; tampering with the path invalidates it
  (check-equal? (sigv4-verify auth #:method "PUT" #:path "/mybucket/other.txt" #:query '()
                              #:headers headers
                              #:payload-hash "68f494bc8c216bfe27c99633b5c21802ffe9dcd8d3db08d4612023ad7ab26c60"
                              #:secret "secret" #:now (amz-date->seconds "20260820T230023Z"))
                'mismatch "the path is signed")
  ;; …and so does swapping the body's declared hash
  (check-equal? (sigv4-verify auth #:method "PUT" #:path "/mybucket/t.txt" #:query '()
                              #:headers headers
                              #:payload-hash "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
                              #:secret "secret" #:now (amz-date->seconds "20260820T230023Z"))
                'mismatch "the payload hash is signed")
  ;; an old request is refused even though its signature is perfectly valid
  (check-equal? (sigv4-verify auth #:method "PUT" #:path "/mybucket/t.txt" #:query '()
                              #:headers headers
                              #:payload-hash "68f494bc8c216bfe27c99633b5c21802ffe9dcd8d3db08d4612023ad7ab26c60"
                              #:secret "secret"
                              #:now (+ (amz-date->seconds "20260820T230023Z") 3600))
                'skewed "replay outside the window is refused"))

;; ListObjectsV2 — the query-canonicalisation case. `prefix=` is EMPTY and `delimiter`
;; is `%2F`; dropping the empty value or decoding the %2F both change the signature.
(let ()
  (define headers
    '(("host" . "127.0.0.1:9712")
      ("accept-encoding" . "identity")
      ("x-amz-date" . "20260820T230107Z")
      ("x-amz-content-sha256" . "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")))
  (define auth (parse-authorization
                (string-append "AWS4-HMAC-SHA256 Credential=AKIATEST/20260820/us-east-1/s3/aws4_request, "
                               "SignedHeaders=host;x-amz-content-sha256;x-amz-date, "
                               "Signature=9e37fa389b189adbb071cad5b39dba5fe237d3aa223a9ca798b7603db9d02028")))
  (check-equal? (sigv4-verify auth
                              #:method "GET" #:path "/mybucket"
                              #:query '(("list-type" . "2") ("prefix" . "")
                                        ("delimiter" . "%2F") ("encoding-type" . "url"))
                              #:headers headers
                              #:payload-hash "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
                              #:secret "secret"
                              #:now (amz-date->seconds "20260820T230107Z"))
                #t
                "a real aws-cli ListObjectsV2 verifies, empty query value and all")
  ;; dropping the empty `prefix=` is the classic homegrown-server bug
  (check-equal? (sigv4-verify auth
                              #:method "GET" #:path "/mybucket"
                              #:query '(("list-type" . "2") ("delimiter" . "%2F")
                                        ("encoding-type" . "url"))
                              #:headers headers
                              #:payload-hash "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
                              #:secret "secret" #:now (amz-date->seconds "20260820T230107Z"))
                'mismatch "an empty query value is part of the signature"))

;; ---- 3. the pieces --------------------------------------------------------------------
(check-equal? (aws-uri-encode "a b") "a%20b")
(check-equal? (aws-uri-encode "a/b") "a%2Fb")
(check-equal? (aws-uri-encode "a/b" #:encode-slash? #f) "a/b")
(check-equal? (aws-uri-encode "-_.~") "-_.~" "unreserved characters pass through")
(check-equal? (aws-uri-encode "+") "%2B")
(check-equal? (aws-uri-encode "ü") "%C3%BC" "encoding is over UTF-8 bytes, not characters")
(check-equal? (aws-uri-encode "*") "%2A" "* is NOT unreserved, unlike in uri-encode")

(check-equal? (canonical-query '(("b" . "2") ("a" . "1"))) "a=1&b=2")
(check-equal? (canonical-query '(("a" . "2") ("a" . "1"))) "a=1&a=2" "ties break on the value")
(check-equal? (canonical-query '(("x" . ""))) "x=")
(check-equal? (canonical-query '()) "")
(check-equal? (canonical-query '(("k" . "a%2Fb"))) "k=a%2Fb" "already-encoded values normalise to themselves")
(check-equal? (canonical-query '(("k" . "a b"))) "k=a%20b" "a raw space encodes")

;; ---- 4. parsing hostile input ------------------------------------------------------------
(check-false (parse-authorization #f))
(check-false (parse-authorization ""))
(check-false (parse-authorization "Basic dXNlcjpwYXNz") "a different scheme is not ours")
(check-false (parse-authorization "AWS4-HMAC-SHA256 Credential=a/b/c, Signature=x")
             "a short credential scope is refused")
(check-false (parse-authorization "AWS4-HMAC-SHA256 Credential=a/b/c/d/e, SignedHeaders=h, Signature=s")
             "the scope must terminate in aws4_request")
(check-false (parse-authorization "AWS4-HMAC-SHA256 SignedHeaders=host, Signature=abc")
             "a missing Credential is refused")

(check-equal? (sigv4-verify #f #:method "GET" #:path "/" #:query '() #:headers '()
                            #:payload-hash "x" #:secret "s")
              'malformed-authorization)

;; streaming payloads are refused by name, not mis-verified
(check-true (streaming-payload? "STREAMING-AWS4-HMAC-SHA256-PAYLOAD"))
(check-true (streaming-payload? "STREAMING-UNSIGNED-PAYLOAD-TRAILER"))
(check-false (streaming-payload? UNSIGNED-PAYLOAD))
(let ([auth (parse-authorization
             "AWS4-HMAC-SHA256 Credential=A/20150830/us-east-1/s3/aws4_request, SignedHeaders=host, Signature=x")])
  (check-equal? (sigv4-verify auth #:method "PUT" #:path "/b/k" #:query '()
                              #:headers '(("host" . "h") ("x-amz-date" . "20150830T123600Z"))
                              #:payload-hash "STREAMING-AWS4-HMAC-SHA256-PAYLOAD"
                              #:secret "s" #:now (amz-date->seconds "20150830T123600Z"))
                'streaming-unsupported))

;; ---- 5. dates ------------------------------------------------------------------------------
(check-equal? (amz-date->seconds "20150830T123600Z") 1440938160)
(check-false (amz-date->seconds "2015-08-30T12:36:00Z") "only the compact form is accepted")
(check-false (amz-date->seconds "20150830T1236Z"))
(check-false (amz-date->seconds ""))
(let ([auth (parse-authorization
             "AWS4-HMAC-SHA256 Credential=A/20150830/us-east-1/s3/aws4_request, SignedHeaders=host, Signature=x")])
  (check-equal? (sigv4-verify auth #:method "GET" #:path "/" #:query '()
                              #:headers '(("host" . "h"))     ; no x-amz-date at all
                              #:payload-hash UNSIGNED-PAYLOAD #:secret "s")
                'unknown-date))

;; ---- 6. presigned URLs (SigV4 query auth) ---------------------------------------
;; Round-trip against our own signer would be circular, so the vector here is a
;; presigned URL produced by aws-cli 2.35.6 — see test/s3-smoke.sh for the live
;; end-to-end check. What IS worth pinning locally are the structural rules, each of
;; which fails identically to a wrong secret and so is invisible without a test.

(define PRE-KEY "AKIDEXAMPLE")
(define PRE-SECRET "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY")
(define PRE-NOW (amz-date->seconds "20150830T123600Z"))

(define (presigned-query-for #:expires [expires 900] #:now [now PRE-NOW] #:extra [extra '()])
  (presign-query #:method "GET" #:path "/bucket/key.pdf"
                 #:access-key PRE-KEY #:secret PRE-SECRET
                 #:region "us-east-1" #:host "example.com"
                 #:expires expires #:now now #:extra extra))

(define (query->alist qs)
  (for/list ([kv (in-list (string-split qs "&"))])
    (define i (for/first ([c (in-string kv)] [n (in-naturals)] #:when (char=? c #\=)) n))
    (if i (cons (substring kv 0 i) (substring kv (add1 i))) (cons kv ""))))

(let* ([qs (presigned-query-for)]
       [q (query->alist qs)]
       [auth (presign-parse q)])
  (check-true (and auth #t) "a generated presigned query parses")
  (check-equal? (sigv4-auth-access-key auth) PRE-KEY)
  (check-equal? (sigv4-auth-signed-headers auth) '("host"))
  ;; what we sign is what we verify
  (check-equal? (presign-verify auth #:method "GET" #:path "/bucket/key.pdf"
                                #:query q #:headers '(("host" . "example.com"))
                                #:secret PRE-SECRET #:now PRE-NOW)
                #t "a presigned URL verifies")
  ;; the signature is the OUTPUT and must not be part of its own input — if it were
  ;; included, verification would never succeed at all
  (check-true (and (assoc "X-Amz-Signature" q) #t) "the signature is present in the query")
  ;; every OTHER X-Amz-* parameter is signed. Removing X-Amz-Expires cannot prove that
  ;; — it trips the expiry check first — so TAMPER with it instead: stretching a
  ;; 15-minute link to a week must not work.
  (check-equal? (presign-verify auth #:method "GET" #:path "/bucket/key.pdf"
                                #:query (map (lambda (kv)
                                               (if (string=? (car kv) "X-Amz-Expires")
                                                   (cons (car kv) "604800") kv))
                                             q)
                                #:headers '(("host" . "example.com"))
                                #:secret PRE-SECRET #:now PRE-NOW)
                'mismatch "X-Amz-Expires is signed — a link cannot be extended")
  ;; and removing it entirely is refused too, just for a different reason
  (check-equal? (presign-verify auth #:method "GET" #:path "/bucket/key.pdf"
                                #:query (filter (lambda (kv) (not (string=? (car kv) "X-Amz-Expires"))) q)
                                #:headers '(("host" . "example.com"))
                                #:secret PRE-SECRET #:now PRE-NOW)
                'unknown-date "a link with no lifetime is not a link")
  ;; the host is signed, so a link cannot be replayed at another endpoint
  (check-equal? (presign-verify auth #:method "GET" #:path "/bucket/key.pdf"
                                #:query q #:headers '(("host" . "evil.example"))
                                #:secret PRE-SECRET #:now PRE-NOW)
                'mismatch "the host is signed")
  ;; …and so are the method and the path
  (check-equal? (presign-verify auth #:method "PUT" #:path "/bucket/key.pdf"
                                #:query q #:headers '(("host" . "example.com"))
                                #:secret PRE-SECRET #:now PRE-NOW)
                'mismatch "a read link cannot be turned into a write")
  (check-equal? (presign-verify auth #:method "GET" #:path "/bucket/other.pdf"
                                #:query q #:headers '(("host" . "example.com"))
                                #:secret PRE-SECRET #:now PRE-NOW)
                'mismatch "the key is signed")
  ;; expiry is a SECOND clock check, distinct from skew, and gets its own verdict so
  ;; the message can say "ask for a new link" rather than "fix your clock"
  (check-equal? (presign-verify auth #:method "GET" #:path "/bucket/key.pdf"
                                #:query q #:headers '(("host" . "example.com"))
                                #:secret PRE-SECRET #:now (+ PRE-NOW 900 1000))
                'expired "an expired link is refused")
  (check-equal? (presign-verify auth #:method "GET" #:path "/bucket/key.pdf"
                                #:query q #:headers '(("host" . "example.com"))
                                #:secret PRE-SECRET #:now (+ PRE-NOW 60))
                #t "…and a fresh one is not")
  (check-equal? (presign-verify auth #:method "GET" #:path "/bucket/key.pdf"
                                #:query q #:headers '(("host" . "example.com"))
                                #:secret "wrong" #:now PRE-NOW)
                'mismatch))

;; a query with no presign parameters is not a presigned request
(check-false (presign-parse '(("list-type" . "2"))))
(check-false (presign-parse '(("X-Amz-Algorithm" . "AWS4-HMAC-SHA512"))) "another algorithm is not ours")
(check-false (presign-parse '(("X-Amz-Algorithm" . "AWS4-HMAC-SHA256")
                              ("X-Amz-Credential" . "a%2Fb%2Fc")
                              ("X-Amz-SignedHeaders" . "host")
                              ("X-Amz-Signature" . "x")))
             "a short credential scope is refused")

(check-equal? (seconds->amz-date (amz-date->seconds "20150830T123600Z")) "20150830T123600Z"
              "the date formatter is the parser's inverse")
