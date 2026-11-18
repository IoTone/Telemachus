#lang racket/base

;; domain/mail/imap.rkt — reading the inbound mailbox, through `curl`.
;;
;; WHY `curl` AND NOT A LIBRARY. Racket 9.3 ships no IMAP client (`collects/net` has
;; no `imap.rkt`), and `curl` in the closure speaks `imap` and `imaps` — so this is
;; a shell-out rather than a dependency, and the platform already shells out to
;; binaries through `find-executable-path` and `subprocess`. It also adds no daemon:
;; a maildir would need a local delivery agent, which is the option that looks
;; simpler and is not.
;;
;; THE CREDENTIAL NEVER TOUCHES ARGV. `curl -K -` reads its configuration from
;; stdin, so the URL and the `user = "name:password"` line are written to the child
;; rather than to the process table. `ps` is world-readable on most hosts, and a
;; password in argv is a password in `ps`.
;;
;; EVERY VALUE IS QUOTED AND ESCAPED, because curl's configuration format is one
;; directive per line: a password containing a `"` would end the string early and a
;; newline would start a directive of the sender's choosing. The password is the
;; operator's, but "the operator typed it" is not a reason for a parser to accept a
;; second directive.
;;
;; EVERY COMMAND IS BOUNDED IN TIME AND SIZE. A hung IMAP conversation would
;; otherwise hold the reaper seam the poller runs on, and the whole message is
;; fetched into memory, so both need a ceiling rather than a hope.
;;
;; THE UID PAIR IS THE SAFETY OF THE WHOLE THING. `UIDVALIDITY` is the server's
;; statement that the UID space is stable; when it changes, every UID the poller
;; remembers names a different message, so the poller re-syncs from the start of the
;; unseen set rather than trusting its stored position. Reading new mail by UID
;; rather than by the UNSEEN flag is the other half: a person who opens the mailbox
;; in webmail marks mail seen, and a consumer that searched UNSEEN would never see
;; it. Losing that pair is the documented way an IMAP consumer duplicates or
;; silently skips mail.

(require racket/string
         racket/port
         racket/system
         racket/list)

(provide imap-uidvalidity imap-unseen-uids imap-uids-after
         imap-fetch imap-mark-seen imap-command
         ;; exported FOR `test/imap-tests.rkt`: the two parsers are where the
         ;; protocol semantics live, and one of them is the `n:*` trap nothing
         ;; exercised before (#110 r4's rule — an export with a test behind it).
         parse-search-reply uids-after-uid strip-fetch-framing)

(define (curl)
  (or (find-executable-path "curl")
      (error 'imap "curl is not on PATH, so the inbound mailbox cannot be read")))

;; A curl configuration value: double-quoted, with `"` and `\` escaped the way
;; curl's own parser unescapes them.
(define (config-value s)
  (define b (open-output-string))
  (for ([ch (in-string (if (string? s) s ""))])
    (when (or (char=? ch #\") (char=? ch #\\))
      (write-char #\\ b))
    (write-char ch b))
  (string-append "\"" (get-output-string b) "\""))

;; The config `curl -K -` reads. `url` and `user` are the two lines it needs, and
;; the ceilings are the two that make a hostile or broken server survivable:
;; `max-time` bounds the whole command, `max-filesize` refuses to buffer a message
;; larger than the poller will ever store.
(define (config m command)
  (define scheme (if (equal? (hash-ref m 'security) "none") "imap" "imaps"))
  (define port (hash-ref m 'port))
  (define folder (hash-ref m 'folder "INBOX"))
  (string-append
   (format "url = ~a\n"
           (config-value (format "~a://~a:~a/~a" scheme (hash-ref m 'host) port folder)))
   (format "user = ~a\n"
           (config-value (format "~a:~a" (or (hash-ref m 'username #f) "")
                                 (or (hash-ref m 'password #f) ""))))
   "connect-timeout = 10\n"
   "max-time = 60\n"
   "max-filesize = 8388608\n"
   "silent\n"
   (if command (format "request = ~a\n" (config-value command)) "")))

;; -> the child's stdout as a string. `command` is an IMAP command sent with
;; `-X`, or #f for a plain fetch of the URL.
(define (imap-command m command)
  (define-values (proc out in err)
    (subprocess #f #f #f (curl) "-K" "-"))
  (write-string (config m command) in)
  (close-output-port in)
  (define o (port->string out))
  (define e (port->string err))
  (subprocess-wait proc)
  (when (not (equal? (subprocess-status proc) 0))
    (error 'imap "curl could not read the mailbox: ~a" (string-trim e)))
  o)

;; -> the mailbox's UIDVALIDITY as a string, or #f when the server does not say.
;; THE FOLDER IS THE CONFIGURED ONE: `STATUS INBOX` on a mailbox the operator
;; pointed at another folder reports a different mailbox's generation counter, and
;; the poller would re-sync on every tick.
(define (imap-uidvalidity m)
  (define folder (hash-ref m 'folder "INBOX"))
  (define out (imap-command m (format "STATUS ~a (UIDVALIDITY)" folder)))
  (define mm (regexp-match #px"UIDVALIDITY[ \t]+([0-9]+)" out))
  (and mm (cadr mm)))

;; `* SEARCH 1 2 3`, with nothing after it on an empty answer.
(define (parse-search-reply out)
  (define mm (regexp-match #px"\\* SEARCH([ 0-9]*)" out))
  (if (not mm)
      '()
      (filter (lambda (s) (not (string=? s ""))) (string-split (string-trim (cadr mm))))))

(define (imap-search m command)
  (parse-search-reply (imap-command m command)))

;; THE `n:*` TRAP, and the reason the filter is here rather than trusted to the
;; server. RFC 3501 defines a range by its two ENDPOINTS, so `5:*` on a mailbox
;; whose largest UID is 3 means `3:5` and answers 3 — a message that was already
;; handled. Comparing after the fact is what stops the poller handling it twice.
;; A reply that carries something which is not a number is dropped for the same
;; reason: a UID this module cannot order is a UID it must not act on.
(define (uids-after-uid uids last)
  (filter (lambda (s) (and (regexp-match? #px"^[0-9]+$" s) (> (string->number s) last)))
          uids))

;; -> a list of UID strings, oldest first. The FIRST poll of a mailbox uses UNSEEN,
;; because reading an archive the operator did not mean to hand over is not a thing
;; to do on a guess.
(define (imap-unseen-uids m)
  (imap-search m "UID SEARCH UNSEEN"))

;; -> a list of UID strings newer than `uid`, oldest first. `uids-after-uid` is
;; what makes this safe against the range trap above.
(define (imap-uids-after m uid)
  (define numeric? (and (string? uid) (regexp-match? #px"^[0-9]+$" uid)))
  (define last (if numeric? (string->number uid) 0))
  (define from (add1 last))
  (uids-after-uid (imap-search m (format "UID SEARCH UID ~a:*" from)) last))

;; -> the message, with curl's IMAP framing removed. `BODY.PEEK[]` so a message is
;; not marked read before it is handled — the mark happens after the platform has it.
;;
;; CURL'S OUTPUT IS NOT THE MESSAGE. `-X "UID FETCH n (BODY.PEEK[])"` prints the
;; untagged response line before the literal:
;;
;;     * 1 FETCH (BODY[] {101}<CRLF>
;;     From: …<CRLF><CRLF>body
;;
;; so the first line is protocol, not a header. Measured against a mock server
;; (`test/mock-imap.rkt`), not assumed: the trailing `)` and the tagged OK are
;; consumed by curl and do not appear. Left in, that line makes `raw-sha256`
;; depend on the SEQUENCE NUMBER, which changes whenever another message is
;; expunged, so the same message fetched twice hashes differently and the
;; `raw_sha256` dedupe cannot see it — which is the one thing that hash is for.
(define (strip-fetch-framing out)
  ;; `[^\r\n]*` is greedy, so this anchors on the LAST `{n}` on the line: a server
  ;; that answers `* 1 FETCH (UID 5 BODY[] {101}` is as ordinary as one that
  ;; answers without the UID, and the literal length is the last one.
  ;; THE LINE ENDING IS AN ALTERNATION, not `\r?\n`, for a measured reason: a
  ;; `#rx` LITERAL did not match `\r?\n` here while `(\r\n|\n)` does, and the
  ;; mock server is what showed it. `#rx`, NOT `#px` — pregexp rejects `\r` and
  ;; `\n` as "illegal alphabetic escape" (the trap `dsn.rkt` records) — and `^`
  ;; is the string start there without needing `(?m:)`.
  (define m (regexp-match-positions
             #rx"^\\* [0-9]+ FETCH \\([^\r\n]*\\{([0-9]+)\\}(\r\n|\n)"
             out))
  (cond
    [(not m) out]
    [else
     ;; group 0 is the whole line, group 1 is the literal length
     (define n (string->number (substring out (car (cadr m)) (cdr (cadr m)))))
     (define start (cdr (car m)))
     ;; A LITERAL SHORTER THAN ITS OWN LENGTH MEANS THE FETCH WAS CUT, and the
     ;; remainder is the honest answer rather than a truncation nobody sees.
     (substring out start (min (string-length out) (+ start n)))]))

(define (imap-fetch m uid)
  (strip-fetch-framing (imap-command m (format "UID FETCH ~a (BODY.PEEK[])" uid))))

;; Mark it seen, so an operator's own client does not show unread mail the platform
;; has already taken. A message that parsed and then failed to handle is marked seen
;; too: re-reading it every tick would be a loop, and the poller's own note is what
;; an operator acts on.
(define (imap-mark-seen m uid)
  (imap-command m (format "UID STORE ~a +FLAGS (\\Seen)" uid))
  (void))
