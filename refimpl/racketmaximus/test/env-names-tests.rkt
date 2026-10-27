#lang racket/base

;; test/env-names-tests.rkt — the operator's own variable names (#128 job 2).
;;
;; Job 1 renamed the PROSE and deliberately left the variables alone, because a
;; variable is a contract with every deployment that already exists: a compose
;; file, a systemd unit, a Kubernetes secret, somebody's shell history. So the
;; rename is a DUAL READ with no flag day — `TMACH_<name>` is the name, the old spelling
;; still answers, the new name wins when both are set.
;;
;; THE GATE BELOW IS THE REASON THIS SLICE IS SAFE. The failure mode of a
;; mechanical sweep over 87 call sites is a site that was MISSED — and a missed
;; site goes on working, because the old name is the fallback. It only surfaces
;; for the one operator who sets the new name and nothing else, which is the
;; worst possible audience for it. A static scan over every module is what turns
;; that from unlikely into impossible; it is the route-permission gate's shape
;; (test/route-perm-gate-tests.rkt) applied to the environment.
;;
;;   raco test test/env-names-tests.rkt

(require rackunit racket/string racket/list racket/file racket/path
         racket/runtime-path
         "../config.rkt")

;; ---- 1. the dual read -----------------------------------------------------------

(define (with-env pairs thunk)
  (define saved (for/list ([kv (in-list pairs)]) (cons (car kv) (getenv (car kv)))))
  (dynamic-wind
    (lambda () (for ([kv (in-list pairs)]) (void (putenv (car kv) (cdr kv)))))
    thunk
    ;; `putenv` answers #t, and a `test-case` whose body ends in an internal
    ;; definition HANDS ITS LAST VALUE BACK — which is how a bare #t once got
    ;; printed into the suite output and read like a leak (#91 req 3's note).
    (lambda () (for ([kv (in-list saved)]) (void (putenv (car kv) (or (cdr kv) "")))))))

(test-case "the new name answers"
  (with-env '(("TMACH_UNIT_PROBE" . "new") ("TELEMACHUS_UNIT_PROBE" . ""))
            (lambda () (check-equal? (tmach-env "UNIT_PROBE") "new"))))

;; THE WHOLE POINT OF THE COMPATIBILITY WINDOW: nothing anybody has deployed
;; stops working. If this case ever fails, every existing installation broke.
(test-case "the OLD name still answers, which is the compatibility window itself"
  (with-env '(("TMACH_UNIT_PROBE" . "") ("TELEMACHUS_UNIT_PROBE" . "old"))
            (lambda () (check-equal? (tmach-env "UNIT_PROBE") "old"))))

(test-case "the new name wins when both are set"
  (with-env '(("TMACH_UNIT_PROBE" . "new") ("TELEMACHUS_UNIT_PROBE" . "old"))
            (lambda () (check-equal? (tmach-env "UNIT_PROBE") "new"))))

;; An EMPTY value is absent, which all eight hand-written copies of this helper
;; already did — and it is load-bearing beyond tidiness: CI's sqlite leg sets
;; DATABASE_URL to the empty string, and #123 records a test that passed
;; everywhere except there for exactly this reason.
(test-case "an empty value is absent, under either spelling"
  (with-env '(("TMACH_UNIT_PROBE" . "") ("TELEMACHUS_UNIT_PROBE" . ""))
            (lambda () (check-false (tmach-env "UNIT_PROBE"))))
  (with-env '(("TMACH_UNIT_PROBE" . "   ") ("TELEMACHUS_UNIT_PROBE" . "old"))
            (lambda ()
              (check-equal? (tmach-env "UNIT_PROBE") "old"
                            "whitespace is empty, so the old name is still reached")
              (void))))

(test-case "a default is returned when neither is set, and never when one is"
  (with-env '(("TMACH_UNIT_PROBE" . "") ("TELEMACHUS_UNIT_PROBE" . ""))
            (lambda () (check-equal? (tmach-env "UNIT_PROBE" "fallback") "fallback")))
  (with-env '(("TMACH_UNIT_PROBE" . "set") ("TELEMACHUS_UNIT_PROBE" . ""))
            (lambda () (check-equal? (tmach-env "UNIT_PROBE" "fallback") "set"))))

;; The instance SAYS which old names it is reading, so an operator can migrate
;; one variable at a time instead of auditing the tree. A SET, not a counter: a
;; variable read on every request would otherwise dominate a tally, and what the
;; operator wants is the list.
(test-case "reading an old name is recorded once, by name"
  (with-env '(("TMACH_UNIT_LEGACY" . "") ("TELEMACHUS_UNIT_LEGACY" . "old"))
            (lambda ()
              (void (tmach-env "UNIT_LEGACY"))
              (void (tmach-env "UNIT_LEGACY"))
              (define names (tmach-env-legacy-names))
              (check-equal? (length (filter (lambda (n) (equal? n "UNIT_LEGACY")) names)) 1
                            "recorded once, however often it is read")
              (define w (legacy-env-warning))
              (check-true (string? w))
              (check-true (regexp-match? #rx"TELEMACHUS_UNIT_LEGACY" w)
                          "the note names the variable, so it can be migrated"))))

(test-case "reading only new names records nothing"
  ;; a fresh suffix, so the set from the cases above cannot make this pass
  (with-env '(("TMACH_UNIT_CLEAN" . "yes"))
            (lambda ()
              (void (tmach-env "UNIT_CLEAN"))
              (check-false (member "UNIT_CLEAN" (tmach-env-legacy-names))))))

;; ---- 2. THE GATE ----------------------------------------------------------------
;; Every operator-facing variable must be read through `tmach-env`, never through
;; `getenv` with a literal name. Read as TEXT rather than through Racket's reader
;; because what is being asserted is the SPELLING at the call site, which is a
;; property of the source; the vocabulary gate learned the other half of this
;; lesson, that a text scan reads its own comments, so comment lines are skipped.

;; ANCHORED AT DEFINITION, NEVER AT USE — this file's own rule, paid for once by
;; a blob root that resolved into the Nix store because `serve/servlet` repoints
;; `current-directory` mid-request. A gate that walks the wrong tree passes by
;; looking at nothing, and the first version of this one did exactly that: it
;; reported offenders that had already been fixed, because `current-directory`
;; was not where it assumed.
(define-runtime-path here ".")
(define IMPL (simplify-path (build-path here 'up)))
;; `#:follow-links? #f` IS LOAD-BEARING, and the first version of this gate paid
;; for it: `nix build` leaves a `result` SYMLINK in the implementation directory,
;; `find-files` follows it into the Nix store, and the gate then reads a PACKAGED
;; COPY OF THE SOURCE from before the change. It duly reported offenders that had
;; already been fixed — a gate reading the wrong tree, which is the one failure a
;; gate must not have. Grepping the repository said zero; the gate said twelve.
(define (rkt-files)
  (for/list ([p (in-list (find-files (lambda (p) (regexp-match? #rx"[.]rkt$" (path->string p)))
                                     IMPL #:follow-links? #f))]
             #:unless (regexp-match? #rx"/compiled/|/nix/store/" (path->string p)))
    p))

(define (code-lines path)
  (for/list ([l (in-list (file->lines path))]
             #:unless (regexp-match? #px"^\\s*;" l))
    l))

;; TWO RULES, and the first is stronger than the one this gate started with.
;;
;;   R1  No module spells an operator variable's FULL name. The name is composed
;;       in config.rkt and nowhere else, so a read cannot be written that skips
;;       the fallback — whatever helper it goes through.
;;   R2  …and in particular no read goes through `getenv` and friends with a
;;       literal name, which is R1 restated at the call sites that matter most.
;;
;; R1 REPLACED A NARROWER RULE, AND THE CONFIGURATION GATE IS WHAT FOUND IT.
;; The first version matched `getenv`, `env` and `env*` only — and three more
;; helpers (`pos-env`, `env-int`, `env-num`) read a full literal and were missed
;; by the sweep. Six variables then became documented-but-read-nowhere, which
;; `scripts/check-config-reference.sh` reported by name. A gate that enumerates
;; the helpers it knows about is a gate that agrees with the sweep that wrote it;
;; one that forbids the SPELLING cannot be outflanked by a new helper.
;;
;; Two files mention the old prefix and must: `config.rkt` DEFINES the fallback,
;; and this file proves it works. Named rather than allowlisted by pattern — two
;; exceptions with reasons is not the list of excuses #110 r4 warns about.
(define EXEMPT #rx"/config[.]rkt$|/env-names-tests[.]rkt$")
;; ANY mention on a non-comment line, not merely a fully-quoted literal — and
;; the broadening is the third thing this gate caught. Three suites failed on
;; operator-facing MESSAGES that still named the old variable inside a longer
;; format string ("…(<OLD>_MAX_JOB_SECONDS=~a)"), which a fully-quoted pattern
;; cannot see. A message naming a variable is text an operator acts on, so it
;; has to name the current spelling. Comment-ONLY lines are exempt, because
;; explaining the fallback is legitimate — which is why `code-lines` strips
;; them rather than this pattern trying to.
(define OLD-LITERAL #px"TELEMACHUS_[A-Z0-9_]+")
(define BAD-READ #px"\\((?:getenv|env\\*|env|env-num|env-int|pos-env) \\\"(?:TELEMACHUS|TMACH)_")

(test-case "no module spells an operator variable's full OLD name (R1)"
  (define offenders
    (for*/list ([f (in-list (rkt-files))]
                #:unless (regexp-match? EXEMPT (path->string f))
                [l (in-list (code-lines f))]
                #:when (regexp-match? OLD-LITERAL l))
      (format "~a: ~a" (file-name-from-path f) (string-trim l))))
  (check-equal? offenders '()
                "the name is composed in config.rkt; read it with (tmach-env \"<SUFFIX>\")"))

(test-case "no module reads an operator variable by its literal name (R2)"
  (define offenders
    (for*/list ([f (in-list (rkt-files))]
                #:unless (regexp-match? EXEMPT (path->string f))
                [l (in-list (code-lines f))]
                #:when (regexp-match? BAD-READ l))
      (format "~a: ~a" (file-name-from-path f) (string-trim l))))
  (check-equal? offenders '()))

;; …and both have to be able to FIND one, or they pass by looking at nothing.
;; The route-permission gate leads with the same assertion for the same reason:
;; its first version counted parens, got 83 forms out of 1,600, and passed its
;; way to a wrong answer.
(test-case "the gates can see a bad line when there is one"
  (check-true (regexp-match? OLD-LITERAL "(with-env \"TELEMACHUS_SECRET_KEY\" k thunk)"))
  (check-true (regexp-match? OLD-LITERAL "(error 'x \"no model — set TELEMACHUS_MODEL_URL\")")
              "a MESSAGE naming the old variable, which a quoted-literal pattern missed")
  (check-false (regexp-match? OLD-LITERAL "(tmach-env \"SECRET_KEY\")"))
  (check-true (regexp-match? BAD-READ "(define x (getenv \"TELEMACHUS_PORT\"))"))
  (check-true (regexp-match? BAD-READ "  (env* \"TMACH_BIND\")"))
  (check-true (regexp-match? BAD-READ "(pos-env \"TMACH_OCR_TIMEOUT\" 120)")
              "a helper the first version of this gate had never heard of")
  (check-false (regexp-match? BAD-READ "(tmach-env \"PORT\")"))
  (check-false (regexp-match? BAD-READ "(getenv \"DATABASE_URL\")")
               "an unprefixed variable is not this rename's business"))

(test-case "the suite itself sets the NEW names, so it exercises the primary path"
  ;; A suite that set only the old names would be testing the fallback on every
  ;; run and the primary read never — which is how a dual read rots into a
  ;; single one pointing the wrong way.
  (define offenders
    (for*/list ([f (in-list (rkt-files))]
                [l (in-list (code-lines f))]
                #:when (and (regexp-match? #px"putenv \\\"TELEMACHUS_" l)
                            (not (regexp-match? #rx"env-names-tests" (path->string f)))))
      (format "~a: ~a" (file-name-from-path f) (string-trim l))))
  (check-equal? offenders '()))
