#lang racket/base

;; domain/net/fetch.rkt — the ONE outbound HTTP request (#142).
;;
;; Everything this platform has fetched until now went to an endpoint the
;; OPERATOR configured: the model URL, `executors.json`, an MCP server, a blob
;; bucket. #114's feeds and RSCH-3's research loop are the first callers to
;; fetch a URL somebody else chose, and that turns an ordinary HTTP client into
;; an SSRF surface onto the instance's own network — the cloud metadata
;; endpoint, the database, whatever else answers on a private address.
;;
;; ONE FETCHER, TWO POLICIES, `'untrusted` BY DEFAULT, so a caller that says
;; nothing is safe. The rule attaches to WHO CHOSE THE URL, not to where it
;; points — which is how RSCH-3 ("refuse private address space") and #114
;; ("feeds in our network") are both satisfied without either being weakened.
;;
;; `'trusted` does NOT mean "any private address": it means public plus the
;; CIDRs an operator allowed (`TELEMACHUS_EGRESS_ALLOW`). On a multi-tenant
;; instance, a tenant admin who could name any private URL would be reading the
;; instance's own cloud metadata.

(require racket/port racket/string racket/list racket/tcp openssl net/url
         net/dns
         (only-in web-kit/http1 make-chunked-body)
         "addresses.rkt")

(provide fetch egress-allowlist safe-url
         (struct-out exn:fail:egress) FETCH-MAX-BYTES FETCH-TIMEOUT FETCH-MAX-REDIRECTS)

;; A refusal by POLICY is its own exception, so a caller can tell "we would not
;; go there" from "it did not answer" — the distinction PULL-14 needed one level
;; down to decide between releasing a job and failing it.
(struct exn:fail:egress exn:fail (reason url) #:transparent)

(define FETCH-MAX-BYTES (* 8 1024 1024))
(define FETCH-TIMEOUT 30)
(define FETCH-MAX-REDIRECTS 3)

;; ---- what a refusal is allowed to say (FEED-6) ----------------------------------
;; A CREDENTIAL IS ROUTINELY IN A URL. A feed's API token arrives as
;; `?token=…`, a signed link carries its signature in the query, and
;; `https://user:pass@host/` is still how half the world spells basic auth. The
;; failing request's URL is the first thing an error wants to quote, and from
;; there it goes where every other copy of this mistake went: into a stored
;; `error` column (#83 r4 sealed four of them for this reason), into a log that
;; leaves the box, into a 500 body (#123). `webhook_deliveries.last_error`
;; stores what this module raises, unsealed, TODAY.
;;
;; So the redaction happens HERE, on the way INTO the exception, not at the
;; call sites that format it — by then it has already been composed, and the
;; next caller would have to remember. Scheme, host, port and path survive,
;; because a diagnostic naming neither the host nor the path is no diagnostic;
;; the query, the fragment and the userinfo do not.
(define (safe-url u)
  (define parsed (with-handlers ([exn:fail? (lambda (_) #f)]) (string->url u)))
  (cond
    [(and parsed (url-host parsed))
     (url->string (make-url (url-scheme parsed) #f (url-host parsed) (url-port parsed)
                            #t (url-path parsed) '() #f))]
    ;; Not a URL we can take apart — a scheme we refuse, or rubbish. Keeping a
    ;; prefix would be a guess at where the secret is NOT, so it says nothing.
    [else "(unparseable url)"]))

(define (egress-error reason url fmt . args)
  (raise (exn:fail:egress (apply format fmt args) (current-continuation-marks)
                          reason (safe-url url))))

;; The operator's allowlist, read per call. Not memoized: it is one `getenv` and
;; a parse against a request that is about to cross the network, and a cache
;; keyed on nothing is how a test that sets the variable stops working.
(define (egress-allowlist)
  (parse-cidr-list (getenv "TELEMACHUS_EGRESS_ALLOW")))

;; ---- the request ----------------------------------------------------------------
;; -> (values status headers body-bytes)
;;
;; Deliberately BUFFERED, with a cap, unlike the S3 client's streaming reader:
;; the callers are a feed document and a webhook response, both small, and the
;; remote end is not ours — an unbounded stream from a URL somebody else chose is
;; the second-easiest way to hurt this process after the SSRF.
(define (fetch url
               #:policy [policy 'untrusted]
               #:method [method "GET"]
               #:headers [headers '()]
               #:body [body #f]
               #:timeout [timeout FETCH-TIMEOUT]
               #:max-bytes [max-bytes FETCH-MAX-BYTES]
               #:max-redirects [max-redirects FETCH-MAX-REDIRECTS]
               #:allow [allow (egress-allowlist)])
  (let loop ([u url] [hops 0])
    (define-values (status hs bs location)
      (one-hop u policy method headers body timeout max-bytes allow))
    (cond
      [(and location (< hops max-redirects))
       ;; EVERY HOP IS RE-VETTED, because that is where a fetcher is usually
       ;; wrong: a 302 to 169.254.169.254 passes any check made only on the URL
       ;; the caller supplied. The redirect target is resolved against the
       ;; current URL, so a relative Location works as browsers have it.
       (loop (url->string (combine-url/relative (string->url u) location)) (add1 hops))]
      [location
       (egress-error 'too-many-redirects u "the URL redirected more than ~a times" max-redirects)]
      [else (values status hs bs)])))

(define (one-hop u policy method headers body timeout max-bytes allow)
  (define parsed (with-handlers ([exn:fail? (lambda (_) #f)]) (string->url u)))
  (define scheme (and parsed (url-scheme parsed)))
  (define host (and parsed (url-host parsed)))
  (unless (and parsed host (not (string=? host "")) (member scheme '("http" "https")))
    ;; `(safe-url u)`, not `u`: this is the one message that quotes the URL, and
    ;; a URL this refuses is exactly the shape somebody typed wrong — including
    ;; typing a credential into it.
    (egress-error 'bad-url u "not an http(s) URL: ~a" (safe-url u)))
  (define ssl? (string=? scheme "https"))
  (define port (or (url-port parsed) (if ssl? 443 80)))
  ;; STEP 1: vet the name's own resolution, before any connection. This is the
  ;; normal case and it is what keeps the refusal message useful — the caller
  ;; learns the host is private rather than that something timed out.
  (vet-host! host policy allow u)
  ;; The whole exchange runs under its OWN CUSTODIAN with a deadline. Killing the
  ;; thread alone would leave the socket open — llm.rkt's measured lesson, and
  ;; the reason `http-sendrecv` is not used anywhere in this tree: it abandons
  ;; the socket under the response port, and collection does not reclaim it.
  (define cust (make-custodian))
  (define result (box #f))
  (define worker
    (parameterize ([current-custodian cust])
      (thread (lambda ()
                (with-handlers ([(lambda (_) #t) (lambda (e) (set-box! result (cons 'raised e)))])
                  (set-box! result (cons 'ok (exchange ssl? host port parsed method headers body
                                                       max-bytes policy allow u))))))))
  (define done? (sync/timeout timeout worker))
  (custodian-shutdown-all cust)
  (define r (unbox result))
  (cond
    [(not done?) (egress-error 'timeout u "no response within ~a seconds" timeout)]
    [(and (pair? r) (eq? (car r) 'raised)) (raise (cdr r))]
    [(pair? r) (apply values (cdr r))]
    [else (egress-error 'no-response u "the request produced no answer")]))

;; -> (list status headers body location-or-#f)
(define (exchange ssl? host port parsed method headers body max-bytes policy allow u)
  (define-values (in out)
    ;; CONNECT BY NAME, never by the address we resolved. Connecting to a literal
    ;; address would break TLS name verification and SNI — and it is also
    ;; unnecessary: `example.com` resolves to one address and answers from
    ;; another in ordinary round-robin, so comparing a prior resolution to the
    ;; peer would refuse healthy traffic. RSCH-3's recorded mechanism ("resolve
    ;; once and pin the connection") is wrong on both counts; the property it
    ;; wanted is enforced in step 3 below instead.
    (if ssl? (ssl-connect host port 'auto) (tcp-connect host port)))
  (define (bail! e) (close-ports in out) (raise e))
  (with-handlers ([(lambda (_) #t) bail!])
    ;; STEP 3: the address we are ACTUALLY talking to, vetted before a single
    ;; byte is written. This is what closes DNS rebinding, and unlike pinning it
    ;; is immune to round-robin. The residual is stated in #142: a rebinding
    ;; attacker can still cause one TCP connect with no bytes sent, and learn
    ;; connect-versus-refuse timing. That is a weak port-scan primitive and the
    ;; honest limit of this approach.
    (define-values (_la _lp peer _rp)
      (if ssl? (ssl-addresses in #t) (tcp-addresses in #t)))
    (define bad (address-allowed? peer #:policy policy #:allow allow))
    (when bad
      (egress-error 'refused-peer u "~a resolves to ~a, which is ~a" host peer (reason-text bad)))
    (define target (let ([p (url->string (make-url #f #f #f #f #t (url-path parsed)
                                                   (url-query parsed) #f))])
                     (if (string=? p "") "/" p)))
    (fprintf out "~a ~a HTTP/1.1\r\n" (string-upcase method) target)
    (fprintf out "host: ~a\r\n" (if (or (and ssl? (= port 443)) (and (not ssl?) (= port 80)))
                                    host (format "~a:~a" host port)))
    ;; `connection: close`, as the S3 client does and for its reason: the far end
    ;; then frames the response by Content-Length, by chunks, or by closing, and
    ;; a pooled connection would need a lifecycle nobody here wants.
    (fprintf out "connection: close\r\n")
    (fprintf out "accept-encoding: identity\r\n")
    (for ([kv (in-list headers)])
      (fprintf out "~a: ~a\r\n" (car kv) (cdr kv)))
    (when body (fprintf out "content-length: ~a\r\n" (bytes-length body)))
    (fprintf out "\r\n")
    (when body (write-bytes body out))
    (flush-output out)
    (define status (read-status-line in u))
    (define hs (read-headers in))
    (define bs (read-body in hs max-bytes u))
    (define loc (and (member status '(301 302 303 307 308)) (header-ref hs "location")))
    (close-ports in out)
    (list status hs bs loc)))

(define (reason-text k)
  (case k
    [(loopback) "this host"]
    [(private) "a private network"]
    [(link-local) "link-local address space (the cloud metadata endpoint lives there)"]
    [(cgnat) "carrier-grade NAT or tailnet address space"]
    [(multicast) "a multicast address"]
    [(this-network) "an unspecified address"]
    [(reserved benchmark documentation ietf-protocol) "reserved address space"]
    [(unparseable) "not an address this build can classify"]
    [else (format "~a" k)]))

;; A LITERAL address in the URL is vetted as itself; a NAME is resolved and its
;; answer vetted. A resolver failure is not a policy refusal and says so — an
;; integrator whose DNS is broken should not be told their feed is private.
(define (vet-host! host policy allow u)
  (cond
    ;; `localhost` is this host by NAME, and resolving it is not reliable — the
    ;; name is usually in /etc/hosts and may not be in DNS at all, so without
    ;; this the refusal arrives as "could not be resolved", which reads as an
    ;; integrator's broken DNS rather than as the policy working. Any
    ;; `*.localhost` is reserved for the same purpose (RFC 6761).
    [(and (string? host)
          (or (string-ci=? host "localhost")
              (regexp-match? #px"(?i:\\.localhost)$" host)))
     (define bad (address-allowed? "127.0.0.1" #:policy policy #:allow allow))
     (when bad (egress-error 'refused-address u "~a is ~a" host (reason-text bad)))]
    [(not (eq? 'unparseable (address-class host)))
     (define bad (address-allowed? host #:policy policy #:allow allow))
     (when bad (egress-error 'refused-address u "~a is ~a" host (reason-text bad)))]
    [else
     (define addr
       (with-handlers ([(lambda (_) #t)
                        (lambda (_) (egress-error 'dns u "~a could not be resolved" host))])
         (dns-get-address (dns-find-nameserver) host)))
     (define bad (address-allowed? addr #:policy policy #:allow allow))
     (when bad (egress-error 'refused-address u "~a resolves to ~a, which is ~a"
                             host addr (reason-text bad)))]))

(define (close-ports in out)
  (with-handlers ([(lambda (_) #t) void]) (close-input-port in))
  (with-handlers ([(lambda (_) #t) void]) (close-output-port out)))

(define (read-status-line in u)
  (define l (read-line in 'return-linefeed))
  (when (eof-object? l)
    (egress-error 'no-response u "the endpoint closed the connection without a response"))
  (define m (regexp-match #px"^HTTP/1\\.[01] ([0-9]{3})" l))
  (unless m (egress-error 'bad-response u "not an HTTP response: ~s" l))
  (string->number (list-ref m 1)))

(define (read-headers in)
  (let loop ([acc '()])
    (define l (read-line in 'return-linefeed))
    (cond
      [(or (eof-object? l) (string=? l "")) (reverse acc)]
      [else
       (define i (for/first ([j (in-range (string-length l))]
                             #:when (char=? (string-ref l j) #\:)) j))
       (loop (if i
                 (cons (cons (string-downcase (substring l 0 i))
                             (string-trim (substring l (add1 i))))
                       acc)
                 acc))])))

(define (header-ref hs name [default #f])
  (define p (assoc (string-downcase name) hs))
  (if p (cdr p) default))

;; The cap is enforced on what is READ, not on Content-Length: a declared length
;; is the remote end's claim about itself, and this whole module exists because
;; the remote end is not ours. Reading one byte past the cap is what makes
;; "exactly at the limit" succeed and a lie fail.
(define (read-body in hs max-bytes u)
  (define te (header-ref hs "transfer-encoding" ""))
  ;; `make-chunked-body` answers TWO values — the port and the body-state the
  ;; server uses for its keep-alive decision. A client has no keep-alive to
  ;; decide (`connection: close`), so the second is dropped, deliberately and in
  ;; one place rather than at a call site that would look like a mistake.
  (define src (if (regexp-match? #px"(?i:chunked)" te)
                  ;; the kit's own RFC 7230 decoder — a second one would be a
                  ;; second place for the trailers to be subtly wrong
                  (let-values ([(port _state) (make-chunked-body in void)]) port)
                  in))
  (define bs (read-bytes (add1 max-bytes) src))
  (define got (if (eof-object? bs) #"" bs))
  (when (> (bytes-length got) max-bytes)
    (egress-error 'too-large u "the response exceeded ~a bytes" max-bytes))
  got)
