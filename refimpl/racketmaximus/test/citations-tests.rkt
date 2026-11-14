#lang racket/base

;; test/citations-tests.rkt — the citation rule's one home (RG‑10, #191).
;;
;;   raco test test/citations-tests.rkt
;;
;; Pure: no database, no model. Help's own suite (test/help-tests.rkt) drives
;; the same rules end to end through `help-answer`; this file pins them where
;; they live, so a second asker inherits a tested rule rather than a copy.

(require rackunit racket/file racket/string racket/list racket/runtime-path
         "../domain/ai/citations.rkt"
         (only-in "../domain/help/answer.rkt" HELP-ANSWER-REASONS))

(define-runtime-path ANSWER "../domain/help/answer.rkt")

(test-case "cited-markers reads what a model really writes"
  (check-equal? (cited-markers "see [docs/a.md]") '("docs/a.md"))
  (check-equal? (cited-markers "[docs/a.md] and [docs/b.md], then [docs/a.md] again")
                '("docs/a.md" "docs/b.md") "de-duplicated, in the order cited")
  (check-equal? (cited-markers "spaced [ docs/a.md ]") '("docs/a.md") "trimmed")
  (check-equal? (cited-markers "nothing here") '())
  (check-equal? (cited-markers "a [markdown](link) is not a citation") '("markdown")
                "stated rather than cured: resolution, not this reader, decides what is trusted"))

(test-case "the floor: an empty retrieval and a weak one are one refusal"
  (check-false (floor-admits? #f 0.35))
  (check-false (floor-admits? 0.2 0.35))
  (check-true (floor-admits? 0.35 0.35) "the floor itself admits")
  (check-true (floor-admits? 0.8 0.35)))

(test-case "resolution: by number or by identifier, and nothing else"
  (define offered '("docs/a.md" "docs/b.md" "docs/c.md" "docs/d.md"))
  (define v (verify-citations "per [2] and [docs/d.md], also [9] and [docs/x.md]" offered))
  (check-equal? (hash-ref v 'kept) '("docs/b.md" "docs/d.md"))
  (check-equal? (hash-ref v 'invented) '("9" "docs/x.md")
                "an out-of-range number is invented on the same footing as a path nobody was shown")
  (check-false (hash-ref v 'reason))
  (check-equal? (hash-ref (verify-citations "[1] and [docs/a.md]" offered) 'kept) '("docs/a.md")
                "two spellings of one source are one citation"))

(test-case "an answer that cites nothing is uncited, and still an answer"
  (define v (verify-citations "I could not find that." '("docs/a.md" "docs/b.md")))
  (check-equal? (hash-ref v 'kept) '())
  (check-equal? (hash-ref v 'reason) "uncited")
  (check-equal? (hash-ref (verify-citations "only [docs/zz.md]" '("docs/a.md")) 'reason) "uncited"
                "citing only things that were not offered is citing nothing"))

(test-case "HELP‑22: citing every source is an inventory, from three sources up"
  (define three '("a" "b" "c"))
  (define v (verify-citations "[1] [2] [3]" three))
  (check-equal? (hash-ref v 'reason) "unfocused")
  (check-equal? (hash-ref v 'kept) '() "the claim that they are sources goes")
  (check-false (hash-ref (verify-citations "[1] [2]" three) 'reason) "some of them is an answer")
  (check-false (hash-ref (verify-citations "[1] [2]" '("a" "b")) 'reason)
               "below the minimum, naming both is what citing looks like")
  ;; several passages may share one source: five passages from three files,
  ;; all three cited, is still every source
  (check-equal? (hash-ref (verify-citations "[a] [b] [c]" '("a" "a" "b" "c" "c")) 'reason) "unfocused")
  (check-false (hash-ref (verify-citations "[1] [2] [3]" three #:inventory-min 4) 'reason)
               "the minimum is the caller's to raise")
  (check-equal? CITATION-INVENTORY-MIN 3))

(test-case "help's closed vocabulary carries the rule's two reasons, not copies"
  (check-equal? (take-right HELP-ANSWER-REASONS (length CITATION-REASONS)) CITATION-REASONS)
  (check-equal? (length HELP-ANSWER-REASONS) (length (remove-duplicates HELP-ANSWER-REASONS))))

(test-case "help asks the rule; it does not re-spell it"
  ;; A second copy is the drift RG‑10 exists to prevent, so help's module may
  ;; not carry the marker regexp, an inventory test, or a literal of either
  ;; shared reason. Comment lines are skipped: this file's own prose names them.
  (define code
    (string-join (for/list ([l (in-list (file->lines ANSWER))]
                            #:unless (regexp-match? #px"^\\s*;" l))
                   l)
                 "\n"))
  (check-false (regexp-match? #rx"regexp-match\\*" code) "no marker reader of its own")
  (check-false (regexp-match? #rx"\"unfocused\"|\"uncited\"" code) "no copy of the shared reasons")
  (check-true (regexp-match? #rx"verify-citations" code) "it asks the shared rule"))
