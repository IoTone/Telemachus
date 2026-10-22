#lang racket/base

;; test/egress-tests.rkt — the outbound fetcher (#142).
;;
;; Two halves. The address table is pure and exhaustive about the ranges that
;; matter; the fetcher half runs against REAL SOCKETS, because every interesting
;; failure here is at the socket (what was connected to, what was read, when it
;; was given up on) and a mocked transport would assert the mock.
;;
;; ONE LIMIT, STATED: the vetting happens in two places — the name's resolution
;; before connecting, and the SOCKET'S REAL PEER before a byte is written — and
;; only the first is reachable deterministically from a test. Making the second
;; fire needs DNS to answer differently than the connection resolves, which is
;; not reproducible in-suite; both ask the same `address-allowed?`, which IS
;; exhaustively tested above. So the peer check has no control of its own, and
;; saying so beats a case that looks like one.
;;
;;   raco test test/egress-tests.rkt

(require rackunit racket/tcp racket/port racket/string
         "../domain/net/addresses.rkt"
         "../domain/net/fetch.rkt")

;; ---- the address table ---------------------------------------------------------
(test-case "the ranges that matter are classified, in both directions"
  ;; the single most valuable SSRF target there is: instance credentials
  (check-equal? (address-class "169.254.169.254") 'link-local)
  (check-equal? (address-class "127.0.0.1") 'loopback)
  (check-equal? (address-class "127.1.2.3") 'loopback)
  (check-equal? (address-class "10.0.0.1") 'private)
  (check-equal? (address-class "172.16.0.1") 'private)
  (check-equal? (address-class "172.31.255.255") 'private)
  (check-equal? (address-class "192.168.1.1") 'private)
  ;; 100.64/10 is CGNAT and is also what Tailscale hands out — this platform's
  ;; own demo box is reached that way, so the range is not theoretical
  (check-equal? (address-class "100.100.100.100") 'cgnat)
  (check-equal? (address-class "0.0.0.0") 'this-network)
  (check-equal? (address-class "224.0.0.1") 'multicast)
  (check-equal? (address-class "255.255.255.255") 'reserved)
  (check-equal? (address-class "::1") 'loopback)
  (check-equal? (address-class "fd00::1") 'private)
  (check-equal? (address-class "fe80::1") 'link-local)
  ;; A v4 address wearing a v6 coat reaches the same network, and a classifier
  ;; that only read the textual form would pass this through to the metadata
  ;; endpoint.
  (check-equal? (address-class "::ffff:169.254.169.254") 'link-local)
  (check-equal? (address-class "::ffff:10.0.0.1") 'private)
  ;; …and the other direction: ordinary public addresses are NOT special, or the
  ;; fetcher refuses everything and the refusals prove nothing
  (check-equal? (address-class "1.1.1.1") 'public)
  (check-equal? (address-class "172.32.0.1") 'public)      ; just outside 172.16/12
  (check-equal? (address-class "172.15.255.255") 'public)
  (check-equal? (address-class "100.63.255.255") 'public)  ; just outside 100.64/10
  (check-equal? (address-class "100.128.0.1") 'public)
  (check-equal? (address-class "9.255.255.255") 'public)
  (check-equal? (address-class "2606:4700::1111") 'public)
  ;; a hostname is not an address, and GUESSING is how a check gets skipped
  (check-equal? (address-class "example.com") 'unparseable)
  (check-equal? (address-class "010.1.1.1") 'unparseable)  ; no padding games
  (check-equal? (address-class "1.2.3") 'unparseable)
  (check-equal? (address-class "1.2.3.256") 'unparseable))

(test-case "trusted means public plus the OPERATOR's CIDRs, not 'any private address'"
  (define allow (parse-cidr-list "10.8.0.0/16, 192.168.4.7"))
  (check-equal? (length allow) 2)
  ;; untrusted: public only, whatever the allowlist says
  (check-equal? (address-allowed? "10.8.0.1" #:policy 'untrusted #:allow allow) 'private)
  (check-false (address-allowed? "1.1.1.1" #:policy 'untrusted #:allow allow))
  ;; trusted: the allowed CIDR opens, and NOTHING ELSE private does. This is the
  ;; multi-tenancy rule — a tenant admin who could name any private URL would be
  ;; reading the instance's own cloud metadata.
  (check-false (address-allowed? "10.8.0.1" #:policy 'trusted #:allow allow))
  (check-false (address-allowed? "192.168.4.7" #:policy 'trusted #:allow allow))
  (check-equal? (address-allowed? "10.9.0.1" #:policy 'trusted #:allow allow) 'private)
  (check-equal? (address-allowed? "192.168.4.8" #:policy 'trusted #:allow allow) 'private)
  (check-equal? (address-allowed? "169.254.169.254" #:policy 'trusted #:allow allow) 'link-local)
  ;; a bare address is /32, and a /0 entry is honoured as written — an operator
  ;; who types it has said something sweeping, and silently narrowing it would be
  ;; worse than doing as asked
  (check-true (address-in-cidr? "8.8.8.8" (parse-cidr "0.0.0.0/0")))
  (check-false (address-in-cidr? "192.168.4.8" (parse-cidr "192.168.4.7")))
  ;; nonsense in the allowlist is DROPPED at parse rather than matching
  ;; everything or nothing by accident
  (check-equal? (parse-cidr-list "nonsense,10.0.0.0/8,10.0.0.0/33") (list (parse-cidr "10.0.0.0/8")))
  (check-false (parse-cidr "fd00::/8")))                   ; IPv6 CIDRs are refused, not ignored

;; ---- a real socket --------------------------------------------------------------
;; One listener per case, answering one request from a script. Scripted rather
;; than mocked because the cases ARE socket behaviour: a redirect to a private
;; address, a body that never stops, a server that accepts and says nothing.
(define (with-server respond proc)
  (define L (tcp-listen 0 4 #t "127.0.0.1"))
  (define-values (_h p _rh _rp) (tcp-addresses L #t))
  (define t (thread (lambda ()
                      (with-handlers ([(lambda (_) #t) void])
                        (let loop ()
                          (define-values (i o) (tcp-accept L))
                          (thread (lambda ()
                                    (with-handlers ([(lambda (_) #t) void])
                                      (let rl ([first #f])
                                        (define l (read-line i 'return-linefeed))
                                        (unless (or (eof-object? l) (string=? l ""))
                                          (rl (or first l))))
                                      (respond o p)
                                      (with-handlers ([(lambda (_) #t) void]) (close-output-port o))
                                      (with-handlers ([(lambda (_) #t) void]) (close-input-port i)))))
                          (loop))))))
  (define allow-was (getenv "TELEMACHUS_EGRESS_ALLOW"))
  ;; A test that sets process-global state restores it in a dynamic-wind — a
  ;; failing check raises, and a leaked allowlist would quietly re-point every
  ;; later case in the file.
  (dynamic-wind
   void
   (lambda () (proc (format "http://127.0.0.1:~a/x" p) p))
   (lambda ()
     (putenv "TELEMACHUS_EGRESS_ALLOW" (or allow-was ""))
     (kill-thread t)
     (tcp-close L))))

(define (ok-response body)
  (lambda (o _p)
    (fprintf o "HTTP/1.1 200 OK\r\ncontent-length: ~a\r\nconnection: close\r\n\r\n" (bytes-length body))
    (write-bytes body o) (flush-output o)))

(test-case "loopback is refused by default, and reachable only when the operator allows it"
  (with-server (ok-response #"hello feed")
    (lambda (url _p)
      ;; `'untrusted` IS THE DEFAULT, so a caller that says nothing is safe
      (define e (with-handlers ([exn:fail:egress? values]) (fetch url) #f))
      (check-true (exn:fail:egress? e))
      (check-equal? (exn:fail:egress-reason e) 'refused-address)
      ;; trusted alone is not enough — the operator has allowed nothing
      (putenv "TELEMACHUS_EGRESS_ALLOW" "")
      (check-equal? (exn:fail:egress-reason
                     (with-handlers ([exn:fail:egress? values]) (fetch url #:policy 'trusted) #f))
                    'refused-address)
      ;; …and with the network allowed, it goes through
      (putenv "TELEMACHUS_EGRESS_ALLOW" "127.0.0.0/8")
      (define-values (status hs body) (fetch url #:policy 'trusted))
      (check-equal? status 200)
      (check-equal? body #"hello feed"))))

(test-case "A REDIRECT IS RE-VETTED, which is where a fetcher is usually wrong"
  ;; A 302 to the metadata endpoint passes any check made only on the URL the
  ;; caller supplied. This is the classic bypass and it has its own case.
  (with-server
    (lambda (o _p)
      (fprintf o "HTTP/1.1 302 Found\r\nlocation: http://169.254.169.254/latest/meta-data/\r\ncontent-length: 0\r\nconnection: close\r\n\r\n")
      (flush-output o))
    (lambda (url _p)
      (putenv "TELEMACHUS_EGRESS_ALLOW" "127.0.0.0/8")
      (define e (with-handlers ([exn:fail:egress? values]) (fetch url #:policy 'trusted) #f))
      (check-true (exn:fail:egress? e))
      (check-equal? (exn:fail:egress-reason e) 'refused-address)
      ;; the message names the range, because "refused" alone reads as a broken
      ;; fetcher rather than as a policy
      (check-true (string-contains? (exn-message e) "metadata")))))

(test-case "a relative redirect is followed, and the hops are bounded"
  (with-server
    (lambda (o p)
      ;; always redirect, so the hop ceiling is what stops it
      (fprintf o "HTTP/1.1 302 Found\r\nlocation: /again\r\ncontent-length: 0\r\nconnection: close\r\n\r\n")
      (flush-output o))
    (lambda (url _p)
      (putenv "TELEMACHUS_EGRESS_ALLOW" "127.0.0.0/8")
      (define e (with-handlers ([exn:fail:egress? values]) (fetch url #:policy 'trusted) #f))
      (check-true (exn:fail:egress? e))
      (check-equal? (exn:fail:egress-reason e) 'too-many-redirects))))

(test-case "the body cap is enforced on what is READ, not on what was declared"
  (with-server
    (lambda (o _p)
      ;; Content-Length LIES: it claims 4 bytes and sends far more. A cap that
      ;; trusted the header would let this through, and the header is the remote
      ;; end's claim about itself — which is what this whole module is about.
      (fprintf o "HTTP/1.1 200 OK\r\ncontent-length: 4\r\nconnection: close\r\n\r\n")
      (write-bytes (make-bytes 5000 65) o) (flush-output o))
    (lambda (url _p)
      (putenv "TELEMACHUS_EGRESS_ALLOW" "127.0.0.0/8")
      (define e (with-handlers ([exn:fail:egress? values])
                  (fetch url #:policy 'trusted #:max-bytes 1000) #f))
      (check-true (exn:fail:egress? e))
      (check-equal? (exn:fail:egress-reason e) 'too-large)))
  ;; exactly at the limit is fine — the cap reads one byte past it, which is what
  ;; makes the boundary right rather than off by one
  (with-server (ok-response (make-bytes 1000 66))
    (lambda (url _p)
      (putenv "TELEMACHUS_EGRESS_ALLOW" "127.0.0.0/8")
      (define-values (_s _h body) (fetch url #:policy 'trusted #:max-bytes 1000))
      (check-equal? (bytes-length body) 1000))))

(test-case "a chunked response is decoded through the kit's own RFC 7230 reader"
  (with-server
    (lambda (o _p)
      (fprintf o "HTTP/1.1 200 OK\r\ntransfer-encoding: chunked\r\nconnection: close\r\n\r\n")
      (fprintf o "5\r\nhello\r\n6\r\n world\r\n0\r\n\r\n")
      (flush-output o))
    (lambda (url _p)
      (putenv "TELEMACHUS_EGRESS_ALLOW" "127.0.0.0/8")
      (define-values (status _h body) (fetch url #:policy 'trusted))
      (check-equal? status 200)
      (check-equal? body #"hello world"))))

(test-case "a server that accepts and says nothing is given up on"
  (with-server
    (lambda (o _p) (sync (make-semaphore 0)))      ; never answers
    (lambda (url _p)
      (putenv "TELEMACHUS_EGRESS_ALLOW" "127.0.0.0/8")
      (define t0 (current-inexact-milliseconds))
      (define e (with-handlers ([exn:fail:egress? values])
                  (fetch url #:policy 'trusted #:timeout 1) #f))
      (check-true (exn:fail:egress? e))
      (check-equal? (exn:fail:egress-reason e) 'timeout)
      ;; and it really did give up near the deadline rather than at some
      ;; unrelated socket timeout
      (check-true (< (- (current-inexact-milliseconds) t0) 5000)))))

(test-case "the refusals that need no server at all"
  ;; a literal metadata address, by default
  (check-equal? (exn:fail:egress-reason
                 (with-handlers ([exn:fail:egress? values])
                   (fetch "http://169.254.169.254/latest/meta-data/") #f))
                'refused-address)
  ;; `localhost` by NAME. Without its own branch this arrives as "could not be
  ;; resolved" — the name is usually only in /etc/hosts — which reads as an
  ;; integrator's broken DNS rather than as the policy working.
  (check-equal? (exn:fail:egress-reason
                 (with-handlers ([exn:fail:egress? values]) (fetch "http://localhost:9/x") #f))
                'refused-address)
  (check-equal? (exn:fail:egress-reason
                 (with-handlers ([exn:fail:egress? values]) (fetch "http://FOO.localhost/x") #f))
                'refused-address)
  ;; a scheme this has no business following. `file:` is the one that matters:
  ;; a fetcher that handed it to a URL library would read the server's disk.
  (for ([u (in-list '("file:///etc/passwd" "gopher://x/1" "ftp://x/y" "not a url"))])
    (check-equal? (exn:fail:egress-reason
                   (with-handlers ([exn:fail:egress? values]) (fetch u) #f))
                  'bad-url
                  (format "~a must be refused" u))))
