#lang racket/base

;; test/chunk-tests.rkt — the chunker (issue #189 step 3, CHUNK‑1…9).
;;
;; What this file can and cannot establish, said at the top because the build
;; plan is explicit that half of step 3 waits for hardware. It CANNOT say whether
;; 1,024 characters with 154 of overlap retrieves well — that is a recall
;; measurement against a live `nomic-embed-text` and no assertion here stands in
;; for it. It CAN say that the offsets mean what `repo_text.spans` means, that
;; the walk terminates, that a boundary-free document does not produce slivers,
;; that nothing blank is emitted, and that two runs agree — which is every
;; property step 4 has to be able to rely on.

(require rackunit
         racket/string
         racket/list
         (only-in "../domain/ai/chunk.rkt"
                  chunk-text chunk-blank?
                  CHUNK-SIZE-DEFAULT CHUNK-OVERLAP-DEFAULT CHUNK-MAX-DEFAULT)
         (only-in "../domain/repo/extract.rkt" spans-covering EXTRACT-CAP))

(define chunks-of
  (make-keyword-procedure
   (lambda (kws kw-args t)
     (define-values (cs trunc) (keyword-apply chunk-text kws kw-args (list t)))
     cs)))

;; ---- CHUNK‑1: the offsets are `repo_text.spans`' own coordinates ------------

(test-case "a chunk's offsets index the text it was cut from"
  (define t (string-append (make-string 900 #\a) " " (make-string 900 #\b)))
  (define cs (chunks-of t))
  (check-true (> (length cs) 1))
  (for ([c (in-list cs)])
    ;; the one property every later reader depends on: the text IS the substring
    (check-equal? (hash-ref c 'text)
                  (substring t (hash-ref c 'start) (hash-ref c 'end)))))

(test-case "a chunk's start resolves through spans-covering with no new code"
  ;; This is CHUNK‑1's whole argument, so it is asserted against the REAL
  ;; function rather than restated: LAY‑5 spans index the same string, so a hit
  ;; can be shown on the page it was read from.
  (define t (string-append (make-string 1200 #\x) " tail"))
  (define spans (list (hasheq 'start 0 'end 600 'page 1 'bbox '(0 0 10 10))
                      (hasheq 'start 600 'end 1300 'page 2 'bbox '(0 0 10 10))))
  (define cs (chunks-of t))
  (check-true (>= (length cs) 2))
  (define second-start (hash-ref (second cs) 'start))
  (define covering (spans-covering spans second-start))
  (check-equal? 1 (length covering))
  (check-equal? 2 (hash-ref (car covering) 'page)))

;; ---- CHUNK‑3: boundaries are preferred, never required ---------------------

(test-case "a chunk ends at a line break when one is in reach"
  (define para (string-append (make-string 950 #\a) "\n\n" (make-string 900 #\b)))
  (define cs (chunks-of para))
  ;; the first chunk carries the a's and the break, not the start of the b's
  (check-equal? 952 (hash-ref (first cs) 'end))
  (check-false (string-contains? (hash-ref (first cs) 'text) "b")))

(test-case "a LATER line break wins over an EARLIER paragraph break (CHUNK‑8)"
  ;; This is the case that distinguishes the paragraph scan the first version
  ;; had from the sentence scan that replaced it, and it is here because the
  ;; control for that scan could not bite without it. A hard-wrapped document
  ;; puts a newline at the end of every line, so preferring the blank line
  ;; would walk back through the whole window and shorten every chunk by up to
  ;; a quarter. The boundary taken is the last one in the window.
  (define t (string-append (make-string 850 #\a) "\n\n"
                           (make-string 100 #\b) "\n"
                           (make-string 900 #\c)))
  (define cs (chunks-of t))
  (check-equal? 953 (hash-ref (first cs) 'end))
  (check-true (string-contains? (hash-ref (first cs) 'text) "b")
              "the chunk must reach past the blank line to the later break"))

(test-case "ONE early boundary does not make a sliver of the whole document"
  ;; The window's real subject: a document whose only boundary is near the
  ;; start, then an unbroken run. Searching the whole chunk for a boundary
  ;; splits two characters in, and every chunk after it is a sliver — a recall
  ;; problem and a cost problem that looks like neither. The fixture with NO
  ;; boundary at all cannot see this, which is what a control showed.
  (define t (string-append "a " (make-string 3000 #\Z)))
  (define cs (chunks-of t #:size 1024 #:overlap 0))
  (check-true (>= (- (hash-ref (first cs) 'end) (hash-ref (first cs) 'start)) 768)
              "the first chunk must not be cut to the early boundary")
  (check-equal? 1024 (hash-ref (first cs) 'end)))

(test-case "…then a sentence end, including a Japanese one"
  ;; CHUNK‑3's CJK clause: a whitespace search finds nothing inside a Japanese
  ;; paragraph, so `。` is the boundary that one actually offers. Without it the
  ;; split is mid-word for every Japanese document this platform stores.
  (define ja (string-append (make-string 1000 #\あ) "。" (make-string 500 #\い)))
  (define cs (chunks-of ja))
  (check-equal? 1001 (hash-ref (first cs) 'end))
  (check-equal? #\。 (string-ref (hash-ref (first cs) 'text) 1000)))

(test-case "…then any whitespace"
  (define t (string-append (make-string 1000 #\a) " " (make-string 500 #\b)))
  (define cs (chunks-of t))
  (check-equal? 1001 (hash-ref (first cs) 'end)))

(test-case "a document with NO boundary at all splits at the hard limit, not into slivers"
  ;; The window is what makes the backward search safe. Minified JSON, a base64
  ;; blob or an unspaced CJK line has nothing to find, and a search over the
  ;; whole chunk would walk back to the floor every time.
  (define blob (make-string 5000 #\Z))
  (define cs (chunks-of blob #:size 1024 #:overlap 0))
  (check-equal? 1024 (hash-ref (first cs) 'end))
  ;; every chunk but the last is the full size — nothing was given away
  (for ([c (in-list (drop-right cs 1))])
    (check-equal? 1024 (- (hash-ref c 'end) (hash-ref c 'start)))))

;; ---- CHUNK‑4: the walk terminates, and the overlap is real -----------------

(test-case "the start strictly increases, and the chunks cover the text"
  (define t (string-join (for/list ([i 400]) (format "sentence ~a is here." i)) " "))
  (define cs (chunks-of t))
  (for ([a (in-list cs)] [b (in-list (cdr cs))])
    (check-true (> (hash-ref b 'start) (hash-ref a 'start))
                "a chunk must start after the one before it"))
  ;; no gap: each chunk begins at or before the previous one's end
  (for ([a (in-list cs)] [b (in-list (cdr cs))])
    (check-true (<= (hash-ref b 'start) (hash-ref a 'end))
                "the chunks must leave no text uncovered"))
  (check-equal? 0 (hash-ref (first cs) 'start))
  (check-equal? (string-length t) (hash-ref (last cs) 'end)))

(test-case "consecutive chunks overlap, and the overlap carries real text"
  ;; Overlap exists so a sentence spanning a boundary is retrievable from one
  ;; side or the other. Asserting the arithmetic alone would pass against a
  ;; version that overlapped whitespace.
  (define t (string-join (for/list ([i 300]) (format "alpha ~a omega." i)) " "))
  (define cs (chunks-of t #:size 1024 #:overlap 154))
  (check-true (> (length cs) 2))
  (define a (first cs))
  (define b (second cs))
  (define shared (substring t (hash-ref b 'start) (hash-ref a 'end)))
  (check-true (>= (string-length shared) 100))
  (check-false (chunk-blank? shared)))

(test-case "an overlap at or above the size is refused, not clamped"
  ;; A clamp would be a parameter silently meaning something else; the caller is
  ;; one keyword from a working call.
  (check-exn exn:fail? (lambda () (chunk-text "abc" #:size 64 #:overlap 64)))
  (check-exn exn:fail? (lambda () (chunk-text "abc" #:size 64 #:overlap 100)))
  (check-exn exn:fail? (lambda () (chunk-text "abc" #:size 4)))
  (check-exn exn:fail? (lambda () (chunk-text "abc" #:max-chunks 0))))

;; ---- CHUNK‑5: nothing blank is emitted -------------------------------------

(test-case "a whitespace-only chunk is never emitted, and the ordinals stay dense"
  ;; VEC's `vec-normalize` answers #f for a zero vector, which is what embedding
  ;; a blank chunk produces. Not producing one costs no request and no row.
  (define t (string-append "alpha" (make-string 4000 #\space) "omega"))
  (define cs (chunks-of t #:size 64 #:overlap 0))
  (for ([c (in-list cs)])
    (check-false (chunk-blank? (hash-ref c 'text))))
  (check-equal? (for/list ([i (length cs)]) i)
                (map (lambda (c) (hash-ref c 'index)) cs)
                "the index must be dense over what was emitted")
  ;; and the text really was all there: both words survived
  (check-true (ormap (lambda (c) (string-contains? (hash-ref c 'text) "alpha")) cs))
  (check-true (ormap (lambda (c) (string-contains? (hash-ref c 'text) "omega")) cs)))

(test-case "empty and whitespace-only documents produce nothing, and do not hang"
  (define-values (a at) (chunk-text ""))
  (check-equal? '() a)
  (check-false at)
  (define-values (b bt) (chunk-text (make-string 3000 #\newline)))
  (check-equal? '() b)
  (check-false bt))

;; ---- CHUNK‑6: pure, so re-chunking is recognisable as a no-op --------------

(test-case "two runs over the same text agree exactly"
  (define t (string-join (for/list ([i 200]) (format "line ~a." i)) "\n"))
  (define-values (a _a) (chunk-text t))
  (define-values (b _b) (chunk-text t))
  (check-equal? a b))

;; ---- CHUNK‑7: the count is capped and the truncation is reported -----------

(test-case "the cap reports itself rather than stopping quietly"
  (define t (make-string 100000 #\q))
  (define-values (cs trunc) (chunk-text t #:size 64 #:overlap 0 #:max-chunks 10))
  (check-equal? 10 (length cs))
  (check-true trunc "a run that stopped at the cap must say so")
  ;; …and a document that fits is NOT reported as truncated, or the flag means
  ;; nothing. CLS‑27's two meanings, kept apart.
  (define-values (cs2 trunc2) (chunk-text (make-string 100 #\q) #:max-chunks 10))
  (check-equal? 1 (length cs2))
  (check-false trunc2))

(test-case "a capped document at the provisional defaults matches the design figure"
  ;; `vector-store.md` says EXTRACT-CAP bounds one document at about 230 chunks.
  ;; This pins that the defaults really do produce that order of magnitude, so
  ;; the figure in the design document is not a number nobody checked — and that
  ;; CHUNK-MAX-DEFAULT is comfortably above it rather than secretly the binding
  ;; constraint on an ordinary large document.
  (define t (string-join (for/list ([i 34000]) (format "word~a" i)) " "))
  (check-true (>= (string-length t) EXTRACT-CAP))
  (define-values (cs trunc)
    (chunk-text (substring t 0 EXTRACT-CAP)))
  (check-false trunc)
  (check-true (< 180 (length cs) 280)
              (format "expected about 230 chunks at the defaults, got ~a" (length cs)))
  (check-true (< (length cs) CHUNK-MAX-DEFAULT)))

(test-case "a boundary landing near the floor with a large overlap still advances"
  ;; CHUNK‑4's `max` is unreachable at the defaults — the window is a quarter of
  ;; the size and the overlap is 15%, so `end - overlap` is always well past
  ;; `start`. It is reachable through the parameters, which are a caller's: with
  ;; the overlap just under the size, a boundary found at the bottom of the
  ;; window puts `end - overlap` BEHIND `start`. Without the `max` the walk
  ;; stalls there and produces the same chunk for ever. A guard with no case
  ;; behind it is a gap, so this is the case.
  (define t (string-append (make-string 48 #\a) " " (make-string 400 #\b)))
  (define-values (cs trunc) (chunk-text t #:size 64 #:overlap 63 #:max-chunks 200))
  (check-true (> (length cs) 1))
  (for ([a (in-list cs)] [b (in-list (cdr cs))])
    (check-true (> (hash-ref b 'start) (hash-ref a 'start))))
  ;; What the guard promises is PROGRESS, not a whole document: at an overlap
  ;; this close to the size it advances a single character per chunk, so the cap
  ;; is what ends the walk and `truncated` is what says so. That is the honest
  ;; outcome for a parameter pair nobody should choose, and it is reported
  ;; rather than hidden — which is the difference between a degenerate setting
  ;; and a hang.
  (check-true trunc)
  (check-equal? 200 (length cs)))
