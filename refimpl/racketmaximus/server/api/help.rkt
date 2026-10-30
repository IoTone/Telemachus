#lang racket/base

;; server/api/help.rkt — the in-product help endpoint (#183 slice 2).
;;
;; `POST /api/help {question, locale?, limit?}` → an answer that cites, or a
;; closed REASON saying why it could not be given. One route; the whole of the
;; decision is in `domain/help/answer.rkt`.
;;
;; `chat:use`, which is VEC‑35's rule arriving at a second asker: this is the
;; only kind of question here that spends the team's AI allowance, because the
;; question must be embedded by the same checkpoint the corpus is of AND then
;; answered by a model. The corpus itself needs no permission (HELP‑7) — it is
;; the manual for the software the caller is signed in to — so the permission is
;; about the spending and not about the documents.

(provide ep-help)

(require json
         (only-in "../../domain/authz/authz.rkt" require-perm)
         web-kit
         db-kit/portable
         racket/string
         (only-in "../../domain/i18n/policy.rkt" i18n-policy)
         (only-in "../../domain/help/answer.rkt" help-answer)
         (only-in "../../domain/ai/executor.rkt" embed-configured?)
         (only-in "../../domain/help/helpsearch.rkt" HELP-K)
         "../kit.rkt")

(define (ep-help req)
  (with-auth req (lambda (p)
    ;; The permission the route table DECLARES, enforced here — the table is
    ;; documentation and the handler is the enforcement (#110 r2's rule), and
    ;; `test/route-perm-gate-tests.rkt` is what found this missing on the first
    ;; run rather than after it shipped. `chat:use`, which is about the SPENDING:
    ;; a question costs one embedding and one completion. The corpus itself needs
    ;; no permission (HELP-7).
    (require-perm db-conn p "chat:use")
    (define b (read-json-body req))
    (define q (hash-ref b 'question #f))
    (define lim (let ([v (hash-ref b 'limit #f)]) (if (exact-positive-integer? v) v HELP-K)))
    (cond
      [(not (and (string? q) (> (string-length (string-trim q)) 0)))
       (err "question required" 400)]
      [else
       ;; HELP‑20 — THE LOCALE IS THE REQUEST'S, resolved by the one rule the rest
       ;; of the platform resolves it by (`X-Telemachus-Locale` →
       ;; `Accept-Language` → the instance default), with an explicit `locale` in
       ;; the body winning because a help panel may legitimately ask in a language
       ;; the browser is not configured for. The FALLBACK is the instance default
       ;; rather than a literal "en": a Japanese-default instance must not fall
       ;; back to English, which is the mistake `resolve-locale` itself had to
       ;; stop making.
       (define policy (i18n-policy db-conn (locales-dir)))
       (define asked (let ([v (hash-ref b 'locale #f)]) (and (string? v) (> (string-length v) 0) v)))
       (define loc (or asked (request-locale req)))
       (define rep (help-answer db-conn p q
                                #:locale loc
                                #:fallback-locale (hash-ref policy 'default)
                                #:k lim))
       (json-response
        (hasheq 'answer (hash-ref rep 'answer)
                'citations (hash-ref rep 'citations)
                ;; The passages are returned too, and that is deliberate: the
                ;; citation names a path and a character range, so a panel that
                ;; wants to SHOW what the answer was built from needs the text it
                ;; was built from rather than a second request to fetch it. It is
                ;; also what a `no-model` instance gets instead of an answer.
                'passages (for/list ([x (in-list (hash-ref rep 'passages))])
                            (hasheq 'path (hash-ref x 'path)
                                    'title (hash-ref x 'title)
                                    'heading (hash-ref x 'heading)
                                    'start (hash-ref x 'start)
                                    'end (hash-ref x 'end)
                                    'score (hash-ref x 'score)
                                    'text (hash-ref x 'text)))
                'locale (hash-ref rep 'locale)
                'asked_locale loc
                'model (hash-ref rep 'model)
                'scanned (hash-ref rep 'scanned)
                'score (hash-ref rep 'score)
                'tokens (hash-ref rep 'tokens)
                ;; QUOTA‑3's rule: the key carries a reason only when there is
                ;; one. A caller branches on its ABSENCE to mean "answered".
                'reason (or (hash-ref rep 'reason) 'null)
                'invented_citations (hash-ref rep 'invented_citations '())))]))))

