#lang racket/base

;; cli/telemachus-anchor.rkt — the operator side of issue #66's external anchor.
;;
;;   racket cli/telemachus-anchor.rkt keygen                 # a fresh Ed25519 anchor key
;;   racket cli/telemachus-anchor.rkt pubkey                 # the public key for the configured one
;;   racket cli/telemachus-anchor.rkt status                 # how far the series has got
;;   racket cli/telemachus-anchor.rkt emit                   # take a measurement now
;;   racket cli/telemachus-anchor.rkt export [file]          # receipts as JSONL (- = stdout)
;;   racket cli/telemachus-anchor.rkt verify <file> [--public-key HEX]
;;
;; `verify` IS THE POINT OF THE WHOLE FEATURE, and it is the one subcommand that
;; touches neither the server nor the database (ANCHOR-5). An anchor is worth
;; something precisely when the instance is the suspect, and a verifier that asks
;; the instance whether the instance is honest is not a verifier. So it reads a
;; retained file, offline, and the only other input is the public key an auditor
;; was given out of band.
;;
;; WITHOUT `--public-key` IT REPORTS `self_consistent`, NOT `verified`
;; (ANCHOR-6). A key taken from the file being checked proves nothing — a forger
;; supplies both — so the honest output says which check was skipped rather than
;; implying one that could not happen.
;;
;;   DATABASE_URL=… TELEMACHUS_ANCHOR_KEY=… racket cli/telemachus-anchor.rkt emit

(require racket/string racket/list racket/port json db-kit db-kit/portable
         "../config.rkt"
         (only-in "../domain/authz/signing.rkt"
                  anchor-key-seed ed25519-generate-seed ed25519-public-key bytes->hex)
         (only-in "../domain/audit/anchor.rkt"
                  anchor-emit! anchor-status anchor-export-jsonl anchor-verify-series
                  anchor-public-key-hex))

(define (die msg) (eprintf "~a\n" msg) (exit 2))

;; the same connector the server uses — opened only by the subcommands that need
;; one, so `verify` and `keygen` run on a box with no database at all
;;
;; A MISSING SCHEMA IS A MESSAGE, NOT A STACK TRACE. Pointing this at a fresh data
;; directory is an ordinary mistake — the tables arrive when the server first
;; migrates — and a `query-maybe-row: no such table` backtrace reads as a broken
;; build rather than as "wrong database". The platform's own rule for a refusal a
;; caller can act on (#123), applied to a CLI.
(define (open-db) ((db-connector (database-url) #:base-dir impl-root)))

(define (with-db proc)
  (define conn (open-db))
  (with-handlers ([exn:fail?
                   (lambda (e)
                     (if (regexp-match? #px"(no such table|does not exist|relation .* does not)"
                                        (exn-message e))
                         (die (format (string-append
                                       "this database has no anchor tables, so it has not been migrated by "
                                       "this build.\n  DATABASE_URL=~a\n"
                                       "Start the server once against it, or point DATABASE_URL at the "
                                       "instance's own database.")
                                      ;; REDACTED: a DATABASE_URL carries its
                                      ;; password in the clear, and this prints to
                                      ;; an operator's terminal and into whatever
                                      ;; captures it (#186, SEC-6).
                                      (redact-db-url (database-url))))
                         (raise e)))])
    (proc conn)))

(define (flag args name)
  (let loop ([a args])
    (cond [(or (null? a) (null? (cdr a))) #f]
          [(equal? (car a) name) (cadr a)]
          [else (loop (cdr a))])))

(define (positional args)
  (let loop ([a args] [out '()])
    (cond [(null? a) (reverse out)]
          [(string-prefix? (car a) "--")
           (loop (if (null? (cdr a)) '() (cddr a)) out)]
          [else (loop (cdr a) (cons (car a) out))])))

;; ---- keygen / pubkey ----------------------------------------------------------

(define (cmd-keygen)
  (define seed (ed25519-generate-seed))
  (printf "TMACH_ANCHOR_KEY=~a\n" (bytes->hex seed))
  (printf "public key: ~a\n" (bytes->hex (ed25519-public-key seed)))
  (displayln "")
  (displayln "Keep the first line secret — it signs receipts. Publish the public key:")
  (displayln "whoever retains your receipts verifies them with it, and cannot forge one.")
  (displayln "Rotating it starts a NEW series; keep the old public key to verify old receipts."))

(define (cmd-pubkey)
  (define pk (anchor-public-key-hex))
  (unless pk (die "no TMACH_ANCHOR_KEY is configured"))
  (displayln pk))

;; ---- status / emit / export ---------------------------------------------------

(define (cmd-status)
  (with-db (lambda (conn)
  (define st (anchor-status conn))
  (printf "anchoring:   ~a\n" (if (hash-ref st 'enabled) "on" "OFF (no TMACH_ANCHOR_KEY)"))
  (printf "public key:  ~a\n" (hash-ref st 'public_key))
  (printf "instance:    ~a\n" (hash-ref st 'instance_id))
  (printf "receipts:    ~a\n" (hash-ref st 'receipts))
  (printf "latest seq:  ~a\n" (hash-ref st 'latest_seq))
  (printf "latest hash: ~a\n" (hash-ref st 'latest_hash))
  (displayln "")
  (displayln "This says what was EMITTED. It cannot say what was RETAINED — and the")
  (displayln "retained copy is the anchor. Check your copy with `verify`."))))

(define (cmd-emit)
  (unless (anchor-key-seed) (die "no TMACH_ANCHOR_KEY is configured — run `keygen` first"))
  (with-db (lambda (conn)
    (define r (anchor-emit! conn))
    (printf "receipt ~a emitted, covering ~a chain(s)\n" (hash-ref r 'seq) (hash-ref r 'chains))
    (printf "hash: ~a\n" (hash-ref r 'hash))
    (displayln "Retain it somewhere this instance's operator does not control."))))

(define (cmd-export args)
  (with-db (lambda (conn)
  (define dest (let ([p (positional args)]) (if (null? p) "-" (car p))))
  (define since (let ([s (flag args "--since-seq")]) (and s (string->number s))))
  (define (go out) (anchor-export-jsonl conn out #:since-seq since))
  (define n (if (equal? dest "-")
                (go (current-output-port))
                (call-with-output-file dest #:exists 'truncate (lambda (out) (go out)))))
  (eprintf "~a receipt(s) exported~a\n" n (if (equal? dest "-") "" (format " to ~a" dest))))))

;; ---- verify (no database, no server) -------------------------------------------

(define (read-receipts path)
  (define lines
    (if (equal? path "-")
        (port->lines (current-input-port))
        (begin (unless (file-exists? path) (die (format "no such file: ~a" path)))
               (file->lines path))))
  (for/list ([l (in-list lines)]
             #:unless (string=? (string-trim l) ""))
    (with-handlers ([exn:fail? (lambda (_) (die (format "not JSONL: ~a" (substring l 0 (min 60 (string-length l))))))])
      (string->jsexpr l))))

(define (file->lines path)
  (call-with-input-file path port->lines))

(define (cmd-verify args)
  (define p (positional args))
  (when (null? p) (die "usage: verify <file.jsonl|-> [--public-key HEX]"))
  (define expected (flag args "--public-key"))
  (define receipts (read-receipts (car p)))
  ;; sorted by seq so a retainer who concatenated two exports out of order gets a
  ;; verdict about their chain rather than a complaint about their file
  (define sorted (sort receipts < #:key (lambda (r) (let ([s (hash-ref r 'seq 0)])
                                                      (if (exact-integer? s) s 0)))))
  (define v (anchor-verify-series sorted #:public-key expected))
  (printf "receipts:        ~a\n" (length sorted))
  (printf "checked:         ~a\n" (hash-ref v 'checked))
  (printf "instance:        ~a\n" (hash-ref v 'instance_id))
  (printf "signed by:       ~a\n" (hash-ref v 'signed_by))
  (printf "sequence:        ~a..~a\n" (hash-ref v 'first_seq 'null) (hash-ref v 'last_seq 'null))
  (printf "self-consistent: ~a\n" (if (hash-ref v 'self_consistent) "yes" "NO"))
  (printf "reaches origin:  ~a\n" (if (hash-ref v 'complete #f) "yes" "NO — see the note below"))
  (printf "signature:       ~a\n"
          ;; "no receipts" is a property of the FILE, asked of `sorted` — not of
          ;; `checked`, which is also 0 when the walk failed at the very first
          ;; receipt. Reading it off the walk reported "this file contains no
          ;; receipts" for a file with two in it, one of them signed by the wrong
          ;; key, which is the most misleading thing this tool could say.
          (cond [(null? sorted)
                 "nothing to verify — this file contains no receipts"]
                [(hash-ref v 'verified) "VERIFIED against the key you supplied"]
                [expected "FAILED against the key you supplied"]
                [else "not verified — no --public-key given, so only the key the file carries was used"]))
  (unless (hash-ref v 'ok)
    (printf "\nPROBLEM at receipt ~a:\n  ~a\n" (hash-ref v 'broken_at) (hash-ref v 'problem)))
  (when (and (hash-ref v 'ok) (not expected))
    (displayln "")
    (displayln "This file agrees with itself, which a forger could also arrange. Re-run with")
    (displayln "--public-key <the key you were given out of band> for a check that means something."))
  (when (and (hash-ref v 'note #f) (not (eq? (hash-ref v 'note) 'null)))
    (printf "\nnote: ~a\n" (hash-ref v 'note)))
  ;; An EMPTY file exits non-zero even though the library calls it `ok`. The two
  ;; are answering different questions: `anchor-verify-series` is asked "is this
  ;; series internally sound", for which a series of nothing vacuously is, while
  ;; this command is asked "is my retained copy good" — and for an empty file the
  ;; answer a cron job must get is no. Exiting 0 there would be a monitor that
  ;; reports success for retaining nothing at all.
  (exit (cond [(not (hash-ref v 'ok)) 1]
              [(null? sorted) 1]
              [else 0])))

;; ---- dispatch ------------------------------------------------------------------

(define (main argv)
  (define args (vector->list argv))
  (define cmd (if (null? args) "help" (car args)))
  (define rest (if (null? args) '() (cdr args)))
  (case cmd
    [("keygen") (cmd-keygen)]
    [("pubkey") (cmd-pubkey)]
    [("status") (cmd-status)]
    [("emit") (cmd-emit)]
    [("export") (cmd-export rest)]
    [("verify") (cmd-verify rest)]
    [else
     (displayln "usage: telemachus-anchor <keygen|pubkey|status|emit|export|verify>")
     (displayln "")
     (displayln "  keygen                      a fresh Ed25519 anchor key")
     (displayln "  pubkey                      the public key for TMACH_ANCHOR_KEY")
     (displayln "  status                      how far the receipt series has got (needs the database)")
     (displayln "  emit                        take a measurement of both chains now")
     (displayln "  export [file|-]             receipts as JSONL  [--since-seq N]")
     (displayln "  verify <file|-> [--public-key HEX]")
     (displayln "                              check a RETAINED series offline")
     (exit (if (equal? cmd "help") 0 2))]))

(module+ main (main (current-command-line-arguments)))
