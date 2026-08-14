#lang racket/base

;; domain/i18n/icu.rkt — a small ICU-MessageFormat subset (decision LOC-1).
;; Supports: literal text, {name} interpolation, {name, plural, cat {..} …} with
;; `#` = the number, and {name, select, key {..} other {..}}. Sub-messages may
;; themselves contain {name}/# (one level is all we need). Pure + unit-tested.

(require racket/string)

(provide format-message plural-category)

(define (base-lang locale) (car (string-split locale "-")))

;; A pragmatic CLDR-ish subset for our target locales. (Full CLDR plural rules —
;; incl. Spanish `many` — are a later refinement; documented in localization.md.)
(define (plural-category locale n)
  (case (base-lang locale)
    [("ja") "other"]                       ; Japanese: no plural distinction
    [("es") (if (= n 1) "one" "other")]    ; simplified
    [else   (if (= n 1) "one" "other")]))  ; en, nl, de, …

;; format-message : string × (hash symbol→any) × string → string
(define (format-message pat args locale)
  (render pat args locale #f))

;; ---- renderer ---------------------------------------------------------------
;; `num` is the active number for `#` substitution inside a plural sub-message.
(define (render pat args locale num)
  (define n (string-length pat))
  (define out (open-output-string))
  (let loop ([i 0])
    (cond
      [(>= i n) (get-output-string out)]
      [else
       (define c (string-ref pat i))
       (cond
         [(char=? c #\{)
          (define-values (txt j) (parse-arg pat (add1 i) args locale))
          (write-string txt out) (loop j)]
         [(and (char=? c #\#) num) (write-string (number->string num) out) (loop (add1 i))]
         [else (write-char c out) (loop (add1 i))])])))

(define (arg->string v)
  (cond [(or (eq? v 'null) (eq? v #f)) ""] [(string? v) v] [else (format "~a" v)]))

(define (whitespace? c) (char-whitespace? c))
(define (skip-ws pat i)
  (let loop ([i i]) (if (and (< i (string-length pat)) (whitespace? (string-ref pat i))) (loop (add1 i)) i)))

;; read until any char in `stops` (a predicate); return (values token next-index)
(define (read-until pat i stop?)
  (define n (string-length pat))
  (let loop ([j i])
    (if (or (>= j n) (stop? (string-ref pat j)))
        (values (substring pat i j) j)
        (loop (add1 j)))))

;; pat[i..] is just after '{'. Parse: name  |  name , type , options }
(define (parse-arg pat i args locale)
  (define n (string-length pat))
  (define-values (name0 j0) (read-until pat i (lambda (c) (or (char=? c #\,) (char=? c #\})))))
  (define name (string-trim name0))
  (define j (skip-ws pat j0))
  (cond
    [(and (< j n) (char=? (string-ref pat j) #\}))
     (values (arg->string (hash-ref args (string->symbol name) "")) (add1 j))]
    [(and (< j n) (char=? (string-ref pat j) #\,))
     (define-values (type0 k0) (read-until pat (add1 j) (lambda (c) (char=? c #\,))))
     (define type (string-trim type0))
     (define-values (opts end) (parse-options pat (add1 k0)))   ; skip the comma
     (define val (hash-ref args (string->symbol name) ""))
     (cond
       [(string=? type "plural")
        (define num (if (number? val) val (or (string->number (format "~a" val)) 0)))
        (define cat (plural-category locale num))
        (values (render (or (hash-ref opts cat #f) (hash-ref opts "other" "")) args locale num) end)]
       [(string=? type "select")
        (define key (arg->string val))
        (values (render (or (hash-ref opts key #f) (hash-ref opts "other" "")) args locale #f) end)]
       [else (values "" end)])]
    [else (values "" (min n (add1 j)))]))

;; parse `key {submessage} key {submessage} … }` → (values (hash key→inner) end)
(define (parse-options pat i)
  (let loop ([i (skip-ws pat i)] [acc (hash)])
    (cond
      [(>= i (string-length pat)) (values acc i)]
      [(char=? (string-ref pat i) #\}) (values acc (add1 i))]
      [else
       (define-values (key j) (read-until pat i (lambda (c) (or (char=? c #\{) (whitespace? c)))))
       (define k (skip-ws pat j))
       (cond
         [(and (< k (string-length pat)) (char=? (string-ref pat k) #\{))
          (define-values (inner m) (read-balanced pat (add1 k)))
          (loop (skip-ws pat m) (hash-set acc (string-trim key) inner))]
         [else (values acc (add1 k))])])))    ; malformed — bail

;; pat[i..] is just after '{'. Return (values inner index-after-matching-}).
(define (read-balanced pat i)
  (define n (string-length pat))
  (let loop ([j i] [depth 0])
    (cond
      [(>= j n) (values (substring pat i j) j)]
      [(char=? (string-ref pat j) #\{) (loop (add1 j) (add1 depth))]
      [(and (char=? (string-ref pat j) #\}) (= depth 0)) (values (substring pat i j) (add1 j))]
      [(char=? (string-ref pat j) #\}) (loop (add1 j) (sub1 depth))]
      [else (loop (add1 j) depth)])))
