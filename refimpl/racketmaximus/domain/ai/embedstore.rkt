#lang racket/base

;; domain/ai/embedstore.rkt — the label vectors, and nothing else (issue #163).
;;
;; EMB-7: THIS STORE IS FOR LABEL VECTORS ONLY, AND SAYING SO IS THE DESIGN.
;; #163's first open question was whether to store document vectors too, and the
;; answer is no — not yet, and not here. A vector per LABEL is a handful of
;; arrays in a settings document: there are at most `MAX-LABELS` of them, they
;; change when an operator edits the label set, and nothing has to search them,
;; because classification compares against every one.
;;
;; A vector per DOCUMENT is a different subsystem wearing the same words. Neither
;; dialect has a vector type, there is no index that would make a nearest
;; neighbour over a team's whole repository anything but a full scan, and this
;; tree has no JSON SQL at all (FEED/#114 settled that when the feed queue needed
;; a typed table rather than LAY-4 attributes). Picking the cheap home now — a
;; blob per document in a settings row — would decide that badly and in a way
;; that is expensive to undo, because by then something would depend on it.
;;
;; So this module CANNOT serve document similarity, and that is deliberate: when
;; semantic search is built it must be forced to answer the storage question
;; rather than inheriting an answer nobody made on purpose.
;;
;; EMB-9: NOT SEALED, and the reason is what the plaintext IS. `TMACH_ENCRYPT_CONTENT`
;; seals content the platform retains by itself — extracted document text, a job
;; payload, a run's bindings. A label vector is derived from the label's own
;; `name`, `description` and `examples`, which are operator-authored
;; CONFIGURATION: they arrive as a tool argument, they are stored unsealed in the
;; workflow spec that passes them, and they are echoed back by the evaluation
;; harness. Sealing a function of that text, two keys away from the text itself,
;; protects nothing and would put a column `rewrap` does not walk into the
;; schema — which #91 req 1 records as the way a sealed value becomes silently
;; unrotatable. The day a DOCUMENT vector is stored, the answer is the opposite,
;; because a document vector is a function of content this platform retained.

(require racket/list racket/string
         (only-in file/sha1 sha1)
         (only-in "../settings/settings.rkt" setting-ref setting-set!))

(provide label-embed-text label-vectors label-cache-key
         cosine embed-store-read embed-store-clear!)

(define (label-cache-key team-id) (string-append "embed-labels:" team-id))

;; What gets embedded FOR a label, and it is a contract rather than a detail: the
;; cached vector is keyed by the sha1 of exactly this string, so changing how it
;; is composed invalidates every cached vector on every instance. That is the
;; correct behaviour — the vectors really would be of different text — but it is
;; a re-embed of every label on every team, so it is a decision, not a tidy-up.
;;
;; Name, description and examples, in that order, one per line. The NAME is
;; included because a label is often only a word and that word is the signal
;; ("invoice"); the examples are included because CLS's label shape offers them
;; and a nearest-label backend is exactly what they are useful for.
(define (label-embed-text l)
  (define (str x) (if (string? x) x ""))
  (string-join
   (filter (lambda (s) (not (string=? s "")))
           (append (list (str (hash-ref l 'name ""))
                         (str (hash-ref l 'description "")))
                   (let ([e (hash-ref l 'examples '())])
                     (if (list? e) (map str e) '()))))
   "\n"))

(define (text-hash s) (sha1 (open-input-string s)))

;; The stored document:
;;
;;   {"model": "<the embedding model that produced these>",
;;    "dim": 768,
;;    "vectors": {"<label name>": {"hash": "<sha1 of label-embed-text>",
;;                                 "v": [0.0123, ...]}}}
;;
;; EMB-8: A MODEL CHANGE INVALIDATES EVERYTHING; A LABEL EDIT INVALIDATES ONE.
;; #163's third question. Vectors from two checkpoints are not comparable — the
;; same discontinuity `digest_key_id` records for the request log (RED-18) — and
;; the failure mode if they are mixed is not an error: it is a cosine between two
;; unrelated coordinate systems, which produces a number, and therefore a
;; confident classification nobody can tell is nonsense. So the model name is
;; stored BESIDE the vectors and a mismatch discards the whole document.
;;
;; The per-label `hash` is the same rule `locales/ja.json` and the screenshot
;; caption catalogs already live by: the vector carries the sha1 of the text it
;; was made from, so editing one label's description makes exactly that vector
;; stale with nothing rewriting a status, and the other labels are not re-embedded.
(define (embed-store-read conn team-id model)
  (define doc (setting-ref conn (label-cache-key team-id) (hasheq)))
  (define stored-model (hash-ref doc 'model #f))
  (cond
    ;; not a mismatch to repair — a cache from another checkpoint is not a cache
    [(not (equal? stored-model model)) (hasheq)]
    [else (let ([v (hash-ref doc 'vectors (hasheq))]) (if (hash? v) v (hasheq)))]))

(define (embed-store-clear! conn team-id)
  (setting-set! conn (label-cache-key team-id) (hasheq)))

;; -> (values (hash name -> (vectorof real)) tokens-spent)
;;
;; `embed` is `(listof string) -> (values (listof vector) tokens)`, the seam
;; `embed-exchange` fills and a test scripts. This module never calls the network
;; and never meters: the CALLER meters, which is `translate!`'s rule and
;; `classify-llm`'s — the quota principal lives above the domain.
(define (label-vectors conn team-id labels model #:embed embed)
  (define cached (embed-store-read conn team-id model))
  (define wanted
    (for/list ([l (in-list labels)])
      (define name (hash-ref l 'name ""))
      (list name (label-embed-text l))))
  ;; which are missing, and which were made from text that has since changed
  (define stale
    (for/list ([w (in-list wanted)]
               #:unless (let* ([e (hash-ref cached (string->symbol (car w)) #f)]
                               [h (and (hash? e) (hash-ref e 'hash #f))])
                          (equal? h (text-hash (cadr w)))))
      w))
  (define-values (fresh tokens)
    (cond
      [(null? stale) (values (hasheq) 0)]
      [else
       (define-values (vs toks) (embed (map cadr stale)))
       (unless (= (length vs) (length stale))
         (error 'label-vectors "the embedding seam answered ~a vector(s) for ~a label(s)"
                (length vs) (length stale)))
       (values (for/hasheq ([w (in-list stale)] [v (in-list vs)])
                 (values (string->symbol (car w))
                         (hasheq 'hash (text-hash (cadr w))
                                 'v (for/list ([x (in-vector v)]) x))))
               (or toks 0))]))
  ;; Write back only what this call touched, over whatever survived the model
  ;; check. A label REMOVED from the set has its vector dropped here rather than
  ;; kept for ever: the document is the team's current label set, and a vector
  ;; for a label nobody can be classified into is dead weight that outlives the
  ;; decision to remove it.
  (define merged
    (for/fold ([h (hasheq)]) ([w (in-list wanted)])
      (define k (string->symbol (car w)))
      (hash-set h k (or (hash-ref fresh k #f) (hash-ref cached k #f)))))
  (when (pair? stale)
    (setting-set! conn (label-cache-key team-id)
                  (hasheq 'model model
                          'dim (let ([any (for/or ([(_ e) (in-hash merged)]) e)])
                                 (if (hash? any) (length (hash-ref any 'v '())) 0))
                          'vectors merged)))
  (values (for/hasheq ([(k e) (in-hash merged)])
            (values k (list->vector (hash-ref e 'v '()))))
          tokens))

;; Cosine similarity, mapped from [-1,1] onto [0,1] by the caller — NOT here,
;; because this is the mathematical object and the mapping is a policy about what
;; "confidence" means.
;;
;; A zero vector has no direction, so its similarity to anything is undefined
;; rather than 0: answering 0 would make it the WORST match, which is a claim,
;; where #f lets the caller say it could not compare. Providers do return a zero
;; vector for empty input, which is why this is reachable.
(define (cosine a b)
  (cond
    [(not (= (vector-length a) (vector-length b))) #f]
    [(zero? (vector-length a)) #f]
    [else
     (define-values (dot na nb)
       (for/fold ([dot 0.0] [na 0.0] [nb 0.0]) ([x (in-vector a)] [y (in-vector b)])
         (values (+ dot (* x y)) (+ na (* x x)) (+ nb (* y y)))))
     (and (positive? na) (positive? nb)
          (/ dot (* (sqrt na) (sqrt nb))))]))
