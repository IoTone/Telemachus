#lang racket/base

;; test/route-perm-gate-tests.rkt — does every route ENFORCE the permission it
;; DECLARES?
;;
;;   raco test test/route-perm-gate-tests.rkt
;;
;; WHY THIS EXISTS. `server/routes.rkt` carries a `#:perm` per route and the
;; dispatcher does not use it: `route` reads `rt-handler` and nothing else. Auth,
;; permission and feature are enforced by each handler BY HAND, and the table's
;; own comment says so — "the permission is the one the handler ENFORCES with
;; require-perm on its main path". Nothing checked that the two agreed, so
;; `#:perm` was a comment living in a struct field, and `docs/reference/api.md`
;; published it as fact.
;;
;; It was wrong once, and this check is what found it: `GET /api/retention`
;; declared `files:read` and enforced NOTHING — `with-auth` and straight to the
;; data, so any authenticated member could read the team's, the company's and the
;; INSTANCE's retention policy. Its sibling two definitions below,
;; `ep-retention-plan-get`, had the line.
;;
;; HOW IT READS THE CODE. Through Racket's own reader, not a regex: each module is
;; read as a module form and walked as DATA. The first version of this file
;; counted parentheses, got 83 top-level forms out of ~1600, and passed its way to
;; a wrong answer — which the "can the walk find a permission that IS enforced"
;; assertion below caught, and which is why that assertion is here.
;;
;; The walk is a call graph by NAME, bounded to DEPTH levels, over main.rkt and
;; every module under domain/ and pkgs/. That is an approximation, and it is sound
;; in the direction that matters: a permission enforced somewhere this cannot
;; reach by name would be a false PASS, never a false failure. So the gate cannot
;; cry wolf and block a correct change — it catches the real class, a route whose
;; permission appears nowhere.

(require rackunit racket/list racket/string racket/set racket/path
         "../server/routes.rkt")

;; ---- reading a module as data ----------------------------------------------------
(define (module-body path)
  (define form
    (with-input-from-file path
      (lambda ()
        (parameterize ([read-accept-reader #t] [read-accept-lang #t])
          (read)))))
  ;; (module NAME LANG (#%module-begin body ...)) — or (module NAME LANG body ...)
  (cond
    [(and (pair? form) (eq? (car form) 'module))
     (define rest (cdddr form))
     (if (and (= 1 (length rest)) (pair? (car rest)) (eq? (caar rest) '#%module-begin))
         (cdr (car rest))
         rest)]
    [else '()]))

(define (rkt-files-under dir)
  (cond
    [(not (directory-exists? dir)) '()]
    [else
     (for/fold ([acc '()]) ([e (in-list (directory-list dir))])
       (define p (build-path dir e))
       (cond
         [(and (file-exists? p) (regexp-match? #rx"[.]rkt$" (path->string e))) (cons p acc)]
         [(and (directory-exists? p) (not (equal? (path->string e) "compiled")))
          (append (rkt-files-under p) acc)]
         [else acc]))]))

(define SOURCES
  (cons (build-path 'up "server" "main.rkt")
        (append (rkt-files-under (build-path 'up "domain"))
                (rkt-files-under (build-path 'up "pkgs")))))

;; name (symbol) -> list of body datums, for every (define (name . args) body ...)
(define DEFS
  (for*/fold ([acc (hash)])
             ([f (in-list SOURCES)]
              [form (in-list (module-body f))])
    (cond
      [(and (pair? form) (memq (car form) '(define define-syntax-rule))
            (pair? (cadr form)) (symbol? (car (cadr form))))
       (hash-update acc (car (cadr form)) (lambda (old) (cons (cddr form) old)) '())]
      [else acc])))

;; every string literal and every called name in a body, found by walking the datum
(define (walk datum)
  (let loop ([d datum] [strs '()] [names '()])
    (cond
      [(string? d) (values (cons d strs) names)]
      [(pair? d)
       (define-values (s1 n1)
         (if (symbol? (car d)) (values strs (cons (car d) names)) (values strs names)))
       (for/fold ([s s1] [n n1]) ([x (in-list (if (list? d) d (list (car d))))])
         (loop x s n))]
      [else (values strs names)])))

(define WALKED
  (for/hash ([(name bodies) (in-hash DEFS)])
    (define-values (strs names)
      (for/fold ([ss '()] [ns '()]) ([b (in-list bodies)])
        (define-values (s n) (walk b))
        (values (append s ss) (append n ns))))
    (values name (cons (list->set strs) (remove-duplicates names)))))

(define DEPTH 4)

;; `name` is a symbol (a named definition) or a BODY — the datums of an inline
;; lambda from the HANDLERS table.
(define (enforces? name perm [depth DEPTH] [seen (set)])
  (define e
    (cond
      [(symbol? name) (hash-ref WALKED name #f)]
      [else (let-values ([(strs names) (walk name)])
              (cons (list->set strs) (remove-duplicates names)))]))
  (cond
    [(or (zero? depth) (not e) (and (symbol? name) (set-member? seen name))) #f]
    [(set-member? (car e) perm) #t]
    [else
     (define seen* (if (symbol? name) (set-add seen name) seen))
     (for/or ([callee (in-list (cdr e))]) (enforces? callee perm (sub1 depth) seen*))]))

;; the HANDLERS table in main.rkt, read as data: 'key -> 'ep-fn
(define HANDLER-OF
  (let ()
    (define tbl
      (for/or ([form (in-list (module-body (build-path 'up "server" "main.rkt")))])
        (and (pair? form) (eq? (car form) 'define) (eq? (cadr form) 'HANDLERS)
             (let ([h (caddr form)]) (and (pair? h) (eq? (car h) 'hasheq) (cdr h))))))
    (let loop ([xs (or tbl '())] [acc (hash)])
      (cond
        [(or (null? xs) (null? (cdr xs))) acc]
        [else
         (define k (car xs)) (define v (cadr xs))
         (loop (cddr xs)
               (cond
                 [(not (and (pair? k) (eq? (car k) 'quote))) acc]
                 [(symbol? v) (hash-set acc (cadr k) v)]
                 ;; Eleven entries are an INLINE lambda rather than a named
                 ;; handler (`'org-suspend (lambda (req ref) …)`). Walking the
                 ;; lambda in place is the honest reading — the alternative, a
                 ;; two-route exemption, would have excused exactly the two
                 ;; routes nobody looks at.
                 [(and (pair? v) (eq? (car v) 'lambda)) (hash-set acc (cadr k) (cddr v))]
                 [else acc]))]))))

(define declared (for/list ([r (in-list ROUTES)] #:when (rt-perm r)) r))

;; ---- the gate's own inputs, asserted FIRST --------------------------------------
;; A gate whose inputs came back empty passes while checking nothing. That shape
;; of mistake has appeared three times in this repo's test history (an undefined
;; `refute`, a vacuous payload assertion, `gh run watch` 404ing while exiting 0),
;; and it is what the first version of THIS file did.
(test-case "the gate's inputs are present, and the walk can find what it should"
  (check-true (> (length declared) 100) (format "routes declaring a perm: ~a" (length declared)))
  (check-true (> (hash-count HANDLER-OF) 150) (format "HANDLERS entries read: ~a" (hash-count HANDLER-OF)))
  (check-true (> (hash-count DEFS) 1000) (format "function definitions read: ~a" (hash-count DEFS)))
  ;; a permission enforced directly in a handler
  (check-true (enforces? 'ep-retention-put "settings:manage") "direct require-perm in the handler")
  ;; one enforced through a main.rkt-local wrapper (with-org)
  (check-true (enforces? 'ep-org-get "instance:manage") "through with-org")
  ;; one enforced a layer down, in the domain module
  (check-true (enforces? 'ep-notes-get "notes:read") "through notes-get in the domain")
  ;; and a permission that is genuinely nowhere must NOT be claimed as found
  (check-false (enforces? 'ep-retention-put "no-such:permission") "the walk does not invent matches"))

(test-case "every route ENFORCES the permission it declares"
  (define missing
    (for/list ([r (in-list declared)]
               #:unless (let ([fn (hash-ref HANDLER-OF (rt-handler r) #f)])
                          (and fn (enforces? fn (rt-perm r)))))
      (format "~a ~a declares ~s — not enforced anywhere reachable from ~a"
              (rt-method r) (rt-path r) (rt-perm r)
              ;; the message names the handler, or the route key for an inline one
              (let ([h (hash-ref HANDLER-OF (rt-handler r) #f)])
                (if (symbol? h) h (rt-handler r))))))
  (check-equal? missing '()
                (string-append "\n  " (string-join missing "\n  "))))
