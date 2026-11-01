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
                  model-context max-input-chars prompt-truncated? truncation-message)
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
      ;; The message names the numbers and both remedies, and never the text.
      (define m (truncation-message 'translate 4095))
      (check-true (regexp-match? #rx"4095" m))
      (check-true (regexp-match? #rx"4096" m))
      (check-true (regexp-match? #rx"OLLAMA_CONTEXT_LENGTH" m))
      (check-true (regexp-match? #rx"TMACH_MODEL_CONTEXT" m)))))

(test-case "#231: translate! refuses an over-long text BEFORE it spends anything"
  (with-env "TMACH_MODEL_CONTEXT" "4096"
    (lambda ()
      (define conn (fresh))
      (define-values (uid tid) (bootstrap! conn #:username "alice"))
      (define alice (user-principal conn uid tid))
      (define called (box 0))
      (define (counting-chat text sys) (set-box! called (add1 (unbox called))) (values text 7))
      (define long (make-string (+ 1 (max-input-chars)) #\x))
      ;; A 400 the caller sees, not a 500 (#123).
      (check-exn exn:fail:user?
                 (lambda () (translate! conn alice #:text long #:target-lang "ja" #:chat counting-chat)))
      ;; THE MODEL WAS NEVER CALLED, which is the point of doing it pre-flight:
      ;; a refusal after the wait has already spent the budget and the minute.
      (check-equal? (unbox called) 0 "the model must not be called for a text that cannot fit")
      ;; …and nothing was stored. The live row this was reported from is 39,462
      ;; characters in and 1,187 out, kept as though it were the translation.
      (check-equal? (length (translate-list conn alice)) 0)
      ;; One character under the limit still goes through.
      (define-values (job _t)
        (translate! conn alice #:text (make-string (max-input-chars) #\x)
                    #:target-lang "ja" #:chat counting-chat))
      (check-equal? (unbox called) 1)
      (check-equal? (length (translate-list conn alice)) 1)
      ;; The refusal says the length, the limit and why longer comes back wrong.
      (define m (with-handlers ([exn:fail:user? exn-message])
                  (translate! conn alice #:text long #:target-lang "ja" #:chat counting-chat)))
      (check-true (regexp-match? #rx"7680" m) m)
      (check-true (regexp-match? #rx"7681" m) m))))
