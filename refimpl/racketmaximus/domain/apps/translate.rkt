#lang racket/base

;; domain/apps/translate.rkt — the Translation app (slice 17).
;;
;; A first user-facing "app" on the platform: translate text (or a whole locale
;; catalog) via the model, with a team GLOSSARY for consistent terminology and a
;; team-scoped history. Every op is authorized through the AuthzService and the
;; endpoints meter AI spend through the usual quotas. The model call is injected
;; (#:chat) so the app is testable without a live model; it defaults to run-chat.
;;
;; Dogfood: `translate-catalog!` translates a locale catalog (keys unchanged,
;; placeholders preserved) — the engine behind producing our ja/nl/es-419 files.

(require db-kit/portable
         racket/string
         json
         "../db/id.rkt"
         "../authz/authz.rkt"
         "../ai/executor.rkt"      ; run-chat, model-info, max-input-chars
         ;; #232: the chunker has been on disk since #189 step 3 and the
         ;; embedding path was its only caller
         (only-in "../ai/chunk.rkt" chunk-text)
         ;; issue #83 r1: these two columns hold derived document content whenever
         ;; the pipeline translates
         (only-in "../authz/sealed.rkt" define-sealed-column)
         ;; TR-10 (#233): the per-chunk metering pair has two askers now — the
         ;; synchronous endpoint and the `translate` job kind — so it is built
         ;; here rather than twice. No cycle: orgs.rkt requires only db, authz
         ;; and quota.
         (only-in "../orgs/orgs.rkt" tenant-quota-check tenant-quota-record!))

(define-sealed-column "translations.source_text" (seal-source unseal-source) (id))
(define-sealed-column "translations.result_text" (seal-result unseal-result) (id))

(provide translate! translate-list translate-catalog!
         glossary-add! glossary-list lang-label
         ;; #231: the endpoint reports it so the console can show the limit
         ;; beside the field, rather than a person discovering it by being
         ;; refused. ONE number, the server's.
         translate-max-chars
         ;; #232: exported FOR the endpoint, which has to admit N requests
         ;; before it starts, and for the tests, which must not depend on
         ;; today's window (`help-answer`'s `#:floor`, for its reason)
         translate-chunk-chars translate-plan TRANSLATE-MAX-CHUNKS
         ;; TR-10 (#233): the admit/record pair, built once for both callers
         translate-metering
         ;; the composed prompt the budget is CHARGED against. Exported for the
         ;; tests, which must charge the same thing the code does — a test that
         ;; re-derived it would agree with any change to it.
         system-prompt)

;; ---- language labels --------------------------------------------------------
(define lang-names
  (hash "en" "English" "ja" "Japanese" "nl" "Dutch" "es-419" "Latin American Spanish"
        "es" "Spanish" "fr" "French" "de" "German" "it" "Italian" "pt" "Portuguese"
        "zh" "Chinese" "ko" "Korean" "la" "Latin" "is" "Icelandic"))
(define (lang-label code) (hash-ref lang-names code code))

;; ---- glossary ---------------------------------------------------------------
(define (glossary-list conn p #:target-lang [tgt #f])
  (require-perm conn p "chat:use")
  (define rows
    (if tgt
        (query-rows conn "SELECT id,target_lang,term,translation FROM glossary WHERE team_id=? AND target_lang=? ORDER BY term"
                    (principal-team-id p) tgt)
        (query-rows conn "SELECT id,target_lang,term,translation FROM glossary WHERE team_id=? ORDER BY target_lang,term"
                    (principal-team-id p))))
  (for/list ([r (in-list rows)])
    (hasheq 'id (vector-ref r 0) 'target_lang (vector-ref r 1) 'term (vector-ref r 2) 'translation (vector-ref r 3))))

(define (glossary-add! conn p #:term term #:translation tr #:target-lang tgt)
  (require-perm conn p "settings:manage")             ; curating terminology is a managed action
  (define id (new-id))
  (query-exec conn
    (string-append "INSERT INTO glossary (id,team_id,target_lang,term,translation) VALUES (?,?,?,?,?) "
                   "ON CONFLICT(team_id,target_lang,term) DO UPDATE SET translation=excluded.translation")
    id (principal-team-id p) tgt term tr)
  (hasheq 'id id 'target_lang tgt 'term term 'translation tr))

;; ---- translation ------------------------------------------------------------
(define (system-prompt tgt src terms)
  (string-append
   "You are a professional translator. Translate the user's text into " (lang-label tgt)
   (if (and src (not (string=? src "auto"))) (string-append " from " (lang-label src)) "") ".\n"
   "Preserve meaning, tone, line breaks, and any placeholders such as {name} or ICU plural/select syntax EXACTLY.\n"
   "Output ONLY the translation — no preamble, no explanation, no surrounding quotes.\n"
   (if (null? terms) ""
       (string-append "Apply this glossary (term => required translation):\n"
                      (string-join (for/list ([t (in-list terms)])
                                     (string-append "- " (hash-ref t 'term) " => " (hash-ref t 'translation))) "\n")
                      "\n"))))

(define (default-chat text sys) (run-chat text #:system sys))

;; ---- #232: a long document is CHUNKED, and #231 is why it had to be ----------
;;
;; #231 made the failure LOUD and deliberately did not make it work: a
;; 39,462-character paste came back as a 1,187-character English summary and the
;; platform stored that as the Japanese translation, so until this slice the
;; answer was a named refusal. WHY it happens is in `executor.rkt` beside the
;; budget — the model server serves a 4,096-token window, the overflow is
;; discarded oldest first, and the oldest message is the system prompt that said
;; "translate".
;;
;; THE CHUNKER WAS ALREADY ON DISK. `domain/ai/chunk.rkt` has been there since
;; #189 step 3 with everything this needs: a boundary window that prefers
;; sentence ends (CJK enders included), a progress guarantee rather than a
;; coverage one (CHUNK-4), whitespace-only chunks never emitted (CHUNK-5), and a
;; count cap independent of `EXTRACT-CAP` (CHUNK-7). The embedding path was its
;; only caller.
;;
;; THREE THINGS A TRANSLATION NEEDS ON TOP OF IT, and each is a decision:
;;
;; 1. THE OVERLAP IS ZERO, where retrieval wants 15%. An overlap is what rescues
;;    recall when a chunk ends mid-clause; here you cannot emit the overlap twice
;;    — the reader would see the seam sentence rendered once in each direction.
;;    So the chunks TILE, and the boundary search is what has to carry the
;;    quality: `chunk-text` already walks back to a sentence end within a quarter
;;    of the size, which is the behaviour CHUNK-3 settled for a different reason.
;;
;; 2. THE SIZE IS DERIVED FROM THE WINDOW, NOT FROM A CONSTANT. CHUNK-10 measured
;;    384–2,048 characters for recall and found the parameter was not the lever;
;;    translation has a different constraint entirely, because the chunk AND its
;;    translation AND the system prompt with the glossary must all fit the context
;;    at once. So the budget is solved for rather than chosen.
;;
;; 3. AND IT IS NOT FOUR CHARACTERS PER TOKEN IN BOTH DIRECTIONS (CHUNK-2). This
;;    is the trap, and it is the one the retrieval work already paid for: English
;;    runs near four characters to the token and Japanese near ONE, so an
;;    English chunk sized against the window will have its JAPANESE reply
;;    truncated — by the model, silently, which is a quietly worse translation
;;    and never an error. The reserve is therefore computed against the TARGET.

;; Characters per token, by language. CHUNK-2's measurement: English ~4, Japanese
;; ~1. Korean is given 1.5 rather than 1.0 because Hangul syllables tokenize
;; somewhat better than CJK ideographs on the tokenizers in use here — that one is
;; an estimate and is marked as such; the two that matter are measured.
(define CHARS-PER-TOKEN (hash "ja" 1.0 "zh" 1.0 "ko" 1.5))
(define CHARS-PER-TOKEN-DEFAULT 4.0)
(define (chars-per-token code)
  (hash-ref CHARS-PER-TOKEN (if (string? code) code "") CHARS-PER-TOKEN-DEFAULT))

;; How long a translation is in CHARACTERS relative to its source. ONE
;; measurement: a book chapter is 3,342 characters in English and 2,079 in
;; Japanese (0.62). It is pinned at 1.0 — "the reply is no longer than the
;; source" — because that is CONSERVATIVE in the direction that matters: too
;; small a chunk costs an extra model call, too large a one loses the end of
;; somebody's translation to a truncation nothing reports.
(define REPLY-EXPANSION 1.0)

;; The window reserve `max-input-chars` already keeps for the exchange's own
;; overhead. Named here so the two cannot drift apart silently.
(define WINDOW-RESERVE 256)

;; A chunk this small is not a translation unit, it is a word. Reaching the floor
;; means the SYSTEM PROMPT does not fit — an operator with an enormous glossary —
;; and that is a named refusal rather than a thousand one-word requests.
(define MIN-CHUNK-CHARS 240)

;; CHUNK-7's rule, for this caller's reason: each chunk is a model request, and
;; `ai.requests` defaults to 200/day, so an unbounded fan-out over a pasted novel
;; would spend a team's allowance on one document. 24 chunks is ~180,000
;; characters of English at a 4,096-token window — about sixty pages.
(define TRANSLATE-MAX-CHUNKS 24)

;; -> how many characters of SOURCE fit in one request, given the composed system
;; prompt and the target language. Solves
;;
;;     chars/cpt(source) + chars*expansion/cpt(target) + prompt <= window - reserve
;;
;; for `chars`. On a Latin target with a small glossary this reproduces
;; `max-input-chars` (7,680 at a 4,096-token window), which is the number #231
;; measured either side of — 8,000 characters translated correctly, 24,000 did
;; not — so the existing behaviour is the arithmetic's own answer rather than a
;; constant sitting beside it.
(define (translate-chunk-chars #:target tgt #:source [src "auto"] #:system [sys ""])
  (define ctx (model-context))
  (define prompt-tokens (/ (string-length sys) CHARS-PER-TOKEN-DEFAULT))
  (define budget (- ctx WINDOW-RESERVE prompt-tokens))
  (define per-char (+ (/ 1.0 (chars-per-token (if (equal? src "auto") #f src)))
                      (/ REPLY-EXPANSION (chars-per-token tgt))))
  (define n (inexact->exact (floor (/ budget per-char))))
  (max 0 n))

;; What `translate!` is about to do, computed BEFORE anything is spent: the
;; chunks, and whether the text is longer than the cap allows. The endpoint asks
;; for it so it can admit N requests up front (FEED-9: meter per request, and
;; before the request).
;;
;; -> (values chunks problem-or-#f)
(define (translate-plan text #:target tgt #:source [src "auto"] #:terms [terms '()])
  (define sys (system-prompt tgt src terms))
  (define size (translate-chunk-chars #:target tgt #:source src #:system sys))
  (cond
    [(< size MIN-CHUNK-CHARS)
     (values '()
             (format (string-append
                      "the translation instructions and glossary alone need ~a of the model"
                      " server's ~a-token window, leaving room for ~a characters of text."
                      " Shorten the glossary for ~a, or raise the window on the model server"
                      " (for ollama, OLLAMA_CONTEXT_LENGTH) and set TMACH_MODEL_CONTEXT to match.")
                     (inexact->exact (round (/ (string-length sys) CHARS-PER-TOKEN-DEFAULT)))
                     (model-context) size (lang-label tgt)))]
    [else
     (define-values (chunks truncated?)
       (chunk-text text #:size size #:overlap 0 #:max-chunks TRANSLATE-MAX-CHUNKS))
     (cond
       [truncated?
        (values '()
                (format (string-append
                         "this text is ~a characters and the limit is ~a. It is translated in"
                         " sections of ~a characters and at most ~a sections per request, because"
                         " each section is a separate model call against the team's AI budget."
                         " Split it, or raise the window on the model server (for ollama,"
                         " OLLAMA_CONTEXT_LENGTH) and set TMACH_MODEL_CONTEXT to match.")
                        (string-length text) (* size TRANSLATE-MAX-CHUNKS)
                        size TRANSLATE-MAX-CHUNKS))]
       [else (values chunks #f)])]))

;; The number the console counts against (#231). It has no target language — the
;; Translate tab reports it before anybody has chosen one — so it is the WORST
;; case, a CJK target with no glossary. Conservative on purpose: being allowed
;; MORE than the counter showed is a pleasant surprise, being refused at a number
;; below the one on screen is the failure #231 was reported for. The server's
;; per-target budget is still the authority.
(define (translate-max-chars)
  (* TRANSLATE-MAX-CHUNKS
     (translate-chunk-chars #:target "ja" #:system (system-prompt "ja" "auto" '()))))

;; ---- the per-chunk metering pair (TR-10, #233) ------------------------------
;;
;; ONE RULE, TWO ASKERS: `POST /api/translate` and the `translate` job kind. Both
;; bill at the tool tier, so the pair is built here rather than written out twice
;; — the drift `executor-can-run?` was extracted to stop, in a place where a
;; divergence would be a team billed differently for the same work depending on
;; which button they pressed.
;;
;; `admit` answers a REASON STRING naming the section, because that is the half
;; a person can act on: "nothing was stored, raise the limit or wait" beats a
;; refusal that only says the budget is gone. `record!` charges BOTH dimensions
;; per section (FEED-9), so a run that stops at section 20 of 24 has paid for
;; twenty and a cancelled job is not free.
;;
;; It takes no HTTP: a refusal is a string, and rendering it as a 429 or as a job
;; error is each caller's own business.
(define (translate-metering conn p)
  (values
   (lambda (i n)
     (define rq (tenant-quota-check conn p "ai.requests" 1))
     (cond
       [(hash-ref rq 'allowed) #f]
       [else (format (string-append "section ~a of ~a could not be translated: the team's"
                                    " ai.requests budget is exhausted. Nothing was stored —"
                                    " raise the limit, or wait for the window to reset, and"
                                    " run it again.")
                     i n)]))
   (lambda (tokens)
     (tenant-quota-record! conn p "ai.requests" 1)
     (tenant-quota-record! conn p "ai.tokens.total" tokens))))

;; returns (values job-hash tokens-used)
;;
;; `#:admit` and `#:record!` are the per-chunk metering seams (#232). Each chunk
;; is a separate model request, so a long document is N requests against a
;; `ai.requests` default of 200/day and N lots of tokens — and FEED-9's rule is
;; to meter PER REQUEST and BEFORE the request, because metering only successes
;; makes a failing run free and metering at the end makes a run that stops
;; halfway look free.
;;
;; THE DEFAULTS ARE TODAY'S BEHAVIOUR EXACTLY — admit everything, record nothing,
;; report no progress — so every existing caller and every test is unchanged. The
;; CALLER fills them, and since #233 there are two: the synchronous endpoint and
;; the `translate` job kind. Both are at the TOOL tier, which is why
;; `translate-metering` below builds the pair once for both rather than letting
;; them drift (`executor-can-run?`'s lesson) — and why a translation run as a job
;; is metered IDENTICALLY to one run inside the request, section by section,
;; rather than as the single `ai.requests` the scheduler bills a job. A job that
;; meters itself says so in its result (`metered`) and the biller does not bill
;; it again; without that, cancelling at section 20 of 24 would cost the team
;; nothing at all, because the scheduler bills only a job that FINISHES.
;;
;; `#:progress!` is called with `(done total)` — once with 0 before any model
;; call, so the total is known from the first poll, and once after each section
;; lands. It is a seam for the same reason the other two are: `translate!` knows
;; the unit count and nothing about where a caller would record it.
;;
;; `#:admit` answers #f to admit, or a REASON STRING to stop. A refusal mid-way
;; raises and nothing is stored — the acceptance criterion is "a named reason
;; rather than a partial result" — but what was already spent has already been
;; recorded, which is the honest half of FEED-9.
(define (translate! conn p #:text text #:target-lang tgt
                    #:source-lang [src "auto"] #:use-glossary [gl? #t] #:chat [chat default-chat]
                    #:admit [admit (lambda (i n) #f)]
                    #:record! [record! (lambda (tokens) (void))]
                    #:progress! [progress! (lambda (done total) (void))])
  (require-perm conn p "chat:use")
  (define terms (if gl? (glossary-list conn p #:target-lang tgt) '()))
  (define sys (system-prompt tgt src terms))
  ;; #232/#231: the plan is computed BEFORE anything is spent, and a text past
  ;; the cap is still a named refusal — `raise-user-error`, so it is a 400 the
  ;; caller sees rather than a 500 whose message only ever reached them through
  ;; the leak #123 closed.
  (define-values (chunks problem) (translate-plan text #:target tgt #:source src #:terms terms))
  (when problem (raise-user-error 'translate "~a" problem))
  ;; A SHORT TRANSLATION IS STILL EXACTLY ONE MODEL CALL, which is the fourth
  ;; acceptance criterion and is what the single-chunk case gives for free — the
  ;; loop below runs once and `string-append` of one element is that element.
  (define total (box 0))
  ;; 0 of N before anything is spent: a caller following this along learns the
  ;; unit count from its first look rather than after the first section, which
  ;; on a 24-section document is a minute of showing nothing but a clock.
  (progress! 0 (length chunks))
  (define parts
    (for/list ([c (in-list chunks)] [i (in-naturals 1)])
      (let ([stop (admit i (length chunks))])
        (when stop (raise-user-error 'translate "~a" stop)))
      ;; THE SYSTEM PROMPT AND THE GLOSSARY GO TO EVERY CHUNK. Composed once
      ;; above and passed N times: an agreed term applied to the first section of
      ;; a document and not the rest is worse than no glossary at all, because
      ;; nobody reading the output can tell which half to trust.
      (define-values (reply tokens) (chat (hash-ref c 'text) sys))
      (set-box! total (+ (unbox total) (if (number? tokens) tokens 0)))
      (record! (if (number? tokens) tokens 0))
      (progress! i (length chunks))
      reply))
  (define reply (apply string-append parts))
  (define tokens (unbox total))
  (define id (new-id))
  (define model (hash-ref (model-info) 'model "fallback"))
  (query-exec conn
    "INSERT INTO translations (id,team_id,owner_user_id,source_lang,target_lang,source_text,result_text,model) VALUES (?,?,?,?,?,?,?,?)"
;; Sealed (#83 r1, "translation output"). The pipeline's `doc_translate` calls
    ;; this with a document's extracted TEXT, so these two columns hold derived
    ;; document content on every pipeline translation — not only when a user types
    ;; into the Translate tab. That is why they are in scope where `notes` is not:
    ;; a note gets content when a workflow is TOLD to write one, this happens by
    ;; itself. The leak scan missed it because the probe workflow does not
    ;; translate, which is the scan's coverage limit, not an absence of the leak.
    id (principal-team-id p) (principal-user-id p) src tgt
    (seal-source id text)
    (seal-result id reply)
    model)
  (values (hasheq 'id id 'source_lang src 'target_lang tgt 'source_text text 'result reply 'model model
                  ;; how many model calls this cost. Reported rather than
                  ;; inferred: `tokens_used` cannot distinguish one long call
                  ;; from six short ones, and the difference is what an operator
                  ;; reading their budget needs.
                  'chunks (length chunks))
          tokens))

(define (row->tr r)
  (hasheq 'id (vector-ref r 0) 'source_lang (vector-ref r 1) 'target_lang (vector-ref r 2)
          ;; the ONE read path for a stored translation
          'source_text (unseal-source (vector-ref r 0)
                                  (vector-ref r 3))
          'result (unseal-result (vector-ref r 0)
                             (vector-ref r 4))
          'model (vector-ref r 5) 'created_at (vector-ref r 6)))

(define (translate-list conn p #:limit [lim 20])
  (require-perm conn p "chat:use")
  (for/list ([r (in-list (query-rows conn
                          "SELECT id,source_lang,target_lang,source_text,result_text,model,created_at FROM translations WHERE team_id=? ORDER BY created_at DESC LIMIT ?"
                          (principal-team-id p) lim))])
    (row->tr r)))

;; ---- catalog translation (localization dogfood) -----------------------------
(define (extract-json s)
  (let ([m (regexp-match #rx"(?s:[{].*[}])" s)]) (if m (car m) s)))

;; cat: hash of key->string. returns (values translated-hash tokens)
(define (translate-catalog! conn p #:catalog cat #:target-lang tgt #:chat [chat default-chat])
  (require-perm conn p "chat:use")
  (define sys
    (string-append
     "You are a localization engine. You are given a JSON object of UI strings. "
     "Translate every string VALUE into " (lang-label tgt) ". Keep every KEY exactly as-is. "
     "Preserve placeholders like {name} and ICU plural/select syntax EXACTLY. "
     "Return ONLY a JSON object with the same keys and translated values."))
  (define-values (reply tokens) (chat (jsexpr->string cat) sys))
  (define parsed (with-handlers ([exn:fail? (lambda (_) #f)]) (string->jsexpr (extract-json reply))))
  (values (if (hash? parsed) parsed (hasheq)) tokens))
