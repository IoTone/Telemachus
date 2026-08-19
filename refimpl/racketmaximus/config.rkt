#lang racket/base

;; config.rkt — Telemachus-app-specific glue that the generic kits deliberately
;; don't know about: where the repo/data live, the app version, and how to open
;; THIS app's database. Everything reusable lives in the cli-kit/db-kit/web-kit
;; packages under pkgs/; this is the only app-branded shared module.

(require racket/runtime-path
         db-kit)

(provide app-version impl-root data-dir database-url call-with-app-db)

(define app-version "0.1.0")

;; This file lives at <repo>/refimpl/racketmaximus/config.rkt. This reference
;; implementation keeps its runtime data alongside itself (racketmaximus/data/),
;; so the anchor is this file's own directory.
(define-runtime-path here ".")
(define impl-root (simplify-path here))

;; App data dir; TELEMACHUS_DATA_DIR overrides for tests/CI.
(define (data-dir)
  (define e (getenv "TELEMACHUS_DATA_DIR"))
  (if (and e (not (string=? e ""))) (string->path e) (build-path impl-root "data")))

;; Prototyping default is sqlite. DATABASE_URL overrides; when the Postgres
;; backend lands in db-kit, a `postgres://…` URL will resolve here unchanged.
;;
;; The default is derived from `data-dir`, NOT a relative "./data/…". A relative
;; URL resolves against `impl-root`, so the database landed next to the source no
;; matter what TELEMACHUS_DATA_DIR said — which made that variable a half-truth
;; (it moved the TLS cert but not the database) and put the database inside a
;; read-only Nix store for a packaged install. One writable state directory,
;; named by one variable.
(define (database-url)
  (or (getenv "DATABASE_URL")
      (string-append "sqlite:///" (path->string (build-path (data-dir) "telemachus.db")))))

;; Open the app db (relative URLs resolve against the implementation root).
(define (call-with-app-db proc #:mode [mode 'read/write])
  (call-with-sqlite (sqlite-path (database-url) #:base-dir impl-root) proc #:mode mode))
