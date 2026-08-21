#lang racket/base

;; domain/s3/sigv4.rkt — AWS Signature Version 4, the verifying half.
;;
;; Written from the published specification and pinned to AWS's own test vectors
;; (test/sigv4-tests.rkt) plus real requests captured off the wire from
;; aws-cli 2.35.6. Deliberately NOT ported from an existing implementation: the
;; algorithm is public and the vectors make correctness objective, whereas a port
;; would put Apache-2.0 code in an MIT repository for no benefit. See DOC-16.
;;
;; Client libraries sign; this verifies. They are not the same job — a verifier
;; must reconstruct the canonical request from what actually arrived, including the
;; parts a signer had the luxury of choosing.
;;
;; TWO S3-SPECIFIC RULES that differ from the generic SigV4 suite, and that a
;; generic implementation gets wrong against real S3 clients:
;;
;;   1. The path is used AS RECEIVED — not re-encoded, not normalized. S3 sets
;;      `disableDoubleEncoding`, and a key legitimately contains `%2F` or `..`
;;      which normalization would destroy. This is why web-kit/http1 hands us the
;;      raw percent-encoded path.
;;   2. The payload hash comes from `x-amz-content-sha256` and is used verbatim in
;;      the canonical request, including the literal words `UNSIGNED-PAYLOAD` and
;;      `STREAMING-*`. Verifying the signature must never require reading the body:
;;      the client is often still waiting on our 100-continue to send it.

(require racket/string racket/list racket/date
         "../authz/sha2.rkt")

(provide (struct-out sigv4-auth)
         parse-authorization
         aws-uri-encode canonical-query canonical-headers signed-headers-of
         canonical-request string-to-sign signing-key sigv4-signature
         sigv4-verify amz-date->seconds
         presign-parse presign-verify presign-query
         UNSIGNED-PAYLOAD MAX-SKEW-SECONDS streaming-payload? seconds->amz-date)

(define ALGORITHM "AWS4-HMAC-SHA256")
(define UNSIGNED-PAYLOAD "UNSIGNED-PAYLOAD")
(define MAX-SKEW-SECONDS (* 15 60))

;; `x-amz-content-sha256` values that mean "the body is framed as signed chunks".
;; We reject them explicitly rather than mis-verify: no client observed so far uses
;; them, and answering NotImplemented is honest where silently accepting is not.
(define (streaming-payload? v) (and (string? v) (string-prefix? v "STREAMING-")))

;; ---- URI encoding ---------------------------------------------------------------
;; RFC 3986 unreserved: A-Z a-z 0-9 - _ . ~ — everything else percent-encoded with
;; UPPERCASE hex. `encode-slash?` is #f for a path segment set and #t for query
;; components. Note this is *not* `uri-encode` from net/uri-codec, which leaves
;; some sub-delims alone and would produce a different canonical string.
(define (unreserved? b)
  (or (and (>= b 65) (<= b 90))          ; A-Z
      (and (>= b 97) (<= b 122))         ; a-z
      (and (>= b 48) (<= b 57))          ; 0-9
      (= b 45) (= b 95) (= b 46) (= b 126)))   ; - _ . ~

(define HEX "0123456789ABCDEF")
(define (aws-uri-encode s #:encode-slash? [encode-slash? #t])
  (define out (open-output-string))
  (for ([b (in-bytes (string->bytes/utf-8 s))])
    (cond
      [(unreserved? b) (write-char (integer->char b) out)]
      [(and (= b 47) (not encode-slash?)) (write-char #\/ out)]
      [else (write-char #\% out)
            (write-char (string-ref HEX (arithmetic-shift b -4)) out)
            (write-char (string-ref HEX (bitwise-and b #x0f)) out)]))
  (get-output-string out))

;; ---- canonical query --------------------------------------------------------------
;; `query` is the already-parsed alist of STILL-ENCODED (key . value) pairs. We decode
;; then re-encode, because the client's encoding and ours must agree byte for byte and
;; only a normal form guarantees that. Sorted by encoded key, then encoded value.
;; A key with no value canonicalizes to `key=` — the AWS CLI sends `?prefix=` and
;; omitting the `=` changes the signature.
(define (canonical-query query)
  (define pairs
    (for/list ([kv (in-list query)])
      (cons (aws-uri-encode (percent-decode (car kv)))
            (aws-uri-encode (percent-decode (cdr kv))))))
  (string-join
   (for/list ([kv (in-list (sort pairs (lambda (a b)
                                         (if (string=? (car a) (car b))
                                             (string<? (cdr a) (cdr b))
                                             (string<? (car a) (car b))))))])
     (string-append (car kv) "=" (cdr kv)))
   "&"))

(define (percent-decode s)
  (define out (open-output-bytes))
  (let loop ([i 0])
    (cond
      [(>= i (string-length s)) (void)]
      [(and (char=? (string-ref s i) #\%) (< (+ i 2) (string-length s))
            (string->number (substring s (add1 i) (+ i 3)) 16))
       => (lambda (b) (write-byte b out) (loop (+ i 3)))]
      [else (write-char (string-ref s i) out) (loop (add1 i))]))
  (bytes->string/utf-8 (get-output-bytes out) #\?))

;; ---- canonical headers -------------------------------------------------------------
;; Only the headers the client listed in SignedHeaders take part. Values are trimmed
;; and internal whitespace runs collapse to one space — including inside quotes, which
;; the `get-header-value-trim` vector pins. Repeated headers join with "," in arrival
;; order.
(define (canonical-headers headers signed-names)
  (string-join
   (for/list ([name (in-list signed-names)])
     (define vals (for/list ([kv (in-list headers)] #:when (string=? (car kv) name)) (cdr kv)))
     (string-append name ":" (string-join (map collapse-ws vals) ",") "\n"))
   ""))

(define (collapse-ws v) (regexp-replace* #px"\\s+" (string-trim v) " "))

(define (signed-headers-of signed-names) (string-join signed-names ";"))

;; ---- the canonical request ----------------------------------------------------------
;; `path` arrives percent-encoded and is used as-is (rule 1 above). An empty path is "/".
(define (canonical-request method path query headers signed-names payload-hash)
  (string-join
   (list (string-upcase method)
         (if (string=? path "") "/" path)
         (canonical-query query)
         (canonical-headers headers signed-names)
         (signed-headers-of signed-names)
         payload-hash)
   "\n"))

(define (string-to-sign amz-date scope creq)
  (string-join (list ALGORITHM amz-date scope (sha256-hex (string->bytes/utf-8 creq))) "\n"))

(define (signing-key secret date region service)
  (define (h k m) (hmac-sha256 k (string->bytes/utf-8 m)))
  (h (h (h (h (string->bytes/utf-8 (string-append "AWS4" secret)) date) region) service)
     "aws4_request"))

(define (sigv4-signature secret date region service sts)
  (bytes->hex-lower (hmac-sha256 (signing-key secret date region service)
                                 (string->bytes/utf-8 sts))))

;; ---- the Authorization header ---------------------------------------------------------
(struct sigv4-auth (access-key date region service signed-headers signature) #:transparent)

;; "AWS4-HMAC-SHA256 Credential=AK/20150830/us-east-1/s3/aws4_request, SignedHeaders=a;b, Signature=hex"
;; Returns #f rather than raising: an unparseable Authorization is a 403, not a 500,
;; and this runs on unauthenticated input.
(define (parse-authorization s)
  (and
   (string? s)
   (string-prefix? s (string-append ALGORITHM " "))
   (let* ([rest (substring s (add1 (string-length ALGORITHM)))]
          [parts (for/hash ([p (in-list (string-split rest ","))])
                   (define kv (string-split (string-trim p) "=" #:trim? #f))
                   (if (>= (length kv) 2)
                       (values (car kv) (string-join (cdr kv) "="))
                       (values (string-trim p) "")))]
          [cred (hash-ref parts "Credential" #f)]
          [sh   (hash-ref parts "SignedHeaders" #f)]
          [sig  (hash-ref parts "Signature" #f)])
     (and cred sh sig
          (let ([cs (string-split cred "/")])
            (and (= 5 (length cs))
                 (string=? (list-ref cs 4) "aws4_request")
                 (sigv4-auth (list-ref cs 0) (list-ref cs 1) (list-ref cs 2) (list-ref cs 3)
                             (string-split sh ";")
                             sig)))))))

;; ---- dates ---------------------------------------------------------------------------
;; "20150830T123600Z" -> seconds since the epoch, UTC. #f if it is not that shape.
(define (amz-date->seconds s)
  (define m (regexp-match #px"^([0-9]{4})([0-9]{2})([0-9]{2})T([0-9]{2})([0-9]{2})([0-9]{2})Z$" s))
  (and m
       (let ([n (lambda (i) (string->number (list-ref m i)))])
         (with-handlers ([exn:fail? (lambda (_) #f)])
           (find-seconds (n 6) (n 5) (n 4) (n 3) (n 2) (n 1) #f)))))

;; ---- verification -----------------------------------------------------------------------
;; Returns #t, or a symbol naming the failure so the caller can map it to S3's own
;; error vocabulary rather than collapsing everything to AccessDenied.
;;
;;   'malformed-authorization 'unknown-date 'skewed 'streaming-unsupported 'mismatch
;;
;; `secret` is looked up by the caller from auth's access-key; passing #f means the
;; key is unknown, which is reported as 'mismatch so an attacker cannot distinguish
;; "no such key" from "wrong secret" by timing the response shape.
(define (sigv4-verify auth
                      #:method method
                      #:path path
                      #:query query
                      #:headers headers
                      #:payload-hash payload-hash
                      #:secret secret
                      #:now [now (current-seconds)]
                      #:max-skew [max-skew MAX-SKEW-SECONDS])
  (cond
    [(not auth) 'malformed-authorization]
    [(streaming-payload? payload-hash) 'streaming-unsupported]
    [else
     (define amz-date (cond [(assoc "x-amz-date" headers) => cdr] [else #f]))
     (define t (and amz-date (amz-date->seconds amz-date)))
     (cond
       [(not t) 'unknown-date]
       [(> (abs (- now t)) max-skew) 'skewed]
       [(not secret) 'mismatch]
       [else
        (define scope (string-join (list (sigv4-auth-date auth) (sigv4-auth-region auth)
                                         (sigv4-auth-service auth) "aws4_request") "/"))
        (define creq (canonical-request method path query headers
                                        (sigv4-auth-signed-headers auth) payload-hash))
        (define sts (string-to-sign amz-date scope creq))
        (define expect (sigv4-signature secret (sigv4-auth-date auth) (sigv4-auth-region auth)
                                        (sigv4-auth-service auth) sts))
        (if (constant-time=? expect (sigv4-auth-signature auth)) #t 'mismatch)])]))

;; ---- presigned URLs (SigV4 query auth) -------------------------------------------
;;
;; Everything moves from the Authorization header into the query string, and the
;; payload hash becomes the literal UNSIGNED-PAYLOAD — a browser following a link
;; cannot compute a body hash it does not have. Two consequences worth stating:
;;
;;   * `X-Amz-Signature` is EXCLUDED from the canonical query (it is the output), but
;;     every other X-Amz-* parameter is included. Getting that wrong is the classic
;;     presigning bug and it fails identically to a wrong secret.
;;   * The URL is valid until `X-Amz-Date + X-Amz-Expires`, which is a second,
;;     independent clock check on top of the skew window.

(define (presign-parse query)
  (define (g k) (cond [(assoc k query) => cdr] [else #f]))
  (define alg (g "X-Amz-Algorithm"))
  (define cred (g "X-Amz-Credential"))
  (define sh (g "X-Amz-SignedHeaders"))
  (define sig (g "X-Amz-Signature"))
  (and alg cred sh sig
       (string=? (percent-decode alg) ALGORITHM)
       (let ([cs (string-split (percent-decode cred) "/")])
         (and (= 5 (length cs))
              (string=? (list-ref cs 4) "aws4_request")
              (sigv4-auth (list-ref cs 0) (list-ref cs 1) (list-ref cs 2) (list-ref cs 3)
                          (string-split (percent-decode sh) ";")
                          (percent-decode sig))))))

;; Same failure vocabulary as sigv4-verify, plus 'expired — which is a different
;; thing from 'skewed and deserves its own message, because the fix is different
;; (ask for a new link, versus fix your clock).
(define (presign-verify auth
                        #:method method
                        #:path path
                        #:query query
                        #:headers headers
                        #:secret secret
                        #:now [now (current-seconds)]
                        #:max-skew [max-skew MAX-SKEW-SECONDS])
  (define (g k) (cond [(assoc k query) => cdr] [else #f]))
  (define amz-date (let ([v (g "X-Amz-Date")]) (and v (percent-decode v))))
  (define expires (let ([v (g "X-Amz-Expires")]) (and v (string->number (percent-decode v)))))
  (define t (and amz-date (amz-date->seconds amz-date)))
  (cond
    [(not auth) 'malformed-authorization]
    [(not t) 'unknown-date]
    [(not expires) 'unknown-date]
    [(> (- now t) (+ expires max-skew)) 'expired]
    [(> (- t now) max-skew) 'skewed]
    [(not secret) 'mismatch]
    [else
     ;; the signature is the output, so it is not part of its own input
     (define signable (filter (lambda (kv) (not (string=? (car kv) "X-Amz-Signature"))) query))
     (define scope (string-join (list (sigv4-auth-date auth) (sigv4-auth-region auth)
                                      (sigv4-auth-service auth) "aws4_request") "/"))
     (define creq (canonical-request method path signable headers
                                     (sigv4-auth-signed-headers auth) UNSIGNED-PAYLOAD))
     (define sts (string-to-sign amz-date scope creq))
     (define expect (sigv4-signature secret (sigv4-auth-date auth) (sigv4-auth-region auth)
                                     (sigv4-auth-service auth) sts))
     (if (constant-time=? expect (sigv4-auth-signature auth)) #t 'mismatch)]))

;; Build the signed query for a presigned URL. Returns the encoded query string, so a
;; caller appends it to `<endpoint><path>?`. `path` must already be encoded the way it
;; will be sent — signing one form and sending another is the same bug as decoding too
;; early, from the other end.
(define (presign-query #:method method
                       #:path path
                       #:access-key access-key
                       #:secret secret
                       #:region region
                       #:host host
                       #:expires expires
                       #:now [now (current-seconds)]
                       #:service [service "s3"]
                       #:extra [extra '()])
  (define amz-date (seconds->amz-date now))
  (define day (substring amz-date 0 8))
  (define scope (string-join (list day region service "aws4_request") "/"))
  (define base
    (append extra
            (list (cons "X-Amz-Algorithm" ALGORITHM)
                  (cons "X-Amz-Credential" (string-append access-key "/" scope))
                  (cons "X-Amz-Date" amz-date)
                  (cons "X-Amz-Expires" (number->string expires))
                  (cons "X-Amz-SignedHeaders" "host"))))
  ;; canonical-query re-encodes, so hand it the raw values and let it normalise
  (define creq (canonical-request method path base (list (cons "host" host)) '("host")
                                  UNSIGNED-PAYLOAD))
  (define sig (sigv4-signature secret day region service (string-to-sign amz-date scope creq)))
  (string-append (canonical-query base) "&X-Amz-Signature=" sig))

;; seconds -> "20260821T041609Z"
(define (seconds->amz-date secs)
  (define d (seconds->date secs #f))
  (define (p2 n) (if (< n 10) (format "0~a" n) (number->string n)))
  (format "~a~a~aT~a~a~aZ"
          (date-year d) (p2 (date-month d)) (p2 (date-day d))
          (p2 (date-hour d)) (p2 (date-minute d)) (p2 (date-second d))))

;; Comparing signatures with string=? leaks their prefix through timing. The cost of
;; not caring is a remote attacker recovering a signature byte by byte.
(define (constant-time=? a b)
  (and (= (string-length a) (string-length b))
       (zero? (for/fold ([acc 0]) ([x (in-string a)] [y (in-string b)])
                (bitwise-ior acc (bitwise-xor (char->integer x) (char->integer y)))))))
