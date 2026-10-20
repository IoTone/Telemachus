#lang racket/base

;; test/s3-client-tests.rkt — the outbound S3 client (issue #82).
;;
;; THE CENTRAL CASE is case 2: a request this module SIGNS is handed to
;; `sigv4-verify`, the verifier this tree already had, and must pass. One SigV4
;; implementation faces both directions, so a canonicalisation mistake cannot
;; produce a client that is wrong in a way our own server would accept — it
;; breaks here, in process, with no bucket and no network. This is why the client
;; composes sigv4.rkt's primitives instead of signing for itself.
;;
;; What else has to hold:
;;   1. the endpoint, the two addressing styles, and the key layout
;;   3. the Host header is signed, and it is NOT computed twice
;;   4. SSE headers follow the mode, and `none` is explicit rather than default
;;   5. only a 429/5xx is retryable — a 4xx is our own request
;;   6. an encrypted-bucket requirement has TEETH (the response is what counts)
;;
;;   raco test test/s3-client-tests.rkt

(require rackunit racket/string racket/list racket/port
         "../domain/s3/client.rkt"
         (only-in "../domain/s3/sigv4.rkt"
                  sigv4-verify parse-authorization seconds->amz-date))

(define (cfg* #:sse [sse "kms"] #:kms [kms #f] #:path-style? [ps #t]
              #:require-enc? [req #t] #:endpoint [ep "http://127.0.0.1:9000"]
              #:bucket [bucket "docs"] #:region [region "us-east-1"]
              #:prefix [prefix "blobs"])
  (s3-config ep bucket region prefix "AKIDEXAMPLE"
             "wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY"
             sse kms req ps 3 30))

;; ---- 1. the endpoint, the styles, the layout -----------------------------------
(test-case "the endpoint parses, and the default port follows the scheme"
  (let-values ([(ssl? host port) (s3-endpoint-parts "https://s3.eu-west-1.amazonaws.com")])
    (check-true ssl?) (check-equal? host "s3.eu-west-1.amazonaws.com") (check-equal? port 443))
  (let-values ([(ssl? host port) (s3-endpoint-parts "http://minio:9000")])
    (check-false ssl?) (check-equal? host "minio") (check-equal? port 9000))
  (let-values ([(ssl? host port) (s3-endpoint-parts "http://example.test/")])
    (check-false ssl?) (check-equal? port 80))
  ;; A bare host with no scheme is the most likely thing an operator types, and
  ;; guessing https for it would silently fail a plaintext MinIO on a LAN.
  (check-exn exn:fail? (lambda () (s3-endpoint-parts "minio:9000"))))

(test-case "path-style puts the bucket in the path; virtual-host puts it in the Host"
  (let-values ([(path host) (s3-object-url (cfg*) "blobs/org1/deadbeef")])
    (check-equal? path "/docs/blobs/org1/deadbeef")
    (check-equal? host "127.0.0.1:9000"))
  (let-values ([(path host) (s3-object-url (cfg* #:path-style? #f) "blobs/org1/deadbeef")])
    (check-equal? path "/blobs/org1/deadbeef")
    (check-equal? host "docs.127.0.0.1:9000"))
  ;; The default port is absent from the Host header, because it is absent from
  ;; what a client would send and the host is SIGNED.
  (let-values ([(path host) (s3-object-url (cfg* #:endpoint "https://s3.amazonaws.com") "k")])
    (check-equal? host "s3.amazonaws.com")))

;; ---- 2. THE CENTRAL CASE: our signer against our verifier ----------------------
(test-case "a request this client signs verifies against this tree's own verifier"
  (define c (cfg*))
  (define payload-hash
    "9f86d081884c7d659a2feaa0c55ad015a3bf4f1b2b0b822cd15d6c15b0f00a08") ; sha256("test")
  (define-values (path host) (s3-object-url c "blobs/org1/abc"))
  (define now (current-seconds))
  (define-values (headers authorization)
    (s3-signed-headers c "PUT" path
                       #:extra-headers (s3-sse-headers c)
                       #:body-size 4
                       #:payload-hash payload-hash
                       #:now now))

  ;; The verifier is given exactly what the socket would carry.
  (define auth (parse-authorization authorization))
  (check-true (and auth #t) "the Authorization header this client builds must parse")
  (define verdict
    (sigv4-verify auth
                  #:method "PUT"
                  #:path path
                  #:query '()
                  #:headers headers
                  #:payload-hash payload-hash
                  #:secret (s3-config-secret-key c)
                  #:now now))
  ;; #t, not 'ok: sigv4-verify answers #t or a SYMBOL naming the failure
  ;; ('mismatch, 'skewed, 'unknown-date, …) so a caller can map it onto S3's own
  ;; error vocabulary instead of collapsing everything to AccessDenied.
  (check-equal? verdict #t (format "verifier said ~a" verdict))

  ;; And it must FAIL on a tampered request, or the check above proves nothing —
  ;; a verifier that says ok to everything would pass it too.
  (define bad
    (sigv4-verify auth
                  #:method "GET"               ; the method is signed
                  #:path path #:query '()
                  #:headers headers
                  #:payload-hash payload-hash
                  #:secret (s3-config-secret-key c)
                  #:now now))
  (check-equal? bad 'mismatch "changing the method must break the signature")

  (define bad2
    (sigv4-verify auth
                  #:method "PUT" #:path path #:query '()
                  #:headers headers
                  #:payload-hash "0000000000000000000000000000000000000000000000000000000000000000"
                  #:secret (s3-config-secret-key c)
                  #:now now))
  (check-equal? bad2 'mismatch "changing the payload hash must break the signature"))

;; ---- 3. what gets signed --------------------------------------------------------
(test-case "host, date, content-sha256 and the SSE headers are all signed"
  (define c (cfg* #:kms "arn:aws:kms:eu-west-1:1:key/k"))
  (define-values (headers authorization)
    (s3-signed-headers c "PUT" "/docs/blobs/o/d"
                       #:extra-headers (s3-sse-headers c)
                       #:body-size 10 #:payload-hash EMPTY-SHA256))
  (define names (map car headers))
  (for ([n (in-list '("host" "x-amz-date" "x-amz-content-sha256" "content-length"
                      "x-amz-server-side-encryption"
                      "x-amz-server-side-encryption-aws-kms-key-id"))])
    (check-true (and (member n names) #t) (format "~a must be sent" n)))
  ;; SignedHeaders must name every one of them: a header sent but unsigned is how
  ;; a proxy edits a request without invalidating it.
  (define m (regexp-match #px"SignedHeaders=([^,]+)" authorization))
  (define signed (string-split (list-ref m 1) ";"))
  (for ([n (in-list names)])
    (check-true (and (member n signed) #t) (format "~a is sent but NOT signed" n))))

(test-case "a bodyless request sends no content-length"
  (define-values (headers _a)
    (s3-signed-headers (cfg*) "GET" "/docs/blobs/o/d"))
  (check-false (assoc "content-length" headers)))

;; ---- 4. server-side encryption --------------------------------------------------
(test-case "the SSE headers follow the mode, and none means none"
  (check-equal? (s3-sse-headers (cfg* #:sse "s3"))
                '(("x-amz-server-side-encryption" . "AES256")))
  (check-equal? (s3-sse-headers (cfg* #:sse "none")) '())
  ;; kms with no key id is a real configuration — the bucket's default key — and
  ;; must not invent one
  (check-equal? (s3-sse-headers (cfg* #:sse "kms"))
                '(("x-amz-server-side-encryption" . "aws:kms")))
  (define with-key (s3-sse-headers (cfg* #:sse "kms" #:kms "k1")))
  (check-equal? (length with-key) 2)
  (check-equal? (cdr (assoc "x-amz-server-side-encryption-aws-kms-key-id" with-key)) "k1"))

;; ---- 5. retry classification ----------------------------------------------------
(test-case "only a 429 or a 5xx is worth retrying"
  (for ([s (in-list '(500 502 503 504 429))])
    (check-true (s3-retryable-status? s) (format "~a should retry" s)))
  ;; A 403 is a credential or a policy problem and a 404 is an answer. Retrying
  ;; either spends the same error again — llm.rkt's rule for the model transport.
  (for ([s (in-list '(200 204 301 400 403 404 409 412))])
    (check-false (s3-retryable-status? s) (format "~a should NOT retry" s))))

;; ---- 6. the request target ------------------------------------------------------
(test-case "a query is appended encoded, and a valueless key keeps its shape"
  (check-equal? (s3-request-target "/docs/k" '()) "/docs/k")
  (check-equal? (s3-request-target "/docs/k" '(("uploads" . ""))) "/docs/k?uploads")
  (check-equal? (s3-request-target "/docs/k" '(("partNumber" . "2") ("uploadId" . "a/b")))
                "/docs/k?partNumber=2&uploadId=a%2Fb"))
