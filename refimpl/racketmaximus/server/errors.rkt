#lang racket/base

;; server/errors.rkt — what a request is allowed to say when it fails (#123).
;;
;; THIS MODULE INSTANTIATES NO CONNECTION POOL, deliberately, and that is the
;; whole reason it exists separately from server/kit.rkt. The rule below was put
;; in kit first, with a comment claiming it was "unit-testable without a live
;; server" — and it was not: requiring kit instantiates the connection POOL,
;; which reads DATABASE_URL at module instantiation. CI's SQLite leg sets that
;; variable to the EMPTY STRING, so the test failed there with
;; `db-connector: unsupported DATABASE_URL` while passing on every machine where
;; the variable happens to be unset or valid. peer.rkt and startup.rkt are free
;; of the domain for exactly this reason; this is the third module to need it.
;;
;; The requires below are modules that take a connection as an ARGUMENT and open
;; none at instantiation, which is the property that matters — the header used to
;; say "no database", which was a stricter claim than the rule and would have
;; forced the SSE classification (#186) back into kit, where it could not be
;; tested.

(provide req-header current-request-id request-id-of server-error-response
         sse-error-event)

(require web-server/http
         web-kit
         (only-in "../domain/db/id.rkt" new-id)
         (only-in "../domain/authz/authz.rkt" exn:fail:forbidden? exn:fail:forbidden-permission)
         (only-in "../surface/messages.rkt" msg-forbidden))

;; case-insensitive, and the one place a header is read as a string
(define (req-header req name-bytes)
  (define h (headers-assq* name-bytes (request-headers/raw req)))
  (and h (bytes->string/utf-8 (header-value h))))

;; ---- one request id per request ---------------------------------------------
;; Precedence stated ONCE: a bound id (so `handle` and `with-auth` agree instead
;; of minting two for one request), then an inbound `X-Request-Id` so a proxy's
;; correlation id is the one in every record, then a fresh one.
(define current-request-id (make-parameter #f))
(define (request-id-of req)
  (or (current-request-id)
      (and req (req-header req #"x-request-id"))
      (new-id)))

;; ---- what a 500 may say -----------------------------------------------------
;; `handle` used to answer `(err (exn-message e) 500)`, so EVERY unhandled
;; exception's message became the response body. The duplicate-username INSERT is
;; how that was reported (#123) and SQL is the least of it: #83 r4 sealed four
;; stored `error` columns precisely because this platform's own code quotes what
;; it choked on — the strict renderer names the missing placeholder, DWF-5's
;; extraction names the JSON path AND the offending value, the knowledge-graph
;; extractor refuses a snippet that is not a verbatim substring and quotes it.
;; That reasoning applies unchanged to a response body, and the wire had never
;; been looked at.
;;
;; So the body carries a generic refusal and a REQUEST ID, and the message goes
;; to the log where an operator can find it by that id — which keeps the
;; diagnostic that putting the message in the body was buying.
;;
;; `exn:fail:user?` and `exn:fail:spec?` keep their messages deliberately: those
;; are the caller's own mistake and the detail is the point of refusing rather
;; than ignoring.
(define (server-error-response e rid)
  ;; the operator's copy. stderr, not the body: a container's log is where this
  ;; is read, and the request id is what joins the two.
  (eprintf "ERROR [~a] ~a\n" rid (if (exn? e) (exn-message e) e))
  (json-response (hasheq 'error "internal error"
                         ;; quote this id to an operator and they can find the
                         ;; message; without it a 500 is unactionable
                         'request_id rid)
                 #:code 500))

;; ---- what an SSE EVENT may say (#186) ---------------------------------------
;; #123 closed the 500-body leak and the streaming path kept it. `sse-response`
;; emitted `(exn-message e)` verbatim, to the client, for every failure — and by
;; then the 200 and its headers have already gone, so there is no status code
;; left to carry the distinction a non-streaming refusal gets from `handle`.
;;
;; Same classification and the same ORDER as `handle`'s: a DELIBERATE refusal
;; keeps its message, because that detail is the point of refusing rather than
;; ignoring, and anything else is generic plus a request id. `exn:fail:user` is a
;; subtype of `exn:fail` and the first matching clause wins, which is why this is
;; a `cond` over predicates in one place rather than a handler list spelled twice
;; (PULL-14's ordering lesson, met in a second file).
;;
;; `exn:fail:spec?` is NOT among them, and that is a measured omission rather
;; than a gap: the only two streaming endpoints are chat and the agent, and a
;; refused workflow spec cannot arise on either. It would be one more clause the
;; day one does.
;;
;; -> (values jsexpr log-message-or-#f). The caller logs, because only it holds
;; the port and the id it is going to emit.
(define (sse-error-event e rid)
  (cond
    [(exn:fail:forbidden? e)
     (values (hasheq 'error (msg-forbidden (exn:fail:forbidden-permission e))) #f)]
    [(exn:fail:user? e) (values (hasheq 'error (exn-message e)) #f)]
    [else
     (values (hasheq 'error "internal error" 'request_id rid)
             (if (exn? e) (exn-message e) (format "~a" e)))]))
