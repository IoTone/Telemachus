#lang racket/base

;; test/mock-smtp.rkt — a mail server that records instead of delivering.
;;
;; `test/mock-llm.rkt`'s shape, for `test/mock-llm.rkt`'s reason: the only way to
;; establish that the transport composes a conformant message and reads a reply
;; correctly is to hold a real SMTP conversation with it. Every unit test of this
;; subsystem could script `smtp-deliver!` instead — and that is the right trade
;; for the queue, whose subject is the retry curve — which would leave the wire
;; itself exercised nowhere. #187's lesson: the one defect that existed only on
;; the streaming path survived a year because every test scripted the seam above
;; it.
;;
;; It speaks exactly as much SMTP as Racket's own client needs, which was read out
;; of `net/smtp.rkt` rather than recalled:
;;
;;   220 greeting → EHLO (multi-line 250, the first line DROPPED by the client as
;;   flavour text, so an advertisement must not be first) → optional STARTTLS →
;;   optional AUTH PLAIN (235) → MAIL FROM (250) → RCPT TO (250) → DATA (354) →
;;   the message, a lone "." → 250 → QUIT (221).
;;
;; WHAT IT IS FOR IS THE REFUSALS AS MUCH AS THE HAPPY PATH. `MOCK_SMTP_FAIL`
;; makes it answer a chosen code at a chosen stage, which is how the permanent /
;; transient split (a 5xx recipient refusal against a 4xx deferral) gets a test at
;; all — that split is the whole of this subsystem's retry policy and it is read
;; off a reply code.

(require racket/tcp racket/string racket/port racket/list
         (only-in racket/file make-temporary-file))

(provide start-mock-smtp! stop-mock-smtp! mock-messages mock-clear!
         mock-message-count mock-last-message
         (struct-out mock-msg))

;; `data` is the message AS RECEIVED, header and body, with the dot-stuffing
;; undone — which is what an assertion about a header wants to look at.
(struct mock-msg (from to data auth) #:transparent)

(define *messages* (box '()))
(define *listener* (box #f))
(define *accept* (box #f))

(define (mock-messages) (reverse (unbox *messages*)))
(define (mock-message-count) (length (unbox *messages*)))
(define (mock-last-message) (let ([l (unbox *messages*)]) (and (pair? l) (car l))))
(define (mock-clear!) (set-box! *messages* '()))

;; #:fail — (cons stage code), e.g. `(cons 'rcpt 550)`. The STAGE matters as much
;; as the code: a relay that refuses at RCPT and one that refuses after the dot
;; are both real and the client reaches them through different `check-reply`
;; calls.
;;
;; #:auth — when set, the mock ADVERTISES nothing about auth (the client does not
;; look) and simply records what it was given, so a test can assert that the
;; password really crossed the wire. An expected pair makes it refuse a wrong one.
(define (start-mock-smtp! #:port [port 8925]
                          #:fail [fail #f]
                          #:auth [auth #f]
                          #:starttls? [starttls? #f])
  (define l (tcp-listen port 8 #t "127.0.0.1"))
  (set-box! *listener* l)
  (set-box! *accept*
    (thread
     (lambda ()
       (let loop ()
         (define-values (in out)
           (with-handlers ([(lambda (_) #t) (lambda (_) (values #f #f))]) (tcp-accept l)))
         (when in
           ;; One session per thread, and a session that raises is DROPPED
           ;; silently: a mock that dies on a client disconnect would make every
           ;; later assertion in the file fail for a reason with nothing to do
           ;; with what it was testing.
           (thread (lambda ()
                     (with-handlers ([(lambda (_) #t) (lambda (_) (void))])
                       (serve-session in out fail auth starttls?))
                     (close-ports in out)))
           (loop))))))
  port)

(define (close-ports in out)
  (with-handlers ([(lambda (_) #t) (lambda (_) (void))]) (close-input-port in))
  (with-handlers ([(lambda (_) #t) (lambda (_) (void))]) (close-output-port out)))

(define (stop-mock-smtp!)
  (define t (unbox *accept*))
  (when t (kill-thread t) (set-box! *accept* #f))
  (define l (unbox *listener*))
  (when l
    (with-handlers ([(lambda (_) #t) (lambda (_) (void))]) (tcp-close l))
    (set-box! *listener* #f)))

(define (say out . parts)
  (fprintf out "~a\r\n" (apply string-append parts))
  (flush-output out))

;; The client reads with 'return-linefeed, so every line we send ends CRLF; what
;; it SENDS we read the same way.
(define (recv in) (read-line in 'return-linefeed))

(define (stage-fail fail stage)
  (and fail (eq? (car fail) stage) (cdr fail)))

;; A refusal is a reply code and a line of text, and the TEXT is deliberately
;; chatty: the transport keeps a server's own reply (it is the most useful thing
;; an operator has for a relay that will not answer) and bounds its LENGTH, so a
;; test needs a reply long enough to prove the bound bites.
(define (refuse out code)
  ;; LONGER THAN `MAX-ERROR-CHARS`, deliberately, and a control is why: at 200
  ;; characters the clipping test passed with the clipping REMOVED, because the
  ;; reply was already under the bound. A fixture that cannot reach the limit
  ;; cannot test it. Real relays are this chatty — many echo the message back
  ;; inside a reply, which is the FEED-6 case the bound exists for.
  (say out (number->string code) " refused by the mock: "
       (make-string 600 #\x) " — end"))

(define (serve-session in0 out0 fail auth starttls?)
  (define in in0)
  (define out out0)
  (say out "220 mock.telemachus.test ESMTP ready")
  (define got-auth (box #f))
  (let loop ()
    (define line (recv in))
    (cond
      [(eof-object? line) (void)]
      [(regexp-match? #px"(?i:^EHLO|^HELO)" line)
       ;; THE FIRST LINE IS DROPPED BY THE CLIENT as flavour text, so an
       ;; advertisement placed first is invisible — which is how a STARTTLS test
       ;; fails while the mock is advertising it.
       (say out "250-mock.telemachus.test greets you")
       (when starttls? (say out "250-STARTTLS"))
       (say out "250-AUTH PLAIN LOGIN")
       (say out "250 OK")
       (loop)]
      [(regexp-match? #px"(?i:^STARTTLS)" line)
       (say out "220 go ahead")
       ;; The handshake needs a certificate, so a mock that advertises STARTTLS
       ;; and is asked for it hands the session off to the caller's own encoder.
       ;; Not reached by this file's own cases — see the gap stated in
       ;; mail-tests.rkt.
       (define-values (sin sout) ((mock-tls-encode) in out))
       (set! in sin) (set! out sout)
       (loop)]
      [(regexp-match #px"(?i:^AUTH +PLAIN +)(.*)$" line)
       => (lambda (m)
            (set-box! got-auth (string-trim (cadr m)))
            (cond
              [(stage-fail fail 'auth) => (lambda (c) (refuse out c))]
              [(and auth (not (equal? (string-trim (cadr m)) (expected-plain auth))))
               (say out "535 authentication failed")]
              [else (say out "235 authenticated")])
            (loop))]
      [(regexp-match #px"(?i:^MAIL +FROM:) *<([^>]*)>" line)
       => (lambda (m)
            (cond
              [(stage-fail fail 'from) => (lambda (c) (refuse out c))]
              [else (say out "250 sender ok")
                    (collect in out (cadr m) fail (unbox got-auth))])
            (loop))]
      [(regexp-match? #px"(?i:^QUIT)" line) (say out "221 bye")]
      [(regexp-match? #px"(?i:^RSET|^NOOP)" line) (say out "250 ok") (loop)]
      [else (say out "500 unrecognised") (loop)])))

(define (expected-plain auth)
  (define-values (u p) (values (car auth) (cdr auth)))
  (string-trim
   (bytes->string/utf-8
    (let ()
      (local-require net/base64)
      (base64-encode (string->bytes/latin-1 (format "~a\0~a\0~a" u u p)) #"")))))

(define (collect in out from fail auth)
  (let loop ([tos '()])
    (define line (recv in))
    (cond
      [(eof-object? line) (void)]
      [(regexp-match #px"(?i:^RCPT +TO:) *<([^>]*)>" line)
       => (lambda (m)
            (cond
              [(stage-fail fail 'rcpt) => (lambda (c) (refuse out c) (loop tos))]
              [else (say out "250 recipient ok") (loop (cons (cadr m) tos))]))]
      [(regexp-match? #px"(?i:^DATA)" line)
       (say out "354 end with <CRLF>.<CRLF>")
       (define body (read-dot-terminated in))
       (cond
         [(stage-fail fail 'data) => (lambda (c) (refuse out c))]
         [else
          (set-box! *messages* (cons (mock-msg from (reverse tos) body auth) (unbox *messages*)))
          (say out "250 queued as mock")])]
      [else (say out "503 bad sequence") (loop tos)])))

;; Undoes the dot-stuffing `protect-line` applies, so an assertion sees the
;; message the sender composed rather than the wire form.
(define (read-dot-terminated in)
  (let loop ([acc '()])
    (define line (recv in))
    (cond
      [(eof-object? line) (string-join (reverse acc) "\n")]
      [(string=? line ".") (string-join (reverse acc) "\n")]
      [else (loop (cons (if (and (> (string-length line) 0) (char=? #\. (string-ref line 0)))
                            (substring line 1)
                            line)
                        acc))])))

;; A parameter rather than a require, so this file needs no certificate and no
;; `openssl` to be loaded by a test that never asks for TLS.
(define mock-tls-encode
  (make-parameter
   (lambda (in out) (error 'mock-smtp "this mock was not given a TLS encoder"))))
(provide mock-tls-encode)

;; ---- runnable, for the HTTP smoke ---------------------------------------------
;; A `main` submodule rather than a top-level script, because this file is BOTH a
;; library the unit suite requires and a server the smoke boots:
;; `racket test/mock-smtp.rkt` runs this, `(require "mock-smtp.rkt")` does not.
;; `test/mock-llm.rkt` is a top-level script and could not be both.
;;
;;   MOCK_SMTP_PORT=8928 MOCK_SMTP_OUT=/tmp/mail.txt racket test/mock-smtp.rkt
;;   MOCK_SMTP_FAIL=rcpt:550 … (a stage and a reply code, so the smoke can drive
;;                              the permanent/transient split over HTTP)
;;
;; Each message is APPENDED to `MOCK_SMTP_OUT` between markers, so bash can grep
;; it. A file rather than stdout: the smoke needs to assert on a message AFTER
;; the request that caused it has returned, and reading a live pipe from bash is
;; the kind of thing that makes a suite flap.
(module+ main
  (define port (string->number (or (getenv "MOCK_SMTP_PORT") "8928")))
  (define out-file (getenv "MOCK_SMTP_OUT"))
  (define fail
    (let ([raw (getenv "MOCK_SMTP_FAIL")])
      (and raw (regexp-match #px"^([a-z]+):([0-9]{3})$" raw)
           (let ([m (regexp-match #px"^([a-z]+):([0-9]{3})$" raw)])
             (cons (string->symbol (cadr m)) (string->number (caddr m)))))))
  (start-mock-smtp! #:port port #:fail fail)
  (printf "mock-smtp on 127.0.0.1:~a (out ~a, fail ~a)\n" port (or out-file "-") (or fail "-"))
  (flush-output)
  (let loop ([seen 0])
    (sleep 0.25)
    (define n (mock-message-count))
    (when (and out-file (> n seen))
      (with-handlers ([(lambda (_) #t) (lambda (_) (void))])
        (call-with-output-file out-file #:exists 'append
          (lambda (o)
            (for ([m (in-list (list-tail (mock-messages) seen))])
              (fprintf o "=== MOCK-SMTP MESSAGE to ~a ===\n~a\n=== MOCK-SMTP END ===\n"
                       (string-join (mock-msg-to m) ",") (mock-msg-data m)))))))
    (loop n)))
