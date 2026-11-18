#lang racket/base

;; domain/authz/peer.rkt — is this request's peer allowed to assert identity in a
;; HEADER rather than with a token? (issue #40)
;;
;; `X-Telemachus-User` / `-Team` are a LOCAL convenience: a script on the box acts
;; as somebody without minting a token. Until this gate they were a login, and on
;; an instance bound to a network address that meant anyone on the network was
;; whoever they claimed to be — ahead of RBAC, scopes, the org gate and session
;; policy, none of which run before a principal exists.
;;
;; A tiny module of its own because the rule is worth testing directly: main.rkt
;; can only be exercised through a live server, and "who is trusted" is exactly
;; the kind of predicate that should not need one.

(require racket/string)

(provide loopback-address? loopback-host? peer-trusted? parse-peer-allowlist
         FORWARDING-HEADERS loopback-trust-on?
         forwarded-address forwarded-client-ip)

;; IPv4 loopback is the whole 127/8 block; IPv6 is ::1, and a v4-mapped v6 peer
;; arrives as ::ffff:127.0.0.1 on a dual-stack listener.
(define (loopback-address? ip)
  (and (string? ip)
       (or (string=? ip "::1")
           (string-prefix? ip "127.")
           (string-prefix? ip "::ffff:127."))))

;; The same question asked about a NAME rather than a connected peer: a bind
;; address, or the host of a backend URL, may be written as `localhost` or
;; bracketed, neither of which a peer ever arrives as. Normalize those and let
;; the predicate above answer.
;;
;; THREE ASKERS NOW, which is why it lives here rather than beside any of them:
;; `loopback-bind?` (the TLS startup warning), and the model-request log's
;; "hosted" column and the no-content-logging policy (RED-21). A second copy and
;; the three would drift about what counts as private — the drift this module's
;; header already warns against.
;;
;; A name that is neither loopback nor an address is NOT loopback. 10.x is
;; somebody else's network (the rule below), and an unresolvable name has to fail
;; toward the stricter answer: calling an unknown host local would exempt it from
;; a policy that exists for exactly the hosts nobody can place.
(define (loopback-host? h)
  (define s (string-downcase (string-trim (or h ""))))
  (or (string=? s "localhost")
      (loopback-address? (if (regexp-match? #px"^\\[.*\\]$" s)
                             (substring s 1 (sub1 (string-length s)))
                             s))))

;; A deployment behind a trusted reverse proxy may name that proxy's address, and
;; must: nothing here treats a private-looking address as trusted on its own,
;; because "10.x is internal" is an assumption about somebody else's network.
(define (parse-peer-allowlist v)
  (if (string? v)
      (filter (lambda (s) (not (string=? s ""))) (map string-trim (string-split v ",")))
      '()))

;; A LOOPBACK PEER IS ONLY THE BOX ITSELF WHEN NOTHING FORWARDED THE REQUEST.
;; A reverse proxy on this host (`tailscale serve`, nginx, caddy) connects from
;; 127.0.0.1 on behalf of whoever called it, so behind one EVERY request has a
;; loopback peer and the rule above would hand a principal to anyone who can
;; reach the proxy and type a username into a header. Two defences, because
;; neither is enough alone:
;;
;;   • a request carrying any header a proxy adds is not local, whatever its
;;     peer address. The caller cannot remove what the proxy appends, and a
;;     script on the box has no reason to send one.
;;   • `TMACH_LOOPBACK_TRUST=off` withdraws loopback's standing altogether, for
;;     a proxy that adds no such header. Identity then needs a token and
;;     bootstrap needs TMACH_BOOTSTRAP_SECRET.
;;
;; A peer the operator NAMED in the allowlist is exempt from the first rule on
;; purpose: it is a proxy trusted to assert identity, and it will be sending
;; forwarding headers as a matter of course.
(define FORWARDING-HEADERS
  '(#"x-forwarded-for" #"x-forwarded-host" #"x-forwarded-proto" #"x-forwarded-server"
    #"forwarded" #"x-real-ip" #"via"))

;; On unless switched off by name. An unrecognised value keeps the default, as
;; every default-bearing setting here does.
(define (loopback-trust-on? v)
  (not (and (string? v)
            (member (string-downcase (string-trim v)) '("0" "off" "false" "no"))
            #t)))

(define (peer-trusted? ip allowlist #:forwarded? [forwarded? #f] #:loopback? [loopback? #t])
  (and (string? ip)
       (or (and (member ip allowlist) #t)
           (and loopback? (not forwarded?) (loopback-address? ip)))))

;; ---- which address is calling, behind a proxy -------------------------------
;; Behind a reverse proxy every connection comes from the proxy, so every caller
;; shares one address: the per-address sign-in and redemption limits treat all
;; users as one, and the audit log records the proxy for every request. The
;; proxy writes the real address into `X-Forwarded-For`, and this is the rule for
;; when to believe it.
;;
;; ONLY FROM A PROXY THE OPERATOR NAMED (`TMACH_TRUSTED_PROXIES`). The header is
;; plain text, so from any other peer it is whatever the caller typed, and
;; believing it would let anyone pick a fresh address per attempt and walk past
;; the limit. With nothing configured this answers the peer, which is what the
;; platform did before.
;;
;; READ FROM THE RIGHT. Each proxy appends the address it received the request
;; from, so the rightmost entry was written by our own proxy and the entries to
;; its left are whatever arrived, including anything the caller put there. Skip
;; entries that are themselves trusted proxies (a chain of two) and take the
;; first that is not. Taking the leftmost is the common mistake: that entry is
;; the caller's to forge.
;;
;; ANYTHING UNREADABLE ANSWERS THE PEER. A caller must never be able to choose
;; their own limiter key, so a hop that is not an address ends the walk on the
;; stricter side: the shared address of the proxy.
;;
;; This is NOT the peer gate's question. Whether a request may assert identity
;; in a header, or bootstrap, is decided on the connection's real peer
;; (`peer-trusted?`), never on an address read out of a header.

;; One `X-Forwarded-For` entry as an address, or #f. Proxies write a bare
;; address; some add a port (`1.2.3.4:5678`, `[2001:db8::1]:5678`).
(define (forwarded-address raw)
  (define s (string-downcase (string-trim (if (string? raw) raw ""))))
  (define bare
    (cond
      [(regexp-match #px"^\\[([^\\]]*)\\](?::[0-9]+)?$" s) => cadr]
      [(regexp-match #px"^([0-9.]+):[0-9]+$" s) => cadr]
      [else s]))
  (and (<= 2 (string-length bare) 45)
       (regexp-match? #px"^[0-9a-f:.]+$" bare)
       bare))

;; `peer` is the connection's address (or #f), `values` the request's
;; `X-Forwarded-For` header values in the order they arrived, `proxies` the
;; addresses the operator trusts to report one.
(define (forwarded-client-ip peer values proxies)
  (cond
    [(not (and (string? peer) (member peer proxies))) peer]
    [else
     (define hops
       (reverse (apply append (map (lambda (v) (string-split v ",")) values))))
     (let loop ([hops hops])
       (cond
         [(null? hops) peer]
         [else
          (define a (forwarded-address (car hops)))
          (cond
            [(not a) peer]
            [(member a proxies) (loop (cdr hops))]
            [else a])]))]))
