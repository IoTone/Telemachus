#lang racket/base

;; domain/mail/transport.rkt — how a message leaves this instance.
;;
;; The operator's half of email, and nothing else: the configuration row, the
;; SMTP conversation, and the probe that proves both. It is deliberately free of
;; the queue and of any notion of WHO a message is for — `mail.rkt` owns that, so
;; this module can be driven by a test with a host, a port and a sink listening
;; on a socket.
;;
;; WHY `net/smtp` AND NOT A VENDOR API (MAIL-1). It is in BASE RACKET, with
;; `#:auth-user`, `#:auth-passwd`, `#:port-no`, `#:tcp-connect` for implicit TLS
;; and `#:tls-encode` for STARTTLS — so the transport is no new dependency and no
;; change to the Nix closure, which for a self-hosted, air-gapped-capable platform
;; is the whole argument: SMTP is what an instance can point at its own Postfix.
;; A vendor HTTP API (SES, Postmark, SendGrid) is somebody else's credential and
;; somebody else's wire, and it is exactly what a plugin should ship — which the
;; slice-3 notification API makes possible without any of it being core.
;;
;; THE CREDENTIAL IS SEALED IN A CORE TABLE, AND THAT IS THE ONE PLACE THIS
;; DIVERGES FROM MATRIX (MAIL-2). MTX-3 put the Matrix bot's token in the
;; ENVIRONMENT because a PLUGIN cannot own a sealed column — FEED-5 recorded that
;; gap deliberately, since a plugin-owned sealed column is absent from
;; `CREDENTIAL-SECRETS` and is therefore silently unrotatable. This is core, so it
;; can own one, and the requirement is that an ADMIN configures it: a row means no
;; restart and no shell on the box. `email_transport.password` is in
;; `CREDENTIAL-SECRETS` in the same commit as its `CREATE TABLE`.
;;
;; A TEAM CONFIGURES NOTHING HERE (MAIL-3). A team-chosen SMTP host is an SSRF
;; primitive, and `from_address` is the INSTANCE's own identity — a team able to
;; set it could send mail as the instance. One row, `instance:manage`, and no
;; `team_id` column to tempt anybody.
;;
;; #142's EGRESS GATE IS NOT ON THIS PATH, AND THAT IS NOT AN OMISSION.
;; `smtp-send-message` opens its own socket, so `fetch.rkt` — and with it EGR-1…3
;; — never sees this call. FEED-4's rule is that the policy attaches to WHO CHOSE
;; THE ADDRESS: this one is the operator's, the same trust as `TMACH_MODEL_URL` or
;; `executors.json`, and MAIL-3 is what keeps it that way. An operator pointing
;; this at `127.0.0.1:25` is the ordinary single-box deployment, not an attack.

(require (only-in "../net/remote-detail.rkt" printable-text clip-text))

(require db-kit/portable
         racket/string
         racket/list
         racket/port
         racket/tcp
         net/smtp
         net/head
         net/base64
         openssl
         (only-in "../authz/sealed.rkt" define-sealed-column)
         "../db/nulls.rkt")

(provide SECURITY-MODES TRANSPORT-ID SMTP-TIMEOUT
         transport-ref transport-configured? transport-set! transport-clear!
         transport-problem transport-record-test!
         transport-from-header transport-base-url transport-password printable clip
         smtp-deliver! mail-address-problem valid-address?
         encode-subject encode-body
         ;; exported FOR the tests: the header composition and the deadline are
         ;; the two halves worth asserting without a mail server, and an export
         ;; with a test behind it is not an over-wide export (#110 r4).
         compose-message call-with-deadline exn:fail:mail? exn:fail:mail-permanent?)

;; #19's seam. `#:credential`, NOT the content gate: ENC-23 found a live defect
;; where #85's `webhooks.secret` was declared through this macro's default seal,
;; which is conditional on `TMACH_ENCRYPT_CONTENT` — so on the DOCUMENTED default
;; the signing secret was written in the clear while the module comment said
;; otherwise. An SMTP password is a replayable credential; it seals whenever a key
;; is configured.
(define-sealed-column "email_transport.password" (seal-password unseal-password) (id) #:credential)

;; A CLOSED vocabulary, like `WORKER-STATES` and `ANNOTATION-KINDS`. The mode is
;; STORED rather than inferred from the port, because 587-with-implicit-TLS and
;; 465-with-STARTTLS both exist in the wild and guessing wrong fails as a hang or
;; as a protocol error nobody can read.
(define SECURITY-MODES '("none" "starttls" "tls"))

;; One row, and the id is the literal so there can only ever be one: the `From`
;; address is the instance's identity and a second row would be a second identity
;; with no rule saying which answers.
(define TRANSPORT-ID "default")

;; Connecting, the handshake, AUTH and the whole DATA phase. Generous next to a
;; webhook's ten seconds, because a mail server legitimately greets slowly and
;; some of them impose a deliberate pause on connect (a cheap greylisting trick) —
;; but bounded, because this runs on the pool's reaper seam and a hung socket
;; would otherwise hold a tick for ever.
(define SMTP-TIMEOUT 30)

(define (now) (current-seconds))

;; ---- the failure vocabulary ---------------------------------------------------
;; `permanent?` is the whole reason this is a struct rather than an `error`. A
;; refused recipient will be refused identically in eight hours, so retrying it
;; ten times is ten identical refusals and a dead letter that took a day to admit
;; it; a connection failure or a 4xx deferral is exactly what a retry is for. The
;; same split `llm.rkt` makes for a model call, and PULL-14's lesson about not
;; sending a genuinely bad request round the fleet.
(struct exn:fail:mail exn:fail (permanent?) #:transparent)

(define (mail-error! permanent? fmt . args)
  (raise (exn:fail:mail (apply format fmt args) (current-continuation-marks) permanent?)))

;; ---- addresses ----------------------------------------------------------------
;; DELIBERATELY NOT RFC 5322. A conforming address grammar admits quoted local
;; parts, comments and bracketed literals, and this platform has nothing that
;; would do anything useful with one — what it needs is to refuse a string that
;; cannot be delivered and, above all, to refuse one that could inject a header.
;; `antispam.rkt`'s `valid-email?` is the prospect funnel's rule and is
;; deliberately NOT reused: it is a heuristic for scoring a lead, and a validator
;; whose failure here is a header injection should not be shared with one whose
;; failure there is a slightly wrong score.
(define (valid-address? a)
  (and (string? a)
       (<= (string-length a) 254)
       ;; A CR or LF anywhere is refused OUTRIGHT and is the reason this function
       ;; exists: the address is interpolated into a header, so a newline in it
       ;; appends headers of the attacker's choosing — a Bcc, a different From.
       ;; The pattern below cannot match one, and the explicit test is here so
       ;; that a future loosening of the pattern cannot quietly open it.
       (not (regexp-match? #px"[\r\n\0]" a))
       (regexp-match? #px"^[^@\\s,<>\"]+@[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?\\.[A-Za-z]{2,}$" a)
       #t))

(define (mail-address-problem a)
  (cond
    [(not (string? a)) "an address must be a string"]
    [(string=? (string-trim a) "") "an address must not be empty"]
    [(not (valid-address? a)) "that does not look like an email address"]
    [else #f]))

;; A REFUSAL ABOUT AN ADDRESS MUST NOT ECHO ITS CONTROL CHARACTERS, and running
;; the thing is what found it: the first version of `smtp-deliver!` formatted the
;; rejected address straight into its message, so the ONE input this module
;; refuses for containing a CRLF put that CRLF into `email_deliveries.last_error`
;; and into the container log — forging log lines, which is the same primitive
;; with a different reader. SEC-6's line: the host and the database survive, the
;; credential does not; here the address survives, legibly, and its control
;; characters do not.
;;
;; IT STRIPS AND DOES NOT TRUNCATE, and a control is why. Its first version also
;; cut at 200 characters, which made `mail.rkt`'s own 400-character bound on a
;; relay's reply UNREACHABLE — two bounds with the tighter one first, so removing
;; the looser one changed no test. #110 r1's redundant guard, and the right fix
;; is not to delete either: the two answer different questions. "No forged log
;; lines" is a property every message wants; HOW MUCH of a value to keep is a
;; decision with a different number per caller, because 200 characters of a
;; relay's reply routinely cuts off the part that says why.
(define printable printable-text)

;; Bound a value for a message, saying that it was cut. A sentence that merely
;; stops is one a reader does not trust (SEC-8's rule for `provider-detail`).
;; SEC-12: BOTH BODIES MOVED to `domain/net/remote-detail.rkt`, which is now the
;; one home for "somebody else's server's own words, made safe to put in a
;; message that outliving the call makes a copy of". The names stay, because
;; `addresses.rkt` and `server/api/mail.rkt` import `printable` from here and
;; SMTP is the vocabulary they are reading. The pair in this file was the RIGHT
;; one of the four spellings — `provider-detail` had the cap and not the
;; control-character strip — so what moved is the answer, not a compromise
;; between them. The suffix is the model seam's "… (truncated)" now rather than
;; " … (cut)": one wording, and a dead-letter list that says the same thing
;; whichever subsystem filled it.
(define (clip s n) (clip-text s n))

;; ---- the configuration row ----------------------------------------------------
(define COLS (string-append "id, host, port, security, username, password, from_address, from_name, "
                            "base_url, active, last_test_epoch, last_test_ok, last_test_error, "
                            "updated_by, updated_epoch"))

;; THE PASSWORD IS NEVER IN A READ. `transport-ref` answers `has_password` and
;; nothing else — #19's rule for a token, and `webhook-list`'s. An operator who
;; needs to change it types a new one; one who does not, does not send the field.
(define (row->transport r)
  (hasheq 'host (vector-ref r 1)
          'port (vector-ref r 2)
          'security (vector-ref r 3)
          'username (nz (vector-ref r 4))
          'has_password (not (sql-null? (vector-ref r 5)))
          'from_address (vector-ref r 6)
          'from_name (nz (vector-ref r 7))
          'base_url (nz (vector-ref r 8))
          'active (= 1 (vector-ref r 9))
          'last_test_epoch (nz (vector-ref r 10))
          'last_test_ok (let ([v (vector-ref r 11)]) (if (sql-null? v) 'null (= 1 v)))
          'last_test_error (nz (vector-ref r 12))
          'updated_by (nz (vector-ref r 13))
          'updated_epoch (vector-ref r 14)))

(define (transport-row conn)
  (query-maybe-row conn (string-append "SELECT " COLS " FROM email_transport WHERE id = ?") TRANSPORT-ID))

;; -> a jsexpr hash, or #f when nothing is configured. The ABSENCE is what makes
;; email off by default (MAIL-10), which is every default-bearing knob's rule in
;; this tree: an upgrade must not start sending mail.
(define (transport-ref conn)
  (define r (transport-row conn))
  (and r (row->transport r)))

;; "Is there a working transport?" — ACTIVE as well as present, so an operator can
;; stop all mail with one field without destroying the configuration they would
;; have to retype. Cheap enough to ask per message: one indexed single-row lookup,
;; beside the token and permission queries the same request already runs
;; (settings.rkt's own argument for not caching).
(define (transport-configured? conn)
  (define t (transport-ref conn))
  (and t (hash-ref t 'active) #t))

;; THE PASSWORD IS NEVER IN A READ, so this is its own function and it is the one
;; place the plaintext exists. Only two callers may have it: the delivery sweep,
;; which is about to speak to the relay, and the probe. It is deliberately NOT a
;; field on `transport-ref`, which is what the API answers with — #19's rule, and
;; `webhook-secret-of`'s shape.
(define (transport-password conn)
  (define r (query-maybe-value conn "SELECT password FROM email_transport WHERE id = ?" TRANSPORT-ID))
  (and r (not (sql-null? r)) (unseal-password TRANSPORT-ID r)))

(define (transport-base-url conn)
  (define t (transport-ref conn))
  (and t (let ([u (hash-ref t 'base_url)]) (and (string? u) (not (string=? u "")) u))))

;; An UNKNOWN field is refused rather than dropped, and so is an unknown security
;; mode: a setting that silently does nothing is how an operator concludes the
;; feature is broken — the call an unknown theme token, an unknown retention field
;; and an unknown feature all make.
(define KNOWN-FIELDS '(host port security username password from_address from_name base_url active))

(define (transport-problem doc)
  (cond
    [(not (hash? doc)) "a transport document must be an object"]
    [(for/or ([(k _) (in-hash doc)])
       (and (not (memq k KNOWN-FIELDS))
            (format "unknown field '~a' — known fields are: ~a" k
                    (string-join (map symbol->string KNOWN-FIELDS) ", "))))
     => values]
    [(let ([h (hash-ref doc 'host #f)])
       (and (not (and (string? h) (regexp-match? #px"^[A-Za-z0-9][A-Za-z0-9._-]*$" h)))
            "host must be a hostname"))
     => values]
    [(let ([p (hash-ref doc 'port #f)])
       (and (not (and (exact-integer? p) (> p 0) (< p 65536))) "port must be 1-65535"))
     => values]
    [(let ([s (hash-ref doc 'security "starttls")])
       (and (not (member s SECURITY-MODES))
            (format "security must be one of: ~a" (string-join SECURITY-MODES ", "))))
     => values]
    ;; The FROM address is checked by the same function a recipient is, and for the
    ;; sharper of the two reasons: it is interpolated into a header this instance
    ;; composes, so a newline in it is a header injection an operator could not
    ;; see in the console.
    [(let ([f (hash-ref doc 'from_address #f)]) (mail-address-problem f)) => values]
    ;; A display name reaches a header too, so it is held to the same no-newline
    ;; rule. It is not an address, so nothing else about it is constrained.
    [(let ([n (hash-ref doc 'from_name #f)])
       (and n (not (eq? n 'null))
            (or (not (string? n)) (regexp-match? #px"[\r\n\0]" n))
            "from_name must be a single line of text"))
     => values]
    [(let ([u (hash-ref doc 'base_url #f)])
       (and u (not (eq? u 'null))
            (not (and (string? u) (regexp-match? #px"^https?://[^\\s\r\n]+$" u)))
            "base_url must be an http(s) URL"))
     => values]
    [(let ([v (hash-ref doc 'active #t)]) (and (not (boolean? v)) "active must be true or false")) => values]
    [else #f]))

;; Read-modify-write of the whole row, with an ABSENT password leaving the stored
;; one alone — otherwise every edit to the port or the From address would silently
;; clear the credential, and the operator would discover it from a dead letter.
;; An explicitly NULL password clears it, which is how an operator moves to a
;; relay that wants none.
(define (transport-set! conn doc #:by [by #f])
  (define p (transport-problem doc))
  (when p (error 'email-transport "~a" p))
  (define cur (transport-row conn))
  (define (f k [d sql-null])
    (let ([v (hash-ref doc k 'absent)])
      (cond [(eq? v 'absent) d] [(eq? v 'null) sql-null] [else v])))
  (define pw
    (let ([v (hash-ref doc 'password 'absent)])
      (cond
        [(eq? v 'absent) (if cur (vector-ref cur 5) sql-null)]
        [(or (eq? v 'null) (and (string? v) (string=? v ""))) sql-null]
        [else (seal-password TRANSPORT-ID v)])))
  (define args
    (list (f 'host) (f 'port) (hash-ref doc 'security "starttls") (f 'username)
          pw (f 'from_address) (f 'from_name) (f 'base_url)
          (if (hash-ref doc 'active #t) 1 0) (or by sql-null) (now)))
  ;; No ON CONFLICT: the dialects spell upsert differently and this is one row —
  ;; settings.rkt's own reason.
  (if cur
      (apply query-exec conn
             (string-append "UPDATE email_transport SET host = ?, port = ?, security = ?, username = ?, "
                            "password = ?, from_address = ?, from_name = ?, base_url = ?, active = ?, "
                            "updated_by = ?, updated_epoch = ? WHERE id = '" TRANSPORT-ID "'")
             args)
      (apply query-exec conn
             (string-append "INSERT INTO email_transport (host, port, security, username, password, "
                            "from_address, from_name, base_url, active, updated_by, updated_epoch, id) "
                            "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, '" TRANSPORT-ID "')")
             args))
  (transport-ref conn))

;; The only way OFF at the instance tier, and it exists for RED-34's reason: a
;; `PUT` with `active: false` is still a CONFIGURED transport, so without a
;; delete there would be no way to return the instance to the state it shipped in
;; — and a smoke fixture that left one behind would change what every later block
;; was testing.
(define (transport-clear! conn)
  (query-exec conn "DELETE FROM email_transport WHERE id = ?" TRANSPORT-ID))

(define (transport-record-test! conn ok? err)
  (query-exec conn (string-append "UPDATE email_transport SET last_test_epoch = ?, last_test_ok = ?, "
                                  "last_test_error = ? WHERE id = ?")
              (now) (if ok? 1 0) (or err sql-null) TRANSPORT-ID))

;; ---- composing ----------------------------------------------------------------
;; RFC 2047 encoded-words, and this is not gold-plating: the console ships a
;; complete `ja` catalog, so a notification's subject legitimately contains
;; Japanese — and a raw UTF-8 subject is non-conformant and arrives mangled in
;; most clients. ASCII is passed through unchanged so the ordinary case stays
;; readable in a transcript and in a dead letter an operator inspects.
(define (ascii? s) (for/and ([ch (in-string s)]) (< (char->integer ch) 128)))

(define (b64-line bs)
  ;; `base64-encode` inserts CRLFs to wrap; a header's encoded-word must be one
  ;; token, so they come out.
  (string-replace (string-replace (bytes->string/utf-8 (base64-encode bs #"")) "\r" "") "\n" ""))

(define (encode-subject s)
  (define one-line (string-trim (regexp-replace* #px"[\r\n]+" s " ")))
  (if (ascii? one-line)
      one-line
      (string-append "=?UTF-8?B?" (b64-line (string->bytes/utf-8 one-line)) "?=")))

;; The BODY goes out as base64 under `Content-Transfer-Encoding: base64`. 8bit is
;; widely accepted and is not guaranteed, quoted-printable is a second encoder to
;; get wrong, and base64 is always correct — and the body is a handful of lines,
;; so the 33% is nothing. `smtp-send-message` takes the body as LINES, which is
;; what the wrapping produces.
(define (encode-body s)
  (define raw (base64-encode (string->bytes/utf-8 s) #""))
  (define text (bytes->string/utf-8 raw))
  (for/list ([chunk (in-list (wrap-76 text))]) chunk))

(define (wrap-76 s)
  (let loop ([i 0] [acc '()])
    (cond
      [(>= i (string-length s)) (reverse (if (null? acc) (list "") acc))]
      [else (define j (min (string-length s) (+ i 76)))
            (loop j (cons (substring s i j) acc))])))

(define (transport-from-header t)
  (define a (hash-ref t 'from_address))
  (define n (hash-ref t 'from_name))
  (if (and (string? n) (not (string=? n "")))
      ;; the display name is encoded by the same rule the subject is; an address
      ;; is always ASCII here because `valid-address?` says so
      (format "~a <~a>" (encode-subject n) a)
      a))

;; -> (values header body-lines). SEPARATED FROM THE SEND so a test can assert
;; what would go on the wire without a mail server, which is where the injection
;; rules are actually worth checking.
(define (compose-message t recipient subject body #:message-id [mid #f])
  (define from (transport-from-header t))
  (define base (standard-message-header from (list recipient) '() '() (encode-subject subject)))
  ;; `standard-message-header` ends the header with a blank line; `insert-field`
  ;; works on that shape, so the MIME fields go in through it rather than by
  ;; string surgery.
  ;; A MESSAGE-ID, AND IT IS THE DELIVERY'S OWN ID. Two things it buys, and
  ;; neither is cosmetic: a relay that is handed none generates one, so the id an
  ;; operator reads in their mail log has nothing to do with the row in
  ;; `email_deliveries` — and several filters score a missing one. The domain is
  ;; taken from the From address, which is this instance's own identity and the
  ;; only domain it may honestly speak for.
  ;;
  ;; A RETRY REUSES IT, deliberately: the attempts are one message, so a reader
  ;; whose relay accepted a duplicate sees one in their client rather than two.
  (define domain
    (let ([m (regexp-match #px"@(.+)$" (hash-ref t 'from_address))])
      (if m (cadr m) "localhost")))
  (define hdr
    (insert-field "MIME-Version" "1.0"
      (insert-field "Content-Transfer-Encoding" "base64"
        (insert-field "Content-Type" "text/plain; charset=utf-8"
          (insert-field "Auto-Submitted" "auto-generated"
            (if mid
                (insert-field "Message-ID" (format "<~a@~a>" mid domain) base)
                base))))))
  (values hdr (encode-body body)))

;; ---- the deadline -------------------------------------------------------------
;; `llm.rkt` has this shape too and is NOT reused: requiring it from here would
;; pull the whole model stack into the mail path, and its version raises
;; `exn:fail:model-retryable`, which is a vocabulary about a model call. Two
;; functions with different contracts are not `executor-can-run?`'s drift — that
;; is two copies of one RULE — and the rule each enforces is its own subsystem's
;; retry policy. What they share is a generic concurrency idiom.
;;
;; THE CUSTODIAN IS THE POINT: killing the thread alone would leave the SMTP
;; socket open, and this runs on a seam that ticks several times a second.
(define (call-with-deadline secs who thunk)
  (define cust (make-custodian))
  (define ch (make-channel))
  (define t (parameterize ([current-custodian cust])
              (thread (lambda ()
                        (channel-put ch
                          (with-handlers ([(lambda (_) #t) (lambda (e) (cons 'raise e))])
                            (cons 'ok (thunk))))))))
  (define r (sync/timeout secs ch))
  (custodian-shutdown-all cust)
  (cond
    [(not r) (kill-thread t) (mail-error! #f "~a: no response within ~as" who secs)]
    [(eq? (car r) 'raise) (raise (cdr r))]
    [else (cdr r)]))

;; ---- the send -----------------------------------------------------------------
;; -> void, or raises `exn:fail:mail`. It is handed the TRANSPORT rather than
;; reading it, so a caller that is sending several messages reads the row once —
;; and so a test can hand it one that is not in any database.
(define (smtp-deliver! t recipient subject body #:password [password #f]
                       #:message-id [mid #f]
                       #:timeout [secs SMTP-TIMEOUT])
  (define bad (mail-address-problem recipient))
  ;; PERMANENT: an address that is not an address now will not be one later, and
  ;; this check is also the last line of defence against the header injection
  ;; `valid-address?` is written for.
  (when bad (mail-error! #t "~a: ~a" (clip (printable recipient) 200) bad))
  (define-values (hdr lines) (compose-message t recipient subject body #:message-id mid))
  (define security (hash-ref t 'security))
  (define user (let ([u (hash-ref t 'username)]) (and (string? u) (not (string=? u "")) u)))
  (call-with-deadline secs 'smtp
    (lambda ()
      (with-handlers
        ([exn:fail:mail? raise]
         ;; `smtp-send-message` raises with the server's own reply text, which is
         ;; the single most useful thing an operator has for a relay that will not
         ;; answer — so it is KEPT, unlike bind.rkt's operands (SEC-7), where the
         ;; value was content the caller already held. What is bounded is its
         ;; LENGTH, in `mail.rkt`, because many relays echo the message back
         ;; inside a reply and FEED-6's rule is that anything outliving the call
         ;; is a copy.
         ;;
         ;; A 5xx reply is PERMANENT and a 4xx is not — RFC 5321's own split, and
         ;; the one this subsystem's retry curve turns on. It is read off the
         ;; message rather than from a structured status because `net/smtp` does
         ;; not surface one; the pattern is anchored at a word boundary so a
         ;; latency figure or a port number in the text cannot be read as a code.
         [exn:fail?
          (lambda (e)
            (define m (exn-message e))
            (mail-error! (and (regexp-match? #px"\\b5[0-9][0-9]\\b" m) #t) "~a" m))])
        (smtp-send-message
         (hash-ref t 'host) (hash-ref t 'from_address) (list recipient) hdr lines
         #:port-no (hash-ref t 'port)
         #:auth-user user
         #:auth-passwd (and user password)
         ;; `tls` is implicit TLS from the first byte — the connection itself is
         ;; encrypted, so it is the CONNECTOR that changes. `starttls` negotiates
         ;; upwards inside a plaintext connection, which is the `#:tls-encode`
         ;; hook. Passing both, or the wrong one, fails as a hang or as a protocol
         ;; error nobody can read, which is why the mode is stored (MAIL-11) and
         ;; not guessed from the port.
         #:tcp-connect (if (equal? security "tls") ssl-connect tcp-connect)
         #:tls-encode (if (equal? security "starttls") starttls-encode #f)))
      (void))))

;; THE STARTTLS ENCODER EXISTS BECAUSE `ports->ssl-ports` PASSED STRAIGHT IN IS
;; BROKEN AGAINST EVERY MODERN RELAY, and nothing found that for as long as the
;; branch had no test.
;;
;; `net/smtp` calls the encoder with `#:encrypt 'tls` hardcoded, and in Racket's
;; openssl binding `'tls` does not mean "TLS" — it means **TLS 1.0 exactly**.
;; OpenSSL 3.x disables that at its default security level, so the handshake dies
;; with `no protocols available` before a byte of mail moves. Measured against
;; OpenSSL 3.6.4: the implicit-TLS branch works, because `ssl-connect` defaults
;; to `'auto` and net/smtp never touches it, and the STARTTLS branch — the one
;; nearly every real relay uses, on 587 — could never have worked.
;;
;; So the encoder takes the keywords net/smtp sends and OVERRIDES that one,
;; leaving the rest as given. It is a wrapper rather than a patch to the argument
;; because the argument is not ours to pass: the version negotiated is between
;; our context and the relay, and `'auto` is what lets them agree on the best
;; both support.
;;
;; WHAT IT DOES NOT DO IS VERIFY THE RELAY'S CERTIFICATE, and that is stated
;; rather than implied. net/smtp passes no `#:context`, so the default client
;; context answers and that one does not verify — a self-signed certificate is
;; accepted, which `test/mail-tests.rkt` establishes by handing it one rather
;; than by assuming. The honest reading: TLS here defends against a PASSIVE
;; listener on the path and not against an active machine-in-the-middle that can
;; present any certificate. Making it verify is a behaviour decision, because it
;; would refuse the self-signed internal relay these deployments often run, so it
;; wants an operator-visible switch rather than a quiet change of posture.
(define (starttls-encode in out
                         #:mode [mode 'connect]
                         #:encrypt [_encrypt 'tls]
                         #:close-original? [close-original? #t])
  (ports->ssl-ports in out
                    #:mode mode
                    #:encrypt 'auto
                    #:close-original? close-original?))
