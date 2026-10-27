#lang racket/base

;; domain/s3/client.rkt — an outbound S3 client, for the blob store (issue #82).
;;
;; The SIGNING IS NOT NEW CODE. `sigv4.rkt` was built from the spec to VERIFY
;; what clients send us, and every primitive a signer needs is already exported
;; from it and already pinned to AWS's own published vectors by 64 cases in
;; test/sigv4-tests.rkt. So this module composes those primitives rather than
;; writing a second SigV4, which means one implementation faces both directions:
;; a canonicalisation bug would break our server AND our client, loudly, instead
;; of letting two subtly different implementations agree with nobody.
;;
;; WHY A RAW SOCKET rather than net/http-client. `http-conn-send!`'s #:data takes
;; bytes (buffer the whole object — a 2 GB document is the case this store exists
;; for) or a procedure, which makes the request CHUNKED. S3 rejects chunked
;; unless it is `aws-chunked` with per-chunk signatures, which sigv4.rkt
;; explicitly refuses to implement on the server side for want of a client that
;; uses it. A plain socket lets us send Content-Length and stream the body, which
;; is what requirement 5 asks for.
;;
;; THE PAYLOAD HASH IS FREE, and that is the whole reason a single pass works. A
;; signed S3 PUT must carry `x-amz-content-sha256`, the SHA-256 of the body —
;; normally either buffer the object to compute it, or give up signing the
;; payload (UNSIGNED-PAYLOAD) and lean on TLS. In a CONTENT-ADDRESSED store the
;; digest we are handed IS that hash, by construction. So the body streams once,
;; unbuffered, fully signed. It also means every write is integrity-checked by
;; the far end for nothing: if our digest disagrees with our bytes, S3 answers
;; XAmzContentSHA256Mismatch instead of silently storing a mislabelled blob.

(require racket/port racket/string racket/list racket/tcp openssl
         (only-in "sigv4.rkt"
                  aws-uri-encode canonical-request string-to-sign sigv4-signature
                  canonical-headers signed-headers-of seconds->amz-date)
         sha2-kit)

(provide (struct-out s3-config) s3-endpoint-parts s3-object-url
         s3-signed-headers s3-request-target
         s3-put-stream s3-get-stream s3-head s3-delete
         (struct-out exn:fail:s3) s3-retryable-status? s3-sse-headers
         EMPTY-SHA256)

;; `require-encryption?` is separate from `sse` on purpose: an operator may run
;; SSE-S3 and still want the instance to refuse if a response comes back WITHOUT
;; the header, which is the check that catches a bucket policy quietly dropping
;; it (requirement 2).
(struct s3-config
  (endpoint bucket region prefix access-key secret-key
   sse kms-key-id require-encryption? path-style? retries timeout)
  #:transparent)

(struct exn:fail:s3 exn:fail (status code) #:transparent)

(define (s3-error status code fmt . args)
  (raise (exn:fail:s3 (apply format fmt args) (current-continuation-marks) status code)))

;; ---- the endpoint ---------------------------------------------------------------
;; -> (values ssl? host port)
(define (s3-endpoint-parts endpoint)
  (define m (regexp-match #px"^(https?)://([^/:]+)(?::([0-9]+))?/?$" endpoint))
  (unless m (error 's3-client "TMACH_S3_BLOB_ENDPOINT must be http(s)://host[:port], got ~s" endpoint))
  (define ssl? (string=? (list-ref m 1) "https"))
  (values ssl? (list-ref m 2)
          (cond [(list-ref m 3) (string->number (list-ref m 3))] [ssl? 443] [else 80])))

;; The Host header the request will carry — path-style leaves it as the endpoint,
;; virtual-host style prefixes the bucket. Signed, so it has to match what the
;; socket actually sends.
(define (s3-host-header cfg)
  (define-values (ssl? host port) (s3-endpoint-parts (s3-config-endpoint cfg)))
  (define hostport (if (or (and ssl? (= port 443)) (and (not ssl?) (= port 80)))
                       host
                       (format "~a:~a" host port)))
  (if (s3-config-path-style? cfg) hostport (string-append (s3-config-bucket cfg) "." hostport)))

;; The request target and the Host header, which differ between the two
;; addressing styles. Path-style is the DEFAULT here, unlike the AWS SDKs: MinIO
;; and Ceph RGW are the deployments this store exists for and neither gets
;; virtual-host DNS for free, while AWS still accepts path-style.
;; -> (values path host-header)
(define (s3-object-url cfg key)
  ;; The Host header comes from s3-host-header and is NOT recomputed here. Two
  ;; copies of this would drift, and because the host is a SIGNED header the
  ;; failure mode would be every request answered SignatureDoesNotMatch with
  ;; nothing in the message pointing at which copy was wrong.
  (define host-header (s3-host-header cfg))
  ;; Each SEGMENT is encoded; the slashes between them are structure, not data.
  ;; aws-uri-encode with #:encode-slash? #f on the whole key would also leave a
  ;; literal "../" intact, and the digest whitelist upstream is what makes that
  ;; moot rather than this encoding.
  (define enc (string-join (for/list ([seg (in-list (string-split key "/"))])
                             (aws-uri-encode seg))
                           "/"))
  (if (s3-config-path-style? cfg)
      (values (string-append "/" (aws-uri-encode (s3-config-bucket cfg)) "/" enc) host-header)
      (values (string-append "/" enc) host-header)))

;; ---- server-side encryption (requirement 2) -------------------------------------
;; SSE-KMS is the default. `none` is accepted and is NOT the default, because the
;; integrators this store is for are the reason it exists; an operator who means
;; to store plaintext says so.
(define (s3-sse-headers cfg)
  (case (s3-config-sse cfg)
    [("kms")
     (append (list (cons "x-amz-server-side-encryption" "aws:kms"))
             (let ([k (s3-config-kms-key-id cfg)])
               (if (and k (not (string=? k "")))
                   (list (cons "x-amz-server-side-encryption-aws-kms-key-id" k))
                   ;; No key id = the bucket's default KMS key, which is a real
                   ;; and supported configuration — not an error to omit.
                   '())))]
    [("s3") (list (cons "x-amz-server-side-encryption" "AES256"))]
    [else '()]))

;; ---- retries --------------------------------------------------------------------
;; A 5xx or a 429 is the far end asking us to come back; a 4xx is our own request
;; and retrying it only spends the same error again. Same rule, and the same
;; reasoning, as the model transport in domain/agent/llm.rkt.
(define (s3-retryable-status? status)
  (or (= status 429) (and (>= status 500) (< status 600))))

(define (backoff-sleep attempt)
  ;; 0.2s, 0.4s, 0.8s … bounded. Deterministic rather than jittered: one process
  ;; writing one blob is not a thundering herd, and a fixed schedule is testable.
  (sleep (min 2.0 (* 0.2 (expt 2 (max 0 (sub1 attempt)))))))

;; ---- the request ----------------------------------------------------------------
;; Returns (values status headers body-port). The body port is LIVE on the socket
;; and the caller must close it — that is what makes a GET stream rather than
;; buffer. `close-connection!` rides along on the port via make-limited-input-port's
;; close-orig? flag.
;;
;; `payload-hash` is the hex SHA-256 of the body. For a blob PUT it is the digest,
;; already known (see the header). For a bodyless request it is the hash of "".
(define EMPTY-SHA256 "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")

;; PURE, and that is the point: it does no I/O, so test/s3-client-tests.rkt can
;; hand what it returns straight to `sigv4-verify` — this module's signer checked
;; against this tree's own verifier, in process, with no bucket and no network.
;; One SigV4 implementation facing both directions is the whole reuse argument in
;; the module header, and this is where it is actually demonstrated.
;;
;; Returns (values signed-headers authorization-header-value). `now` is a
;; parameter so a test can pin the date and get a byte-stable signature.
(define (s3-signed-headers cfg method path
                           #:query [query '()]
                           #:extra-headers [extra '()]
                           #:body-size [body-size 0]
                           #:payload-hash [payload-hash EMPTY-SHA256]
                           #:now [now (current-seconds)])
  (define host-header (s3-host-header cfg))
  (define amz-date (seconds->amz-date now))
  (define date8 (substring amz-date 0 8))
  (define region (s3-config-region cfg))
  (define scope (string-join (list date8 region "s3" "aws4_request") "/"))
  ;; EVERY header we send is signed. Signing a subset is legal, and is exactly
  ;; how a proxy-inserted header changes a request without breaking its
  ;; signature; there is no reason to permit that here.
  (define base
    (append (list (cons "host" host-header)
                  (cons "x-amz-content-sha256" payload-hash)
                  (cons "x-amz-date" amz-date))
            (if (> body-size 0) (list (cons "content-length" (number->string body-size))) '())
            (for/list ([kv (in-list extra)]) (cons (string-downcase (car kv)) (cdr kv)))))
  (define signed-names (sort (remove-duplicates (map car base)) string<?))
  (define creq (canonical-request method path query base signed-names payload-hash))
  (define sts (string-to-sign amz-date scope creq))
  (define sig (sigv4-signature (s3-config-secret-key cfg) date8 region "s3" sts))
  (values base
          (format "AWS4-HMAC-SHA256 Credential=~a/~a, SignedHeaders=~a, Signature=~a"
                  (s3-config-access-key cfg) scope (signed-headers-of signed-names) sig)))

(define (s3-request-target path query)
  (if (null? query)
      path
      (string-append path "?"
                     (string-join (for/list ([kv (in-list query)])
                                    (if (string=? (cdr kv) "")
                                        (aws-uri-encode (car kv))
                                        (string-append (aws-uri-encode (car kv)) "="
                                                       (aws-uri-encode (cdr kv)))))
                                  "&"))))

(define (s3-send cfg method key
                 #:query [query '()]
                 #:extra-headers [extra '()]
                 #:body [body #f]            ; input port, or #f
                 #:body-size [body-size 0]
                 #:payload-hash [payload-hash EMPTY-SHA256])
  (define-values (path host-header) (s3-object-url cfg key))
  (define-values (ssl? host port) (s3-endpoint-parts (s3-config-endpoint cfg)))
  (define-values (base authorization)
    (s3-signed-headers cfg method path
                       #:query query
                       #:extra-headers extra
                       #:body-size (if body body-size 0)
                       #:payload-hash payload-hash))
  (define target (s3-request-target path query))
  (define-values (in out)
    (if ssl? (ssl-connect host port 'auto) (tcp-connect host port)))
  (with-handlers ([(lambda (_) #t)
                   (lambda (e) (close-output-port out) (close-input-port in) (raise e))])
    (fprintf out "~a ~a HTTP/1.1\r\n" (string-upcase method) target)
    (for ([kv (in-list base)]) (fprintf out "~a: ~a\r\n" (car kv) (cdr kv)))
    (fprintf out "authorization: ~a\r\n" authorization)
    ;; NO KEEP-ALIVE: one connection per operation, so a put! that HEADs first
    ;; costs two. That is a real cost and it is chosen — a pooled connection
    ;; would need its own lifecycle, and the body of a blob PUT is the expensive
    ;; part by orders of magnitude. `connection: close` also means the far end
    ;; frames the response by Content-Length or by closing, which is what makes
    ;; the response reader above as simple as it is.
    (fprintf out "connection: close\r\n\r\n")
    (flush-output out)
    (when body
      (copy-port body out)
      (flush-output out))
    ;; `out` is deliberately NOT closed here, and it IS returned so the caller
    ;; can close it. Closing it now would, under TLS, tear the session down
    ;; before the response is read; leaving it unreferenced leaks a descriptor on
    ;; every successful request — the measured mistake llm.rkt documents for
    ;; `http-sendrecv`, and one this code made until the leak was traced. Every
    ;; caller below closes both ports, or hands both to `streamed-body`.
    (define status (read-status-line in))
    (define headers (read-headers in))
    (values status headers in out)))

;; A GET's body as a port the CALLER owns, with the socket closed deterministically.
;;
;; The socket's input port cannot simply be handed out: closing it would leave
;; `out` open and nothing the caller does can reach `out`. So the body is copied
;; into a BOUNDED pipe by a thread that closes the socket on its way out.
;; Bounded is the point — an unbounded pipe would buffer the whole object in
;; memory, which is what this store exists to avoid. At this size the copy blocks
;; until the reader consumes, so the stream keeps its backpressure.
;;
;; A caller that closes early is handled: `copy-port` then raises writing to a
;; closed pipe, the handler swallows it, and the socket is closed regardless.
(define PIPE-BYTES (* 1024 1024))

(define (streamed-body in out len)
  (define-values (pin pout) (make-pipe PIPE-BYTES))
  (thread
   (lambda ()
     (with-handlers ([(lambda (_) #t) void])
       (copy-port (if len (make-limited-input-port in len #f) in) pout))
     (with-handlers ([(lambda (_) #t) void]) (close-output-port pout))
     (with-handlers ([(lambda (_) #t) void]) (close-input-port in))
     (with-handlers ([(lambda (_) #t) void]) (close-output-port out))))
  pin)

(define (read-status-line in)
  (define l (read-line in 'return-linefeed))
  (when (eof-object? l) (s3-error 0 "no-response" "the endpoint closed the connection without a response"))
  (define m (regexp-match #px"^HTTP/1\\.[01] ([0-9]{3})" l))
  (unless m (s3-error 0 "bad-response" "not an HTTP response: ~s" l))
  (string->number (list-ref m 1)))

(define (read-headers in)
  (let loop ([acc '()])
    (define l (read-line in 'return-linefeed))
    (cond
      [(or (eof-object? l) (string=? l "")) (reverse acc)]
      [else
       (define i (let loop2 ([j 0]) (cond [(>= j (string-length l)) #f]
                                          [(char=? (string-ref l j) #\:) j]
                                          [else (loop2 (add1 j))])))
       (loop (if i
                 (cons (cons (string-downcase (substring l 0 i))
                             (string-trim (substring l (add1 i))))
                       acc)
                 acc))])))

(define (header-ref headers name [default #f])
  (cond [(assoc (string-downcase name) headers) => cdr] [else default]))

;; A failure's BODY is where S3 puts the reason (an <Error><Code> document), and
;; discarding it turns every misconfiguration into a bare status number. The code
;; is lifted out so a caller can branch on it without parsing XML.
(define (drain-error status headers in)
  (define body (with-handlers ([(lambda (_) #t) (lambda (_) "")])
                 (let ([s (port->string in)]) (if (> (string-length s) 2000) (substring s 0 2000) s))))
  (close-input-port in)
  (define code (let ([m (regexp-match #px"<Code>([^<]+)</Code>" body)])
                 (if m (list-ref m 1) "")))
  (values code body))

;; ---- the four operations --------------------------------------------------------
;; Each retries the whole attempt, which is safe because every one of them is
;; IDEMPOTENT: a content-addressed PUT writes bytes whose name is their hash, and
;; GET/HEAD/DELETE are idempotent by definition. Nothing here needs an
;; idempotency key (#90) to be retried safely.
(define (with-retries cfg who thunk)
  (define tries (max 1 (s3-config-retries cfg)))
  (let loop ([attempt 1])
    (define-values (ok? result)
      (with-handlers ([exn:fail:s3?
                       (lambda (e)
                         (if (and (< attempt tries) (s3-retryable-status? (exn:fail:s3-status e)))
                             (values #f e)
                             (raise e)))]
                      [exn:fail?
                       (lambda (e)
                         ;; A refused connection or a reset mid-handshake. Not a
                         ;; mid-STREAM failure: a GET that has begun handing bytes
                         ;; to its caller is never retried, the rule llm.rkt sets
                         ;; for a streamed model reply.
                         (if (< attempt tries) (values #f e) (raise e)))])
        (values #t (thunk))))
    (cond [ok? result]
          [else (backoff-sleep attempt) (loop (add1 attempt))])))

;; A streaming, fully signed PUT. `digest` is both the key's last segment and the
;; payload hash — see the module header.
;; NOT RETRIED, and this is the rule llm.rkt already states for a streamed model
;; reply: once bytes have left, replaying is not a recovery.
;;
;; The reason here is concrete rather than stylistic. `in` is a ONE-SHOT input
;; port — a socket, or a blob being read out of another store — so a second
;; attempt would find it at EOF and send ZERO bytes while Content-Length promised
;; `size` of them. The far end then waits for a body that never arrives, so the
;; failure a retry produces is a HANG, which is strictly worse than the 500 it
;; was trying to paper over. (This function was wrapped in `with-retries` when it
;; was written, which would have done exactly that.)
;;
;; What to do instead is caller-shaped, and both callers already have an answer:
;; repo-put! is driven by a request that can be made again, and
;; cli/telemachus-blobs.rkt opens each file per blob and is resumable, so
;; re-running `migrate` IS the retry. A retrying write would need the body as a
;; re-openable thunk rather than a port, which is a seam change (DOC-5) and not
;; this slice's to make.
(define (s3-put-stream cfg key in size digest)
  (let ()
    (define-values (status headers body out)
      (s3-send cfg "PUT" key
               #:extra-headers (s3-sse-headers cfg)
               #:body in #:body-size size #:payload-hash digest))
    (define (done!) (close-input-port body) (close-output-port out))
    (cond
      [(and (>= status 200) (< status 300))
       (done!)
       ;; Requirement 2's teeth. The bucket, not us, decides what it stored, so
       ;; the ANSWER is what gets checked — a bucket policy or a replication
       ;; rule that drops encryption is invisible in the request we sent.
       ;; The object HAS LANDED by the time we can check this, and it is left
       ;; where it is rather than deleted. The response is the only source of
       ;; truth about what the bucket did, so there is no way to check before
       ;; writing; and quietly deleting an object we have just been told we do
       ;; not understand would destroy the evidence an operator needs to see
       ;; what their bucket policy actually did. So: refuse loudly, say the
       ;; object exists, and let them look.
       (when (s3-config-require-encryption? cfg)
         (define got (header-ref headers "x-amz-server-side-encryption"))
         (unless got
           (s3-error status "unencrypted"
                     (string-append "the bucket stored ~a WITHOUT reporting server-side "
                                    "encryption, and TMACH_S3_BLOB_REQUIRE_ENCRYPTION is on. "
                                    "The object exists and may be in plaintext — it is left in "
                                    "place deliberately so you can inspect it. Check the bucket's "
                                    "default encryption and any policy that strips the header, or "
                                    "set TMACH_S3_BLOB_SSE=none if plaintext is intended.")
                     key)))
       (void)]
      [else
       (define-values (code text) (drain-error status headers body))
       (close-output-port out)
       (s3-error status code "PUT ~a failed: ~a ~a~a" key status code
                 (if (string=? text "") "" (format " — ~a" text)))])))

;; -> input port, or #f for a miss. The port is live on the socket; the caller
;; closes it. A 404 is NOT an error here: the seam's contract is that `get`
;; answers #f for a missing blob (DOC-5), and repo.rkt's callers distinguish a
;; miss from a refusal on that basis.
(define (s3-get-stream cfg key)
  (with-retries cfg 'get
    (lambda ()
      (define-values (status headers body out) (s3-send cfg "GET" key))
      (cond
        [(and (>= status 200) (< status 300))
         ;; A CHUNKED response is REFUSED rather than read. This reader frames the
         ;; body by Content-Length or by the connection closing, so chunked bytes
         ;; would be handed back WITH their framing — a blob silently corrupted
         ;; by its own length prefixes, which is the worst failure this store can
         ;; have, and one that would survive as far as a digest check. S3 itself
         ;; does not chunk a GET response; an intermediary can, so this answers by
         ;; name instead of de-framing a case no bucket produces.
         (when (header-ref headers "transfer-encoding")
           (close-input-port body) (close-output-port out)
           (s3-error status "chunked-response"
                     (string-append "GET ~a came back with Transfer-Encoding: ~a. This client "
                                    "frames a body by Content-Length, so reading it would "
                                    "corrupt the blob — refusing instead. Something between "
                                    "here and the bucket is re-framing responses.")
                     key (header-ref headers "transfer-encoding")))
         (define len (let ([v (header-ref headers "content-length")])
                       (and v (string->number v))))
         (streamed-body body out len)]
        [(= status 404) (close-input-port body) (close-output-port out) #f]
        [else
         (define-values (code text) (drain-error status headers body))
         (close-output-port out)
         (s3-error status code "GET ~a failed: ~a ~a" key status code)]))))

;; -> size, or #f for a miss
(define (s3-head cfg key)
  (with-retries cfg 'head
    (lambda ()
      (define-values (status headers body out) (s3-send cfg "HEAD" key))
      (close-input-port body) (close-output-port out)
      (cond
        [(and (>= status 200) (< status 300))
         (let ([v (header-ref headers "content-length")]) (and v (string->number v)))]
        [(= status 404) #f]
        [else (s3-error status "" "HEAD ~a failed: ~a" key status)]))))

(define (s3-delete cfg key)
  (with-retries cfg 'delete
    (lambda ()
      (define-values (status headers body out) (s3-send cfg "DELETE" key))
      (cond
        ;; 204 is the success; 404 is already-gone, which for a delete is the
        ;; same outcome and must not raise — the seam's delete is idempotent and
        ;; the reaper calls it on blobs it may have already removed.
        [(or (and (>= status 200) (< status 300)) (= status 404))
         (close-input-port body) (close-output-port out) (void)]
        [else
         (define-values (code text) (drain-error status headers body))
         (close-output-port out)
         (s3-error status code "DELETE ~a failed: ~a ~a" key status code)]))))
