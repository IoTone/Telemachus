#lang racket/base

;; domain/repo/redact.rkt — keeping identifiers out of a model request
;; (issue #91 requirement 1, decisions RED-1…9).
;;
;; A workflow can send a document's text to a model, and until this there was no
;; step that MINIMISED what went: a letter naming a person, their telephone
;; number and their date of birth was sent entire, to whatever executor the team
;; had configured. This module finds those spans and replaces them with stable
;; tokens; the map from token back to value is the caller's to keep (doc-tools.rkt
;; seals it into a row) and is the one artifact this platform most has to protect.
;;
;; IT IS PURE OF THE REPOSITORY, like `classify.rkt` beside it: text in, redacted
;; text and a map out, so every rule below is testable with a string and no
;; database, no model and no document.
;;
;; RED-1: THE DETECTORS ARE A CLOSED, PLATFORM-AUTHORED SET AND THE CALLER
;; CHOOSES ONLY WHICH ONES RUN. The requirement says "regex (emails, phones,
;; SSN-like, policy/account numbers, dates)" and those are the CLASSES to detect,
;; not a facility for writing patterns: an operator-authored regexp evaluated
;; against the text of a document the operator does not control is a denial of
;; service with the operator's own configuration as the weapon, which is the call
;; `classify.rkt` made for its rules (CLS-2), `fields.rkt` made for the funnel's
;; validation vocabulary and `bind.rkt` made for the workflow binding
;; sublanguage. The same answer here, and for once it costs the caller nothing:
;; nobody wants to write an email pattern, they want emails found.
;;
;; Every pattern below is therefore reviewed in one place, and each is written
;; with NO NESTED QUANTIFIER — the shape that backtracks catastrophically — and
;; against input the extractor has already capped.

(require racket/string racket/list racket/match)

(provide DETECTORS TOKEN-CLASSES MAX-TERMS MAX-TERM-LENGTH
         detectors-problem terms-problem token-shaped?
         redact redaction-counts)

;; ---- the vocabulary ------------------------------------------------------------------
;; CLOSED, in the sense `EXTRACT-REASONS` and `REVIEW-VERDICTS` are closed: a
;; detector nobody declared would arrive in a stored report as a name nothing
;; explains, and the quality report (requirement 5) is counts PER DETECTOR — a
;; report whose rows a reader cannot look up is not a report.
;;
;; `dictionary` is the only one the caller supplies anything for, and what it
;; supplies is LITERAL STRINGS, never patterns (RED-1). A name is a name.
;;
;; THE ORDER IS THE PRIORITY, AND IT RUNS FROM THE MOST SPECIFIC PATTERN TO THE
;; LOOSEST (RED-3's tie-break). `phone` is last because it is the loosest thing
;; here by a wide margin — a digit, then seven to nineteen digits-and-separators,
;; then a digit — and that is not a hypothetical: with `phone` ranked FIRST, as
;; the first version of this list had it, the fixture letter's `2026-10-14` came
;; back as `<PHONE_1>` and its `078-05-1120` as `<PHONE_3>`, because the phone
;; pattern matched exactly as many characters as the date and the SSN patterns
;; did and won the tie. The redaction was still complete — nothing leaked — but
;; the quality report said one date and three telephone numbers about a letter
;; that had two of each, and requirement 5 exists to be read.
(define DETECTORS '("email" "date" "id_number" "dictionary" "phone"))

;; The token CLASS each detector mints, which is what the issue's `<PERSON_1>` /
;; `<DATE_2>` / `<ID_3>` asks for. Several detectors may share a class.
(define TOKEN-CLASSES
  (hash "email" "EMAIL" "phone" "PHONE" "id_number" "ID"
        "date" "DATE" "dictionary" "PERSON"))

(define MAX-TERMS 200)
(define MAX-TERM-LENGTH 120)

;; ---- the patterns --------------------------------------------------------------------
;; One detector may own several patterns; they are tried in order and the
;; longest-match rule below settles any overlap, so the order inside a detector
;; is not load-bearing.
(define DETECTOR-PATTERNS
  (hash
   "email"
   (list #px"[A-Za-z0-9._%+-]+@[A-Za-z0-9-]+\\.[A-Za-z0-9.-]*[A-Za-z]{2}")
   ;; A leading `+`, then digits and the separators a person actually types.
   ;; Bounded, one quantifier run, and it demands a digit at each end so it
   ;; cannot end on a bracket or a dash.
   "phone"
   (list #px"\\+?[0-9][0-9 ()./-]{7,19}[0-9]")
   ;; "SSN-like, policy/account numbers". The grouped form first, so the
   ;; longest-match rule prefers it over the bare run inside it.
   "id_number"
   (list #px"[0-9]{3}-[0-9]{2}-[0-9]{4}"
         #px"\\b[A-Z]{1,4}[-/]?[0-9]{5,12}\\b"
         #px"\\b[0-9]{6,12}\\b")
   "date"
   (list #px"\\b[0-9]{4}-[0-9]{2}-[0-9]{2}\\b"
         #px"\\b[0-9]{1,2}/[0-9]{1,2}/[0-9]{2,4}\\b"
         #px"\\b[0-9]{1,2} (?i:January|February|March|April|May|June|July|August|September|October|November|December) [0-9]{4}\\b"
         #px"\\b(?i:January|February|March|April|May|June|July|August|September|October|November|December) [0-9]{1,2}, [0-9]{4}\\b")))

;; ---- what the caller may ask for -----------------------------------------------------
(define (detectors-problem ds)
  (cond
    [(not (and (list? ds) (andmap string? ds))) "detectors must be an array of strings"]
    [(null? ds) "at least one detector is needed"]
    [(for/or ([d (in-list ds)]) (and (not (member d DETECTORS)) d))
     => (lambda (d)
          (format (string-append
                   "unknown detector '~a' — this build detects ~a. A detector is a NAMED, "
                   "platform-authored pattern rather than one the caller writes: a regular "
                   "expression supplied here would run against the text of a document nobody "
                   "in this instance chose, which is the same objection that keeps patterns out "
                   "of classification rules and out of the workflow bindings. An NER backend is "
                   "requirement 1's optional third detector and is not built.")
                  d (string-join DETECTORS ", ")))]
    [(not (= (length ds) (length (remove-duplicates ds)))) "a detector is named twice"]
    [else #f]))

;; The dictionary's terms. LITERAL, so the only limits are size.
(define (terms-problem terms)
  (cond
    [(not (and (list? terms) (andmap string? terms))) "terms must be an array of strings"]
    [(> (length terms) MAX-TERMS) (format "at most ~a terms" MAX-TERMS)]
    [(for/or ([t (in-list terms)]) (string=? (string-trim t) "")) "an empty term"]
    [(for/or ([t (in-list terms)]) (> (string-length t) MAX-TERM-LENGTH))
     (format "a term is longer than ~a characters" MAX-TERM-LENGTH)]
    [else #f]))

;; ---- RED-4: a document that already contains a token is REFUSED ------------------------
;; The token is what the model is asked to reason about and what requirement 2
;; will replace BACK, so a literal `<PERSON_1>` already in the text would make
;; the reply ambiguous between a span this redaction replaced and a string that
;; was always there — and rehydration would then put a real name where no
;; identifier had been. That is the one failure mode of this feature that INVENTS
;; data rather than losing it, so it is refused by name rather than escaped,
;; renumbered or quietly tolerated. A per-redaction nonce in the token was the
;; alternative and it makes every token unreadable to the model, which is the
;; thing the tokens exist to be.
(define TOKEN-RX #px"<[A-Z][A-Z_]*_[0-9]+>")
(define (token-shaped? text) (and (regexp-match? TOKEN-RX text) #t))

;; ---- matching ------------------------------------------------------------------------
;; A dictionary term matches case-insensitively, and WHOLE-WORD when the term is
;; alphabetic — "Lee" must not redact the middle of "Fleet", and a term with a
;; space or a digit in it has no word boundary to speak of.
(define (term-pattern t)
  (define q (regexp-quote t))
  (if (regexp-match? #px"^[A-Za-z]+$" t)
      (pregexp (string-append "(?i:\\b" q "\\b)"))
      (pregexp (string-append "(?i:" q ")"))))

;; every (start end detector value) a detector's patterns find, overlaps and all.
;;
;; THE DICTIONARY'S VALUE IS THE TERM, NOT THE MATCHED TEXT, and that is what
;; makes RED-2 true for it. A term matches case-insensitively, so "Lee" and "LEE"
;; are the same person — keyed on the matched text they would get two tokens, and
;; the model would be shown two people where the caller named one, which is
;; precisely the reasoning the token exists to permit. A pattern detector keys on
;; the matched text, because an email IS its own value.
(define (raw-matches text detectors terms)
  (for*/list ([d (in-list detectors)]
              [spec (in-list (if (string=? d "dictionary")
                                 (for/list ([t (in-list terms)]) (cons (term-pattern t) t))
                                 (for/list ([rx (in-list (hash-ref DETECTOR-PATTERNS d '()))])
                                   (cons rx #f))))]
              [p (in-list (regexp-match-positions* (car spec) text))])
    (list (car p) (cdr p) d (or (cdr spec) (substring text (car p) (cdr p))))))

;; RED-3: OVERLAPS ARE SETTLED BY THE LONGEST MATCH, AND THE TIE BY A FIXED
;; PLATFORM ORDER — never by the order the caller named the detectors, or the same
;; document redacted by two callers who asked for the same work would come back
;; differently. A date inside an account number is the ordinary case: the longer
;; span is the one that was really there.
(define (detector-rank d)
  (or (index-of DETECTORS d) (length DETECTORS)))

(define (accept-matches ms)
  (define sorted
    (sort ms (lambda (a b)
               (cond
                 [(not (= (first a) (first b))) (< (first a) (first b))]
                 [(not (= (- (second a) (first a)) (- (second b) (first b))))
                  (> (- (second a) (first a)) (- (second b) (first b)))]
                 [else (< (detector-rank (third a)) (detector-rank (third b)))]))))
  (let loop ([in sorted] [out '()] [end 0])
    (cond
      [(null? in) (reverse out)]
      [(< (first (car in)) end) (loop (cdr in) out end)]        ; overlaps one already taken
      [else (loop (cdr in) (cons (car in) out) (second (car in)))])))

;; ---- RED-2: the token is stable WITHIN ONE DOCUMENT and nowhere else ------------------
;; The same value gets the same token here, so the model can see that one person
;; appears in three places and reason about it — which is the whole reason the
;; span becomes a token rather than a black box.
;;
;; IT IS DELIBERATELY NOT STABLE ACROSS DOCUMENTS. A token that meant the same
;; person everywhere would be a PSEUDONYM, and a pseudonym is a join key: hand two
;; redacted documents to a model, or to anybody, and they learn the two concern
;; the same person, which is exactly the disclosure this step exists to prevent.
;; The numbering is per class, in order of first appearance, so the output is a
;; function of the document and not of a counter somebody has to keep.
;; -> (values redacted-text map counts)
;;    map is a list of (token . value), in token order
(define (redact text #:detectors [detectors '("email" "phone" "id_number" "date")]
                     #:terms [terms '()])
  (define accepted (accept-matches (raw-matches text detectors terms)))
  ;; value -> token, so a repeated value reuses its token
  (define assigned (make-hash))
  (define counters (make-hash))
  (define counts (make-hash))
  (define (token-for cls value)
    (hash-ref! assigned (cons cls value)
               (lambda ()
                 (define n (add1 (hash-ref counters cls 0)))
                 (hash-set! counters cls n)
                 (format "<~a_~a>" cls n))))
  (define out (open-output-string))
  (define map-acc
    (for/fold ([acc '()] #:result (reverse acc))
              ([m (in-list accepted)] [prev (in-list (cons 0 (map second accepted)))])
      (match-define (list s e d value) m)
      (write-string (substring text prev s) out)
      (define tok (token-for (hash-ref TOKEN-CLASSES d) value))
      (write-string tok out)
      (hash-update! counts d add1 0)
      (if (assoc tok acc) acc (cons (cons tok value) acc))))
  (write-string (substring text (if (null? accepted) 0 (second (last accepted)))) out)
  (values (get-output-string out) map-acc counts))

;; ---- requirement 5: the quality report ------------------------------------------------
;; Counts per detector per document, so a reviewer can spot UNDER-redaction — a
;; letter that plainly names somebody and reports `dictionary: 0` is the case this
;; exists for. EVERY DETECTOR THAT RAN GETS A ROW, including a zero: a detector
;; omitted from the report cannot be told from one that was never asked to run,
;; and those have opposite remedies (add the term, or turn the detector on).
(define (redaction-counts detectors counts)
  (for/hasheq ([d (in-list detectors)])
    (values (string->symbol d) (hash-ref counts d 0))))
