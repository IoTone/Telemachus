#lang racket/base

;; domain/idem/idem.rkt — idempotency keys (issue #90).
;;
;; `POST /api/workflows/<slug>/run` was not idempotent: a client that timed out
;; and retried started a SECOND run on the same object. For an integrator driving
;; Telemachus from a queued worker — which is the shape the issue describes — a
;; retry is not an unusual event, it is the normal one.
;;
;; THE CONTRACT. Same key + same team + same payload within the window returns the
;; ORIGINAL response and its ORIGINAL status code, byte for byte. Same key with a
;; DIFFERENT payload is a 409: the client has reused a key for a different
;; request, and answering either request would be wrong — replaying the first
;; hides the second, performing the second breaks the promise the key made.
;;
;; WHY THE RESPONSE IS STORED AND NOT RECOMPUTED. The point of a retry is that
;; the client never saw the first answer. Recomputing it would mean deciding, for
;; every endpoint, what "the same answer again" is — and for a run that has since
;; finished it is a DIFFERENT answer, which is exactly the confusion a retrying
;; client cannot afford. The stored bytes are the only thing that is certainly
;; what the first call said.
;;
;; THE KEY IS SCOPED TO THE TEAM, NOT TO THE ENDPOINT. One key is one request. A
;; client that sends the same key to two different endpoints has made a mistake,
;; and a 409 says so; scoping per endpoint would silently accept it and leave two
;; records claiming the same key. (Stripe scopes per account for the same reason.)

(require db-kit/portable json racket/string
         (only-in sha2-kit sha256-hex))

(provide idem-lookup idem-store! idem-reap! idem-fingerprint IDEM-WINDOW-SECONDS)

;; 24 hours, as r1 specifies. A key outside the window is a MISS, not a conflict:
;; after a day the client is not retrying, it is making a new request, and
;; refusing it would be worse than performing it.
(define IDEM-WINDOW-SECONDS (* 24 60 60))

;; The payload's identity. An ordered LIST through `jsexpr->string` would carry
;; hash iteration order, which is not stable across processes — the trap that
;; makes `json-out` sort and AUD-13 use a list — so the fingerprint CANONICALIZES
;; first: keys sorted, recursively. Two requests that differ only in the order
;; their JSON object was written are the same request, and must not 409.
(define (canon x)
  (cond
    [(hash? x) (for/list ([k (in-list (sort (hash-keys x) symbol<?))])
                 (list (symbol->string k) (canon (hash-ref x k))))]
    [(list? x) (map canon x)]
    [(or (string? x) (number? x) (boolean? x)) x]
    [(eq? x 'null) 'null]
    [else (format "~a" x)]))

(define (idem-fingerprint endpoint payload)
  (sha256-hex (string->bytes/utf-8 (jsexpr->string (list endpoint (canon payload))))))

;; -> (hasheq 'hit response-jsexpr 'code n) | 'conflict | #f
;;
;; The three answers are distinct because the caller says something different
;; about each: replay this, refuse this, or go ahead. A boolean could not.
(define (idem-lookup conn team key endpoint fingerprint)
  (define r (query-maybe-row conn
    (string-append "SELECT fingerprint, response, status_code FROM idempotency_keys "
                   "WHERE team_id = ? AND key = ? AND created_epoch > ?")
    team key (- (current-seconds) IDEM-WINDOW-SECONDS)))
  (cond
    [(not r) #f]
    [(not (equal? (vector-ref r 0) fingerprint)) 'conflict]
    [else
     (hasheq 'hit (with-handlers ([exn:fail? (lambda (_) (hasheq))])
                    (string->jsexpr (vector-ref r 1)))
             'code (vector-ref r 2))]))

;; Stored AFTER the work succeeded, and deliberately not before.
;;
;; A row written first would make a crash mid-request permanent: the client
;; retries, gets the stored answer for work that never happened, and nothing
;; ever runs. A row written last means a crash mid-request leaves no key, the
;; retry does the work, and the worst case is the DOUBLE EXECUTION this feature
;; exists to prevent — which is the pre-existing behaviour, not a new failure.
;; Narrowing that window needs a two-phase record and is not built; the trade is
;; named here rather than discovered.
;;
;; The insert is `ON CONFLICT DO NOTHING`: two concurrent retries can both get
;; past the lookup, and the loser must not fail the request it has already
;; performed.
(define (idem-store! conn team key endpoint fingerprint response code)
  (query-exec conn
    (string-append "INSERT INTO idempotency_keys "
                   "(team_id, key, endpoint, fingerprint, response, status_code, created_epoch) "
                   "VALUES (?, ?, ?, ?, ?, ?, ?) "
                   "ON CONFLICT (team_id, key) DO NOTHING")
    team key endpoint fingerprint (jsexpr->string response) code (current-seconds)))

;; r4: "keys stored with the response for replay, purged with the retention
;; policy". They are purged on their OWN window rather than by a team's retention
;; rule, because a key past 24h is not retained data — it is dead weight that can
;; never be replayed, and a team that configured no retention policy would
;; otherwise accumulate it for ever. The stored response may name a document, so
;; keeping it longer than it can be used is a copy with no purpose.
(define (idem-reap! conn)
  (define r (query conn
    "DELETE FROM idempotency_keys WHERE created_epoch <= ? RETURNING key"
    (- (current-seconds) IDEM-WINDOW-SECONDS)))
  (if (rows-result? r) (length (rows-result-rows r)) 0))
