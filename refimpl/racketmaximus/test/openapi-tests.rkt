#lang racket/base

;; test/openapi-tests.rkt — the OpenAPI 3.1 description of the route table
;; (issue #227 slice 2a).
;;
;; WHAT THIS FILE DOES NOT ESTABLISH, said first: no conforming OpenAPI validator
;; has been run against the emitted document. One is not in the Nix closure and
;; fetching one is not something a test may do, so the structural checks below are
;; written against the specification by hand — which agrees with my reading of it
;; and not with an implementation of it. Stated rather than implied, the way the
;; LibreOffice branch, veraPDF and the four feed adapters' fixtures are.
;;
;; What it DOES establish is every rule this generator decides for itself, and the
;; one that matters most is the first: a generated reference that silently
;; describes fewer routes than exist is the shape #119 was filed over, and
;; `paths` being keyed by template is exactly how that could happen.

(require rackunit racket/list racket/string racket/port json
         "../cli/telemachus-docs.rkt"
         "../server/routes.rkt"
         (only-in "../config.rkt" app-version))

;; one model for the whole file: `describe` loads the plugins
(define model (describe))
(define doc-text (render-openapi model (lambda (id en) en)))
(define doc (string->jsexpr doc-text))
(define routes (append (hash-ref model 'routes) (hash-ref model 'plugin_routes '())))

(define (ops)
  (for*/list ([(p v) (in-hash (hash-ref doc 'paths))]
              [(m o) (in-hash v)])
    (list (symbol->string p) (symbol->string m) o)))

;; ---------------------------------------------------------------------------
;; 1. every declared route is an operation, and nothing is invented
;;
;; The count is the half that bites: `paths` is keyed by template, so two routes
;; collapsing to one key would leave the document a route short with nothing
;; failing. Asserting the SET of operationIds both ways is what makes "nothing
;; invented" a check rather than a hope.
(test-case "every route in the table is an operation, and every operation is a route"
  (check-equal? (length (ops)) (length routes))
  (define declared (sort (for/list ([r (in-list routes)]) (route-key r)) string<?))
  (define emitted (sort (for/list ([o (in-list (ops))]) (hash-ref (caddr o) 'operationId)) string<?))
  (check-equal? emitted declared)
  ;; …and each one is under the template its own path produces
  (for ([r (in-list routes)])
    (define tmpl (oa-path-template (hash-ref r 'path)))
    (define m (string->symbol (string-downcase (hash-ref r 'method))))
    (define p (hash-ref (hash-ref doc 'paths) (string->symbol tmpl) #f))
    (check-true (and (hash? p) (hash-has-key? p m))
                (format "~a ~a is missing from paths" (hash-ref r 'method) tmpl))))

;; ---------------------------------------------------------------------------
;; 2. a collapse is REFUSED, and this is the only way to reach that refusal —
;;    the committed document is by definition one that did not collide.
(test-case "two routes that collapse to one operation are refused by name"
  (define (fake method path) (hasheq 'method method 'path path 'handler "h" 'auth "bearer"
                                     'permission 'null 'scope "role" 'feature 'null
                                     'description "d"))
  (define L (lambda (id en) en))
  ;; THE REALISTIC ONE: the table has two parameter forms where OpenAPI has one,
  ;; so a one-segment `:x` and a rest `*x` of the same spelling are different
  ;; routes and one template. My first version of this case used a parameter
  ;; beside a LITERAL `id`, which does not collapse — `{id}` keeps its braces —
  ;; and the failure is what corrected the comment at the definition.
  (check-exn #px"collapse to one OpenAPI operation"
             (lambda () (oa-paths (list (fake "GET" "/api/a/:x") (fake "GET" "/api/a/*x")) L)))
  ;; and a duplicated table entry
  (check-exn #px"collapse to one OpenAPI operation"
             (lambda () (oa-paths (list (fake "GET" "/api/a/:id") (fake "GET" "/api/a/:id")) L)))
  ;; a parameter and a literal are NOT a collapse, which is why the case above
  ;; had to change rather than the generator
  (check-equal? (hash-count (oa-paths (list (fake "GET" "/api/a/:id") (fake "GET" "/api/a/id")) L)) 2)
  ;; the same path with two methods is NOT a collapse — that is how OpenAPI is shaped
  (check-equal? (hash-count (hash-ref (oa-paths (list (fake "GET" "/api/a") (fake "POST" "/api/a")) L)
                                      '|/api/a|))
                2))

;; ---------------------------------------------------------------------------
;; 3. the path template, and the one parameter whose plain shape would mislead
(test-case "a pattern becomes a template, and a REST parameter says it takes the rest"
  (check-equal? (oa-path-template "/") "/")
  (check-equal? (oa-path-template "/api/notes/:id") "/api/notes/{id}")
  (check-equal? (oa-path-template "/api/repo/*key") "/api/repo/{key}")
  (check-equal? (oa-path-template "/api/x/:plugin/bundle/*path") "/api/x/{plugin}/bundle/{path}")
  ;; nothing declares a description for an ordinary path parameter, so none is invented
  (define one (car (oa-parameters "/api/notes/:id")))
  (check-equal? (hash-ref one 'name) "id")
  (check-equal? (hash-ref one 'in) "path")
  (check-true (hash-ref one 'required))
  (check-false (hash-has-key? one 'description))
  (check-false (hash-has-key? one 'x-tmach-rest))
  ;; the rest parameter is the exception, and has to be: declared as a plain
  ;; string it would say "one segment" and mean "the remainder"
  (define rest (car (oa-parameters "/api/repo/*key")))
  (check-true (hash-ref rest 'x-tmach-rest))
  (check-true (string-contains? (hash-ref rest 'description) "rest of the path"))
  (check-true (string-contains? (hash-ref rest 'description) "/"))
  ;; both parameters of a two-parameter path, in path order
  (check-equal? (map (lambda (p) (hash-ref p 'name)) (oa-parameters "/api/x/:plugin/bundle/*path"))
                '("plugin" "path")))

;; ---------------------------------------------------------------------------
;; 4. the operationId IS the localization key — one derivation, two askers
;;
;; `route-id` is a COMMITTED catalog key: it is in locales/ja.json, so a tidy-up
;; of this derivation would orphan a translated string silently. The "/" case is
;; pinned for that reason — its key really is `doc.route.get.`, trailing dot and
;; all, and `get.` is consequently its operationId.
(test-case "an operation's id is the doc.route.* message id without its prefix"
  (for ([r (in-list routes)])
    (check-equal? (route-id r) (string-append ROUTE-ID-PREFIX (route-key r))))
  (check-equal? (route-key (hasheq 'method "GET" 'path "/")) "get.")
  (check-equal? (route-id (hasheq 'method "GET" 'path "/")) "doc.route.get.")
  (check-equal? (route-key (hasheq 'method "GET" 'path "/api/repo-obj/:id/content"))
                "get.api.repo-obj.id.content"))

;; ---------------------------------------------------------------------------
;; 5. how a route authenticates
(test-case "public carries an empty requirement list and the one either-or route says either"
  (check-equal? (oa-security "public") '())
  (check-equal? (oa-security "bearer") (list (hasheq 'bearerAuth '())))
  (check-equal? (oa-security "superadmin") (list (hasheq 'bearerAuth '())))
  ;; #43: a bearer OR a bundle ticket. The EMPTY requirement object is what says
  ;; the credential is optional; one entry alone would make it mandatory.
  (define h (oa-security "handler"))
  (check-equal? (length h) 2)
  ;; `member` answers the TAIL, not #t, and check-true demands exactly #t — it
  ;; fails while printing the list that proves it right. Fifth appearance.
  (check-true (and (member (hasheq) h) #t)
              "an empty requirement object is what makes the bearer optional")
  ;; and it reaches the document
  (check-equal? (hash-ref (hash-ref (hash-ref (hash-ref doc 'paths) '|/| ) 'get) 'security) '()))

;; ---------------------------------------------------------------------------
;; 6. it promises no schemas, and the promise is CHECKED
;;
;; Both directions on purpose. The note must be present, so a future slice cannot
;; quietly start implying completeness; and the fields must be absent, so it
;; cannot carry a half-declared shape while the note still disclaims everything.
;; When 2b lands, both halves of this case are edited deliberately — which is the
;; point of pinning them.
(test-case "no request or response schemas, and the document says so"
  (define note (hash-ref (hash-ref doc 'info) 'description))
  (check-true (string-contains? note "no request or response schemas"))
  (check-true (string-contains? note "never as absent"))
  (define (walk v)
    (cond [(hash? v) (for ([(k x) (in-hash v)])
                       (check-false (memq k '(requestBody responses content))
                                    (format "the document carries ~a while promising it does not" k))
                       (walk x))]
          [(list? v) (for-each walk v)]
          [else (void)]))
  (walk (hash-ref doc 'paths)))

;; ---------------------------------------------------------------------------
;; 7. the keys are WRITTEN in sorted order
;;
;; Not a style point: a hasheq's iteration order is not stable across Racket
;; processes, so a document emitted with `write-json` would differ run to run and
;; the drift gate would cry wolf for ever (DOCGEN-6). That is a property of the
;; TEXT, not of the parsed value, so this reads the text.
(test-case "every object's keys are emitted in sorted order"
  (define last (make-hash))          ; indent -> the last key seen at it
  ;; COUNTED, because the check is over the TEXT and a control showed it could
  ;; pass vacuously: substituting `write-json` emits the whole document on ONE
  ;; line, so the line-wise scan below matched nothing at all and agreed. A
  ;; comparison count is what makes "the keys are sorted" mean "and there were
  ;; keys to sort".
  (define compared (box 0))
  (for ([line (in-list (string-split doc-text "\n"))])
    (define m (regexp-match #px"^( *)\"([^\"]*)\": " line))
    (define i (cond [m (string-length (cadr m))]
                    [else (let ([n (regexp-match #px"^( *)" line)]) (string-length (cadr n)))]))
    ;; a line at this indent closes every deeper object
    (for ([k (in-list (hash-keys last))]) (when (> k i) (hash-remove! last k)))
    (when m
      (define key (caddr m))
      (define prev (hash-ref last i #f))
      (when prev
        (set-box! compared (add1 (unbox compared)))
        (check-true (string<? prev key)
                    (format "keys out of order at indent ~a: ~s then ~s" i prev key)))
      (hash-set! last i key)))
  (check-true (> (unbox compared) 500)
              (format "only ~a sibling keys were compared — the document is not being written one key per line, so this case is not checking anything" (unbox compared))))

;; ---------------------------------------------------------------------------
;; 8. what the table declares reaches the document, including the distinction
;;    #110 r2 cost a slice to get right
(test-case "the permission and WHO checks it both survive"
  (define (op path method) (hash-ref (hash-ref (hash-ref doc 'paths) (string->symbol path)) method))
  ;; /api/retention is the route that declared a permission and enforced nothing
  ;; (#109). It has no resource to weigh, so the dispatcher pre-checks it.
  (define ret (op "/api/retention" 'get))
  (check-equal? (hash-ref ret 'x-tmach-permission) "files:read")
  (check-equal? (hash-ref ret 'x-tmach-permission-checked) "role")
  ;; the SAME permission on a route with a document to weigh, where a role
  ;; pre-check would refuse exactly what sharing exists for (DSH-1)
  (define content (op "/api/repo-obj/{id}/content" 'get))
  (check-equal? (hash-ref content 'x-tmach-permission) "files:read")
  (check-equal? (hash-ref content 'x-tmach-permission-checked) "resource")
  ;; a route with no permission carries neither key rather than a null
  (define health (op "/health" 'get))
  (check-false (hash-has-key? health 'x-tmach-permission))
  (check-false (hash-has-key? health 'x-tmach-permission-checked))
  (check-false (hash-has-key? health 'x-tmach-feature))
  ;; the feature flag, where one is declared
  (check-equal? (hash-ref (op "/api/translate" 'post) 'x-tmach-feature) "translate")
  ;; the multi-tenancy plane, which is a 404 when the flag is off
  (check-equal? (hash-ref (op "/api/orgs" 'get) 'x-tmach-auth) "superadmin"))

;; ---------------------------------------------------------------------------
;; 9. the structural rules, checked by hand because no validator is available
(test-case "the document's own shape"
  (check-equal? (hash-ref doc 'openapi) OPENAPI-VERSION)
  (define info (hash-ref doc 'info))
  (for ([k '(title version description)]) (check-true (string? (hash-ref info k #f))))
  ;; the version is the one home (#227 slice 1), not a literal here
  (check-equal? (hash-ref info 'version) app-version)
  ;; one security scheme, http bearer
  (define schemes (hash-ref (hash-ref doc 'components) 'securitySchemes))
  (check-equal? (sort (map symbol->string (hash-keys schemes)) string<?) '("bearerAuth"))
  (check-equal? (hash-ref (hash-ref schemes 'bearerAuth) 'type) "http")
  (check-equal? (hash-ref (hash-ref schemes 'bearerAuth) 'scheme) "bearer")
  ;; every path is a path and every method is one OpenAPI has
  (define METHODS '(get put post delete options head patch trace))
  (for ([o (in-list (ops))])
    (check-true (string-prefix? (car o) "/") (format "~s is not a path" (car o)))
    (check-true (and (memq (string->symbol (cadr o)) METHODS) #t)
                (format "~a is not an OpenAPI method" (cadr o)))
    (define op (caddr o))
    (check-true (string? (hash-ref op 'description #f)))
    (check-true (pair? (hash-ref op 'tags '())))
    (for ([p (in-list (hash-ref op 'parameters '()))])
      (check-equal? (hash-ref p 'in) "path")
      (check-true (hash-ref p 'required))
      (check-true (string? (hash-ref p 'name #f)))
      (check-equal? (hash-ref (hash-ref p 'schema) 'type) "string"))
    ;; a template's parameters and its declared ones agree, or a viewer sends
    ;; a request to a URL with a brace still in it
    (define in-template (map (lambda (m) (cadr m)) (regexp-match* #px"\\{([^}]*)\\}" (car o) #:match-select values)))
    (check-equal? (sort (map (lambda (p) (hash-ref p 'name)) (hash-ref op 'parameters '())) string<?)
                  (sort in-template string<?)
                  (format "~a ~a declares different parameters from its template" (cadr o) (car o)))
    ;; a parameter is unique by (name, in), which the comparison above cannot
    ;; see: a template of `:id/:id` matches a declaration of the same pair
    (check-equal? (length (remove-duplicates in-template)) (length in-template)
                  (format "~a names one parameter twice" (car o))))
  ;; every tag an operation uses is declared at the top level, so a viewer orders
  ;; them predictably rather than in first-seen order
  (define declared-tags (for/list ([t (in-list (hash-ref doc 'tags))]) (hash-ref t 'name)))
  (check-equal? declared-tags (sort declared-tags string<?))
  (define used (remove-duplicates (append* (for/list ([o (in-list (ops))]) (hash-ref (caddr o) 'tags)))))
  (for ([t (in-list used)]) (check-true (and (member t declared-tags) #t) (format "tag ~s is undeclared" t)))
  (check-equal? (sort used string<?) declared-tags "a declared tag nothing uses is a tag nobody meant")
  ;; THE SERVER URL IS TEMPLATED, NOT A RELATIVE `/`. A relative URL resolves
  ;; against where the document was LOADED from, and this document is published
  ;; with the documentation rather than served by the instance — so `/` would
  ;; have aimed every request from a viewer at the documentation site. The
  ;; variable must be declared, or a viewer substitutes nothing and calls a URL
  ;; with a brace in it.
  (define srv (car (hash-ref doc 'servers)))
  (check-equal? (hash-ref srv 'url) "{instance}")
  (define vars (hash-ref srv 'variables))
  (check-true (hash-has-key? vars 'instance))
  (check-true (string? (hash-ref (hash-ref vars 'instance) 'default)))
  ;; every `{var}` in a server url is declared, the same rule as a path template
  (for ([m (in-list (regexp-match* #px"\\{([^}]*)\\}" (hash-ref srv 'url) #:match-select values))])
    (check-true (hash-has-key? vars (string->symbol (cadr m)))
                (format "server variable ~s is undeclared" (cadr m)))))

;; ---------------------------------------------------------------------------
;; 10. the tag derivation, which is the generator's and says so
(test-case "tags group by the path, and the console is not /api"
  (check-equal? (oa-tag "/api/notes") "notes")
  (check-equal? (oa-tag "/api/notes/:id") "notes")
  (check-equal? (oa-tag "/api/repo-obj/:id/content") "repo-obj")
  (check-equal? (oa-tag "/") "console")
  (check-equal? (oa-tag "/console/*path") "console")
  (check-equal? (oa-tag "/health") "console")
  (check-equal? (oa-tag "/api") "api")
  (check-true (string-contains? OPENAPI-NOTE "nothing in the source declares them")))
