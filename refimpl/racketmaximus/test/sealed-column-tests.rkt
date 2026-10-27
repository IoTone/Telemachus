#lang racket/base

;; test/sealed-column-tests.rkt — `define-sealed-column` (issue #110 r1).
;;
;;   raco test test/sealed-column-tests.rkt
;;
;; The macro replaces five hand-written copies of issue #83's sealing rule. The
;; risk it carries is not "does it compile" — it is that the AAD is
;; AUTHENTICATED DATA in every sealed row ever written. Change a context string
;; by one character and every existing row for that column stops opening.
;;
;; So the first two cases are compatibility, not behaviour:
;;
;;   1. the generated context is byte-identical to the string each of the five
;;      modules was already building, pinned literal by literal
;;   2. a row sealed the OLD way — `secret-wrap` called with the hand-built
;;      string — opens through the GENERATED unseal
;;
;; Case 2 is the one that matters. Case 1 could pass while both sides were
;; changed together; case 2 cannot, because the "old" ciphertext in it is built
;; from a literal written out here by hand.

(require rackunit racket/string
         "../domain/authz/sealed.rkt"
         (only-in "../domain/authz/secretbox.rkt" secret-wrap secret-unwrap wrapped-secret?))

(define (with-env name value thunk)
  (define saved (getenv name))
  (dynamic-wind (lambda () (putenv name value)) thunk
                (lambda () (putenv name (or saved "")))))

(define (sealed thunk)
  (with-env "TMACH_SECRET_KEY" (make-string 64 #\a)
    (lambda () (with-env "TMACH_ENCRYPT_CONTENT" "1" thunk))))

;; the thirteen columns, declared exactly as the five modules now declare them
(define-sealed-column "jobs.payload"             (s-payload u-payload) (id))
(define-sealed-column "jobs.result"              (s-result u-result) (id))
(define-sealed-column "jobs.error"               (s-joberr u-joberr) (id) #:forgiving)
(define-sealed-column "workflow_runs.input"      (s-rin u-rin) (id))
(define-sealed-column "workflow_runs.output"     (s-rout u-rout) (id))
(define-sealed-column "workflow_runs.cursor"     (s-rcur u-rcur) (id))
(define-sealed-column "workflow_runs.error"      (s-rerr u-rerr) (id) #:forgiving)
(define-sealed-column "workflow_steps.input"     (s-sin u-sin) (id))
(define-sealed-column "workflow_steps.output"    (s-sout u-sout) (id))
(define-sealed-column "workflow_steps.error"     (s-serr u-serr) (id) #:forgiving)
(define-sealed-column "repo_text.content"        (s-text u-text) (object-id))
(define-sealed-column "repo_text.spans"          (s-spans u-spans) (object-id))
(define-sealed-column "translations.source_text" (s-src u-src) (id))
(define-sealed-column "translations.result_text" (s-res u-res) (id))
(define-sealed-column "doc_trigger_fires.error"  (s-fire u-fire) (trigger-id version-id) #:forgiving)

;; ---- 1. the context format, pinned ----------------------------------------------
(test-case "the generated AAD is byte-identical to what the five modules built"
  ;; one key: `<table>.<column>:<id>`
  (check-equal? (sealed-context "jobs.payload" (list "J1")) "jobs.payload:J1")
  (check-equal? (sealed-context "repo_text.content" (list "O1")) "repo_text.content:O1")
  ;; the cursor's context says `cursor` while the COLUMN is `cursor_json` — a
  ;; mismatch that is now load-bearing history, because rows exist with it
  (check-equal? (sealed-context "workflow_runs.cursor" (list "R1")) "workflow_runs.cursor:R1")
  ;; two keys, joined with ":" — doc_trigger_fires has no single id column
  (check-equal? (sealed-context "doc_trigger_fires.error" (list "T1" "V1"))
                "doc_trigger_fires.error:T1:V1"))

;; ---- 2. THE COMPATIBILITY CASE ---------------------------------------------------
(test-case "a row sealed the OLD way opens through the generated unseal"
  (sealed
   (lambda ()
     ;; Sealed exactly as the pre-macro code did it: `secret-wrap` with the
     ;; context string hand-built at the call site. These literals are the
     ;; old code, transcribed.
     (define old-payload (secret-wrap (string-append "jobs.payload:" "J1") "the payload"))
     (define old-text    (secret-wrap (string-append "repo_text.content:" "O1") "the text"))
     (define old-src     (secret-wrap (string-append "translations.source_text:" "X1") "quelle"))
     (define old-fire    (secret-wrap (string-append "doc_trigger_fires.error:" "T1" ":" "V1") "boom"))
     ;; …and opened by the generated functions. If an AAD had drifted, these
     ;; raise rather than return a wrong answer — secretbox refuses to open a
     ;; ciphertext whose AAD does not match.
     (check-equal? (u-payload "J1" old-payload) "the payload")
     (check-equal? (u-text "O1" old-text) "the text")
     (check-equal? (u-src "X1" old-src) "quelle")
     (check-equal? (u-fire "T1" "V1" old-fire) "boom")
     ;; and the ciphertext really was sealed, or the assertions above pass on
     ;; plaintext and prove nothing
     (check-true (string-prefix? old-payload "enc:v1:") "the fixture must be ciphertext"))))

;; ---- 3. the rule itself ----------------------------------------------------------
(test-case "seal is conditional on the switch; unseal never is"
  (define plain
    (with-env "TMACH_SECRET_KEY" (make-string 64 #\b)
      (lambda () (with-env "TMACH_ENCRYPT_CONTENT" ""
                   (lambda () (s-payload "J2" "visible"))))))
  (check-equal? plain "visible" "with the switch off, nothing is sealed")
  ;; a row sealed while the switch was ON must still open after it is turned OFF,
  ;; or turning it off would lose the data it was turned on to protect
  (define ct (sealed (lambda () (s-payload "J3" "secret"))))
  (check-true (string-prefix? ct "enc:v1:"))
  (check-equal? (with-env "TMACH_SECRET_KEY" (make-string 64 #\a)
                  (lambda () (u-payload "J3" ct)))
                "secret"
                "the unseal is unconditional"))

(test-case "a ciphertext moved between rows does NOT open (#19's AAD rule)"
  (sealed
   (lambda ()
     (define ct (s-payload "J4" "row four"))
     (check-equal? (u-payload "J4" ct) "row four")
     ;; the same column, a different row id: the AAD differs, so it must refuse
     (check-exn exn:fail? (lambda () (u-payload "J5" ct)))
     ;; the same row id, a different COLUMN: likewise
     (check-exn exn:fail? (lambda () (u-result "J4" ct))))))

(test-case "a non-string, and an unwrapped value, pass straight through"
  ;; The four hand-written copies guarded `(string? v)` and the fifth did not.
  ;; That was NOT a divergence: secret-wrap and secret-unwrap are both total, so
  ;; the guards duplicated the seam's own contract. The guards are gone; this
  ;; pins the property they were there for.
  (sealed
   (lambda ()
     (check-equal? (s-payload "J6" 'null) 'null)
     (check-equal? (u-payload "J6" 'null) 'null)
     (check-equal? (u-payload "J6" "never sealed") "never sealed"))))

;; ---- 4. the forgiving variant (ENC-21) -------------------------------------------
(test-case "a forgiving unseal reports rather than raising; a strict one raises"
  (sealed
   (lambda ()
     (define ct (s-joberr "J7" "could not read a total"))
     (check-equal? (u-joberr "J7" ct) "could not read a total")
     ;; the wrong row: a diagnostic must not take the row it describes down with
     ;; it, so the forgiving one answers with a note
     (check-equal? (u-joberr "J8" ct) "(the stored message could not be decrypted)")
     ;; while a payload in the same situation RAISES, because a handler running
     ;; on an unreadable payload is worse than a refusal
     (define pct (s-payload "J7" "{}"))
     (check-exn exn:fail? (lambda () (u-payload "J8" pct))))))

;; ---- 5. a credential is not content (#114) -----------------------------------------
;; The default seal is conditional on `TELEMACHUS_ENCRYPT_CONTENT`, which is right
;; for extracted text — sealing it costs content search, so it waits to be asked
;; for. It is WRONG for a replayable credential, and #85's `webhooks.secret` was
;; the first credential declared through this macro: with a key configured and the
;; content switch off, which is the DOCUMENTED DEFAULT, its signing secret was
;; written in the clear while `CREDENTIAL-SECRETS` said it was sealed.
;;
;; Both directions are asserted, because the content gate is still correct for
;; content and an over-correction here would start sealing extracted text on every
;; instance that set a key.
(define-sealed-column "feeds.secret"    (s-feed u-feed) (id) #:credential)
(define-sealed-column "webhooks.secret" (s-hook u-hook) (id) #:credential)

(define (keyed-no-content thunk)
  (with-env "TMACH_SECRET_KEY" (make-string 64 #\a)
    (lambda () (with-env "TMACH_ENCRYPT_CONTENT" "" thunk))))

(test-case "a credential column seals with a key alone; a content column waits for the switch"
  (keyed-no-content
   (lambda ()
     (define ct (s-feed "F1" "t0p-s3cret"))
     (check-true (wrapped-secret? ct))
     (check-false (regexp-match? #rx"t0p-s3cret" ct))
     (check-equal? (u-feed "F1" ct) "t0p-s3cret")
     (check-true (wrapped-secret? (s-hook "W1" "signing-key")))
     ;; THE CONTROL. In the same environment a CONTENT column is untouched, so
     ;; this case cannot pass by sealing everything — which would silently remove
     ;; content search from every instance with a key.
     (check-equal? (s-payload "J9" "{\"a\":1}") "{\"a\":1}")
     (check-false (wrapped-secret? (s-payload "J9" "{\"a\":1}")))))
  ;; …and with no key at all, nothing is sealed and the value passes through
  (with-env "TMACH_SECRET_KEY" ""
    (lambda ()
      (check-equal? (s-feed "F1" "t0p-s3cret") "t0p-s3cret")))
  ;; the AAD is the compatibility surface for these two as well
  (check-equal? (sealed-context "feeds.secret" '("F1")) "feeds.secret:F1")
  (check-equal? (sealed-context "webhooks.secret" '("W1")) "webhooks.secret:W1"))
