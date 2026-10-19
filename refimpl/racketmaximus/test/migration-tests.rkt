#lang racket/base

;; test/migration-tests.rkt — the schema comes forward from ANY point in its
;; history, on EITHER dialect.
;;
;;   raco test test/migration-tests.rkt
;;   DATABASE_URL="postgres://…" raco test test/migration-tests.rkt
;;
;; Issue #89 asked for "migrations tested on both for upgrade from the previous
;; release". This is deliberately stronger and needs no knowledge of tags: it
;; upgrades from EVERY prefix of the migration list, so the previous release is
;; one of the cases rather than the only one. The release tags are a prefix of
;; today's ids (v0.3.0 ends at `0003-quota`), so "stop after N and come forward"
;; IS the upgrade an operator on any past version performs — and it costs no
;; checkout of old code, which for a two-month-old tag would not build anyway.
;;
;; What each case proves, and why each one has been wrong somewhere before:
;;
;;   • every migration applies to the schema the ones before it left. A migration
;;     written against today's tables rather than the tables as they were at its
;;     own point in history passes `nix build` (which migrates from empty, once)
;;     and fails on the first real upgrade.
;;   • `migrate!` is idempotent — a second run applies nothing. The runner
;;     records ids and skips them, so this is a property of the LIST (no
;;     duplicate ids) as much as of the runner.
;;   • the dialects disagree, which is the whole reason this runs twice. SQLite
;;     accepts a surprising amount of loose DDL; Postgres does not, and
;;     `db-kit/portable` only rewrites placeholders — it cannot rescue
;;     SQLite-only syntax.
;;
;; A migration that needs a LATER migration's table is the failure this file is
;; built to catch, and it cannot be caught by a from-empty run.

(require rackunit db-kit/portable db-kit/migrate
         racket/file racket/list
         "../domain/db/migrations.rkt"
         "../domain/repo/blobs.rkt"
         "db-fixture.rkt")

;; 0022 folds document bodies into the blob store. There are no documents in an
;; empty database so it moves nothing, but the root must still not point into the
;; checkout — the rule every test that can touch blobs lives by.
(define BLOB-ROOT (make-temporary-file "telemachus-migration-blobs-~a" 'directory))
(current-blob-root BLOB-ROOT)

(define ALL (length all-migrations))
(define IDS (map migration-id all-migrations))

;; Apply the first `n` migrations, then bring the database all the way forward.
(define (check-upgrade-from n)
  (define conn (fresh-db #:migrate? #f))
  (dynamic-wind
   void
   (lambda ()
     (define stopped-at (if (zero? n) "(empty)" (list-ref IDS (sub1 n))))
     ;; the world as it was at that point in history
     (migrate! conn (take all-migrations n))
     (check-equal? (length (applied-migrations conn)) n
                   (format "~a migration(s) applied at ~a" n stopped-at))
     ;; …and the upgrade an operator on that version runs
     (migrate! conn all-migrations)
     (check-equal? (applied-migrations conn) (sort IDS string<?)
                   (format "every migration is applied after upgrading from ~a" stopped-at))
     (check-equal? (pending-migrations conn all-migrations) '()
                   (format "nothing is left pending after upgrading from ~a" stopped-at))
     ;; a restart must not re-run anything: migrate! is the boot path, and an
     ;; instance that re-applied DDL on every start would fail on the second boot
     (migrate! conn all-migrations)
     (check-equal? (length (applied-migrations conn)) ALL
                   (format "a second migrate! from ~a is a no-op" stopped-at))
     ;; the schema is actually usable, not merely recorded — one table from the
     ;; first migration and one from the most recent, on the real connection
     (check-equal? (query-value conn "SELECT COUNT(*) FROM users") 0
                   "the oldest table answers")
     (check-equal? (query-value conn "SELECT COUNT(*) FROM jobs") 0
                   "the newest tables answer"))
   (lambda () (close-db! conn))))

(test-case "the migration list has no duplicate ids"
  ;; migrate! skips an id it has already applied, so a duplicate id would make
  ;; the SECOND migration with that id silently never run.
  (check-equal? (length (remove-duplicates IDS)) ALL))

(test-case "migration ids are in sorted order"
  ;; applied-migrations reads `ORDER BY id`, so lexical order must equal
  ;; declaration order or "what has been applied" and "what runs next" disagree.
  (check-equal? IDS (sort IDS string<?)))

(test-case "the schema comes forward from every point in its history"
  ;; Every prefix, on both dialects. Measured: 1.2s on SQLite and 4.5s on
  ;; Postgres for all ~44 points, so there is no reason to sample — and sampling
  ;; is how the one migration that assumes a later table stays hidden.
  (printf "  (~a: upgrading from ~a point(s))\n" (fixture-dialect) (add1 ALL))
  (for ([n (in-range 0 (add1 ALL))]) (check-upgrade-from n)))
