#lang racket/base

;; domain/help/answer.rkt — the question, the passages, and an answer that cites
;; or refuses (#183 slice 2, decisions HELP‑15…21).
;;
;; Slice 1 built the corpus and the nearest-passage read. This is the half #183
;; is actually asking for: "it must cite, and it must be able to say 'I don't
;; know'. An answer invented about an operator's own platform is worse than
;; silence."
;;
;; TWO LAYERS DO THAT WORK, and neither is sufficient alone (HELP‑15/‑16):
;;
;;   1. A SCORE FLOOR, before any model is called. If nothing in the
;;      documentation is close to the question, there is nothing to answer from
;;      and the honest reply costs no tokens.
;;   2. EVERY CITATION IS RESOLVED AGAINST WHAT WAS RETRIEVED. The model is
;;      asked to cite by path; a path it names that was not among the passages
;;      is DROPPED, and an answer that cites nothing at all is reported as
;;      uncited. That is as far as verification can honestly go — the KG
;;      extractor can demand a verbatim substring because it extracts spans,
;;      and a prose answer has no such invariant.
;;
;; The model seam is a parameter, as every model-backed path here has one, so a
;; test needs no model and the suite needs no endpoint.

(require racket/list racket/string
         (only-in "../authz/authz.rkt" principal-team-id)
         (only-in "../ai/executor.rkt" run-chat model-configured? embed-exchange embed-model
                  embed-configured?)
         (only-in "../ai/roles.rkt" model-role-executor)
         (only-in "../orgs/orgs.rkt" tenant-quota-record!)
         (only-in "helpsearch.rkt" help-passages help-available? HELP-K HELP-MAX))

(provide help-answer current-help-chat current-help-embed-one
         HELP-SCORE-FLOOR HELP-ANSWER-REASONS HELP-SYSTEM
         help-cited-paths)

;; ---- the two seams -----------------------------------------------------------

(define (default-chat prompt #:system [sys #f] #:executor [ex #f])
  (unless (or ex (model-configured?))
    (error 'help-answer
           (string-append "no model configured — set TMACH_MODEL_URL, or a utility executor in "
                          "Model roles. Retrieval alone can find the passages but cannot answer "
                          "from them.")))
  (run-chat prompt #:system sys #:temperature 0 #:executor ex))

(define current-help-chat (make-parameter default-chat))

;; One string in, one vector out. Its own parameter beside the chat seam for the
;; reason `embed-exchange` is its own function: an embedding model is a different
;; model on a different endpoint, so scripting one says nothing about the other.
(define (default-embed-one text)
  (define-values (vs toks _u _m) (embed-exchange (list text) #:who 'help-answer))
  (values (car vs) toks))

(define current-help-embed-one (make-parameter default-embed-one))

;; ---- the floor ---------------------------------------------------------------
;;
;; HELP‑15 — PROVISIONAL, AND THE WORD IS LOAD-BEARING, exactly as it is on
;; `CHUNK-SIZE-DEFAULT`. What it is set from is slice 1's first real probe
;; against `nomic-embed-text` over the real corpus, recorded in
;; `docs/design/in-product-help.md`:
;;
;;   * a prose question answered out of the right runbook scored **0.66–0.73**
;;   * a question naming a SYMPTOM found the right file and the wrong section at
;;     **0.576**
;;   * a Japanese question answered out of the Japanese chapter scored **0.805**
;;   * a Japanese question that MISSED its chapter entirely still had a top hit
;;     at **0.651** — which is the measurement that stops this floor being set
;;     anywhere near where it would be useful as a relevance test
;;
;; So the floor is deliberately LOW. It is not "is this passage a good answer" —
;; nothing here can decide that, and the 0.651 miss proves a threshold cannot.
;; It is "is there anything in this documentation at all near this question",
;; which is what makes the difference between a refusal that costs nothing and a
;; model call that invents. The second layer — the prompt, and the citation
;; resolution — is what catches close-but-wrong. What would move this number is a
;; recall measurement over a question set with known answers, in both languages,
;; which is #189 step 3's calibration and the same sitting.
(define HELP-SCORE-FLOOR 0.35)

;; HELP‑19 — A CLOSED VOCABULARY, never an exception message (#123's line, and
;; VEC‑39's). `unconfigured`/`empty`/`locale-empty` come from `help-available?`;
;; `no-model` is the chat half of the same question; `nothing-relevant` is the
;; floor; `uncited` is an answer the model gave that named no passage.
(define HELP-ANSWER-REASONS '("unconfigured" "empty" "locale-empty" "no-model"
                              "nothing-relevant" "uncited"))

;; ---- the prompt --------------------------------------------------------------
;;
;; HELP‑16 — THE INSTRUCTION TO REFUSE IS IN THE PROMPT AND IS NOT TRUSTED. A
;; model told to say "I don't know" sometimes does; what makes the refusal real
;; is that the answer's citations are resolved against the retrieved set
;; afterwards, so an answer about a file the retrieval never offered cannot carry
;; a citation to it. The prompt is in English whatever the asker's language,
;; because it is an instruction to the model rather than copy anybody reads — the
;; ANSWER's language is named in it.
(define HELP-SYSTEM
  (string-join
   (list
    "You answer questions about the TMach platform using ONLY the numbered passages given to you."
    "Each passage carries the path of the file it came from."
    ""
    "Rules:"
    "- Answer from the passages. Do not use anything you know from elsewhere."
    "- Cite every claim by putting the file's path in square brackets, like [docs/ops/container.md]."
    "- If the passages do not answer the question, say so plainly and cite nothing."
    "  Do not guess, and do not describe what the passages are about instead."
    "- Be brief: a few sentences, or a short list."
    "- Answer in the language named below.")
   "\n"))

(define (compose-prompt question passages locale)
  (string-join
   (append
    (list (format "Answer in: ~a" locale)
          ""
          (format "Question: ~a" question)
          ""
          "Passages:")
    (for/list ([p (in-list passages)] [i (in-naturals 1)])
      (format "~a. [~a]~a\n~a"
              i (hash-ref p 'path)
              (let ([h (hash-ref p 'heading "")])
                (if (string=? h "") "" (format " — ~a" h)))
              (hash-ref p 'text))))
   "\n"))

;; Every `[…]` the answer carries, in the order it carries them, de-duplicated.
;; Exported FOR the test: this is the half of HELP‑16 that has to be exercised
;; against strings a model really produces (a trailing full stop inside the
;; bracket, a path with no `docs/` prefix, the same path twice).
(define (help-cited-paths text)
  (remove-duplicates
   (for/list ([m (in-list (regexp-match* #px"\\[([^\\]\\[]+)\\]" text #:match-select cadr))])
     (string-trim m))))

;; ---- the answer --------------------------------------------------------------
;;
;; Answers ONE hash: 'answer 'citations 'passages 'locale 'reason 'model 'scanned
;; 'score 'tokens. `reason` is #f when the question was answered.
;;
;; HELP‑21 — WHAT IT CHARGES, AND WHAT IT DELIBERATELY DOES NOT. `ai.help.total`
;; is its own dimension with no default limit (EMB‑6's and JUDGE‑10's shape: a
;; cost with no sensible home gets a dimension rather than being folded into
;; somebody else's budget), and `ai.requests` is charged because the dimension
;; counts calls to a model and this is two of them — its 200/day default is a
;; real bound and is not the one that would hurt. **`ai.tokens.total` is NOT
;; charged**, and that is the whole point of the dimension: at its shipped
;; 2,000/day default a question or three would exhaust it, and #183's own words
;; are that "help that stops working at lunchtime is worse than no help". What
;; that does not bound is stated rather than left implicit: a team with no
;; `ai.help.total` limit can spend provider tokens on help without it appearing
;; in the completion budget an operator reads as spend, and the remedy is to set
;; the limit the dimension exists for.
;; `#:floor` is an argument rather than a constant read at the call because the
;; number is PROVISIONAL and is the subject of a measurement (see
;; `HELP-SCORE-FLOOR`): a calibration run has to sweep it, and a test of anything
;; else must not depend on today's value. The ROUTE does not expose it — a
;; caller choosing their own relevance threshold is choosing how much invention
;; to allow.
(define (help-answer conn p question
                     #:locale [locale "en"]
                     #:fallback-locale [fallback "en"]
                     #:k [k HELP-K]
                     #:floor [floor HELP-SCORE-FLOOR])
  (define q (and (string? question) (string-trim question)))
  (when (or (not q) (string=? q ""))
    (raise-user-error 'help-answer "a question is required"))
  (define unavailable (help-available? conn (embed-configured?) locale))
  (cond
    [unavailable (refusal unavailable locale)]
    [else
     (define-values (qv qtokens) ((current-help-embed-one) q))
     (define rep (help-passages conn qv (embed-model)
                                #:k (min (max 1 k) HELP-MAX)
                                #:locale locale #:fallback-locale fallback))
     (define ps (hash-ref rep 'passages))
     (define top (if (null? ps) 0.0 (hash-ref (car ps) 'score)))
     ;; The embedding was spent whether or not the floor admits, so it is metered
     ;; before the branch — FEED‑9's rule, that metering only successes makes a
     ;; failing path free.
     (meter! conn p qtokens)
     (cond
       [(or (null? ps) (< top floor))
        (hash-set* (refusal "nothing-relevant" (hash-ref rep 'locale))
                   'scanned (hash-ref rep 'scanned)
                   'score top)]
       [(not (or (utility-of conn p) (model-configured?)))
        ;; The passages ARE the answer this instance can give, so they come back
        ;; with the refusal rather than being thrown away: a reader handed three
        ;; cited passages is better off than one handed an error, and it is the
        ;; `content_search: false` posture — report what did not run, keep what
        ;; did.
        (hash-set* (refusal "no-model" (hash-ref rep 'locale))
                   'passages ps 'scanned (hash-ref rep 'scanned) 'score top)]
       [else
        (define-values (reply tokens) ((current-help-chat)
                                       (compose-prompt q ps (hash-ref rep 'locale))
                                       #:system HELP-SYSTEM
                                       #:executor (utility-of conn p)))
        (meter! conn p tokens)
        ;; HELP‑16's second layer: a cited path is kept only if the retrieval
        ;; offered it. A model that names a plausible file it was never shown is
        ;; the failure this feature cannot be allowed to have.
        (define offered (for/list ([x (in-list ps)]) (hash-ref x 'path)))
        (define named (help-cited-paths reply))
        (define kept (filter (lambda (c) (and (member c offered) #t)) named))
        (define invented (filter (lambda (c) (not (member c offered))) named))
        (hasheq 'answer reply
                'citations (for/list ([c (in-list kept)])
                             (define hit (for/first ([x (in-list ps)]
                                                     #:when (equal? (hash-ref x 'path) c)) x))
                             (hasheq 'path c
                                     'title (hash-ref hit 'title)
                                     'heading (hash-ref hit 'heading)
                                     'start (hash-ref hit 'start)
                                     'end (hash-ref hit 'end)
                                     'score (hash-ref hit 'score)))
                'invented_citations invented
                'passages ps
                'locale (hash-ref rep 'locale)
                'model (embed-model)
                'scanned (hash-ref rep 'scanned)
                'score top
                'tokens (+ (or qtokens 0) (or tokens 0))
                ;; An answer that cites nothing is REPORTED and still returned:
                ;; it is usually the model refusing, which is what it was asked
                ;; to do, and a caller that wants to render it differently needs
                ;; to be able to tell. QUOTA‑3's rule — the key is absent when
                ;; there is nothing to say.
                'reason (if (null? kept) "uncited" #f))])]))

;; KG‑7/LOC‑5: bulk work goes to the team's `utility` executor when one is set,
;; which is how a GPU box takes the answering without this module knowing it
;; exists. Resolved from the ASKER's team rather than read out of
;; `current-utility-executor` — that parameter is the document tools' binder, and
;; requiring it here would pull the repository, the classifier and the
;; sensitivity policy into a module that needs none of them.
(define (utility-of conn p)
  (model-role-executor conn (principal-team-id p) "utility"))

(define (refusal reason locale)
  (hasheq 'answer 'null 'citations '() 'passages '() 'locale locale
          'reason reason 'model (embed-model) 'scanned 0 'score 0.0 'tokens 0))

(define (meter! conn p tokens)
  (tenant-quota-record! conn p "ai.requests" 1)
  (when (and (number? tokens) (> tokens 0))
    (tenant-quota-record! conn p "ai.help.total" tokens)))
