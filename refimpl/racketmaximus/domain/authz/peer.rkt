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

(provide loopback-address? loopback-host? peer-trusted? parse-peer-allowlist)

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

(define (peer-trusted? ip allowlist)
  (and (string? ip)
       (or (loopback-address? ip)
           (and (member ip allowlist) #t))))
