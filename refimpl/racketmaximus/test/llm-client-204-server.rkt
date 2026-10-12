#lang racket/base

;; test/llm-client-204-server.rkt — a tiny 204 server for test/llm-client-tests.rkt.
;;
;; It runs as its own process, on a port given on the command line, because the test counts the
;; descriptors of the process it measures: a server in the same process would be counted too, and
;; the count would grow on the server's side of every connection and hide whether the client
;; closed its own. It answers 204 No Content with no body, which is what the claim endpoint
;; answers when there is no job, and keeps each connection open for the next request.
;;
;;   racket test/llm-client-204-server.rkt <port>
(require racket/tcp)

(define port (string->number (vector-ref (current-command-line-arguments) 0)))
(define listener (tcp-listen port 64 #t))
(let accept ()
  (define-values (in out) (tcp-accept listener))
  (thread (lambda ()
            (with-handlers ([exn:fail? void])
              ;; One request per connection is enough: the client opens a new connection for each
              ;; request once it closes them, which is the behaviour under test.
              (let loop ()
                (define line (read-line in 'any))
                (unless (eof-object? line)
                  (when (regexp-match? #rx"^\r?$" line)
                    (display "HTTP/1.1 204 No Content\r\n\r\n" out)
                    (flush-output out))
                  (loop))))))
  (accept))
