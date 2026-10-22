#lang racket/base

;; test/vocabulary-tests.rkt — the closed vocabularies that nothing checked.
;;
;; #110 r4's reverse-direction sweep turned up two constants that are declared,
;; commented as CLOSED, and referenced by nothing at all — not another module,
;; not a test, not even the module that defines them:
;;
;;   • `READ-DOORS`     (domain/audit/reads.rkt)  — the doors a read arrives through
;;   • `QUESTION-TYPES` (domain/judge/wire.rkt)   — the typed-judgment question kinds
;;
;; That is #113's shape: a declaration the server does not keep. Each comment
;; says a value invented in passing "would arrive as something nothing explains",
;; and nothing was stopping one.
;;
;; THESE ARE STATIC CHECKS, NOT RUNTIME VALIDATION, and that is deliberate. A
;; `read-context` is built on the path of every read, so raising there would turn
;; a typo'd door into a 500 on a document download — worse than recording an odd
;; string. Every door in the tree is a platform-supplied LITERAL, so reading the
;; source and comparing is sound, catches the whole class, and cannot break a
;; request. It is the route-permission gate's shape, applied to a vocabulary.
;;
;;   raco test test/vocabulary-tests.rkt

(require rackunit racket/list racket/string racket/path racket/file racket/runtime-path
         (only-in "../domain/audit/reads.rkt" READ-DOORS read-context read-context-via)
         (only-in "../domain/judge/wire.rkt" QUESTION-TYPES judge-noul judge-choice judge-score
                  jobj-pairs))

;; ---- reading the tree as text, from where this file is ----------------------
(define-runtime-path here ".")
(define ROOT (simplify-path (build-path here 'up)))

(define (rkt-under dir)
  (cond
    [(not (directory-exists? dir)) '()]
    [else
     (for/fold ([acc '()]) ([e (in-list (directory-list dir))])
       (define p (build-path dir e))
       (cond [(and (file-exists? p) (regexp-match? #rx"[.]rkt$" (path->string e))) (cons p acc)]
             [(and (directory-exists? p) (not (member (path->string e) '("compiled"))))
              (append (rkt-under p) acc)]
             [else acc]))]))

(define SOURCES
  (append (rkt-under (build-path ROOT "domain"))
          (rkt-under (build-path ROOT "server"))
          (rkt-under (build-path ROOT "test"))
          (rkt-under (build-path ROOT "plugins"))
          (rkt-under (build-path ROOT "cli"))))

;; every door literal in the tree, COMMENT LINES SKIPPED. This file's own prose
;; describes the pattern it scans for, so without that the scan reads its own
;; comment and reports a door nobody uses — the same shape as #110 r3's require
;; analyser counting `'tool` inside a quoted literal.
(define (doors-in-source)
  (remove-duplicates
   (append*
    (for/list ([f (in-list SOURCES)])
      (append*
       (for/list ([ln (in-list (string-split (file->string f) "\n"))]
                  #:unless (regexp-match? #px"^\\s*;" ln))
         (regexp-match* #px"[(]read-context\\s+\"([^\"]+)\"" ln #:match-select cadr)))))))

;; ---- READ-DOORS -------------------------------------------------------------
(test-case "every door the tree actually uses is in READ-DOORS"
  ;; the check that was missing. A door invented in passing would have been
  ;; recorded, grouped on by the #84 export, and explained by nothing.
  (define used (doors-in-source))
  (check-true (> (length used) 3) "the scan found doors at all — a positive control on itself")
  (define unknown (filter (lambda (d) (not (member d READ-DOORS))) used))
  (check-equal? unknown '()
                (format "these doors are used and not declared: ~a — add them to READ-DOORS in domain/audit/reads.rkt, or fix the caller"
                        (string-join unknown ", "))))

(test-case "the DEFAULT door is one of them"
  ;; `current-read-context`'s default is "internal", which is honest: a read from
  ;; a path that set no context is not an API read, and guessing "api" would put
  ;; a false client in the record. It still has to be in the vocabulary.
  (check-true (and (member (read-context-via (read-context "internal" #f #f #f #f #f #f))
                           READ-DOORS) #t))
  (check-true (and (member "internal" READ-DOORS) #t)))

(test-case "READ-DOORS is the list its comment claims, so a change is deliberate"
  ;; pinned rather than derived: the point of a closed vocabulary is that adding
  ;; to it is a decision somebody makes on purpose, and a test that re-derived
  ;; the list from the source would agree with any change whatsoever
  (check-equal? (sort READ-DOORS string<?)
                '("api" "internal" "plugin" "presign" "run" "s3" "worker")))

;; ---- QUESTION-TYPES ---------------------------------------------------------
;; a question is a `jobj` — an ORDERED list of pairs, because key order is part
;; of the question (JUDGE-13) — so the type is read off that, not with hash-ref
(define (type-of q) (cdr (assoc "type" (jobj-pairs q))))
(define (one-of-each)
  (list (judge-noul "is it so?" "yes because" "no because")
        ;; options are (key . description), description #f for one that speaks
        ;; for itself — not a bare list of strings
        (judge-choice "which?" (list (cons "a" "the first") (cons "b" #f)))
        (judge-score "how much?" (list "low" "high"))))

(test-case "each question constructor emits a type QUESTION-TYPES knows"
  ;; the check that was missing: a fourth constructor, or a renamed type, would
  ;; have produced a question `verdict-problem` validates against a list that
  ;; never heard of it
  (for ([q (in-list (one-of-each))])
    (check-true (and (member (type-of q) QUESTION-TYPES) #t)
                (format "~s is produced by a constructor and not in QUESTION-TYPES" (type-of q)))))

(test-case "…and every declared type has a constructor behind it"
  ;; the other direction, which is the half #113 was about: a type in the list
  ;; that nothing can produce is a promise the wire does not keep
  (check-equal? (sort QUESTION-TYPES string<?) (sort (map type-of (one-of-each)) string<?)))
