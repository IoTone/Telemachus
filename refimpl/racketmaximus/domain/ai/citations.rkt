#lang racket/base

;; domain/ai/citations.rkt — whether an answer's citations name what was
;; actually retrieved (RG‑10, issue #191; the rules are #183's HELP‑15/‑16/‑22).
;;
;; ONE HOME, TWO ASKERS. In-product help (`domain/help/answer.rkt`) is the first;
;; a research answer over the knowledge graph (#191's RG‑6) is the second. A
;; second copy of these rules is `executor-can-run?`'s drift in the worst place
;; available: the failure is a reader following a citation to a page that says
;; something else, and nothing raises.
;;
;; THREE RULES, and what each caller keeps for itself:
;;
;;   1. THE FLOOR — nothing is composed over passages nothing retrieved
;;      (HELP‑15). The RULE is here; the VALUE stays with each caller, because
;;      it is model- and corpus-dependent and provisional (`HELP-SCORE-FLOOR`
;;      records the measurement that makes it so).
;;   2. RESOLUTION — a citation is kept only if it names something the
;;      retrieval offered, by its 1-based number in the prompt or by the
;;      identifier itself; anything else is DROPPED and reported (HELP‑16).
;;   3. THE INVENTORY — an answer that cites every source it was shown has cited
;;      nothing (HELP‑22, found by the only real-model run: qwen2.5:7b refused
;;      correctly and then named all five passages by way of explaining them).
;;
;; The prompt, the retrieval, the locale and the refusals that mean "there is
;; no corpus" are each caller's own. So is what an identifier IS — a help
;; passage's path, a research passage's object key — which is why this module
;; takes plain strings and knows nothing about a passage's shape.
;;
;; No dependencies, on purpose: both askers must be able to require it without
;; pulling in the other's subsystem.

(require racket/list racket/string)

(provide cited-markers floor-admits? verify-citations
         CITATION-REASONS CITATION-INVENTORY-MIN)

;; The two reasons that belong to the RULE rather than to a caller. A closed
;; vocabulary (#123's line): a caller's own list is its "no corpus" reasons
;; APPENDED to this one, so neither can invent a spelling the other's client
;; does not know.
(define CITATION-REASONS '("uncited" "unfocused"))

;; Citing one of one, or both of two, is what a good answer LOOKS like, so the
;; inventory rule cannot fire below three. The test that pins this needed a
;; tree of its own: a fixture offering two sources made the rule unreachable and
;; the case passed for the wrong reason.
(define CITATION-INVENTORY-MIN 3)

;; Every `[…]` the text carries, in the order it carries them, trimmed and
;; de-duplicated. A bracketed word is indistinguishable from a citation here,
;; which is exactly why resolution, not this reader, decides what is trusted.
(define (cited-markers text)
  (remove-duplicates
   (for/list ([m (in-list (regexp-match* #px"\\[([^\\]\\[]+)\\]" text #:match-select cadr))])
     (string-trim m))))

;; The best score the retrieval produced (or #f for none) against the caller's
;; floor. `#f` when nothing was retrieved, so an empty retrieval and a weak one
;; are refused by the same rule.
(define (floor-admits? top floor)
  (and (real? top) (>= top floor)))

;; `reply`   — the model's answer text.
;; `offered` — the identifiers of the sources, in the order the PROMPT numbered
;;             them (several passages may share one identifier).
;; Answers a hash:
;;   'kept     — identifiers to report as citations, in citation order, unique;
;;   'invented — what the answer named that resolved to nothing, as written;
;;   'reason   — #f, "uncited" or "unfocused".
;; When the answer is an inventory, 'kept is EMPTY: what goes is the claim that
;; they are sources, never the passages themselves, which the caller returns.
(define (verify-citations reply offered #:inventory-min [inv-min CITATION-INVENTORY-MIN])
  (define named (cited-markers reply))
  (define (resolve c)
    (define n (string->number c))
    (cond [(and (exact-integer? n) (>= n 1) (<= n (length offered)))
           (list-ref offered (sub1 n))]
          [(member c offered) c]
          [else #f]))
  (define resolved (remove-duplicates (filter values (map resolve named))))
  (define invented (for/list ([c (in-list named)] #:unless (resolve c)) c))
  (define inventory?
    (and (>= (length offered) inv-min)
         (= (length resolved) (length (remove-duplicates offered)))))
  (define kept (if inventory? '() resolved))
  (hasheq 'kept kept
          'invented invented
          'reason (cond [inventory? "unfocused"]
                        [(null? kept) "uncited"]
                        [else #f])))
