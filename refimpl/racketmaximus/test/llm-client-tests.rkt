#lang racket/base

;; test/llm-client-tests.rkt — http-post-json must not leave a file descriptor open per request.
;;   raco test test/llm-client-tests.rkt
;;
;; Why this exists. cli/telemachus-worker.rkt long-polls /api/workers/claim through
;; http-post-json, and the claim endpoint answers 204 No Content when there is no job. Racket's
;; http-sendrecv abandons the connection for a response with no body: it hands back an in-memory
;; empty port and never closes the socket underneath. Measured on 2026-09-28 against a server that
;; answers 204: ten requests took the process from 11 open descriptors to 31, two per request.
;; An idle worker therefore reached its 1024-descriptor limit in about five and a half hours, and
;; from then on every claim failed with "Too many open files" while the process stayed alive, so
;; nothing recovered it but a container restart. Measured on dev1's own worker: 1023 of 1024
;; descriptors and sixteen hours without claiming a job.
;;
;; http-post-json now opens the connection itself and closes it, and this test holds that. It runs
;; only where /proc/self/fd exists, because counting descriptors is the only way to see the leak.

(require rackunit
         racket/tcp
         racket/port
         racket/file
         racket/system
         "../domain/agent/llm.rkt")

(define PORT 18876)

(define (descriptors) (length (directory-list "/proc/self/fd")))
(define (can-count-descriptors?) (directory-exists? "/proc/self/fd"))

;; The server runs as its own process (test/llm-client-204-server.rkt), because this test counts
;; the descriptors of the process it measures and a server in the same process would be counted
;; with it: its side of every connection stays open and would hide whether the client closed its
;; own. It is the shape that leaks: 204 No Content with no body, which is what the claim endpoint
;; answers when there is no job.
(define test-dir (or (current-load-relative-directory) (current-directory)))
(define (start-204-server)
  ;; The interpreter running this test, which may not be on PATH: `raco test` is normally invoked
  ;; by absolute path.
  (define racket-exe (or (find-executable-path "racket") (path->string (find-system-path 'exec-file))))
  (define-values (p _stdin _stdout _stderr)
    (subprocess #f #f #f racket-exe
                (path->string (build-path test-dir "llm-client-204-server.rkt"))
                (number->string PORT)))
  ;; Wait until it accepts, rather than sleeping a guessed amount.
  (let wait ([tries 100])
    (define ready?
      (with-handlers ([exn:fail? (lambda (_) #f)])
        (define-values (in out) (tcp-connect "127.0.0.1" PORT))
        (close-input-port in) (close-output-port out) #t))
    (cond [ready? p]
          [(zero? tries) (subprocess-kill p #t) (error 'llm-client-tests "the 204 test server never accepted")]
          [else (sleep 0.1) (wait (sub1 tries))])))

(define (post-claim)
  (define-values (code _body) (http-post-json (format "http://127.0.0.1:~a/api/workers/claim" PORT)
                                              (hasheq 'kinds '("infer.chat") 'models '() 'max_wait 1)
                                              '("Content-Type: application/json")))
  code)

(define server (start-204-server))
;; One request first, so the listener and the first connection exist before the count is taken, and
;; so any one-off allocation is already done.
(check-equal? (post-claim) 204 "the test server answers 204")

(test-case "http-post-json closes its connection, so a 204 response leaks no descriptor"
  (when (can-count-descriptors?)
    (collect-garbage)
    (define before (descriptors))
    (for ([i (in-range 20)]) (check-equal? (post-claim) 204))
    (collect-garbage)
    (define growth (- (descriptors) before))
    ;; Zero is what a fixed helper gives. The slack is for the server side of these connections,
    ;; which lives in this same process and is collected on its own schedule. A leak of one
    ;; descriptor per request is 40 here, so the margin is wide in both directions.
    (check-pred (lambda (g) (< g 8))
                growth
                (format "descriptor growth over 20 requests: ~a" growth))))

(void (subprocess-kill server #t))
