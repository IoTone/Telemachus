#lang racket/base

;; test/embed-tests.rkt — the embedding wire, the label store, and the
;; nearest-label backend (issue #163).
;;   raco test test/embed-tests.rkt
;;
;; Four layers, none of which needs a socket or a model:
;;   1. the RESPONSE reader as a pure function — the half where a mistake does
;;      not raise, it classifies confidently and wrongly for ever
;;   2. cosine and the label-text composition, pure
;;   3. the store against a real database: caching, staleness, and the two
;;      invalidation rules that differ (one label vs the whole document)
;;   4. the backend: the margin, and the two cases it declines rather than guesses

(require rackunit db-kit/portable
         racket/list
         db-kit/migrate
         "../domain/db/migrations.rkt"
         "db-fixture.rkt"
         (only-in "../domain/ai/executor.rkt" embedding-vectors embedding-tokens
                  embed-exchange embed-configured? log-model-request!)
         (only-in "../domain/ai/requestlog.rkt" REQUEST-OPERATIONS)
         (only-in "../domain/ai/embedstore.rkt"
                  cosine label-embed-text label-vectors embed-store-read label-cache-key)
         (only-in "../domain/repo/classify.rkt"
                  classify-embed CLASSIFY-BACKENDS CLASSIFY-BACKENDS-DEFAULT backends-problem EMBED-MARGIN-SCALE))

;; ---- 1. the response reader -------------------------------------------------
;; THE INDEX IS THE WHOLE POINT OF THIS LAYER. A server may answer out of order,
;; the field exists to say so, and pairing the wrong vector with the wrong label
;; does not fail — it produces a confident wrong classification that every figure
;; in the evaluation harness would blame on the model.

(define (resp data #:usage [usage (hasheq)])
  (hasheq 'data data 'usage usage))

(define (datum i v) (hasheq 'index i 'embedding v))

(test-case "a response is read by INDEX, not by position"
  (define r (resp (list (datum 2 '(0.0 0.0 1.0))
                        (datum 0 '(1.0 0.0 0.0))
                        (datum 1 '(0.0 1.0 0.0)))))
  (define vs (embedding-vectors r 3 'test))
  (check-equal? (vector-ref (list-ref vs 0) 0) 1.0 "input 0 got the vector labelled index 0")
  (check-equal? (vector-ref (list-ref vs 1) 1) 1.0)
  (check-equal? (vector-ref (list-ref vs 2) 2) 1.0))

(test-case "…and an absent index falls back to arrival order"
  ;; some servers omit it; position is then the only thing on offer and is right
  (define vs (embedding-vectors (resp (list (hasheq 'embedding '(1.0 0.0))
                                            (hasheq 'embedding '(0.0 1.0))))
                                2 'test))
  (check-equal? (vector-ref (list-ref vs 0) 0) 1.0)
  (check-equal? (vector-ref (list-ref vs 1) 1) 1.0))

(test-case "a response that cannot be trusted is refused, by shape"
  ;; fewer vectors than inputs: the caller would otherwise pair them off by
  ;; position and be wrong about every label after the gap
  (check-exn #rx"1 vector" (lambda () (embedding-vectors (resp (list (datum 0 '(1.0)))) 2 'test)))
  ;; an index outside the request
  (check-exn #rx"index 5" (lambda () (embedding-vectors (resp (list (datum 5 '(1.0)))) 1 'test)))
  ;; the same index twice — one input would be silently unanswered
  (check-exn #rx"twice" (lambda () (embedding-vectors (resp (list (datum 0 '(1.0)) (datum 0 '(1.0))))
                                                      2 'test)))
  ;; not a vector at all
  (check-exn #rx"no usable vector"
             (lambda () (embedding-vectors (resp (list (hasheq 'index 0 'embedding "nope"))) 1 'test)))
  ;; differing widths: cosine would raise deep in the arithmetic instead of here,
  ;; where the endpoint can be named
  (check-exn #rx"differing widths"
             (lambda () (embedding-vectors (resp (list (datum 0 '(1.0 2.0)) (datum 1 '(1.0))))
                                           2 'test))))

(test-case "the token count is the INPUT count, and absent means absent"
  (check-equal? (embedding-tokens (resp '() #:usage (hasheq 'prompt_tokens 42))) 42)
  ;; total_tokens is the same number for an embedding and is accepted
  (check-equal? (embedding-tokens (resp '() #:usage (hasheq 'total_tokens 7))) 7)
  ;; a provider that said nothing bills nothing — never an estimate, which is
  ;; what the agent used to do and was wrong by two orders of magnitude
  (check-false (embedding-tokens (resp '())))
  (check-false (embedding-tokens (resp '() #:usage (hasheq 'prompt_tokens "many")))))

;; ---- 2. cosine and the label text -------------------------------------------

(test-case "cosine, including the cases that have no answer"
  (check-= (cosine (vector 1.0 0.0) (vector 1.0 0.0)) 1.0 1e-9)
  (check-= (cosine (vector 1.0 0.0) (vector 0.0 1.0)) 0.0 1e-9)
  (check-= (cosine (vector 1.0 0.0) (vector 2.0 0.0)) 1.0 1e-9 "magnitude does not matter")
  ;; A ZERO VECTOR HAS NO DIRECTION, so its similarity is undefined rather than
  ;; 0 — answering 0 would make it the WORST match, which is a claim. Providers
  ;; really do return one for empty input.
  (check-false (cosine (vector 0.0 0.0) (vector 1.0 0.0)))
  (check-false (cosine (vector 1.0 0.0) (vector 1.0 0.0 0.0)) "different widths do not compare")
  (check-false (cosine (vector) (vector))))

(test-case "what gets embedded for a label is name, description and examples"
  (check-equal? (label-embed-text (hasheq 'name "invoice"
                                          'description "a bill"
                                          'examples '("total due" "VAT")))
                "invoice\na bill\ntotal due\nVAT")
  ;; a label is often only a word, and that word is the signal
  (check-equal? (label-embed-text (hasheq 'name "invoice")) "invoice")
  ;; an absent description must not leave a blank line, or two labels differing
  ;; only in whether they have one would hash differently for no reason
  (check-equal? (label-embed-text (hasheq 'name "a" 'description "" 'examples '())) "a"))

;; ---- 3. the store -----------------------------------------------------------

(define TEAM "team-embed")

;; a deterministic stand-in for an embedding model: the vector is a function of
;; the text, so "was this re-embedded" is answerable without a network
(define (fake-embed texts)
  (values (for/list ([t (in-list texts)])
            (vector (exact->inexact (string-length t))
                    (exact->inexact (for/sum ([c (in-string t)]) (char->integer c)))))
          (* 2 (length texts))))

;; `label-vectors` answers TWO values, so `(void (label-vectors …))` is an arity
;; error rather than a discard — the third appearance of that shape in this tree.
(define-syntax-rule (discard e) (call-with-values (lambda () e) void))

(define (counting-embed box)
  (lambda (texts)
    (set-box! box (append (unbox box) (list texts)))
    (fake-embed texts)))

(define L1 (hasheq 'name "invoice" 'description "a bill"))
(define L2 (hasheq 'name "letter" 'description "correspondence"))

(test-case "the label vectors are embedded once and then cached"
  (define c (fresh-db))
  (define calls (box '()))
  (define-values (v1 t1) (label-vectors c TEAM (list L1 L2) "m1" #:embed (counting-embed calls)))
  (check-equal? (length (unbox calls)) 1 "one batched call, not one per label")
  (check-equal? (length (car (unbox calls))) 2)
  (check-equal? t1 4 "…and it reported what it spent")
  (check-true (vector? (hash-ref v1 'invoice)))
  ;; second time: nothing is embedded and nothing is billed
  (define-values (v2 t2) (label-vectors c TEAM (list L1 L2) "m1" #:embed (counting-embed calls)))
  (check-equal? (length (unbox calls)) 1 "the cache answered")
  (check-equal? t2 0 "a cached label set spends nothing, so it bills nothing")
  (check-equal? (hash-ref v2 'invoice) (hash-ref v1 'invoice))
  (close-db! c))

(test-case "editing ONE label re-embeds ONE label"
  ;; the source-hash rule locales/ja.json and the caption catalogs already live
  ;; by: the vector carries the sha1 of the text it was made from
  (define c (fresh-db))
  (define calls (box '()))
  (discard (label-vectors c TEAM (list L1 L2) "m1" #:embed (counting-embed calls)))
  (define L2* (hasheq 'name "letter" 'description "a letter from somebody"))
  (define-values (v _t) (label-vectors c TEAM (list L1 L2*) "m1" #:embed (counting-embed calls)))
  (check-equal? (length (unbox calls)) 2)
  (check-equal? (cadr (unbox calls)) (list (label-embed-text L2*))
                "only the edited label was sent")
  (check-equal? (hash-ref v 'invoice)
                (let-values ([(vs _) (fake-embed (list (label-embed-text L1)))]) (car vs))
                "…and the untouched one kept its vector")
  (close-db! c))

(test-case "changing the MODEL invalidates everything"
  ;; EMB-8. Vectors from two checkpoints are not comparable, and mixing them does
  ;; not raise — it produces a number, and therefore a confident classification
  ;; nobody can tell is nonsense.
  (define c (fresh-db))
  (define calls (box '()))
  (discard (label-vectors c TEAM (list L1 L2) "m1" #:embed (counting-embed calls)))
  (discard (label-vectors c TEAM (list L1 L2) "m2" #:embed (counting-embed calls)))
  (check-equal? (length (cadr (unbox calls))) 2 "both labels were re-embedded, not one")
  ;; and the cache now belongs to the new model
  (check-equal? (hash-count (embed-store-read c TEAM "m2")) 2)
  (check-equal? (hash-count (embed-store-read c TEAM "m1")) 0
                "a cache from another checkpoint is not a cache")
  (close-db! c))

(test-case "a label removed from the set loses its vector"
  (define c (fresh-db))
  (discard (label-vectors c TEAM (list L1 L2) "m1" #:embed fake-embed))
  ;; the edit that drops L2 also re-embeds nothing, so the write has to happen
  ;; on the strength of a change the caller made rather than a stale entry
  (define L1* (hasheq 'name "invoice" 'description "a bill, revised"))
  (discard (label-vectors c TEAM (list L1*) "m1" #:embed fake-embed))
  (check-equal? (hash-count (embed-store-read c TEAM "m1")) 1
                "a vector for a label nobody can be classified into is dead weight")
  (close-db! c))

;; ---- 4. the backend ---------------------------------------------------------

(define (vecs-for h) (lambda (_labels) h))
(define (doc-vec v) (lambda (_t) v))

(test-case "the nearest label wins, and the confidence is the MARGIN"
  ;; cosine against a label is uncalibrated — ordinary English documents score
  ;; 0.6-0.9 against everything — so the top similarity says nothing. The gap to
  ;; the runner-up is what carries information.
  (define near (hasheq 'invoice (vector 1.0 0.0) 'letter (vector 0.0 1.0)))
  (define r (classify-embed (list L1 L2) "anything"
                            #:embed-doc (doc-vec (vector 1.0 0.0))
                            #:label-vectors (vecs-for near)))
  (check-equal? (hash-ref r 'label) "invoice")
  (check-equal? (hash-ref r 'source) "embed")
  (check-= (hash-ref r 'confidence) 1.0 1e-9 "1.0 vs 0.0 is the widest margin there is")
  (check-true (regexp-match? #rx"invoice" (hash-ref r 'rationale))))

(test-case "a document equally close to two labels scores ~0, which is the review case"
  ;; CLS-13 parks a run below a confidence threshold; a backend whose confidence
  ;; could not reach 0 would never park anything.
  (define h (hasheq 'invoice (vector 1.0 0.0) 'letter (vector 1.0 0.0)))
  (define r (classify-embed (list L1 L2) "anything"
                            #:embed-doc (doc-vec (vector 1.0 0.0))
                            #:label-vectors (vecs-for h)))
  (check-= (hash-ref r 'confidence) 0.0 1e-9)
  ;; and a small margin scales rather than saturating
  (define h2 (hasheq 'invoice (vector 1.0 0.0) 'letter (vector 0.99 0.141)))
  (define r2 (classify-embed (list L1 L2) "x"
                             #:embed-doc (doc-vec (vector 1.0 0.0))
                             #:label-vectors (vecs-for h2)))
  (check-true (< 0.0 (hash-ref r2 'confidence) 1.0) "a near tie is a low confidence, not zero"))

(test-case "it DECLINES rather than guessing, in the three cases with no margin"
  ;; one label: no runner-up, so no margin. Reporting 1.0 would claim a
  ;; comparison that was never made — and a one-label set means every document
  ;; is an invoice, which a rule says better and for nothing.
  ;;
  ;; IT MUST DECLINE WITHOUT SPENDING, and that is what this asserts rather than
  ;; the mere #f. A positive control taught it: inverting the one-label guard
  ;; still answered #f, because the "fewer than two comparable vectors" guard
  ;; below catches the same case — so the first guard looked redundant. It is
  ;; not. What it uniquely does is decline BEFORE calling the two seams, each of
  ;; which is a metered request to a model. Testing only the answer could not
  ;; see the difference between declining and paying to decline.
  (define spent (box 0))
  (define (counting v) (lambda (_x) (set-box! spent (add1 (unbox spent))) v))
  (check-false (classify-embed (list L1) "x"
                               #:embed-doc (counting (vector 1.0))
                               #:label-vectors (counting (hasheq 'invoice (vector 1.0)))))
  (check-equal? (unbox spent) 0 "a set with no runner-up costs nothing to decline")
  ;; no text: there is nothing to be near to
  (check-false (classify-embed (list L1 L2) "   "
                               #:embed-doc (doc-vec (vector 1.0 0.0))
                               #:label-vectors (vecs-for (hasheq))))
  ;; only one label's vector could be computed — declining passes the document to
  ;; the next backend rather than picking between the ones that happened to work
  (check-false (classify-embed (list L1 L2) "x"
                               #:embed-doc (doc-vec (vector 1.0 0.0))
                               #:label-vectors (vecs-for (hasheq 'invoice (vector 1.0 0.0))))))

;; ---- the vocabulary and the refusals ----------------------------------------

(test-case "`embed` is a backend this build has, and sits between rules and llm"
  (check-equal? CLASSIFY-BACKENDS '("rules" "embed" "llm")
                "rules first (free and certain), llm last (the expensive one)")
  ;; …but NOT in the chain a caller gets by not asking: an embedding needs an
  ;; endpoint the ordinary instance has not configured, so defaulting to it would
  ;; make every existing call on every existing instance try to embed.
  (check-equal? CLASSIFY-BACKENDS-DEFAULT '("rules" "llm")
                "naming it is how you ask for it")
  (check-false (backends-problem '("embed")))
  (check-false (backends-problem '("rules" "embed" "llm")))
  (check-true (string? (backends-problem '("vectors")))))

(test-case "an embedding is refused by name rather than misrouted"
  ;; EMB-4: an executor declares ONE endpoint and it is its chat endpoint, so
  ;; serving this from the instance's embedding endpoint while the caller
  ;; believes it went to the executor is the misroute-that-lies.
  (check-exn #rx"cannot be routed to the named executor"
             (lambda () (embed-exchange '("x") #:executor "gpu-1")))
  ;; EMB-3: configuration IS the capability, so an unset endpoint is a named
  ;; refusal before anything leaves
  (when (not (embed-configured?))
    (check-exn #rx"TMACH_EMBED_URL" (lambda () (embed-exchange '("x"))))))

(test-case "the request log can say WHICH operation, and the vocabulary is closed"
  (check-equal? REQUEST-OPERATIONS '("chat" "embed"))
  (check-true (> EMBED-MARGIN-SCALE 1.0) "the margin is scaled, or every answer is near zero"))

;; ---- the logger box is a CONTRACT, and breaking it is SILENT ----------------
;; Adding `#:operation` to `log-model-request!` broke every installed logger at
;; once — three test suites and the server's own — and not one of them raised,
;; because RED-17 has the wrapper swallow any failure so that an unwritable log
;; can never cost somebody their answer. What that produces is the log simply
;; not being written, which `dump-leak-tests.rkt` found as "the request really
;; was logged: expected 1, actual 0" — a sentence that points at the logging and
;; says nothing about the keyword.
;;
;; So the swallow that protects the model call also hides a contract change, and
;; the only thing that can catch it is a check that the DEFAULT implementation
;; accepts exactly what the wrapper sends. This is that check.
(require (only-in "../domain/ai/executor.rkt" model-request-logger)
         racket/function)

(test-case "the no-op logger accepts every keyword the wrapper passes"
  (define sent (box #f))
  (define saved (unbox model-request-logger))
  (dynamic-wind
    void
    (lambda ()
      ;; what `log-model-request!` really sends, keyword for keyword
      (check-not-exn
       (lambda ()
         ((unbox model-request-logger)
          #:executor #f #:transport "push" #:model "m" #:endpoint "http://x/"
          #:messages '() #:tokens 1 #:status "ok" #:error-kind #f
          #:http-status 200 #:operation "embed" #:ms 1))
       "the shipped no-op must take what the wrapper gives it")
      ;; …and a logger that does NOT take it fails invisibly, which is the whole
      ;; point: the wrapper swallows it, so nothing but this kind of check sees it
      (set-box! model-request-logger
                (lambda (#:executor e #:transport t #:model m #:endpoint u #:messages msgs
                         #:tokens tok #:status st #:error-kind ek #:http-status hs #:ms ms)
                  (set-box! sent #t)))
      (check-not-exn
       (lambda () (log-model-request! #:executor #f #:transport "push" #:status "ok"
                                      #:operation "embed"))
       "a broken logger never fails the model call (RED-17)")
      (check-false (unbox sent)
                   "…and it also never ran, which is exactly why this case exists"))
    (lambda () (set-box! model-request-logger saved))))
