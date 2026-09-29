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

(provide loopback-address? peer-trusted? parse-peer-allowlist)

;; IPv4 loopback is the whole 127/8 block; IPv6 is ::1, and a v4-mapped v6 peer
;; arrives as ::ffff:127.0.0.1 on a dual-stack listener.
(define (loopback-address? ip)
  (and (string? ip)
       (or (string=? ip "::1")
           (string-prefix? ip "127.")
           (string-prefix? ip "::ffff:127."))))

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
