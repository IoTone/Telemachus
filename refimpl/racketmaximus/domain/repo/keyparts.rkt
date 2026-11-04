#lang racket/base

;; domain/repo/keyparts.rkt — somebody else's string, made safe to be a
;; segment of a repository key.
;;
;; THIS IS ONE RULE WITH TWO ASKERS, which is why it is here rather than in
;; either of them. It was written for FEED-16, where a GitHub repository's name
;; becomes part of a pulled item's key; #191's research archive is the second,
;; where a URL's HOST and a slug taken from its PATH become segments of
;; `research/<host>/<slug>-<id8>`. Two copies of a key-safety rule is
;; `executor-can-run?`'s drift in the one place where the consequence is a
;; traversal rather than a wrong answer — which is the move
;; `repo-fields-declare!` and `repo-readable?` already made for their own second
;; askers.
;;
;; It has no dependencies on purpose: `domain/feeds/adapters.rkt` promises in its
;; own header that an adapter never fetches and never writes, so it must be able
;; to ask this without requiring the repository.

(provide safe-key-part)

(require racket/string)

(define (safe-key-part s)
  (define t (string-downcase (format "~a" s)))
  (define cleaned (regexp-replace* #px"[^a-z0-9._-]+" t "-"))
  ;; Dots are kept INSIDE (a source's `v1.2` is a legitimate id, and a host is
  ;; dotted by construction) and trimmed at the EDGES, because `valid-key?`
  ;; refuses a segment that is exactly `.` or `..` and a leading dot is how that
  ;; happens — `../../etc` arriving as a repository name is the case this is
  ;; written for.
  (define collapsed (regexp-replace* #px"-{2,}" cleaned "-"))
  (define trimmed (regexp-replace* #px"^[-.]+|[-.]+$" collapsed ""))
  (if (string=? trimmed "") "x" (substring trimmed 0 (min 64 (string-length trimmed)))))
