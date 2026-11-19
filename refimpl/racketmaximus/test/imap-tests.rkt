#lang racket/base

;; test/imap-tests.rkt — the IMAP conversation itself.
;;
;; WHY THIS FILE EXISTS. Every other test of the inbound mailbox injects
;; `#:fetch`, `#:uids` and `#:uidvalidity` into `inbound-poll!`, which is the right
;; trade for the dispatch but leaves `domain/mail/imap.rkt` — the half that talks
;; to somebody else's server — exercised nowhere. Three things live only here:
;;
;;   1. WHAT CURL ACTUALLY PRINTS for `-X "UID FETCH n (BODY.PEEK[])"`: the
;;      untagged response line, `* 1 FETCH (BODY[] {101}`, arrives in front of the
;;      literal. `strip-fetch-framing` removes it, and the test asserts the fetched
;;      bytes ARE the message. Left in, that line makes `raw_sha256` change whenever
;;      another message is expunged, which defeats the dedupe the hash exists for.
;;   2. The `n:*` range trap: a start past the largest UID answers the LARGEST, so a
;;      poller that trusted the server would handle a message twice.
;;   3. `STATUS INBOX` on a configured folder reports the wrong mailbox's generation
;;      counter, which would re-sync the poller on every tick.
;;
;; The server is `test/mock-imap.rkt`, which answers RFC 3501 semantics rather than
;; being helpful, because the trap in (2) IS the RFC semantics.
;;
;;   raco test test/imap-tests.rkt

(require rackunit
         racket/string
         "mock-imap.rkt"
         "../domain/mail/imap.rkt")

(define PORT 8993)

(define MSG-1
  (string-append "From: supplier@example.test\r\n"
                 "To: reply+tk_abc@example.test\r\n"
                 "Subject: Re: the label artwork\r\n"
                 "Message-ID: <r1@example.test>\r\n"
                 "\r\n"
                 "Here it is.\r\n"))

(define MSG-2
  (string-append "From: broker@example.test\r\n"
                 "To: bounce+0123@example.test\r\n"
                 "Subject: something else\r\n"
                 "\r\n"
                 "Second.\r\n"))

(define (mbx #:folder [folder "INBOX"] #:password [password "s3cret"])
  (hasheq 'mode "imap" 'host "127.0.0.1" 'port PORT 'security "none"
          'username "tmach" 'password password 'folder folder))

;; Did the client send a line matching `rx`? A `for/or` at each use site is a paren
;; trap, and four of these cases ask this one question.
(define (sent? rx)
  (for/or ([l (in-list (mock-imap-commands!))]) (regexp-match? rx l)))

(define (with-imap thunk)
  (mock-imap-messages! (list MSG-1 MSG-2))
  (mock-imap-uidvalidity! "4242")
  (mock-imap-cleared!)
  (start-mock-imap! #:port PORT)
  (dynamic-wind void thunk (lambda () (stop-mock-imap!))))

;; ---- the generation counter ---------------------------------------------------
(test-case "the generation counter comes from the CONFIGURED folder"
  ;; THE DEFECT: `STATUS INBOX` on a mailbox the operator pointed elsewhere asks a
  ;; different mailbox, so the poller re-syncs on every tick. Asserted on the
  ;; command that crossed the wire, not on the module's intention.
  (with-imap
   (lambda ()
     (check-equal? (imap-uidvalidity (mbx #:folder "Archive")) "4242")
     (check-true (sent? #px"(?i:^[^ ]+ STATUS Archive \\(UIDVALIDITY\\))")
                 "STATUS asked the configured folder"))))

;; ---- searching ----------------------------------------------------------------
(test-case "a mailbox with no UNSEEN answer is an empty list, not an error"
  (with-imap
   (lambda ()
     (mock-imap-unseen! '())
     (check-equal? (imap-unseen-uids (mbx)) '())
     (check-equal? (imap-unseen-uids (mbx)) '()))))

(test-case "the first poll reads UNSEEN, and a position reads from the position"
  (with-imap
   (lambda ()
     (check-equal? (imap-unseen-uids (mbx)) '("1" "2"))
     ;; last UID 0 => `1:*`, which is everything
     (check-equal? (imap-uids-after (mbx) "0") '("1" "2"))
     (check-equal? (imap-uids-after (mbx) "1") '("2"))
     (check-true (sent? #px"(?i:^[^ ]+ UID SEARCH UID 2:\\*)")
                 "the search started at last+1"))))

(test-case "the n:* trap: a start past the largest UID answers the largest, and is dropped"
  ;; THE WHOLE REASON `uids-after-uid` COMPARES AFTER THE FACT. RFC 3501 defines
  ;; `3:*` on a two-message mailbox as 2:3, so the server answers 2 — a message this
  ;; poller has already handled. A poller that trusted the answer would store it
  ;; twice and spend its token twice.
  (with-imap
   (lambda ()
     (check-equal? (imap-uids-after (mbx) "2") '())
     ;; and the pure half, so the semantics are asserted where they live
     (check-equal? (uids-after-uid '("3") 3) '())
     (check-equal? (uids-after-uid '("4" "5") 3) '("4" "5"))
     (check-equal? (uids-after-uid '() 3) '())
     (check-equal? (uids-after-uid '("not-a-uid" "7") 3) '("7")))))

(test-case "a search reply is parsed, including the empty one"
  (check-equal? (parse-search-reply "* SEARCH 1 2 3\r\nA004 OK done\r\n") '("1" "2" "3"))
  (check-equal? (parse-search-reply "* SEARCH\r\nA004 OK done\r\n") '())
  (check-equal? (parse-search-reply "A004 OK done\r\n") '()))

;; ---- fetching -----------------------------------------------------------------
(test-case "a fetch returns the message, and curl's framing is not part of it"
  (with-imap
   (lambda ()
     (define raw (imap-fetch (mbx) "1"))
     (check-equal? raw MSG-1
                   "the fetched bytes must be the message, not the untagged response line")
     (check-false (string-contains? raw "FETCH"))
     (check-false (string-prefix? raw "* "))
     ;; and the two parsers the poller runs on it
     (check-true (regexp-match? #px"(?m:^Subject: Re: the label artwork)" raw))
     (check-true (regexp-match? #px"(?m:^To: reply\\+tk_[0-9a-f]+@)" raw)))))

(test-case "the framing is stripped with or without a UID in the response"
  ;; A server that answers `* 1 FETCH (UID 5 BODY[] {n}` is as ordinary as one that
  ;; answers without it, and the literal length is the LAST `{n}` on the line.
  (check-equal? (strip-fetch-framing "* 1 FETCH (BODY[] {5}\r\nhello") "hello")
  (check-equal? (strip-fetch-framing "* 1 FETCH (UID 9 BODY[] {5}\r\nhello") "hello")
  (check-equal? (strip-fetch-framing "* 7 FETCH (BODY[] {12}\r\nSubject: x\r\n") "Subject: x\r\n")
  ;; no framing at all is left alone rather than mangled
  (check-equal? (strip-fetch-framing "From: a@b.test\r\n\r\nx") "From: a@b.test\r\n\r\nx")
  ;; a literal shorter than its own length is returned whole, not truncated twice
  (check-equal? (strip-fetch-framing "* 1 FETCH (BODY[] {99}\r\nshort") "short"))

;; ---- marking ------------------------------------------------------------------
(test-case "the seen mark is sent, and the mailbox stops reporting the message"
  (with-imap
   (lambda ()
     (imap-mark-seen (mbx) "1")
     (check-true (sent? #px"(?i:^[^ ]+ UID STORE 1 \\+FLAGS)") "the seen mark was sent")
     ;; what an operator's own client would see afterwards
     (check-equal? (imap-unseen-uids (mbx)) '("2")))))

;; ---- the config curl reads ----------------------------------------------------
(test-case "a password with a quote and a backslash crosses intact"
  ;; curl's config format is one directive per line, so an unescaped `"` ends the
  ;; string early. The login line is what proves the escaping produced the value the
  ;; operator typed, because curl unquotes its own escapes before sending.
  (with-imap
   (lambda ()
     (void (imap-unseen-uids (mbx #:password "pa\"ss\\word")))
     (define login (mock-imap-login!))
     (check-true (and login #t) "the client logged in")
     (check-true (string-contains? login "tmach") "the username crossed")
     ;; AND IT CROSSES AS A QUOTED IMAP STRING, with both specials escaped. curl
     ;; quotes a value that needs it and leaves the escapes for the server to
     ;; unquote, so what is asserted here is exactly what the operator typed.
     (check-true (string-contains? login "\"pa\\\"ss\\\\word\"")
                 "the password crossed with its quote and its backslash"))))

(test-case "a server that will not answer is an error, not an empty mailbox"
  ;; The poller's rule is that a FETCH failure stops the poll and leaves the
  ;; position alone; that only holds if this raises rather than answering "".
  (stop-mock-imap!)
  (check-exn exn:fail?
             (lambda () (imap-unseen-uids (mbx)))))
