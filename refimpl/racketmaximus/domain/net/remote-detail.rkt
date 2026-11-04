#lang racket/base

;; domain/net/remote-detail.rkt — somebody else's server's own words, made safe
;; to put in a message that outlives the call (issue #186, SEC-12).
;;
;; ONE RULE, FOUR ASKERS, AND THEY DID NOT AGREE. SEC-8 made
;; `provider-detail` the one home for the model, embedding and transcription
;; seams and recorded a fourth asker outside it — `domain/mcp/client.rkt`,
;; which formats a remote MCP server's `error.message` whole. Writing that one
;; home turned up a fifth and a behaviour difference that matters more than the
;; duplication:
;;
;;   • `provider-detail` CAPS and does not strip control characters;
;;   • `mail/transport.rkt`'s `clip` + `printable` cap AND strip them;
;;   • `mcp/client.rkt` did neither.
;;
;; **The mail pair was the right one.** Its own comment says "no forged log
;; lines is a property every message wants", and that applies hardest to the
;; model seam rather than least: `provider-detail`'s output goes into an
;; exception message which reaches a SEALED `error` column *and* stderr, which
;; #83 r4 names as the copy most likely to be read by a person. A remote
;; provider that puts a CRLF and a plausible-looking line in its own `error`
;; string therefore wrote into this instance's container log. Nothing had
;; noticed because the three model seams were compared against each other and
;; the one that had the answer was in another subsystem.
;;
;; TWO HALVES, KEPT SEPARATE, because they are two decisions. What is printable
;; is a property every message wants and has no knob; HOW MUCH to keep is a
;; number with a different right answer per caller — 200 characters of a relay's
;; reply routinely cuts off the part that says why, which is `transport.rkt`'s
;; own recorded reason for not sharing one constant.
;;
;; No dependencies, on purpose: the askers are an HTTP seam, an SMTP transport
;; and a JSON-RPC client over stdio, and none of them should have to require
;; either of the others to ask what is safe to quote.

(provide printable-text clip-text remote-detail REMOTE-DETAIL-MAX)

;; Control characters become `?`. Never dropped: a value whose length changes
;; silently is one a reader cannot compare with what the far end claims it sent.
(define (printable-text a)
  (regexp-replace* #px"[\x00-\x1f\x7f]" (if (string? a) a (format "~a" a)) "?"))

;; Bound it, SAYING it was cut. A sentence that merely stops is one a reader does
;; not trust — and the detail is kept rather than dropped, because
;; `invalid_api_key` is the only diagnostic an operator has for a backend that
;; will not answer. SEC-8's distinction from SEC-7 holds: there the value was
;; content the caller already had and the TYPE was the information; here the
;; text IS the answer.
(define (clip-text s n)
  (if (> (string-length s) n) (string-append (substring s 0 n) "… (truncated)") s))

(define REMOTE-DETAIL-MAX 400)

;; Both halves, for a caller that has already dug its own field out of whatever
;; shape its protocol uses — `resp.error` for an OpenAI-compatible endpoint,
;; `resp.error.message` for JSON-RPC, a reply line for SMTP. THE FIELD PATH IS
;; THE PROTOCOL'S BUSINESS; the bound and the printability are not.
(define (remote-detail v #:max [n REMOTE-DETAIL-MAX] #:absent [absent "no detail"])
  (cond
    [(or (not v) (and (string? v) (string=? v ""))) absent]
    [else (clip-text (printable-text v) n)]))
