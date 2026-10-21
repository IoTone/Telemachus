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
         "../server/routes.rkt"
         "../domain/authz/permissions.rkt")

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

;; EVERY module under server/, not main.rkt by name. #110 r3 moved the handlers
;; out of main.rkt into server/api/*.rkt and the shared wrappers into
;; server/kit.rkt, so a named-file list would have gone on passing while walking
;; a module that no longer holds the handler bodies — the shape of false PASS
;; this gate exists to avoid. The HANDLERS table is still read from main.rkt by
;; name below, because that table is what main.rkt keeps.
(define SOURCES
  (append (rkt-files-under (build-path 'up "server"))
          (rkt-files-under (build-path 'up "domain"))
          (rkt-files-under (build-path 'up "pkgs"))))

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

;; ---- #110 r2: the scope the dispatcher acts on ----------------------------------
;; `dispatch` pre-checks a route's permission when `rt-scope` is 'role and leaves
;; it alone when it is 'resource, because a role-level pre-check on a resource
;; permission is STRICTER than the handler's own `can?` — which also admits the
;; owner and anyone holding a grant (DSH-1). So the classification is a security
;; decision per route, and these are its invariants.
(test-case "scope is a closed vocabulary, and only means something with a permission"
  (for ([r (in-list ROUTES)])
    ;; check-not-false, not check-true: `memq` answers the TAIL, and check-true
    ;; wants exactly #t — the trap CLAUDE.md records from the OCR slice
    (check-not-false (memq (rt-scope r) '(role resource))
                     (format "~a ~a has scope ~s" (rt-method r) (rt-path r) (rt-scope r)))
    (unless (rt-perm r)
      (check-eq? (rt-scope r) 'role
                 (format "~a ~a declares no permission, so 'resource says nothing"
                         (rt-method r) (rt-path r))))))

(test-case "a resource-scoped route names a resource (or is the documented exception)"
  ;; The rule is "is the real check per-row `can?` or the role" — and a path with
  ;; no parameter has no row to weigh. The one exception is the prefix delete,
  ;; which fans out over many objects and checks each: a role pre-check there
  ;; would refuse a caller whose grants cover the objects their role does not.
  (define odd
    (for/list ([r (in-list ROUTES)]
               #:when (and (eq? (rt-scope r) 'resource)
                           (not (regexp-match? #rx":|[*]" (rt-path r)))
                           (not (and (equal? (rt-method r) "DELETE")
                                     (equal? (rt-path r) "/api/repo")))))
      (format "~a ~a" (rt-method r) (rt-path r))))
  (check-equal? odd '()))

(test-case "the routes the dispatcher pre-checks are the ones a role decides"
  ;; A sanity bound rather than a re-derivation: if this count moves a long way,
  ;; somebody has reclassified routes in bulk and should have thought about it.
  ;; 93 role-scoped + 30 resource-scoped at the time of writing.
  (define role-scoped
    (for/list ([r (in-list ROUTES)] #:when (and (rt-perm r) (eq? (rt-scope r) 'role))) r))
  (define resource-scoped
    (for/list ([r (in-list ROUTES)] #:when (and (rt-perm r) (eq? (rt-scope r) 'resource))) r))
  (check-true (> (length role-scoped) 80) (format "role-scoped: ~a" (length role-scoped)))
  (check-true (> (length resource-scoped) 25) (format "resource-scoped: ~a" (length resource-scoped)))
  ;; every `files:*` / `notes:*` route that names an object must be resource-scoped
  ;; — this is the direction that would be a REGRESSION if it flipped
  (define dangerous
    (for/list ([r (in-list ROUTES)]
               #:when (and (rt-perm r)
                           (regexp-match? #rx"^(files|notes):" (rt-perm r))
                           (regexp-match? #rx":id|:slug|[*]key" (rt-path r))
                           (eq? (rt-scope r) 'role)))
      (format "~a ~a declares ~a at ROLE scope — a grant would stop admitting"
              (rt-method r) (rt-path r) (rt-perm r))))
  (check-equal? dangerous '()))


;; ---- the OTHER direction: is every granted permission reachable? (issue #113) ----
;;
;; The check above asks "is the permission a route DECLARES enforced?". It cannot
;; see the opposite failure, and that one shipped: `quota:manage` is granted to
;; the team owner and to both company-admin roles, no route declared it, nothing
;; read it, and `POST /api/quota` demanded `instance:manage` instead — so a team
;; that hit its 2,000-token daily default could be unblocked only by the instance
;; operator. Reported from outside as issue #113, a year after the permission was
;; written into the catalog.
;;
;; A granted permission nothing enforces is a promise the role listing makes and
;; the server does not keep, and `GET /api/roles` publishes it. So: every
;; permission in the catalog must be enforced somewhere reachable from a route's
;; handler, or be listed here WITH A REASON.
;;
;; The list fails in BOTH directions — an unreachable permission that is not
;; listed, and a listed permission that has since become reachable — which is the
;; shape `scripts/check-config-reference.sh` already uses for the configuration
;; reference. A one-directional allowlist rots into a list of excuses.
(define UNREACHABLE-BY-DESIGN
  (hash
   ;; Documented as granted-and-inert. RBAC-5b: custom team roles are not in v1,
   ;; and the permission's own description says so, which is the condition for
   ;; leaving it in the catalog at all.
   "roles:manage"    "RBAC-5b: custom team roles are not in v1; its description says so"
   "roles:read"      "the role catalog is public to any authenticated caller; nothing gates it"
   ;; Features that have no implementation at all. The permission exists so the
   ;; role data does not have to change when they are built.
   "tasks:read"      "no task subsystem is built"
   "tasks:write"     "no task subsystem is built"
   "tasks:delete"    "no task subsystem is built"
   "memory:read"     "no memory subsystem is built"
   "memory:write"    "no memory subsystem is built"
   "research:use"    "no research surface is built; chat:use gates the model paths"
   "models:serve"    "no inbound model-serving surface is built; executors are configured, not served"
   "webhooks:manage" "outbound webhooks are issue #85, unbuilt"
   ;; The company plane uses its OWN tier (`org:read` / `org:manage`) rather than
   ;; the team-tier permission a company admin also happens to hold — see the
   ;; routes under /api/org. These three are the team-tier spellings that the
   ;; plane does not use. Keeping them granted costs nothing and removing them
   ;; would be a role change; what matters is that no route silently depends on
   ;; one while declaring another.
   "team:read"       "the company plane gates team reads with org:read"
   "team:write"      "the company plane gates team writes with org:manage"
   "features:manage" "the feature switches gate on settings:manage / instance:manage / org:manage (#63)"
   "quota:read"      "GET /api/usage is deliberately ungated: a plain member does NOT hold quota:read, and declaring it would stop them reading their own team's usage"
   ;; Vestigial since migration 0022 folded the `documents` table into the
   ;; repository: a text document IS a repo object, so /api/documents/* enforces
   ;; `files:read` / `files:write` / `files:delete`. Worth knowing that this is
   ;; NOT purely cosmetic — these three are offered in the API-token SCOPE
   ;; vocabulary too, and a token scoped to `documents:write` is capped away from
   ;; the only routes that write a document. Retiring them, or mapping them onto
   ;; the `files:*` triple, is its own decision; what this entry buys is that the
   ;; situation is written down instead of inferred.
   "documents:read"   "the 0022 fold: /api/documents/* enforces files:read"
   "documents:write"  "the 0022 fold: /api/documents/* enforces files:write"
   "documents:delete" "the 0022 fold: /api/documents/* enforces files:delete"
   ;; No route deletes a team, deliberately — the same call TEN-2g makes for
   ;; companies (`there is no DELETE /api/orgs`). The permission is what `*:*`
   ;; would reach if one were ever built.
   "team:delete"      "no team-delete route exists, as TEN-2g decided for orgs"))

(test-case "every permission the catalog grants is enforced somewhere, or is listed with a reason"
  (define (reachable? perm)
    (for/or ([r (in-list ROUTES)])
      (define fn (hash-ref HANDLER-OF (rt-handler r) #f))
      (and fn (enforces? fn perm))))
  ;; A WILDCARD is excluded, not excused. `*:*`, `*:read`, `instance:*` and
   ;; `org:*` are what a role HOLDS; `perm-matches?` expands them against what a
   ;; route REQUIRES. Asking whether one is enforced is a category error — and
   ;; the walk answers yes for the wrong reason, because it matches string
   ;; literals and `"*:*"` appears as a token SCOPE in bootstrap. So they are
   ;; partitioned out, and the partition is asserted rather than assumed.
  (define-values (wildcards catalog)
    (partition (lambda (p) (regexp-match? #rx"[*]" p)) (all-permissions)))
  (check-equal? (sort wildcards string<?) '("*:*" "*:read" "instance:*" "org:*")
                "the wildcard grants are the four known ones")
  ;; the gate's own input, first — see the note at the top of this file
  (check-true (> (length catalog) 40) (format "permissions in the catalog: ~a" (length catalog)))
  (define unreachable (filter (lambda (p) (not (reachable? p))) catalog))
  (define unlisted (filter (lambda (p) (not (hash-has-key? UNREACHABLE-BY-DESIGN p))) unreachable))
  (check-equal? unlisted '()
                (string-append "\n  granted and enforced NOWHERE:\n  "
                               (string-join unlisted "\n  ")
                               "\n  Either a route must enforce it, or add it to"
                               " UNREACHABLE-BY-DESIGN with the reason."))
  ;; and the reverse: a listed permission that IS now reachable
  (define stale
    (for/list ([(perm _reason) (in-hash UNREACHABLE-BY-DESIGN)]
               #:when (and (member perm catalog) (reachable? perm)))
      perm))
  (check-equal? (sort stale string<?) '()
                (string-append "\n  listed as unreachable but now enforced (drop the entry):\n  "
                               (string-join (sort stale string<?) "\n  ")))
  ;; a listed permission that has left the catalog entirely
  (define gone
    (for/list ([(perm _reason) (in-hash UNREACHABLE-BY-DESIGN)]
               #:unless (member perm catalog))
      perm))
  (check-equal? (sort gone string<?) '()
                (string-append "\n  listed but no longer in the catalog:\n  "
                               (string-join (sort gone string<?) "\n  "))))

;; The one the issue was about, pinned by name so a revert is loud.
(test-case "POST /api/quota is gated by quota:manage, not the operator tier (#113)"
  (define r (for/or ([r (in-list ROUTES)])
              (and (equal? (rt-method r) "POST") (equal? (rt-path r) "/api/quota") r)))
  (check-not-false r "POST /api/quota is in the table")
  (check-equal? (rt-perm r) "quota:manage")
  (check-true (enforces? (hash-ref HANDLER-OF (rt-handler r)) "quota:manage")
              "and the handler enforces it")
  ;; the company plane's per-team route, which is what an org admin uses
  (define o (for/or ([r (in-list ROUTES)])
              (and (equal? (rt-path r) "/api/org/teams/:ref/quota") r)))
  (check-not-false o "POST /api/org/teams/:ref/quota is in the table")
  (check-equal? (rt-auth o) 'org-admin)
  (check-equal? (rt-perm o) "org:manage"))
