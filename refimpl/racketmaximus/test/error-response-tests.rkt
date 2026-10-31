#lang racket/base

;; test/error-response-tests.rkt — what a 500 is allowed to say (issue #123).
;;
;; `handle` answered `(err (exn-message e) 500)`, so every unhandled exception's
;; message became the response body. The duplicate-username INSERT is how that
;; was reported and SQL is the least of it: #83 r4 sealed four stored `error`
;; columns precisely because this platform's own code quotes what it choked on —
;; the strict renderer names the missing placeholder, DWF-5's extraction names
;; the JSON path and the offending value, the knowledge-graph extractor quotes a
;; snippet it refused. That reasoning applies unchanged to a response body.
;;
;; The rule lives in `server/kit.rkt` rather than inside `handle` so it is
;; testable without a live server — peer.rkt's and startup.rkt's move, and here
;; it is load-bearing: after the 409 fix there may be no request left that still
;; raises, so a smoke could not reach this path at all.
;;
;;   raco test test/error-response-tests.rkt

(require rackunit racket/port racket/string
         web-server/http
         ;; errors.rkt and NOT kit.rkt: requiring kit instantiates the connection
         ;; POOL, which reads DATABASE_URL at module instantiation — and CI's
         ;; SQLite leg sets that to the EMPTY STRING, so this test failed there
         ;; and passed everywhere the variable happens to be unset or valid. The
         ;; comment claiming the rule was "unit-testable without a live server"
         ;; was false until the rule moved to a module with no database in it.
         json
         (only-in "../domain/authz/authz.rkt" exn:fail:forbidden)
         "../server/errors.rkt")

;; the response's body, which is written by a procedure rather than stored
(define (body-of resp)
  (define o (open-output-bytes))
  ((response-output resp) o)
  (bytes->string/utf-8 (get-output-bytes o)))

(define (capture-stderr thunk)
  (define e (open-output-string))
  (define r (parameterize ([current-error-port e]) (thunk)))
  (values r (get-output-string e)))

;; the shapes this platform's own code actually raises
(define SQL-EXN
  (make-exn:fail (string-append "query-exec: abort due to constraint violation\n"
                                "  SQL: INSERT INTO users (id, username, password_hash) VALUES (?, ?, ?)")
                 (current-continuation-marks)))
(define RENDERER-EXN
  (make-exn:fail "render: no value for {{patient_name}}" (current-continuation-marks)))
;; NB: an INVENTED shape, not one this tree produces — `jsonschema.rkt` quotes no
;; value anywhere (#186's sweep established that, correcting this file's own
;; earlier claim). It is kept because the rule under test is "a 500 body carries
;; no exception message", and a message that quotes a national id is the right
;; adversarial input for that whatever raised it.
(define EXTRACT-EXN
  (make-exn:fail "$.total: expected number, got string \"444-55-6666\"" (current-continuation-marks)))

(test-case "the body carries no exception message, and no SQL"
  (define-values (resp _log) (capture-stderr (lambda () (server-error-response SQL-EXN "rid-1"))))
  (define b (body-of resp))
  (check-equal? (response-code resp) 500)
  (check-false (string-contains? b "INSERT") "the statement must not reach the caller")
  (check-false (string-contains? b "constraint") "nor the engine's wording")
  (check-false (string-contains? b "users") "nor the table")
  (check-true (string-contains? b "internal error")))

(test-case "…and no document content either, which is the half that matters"
  ;; a template placeholder and an extracted value are both CONTENT. #83 sealed
  ;; the stored copies of exactly these messages; the wire is the other copy.
  ;; (The second fixture's shape is invented — see the note at its definition.)
  (for ([e (in-list (list RENDERER-EXN EXTRACT-EXN))]
        [needle (in-list '("patient_name" "444-55-6666"))])
    (define-values (resp _l) (capture-stderr (lambda () (server-error-response e "rid-2"))))
    (check-false (string-contains? (body-of resp) needle)
                 (format "~a must not be in a 500 body" needle))))

(test-case "the request id IS in the body, because a 500 without one is unactionable"
  (define-values (resp _l) (capture-stderr (lambda () (server-error-response SQL-EXN "rid-3"))))
  (check-true (string-contains? (body-of resp) "rid-3"))
  (check-true (string-contains? (body-of resp) "request_id")))

(test-case "the message is NOT lost — it goes to the log, joined by that id"
  ;; the whole argument for this change is that the diagnostic survives. A
  ;; version that merely dropped the message would pass every check above.
  (define-values (_r log) (capture-stderr (lambda () (server-error-response SQL-EXN "rid-4"))))
  (check-true (string-contains? log "rid-4") "the id joins the body to the log")
  (check-true (string-contains? log "INSERT INTO users") "…and the operator still gets the detail"))

(test-case "a non-exn value does not take the handler down with it"
  ;; `exn:fail?` is what `handle` catches, but this is called with whatever was
  ;; raised; a raise of a non-exn must still produce a response.
  (define-values (resp log) (capture-stderr (lambda () (server-error-response 'something-odd "rid-5"))))
  (check-equal? (response-code resp) 500)
  (check-true (string-contains? log "something-odd")))

(test-case "request-id-of honours an inbound X-Request-Id, else mints one"
  (define (req-with . hs)
    (request #"GET" (string->url "http://x/y") hs (delay #f) #f "1.2.3.4" 80 "127.0.0.1"))
  (check-equal? (request-id-of (req-with (make-header #"X-Request-Id" #"from-proxy"))) "from-proxy"
                "a proxy's correlation id is the one in every record")
  (define a (request-id-of (req-with)))
  (define b (request-id-of (req-with)))
  (check-true (and (string? a) (> (string-length a) 8)))
  (check-not-equal? a b "a fresh one per request")
  ;; …and a bound one wins over both, which is what makes `handle` and `with-auth`
  ;; agree instead of minting two ids for one request
  (check-equal? (parameterize ([current-request-id "bound"]) (request-id-of (req-with))) "bound"))
(require net/url racket/promise)

;; ---- what an SSE EVENT may say (#186) ---------------------------------------
;;
;; #123 closed the 500-body leak for `handle` and the STREAMING path kept it:
;; `sse-response` emitted `(exn-message e)` verbatim for every failure. By then
;; the 200 and its headers have gone, so there is no status code left to carry
;; the distinction a non-streaming refusal gets — which is why the rule has to be
;; in the event's own shape.

(test-case "a stream's failure event carries no exception message"
  (define-values (ev log) (sse-error-event (make-exn:fail "duplicate key value violates unique constraint \"users_username_key\"" (current-continuation-marks)) "rid-1"))
  (check-equal? (hash-ref ev 'error) "internal error")
  (check-equal? (hash-ref ev 'request_id) "rid-1"
                "and the id, or a failed stream is unactionable")
  (check-false (regexp-match? #rx"users_username_key" (jsexpr->string ev))
               "the constraint name must not reach the client")
  (check-true (and log (regexp-match? #rx"users_username_key" log) #t)
              "…and the operator's copy keeps it, or the diagnostic is lost"))

(test-case "a DELIBERATE refusal keeps its message, as it does off the stream"
  ;; The detail is the point of refusing rather than ignoring — the same call
  ;; `handle` makes for `exn:fail:user?`, and the two deliberate refusals #123
  ;; found ("no model configured", "input 'x' is required") are both reachable
  ;; from a streaming chat.
  (define-values (ev log)
    (sse-error-event (with-handlers ([exn:fail:user? values])
                       (raise-user-error 'run-chat "no model configured"))
                     "rid-2"))
  (check-true (and (regexp-match? #rx"no model configured" (hash-ref ev 'error)) #t))
  (check-false log "a caller's own mistake is not an operator's incident")
  (check-false (hash-has-key? ev 'request_id)
               "and it needs no id, because the message is the answer"))

(test-case "a forbidden refusal is LOCALIZED, not the raw exception"
  ;; The localizer is one of the two parameters that did not cross into the SSE
  ;; body before #186, so this message was the instance default's whatever the
  ;; caller asked for — and before that it was the raw `exn-message`.
  (define-values (ev log)
    (sse-error-event (exn:fail:forbidden "feature chat is disabled" (current-continuation-marks) "chat:use")
                     "rid-3"))
  (check-false log)
  (check-false (regexp-match? #rx"feature chat is disabled" (hash-ref ev 'error))
               "the struct's own message is internal; the localized one is the answer")
  (check-true (string? (hash-ref ev 'error))))

(test-case "the ORDER is the subtype order, and a control proves it matters"
  ;; `exn:fail:user` is a subtype of `exn:fail` and `exn:fail:forbidden` is
  ;; another — classified with the generic arm first, every deliberate refusal
  ;; would come back as "internal error" and the caller would be told nothing.
  ;; PULL-14's lesson, met in a second file.
  (define-values (gen _l1) (sse-error-event (make-exn:fail "boom" (current-continuation-marks)) "r"))
  (define-values (usr _l2) (sse-error-event (with-handlers ([exn:fail:user? values])
                                              (raise-user-error 'x "say this"))
                                            "r"))
  (check-equal? (hash-ref gen 'error) "internal error")
  (check-true (and (regexp-match? #rx"say this" (hash-ref usr 'error)) #t))
  (check-false (equal? (hash-ref gen 'error) (hash-ref usr 'error))
               "the two classes must not collapse into one answer"))
