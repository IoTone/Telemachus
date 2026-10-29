#lang racket/base

;; domain/ai/chunk.rkt — a document's text, cut into pieces worth embedding
;; (issue #189 step 3, decisions CHUNK‑1…9).
;;
;; `docs/design/vector-store.md`'s build plan calls this "the decision that
;; governs retrieval quality and the one with no measurement behind it yet,
;; because measuring recall needs a real embedding endpoint". That is true of ONE
;; thing — the chunk SIZE and the OVERLAP, which is why both are parameters and
;; why their defaults are labelled provisional below. It is not true of the
;; mechanism, which is a pure function of a string and three numbers: where a
;; boundary falls, what an offset MEANS, that the walk terminates, and that two
;; runs over the same bytes produce the same offsets. All four are decidable here
;; and all four are tested, so the slice that waits for hardware is a
;; calibration rather than a build.
;;
;; CHUNK‑1 — THE OFFSETS ARE CHARACTER OFFSETS INTO THE TEXT THE EXTRACTOR
;; RETURNED, which is the one in `repo_text.content`. That is not a convention
;; chosen for tidiness: LAY‑5's `repo_text.spans` indexes the same string, so
;; `spans-covering` (extract.rkt) resolves a chunk's start to a page and a bbox
;; with NO NEW CODE, and step 5's "return the chunk's offsets so the caller can
;; cite it" becomes a lookup rather than a second coordinate system. A chunker
;; that carried its own notion of position — token indices, paragraph numbers —
;; would need a mapping back, and a mapping is a thing that can disagree.
;;
;; CHUNK‑2 — THE UNIT IS CHARACTERS, NOT TOKENS, AND THAT IS FORCED. There is no
;; tokenizer in this tree, and the tokenizer that matters is `nomic-embed-text`'s
;; own: a token count computed here would be a guess wearing a number's clothes.
;; The defaults are converted from the 256-token figure the design document
;; measured #183's corpus with, at the usual English ratio of about four
;; characters to the token.
;;
;; **AND THE RATIO IS AN ENGLISH ASSUMPTION, which is a finding rather than a
;; footnote.** Japanese runs closer to one character per token, so a 1,024-
;; character chunk of Japanese is roughly four times the tokens a 1,024-character
;; chunk of English is, and this platform ships a complete `ja` catalog and a
;; Japanese edition of its own book. A chunk that overruns the model's context is
;; silently truncated BY THE MODEL, so the failure is a quietly worse embedding
;; and not an error. The recall measurement must therefore be made in both
;; languages, and if it has to be one number per language then `size` is already
;; the knob for it. Nothing here guesses at a locale.
;;
;; CHUNK‑3 — A BOUNDARY IS PREFERRED, NEVER REQUIRED. The search runs BACKWARDS
;; from the hard limit through a bounded window: a sentence end, then any
;; whitespace, then — last — the hard limit itself, mid-word. The window is what makes that safe on text with no boundaries in it
;; at all: minified JSON, a base64 blob, a line of CJK with no spaces. Searching
;; the whole chunk for a boundary would let one such document produce a chunk a
;; few characters long per step, which is a recall problem and a cost problem and
;; looks like neither.
;;
;; CHUNK‑4 — THE PROGRESS RULE IS THE ONE PLACE TERMINATION IS GUARANTEED, and
;; it is deliberately not inferred from the parameter checks. The next start is
;; `(max (add1 start) (- end overlap))`. Three knobs interact — size, overlap and
;; the boundary window — so an argument that the arithmetic cannot stall is an
;; argument about all three at once, and the kind of thing that stays true until
;; somebody changes one. One rule, stated once, with a test and a control: remove
;; the `max` and a chunk whose boundary landed early repeats for ever. What the
;; guard promises is PROGRESS and not coverage: `overlap` is only held below
;; `size`, so a caller who sets the two within a character of each other
;; advances one character per chunk and the count cap (CHUNK‑7) is what ends the
;; walk, reporting `truncated`. A degenerate setting that says so beats one that
;; hangs.
;;
;; CHUNK‑5 — A WHITESPACE-ONLY CHUNK IS NEVER EMITTED. VEC's `vec-normalize`
;; answers `#f` for a zero vector because a zero vector has no direction, and
;; `vector-store.md` already names "a chunker will eventually hand an embedder
;; one whitespace-only chunk" as the way that is reached. Refusing to produce one
;; is better than refusing to embed one: it costs no request, no budget and no
;; row, and it means the output of this module is exactly "the chunks worth
;; embedding" rather than a list something downstream has to filter.
;;
;; CHUNK‑6 — PURE, AND THAT IS WHAT MAKES STEP 4 CHEAP. No clock, no randomness,
;; no database: the same text and the same parameters give byte-identical
;; offsets in any process. So a re-chunk of an unchanged version is a no-op that
;; can be recognised as one, and a stored chunk's offsets are still true about
;; the text they were cut from. `canonical-json`'s stability argument (FEED‑18),
;; one layer up.
;;
;; CHUNK‑7 — THE COUNT IS CAPPED AND THE TRUNCATION IS REPORTED. `EXTRACT-CAP`
;; already bounds one document at 200,000 characters, which at the provisional
;; defaults is about 230 chunks — the figure `vector-store.md` quotes. The cap
;; here is a second, independent bound, because `size` is a caller's argument and
;; a small one turns one document into thousands of model requests against a
;; 200/day `ai.requests` default. It answers `truncated` rather than quietly
;; stopping: CLS‑27's rule, where a short page and the last page are the same
;; shape and must not be.
;;
;; CHUNK‑8 — THERE IS NO PARAGRAPH SCAN, AND A POSITIVE CONTROL IS WHAT REMOVED
;; IT. The first version preferred a blank line over a sentence end, which reads
;; well and was doing nothing: `#\newline` is already a member of
;; SENTENCE-ENDERS, so both scans walk BACKWARDS to a newline and on ordinary
;; prose they find the same one. Dropping it changed no test at all — #110 r1's
;; shape, where a check that duplicates the next one is how a reader comes to
;; believe the next one is missing.
;;
;; Where the two genuinely differed is the case that settles it: a window
;; holding a blank line AND, later, a single line break. The paragraph scan
;; prefers the EARLIER, stronger break — which on a hard-wrapped document, where
;; every line ends in a newline, walks back up to the whole window and gives
;; away a quarter of every chunk. The cost of ending mid-paragraph instead is
;; the seam, and the overlap is what already covers a seam (CHUNK‑4). So the
;; trade is a measurable quarter of the context against a coherence argument
;; with no number behind it, and this module does not pay that. If a recall
;; measurement later shows paragraph-aligned chunks retrieve better, it comes
;; back WITH the number.
;;
;; NOTHING CALLS THIS YET, by the build plan's own ordering (#110 r4's rule, and
;; its stated exception — an export with a test behind it). Step 4 is the table
;; and the write path in `plugins/doc-indexer`.

(require racket/string)

(provide CHUNK-SIZE-DEFAULT CHUNK-OVERLAP-DEFAULT CHUNK-MAX-DEFAULT
         chunk-text chunk-blank?)

;; PROVISIONAL, and the word is load-bearing: these two numbers are the ones the
;; build plan says wait for a live `nomic-embed-text`. 256 tokens at ~4 English
;; characters to the token, with the 15% overlap `vector-store.md` measured
;; #183's corpus at. What would change them is a recall measurement, in both
;; languages (CHUNK‑2) — not a preference.
(define CHUNK-SIZE-DEFAULT 1024)
(define CHUNK-OVERLAP-DEFAULT 154)      ; 15% of the size, rounded

;; A second bound, independent of `EXTRACT-CAP` (CHUNK‑7).
(define CHUNK-MAX-DEFAULT 400)

;; The window the boundary search may walk back through, as a fraction of the
;; size (CHUNK‑3). A quarter: enough to reach the end of an ordinary sentence,
;; far short of enough to let a boundary-free document produce slivers.
(define BOUNDARY-FRACTION 1/4)

(define (chunk-blank? s) (string=? "" (string-trim s)))

;; A sentence end, then any whitespace. `#\newline` is a member, which is why
;; there is NO separate paragraph scan — see CHUNK‑8. The CJK enders are
;; here because this platform ships a Japanese edition of its own documentation,
;; and `。` is the boundary a Japanese paragraph actually offers — a whitespace
;; search finds nothing inside one.
(define SENTENCE-ENDERS '(#\. #\! #\? #\。 #\！ #\？ #\newline))

;; The split point at or before `hard`, never earlier than `floor`. Answers the
;; position AFTER the boundary, so a chunk ends with its own sentence.
(define (boundary-before text floor hard)
  (define (scan ok?)
    (let loop ([i (sub1 hard)])
      (cond
        [(< i floor) #f]
        [(ok? i) (add1 i)]
        [else (loop (sub1 i))])))
  (or
   (scan (lambda (i) (and (memv (string-ref text i) SENTENCE-ENDERS) #t)))
   (scan (lambda (i) (char-whitespace? (string-ref text i))))
   hard))

;; (chunk-text text) -> (values chunks truncated?)
;;
;; Each chunk is `(hasheq 'index i 'start s 'end e 'text str)`, in document
;; order, `index` dense over what was EMITTED (CHUNK‑5 drops a blank one, and a
;; gap in the ordinals would be a key with a hole in it for step 4). `start` and
;; `end` are character offsets into `text`, half-open, in `repo_text.spans`'
;; coordinates (CHUNK‑1).
(define (chunk-text text
                    #:size [size CHUNK-SIZE-DEFAULT]
                    #:overlap [overlap CHUNK-OVERLAP-DEFAULT]
                    #:max-chunks [max-chunks CHUNK-MAX-DEFAULT])
  (unless (and (exact-integer? size) (>= size 16))
    (error 'chunk-text "size must be an integer of at least 16, got: ~a" size))
  (unless (and (exact-nonnegative-integer? overlap) (< overlap size))
    (error 'chunk-text
           "overlap must be a non-negative integer below the size (~a), got: ~a"
           size overlap))
  (unless (and (exact-integer? max-chunks) (positive? max-chunks))
    (error 'chunk-text "max-chunks must be a positive integer, got: ~a" max-chunks))
  (define len (string-length text))
  (define window (max 1 (inexact->exact (floor (* size BOUNDARY-FRACTION)))))
  (let loop ([start 0] [out '()] [n 0])
    (cond
      [(>= start len) (values (reverse out) #f)]
      [(>= n max-chunks) (values (reverse out) #t)]
      [else
       (define hard (min len (+ start size)))
       ;; The last chunk needs no boundary search: there is nothing after it to
       ;; carry the remainder, so a boundary would simply drop the tail.
       (define end (if (= hard len) len (boundary-before text (- hard window) hard)))
       (define body (substring text start end))
       (define keep? (not (chunk-blank? body)))
       ;; CHUNK‑4: the ONE place termination is guaranteed, and the first arm
       ;; is there because a test found its absence. Once a chunk ends at the
       ;; end of the text there is nothing left to cover — and the overlap
       ;; subtracts from the end, so without this the walk steps BACK inside a
       ;; finished document and re-emits its tail until the cap stops it. The
       ;; symptom is a short document answering with `max-chunks` identical
       ;; chunks and `truncated`, which reads as a cap that is set too low.
       (define next (if (>= end len) len (max (add1 start) (- end overlap))))
       (loop next
             (if keep?
                 (cons (hasheq 'index n 'start start 'end end 'text body) out)
                 out)
             (if keep? (add1 n) n))])))
