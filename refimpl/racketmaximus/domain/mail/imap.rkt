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
;; THE UID PAIR IS THE SAFETY OF THE WHOLE THING. `UIDVALIDITY` is the server's
;; statement that the UID space is stable; when it changes, every UID the poller
;; remembers names a different message, so the poller re-syncs from the start of the
;; unseen set rather than trusting its stored position. Losing that pair is the
;; documented way an IMAP consumer duplicates or silently skips mail.

(require racket/string
         racket/port
         racket/system
         racket/list)

(provide imap-available? imap-uidvalidity imap-unseen-uids imap-fetch imap-mark-seen
         imap-command)

(define (imap-available?)
  (and (find-executable-path "curl") #t))

(define (curl)
  (or (find-executable-path "curl")
      (error 'imap "curl is not on PATH, so the inbound mailbox cannot be read")))

;; The config `curl -K -` reads. `url` and `user` are the two lines it needs, and
;; the password is quoted the way curl's config parser wants it.
(define (config m command)
  (define scheme (if (equal? (hash-ref m 'security) "none") "imap" "imaps"))
  (define port (hash-ref m 'port))
  (define folder (hash-ref m 'folder "INBOX"))
  (string-append
   (format "url = \"~a://~a:~a/~a\"\n" scheme (hash-ref m 'host) port folder)
   (format "user = \"~a:~a\"\n" (or (hash-ref m 'username #f) "")
           (or (hash-ref m 'password #f) ""))
   "silent\n"
   (if command (format "request = \"~a\"\n" command) "")))

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
(define (imap-uidvalidity m)
  (define out (imap-command m "STATUS INBOX (UIDVALIDITY)"))
  (define mm (regexp-match #px"UIDVALIDITY[ \t]+([0-9]+)" out))
  (and mm (cadr mm)))

;; -> a list of UID strings, oldest first. `UNSEEN` rather than `ALL` because a
;; message the poller has already handled is marked seen, and re-reading the whole
;; mailbox on every tick is how a poller becomes a denial of service on itself.
(define (imap-unseen-uids m)
  (define out (imap-command m "UID SEARCH UNSEEN"))
  (define mm (regexp-match #px"\\* SEARCH([ 0-9]*)" out))
  (if (not mm)
      '()
      (filter (lambda (s) (not (string=? s ""))) (string-split (string-trim (cadr mm))))))

;; -> the raw message for one UID.
(define (imap-fetch m uid)
  (imap-command m (format "UID FETCH ~a (BODY.PEEK[])" uid)))

;; Mark it seen, so the next tick does not read it again. A message that failed to
;; parse is marked seen too: re-reading it every tick would be a loop, and the
;; poller's own error is what an operator acts on.
(define (imap-mark-seen m uid)
  (imap-command m (format "UID STORE ~a +FLAGS (\\Seen)" uid))
  (void))
