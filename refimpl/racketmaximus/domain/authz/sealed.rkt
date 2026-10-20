#lang racket/base

;; domain/authz/sealed.rkt — ONE sealed column, declared once (issue #110 r1).
;;
;; Issue #83 sealed thirteen columns across five modules, and each module wrote
;; the rule out again: a context function to build the AAD, a seal that is
;; conditional on the switch, an unseal that is NOT, and — in three of them — a
;; forgiving unseal for a value a reader should not lose a whole listing over.
;; Five copies of one rule, which is five chances to get the next change wrong.
;;
;; `define-sealed-column` emits the lot from one line. The same move `define-tool`
;; and `define-workflow` already make in this codebase, and for the same reason:
;; the declaration becomes the single statement of intent, and a variant nobody
;; meant to write becomes impossible rather than merely absent.
;;
;; THE AAD IS THE COMPATIBILITY SURFACE, and it is why this module is written with
;; more care than its size suggests. The context string is authenticated DATA in
;; every sealed row ever written: `<table>.<column>:<row-id>` (#19), so a
;; ciphertext moved between rows does not open. Change one of those strings by a
;; character and every existing row for that column stops opening — loudly, which
;; is the one mercy, but irrecoverably without the old string. So the generated
;; context is pinned literal-by-literal in `test/sealed-column-tests.rkt` against
;; the thirteen strings the five modules were already producing.
;;
;; WHAT THE COPIES GOT RIGHT AND WRONG, measured rather than assumed. Four of the
;; five guarded `(string? v)` before calling `secret-wrap` and the fifth
;; (`extract.rkt`) did not — which looks like a divergence and is not one:
;; `secret-wrap` and `secret-unwrap` are both TOTAL (they pass a non-string, and
;; an unwrapped value, straight through). So the guards were redundant with the
;; seam's own contract and the five copies behaved identically. They are dropped
;; here rather than preserved: a guard that duplicates the callee's own is how a
;; reader comes to believe the callee lacks it.

(require (for-syntax racket/base)
         racket/string
         (only-in "secretbox.rkt" secret-wrap secret-unwrap)
         (only-in "../../config.rkt" content-encryption-enabled?))

(provide define-sealed-column sealed-context)

;; `<table>.<column>:<key>[:<key>…]` — the ONE place that format is spelled.
(define (sealed-context column keys)
  (string-append column ":" (string-join keys ":")))

;; (define-sealed-column "jobs.payload" (seal-payload unseal-payload) (id))
;; (define-sealed-column "jobs.error"   (seal-error unseal-error) (id) #:forgiving)
;; (define-sealed-column "doc_trigger_fires.error"
;;                       (seal-fire-error unseal-fire-error) (trigger-id version-id) #:forgiving)
;;
;; The key names are written by the CALLER rather than generated, which keeps the
;; arity checked (a two-key column called with one argument is an error at the
;; call, not a context string with a hole in it) and documents what the row id
;; actually is at the point of declaration.
;;
;; `#:forgiving` is ENC-21's rule, and it exists because the two cases are
;; genuinely different: a PAYLOAD that will not open must raise, because a handler
;; running on an unreadable payload is worse than a refusal, while a stored
;; ERROR MESSAGE that will not open must not take the row it describes down with
;; it — a rotated key should cost a person the diagnostic, never the job's status.
(define-syntax define-sealed-column
  (syntax-rules (:)
    [(_ column (seal-id unseal-id) (key ...))
     (begin
       (define (seal-id key ... v)
         (if (content-encryption-enabled?)
             (secret-wrap (sealed-context column (list key ...)) v)
             v))
       ;; NEVER conditional on the switch: a row sealed while it was on must still
       ;; open after it is turned off, or turning it off would lose the data it was
       ;; turned on to protect.
       (define (unseal-id key ... v)
         (secret-unwrap (sealed-context column (list key ...)) v)))]
    [(_ column (seal-id unseal-id) (key ...) #:forgiving)
     (begin
       (define-sealed-column column (seal-id unseal-id/strict) (key ...))
       (define (unseal-id key ... v)
         (with-handlers ([exn:fail? (lambda (_) "(the stored message could not be decrypted)")])
           (unseal-id/strict key ... v))))]))
