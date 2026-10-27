#lang racket/base

;; config.rkt — Telemachus-app-specific glue that the generic kits deliberately
;; don't know about: where the repo/data live, the app version, and how to open
;; THIS app's database. Everything reusable lives in the cli-kit/db-kit/web-kit
;; packages under pkgs/; this is the only app-branded shared module.

(require racket/runtime-path racket/string
         db-kit
         (only-in web-kit default-max-body-length))

(provide app-version impl-root data-dir database-url call-with-app-db anchor-path
         max-upload-bytes content-encryption-enabled?
         ;; #128 job 2: the ONE place an operator-facing variable is read.
         tmach-env tmach-env-legacy-names legacy-env-warning)

;; ---- the operator's own names (#128 job 2) --------------------------------------
;; The product is branded TMach; the variables said TELEMACHUS_. Job 1 renamed the
;; PROSE and deliberately left these alone, because a variable is a contract with
;; every deployment that already exists — a compose file, a systemd unit, a
;; Kubernetes secret, somebody's shell history.
;;
;; So this is a DUAL READ with no flag day: `TMACH_<name>` is the name, the old spelling
;; still answers, the new name wins when both are set, and the instance SAYS at
;; boot which old names it is still reading. Nothing that works today stops
;; working, and an operator can migrate one variable at a time.
;;
;; THE SUFFIX IS THE ARGUMENT, not the whole name, and that is what makes the
;; gate in test/env-names-tests.rkt possible: with the full name at the call site
;; a reader cannot tell a dual read from a single one, and a missed site would go
;; on working — silently, until the day somebody sets only the new name. That is
;; the one failure this slice has to make impossible rather than unlikely.
(define NEW-PREFIX "TMACH_")
(define OLD-PREFIX "TELEMACHUS_")

;; Which old names actually answered, in first-read order. A SET rather than a
;; counter: an operator wants the list to migrate, not a tally, and a variable
;; read on every request would otherwise dominate it.
(define *legacy* (box '()))
(define (note-legacy! suffix)
  (unless (member suffix (unbox *legacy*))
    (set-box! *legacy* (append (unbox *legacy*) (list suffix)))))
(define (tmach-env-legacy-names) (unbox *legacy*))

;; An EMPTY value is absent, which is the behaviour all eight of the hand-written
;; copies of this helper already had — and it matters here beyond tidiness: CI's
;; sqlite leg sets DATABASE_URL to the empty string, and #123 records a test that
;; passed everywhere except there because of it.
(define (tmach-env suffix [default #f])
  (define (live k) (let ([v (getenv k)]) (and v (not (string=? (string-trim v) "")) v)))
  (define new (live (string-append NEW-PREFIX suffix)))
  (cond
    [new new]
    [(live (string-append OLD-PREFIX suffix))
     => (lambda (v) (note-legacy! suffix) v)]
    [else default]))

;; -> a string for the boot line, or #f when nothing legacy was read. Printed by
;; the server once, the way the plugin-failure block is: an operator who never
;; reads it loses nothing, and one who is migrating gets the list.
(define (legacy-env-warning)
  (define names (tmach-env-legacy-names))
  (and (pair? names)
       (format (string-append
                "NOTE: ~a variable(s) are still being read under the old ~a names: ~a.\n"
                "      The ~a spellings are the current ones and win when both are set;\n"
                "      the old names keep working. See docs/ops/configuration.md.")
               (length names) OLD-PREFIX
               (string-join (for/list ([n (in-list names)]) (string-append OLD-PREFIX n)) ", ")
               NEW-PREFIX)))

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
  (define e (tmach-env "DATA_DIR"))
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
  (define raw (tmach-env "MAX_UPLOAD"))
  (define n (and raw (string->number raw)))
  (if (and n (exact-positive-integer? n)) n default-max-body-length))

;; ---- encrypting document-derived content at rest (issue #83) --------------------
;; OPT-IN, and it has to be: sealing `repo_text.content` makes CONTENT SEARCH
;; impossible, because the match is a SQL `LIKE` over that column. Turning this on
;; for every instance that sets a secret key — which is the recommended posture —
;; would silently remove a feature people use. #83 r3 allows exactly this shape:
;; an index that holds no plaintext, "or be an explicit opt-in per instance".
;;
;; It is NOT the same switch as TELEMACHUS_SECRET_KEY. That key seals the three
;; replayable credentials (#19) and is wanted on every instance; this decides
;; whether DERIVED DOCUMENT CONTENT is sealed too, and costs a capability. A
;; deployment holding regulated documents wants both; one that wants to search its
;; documents wants only the first.
;;
;; Enabled without a key, this would silently do nothing — `secret-wrap` passes
;; plaintext through when no key is configured, by design, so adoption needs no
;; migration. `server/startup.rkt` therefore REFUSES to serve in that combination
;; rather than leaving an operator believing their text is encrypted.
(define (content-encryption-enabled?)
  (and (member (string-downcase (string-trim (or (tmach-env "ENCRYPT_CONTENT") "")))
               '("1" "yes" "true" "on"))
       #t))
