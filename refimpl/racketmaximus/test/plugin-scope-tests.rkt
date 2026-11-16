#lang racket/base

;; test/plugin-scope-tests.rkt — a plugin route says whose authority its
;; permission is weighed against (r2's distinction, extended to plugins).
;;
;; A core route has carried `#:scope 'role|'resource` since #110 r2. A plugin
;; route could not express it: every plugin route was pre-checked by role, so a
;; viewer holding a grant on one document was refused by the very route that
;; should serve it (DSH-1). The seventh element is append-only, so every existing
;; 4-, 5- and 6-element route is unchanged.
;;
;;   raco test test/plugin-scope-tests.rkt

(require rackunit
         racket/file            ; file->string: the runtime half is a source read, see below
         (only-in "../domain/agent/plugins.rkt" check-route! PLUGIN-ROUTE-SCOPES))

(define (handler conn p args) 'ok)
(define (public-handler conn args) 'ok)

(test-case "an absent seventh element means role"
  (check-equal? (hash-ref (check-route! "demo" (list "GET" "/x" "files:read" handler "doc")) 'scope 'role)
                'role)
  (check-equal? (hash-ref (check-route! "demo" (list "GET" "/x" "files:read" handler "doc" 'bearer)) 'scope)
                'role))

(test-case "a resource-scoped route carries its scope, and its permission"
  (define r (check-route! "demo" (list "GET" "/x" "files:read" handler "doc" 'bearer 'resource)))
  (check-equal? (hash-ref r 'scope) 'resource)
  (check-equal? (hash-ref r 'perm) "files:read"))

(test-case "a resource scope with nothing to weigh is refused at load"
  (check-exn exn:fail? (lambda () (check-route! "demo" (list "GET" "/x" #f handler "doc" 'bearer 'resource)))))

(test-case "a public route cannot be resource-scoped"
  (check-exn exn:fail? (lambda () (check-route! "demo" (list "GET" "/x" "files:read" public-handler "doc" 'public 'resource)))))

;; THE RUNTIME HALF, which the loader tests above cannot reach. `check-route!` decides
;; what a route MAY declare; the wrapper in server/main.rkt decides what happens at
;; dispatch, and reverting its one conditional would leave every resource-scoped route
;; pre-checked by role again — exactly the DSH-1 refusal this feature removes — with the
;; whole suite still green. A smoke case needs a shipped plugin that declares 'resource
;; and none does, so the assertion is on the line itself. It is a source read, like
;; password-floor-tests.rkt's check that no endpoint computes a floor of its own: the
;; claim is "this branch is guarded", and a branch is not callable from a test.
(test-case "the wrapper pre-checks by role ONLY for a role-scoped route"
  (define src (file->string "../server/main.rkt"))
  (check-true (regexp-match?
               #px"\\(when \\(and perm \\(eq\\? scope 'role\\)\\) \\(require-perm db-conn p perm\\)\\)"
               src)
              "the permission pre-check must be conditional on the route's own scope"))

(test-case "an unknown scope is refused and the vocabulary is named"
  (check-exn (lambda (e) (and (regexp-match? #rx"role resource" (exn-message e)) #t))
             (lambda () (check-route! "demo" (list "GET" "/x" "files:read" handler "doc" 'bearer 'tenant)))))
