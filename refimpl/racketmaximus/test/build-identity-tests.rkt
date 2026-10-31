#lang racket/base

;; test/build-identity-tests.rkt — which build is this? (the version footer)
;;
;; Two instances of this platform running on one box, one of them a day behind,
;; were INDISTINGUISHABLE ON SCREEN; that is what this field exists to fix. The
;; version alone could not have done it — it was 0.1.0 on both, through three
;; release tags, which is what #227 then fixed — so the commit is the
;; load-bearing half and its RESOLUTION is the logic worth testing.
;;
;; This file deliberately does NOT require server/kit.rkt. Requiring kit
;; instantiates the connection pool, which reads DATABASE_URL at module
;; instantiation — and CI's SQLite leg sets it to the EMPTY string, which the
;; connector refuses. That is #123's trap, and it failed only in CI.
;;   raco test test/build-identity-tests.rkt

(require rackunit racket/file racket/string racket/port json racket/runtime-path
         (only-in "../config.rkt" app-build app-version app-commit commit-from-git))

(define SHA "0123456789abcdef0123456789abcdef01234567")
(define OTHER "fedcba9876543210fedcba9876543210fedcba98")

(define (with-fake-repo proc #:head [head (string-append "ref: refs/heads/main")]
                              #:ref [ref 'loose] #:git-as-file? [as-file? #f])
  (define root (make-temporary-file "tmx-build-~a" 'directory))
  (define git (build-path root ".git"))
  (define real (if as-file? (build-path root "real-git") git))
  (make-directory* (build-path real "refs" "heads"))
  (when as-file?
    (call-with-output-file git (lambda (o) (fprintf o "gitdir: ~a\n" (path->string real)))))
  (call-with-output-file (build-path real "HEAD") (lambda (o) (displayln head o)))
  (case ref
    [(loose) (call-with-output-file (build-path real "refs" "heads" "main")
               (lambda (o) (displayln SHA o)))]
    [(packed) (call-with-output-file (build-path real "packed-refs")
                (lambda (o)
                  (displayln "# pack-refs with: peeled fully-peeled sorted" o)
                  (displayln (string-append OTHER " refs/heads/other") o)
                  (displayln (string-append SHA " refs/heads/main") o)))]
    [(none) (void)])
  (begin0 (proc root) (delete-directory/files root)))

(test-case "a checkout's commit is read from .git, with no subprocess"
  ;; no `git` on PATH is the normal case in the container, and a subprocess on
  ;; the boot path to answer a cosmetic question is the wrong trade
  (check-equal? (with-fake-repo (lambda (r) (commit-from-git r))) SHA))

(test-case "a detached HEAD is the sha itself"
  (check-equal? (with-fake-repo (lambda (r) (commit-from-git r)) #:head SHA #:ref 'none) SHA))

(test-case "a ref that exists only in packed-refs is still found"
  ;; a freshly cloned branch has no loose ref file at all, which is exactly the
  ;; state a deployment box is in
  (check-equal? (with-fake-repo (lambda (r) (commit-from-git r)) #:ref 'packed) SHA)
  ;; …and it is the NAMED ref, not merely the first line that looks like a sha
  (check-not-equal? (with-fake-repo (lambda (r) (commit-from-git r)) #:ref 'packed) OTHER))

(test-case "a worktree's .git is a FILE naming the real directory"
  (check-equal? (with-fake-repo (lambda (r) (commit-from-git r)) #:git-as-file? #t) SHA))

(test-case "no .git, or a ref that resolves to nothing, answers #f — never a guess"
  (define empty (make-temporary-file "tmx-build-~a" 'directory))
  (check-false (commit-from-git empty) "a directory that is not a checkout")
  (delete-directory/files empty)
  (check-false (with-fake-repo (lambda (r) (commit-from-git r)) #:ref 'none)
               "HEAD names a ref nothing has written"))

(test-case "the build record is the shape the console and the status route read"
  (define b (app-build))
  (check-equal? (hash-ref b 'version) app-version)
  (check-equal? (hash-ref b 'commit) app-commit)
  ;; the short form is a PREFIX of the full one, never a second reading of it
  (check-true (string-prefix? (hash-ref b 'commit) (hash-ref b 'commit_short)))
  (check-true (<= (string-length (hash-ref b 'commit_short)) 7))
  (check-true (exact-integer? (hash-ref b 'started)) "a boot time, for 'did it restart'")
  (check-equal? (hash-ref b 'source) "https://github.com/IoTone/Telemachus")
  ;; it must be a jsexpr: it rides on whoami
  (check-true (jsexpr? b)))


;; ---- the version has ONE home (#227) ----------------------------------------
;;
;; It was spelled three times: `app-version`, `nix/telemachus.nix`'s derivation
;; version, and the `version` flake.nix passes to `nix/container.nix` — which
;; becomes the image TAG, the `org.opencontainers.image.version` label and the
;; SBOM component's version. All three said 0.1.0 while `git tag` read v0.3.0 and
;; 442 commits had landed, so they agreed by nobody having touched them rather
;; than by anything keeping them in step. LIVE-IN's shape, with three publishers.

;; anchored at THIS FILE, never at `current-directory` — raco test's cwd is not
;; something to build a path from (the first version did and resolved to test/)
(define-runtime-path test-dir ".")
(define (impl . parts) (apply build-path (simplify-path (build-path test-dir "..")) parts))

(test-case "app-version IS the VERSION file, read rather than restated"
  (define f (impl "VERSION"))
  (check-true (file-exists? f) "the one home exists")
  (define on-disk (string-trim (file->string f)))
  (check-equal? app-version on-disk)
  ;; a semver-shaped line and nothing else — the file is read by Nix at eval time
  ;; too, so a stray comment or a second line would land in an image tag
  (check-true (and (regexp-match? #px"^[0-9]+\\.[0-9]+\\.[0-9]+(-[0-9A-Za-z.-]+)?$" on-disk) #t)
              (format "VERSION must be one semver line, got ~s" on-disk))
  (check-false (regexp-match? #rx"
" (string-trim (file->string f) #:left? #f))
               "no trailing content after the number"))

(test-case "…and NO version literal survives in the build files, which is the point"
  ;; the control for the case above: `app-version` could agree with the file while
  ;; either Nix copy sat at 0.1.0, which is exactly the state #227 was filed in.
  ;; Both must READ it, so neither may contain a semver literal at all.
  ;;
  ;; THE BUILD FILES ARE OUTSIDE `src`, SO THEY ARE ABSENT FROM THE NIX SANDBOX,
  ;; and this case errored there on its first run — REL‑2's own fact, met from
  ;; inside the test written to document it. `nix/telemachus.nix` sets
  ;; `src = ../refimpl/racketmaximus`, so the store holds this directory and
  ;; nothing above it.
  ;;
  ;; It therefore SKIPS when they are not reachable, and SAYS SO — a silent skip
  ;; is how a path goes unexercised for a year (the S3 smoke's lesson, recorded
  ;; twice in these notes). In a checkout it runs and is positive-controlled;
  ;; `nix build` runs the suite with nothing above `src` to read, and CI runs it
  ;; in a checkout as well, so the assertion is never only-skipped.
  (define present
    (for/list ([rel (in-list '("nix/telemachus.nix" "flake.nix"))]
               #:when (file-exists? (impl ".." ".." rel)))
      rel))
  (when (null? present)
    (printf (string-append "  SKIPPED: the build files are above `src` and so are not in this "
                           "tree (a Nix sandbox). Run this case from a checkout.\n")))
  (for ([rel (in-list present)])
    (define src (file->string (impl ".." ".." rel)))
    (check-false (regexp-match? #px"version[^\n]*\"[0-9]+\\.[0-9]+\\.[0-9]+\"" src)
                 (format "~a still spells a version literally" rel))
    (check-true (and (regexp-match? #rx"refimpl/racketmaximus/VERSION" src) #t)
                (format "~a must read the one home" rel))))
