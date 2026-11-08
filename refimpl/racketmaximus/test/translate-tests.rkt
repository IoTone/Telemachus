#lang racket/base

;; test/translate-tests.rkt — the Translation app: jobs, glossary (managed +
;; used in the prompt), RBAC, and catalog translation. The model call is injected
;; so these are deterministic and need no live model.  raco test test/translate-tests.rkt

(require rackunit db-kit/portable
         db-kit/migrate
         "../domain/apps/translate.rkt"
         ;; #231: the context budget and the truncation detector live at the
         ;; model seam, because the backstop belongs where the response is.
         (only-in "../domain/ai/executor.rkt"
                  model-context max-input-chars prompt-chars prompt-truncated?
                  truncation-message)
         ;; #232: the chunk budget and the plan, exported so a test need not
         ;; depend on today's window
         (only-in "../domain/apps/translate.rkt"
                  translate-chunk-chars translate-plan TRANSLATE-MAX-CHUNKS system-prompt)
         ;; #233: the metering pair, and the ledger it writes to
         (only-in "../domain/apps/translate.rkt" translate-metering)
         (only-in "../domain/quota/quota.rkt" set-limit! quota-used)
         racket/list
         "../domain/db/migrations.rkt"
         "db-fixture.rkt"
         "../domain/authz/authz.rkt")

(define (fresh) (define c (fresh-db #:migrate? #f)) (migrate! c all-migrations) c)
(define (upcase-chat text sys) (values (string-upcase text) 7))

(test-case "translate!: returns result + tokens and records team history"
  (define conn (fresh))
  (define-values (uid tid) (bootstrap! conn #:username "alice"))
  (define alice (user-principal conn uid tid))
  (define-values (job tokens) (translate! conn alice #:text "hello world" #:target-lang "ja" #:chat upcase-chat))
  (check-equal? (hash-ref job 'result) "HELLO WORLD")
  (check-equal? (hash-ref job 'target_lang) "ja")
  (check-equal? tokens 7)
  (define hist (translate-list conn alice))
  (check-equal? (length hist) 1)
  (check-equal? (hash-ref (car hist) 'source_text) "hello world"))

(test-case "glossary: add (managed), upsert, and injected into the model prompt"
  (define conn (fresh))
  (define-values (uid tid) (bootstrap! conn #:username "alice"))
  (define alice (user-principal conn uid tid))
  (glossary-add! conn alice #:term "note" #:translation "メモ" #:target-lang "ja")
  (check-equal? (length (glossary-list conn alice #:target-lang "ja")) 1)
  (define seen (box ""))
  (translate! conn alice #:text "x" #:target-lang "ja"
              #:chat (lambda (text sys) (set-box! seen sys) (values text 3)))
  (check-true (regexp-match? #rx"メモ" (unbox seen)))            ; term reached the prompt
  (glossary-add! conn alice #:term "note" #:translation "覚書" #:target-lang "ja")  ; upsert
  (check-equal? (length (glossary-list conn alice #:target-lang "ja")) 1))

(test-case "glossary-add! requires settings:manage — a viewer is denied"
  (define conn (fresh))
  (define-values (uid tid) (bootstrap! conn #:username "alice"))
  (define dave (create-user! conn #:username "dave"))
  (add-member! conn #:user dave #:team tid #:role "viewer")
  (define pdave (user-principal conn dave tid))
  (check-exn exn:fail:forbidden?
             (lambda () (glossary-add! conn pdave #:term "a" #:translation "b" #:target-lang "ja"))))

(test-case "translate-catalog!: keys preserved, values translated"
  (define conn (fresh))
  (define-values (uid tid) (bootstrap! conn #:username "alice"))
  (define alice (user-principal conn uid tid))
  (define (json-chat text sys) (values "here you go: {\"greeting\":\"こんにちは\",\"bye\":\"さようなら\"}" 12))
  (define-values (out tokens)
    (translate-catalog! conn alice #:catalog (hasheq 'greeting "hello" 'bye "bye") #:target-lang "ja" #:chat json-chat))
  (check-equal? (hash-ref out 'greeting) "こんにちは")
  (check-equal? (hash-ref out 'bye) "さようなら"))

;; ---- #231: too long to translate is a REFUSAL, not a summary ----------------
;;
;; The report, twice, with the input attached: a Wikipedia article pasted into
;; the Translate tab came back as a short English summary and the platform stored
;; that as the Japanese translation. The measurement behind these numbers is in
;; `domain/ai/executor.rkt`; what is pinned here is that the platform refuses
;; rather than returning it, and that the refusal arrives BEFORE anything is
;; spent.

(define (with-env name value thunk)
  (define saved (getenv name))
  (dynamic-wind (lambda () (putenv name value))
                thunk
                (lambda () (putenv name (or saved "")))))

(test-case "#231: the budget is derived from the declared window, and 0 is never honoured"
  ;; THE DEFAULT IS OLLAMA'S OWN DEFAULT, which is what makes it right for the
  ;; ordinary deployment with nothing set — the demo box this was reported from
  ;; serves exactly 4,096 while the model itself supports 32,768.
  (with-env "TMACH_MODEL_CONTEXT" ""
    (lambda ()
      (check-equal? (model-context) 4096)
      ;; 4 * (4096 - 256) / 2 = 7680 — and the measurement either side of it is
      ;; what says it is in the right place: 8,000 characters came back wrong,
      ;; 2,000 and 8,000... (8,000 was the last correct one, 24,000 was not).
      (check-equal? (max-input-chars) 7680)))
  (with-env "TMACH_MODEL_CONTEXT" "32768"
    (lambda () (check-equal? (max-input-chars) (quotient (* 4 (- 32768 256)) 2))))
  ;; An unparseable or non-positive value falls back to the DEFAULT, never to 0 —
  ;; a 0 window would refuse every prompt ever sent.
  (for ([bad (in-list '("nonsense" "0" "-5" "4096.5"))])
    (with-env "TMACH_MODEL_CONTEXT" bad
      (lambda () (check-equal? (model-context) 4096 (format "~a must fall back" bad))))))

(test-case "#231: the detector is the PIN, and it does not fire on a healthy call"
  (with-env "TMACH_MODEL_CONTEXT" "4096"
    (lambda ()
      (define (msgs chars) (list (hasheq 'role "user" 'content (make-string chars #\x))))
      ;; The four rows measured against the live model. A ratio against our own
      ;; estimate CANNOT separate these — the healthy 8,000 call reports 73% of
      ;; its chars/4 estimate and the truncated 24,000 one reports 68% — which is
      ;; the whole reason the test is "it read a windowful and we sent more".
      (check-false (prompt-truncated? 390  (msgs 2000))  "2,000 chars / 390 tokens is healthy")
      (check-false (prompt-truncated? 1470 (msgs 8000))  "8,000 chars / 1,470 tokens is healthy")
      (check-true  (prompt-truncated? 4095 (msgs 24000)) "24,000 chars pinned at the window")
      (check-true  (prompt-truncated? 4095 (msgs 45000)) "45,000 chars pinned at the window")
      ;; ABOVE the band is a window declared too small, not a truncation: a
      ;; server really serving 32,768 reports 5,000 tokens for a complete
      ;; prompt, and a bare `>=` would refuse it.
      (check-false (prompt-truncated? 5000 (msgs 45000))
                   "a report above the declared window means the declaration is wrong")
      ;; A provider that reports nothing cannot be judged, and must not be.
      (check-false (prompt-truncated? #f (msgs 45000)))
      ;; Pinned at the window with a SHORT prompt is not truncation — it is a
      ;; declared window far below the real one, where every prompt would look
      ;; pinned. A token covers at least one character, so the character count
      ;; is the sound bound that rules it out.
      (check-false (prompt-truncated? 4095 (msgs 100)))
      ;; THE CASE A RATIO CANNOT SEE, and it is the one CHUNK-2 predicted. A
      ;; control that swapped the pin for `prompt_tokens < 0.70 * estimate`
      ;; passed every English row above, because the measured ratios (73.5%
      ;; healthy, 68% truncated) straddle 0.70 — so the comment claiming a ratio
      ;; cannot separate them was WRONG about English and is right here instead.
      ;; Japanese runs near ONE token per character where `estimate-tokens`
      ;; assumes four, so 8,000 characters of Japanese is ~8,000 real tokens, the
      ;; estimate says 2,000, and the reported 4,095 is ABOVE the estimate: every
      ;; ratio test reads a truncated call as comfortably healthy. The pin does
      ;; not estimate, so it fires.
      (define ja (list (hasheq 'role "user" 'content (make-string 8000 #\u3042))))
      (check-true (prompt-truncated? 4095 ja)
                  "a truncated Japanese prompt: the pin must fire where a ratio cannot")
      ;; THE GAP, PINNED RATHER THAN IMPLIED. An operator who declares a window
      ;; LARGER than the server really serves is protected by neither layer: the
      ;; cap grows to fit the declaration and the detector looks for a pin at
      ;; the declared number, so a prompt truncated at the real 4,096 reports
      ;; 4,095 and sails under a band centred on 16,384. Verified on the live
      ;; box — 32,256 characters came back in English with CJK 0.0 and nothing
      ;; fired. There is no sound test that separates it from a complete prompt
      ;; on a window bigger than we were told, so the contract is that the
      ;; declaration is truthful, and this case exists so that nobody reads the
      ;; detector as covering more than it does.
      (check-false (parameterize () (with-env "TMACH_MODEL_CONTEXT" "16384"
                                      (lambda () (prompt-truncated? 4095 (msgs 32256)))))
                   "an OVER-declared window is caught by neither layer — by contract")
      ;; THE EXTRAS ARE PART OF THE PROMPT, AND THEY WERE NOT COUNTED. This is
      ;; the regression for the agent's six empty notes: the tool schemas ride in
      ;; `#:extras`, not in `messages`, so on that path the detector was blind
      ;; to 22,599 characters of what it was judging and the live rows — six
      ;; rounds, `prompt_tokens: 4095` against 356 characters of messages — went
      ;; through as `ok`. The character bound is sound only if it counts
      ;; everything that is sent.
      (define tools (hasheq 'tools (for/list ([i 24])
                                     (hasheq 'name (format "t~a" i)
                                             'description (make-string 900 #\y)))))
      (check-true (> (prompt-chars (msgs 356) tools) 20000)
                  "the extras are counted as the JSON they are serialized into")
      (check-false (prompt-truncated? 4095 (msgs 356))
                   "messages alone cannot explain a windowful — this is the OLD blindness")
      (check-true (prompt-truncated? 4095 (msgs 356) tools)
                  "…and with the tool list counted, the agent's own case fires")
      ;; The message names the numbers and both remedies, and never the text.
      (define m (truncation-message 'translate 4095))
      (check-true (regexp-match? #rx"4095" m))
      (check-true (regexp-match? #rx"4096" m))
      (check-true (regexp-match? #rx"OLLAMA_CONTEXT_LENGTH" m))
      (check-true (regexp-match? #rx"TMACH_MODEL_CONTEXT" m)))))

(test-case "#232: a long text is TRANSLATED IN SECTIONS, not refused"
  ;; THE CONTRACT #231 ESTABLISHED IS DELIBERATELY CHANGED HERE, and the old
  ;; case is what caught it: #231 made the failure loud and said in as many words
  ;; that it did not make it work. A text past one window's worth is now chunked.
  (with-env "TMACH_MODEL_CONTEXT" "4096"
    (lambda ()
      (define conn (fresh))
      (define-values (uid tid) (bootstrap! conn #:username "alice"))
      (define alice (user-principal conn uid tid))
      (define calls (box '()))
      (define (counting-chat text sys)
        (set-box! calls (cons (cons (string-length text) sys) (unbox calls)))
        (values (string-append "[" text "]") 7))
      ;; one window's worth for a LATIN target reproduces #231's measured number
      (define size (translate-chunk-chars #:target "fr"
                                          #:system (system-prompt "fr" "auto" '())))
      ;; sentences, so the boundary search has something to find — a single
      ;; 40,000-character run of `x` has no boundary at all, which is CHUNK-3's
      ;; own fixture and a different test
      (define sentence "The quick brown fox jumps over the lazy dog. ")
      (define long (apply string-append (for/list ([_ (in-range 900)]) sentence)))
      (check-true (> (string-length long) (* 3 size)) "the fixture really is several windowfuls")
      (define-values (job tokens)
        (translate! conn alice #:text long #:target-lang "fr" #:chat counting-chat))
      (define n (length (unbox calls)))
      (check-true (> n 3) (format "several model calls, got ~a" n))
      (check-equal? (hash-ref job 'chunks) n "the job reports how many it cost")
      (check-equal? tokens (* 7 n) "tokens are the SUM across the sections")
      ;; NO SECTION OVERRUNS THE BUDGET — the whole point
      (for ([c (in-list (unbox calls))])
        (check-true (<= (car c) size) (format "a section of ~a exceeds the ~a budget" (car c) size)))
      ;; …and the whole document came back: the sections TILE (overlap 0), so
      ;; joining them reconstructs the source with nothing dropped and nothing
      ;; rendered twice
      (define result (hash-ref job 'result))
      (check-equal? (string-length (regexp-replace* #rx"[][]" result ""))
                    (string-length long)
                    "every character of the source is accounted for exactly once")
      (check-equal? (length (translate-list conn alice)) 1 "ONE stored translation, not one per section"))))

(test-case "#232: the glossary and the instructions go to EVERY section"
  ;; An agreed term applied to the first part of a document and not the rest is
  ;; worse than no glossary at all, because nobody reading the output can tell
  ;; which half to trust.
  (with-env "TMACH_MODEL_CONTEXT" "4096"
    (lambda ()
      (define conn (fresh))
      (define-values (uid tid) (bootstrap! conn #:username "alice"))
      (define alice (user-principal conn uid tid))
      (glossary-add! conn alice #:term "fox" #:translation "renard" #:target-lang "fr")
      (define systems (box '()))
      (define (spy text sys) (set-box! systems (cons sys (unbox systems))) (values text 1))
      (define sentence "The quick brown fox jumps over the lazy dog. ")
      (define long (apply string-append (for/list ([_ (in-range 900)]) sentence)))
      (translate! conn alice #:text long #:target-lang "fr" #:chat spy)
      (check-true (> (length (unbox systems)) 3))
      (for ([sys (in-list (unbox systems))])
        (check-true (regexp-match? #rx"renard" sys) "the glossary reached this section")
        (check-true (regexp-match? #rx"professional translator" sys) "…and so did the instructions")))))

(test-case "#232: a SHORT translation is still exactly one model call"
  (with-env "TMACH_MODEL_CONTEXT" "4096"
    (lambda ()
      (define conn (fresh))
      (define-values (uid tid) (bootstrap! conn #:username "alice"))
      (define alice (user-principal conn uid tid))
      (define calls (box 0))
      (define (counting-chat text sys) (set-box! calls (add1 (unbox calls))) (values (string-upcase text) 7))
      (define-values (job tokens)
        (translate! conn alice #:text "hello world" #:target-lang "ja" #:chat counting-chat))
      (check-equal? (unbox calls) 1)
      (check-equal? (hash-ref job 'chunks) 1)
      (check-equal? (hash-ref job 'result) "HELLO WORLD" "…and the text is untouched by the chunker"))))

(test-case "#232: a CJK target gets SMALLER sections — CHUNK-2's trap, priced in"
  ;; THE ONE THING A SIZE DERIVED FROM THE INPUT ALONE CANNOT SEE. English runs
  ;; near four characters to the token and Japanese near one, so an English chunk
  ;; sized against the window has its JAPANESE reply truncated — by the model,
  ;; silently, which is a quietly worse translation and never an error.
  (with-env "TMACH_MODEL_CONTEXT" "4096"
    (lambda ()
      (define latin (translate-chunk-chars #:target "fr" #:system ""))
      (define cjk   (translate-chunk-chars #:target "ja" #:system ""))
      (check-true (< cjk latin) (format "ja ~a must be under fr ~a" cjk latin))
      ;; and the arithmetic reproduces #231's measured number for a Latin target,
      ;; so the existing behaviour is the model's own answer rather than a
      ;; constant sitting beside it: 8,000 characters translated correctly,
      ;; 24,000 did not
      (check-equal? latin 7680)
      (check-equal? cjk 3072))))

(test-case "#232: the SYSTEM PROMPT is charged against the window"
  ;; N sections is N copies of the prompt and the glossary, so the budget has to
  ;; be computed against the real composed prompt rather than against the text.
  (with-env "TMACH_MODEL_CONTEXT" "4096"
    (lambda ()
      (define bare (translate-chunk-chars #:target "fr" #:system ""))
      (define heavy (translate-chunk-chars #:target "fr" #:system (make-string 4000 #\x)))
      (check-true (< heavy bare) "a longer prompt leaves room for less text")
      ;; and a glossary that cannot fit at all is a NAMED refusal rather than a
      ;; thousand one-word requests
      (define-values (chunks problem)
        (translate-plan "hello" #:target "fr"
                        #:terms (for/list ([i (in-range 400)])
                                  (hasheq 'term (format "term~a" i) 'translation (make-string 40 #\y)))))
      (check-equal? chunks '())
      (check-true (and problem #t))
      (check-true (regexp-match? #rx"glossary" problem) problem))))

(test-case "#232: past the SECTION CAP it is still a refusal, and nothing is spent"
  ;; CHUNK-7's rule for this caller's reason: each section is a model request and
  ;; `ai.requests` defaults to 200/day, so an unbounded fan-out over a pasted
  ;; novel would spend a team's allowance on one document.
  (with-env "TMACH_MODEL_CONTEXT" "4096"
    (lambda ()
      (define conn (fresh))
      (define-values (uid tid) (bootstrap! conn #:username "alice"))
      (define alice (user-principal conn uid tid))
      (define called (box 0))
      (define (counting-chat text sys) (set-box! called (add1 (unbox called))) (values text 7))
      (define sentence "The quick brown fox jumps over the lazy dog. ")
      (define cap (* TRANSLATE-MAX-CHUNKS
                     (translate-chunk-chars #:target "fr" #:system (system-prompt "fr" "auto" '()))))
      (define toolong (apply string-append
                             (for/list ([_ (in-range (add1 (quotient cap (string-length sentence))))])
                               sentence)))
      (check-true (> (string-length toolong) cap))
      (check-exn exn:fail:user?
                 (lambda () (translate! conn alice #:text toolong #:target-lang "fr" #:chat counting-chat)))
      ;; THE MODEL WAS NEVER CALLED, which is the point of doing it pre-flight
      (check-equal? (unbox called) 0 "the model must not be called for a text that cannot fit")
      (check-equal? (length (translate-list conn alice)) 0 "…and nothing was stored")
      (define m (with-handlers ([exn:fail:user? exn-message])
                  (translate! conn alice #:text toolong #:target-lang "fr" #:chat counting-chat)))
      (check-true (regexp-match? #rx"sections" m) m)
      (check-true (regexp-match? (regexp (number->string TRANSLATE-MAX-CHUNKS)) m) m))))

(test-case "#232: a budget exhausted MID-document stops with a reason, not a partial result"
  (with-env "TMACH_MODEL_CONTEXT" "4096"
    (lambda ()
      (define conn (fresh))
      (define-values (uid tid) (bootstrap! conn #:username "alice"))
      (define alice (user-principal conn uid tid))
      (define calls (box 0))
      (define spent (box 0))
      (define (counting-chat text sys) (set-box! calls (add1 (unbox calls))) (values text 7))
      (define sentence "The quick brown fox jumps over the lazy dog. ")
      (define long (apply string-append (for/list ([_ (in-range 900)]) sentence)))
      ;; the endpoint's seam, scripted: the team runs out after two sections
      (define (admit i n) (and (> i 2) (format "section ~a of ~a: out of budget" i n)))
      (check-exn exn:fail:user?
                 (lambda () (translate! conn alice #:text long #:target-lang "fr"
                                        #:chat counting-chat #:admit admit
                                        #:record! (lambda (t) (set-box! spent (+ (unbox spent) t))))))
      (check-equal? (unbox calls) 2 "it stopped where it was refused")
      ;; NOTHING IS STORED — the acceptance criterion is "a named reason rather
      ;; than a partial result"
      (check-equal? (length (translate-list conn alice)) 0)
      ;; …but WHAT WAS SPENT WAS RECORDED (FEED-9): metering only successes makes
      ;; a run that stops halfway look free
      (check-equal? (unbox spent) 14))))

;; ---- #233: the progress seam, and the metering pair with two askers ---------

(test-case "#233: progress is reported 0-of-N BEFORE any model call, then per section"
  ;; WHY THE LEADING REPORT MATTERS: a 24-section document spends a minute in
  ;; `running`, and without it the unit count is unknown until the first section
  ;; lands — so the console could show nothing but a clock for exactly the wait
  ;; the field exists to explain.
  (with-env "TMACH_MODEL_CONTEXT" "4096"
    (lambda ()
      (define conn (fresh))
      (define-values (uid tid) (bootstrap! conn #:username "alice"))
      (define alice (user-principal conn uid tid))
      (define seen (box '()))
      (define calls (box 0))
      (define (counting-chat text sys) (set-box! calls (add1 (unbox calls))) (values text 7))
      (define sentence "The quick brown fox jumps over the lazy dog. ")
      (define long (apply string-append (for/list ([_ (in-range 900)]) sentence)))
      (define-values (_job _toks)
        (translate! conn alice #:text long #:target-lang "fr" #:chat counting-chat
                    #:progress! (lambda (d n)
                                  ;; the model-call count AT THE MOMENT each
                                  ;; report is made: this is what says the first
                                  ;; one precedes every call, which a report of
                                  ;; `done` alone cannot
                                  (set-box! seen (cons (list d n (unbox calls)) (unbox seen))))))
      (define reports (reverse (unbox seen)))
      (check-true (> (length reports) 2) "the fixture has to be more than one section")
      ;; the lead: 0 of N, with the model not yet called
      ;; N sections produce N+1 reports — the lead, then one each
      (define n (sub1 (length reports)))
      (check-equal? (car reports) (list 0 n 0) "0 of N, before any model call")
      ;; and then one per section, in order, each after its own call
      (for ([r (in-list (cdr reports))] [i (in-naturals 1)])
        (check-equal? r (list i n i)
                      (format "report ~a" i)))
      ;; THE TOTAL NEVER MOVES. A total that grew as the work went would make a
      ;; progress bar run backwards, and the plan is computed once.
      (check-equal? (length (remove-duplicates (map cadr reports))) 1))))

(test-case "#233: the default progress seam is a no-op — every existing caller unchanged"
  (define conn (fresh))
  (define-values (uid tid) (bootstrap! conn #:username "alice"))
  (define alice (user-principal conn uid tid))
  (define-values (job _t) (translate! conn alice #:text "hello" #:target-lang "ja" #:chat upcase-chat))
  (check-equal? (hash-ref job 'result) "HELLO"))

(test-case "#233: translate-metering admits, then refuses BY SECTION, and records both dimensions"
  ;; ONE RULE, TWO ASKERS (TR-10): `POST /api/translate` and the `translate` job
  ;; kind. The pair is built in the domain so the two cannot bill differently —
  ;; a team billed differently for the same work depending on which button they
  ;; pressed is the drift `executor-can-run?` was extracted to stop.
  (define conn (fresh))
  (define-values (uid tid) (bootstrap! conn #:username "alice"))
  (define alice (user-principal conn uid tid))
  (set-limit! conn "team" tid "ai.requests" 2)
  (define-values (admit record!) (translate-metering conn alice))
  (check-false (admit 1 5) "nothing spent yet, so the first section is admitted")
  (record! 7)
  (check-false (admit 2 5))
  (record! 7)
  ;; the ledger is at its limit now
  (define stop (admit 3 5))
  (check-true (string? stop) "an exhausted budget is a reason string, not an exception")
  (check-true (regexp-match? #rx"section 3 of 5" stop) stop)
  ;; the remedy is in the message, because "the budget is gone" is not something
  ;; a person can act on
  (check-true (regexp-match? #rx"raise the limit" stop) stop)
  (check-true (regexp-match? #rx"ai.requests" stop) stop)
  ;; BOTH dimensions, per section (FEED-9) — a run that stops at section 20 of 24
  ;; has paid for twenty, and metering tokens only at the end would make a
  ;; cancelled job free
  (check-equal? (quota-used conn "team" tid "ai.requests" "day") 2)
  (check-equal? (quota-used conn "team" tid "ai.tokens.total" "day") 14))
