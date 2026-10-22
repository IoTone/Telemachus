#lang racket/base

;; domain/net/addresses.rkt — is this address somebody's private network? (#142)
;;
;; Pure classification: parse an address, decide whether it is special. No I/O,
;; no DNS, no sockets, so the whole table is unit-testable and the fetcher above
;; it has one question to ask.
;;
;; THE DIRECTION MATTERS. `domain/authz/peer.rkt` answers the INBOUND question
;; and deliberately refuses to treat a private-looking address as trusted,
;; because "10.x is internal" is an assumption about somebody else's network.
;; Outbound is the mirror: a private-looking address is exactly what must not be
;; reached on behalf of a URL we did not choose. Loopback is the one judgement
;; both directions share, so it is DELEGATED to peer.rkt rather than written
;; twice — two predicates would drift, and the TLS warning and this would start
;; disagreeing about what "private" means.

(require racket/string racket/list
         (only-in "../authz/peer.rkt" loopback-address?))

(provide special-address? address-class ipv4-bytes parse-cidr address-in-cidr?
         parse-cidr-list address-allowed?)

;; ---- parsing -------------------------------------------------------------------
;; -> (list a b c d) or #f. Strict: four decimal octets, 0-255, no padding games
;; ("010" is refused rather than read as 8 or 10 depending on who is reading).
(define (ipv4-bytes s)
  (and (string? s)
       (let ([parts (string-split s "." #:trim? #f)])
         (and (= (length parts) 4)
              (let ([ns (for/list ([p (in-list parts)])
                          (and (regexp-match? #px"^(0|[1-9][0-9]{0,2})$" p)
                               (let ([n (string->number p)])
                                 (and (<= n 255) n))))])
                (and (andmap exact-integer? ns) ns))))))

;; An IPv4-mapped or -compatible IPv6 address carries a v4 address inside it, and
;; a classifier that only looked at the textual form would pass
;; `::ffff:169.254.169.254` straight through to the metadata endpoint.
(define (embedded-ipv4 s)
  (and (string? s)
       (let ([m (regexp-match #px"^(?i:::ffff:|::)([0-9]{1,3}(?:\\.[0-9]{1,3}){3})$" s)])
         (and m (ipv4-bytes (cadr m))))))

;; ---- classification -------------------------------------------------------------
;; -> a symbol naming WHY an address is special, or 'public. The reason is
;; returned rather than a boolean because it goes in the refusal: "refused:
;; link-local (cloud metadata)" tells an integrator what happened, where
;; "refused" alone reads as a broken fetcher.
(define (address-class addr)
  (define v4 (or (ipv4-bytes addr) (embedded-ipv4 addr)))
  (cond
    [(loopback-address? addr) 'loopback]
    [v4 (ipv4-class v4)]
    [(ipv6? addr) (ipv6-class addr)]
    ;; Not an address at all. A hostname reaching here is a caller mistake, and
    ;; guessing is how a check gets skipped.
    [else 'unparseable]))

(define (ipv4-class b)
  (define a (first b)) (define c (second b))
  (cond
    [(= a 127) 'loopback]
    [(= a 0) 'this-network]
    [(= a 10) 'private]
    [(and (= a 172) (>= c 16) (<= c 31)) 'private]
    [(and (= a 192) (= c 168)) 'private]
    ;; 169.254/16 is link-local, and 169.254.169.254 is the cloud metadata
    ;; endpoint on AWS, GCP and Azure alike — the single most valuable target an
    ;; SSRF has, since it hands out instance credentials.
    [(and (= a 169) (= c 254)) 'link-local]
    ;; 100.64/10 is carrier-grade NAT, which is also what Tailscale hands out.
    ;; This platform's own demo box is reached that way, so this is not a
    ;; theoretical range: it is exactly the network an operator might legitimately
    ;; want a feed on, and exactly the one a tenant must not reach by naming it.
    [(and (= a 100) (>= c 64) (<= c 127)) 'cgnat]
    [(and (= a 192) (= c 0) (= (third b) 0)) 'ietf-protocol]
    [(and (= a 192) (= c 0) (= (third b) 2)) 'documentation]
    [(and (= a 198) (>= c 18) (<= c 19)) 'benchmark]
    [(and (= a 198) (= c 51) (= (third b) 100)) 'documentation]
    [(and (= a 203) (= c 0) (= (third b) 113)) 'documentation]
    [(and (>= a 224) (<= a 239)) 'multicast]
    [(>= a 240) 'reserved]
    [else 'public]))

(define (ipv6? s)
  (and (string? s) (regexp-match? #px"^[0-9A-Fa-f:]+$" s) (string-contains? s ":")))

(define (ipv6-class s)
  (define low (string-downcase s))
  (cond
    [(string=? low "::") 'this-network]
    [(string=? low "::1") 'loopback]
    ;; fc00::/7 unique-local: fc and fd
    [(or (string-prefix? low "fc") (string-prefix? low "fd")) 'private]
    ;; fe80::/10 link-local
    [(regexp-match? #px"^fe[89ab]" low) 'link-local]
    [(string-prefix? low "ff") 'multicast]
    [else 'public]))

;; `#f` for a public address, else the reason. One predicate, used by the fetcher
;; for the resolved addresses AND for the socket's real peer.
(define (special-address? addr)
  (define k (address-class addr))
  (and (not (eq? k 'public)) k))

;; ---- the operator's allowlist ---------------------------------------------------
;; "10.0.0.0/8,192.168.4.7" -> a list of (list octets prefix-bits). A bare
;; address is /32. IPv6 CIDRs are deliberately NOT supported yet and are
;; refused at parse rather than silently ignored — an allowlist entry that does
;; nothing is how an operator comes to believe a network is reachable.
(define (parse-cidr s)
  (and (string? s)
       (let* ([t (string-trim s)]
              [parts (string-split t "/")]
              [addr (if (pair? parts) (car parts) "")]
              [bits (cond [(= (length parts) 1) 32]
                          [(= (length parts) 2) (string->number (cadr parts))]
                          [else #f])]
              [b (ipv4-bytes addr)])
         (and b (exact-integer? bits) (>= bits 0) (<= bits 32) (list b bits)))))

(define (parse-cidr-list v)
  (if (string? v)
      (filter values (map parse-cidr (filter (lambda (x) (not (string=? (string-trim x) "")))
                                             (string-split v ","))))
      '()))

(define (octets->number b)
  (+ (* (first b) 16777216) (* (second b) 65536) (* (third b) 256) (fourth b)))

(define (address-in-cidr? addr cidr)
  (define b (or (ipv4-bytes addr) (embedded-ipv4 addr)))
  (and b
       (let* ([bits (cadr cidr)]
              [mask (if (= bits 0) 0 (arithmetic-shift (- (arithmetic-shift 1 bits) 1) (- 32 bits)))])
         (= (bitwise-and (octets->number b) mask)
            (bitwise-and (octets->number (car cidr)) mask)))))

;; THE WHOLE POLICY, in one function, so the fetcher cannot implement half of it.
;; -> #f when the address may be reached, else the reason it may not.
;;
;; `'trusted` does NOT mean "any private address". It means public, plus the
;; CIDRs the OPERATOR allowed: on a multi-tenant instance a tenant admin who
;; could name any private URL would be reading the instance's own cloud
;; metadata, so the operator owns which networks are reachable and a team names
;; a URL inside them.
(define (address-allowed? addr #:policy [policy 'untrusted] #:allow [allow '()])
  (define k (address-class addr))
  (cond
    [(eq? k 'unparseable) 'unparseable]
    [(eq? k 'public) #f]
    [(and (eq? policy 'trusted)
          (for/or ([c (in-list allow)]) (address-in-cidr? addr c)))
     #f]
    [else k]))
