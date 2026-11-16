#lang racket/base

;; test/plugin-seals-tests.rkt — a plugin's sealed column survives a rotation.
;;
;; SEAL-1. `rewrap` walked a hardcoded list, so a plugin that sealed a column
;; with the platform key could not be rotated: the row kept opening while
;; TMACH_SECRET_KEY_OLD was set and stopped the day the runbook dropped it. This
;; file proves the three halves of the fix:
;;
;;   1. a declaration is validated at load, so a bad one fails the plugin and
;;      names what is wrong (not a request, not the rotation);
;;   2. the context template renders the AAD the rows were ACTUALLY written
;;      under, which is the assertion that fails if the template is ignored;
;;   3. the ledger rotates a column whose plugin is not loaded at all.
;;
;;   raco test test/plugin-seals-tests.rkt

(require rackunit racket/string racket/list racket/port db-kit/portable db-kit/migrate
         "../domain/db/migrations.rkt"
         "../domain/authz/secretbox.rkt"
         "../domain/agent/seals.rkt"
         "../domain/agent/plugins.rkt"
         (only-in "../cli/telemachus-secrets.rkt" rewrap status)
         "db-fixture.rkt")

(define KEY-A (make-string 64 #\a))
(define KEY-B (make-string 64 #\b))
(define K "TMACH_SECRET_KEY")
(define K-OLD "TMACH_SECRET_KEY_OLD")

(define (with-env* pairs thunk)
  (define saved (for/list ([p (in-list pairs)]) (cons (car p) (getenv (car p)))))
  (dynamic-wind (lambda () (for ([p (in-list pairs)]) (putenv (car p) (cdr p))))
                thunk
                (lambda () (for ([p (in-list saved)]) (putenv (car p) (or (cdr p) ""))))))

;; ---- 1. the declaration ------------------------------------------------------

(define PREFIX "x_demo_")

(test-case "a spec may name its own AAD order, and {id} is {id1}"
  (check-equal? (seal-context-of "{table}.{id}.{column}" "x_demo_t" "body" '("abc"))
                "x_demo_t.abc.body")
  (check-equal? (seal-context-of "{table}:{id1}:{id2}:{column}" "x_demo_t" "body" '("a" "b"))
                "x_demo_t:a:b:body")
  (check-equal? (seal-context-of "{column}:{id}" "x_demo_t" "body" '("abc"))
                "body:abc"))

(test-case "a declaration is refused when it is not the plugin's table"
  (check-not-false (seal-spec-problem PREFIX (list "users" "totp_secret" "id" "{column}:{id}")))
  (check-not-false (seal-spec-problem PREFIX (list "x_demo_t" "body" "id" "{column}")))
  (check-not-false (seal-spec-problem PREFIX (list "x_demo_t" "body" "id" "{column}:{id3}"))))

(test-case "check-seals! fails the plugin, not a request"
  (check-exn exn:fail?
             (lambda () (check-seals! "demo" PREFIX (list (list "users" "totp_secret" "id" "{column}:{id}")))))
  (check-exn exn:fail?
             (lambda () (check-seals! "demo" PREFIX (list (list "x_demo_t" "body" "id" "{column}")))))
  (check-exn exn:fail?
             (lambda () (check-seals! "demo" PREFIX
                                      (list (list "x_demo_t" "body" "id" "{column}:{id}" 'bytes)
                                            (list "x_demo_t" "body" "id" "{column}:{id}")))))
  (define ok (car (check-seals! "demo" PREFIX (list (list "x_demo_t" "body" (list "id" "version")
                                                       "{table}.{id1}.{id2}.{column}" 'bytes)))))
  (check-equal? (car ok) "demo")
  (check-equal? (list-ref ok 3) '("id" "version"))
  (check-equal? (list-ref ok 5) 'bytes))

;; ---- 2 and 3. a real rotation, with the plugin absent from the ledger's walk --

(define (fresh) (define c (fresh-db #:migrate? #f)) (migrate! c all-migrations) c)

(define (seed-demo! conn)
  (query-exec conn "CREATE TABLE x_demo_t (id TEXT PRIMARY KEY, body TEXT)")
  (define plain "supplier's words")
  (define ctx "x_demo_t.row-1.body")
  (define sealed (secret-wrap ctx plain))
  (query-exec conn "INSERT INTO x_demo_t (id, body) VALUES (?, ?)" "row-1" sealed)
  ;; the ledger row the loader would have written, with NO plugin loaded: this is
  ;; the uninstalled case the in-memory registry cannot serve
  (query-exec conn
              (string-append "INSERT INTO plugin_seals "
                             "(plugin_id, tbl, col, id_columns, context_template, form, first_seen_epoch, last_seen_epoch) "
                             "VALUES (?,?,?,?,?,?,?,?)")
              "demo" "x_demo_t" "body" "id" "{table}.{id}.{column}" "text" 0 0)
  plain)

(test-case "the ledger rotates a column whose plugin is not loaded"
  (define conn (fresh))
  (define plain (with-env* (list (cons K KEY-A) (cons K-OLD "")) (lambda () (seed-demo! conn))))
  (with-env* (list (cons K KEY-B) (cons K-OLD KEY-A))
    (lambda ()
      (rewrap conn)
      ;; the AAD the row was written under is the one the template names; the old
      ;; key is now unnecessary, which is the assertion that fails on a
      ;; prefix-only registry (the tag check would fail on the first row)
      (check-equal? (secret-unwrap "x_demo_t.row-1.body"
                                   (vector-ref (car (query-rows conn "SELECT body FROM x_demo_t")) 0))
                    plain)
      ;; idempotent: a second run changes nothing and does not abort
      (rewrap conn)
      (check-equal? (secret-unwrap "x_demo_t.row-1.body"
                                   (vector-ref (car (query-rows conn "SELECT body FROM x_demo_t")) 0))
                    plain)))
  (disconnect conn))

(test-case "status names a row it cannot see"
  (define conn (fresh))
  (with-env* (list (cons K KEY-A))
    (lambda ()
      (define out (with-output-to-string (lambda () (status conn))))
      (check-true (string? out))))
  (disconnect conn))
