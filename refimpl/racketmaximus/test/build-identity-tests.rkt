#lang racket/base

;; test/build-identity-tests.rkt — which build is this? (the version footer)
;;
;; Two instances of this platform running on one box, one of them a day behind,
;; were INDISTINGUISHABLE ON SCREEN; that is what this field exists to fix. The
;; version alone could not have done it — it is 0.1.0 on both — so the commit is
;; the load-bearing half and its RESOLUTION is the only logic worth testing.
;;
;; This file deliberately does NOT require server/kit.rkt. Requiring kit
;; instantiates the connection pool, which reads DATABASE_URL at module
;; instantiation — and CI's SQLite leg sets it to the EMPTY string, which the
;; connector refuses. That is #123's trap, and it failed only in CI.
;;   raco test test/build-identity-tests.rkt

(require rackunit racket/file racket/string racket/port json
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
