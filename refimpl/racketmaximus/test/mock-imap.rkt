#lang racket/base

;; test/mock-imap.rkt — an IMAP server that answers from memory.
;;
;; `test/mock-smtp.rkt`'s shape and `test/mock-smtp.rkt`'s reason: `domain/mail/imap.rkt`
;; shells out to `curl`, so every unit test of the poller injects `#:fetch` and
;; `#:uids` and the WIRE is exercised nowhere. That is the seam #187 records, and
;; here it hides two things a scripted fetch cannot see at all:
;;
;;   1. WHAT `curl -X "UID FETCH n (BODY.PEEK[])"` ACTUALLY PRINTS. The poller
;;      parses the result as a message, so if curl stamped IMAP framing around the
;;      literal — `* 1 FETCH (BODY[] {123}`, a closing paren, the tagged OK — the
;;      body a person is shown would carry it. That is settled here rather than
;;      assumed.
;;   2. THE CONFIG `curl -K -` READS: a quoted, escaped `user` line, a URL with the
;;      configured folder, and the three ceilings. A password containing a quote is
;;      the one that ends the string early if the escaping is wrong.
;;
;; It speaks exactly as much IMAP as curl needs, and it answers a range the way
;; RFC 3501 says to — `a:*` with `a` past the largest UID answers the LARGEST —
;; because that trap is the whole reason `imap-uids-after` filters after the fact.
;;
;;   * OK greeting
;;   A001 LOGIN user pass                → A001 OK
;;   A002 STATUS INBOX (UIDVALIDITY)     → * STATUS INBOX (UIDVALIDITY <n>)
;;   A003 UID SEARCH UNSEEN              → * SEARCH <uids>
;;   A004 UID SEARCH UID <a>:*           → * SEARCH <uids, RFC semantics>
;;   A005 UID FETCH <n> (BODY.PEEK[])    → * 1 FETCH (BODY[] {<len>} + literal + )
;;   A006 UID STORE <n> +FLAGS (\Seen)   → A006 OK
;;   <anything else>                     → <tag> OK

(require racket/tcp
         racket/string
         racket/port
         racket/list)

(provide start-mock-imap! stop-mock-imap!
         mock-imap-uidvalidity! mock-imap-messages! mock-imap-unseen!
         mock-imap-selected! mock-imap-commands! mock-imap-login!
         mock-imap-fetched! mock-imap-cleared!)

;; The mailbox, as UID → raw message. UIDs start at 1 and are dense, which is what
;; a test wants and what a real server is not.
(define *messages* (box (list)))
(define *unseen* (box (list)))
(define *uidvalidity* (box "1"))
(define *listener* (box #f))
(define *accept* (box #f))
(define *selected* (box '()))
(define *commands* (box '()))
(define *login* (box #f))
(define *fetched* (box '()))

(define (mock-imap-messages! ms)
  (set-box! *messages* ms)
  (set-box! *unseen* (for/list ([_ (in-list ms)] [i (in-naturals 1)]) (number->string i))))
(define (mock-imap-unseen! uids) (set-box! *unseen* uids))
(define (mock-imap-uidvalidity! v) (set-box! *uidvalidity* v))
(define (mock-imap-selected!) (reverse (unbox *selected*)))
;; EVERY LINE the client sent, so a test can assert what the config produced — a
;; folder interpolated into STATUS, a password that crossed with its escapes.
(define (mock-imap-commands!) (reverse (unbox *commands*)))
(define (mock-imap-login!) (unbox *login*))
(define (mock-imap-fetched!) (reverse (unbox *fetched*)))
(define (mock-imap-cleared!)
  (set-box! *selected* '())
  (set-box! *commands* '())
  (set-box! *login* #f)
  (set-box! *fetched* '()))

(define (uid->index uid) (- (string->number uid) 1))

(define (cmd-status out tag _rest)
  (define uv (unbox *uidvalidity*))
  (fprintf out "* STATUS INBOX (UIDVALIDITY ~a)\r\n" uv)
  (fprintf out "~a OK STATUS completed\r\n" tag))

(define (cmd-search out tag rest)
  (define uids (unbox *unseen*))
  (define n (length (unbox *messages*)))
  (define answered
    (cond
      [(regexp-match #px"(?i:^UID SEARCH UID ([0-9]+):\\*$)" rest)
       => (lambda (m)
            (define a (string->number (cadr m)))
            ;; RFC 3501: a range is defined by its endpoints, so `a:*` with `a` past
            ;; the largest answers the largest. This is the trap, reproduced.
            (cond
              [(zero? n) '()]
              [(> a n) (list (number->string n))]
              [else (for/list ([i (in-range a (add1 n))]) (number->string i))]))]
      [(regexp-match #px"(?i:^UID SEARCH UNSEEN$)" rest) uids]
      [(regexp-match #px"(?i:^UID SEARCH ALL$)" rest)
       (for/list ([_ (in-list (unbox *messages*))] [i (in-naturals 1)]) (number->string i))]
      [else '()]))
  (fprintf out "* SEARCH~a\r\n" (if (null? answered) "" (string-append " " (string-join answered " "))))
  (fprintf out "~a OK SEARCH completed\r\n" tag))

(define (cmd-fetch out tag rest)
  (define m (regexp-match #px"^UID FETCH ([0-9]+) " rest))
  (if (not m)
      (fprintf out "~a BAD FETCH needs a UID\r\n" tag)
      (let* ([uid (cadr m)]
             [i (uid->index uid)]
             [msgs (unbox *messages*)])
        (set-box! *fetched* (cons uid (unbox *fetched*)))
        (if (or (< i 0) (>= i (length msgs)))
            (fprintf out "~a OK FETCH completed\r\n" tag)
            (let ([raw (list-ref msgs i)])
              ;; THE LITERAL IS THE MESSAGE, and the closing paren and the tagged OK
              ;; follow it exactly as a real server sends them. What curl does with
              ;; them is the question this mock exists to answer.
              (fprintf out "* 1 FETCH (BODY[] {~a}\r\n" (string-length raw))
              (display raw out)
              (fprintf out ")\r\n~a OK FETCH completed\r\n" tag))))))

(define (cmd-store out tag rest)
  (define m (regexp-match #px"^UID STORE ([0-9]+) \\+FLAGS" rest))
  (when m
    (set-box! *unseen* (remove (cadr m) (unbox *unseen*))))
  (fprintf out "~a OK STORE completed\r\n" tag))

(define (cmd-login out tag rest)
  ;; curl's config makes the argument `"user:pass"`, so the mock sees the pair as
  ;; one token. RECORDED, not checked here: the test asserts on it.
  (set-box! *login* rest)
  (fprintf out "~a OK LOGIN completed\r\n" tag))

(define (handle-port in out)
  (fprintf out "* OK mock-imap ready\r\n")
  (flush-output out)
  (let loop ()
    (define line (read-line in 'any))
    (cond
      [(eof-object? line) (void)]
      [else
       (set-box! *commands* (cons line (unbox *commands*)))
       (define m (regexp-match #px"^([^ ]+) (.*)$" line))
       (cond
         [(not m) (loop)]
         [else
          (define tag (cadr m))
          (define rest (caddr m))
          (define (cmd) (string-upcase (if (string=? rest "") "NOOP" (car (string-split rest " " #:limit 2)))))
          (cond
            [(regexp-match? #px"(?i:^LOGIN )" rest) (set-box! *selected* (cons line (unbox *selected*))) (cmd-login out tag rest)]
            [(regexp-match? #px"(?i:^(SELECT|EXAMINE) )" rest)
             (set-box! *selected* (cons line (unbox *selected*)))
             (fprintf out "* ~a EXISTS\r\n" (length (unbox *messages*)))
             (fprintf out "* OK [UIDVALIDITY ~a] UIDs valid\r\n" (unbox *uidvalidity*))
             (fprintf out "~a OK SELECT completed\r\n" tag)]
            [(regexp-match? #px"(?i:^STATUS )" rest) (cmd-status out tag rest)]
            [(regexp-match? #px"(?i:^UID SEARCH )" rest) (cmd-search out tag rest)]
            [(regexp-match? #px"(?i:^UID FETCH )" rest) (cmd-fetch out tag rest)]
            [(regexp-match? #px"(?i:^UID STORE )" rest) (cmd-store out tag rest)]
            [(regexp-match? #px"(?i:^NOOP)" rest) (fprintf out "~a OK NOOP completed\r\n" tag)]
            [(regexp-match? #px"(?i:^LOGOUT)" rest) (fprintf out "* BYE\r\n~a OK LOGOUT completed\r\n" tag)]
            [(regexp-match? #px"(?i:^CAPABILITY)" rest)
             (fprintf out "* CAPABILITY IMAP4rev1\r\n~a OK CAPABILITY completed\r\n" tag)]
            [else (fprintf out "~a OK ~a completed\r\n" tag (cmd))])
          (flush-output out)
          (loop)])])))

(define (start-mock-imap! #:port [port 8993])
  (define l (tcp-listen port 8 #t))
  (set-box! *listener* l)
  (define (accept-loop)
    (let loop ()
      ;; `stop-mock-imap!` closes the listener while this is blocked in
      ;; `tcp-accept`, and the resulting exception is the STOP, not a failure.
      (define ready
        (with-handlers ([exn:fail? (lambda (_) #f)])
          (define-values (in out) (tcp-accept l))
          (cons in out)))
      (cond
        [(not ready) (void)]
        [else
         (define t (thread (lambda ()
                             (with-handlers ([exn:fail? void])
                               (handle-port (car ready) (cdr ready)))
                             (with-handlers ([exn:fail? void]) (close-input-port (car ready)))
                             (with-handlers ([exn:fail? void]) (close-output-port (cdr ready))))))
         (set-box! *accept* t)
         (loop)])))
  (thread accept-loop)
  (void))

(define (stop-mock-imap!)
  (define l (unbox *listener*))
  (when l (with-handlers ([exn:fail? void]) (tcp-close l)))
  (set-box! *listener* #f)
  (void))
