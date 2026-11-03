#lang racket/base

;; domain/notes/note-tools.rkt — "ask the AI to tag this note" (issue #245),
;; decisions TAG-6 and TAG-7.
;;
;; THE MODEL SEAM IS `current-doc-chat`, the document pipeline's, which the
;; knowledge graph already reuses (kg-tools.rkt) for the reason that applies
;; here too: the `utility` model role (KG-7) exists so a team's bulk model work
;; goes to one executor, and a second parameter for the same model doing the same
;; kind of work would be two things to script in a test and two things to point
;; at a GPU box. An EMBEDDING seam is its own parameter (EMB-1) because that is a
;; different model on a different endpoint; this is not.
;;
;; TAG-7 — THIS IS A TOOL, AND A BACKFILL OVER A TEAM'S NOTES IS A WORKFLOW.
;; CLS-24's rule: a `batch: true` flag here would be one tool call doing
;; unbounded work — no per-note retry, no cancel granularity, no quota admission
;; between notes, and a result that is a list of N outcomes nothing can route on.
;; `map` has been the fan-out primitive since slice 46. The backfill is therefore
;; its own slice, exactly as #87 made the classifier (CLS-1) and the
;; classification backfill (CLS-24) two.

(require racket/list racket/string
         "../tools/dsl.rkt"
         "../agent/registry.rkt"
         "notes.rkt"
         (only-in "../orgs/orgs.rkt" tenant-quota-record!)
         "../authz/authz.rkt"
         "../ai/roles.rkt"                      ; the team's utility executor
         (only-in "../ai/content.rkt" outer-json)
         (only-in "../tools/jsonschema.rkt" validate-json json-valid?)
         (only-in "../repo/doc-tools.rkt" current-doc-chat))

(provide note-autotag! TAG-PROPOSAL-MAX NOTE-TEXT-CAP note_autotag)

;; At most five per call. The cap is on the PROPOSAL, not on the note: TAG-6 adds
;; to what a person typed, and `notes-set-tags!` holds the RESULT to MAX-TAGS, so
;; this number is about how much a model may say at once rather than about how
;; many tags a note may carry.
(define TAG-PROPOSAL-MAX 5)

;; A note is short by nature, but nothing enforces that, and the prompt has to
;; fit a 4,096-token window alongside the team's existing tag list — the agent's
;; own budget trap, met from the prompt side.
(define NOTE-TEXT-CAP 6000)

;; OPEN (`additionalProperties`), unlike the pipeline's closed extraction object
;; (DWF-5). There the shape is the caller's own schema and an unexpected key is a
;; model that did not do as it was told; here the prompt is ours, the only field
;; that matters is `tags`, and every tag is validated one by one below — so a
;; model that helpfully adds "reasoning" should not have its perfectly good tags
;; thrown away. JUDGE-6 made the same call for the same reason.
;; `tags` must be an ARRAY and the schema says nothing about its ITEMS, which is
;; deliberate and a test is what established it: with `items: {type: string}` one
;; number in the list makes the WHOLE reply invalid, so four good tags are thrown
;; away for the fifth — and the per-item check below, which exists to drop
;; exactly that one element, becomes unreachable. The element rules live in one
;; place (`tags-clean`'s own vocabulary) rather than half here and half there.
(define SCHEMA
  (hasheq 'type "object"
          'properties (hasheq 'tags (hasheq 'type "array"))
          'required '("tags")
          'additionalProperties #t))

(define SYSTEM
  (string-append
   "You label a short note with topic tags. Answer with JSON only: "
   "{\"tags\": [\"...\"]}. Rules: at most " (number->string TAG-PROPOSAL-MAX) " tags; "
   "each is one to three words, lower case, no punctuation; "
   "prefer a tag from the list of tags already in use when one fits, because a "
   "synonym makes a second tag for one idea; "
   "answer in the SAME LANGUAGE the note is written in; "
   "if the note says too little to label, answer {\"tags\": []}."))

(define (prompt-for title body in-use)
  (string-append
   (if (null? in-use)
       "Tags already in use: (none yet).\n\n"
       (string-append "Tags already in use: " (string-join in-use ", ") "\n\n"))
   "Note title: " title "\n"
   "Note body:\n"
   (let ([b (format "~a" body)])
     (if (> (string-length b) NOTE-TEXT-CAP) (substring b 0 NOTE-TEXT-CAP) b))))

;; The model's answer, held to the SAME rules a person's tags are held to.
;; CLS-15's lesson: a label the model invents is one keystroke from a tag no
;; filter will ever match, and here `tags-clean` is already the one place that
;; decides what a tag may be — so the model is held to it rather than to a second
;; copy of it. A tag it proposes that cannot be cleaned is DROPPED rather than
;; failing the call, because the other four may be perfectly good; what is
;; dropped is reported, because a tag that silently vanishes is indistinguishable
;; from a model that said nothing.
(define (read-proposal raw)
  (define j (outer-json raw))
  (cond
    [(not (hash? j)) (values '() (list "the reply was not a JSON object"))]
    ;; `validate-json` is (schema value) and answers a LIST — and an EMPTY list is
    ;; truthy in Racket, so a `cond` written on its result alone takes the failure
    ;; branch for a perfectly valid reply. `json-valid?` is the predicate that
    ;; exists for this; the same family of trap as `'null` being truthy.
    [(not (json-valid? SCHEMA j))
     (values '() (validate-json SCHEMA j))]
    [else
     (define proposed (hash-ref j 'tags '()))
     (for/fold ([keep '()] [dropped '()] #:result (values (reverse keep) (reverse dropped)))
               ([raw-tag (in-list (if (list? proposed) proposed '()))])
       (cond
         [(not (string? raw-tag)) (values keep (cons (format "~a is not a string" raw-tag) dropped))]
         [(tag-problem raw-tag)
          => (lambda (why) (values keep (cons (format "~s: ~a" raw-tag why) dropped)))]
         [else (values (cons (tag-normalize raw-tag) keep) dropped)]))]))

(define (meter! conn p tokens)
  (tenant-quota-record! conn p "ai.requests" 1)
  (tenant-quota-record! conn p "ai.tokens.total" tokens))

;; The ONE function both the tool and the endpoint call, so "what auto-tagging
;; does" has a single home and the two surfaces cannot drift — which is the shape
;; `record-type!` already holds for the two classification tools.
;;
;; ALWAYS three values — (values note-or-#f added dropped). Returning a bare #f
;; for "no such note" and three values otherwise is a result arity mismatch at
;; every call site that destructures it, which is a trap this tree has recorded
;; five times and which the HTTP smoke caught here as a 500 on all three autotag
;; assertions.
(define (note-autotag! conn p id #:chat [chat #f])
  (define existing (notes-get conn p id))          ; notes:read, and 403/404 as ever
  (if (not existing)
      (values #f '() '())
      (let ()
         ;; THE WRITE PERMISSION IS CHECKED BEFORE THE MODEL IS CALLED. The call
         ;; sits between a read and a write, so without this a caller who may
         ;; read the note and not write it spends a model request and the team's
         ;; budget and is only then refused — and the refusal they see is about
         ;; the model rather than about their permission. Found by the HTTP
         ;; smoke, asserted with a VIEWER: a member holds both permissions, so
         ;; the same assertion against one passes against a server that checks
         ;; nothing at all.
         (notes-require-write! conn p id)
         ;; the model is shown the tags THIS CALLER can see (TAG-1/PATH-6), never
         ;; the whole team's: a proposal must not be steered by a word that only
         ;; exists on a colleague's private note
         (define in-use (map (lambda (r) (hash-ref r 'tag)) (notes-tag-list conn p)))
         (define-values (reply tokens)
           (parameterize ([current-utility-executor
                           (model-role-executor conn (hash-ref existing 'team_id) "utility")])  ; KG-7
             ((or chat (current-doc-chat))
              (prompt-for (hash-ref existing 'title "") (hash-ref existing 'body "") in-use)
              #:system SYSTEM)))
         ;; metered before the write and whatever the reply turns out to be: the
         ;; request was made, so FEED-9's rule applies — a refusal mid-way still
         ;; records what was already spent
         (meter! conn p tokens)
         (define-values (proposed dropped) (read-proposal reply))
         (define capped (take proposed (min (length proposed) TAG-PROPOSAL-MAX)))
         (define before (hash-ref existing 'tags '()))
         ;; 'add, never 'replace (TAG-6) — a proposal does not remove a word
         ;; somebody typed
         (define after (notes-set-tags! conn p id capped #:mode 'add))
         (values after
                 (remove* before (hash-ref after 'tags '()))
                 dropped))))

;; ---- the agent-facing tool -------------------------------------------------------
;; Agent-facing (`#:agent?` defaults to #t) because its only required argument is
;; a note id — "tag note X" is a whole sentence somebody can utter, which is the
;; line the agent tool surface is drawn on. Nothing here is spec-authored.
(define-tool note_autotag
  #:description "Suggest topic tags for a note and add them to it, in the note's own language."
  (id string #:description "The note id"))

(register-tool! "note_autotag" note_autotag "notes:write"
  (lambda (conn p args)
    (define id (let ([v (hash-ref args 'id "")]) (if (eq? v 'null) "" (format "~a" v))))
    (define-values (n added dropped) (note-autotag! conn p id))
    (cond
      [(not n) "Note not found"]
      [(null? added)
       (format "No new tags for \"~a\"; it already carries ~a"
               (hash-ref n 'title)
               (let ([ts (hash-ref n 'tags '())])
                 (if (null? ts) "none" (string-join ts ", "))))]
      [else (format "Tagged \"~a\" with ~a" (hash-ref n 'title) (string-join added ", "))])))
