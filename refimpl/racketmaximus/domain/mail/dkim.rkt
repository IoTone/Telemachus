#lang racket/base

;; domain/mail/dkim.rkt — the signature that makes DMARC alignment possible.
;;
;; WHY IT IS HERE AT ALL. DMARC requires alignment: the domain the recipient sees
;; in `From` must be the domain that authenticated. SPF authenticates the ENVELOPE
;; sender, and an external message's envelope sender is the VERP bounce address, so
;; SPF alone cannot carry DMARC for it. DKIM signs the message and names the
;; signing domain in `d=`, so a signature with `d=<the From domain>` aligns
;; whatever the envelope says. Without it, a message from a domain with a DMARC
;; record is the one that lands in spam or is refused outright.
;;
;; RELAXED/RELAXED, and that is the choice that survives a relay. Relaxed header
;; canonicalization lowercases the field name, unfolds continuation lines and
;; collapses internal whitespace, so a relay that rewraps a header does not break
;; the signature; relaxed body canonicalization collapses whitespace and drops
;; trailing empty lines, so a relay that re-encodes line endings does not either.
;; Simple/simple is stricter and breaks on the first hop that touches anything.
;;
;; THE SIGNING IS `openssl dgst -sha256 -sign`, not a Racket RSA implementation.
;; `openssl` is already a dependency and already shelled out to for the
;; self-signed certificate, and a hand-rolled RSA-PKCS#1 v1.5 is exactly the kind
;; of code that is subtly wrong in a way no test notices. The key is written to a
;; 0600 file inside a private temporary directory, used, and removed in the same
;; call — the window is the length of one `openssl` invocation, and the alternative
;; (a key on disk for the life of the process) is worse.
;;
;; WHAT THIS DOES NOT DO: it does not publish the DNS record, and it does not
;; rotate the key. The record is `<selector>._domainkey.<domain>` with
;; `v=DKIM1; k=rsa; p=<base64 of the public key>`, and it is the deploy's job; the
;; rotation is `telemachus-secrets rewrap` plus a new selector.

(require racket/string
         racket/list
         racket/port
         racket/file
         racket/system
         net/base64
         sha2-kit
         json
         (only-in "../i18n/i18n.rkt" no-i18n))

(provide dkim-configured? dkim-public-record
         dkim-body-hash dkim-signing-input dkim-sign-header
         dkim-relaxed-header dkim-relaxed-body dkim-parse-headers)

;; The headers a signature covers. `from` is mandatory; the rest are the ones a
;; reader sees and a relay is most likely to touch, and covering them is what makes
;; a tampered subject or recipient detectable.
(define SIGNED-HEADERS '(from to subject date message-id))

;; ---- canonicalization ---------------------------------------------------------
;; Relaxed header: lowercase the name, unfold, collapse internal whitespace, strip
;; trailing whitespace. The value is everything after the first colon.
(define (relaxed-value v)
  ;; RFC 6376 3.4.2: unfold, collapse every run of whitespace to one space, then
  ;; DELETE the whitespace before and after the colon — so the leading space of a
  ;; header value is not part of the canonical form.
  (define unfolded (regexp-replace* #rx"\r?\n[ \t]+" v (no-i18n " ")))
  (define collapsed (regexp-replace* #rx"[ \t]+" unfolded (no-i18n " ")))
  (regexp-replace #rx"^[ \t]+" (regexp-replace #rx"[ \t]+$" collapsed (no-i18n "")) (no-i18n "")))

(define (dkim-relaxed-header name value)
  (string-append (string-downcase name) (no-i18n ":") (relaxed-value value)))

;; Relaxed body: collapse whitespace within a line, strip trailing whitespace, drop
;; trailing empty lines, and end with exactly one CRLF. An empty body hashes as the
;; empty string, which is the one case the trailing CRLF is not added to.
(define (dkim-relaxed-body lines)
  (define cleaned
    (for/list ([l (in-list lines)])
      (regexp-replace #rx"[ \t]+$" (regexp-replace* #rx"[ \t]+" l (no-i18n " ")) (no-i18n ""))))
  (define trimmed
    (let loop ([ls (reverse cleaned)])
      (cond [(null? ls) '()]
            [(string=? (car ls) (no-i18n "")) (loop (cdr ls))]
            [else (reverse ls)])))
  (cond
    [(null? trimmed) (no-i18n "")]
    [else (string-append (string-join trimmed (no-i18n "\r\n")) (no-i18n "\r\n"))]))

;; The body hash is base64(sha256(canonical body)), and it is what a receiver
;; compares against the body it actually got.
(define (dkim-body-hash lines)
  (bytes->string/utf-8
   (base64-encode (sha256 (string->bytes/utf-8 (dkim-relaxed-body lines))) (no-i18n ""))))

;; ---- the header block ---------------------------------------------------------
;; -> a list of (name . value) in the order they appear. A header this module
;; cannot parse is a header it will not sign, so the caller gets an error rather
;; than a signature over something else.
(define (dkim-parse-headers hdr)
  (define lines (string-split hdr "\r\n"))
  (define-values (acc cur)
    (for/fold ([acc '()] [cur #f]) ([l (in-list lines)])
    (cond
      [(string=? l (no-i18n "")) (values acc cur)]
      ;; a continuation line belongs to the previous header
      [(and (positive? (string-length l)) (member (substring l 0 1) '(" " "\t")))
       (values acc (and cur (cons (car cur) (string-append (cdr cur) "\r\n" l))))]
      [else
       (define i (string-index-of l #\:))
       (define acc* (if cur (cons cur acc) acc))
       (if (not i)
           (values acc* #f)
           (values acc* (cons (string-downcase (substring l 0 i))
                              (substring l (add1 i) (string-length l)))))])))
  ;; `acc` is built by consing, so it is reversed; the order matters because the
  ;; signing input lists the covered headers in the order `h=` names them.
  (reverse (if cur (cons cur acc) acc)))

;; Racket has no `string-index`; the first colon is what separates a field name
;; from its value, and a header with none is not a header.
(define (string-index-of s ch)
  (let loop ([i 0])
    (cond [(>= i (string-length s)) #f]
          [(char=? (string-ref s i) ch) i]
          [else (loop (add1 i))])))

(define (header-value hs name)
  (define p (assoc name hs))
  (and p (cdr p)))

;; ---- the signing input --------------------------------------------------------
;; The bytes that are signed: each covered header canonicalized and CRLF-terminated,
;; then the DKIM-Signature header itself with `b=` empty and NO trailing CRLF. A
;; verifier recomputes exactly this, which is why it is exported: the test signs and
;; then verifies with `openssl`, and the two halves have to agree byte for byte.
(define (dkim-signing-input hdr body-lines domain selector)
  (define hs (dkim-parse-headers hdr))
  (define missing (for/list ([n (in-list SIGNED-HEADERS)] #:unless (header-value hs (symbol->string n))) n))
  (when (pair? missing)
    (error 'dkim "the message has no ~a header, so it cannot be signed"
           (string-join (map symbol->string missing) ", ")))
  (define bh (dkim-body-hash body-lines))
  (define unsigned
    (format (no-i18n "v=1; a=rsa-sha256; c=relaxed/relaxed; d=~a; s=~a; h=~a; bh=~a; b=")
            domain selector
            (string-join (map symbol->string SIGNED-HEADERS) (no-i18n ":"))
            bh))
  (values
   (string-append
    (apply string-append
           (for/list ([n (in-list SIGNED-HEADERS)])
             (string-append (dkim-relaxed-header (symbol->string n)
                                                 (header-value hs (symbol->string n)))
                            (no-i18n "\r\n"))))
    (dkim-relaxed-header (no-i18n "DKIM-Signature") unsigned))
   unsigned))

;; ---- the signature ------------------------------------------------------------
(define (rsa-sha256-sign pem input)
  (define openssl (or (find-executable-path "openssl")
                      (error 'dkim "openssl is not on PATH, so a message cannot be signed")))
  (define dir (make-temporary-file "tmach-dkim-~a" 'directory))
  (define key (build-path dir (no-i18n "k.pem")))
  (dynamic-wind
    void
    (lambda ()
      (call-with-output-file key #:exists 'replace
        (lambda (o) (write-bytes (string->bytes/utf-8 pem) o)))
      (file-or-directory-permissions key #o600)
      (define-values (proc out in err)
        (subprocess #f #f #f openssl (no-i18n "dgst") (no-i18n "-sha256")
                    (no-i18n "-sign") (path->string key)))
      (write-bytes (string->bytes/utf-8 input) in)
      (close-output-port in)
      ;; READ BEFORE WAITING: a full pipe would deadlock the child, and the
      ;; signature is small enough that this is the whole output.
      (define sig (port->bytes out))
      (define errs (port->string err))
      (subprocess-wait proc)
      (when (not (equal? (subprocess-status proc) 0))
        (error 'dkim "openssl could not sign: ~a" (string-trim errs)))
      sig)
    (lambda () (with-handlers ([exn:fail? void]) (delete-directory/files dir #:must-exist? #f)))))

;; -> the DKIM-Signature VALUE, ready for `(insert-field "DKIM-Signature" v hdr)`.
;; The value and not the whole line, because `insert-field` is the one place a
;; header is composed and a second spelling of "Name: value" is a second rule.
(define (dkim-sign-header hdr body-lines #:domain domain #:selector selector #:key pem)
  (define-values (input unsigned) (dkim-signing-input hdr body-lines domain selector))
  (define sig (bytes->string/utf-8 (base64-encode (rsa-sha256-sign pem input) (no-i18n ""))))
  (string-append unsigned sig))

;; ---- what the deploy publishes ------------------------------------------------
;; The DNS record for the selector, from the private key. `openssl rsa -pubout`
;; gives the PEM; the record wants the base64 body of that PEM with the armour
;; removed, which is what this returns.
(define (dkim-public-record pem #:selector selector #:domain domain)
  (define openssl (or (find-executable-path "openssl")
                      (error 'dkim "openssl is not on PATH")))
  (define dir (make-temporary-file "tmach-dkim-pub-~a" 'directory))
  (define key (build-path dir (no-i18n "k.pem")))
  (dynamic-wind
    void
    (lambda ()
      (call-with-output-file key #:exists 'replace
        (lambda (o) (write-bytes (string->bytes/utf-8 pem) o)))
      (file-or-directory-permissions key #o600)
      (define-values (proc out in err)
        (subprocess #f #f #f openssl (no-i18n "rsa") (no-i18n "-in") (path->string key)
                    (no-i18n "-pubout")))
      (close-output-port in)
      (define pub (port->string out))
      (define errs (port->string err))
      (subprocess-wait proc)
      (when (not (equal? (subprocess-status proc) 0))
        (error 'dkim "openssl could not read the key: ~a" (string-trim errs)))
      (define body
        (string-join (for/list ([l (in-list (string-split pub "\n"))]
                                #:unless (or (string=? l (no-i18n ""))
                                             (string-prefix? l (no-i18n "-----"))))
                       l)
                     (no-i18n "")))
      (format (no-i18n "~a._domainkey.~a. IN TXT \"v=DKIM1; k=rsa; p=~a\"") selector domain body))
    (lambda () (with-handlers ([exn:fail? void]) (delete-directory/files dir #:must-exist? #f)))))

;; "Is there a key and a selector?" — the two things a signature needs. The domain
;; defaults to the From address's domain, which is the only domain the instance may
;; honestly claim.
(define (dkim-configured? t)
  (and t
       (let ([s (hash-ref t 'dkim_selector #f)] [k (hash-ref t 'dkim_key #f)])
         (and (string? s) (not (string=? s (no-i18n "")))
              (string? k) (not (string=? k (no-i18n "")))
              #t))))
