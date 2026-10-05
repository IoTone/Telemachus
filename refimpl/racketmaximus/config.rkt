#lang racket/base

;; config.rkt — Telemachus-app-specific glue that the generic kits deliberately
;; don't know about: where the repo/data live, the app version, and how to open
;; THIS app's database. Everything reusable lives in the cli-kit/db-kit/web-kit
;; packages under pkgs/; this is the only app-branded shared module.

(require racket/runtime-path
         db-kit
         (only-in web-kit default-max-body-length))

(provide app-version impl-root data-dir database-url call-with-app-db anchor-path
         max-upload-bytes)

(define app-version "0.1.0")

;; This file lives at <repo>/refimpl/racketmaximus/config.rkt. This reference
;; implementation keeps its runtime data alongside itself (racketmaximus/data/),
;; so the anchor is this file's own directory.
(define-runtime-path here ".")
(define impl-root (simplify-path here))

;; Resolve a possibly-relative path against `impl-root` rather than the process's
;; current directory.
;;
;; This is not a nicety. `serve/servlet` sets `current-directory` to the web
;; server's own default web root while it is handling a request, which for a Nix
;; install is INSIDE THE READ-ONLY STORE. Any relative path that is resolved
;; lazily — at write time, in a handler — therefore aims at the store and fails
;; with EACCES. It works in the unit tests and it works at startup; it fails only
;; on the first write made by a live request. Anchor at definition, not at use.
(define (anchor-path p)
  (define pp (if (path? p) p (string->path p)))
  (if (absolute-path? pp) pp (simplify-path (build-path impl-root pp))))

;; App data dir; TELEMACHUS_DATA_DIR overrides for tests/CI. A relative override
;; is anchored to impl-root, so it means the same thing from any cwd.
(define (data-dir)
  (define e (getenv "TELEMACHUS_DATA_DIR"))
  (if (and e (not (string=? e ""))) (anchor-path e) (build-path impl-root "data")))

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

;; Largest request body / upload the app will accept. web-server's own default is
;; 1 MiB and it enforces it by DROPPING the connection — no status, no log line —
;; so a handler's own size check never runs. Deliberate here rather than inherited.
;; Shared between the servlet's #:max-body-length (server/main.rkt) and every blob
;; write that can be reached from outside the servlet's own body limit, such as the
;; S3 door (domain/s3/server.rkt), which is a separate listener with no ceiling of
;; its own otherwise.
(define (max-upload-bytes)
  (define raw (getenv "TELEMACHUS_MAX_UPLOAD"))
  (define n (and raw (string->number raw)))
  (if (and n (exact-positive-integer? n)) n default-max-body-length))
