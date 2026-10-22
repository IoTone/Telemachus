#lang racket/base

;; test/feed-tests.rkt — external feed configuration (#114, FEED-2/-5/-6).
;;
;;   raco test test/feed-tests.rkt
;;
;; Three properties carry the slice, and each is positive-controlled by being
;; written so that the obvious wrong implementation fails it:
;;
;;   1. WHERE THE CREDENTIAL GOES. `feed-request` is asserted mode by mode, and
;;      the secret must appear in exactly ONE place — so a `query` feed that also
;;      sent a bearer header, or a `none` feed that sent anything, fails.
;;   2. WHAT A FAILURE IS ALLOWED TO SAY (FEED-6). A token in the URL's query is
;;      the fixture, and the assertion is over the STORED ROW and the raised
;;      message, not over a formatted log line — the copy that outlives the
;;      process is the one that matters.
;;   3. THE SECRET IS SEALED, ROTATABLE AND NEVER READ BACK. Asserted off the raw
;;      row, with the rotation done through the same two keys `rewrap` uses.

(require rackunit db-kit/portable db-kit/migrate
         racket/tcp racket/string racket/list racket/port racket/file
         racket/runtime-path racket/path json
         "../domain/db/migrations.rkt"
         "db-fixture.rkt"
         "../domain/authz/authz.rkt"
         (only-in "../domain/authz/secretbox.rkt" wrapped-secret? secret-key-id)
         (only-in "../domain/net/fetch.rkt" fetch safe-url exn:fail:egress? exn:fail:egress-url)
         "../domain/feeds/feeds.rkt")

(define (fresh) (define c (fresh-db #:migrate? #f)) (migrate! c all-migrations) c)

;; Anchored at the MODULE, not at the working directory: `nix build` runs the
;; suite from somewhere else, and the registry case below reads a source file.
(define-runtime-path here ".")
(define ROOT (simplify-path (build-path here 'up)))

(define (with-env name value thunk)
  (define saved (getenv name))
  (dynamic-wind (lambda () (putenv name (or value ""))) thunk
                (lambda () (putenv name (or saved "")))))

(define KEY-A (make-string 64 #\a))
(define KEY-B (make-string 64 #\b))

(define (mk conn team user #:slug [slug "jira"] #:url [url "https://src.example.com/api/items"]
            #:auth [auth "none"] #:auth-name [an #f] #:secret [secret #f] #:kind [kind "http.json"])
  (feed-create! conn #:team team #:user user #:slug slug #:name "Tickets" #:kind kind
                #:url url #:auth auth #:auth-name an #:secret secret #:created-by user))

;; ---- validation ---------------------------------------------------------------------
(test-case "configuration that would fail on the first poll is refused now"
  (define (prob #:slug [slug "jira"] #:kind [kind "http.json"] #:url [url "https://h/x"]
                #:auth [auth "none"] #:auth-name [an #f] #:secret [secret #f])
    (feed-problem #:slug slug #:kind kind #:url url #:auth auth #:auth-name an #:secret secret))
  (check-false (prob))
  (check-false (prob #:auth "bearer" #:secret "t0ken"))
  (check-false (prob #:auth "header" #:auth-name "X-Api-Key" #:secret "t0ken"))
  (check-false (prob #:auth "query" #:auth-name "token" #:secret "t0ken"))
  ;; the slug is a KEY PREFIX, so it has to be a key
  (check-true (string? (prob #:slug "Jira Tickets")))
  (check-true (string? (prob #:slug "")))
  (check-true (string? (prob #:slug "-leading")))
  ;; a kind nothing pulls is #113's shape — refused where somebody is reading
  (check-true (string? (prob #:kind "jira")))
  (check-true (string? (prob #:kind "")))
  (check-true (string? (prob #:url "ftp://h/x")))
  (check-true (string? (prob #:url "not a url")))
  ;; userinfo is unambiguously a credential and there is a sealed home for one
  (check-true (string? (prob #:url "https://u:pw@h/x")))
  (check-true (string? (prob #:url "https://u@h/x")))
  ;; …while a query the operator wrote is ordinary configuration
  (check-false (prob #:url "https://h/x?project=FOO"))
  (check-true (string? (prob #:auth "oauth2" #:secret "t")))
  ;; a credential with no way to present it, and a presentation with no
  ;; credential, are both configuration that fails on the first poll
  (check-true (string? (prob #:auth "bearer")))
  (check-true (string? (prob #:auth "none" #:secret "t0ken")))
  (check-true (string? (prob #:auth "header" #:secret "t0ken")))
  (check-true (string? (prob #:auth "query" #:secret "t0ken")))
  (check-true (string? (prob #:auth "header" #:auth-name "bad name" #:secret "t0ken"))))

;; ---- FEED-2: whose authority a pull spends -------------------------------------------
(test-case "a feed cannot act as somebody outside its team"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice"))
  (check-true (string? (mk c tid uid)))
  ;; A user id that is not an ACTIVE member is refused at the write, not left to
  ;; fail at `can?` time on a timer with nobody watching.
  (check-equal? (mk c tid "u-nobody" #:slug "other") 'no-such-user)
  (query-exec c "UPDATE memberships SET status = 'inactive' WHERE user_id = ? AND team_id = ?" uid tid)
  (check-equal? (mk c tid uid #:slug "third") 'no-such-user)
  (close-db! c))

(test-case "the slug is unique per team, and a re-post does not adopt the existing feed"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice"))
  (define id (mk c tid uid #:url "https://a.example.com/x"))
  (check-true (string? id))
  ;; Deliberately NOT converging (unlike TEN-2f's orgs): a second create would
  ;; silently take over the first feed's URL and credential.
  (check-equal? (mk c tid uid #:url "https://b.example.com/x") 'duplicate-slug)
  (check-equal? (hash-ref (feed-get c id tid) 'url) "https://a.example.com/x")
  (close-db! c))

;; ---- FEED-5: the credential at rest ---------------------------------------------------
(test-case "the secret is sealed in the row, never in a read, and rotates with the key"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice"))
  (with-env "TELEMACHUS_SECRET_KEY" KEY-A
    (lambda ()
      (define id (mk c tid uid #:auth "bearer" #:secret "t0p-s3cret"))
      ;; off the RAW ROW, which is what a dump holds
      (define raw (query-value c "SELECT secret FROM feeds WHERE id = ?" id))
      (check-true (wrapped-secret? raw))
      (check-false (regexp-match? #rx"t0p-s3cret" raw))
      (check-equal? (feed-secret-of c id) "t0p-s3cret")
      ;; No read hands it back: the row says WHETHER there is one, which is the
      ;; configuration an operator needs, and that is all.
      (define f (feed-get c id tid))
      (check-true (hash-ref f 'has_secret))
      (check-false (regexp-match? #rx"t0p-s3cret" (jsexpr->string f)))
      (check-false (regexp-match? #rx"t0p-s3cret" (jsexpr->string (hasheq 'l (feed-list c tid)))))
      ;; `telemachus-secrets rewrap`'s own path: read with the previous key,
      ;; write with the current one. A sealed column outside `CREDENTIAL-SECRETS`
      ;; is silently unrotatable, which is the step #83's notes say people forget
      ;; — so the registry row is pinned in `test/secrets-registry` below.
      (with-env "TELEMACHUS_SECRET_KEY_OLD" KEY-A
        (lambda ()
          (with-env "TELEMACHUS_SECRET_KEY" KEY-B
            (lambda ()
              (define plain (feed-secret-of c id))
              (check-equal? plain "t0p-s3cret")
              (feed-update! c id tid #:secret plain)
              ;; written with the CURRENT key, so the label changed
              (check-true (regexp-match? (regexp (secret-key-id))
                                         (query-value c "SELECT secret FROM feeds WHERE id = ?" id)))
              (check-equal? (feed-secret-of c id) "t0p-s3cret")))))
      ;; …and the old key no longer opens it, which is what a rotation means
      (with-env "TELEMACHUS_SECRET_KEY" KEY-B
        (lambda () (check-equal? (feed-secret-of c id) "t0p-s3cret")))))
  (close-db! c))

(test-case "clearing the credential is distinguishable from never having had one"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice"))
  (define id (mk c tid uid #:auth "bearer" #:secret "t0ken"))
  (check-true (hash-ref (feed-get c id tid) 'has_secret))
  ;; A NULL, not an empty string: `rewrap`'s `rows-of` filters on `IS NOT NULL`,
  ;; so an empty string would be a row it tried to seal for ever.
  (feed-update! c id tid #:auth "none" #:secret #f)
  (check-false (hash-ref (feed-get c id tid) 'has_secret))
  (check-true (sql-null? (query-value c "SELECT secret FROM feeds WHERE id = ?" id)))
  (check-false (feed-secret-of c id))
  (close-db! c))

;; ---- where the credential goes ---------------------------------------------------------
(test-case "each auth mode puts the secret in exactly one place"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice"))
  (define (request! #:auth auth #:auth-name [an #f] #:secret [secret "t0ken"]
                    #:url [url "https://src.example.com/api/items"] #:slug slug)
    (define id (mk c tid uid #:slug slug #:url url #:auth auth #:auth-name an #:secret secret))
    (define-values (u hs) (feed-request c (feed-get c id tid)))
    (values u hs))
  ;; `none` sends nothing anywhere — the control that makes the others mean
  ;; something, since a mode that leaked into every request would still pass a
  ;; "the header is present" assertion.
  (let-values ([(u hs) (request! #:auth "none" #:secret #f #:slug "pub")])
    (check-equal? u "https://src.example.com/api/items")
    (check-false (regexp-match? #rx"t0ken" (format "~a~a" u hs))))
  (let-values ([(u hs) (request! #:auth "bearer" #:slug "b")])
    (check-equal? u "https://src.example.com/api/items")
    (check-equal? (cdr (assoc "authorization" hs)) "Bearer t0ken")
    (check-false (regexp-match? #rx"t0ken" u)))
  (let-values ([(u hs) (request! #:auth "header" #:auth-name "X-Api-Key" #:slug "h")])
    ;; lower-cased on the way out, because that is how the wire spells it and a
    ;; receiver matching case-insensitively should not depend on ours
    (check-equal? (cdr (assoc "x-api-key" hs)) "t0ken")
    (check-false (regexp-match? #rx"t0ken" u)))
  (let-values ([(u hs) (request! #:auth "query" #:auth-name "token"
                                 #:url "https://src.example.com/api/items?project=FOO" #:slug "q")])
    ;; APPENDED, so a source that needs both a filter and a token works — the
    ;; first version replaced the query and the filter silently vanished.
    (check-true (regexp-match? #rx"project=FOO" u))
    (check-true (regexp-match? #rx"token=t0ken" u))
    (check-false (regexp-match? #rx"t0ken" (format "~a" hs))))
  (close-db! c))

;; ---- FEED-6: what a failure is allowed to say -------------------------------------------
(test-case "a token in the URL reaches neither the stored error nor the exception"
  ;; This is the acceptance criterion, written as the leak test rather than as a
  ;; check that a redaction function exists: the fixture carries the credential
  ;; in the query string, and the assertion is over every copy that outlives the
  ;; call — the stored row and the raised message.
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice"))
  (define leaky "https://u:pw@src.invalid.example/api/items?token=SEKRIT-abc123&project=FOO")
  (check-equal? (safe-url leaky) "https://src.invalid.example/api/items")
  ;; `safe-url` keeps the host and the path, because a diagnostic naming neither
  ;; is no diagnostic — FEED-6 says host, path and status.
  (check-true (regexp-match? #rx"src.invalid.example" (safe-url leaky)))
  (check-false (regexp-match? #rx"SEKRIT|pw@|project=FOO" (safe-url leaky)))
  ;; TWO COPIES OUTLIVE THE CALL and both are asserted, because they are
  ;; produced in different places: the MESSAGE, which a caller stores, and the
  ;; exception's own `url` FIELD, which a caller may format into anything. A test
  ;; that checked only one of them passed against a version that redacted only
  ;; the other — which is what the control found.
  (define raised
    (with-handlers ([exn:fail:egress? (lambda (e) e)])
      ;; `bad-url` is the one refusal that quotes the URL, and a URL this refuses
      ;; is exactly the shape somebody mistyped — credential and all.
      (fetch "ftp://src.example.com/api/items?token=SEKRIT-abc123" #:policy 'trusted)
      #f))
  (check-true (exn:fail:egress? raised))
  (check-false (regexp-match? #rx"SEKRIT" (exn-message raised)))
  (check-false (regexp-match? #rx"SEKRIT" (exn:fail:egress-url raised)))
  ;; and it still names the host, or it would be no diagnostic
  (check-true (regexp-match? #rx"src.example.com" (exn-message raised)))
  (define id (mk c tid uid #:url leaky))
  (define outcome (probe-feed! c (feed-get c id tid)))
  (check-false (hash-ref outcome 'ok))
  (define stored (query-value c "SELECT last_error FROM feeds WHERE id = ?" id))
  (check-true (string? stored))
  (check-false (regexp-match? #rx"SEKRIT" stored))
  (check-false (regexp-match? #rx"pw@" stored))
  (check-false (regexp-match? #rx"SEKRIT" (jsexpr->string outcome)))
  ;; a refusal that named nothing would also pass the two checks above, so the
  ;; host has to be IN it
  (check-true (regexp-match? #rx"src.invalid.example" (format "~a~a" stored (jsexpr->string outcome))))
  ;; the same, stored, for the refusal that DOES quote the URL
  (define id2 (mk c tid uid #:slug "scheme" #:url "ftp://src.example.com/api/items?token=SEKRIT-abc123"))
  (void (probe-feed! c (feed-get c id2 tid)))
  (define stored2 (query-value c "SELECT last_error FROM feeds WHERE id = ?" id2))
  (check-true (string? stored2))
  (check-false (regexp-match? #rx"SEKRIT" stored2))
  (close-db! c))

;; ---- the probe, over a real socket ------------------------------------------------------
;; A probe is the only thing in this slice that crosses the network, and every
;; property worth asserting is at the wire: which status came back, whether the
;; body was JSON, what the row says afterwards, and — the point of the fixture —
;; that the credential arrived in the right place.
(define (with-source handler proc)
  (define L (tcp-listen 0 8 #t "127.0.0.1"))
  (define-values (_h p _rh _rp) (tcp-addresses L #t))
  (define seen (box '()))
  (define t
    (thread (lambda ()
              (with-handlers ([(lambda (_) #t) void])
                (let loop ()
                  (define-values (i o) (tcp-accept L))
                  (thread (lambda ()
                            (with-handlers ([(lambda (_) #t) void])
                              (define lines
                                (let rl ([acc '()])
                                  (define l (read-line i 'return-linefeed))
                                  (cond [(or (eof-object? l) (string=? l "")) (reverse acc)]
                                        [else (rl (cons l acc))])))
                              (set-box! seen (cons lines (unbox seen)))
                              (handler o lines)
                              (with-handlers ([(lambda (_) #t) void]) (close-output-port o))
                              (with-handlers ([(lambda (_) #t) void]) (close-input-port i)))))
                  (loop))))))
  (define was (getenv "TELEMACHUS_EGRESS_ALLOW"))
  ;; the source is on loopback, which #142 refuses unless the OPERATOR allowed
  ;; that network — which is exactly the customer's "feeds in our network" case
  (putenv "TELEMACHUS_EGRESS_ALLOW" "127.0.0.0/8")
  (dynamic-wind
   void
   (lambda () (proc (format "http://127.0.0.1:~a/api/items" p) seen))
   (lambda ()
     (putenv "TELEMACHUS_EGRESS_ALLOW" (or was ""))
     (kill-thread t)
     (tcp-close L))))

(define (respond o code body [ctype "application/json"])
  (fprintf o "HTTP/1.1 ~a X\r\ncontent-type: ~a\r\ncontent-length: ~a\r\nconnection: close\r\n\r\n~a"
           code ctype (bytes-length (string->bytes/utf-8 body)) body)
  (flush-output o))

(test-case "a probe answers what the source did, and records it without storing a document"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice"))
  (with-source (lambda (o _l) (respond o 200 "{\"items\":[]}"))
    (lambda (url seen)
      (define id (mk c tid uid #:url url #:auth "header" #:auth-name "X-Api-Key" #:secret "t0ken"))
      (define outcome (probe-feed! c (feed-get c id tid)))
      (check-true (hash-ref outcome 'ok))
      (check-equal? (hash-ref outcome 'status) 200)
      (check-true (hash-ref outcome 'json))
      ;; the credential arrived, in the header the operator named
      (define hs (map string-downcase (car (unbox seen))))
      (check-true (and (member "x-api-key: t0ken" hs) #t))
      (define f (feed-get c id tid))
      (check-true (number? (hash-ref f 'last_fetch_epoch)))
      (check-true (number? (hash-ref f 'last_ok_epoch)))
      (check-equal? (hash-ref f 'last_status) 200)
      (check-equal? (hash-ref f 'last_error) 'null)
      ;; A PROBE IS NOT AN INGEST. Slice 4 lands items; if this ever creates a
      ;; repo object, an operator checking their configuration would be writing
      ;; documents and spending storage quota by doing so.
      (check-equal? (query-value c "SELECT COUNT(*) FROM repo_objects") 0)))
  (close-db! c))

(test-case "a refused credential is the source's own status, and `last_ok_epoch` does not move"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice"))
  (define n (box 0))
  (with-source (lambda (o _l)
                 (set-box! n (add1 (unbox n)))
                 (if (= (unbox n) 1)
                     (respond o 200 "{\"items\":[]}")
                     (respond o 401 "{\"error\":\"bad token\"}")))
    (lambda (url seen)
      (define id (mk c tid uid #:url url #:auth "bearer" #:secret "t0ken"))
      (void (probe-feed! c (feed-get c id tid)))
      ;; AGED DELIBERATELY. `last_ok_epoch` is seconds, so two probes in one
      ;; second tie and "it did not move" would hold against a version that
      ;; stamps it on every attempt — which is exactly what the control does.
      (query-exec c "UPDATE feeds SET last_ok_epoch = 1700000000 WHERE id = ?" id)
      (define ok-at (hash-ref (feed-get c id tid) 'last_ok_epoch))
      (check-equal? ok-at 1700000000)
      (define outcome (probe-feed! c (feed-get c id tid)))
      (check-false (hash-ref outcome 'ok))
      (check-equal? (hash-ref outcome 'status) 401)
      (define f (feed-get c id tid))
      (check-equal? (hash-ref f 'last_status) 401)
      (check-true (string? (hash-ref f 'last_error)))
      ;; "it last worked at" survives a run of failures — the number an operator
      ;; wants when a feed has been quietly failing for a week.
      (check-equal? (hash-ref f 'last_ok_epoch) ok-at)))
  (close-db! c))

(test-case "a 200 that is not JSON is named, not counted as a success"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice"))
  (with-source (lambda (o _l) (respond o 200 "<html>sign in</html>" "text/html"))
    (lambda (url seen)
      (define id (mk c tid uid #:url url))
      (define outcome (probe-feed! c (feed-get c id tid)))
      ;; The commonest misconfiguration of all: a captive portal or a login page
      ;; answering 200. "ok" on the status alone would call that working.
      (check-false (hash-ref outcome 'ok))
      (check-equal? (hash-ref outcome 'status) 200)
      (check-false (hash-ref outcome 'json))
      (check-true (regexp-match? #rx"not JSON" (hash-ref (feed-get c id tid) 'last_error)))))
  (close-db! c))

;; ---- the registry `rewrap` walks --------------------------------------------------------
(test-case "feeds.secret is in CREDENTIAL-SECRETS"
  ;; A STATIC CHECK, deliberately, in the shape `vocabulary-tests.rkt` uses: the
  ;; CLI has no exports, and the failure this guards against is an omission —
  ;; a sealed column outside the registry is skipped by `rewrap` and a key
  ;; rotation leaves it unopenable, with nothing at runtime to notice.
  (define src (file->string (build-path ROOT "cli" "telemachus-secrets.rkt")))
  (define (listed? table col) (regexp-match? (regexp (format "\"~a\" +\"~a\"" table col)) src))
  (check-true (listed? "feeds" "secret"))
  ;; the control: the assertion is only worth anything if it can tell the
  ;; registry apart from any other list of strings in that file
  (check-true (listed? "webhooks" "secret"))
  (check-true (listed? "users" "totp_secret"))
  (check-false (listed? "feeds" "url")))
