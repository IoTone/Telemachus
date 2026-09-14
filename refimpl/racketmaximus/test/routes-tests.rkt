#lang racket/base

;; test/routes-tests.rkt — the declared route table's matcher (slice 60).
;;   raco test test/routes-tests.rkt
;;
;; The table is data; this is the one piece of code under it. What has to hold:
;; literal, `:name` and `*name` segments match as documented, first match wins in
;; list order, and — the one that shipped broken — `*name` matches an EMPTY rest,
;; because /beta/bundle/<plugin>/ is how a Tier-B bundle's index.html is reached.

(require rackunit racket/list "../server/routes.rkt")

(define (m method path)
  (define-values (r params) (match-route method (cdr (regexp-split #rx"/" path))))
  (and r (cons (rt-handler r) params)))

(check-equal? (m "GET" "/health") '(health))
(check-equal? (m "GET" "/") '(ui) "the root is the console")
(check-equal? (m "GET" "/api/repo-obj/abc/grants") '(repo-grants "abc"))
(check-equal? (m "GET" "/api/workflows/schema") '(workflow-schema) "the literal beats the :slug below it")
(check-equal? (m "GET" "/api/workflows/process-upload") '(workflow-get "process-upload"))
(check-equal? (m "PUT" "/api/repo/inbox/2026/acme.pdf") '(repo-put "inbox/2026/acme.pdf") "*key takes the rest, joined")
(check-equal? (m "GET" "/beta/bundle/beta-onboarding/app.js") '(bundle-file "beta-onboarding" "app.js"))
(check-equal? (m "GET" "/beta/bundle/beta-onboarding/") '(bundle-file "beta-onboarding" "")
              "a trailing slash is the bundle root: *path matches an EMPTY rest")
(check-equal? (m "GET" "/beta/bundle/beta-onboarding") '(bundle-file "beta-onboarding" "")
              "…with or without the slash")
(check-false (m "DELETE" "/health") "the method is part of the match")
(check-false (m "GET" "/api/nope") "an unknown path is no match")
(check-equal? (m "PUT" "/api/repo") '(repo-put "")
              "an empty *key reaches the upload handler, which refuses it as an invalid key (400, not 404)")
(check-equal? (m "GET" "/api/repo") '(repo-list))

;; every entry's handler key is unique to its (method, path) — a duplicate path
;; would be dead code below the first, and a duplicate key is fine (org-suspend and
;; org-resume are one handler with a literal), so check paths
(define seen (make-hash))
(for ([r (in-list ROUTES)])
  (define k (cons (rt-method r) (rt-path r)))
  (check-false (hash-ref seen k #f) (format "duplicate route ~a ~a" (rt-method r) (rt-path r)))
  (hash-set! seen k #t))
;; and every entry carries a description — api.md is rendered from it
(for ([r (in-list ROUTES)])
  (check-true (and (string? (rt-doc r)) (> (string-length (rt-doc r)) 0))
              (format "~a ~a has no doc" (rt-method r) (rt-path r))))
