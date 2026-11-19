#lang racket/base

;; domain/mail/dsn.rkt — what a bounce report says, and nothing else.
;;
;; A DELIVERY STATUS NOTIFICATION IS A MIME MESSAGE whose `message/delivery-status`
;; part carries one per-message block and then one block per recipient (RFC 3464).
;; The part is 7bit by the RFC's own requirement, so there is no transfer decoding
;; to get wrong — which is the one simplification this format gives and the reason
;; this parser is short.
;;
;; WHAT IS READ: `Final-Recipient`, `Action`, `Status` and `Diagnostic-Code` per
;; recipient. `Action` is the field that decides: `failed` is terminal, `delayed` is
;; not, and `delivered`/`relayed`/`expanded` are not failures at all. `Status` is the
;; enhanced code, and its first digit is the same split SMTP uses — 5 is permanent,
;; 4 is temporary.
;;
;; WHAT IS NOT READ: the human-readable first part, the returned original message,
;; and any header the sender supplied. A report is evidence of an attempt, not proof
;; of non-delivery (RFC 3464 records the SMTP race that can produce a failure DSN
;; for a message that was delivered), so the caller treats a suppression as
;; reversible.

(require racket/string
         racket/list)

(provide dsn? dsn-reports dsn-report-recipient dsn-report-action dsn-report-status
         dsn-report-permanent? dsn-report-diagnostic)

;; A report is a `multipart/report` whose `report-type` is `delivery-status`. The
;; check is on the top-level headers only, because that is what the RFC fixes.
(define (dsn? raw)
  (define head (car (regexp-split #rx"\r?\n\r?\n" raw)))
  ;; `(?m:...)` because the header is not the first line of the message.
  (and (regexp-match? #rx"(?i:(?m:^Content-Type:[ \t]*multipart/report))" head)
       (regexp-match? #rx"(?i:report-type[ \t]*=[ \t]*\"?delivery-status)" head)
       #t))

;; -> a list of hashes, one per recipient block. Empty when the message is not a
;; DSN or carries no per-recipient block, which is the honest answer for a report
;; this parser does not understand.
(define (dsn-reports raw)
  (define body (dsn-part raw))
  (if (not body)
      '()
      (for/list ([block (in-list (per-recipient-blocks body))])
        (hasheq 'recipient (field block "Final-Recipient")
                'action (string-downcase (or (field block "Action") ""))
                'status (or (field block "Status") "")
                'diagnostic (field block "Diagnostic-Code")))))

;; The delivery-status part's body: everything after its own header block. The part
;; is found by its `Content-Type`, and the search is over the whole message because
;; a DSN's structure is fixed and a full MIME walk would be a parser for a format
;; this module does not otherwise need.
(define (dsn-part raw)
  (define pat #px"(?i:Content-Type):[ \t]*message/delivery-status[^\r\n]*(?:\r?\n[ \t][^\r\n]*)*\r?\n\r?\n")
  (define m (regexp-match-positions pat raw))
  (and m (substring raw (cdr (car m)) (string-length raw))))

;; The first block is the per-message one (Reporting-MTA and friends); every block
;; after it is a recipient. A block is separated by a blank line.
(define (per-recipient-blocks body)
  ;; A BLOCK THAT STARTS WITH `--` IS A MIME BOUNDARY, not a recipient: the body
  ;; ends with the closing delimiter after a blank line, and counting it would
  ;; report a recipient with no address.
  (define blocks (filter (lambda (b)
                           (define t (string-trim b))
                           (and (not (string=? t "")) (not (string-prefix? t "--"))))
                         (regexp-split #rx"\r?\n\r?\n" body)))
  (cond
    [(null? blocks) '()]
    ;; a report with ONE block has no per-recipient block, which is malformed
    [(null? (cdr blocks)) '()]
    [else (cdr blocks)]))

;; A field's value, unfolded. `Final-Recipient: rfc822; a@b.test` carries an
;; address TYPE before the semicolon, and the address is what a caller wants.
(define (field block name)
  ;; `(?i:...)` and `(?m:...)` are the SCOPED forms; a bare `(?im)` is not a
  ;; pregexp mode sequence and the reader refuses it.
  ;; `regexp`, NOT `pregexp`: Racket's pregexp rejects `\t` and `\r` as "illegal
  ;; alphabetic escape", and PCRE accepts them. The pattern is built at run time
  ;; because the field name is an argument.
  (define m (regexp-match (regexp (format "(?i:(?m:^~a:[ \\t]*(.*(?:\\r?\\n[ \\t]+.*)*)))"
                                          (regexp-quote name)))
                          block))
  (and m
       (let* ([v (string-trim (regexp-replace* #rx"\r?\n[ \t]+" (cadr m) " "))]
              [semi (string-index-of v #\;)])
         (if (and semi (member (string-downcase (string-trim (substring v 0 semi)))
                               '("rfc822" "utf-8" "unknown")))
             (string-trim (substring v (add1 semi) (string-length v)))
             v))))

(define (string-index-of s ch)
  (let loop ([i 0])
    (cond [(>= i (string-length s)) #f]
          [(char=? (string-ref s i) ch) i]
          [else (loop (add1 i))])))

(define (dsn-report-recipient r) (hash-ref r 'recipient #f))
(define (dsn-report-action r) (hash-ref r 'action ""))
(define (dsn-report-status r) (hash-ref r 'status ""))
(define (dsn-report-diagnostic r) (hash-ref r 'diagnostic #f))

;; PERMANENT IS `Action: failed` AND A 5.x.x STATUS, and both halves are asked
;; because either alone is wrong: a `failed` with a 4.x.x status is a report about a
;; temporary condition that the reporting MTA gave up on, and a 5.x.x status with
;; `Action: delayed` is a warning about a message still being retried.
(define (dsn-report-permanent? r)
  (and (equal? (dsn-report-action r) "failed")
       (regexp-match? #rx"^5\\." (dsn-report-status r))
       #t))
