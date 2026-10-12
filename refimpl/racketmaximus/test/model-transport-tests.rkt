#lang racket/base

;; test/model-transport-tests.rkt — the transport under every model call: a
;; deadline, a bounded retry, and an idle timeout on a stream.
;;
;; `http-sendrecv` takes no timeout and nothing wrapped these calls, so an
;; endpoint that accepted the connection and never answered hung the calling
;; thread for ever — in a scheduler job the lease reaper requeued the WORK, but
;; the thread kept its team's ai.concurrency slot, so a flapping endpoint drained
;; the pool while /health still said ok.
;;
;; Real sockets, in-process: a mock that returns canned bytes cannot stall, and
;; stalling is the whole point.  raco test test/model-transport-tests.rkt

(require rackunit
         racket/tcp
         racket/port
         racket/string
         "../domain/agent/llm.rkt")

;; ---- a tiny HTTP server whose handler decides what (if anything) to answer ---
;; `respond` is called with the attempt number and the output port. A handler
;; that writes nothing is an endpoint that accepted the connection and went quiet.
(define (serve! port respond)
  (define l (tcp-listen port 4 #t "127.0.0.1"))
  (define attempts (box 0))
  (define workers (box '()))
  (define (read-request! in)
    (define len
      (let loop ([len 0])
        (define line (read-line in 'any))
        (cond [(or (eof-object? line) (string=? line "")) len]
              [(regexp-match #px"(?i:^content-length:[ ]*([0-9]+))" line)
               => (lambda (m) (loop (string->number (cadr m))))]
              [else (loop len)])))
    (when (> len 0) (read-bytes len in)))
  (define acceptor
    (thread (lambda ()
              (let loop ()
                (define-values (in out) (tcp-accept l))
                (set-box! attempts (add1 (unbox attempts)))
                (define n (unbox attempts))
                (set-box! workers
                          (cons (thread (lambda ()
                                          (with-handlers ([exn:fail? void])
                                            (read-request! in)
                                            (respond n out))))
                                (unbox workers)))
                (loop)))))
  (values attempts
          (lambda ()
            (kill-thread acceptor)
            (for ([t (in-list (unbox workers))]) (kill-thread t))
            (tcp-close l))))

(define (reply! out code body)
  (define b (string->bytes/utf-8 body))
  (fprintf out "HTTP/1.1 ~a STATUS\r\nContent-Type: application/json\r\nContent-Length: ~a\r\nConnection: close\r\n\r\n"
           code (bytes-length b))
  (write-bytes b out)
  (flush-output out)
  (close-output-port out))

(define OK "{\"choices\":[{\"message\":{\"content\":\"ok\"}}],\"usage\":{\"total_tokens\":7}}")
(define (url port) (format "http://127.0.0.1:~a/v1/chat/completions" port))
(define HDRS (list "Content-Type: application/json"))
(define BODY (hasheq 'model "m" 'messages (list (hasheq 'role "user" 'content "hi"))))

;; ---- the deadline -----------------------------------------------------------
(test-case "an endpoint that accepts and never answers hits the deadline"
  (define-values (attempts stop!) (serve! 8931 (lambda (n out) (sync never-evt))))
  (define t0 (current-inexact-milliseconds))
  (define e (with-handlers ([exn:fail:model-retryable? values])
              (http-post-json (url 8931) BODY HDRS #:timeout 1 #:retries 0)
              #f))
  (define elapsed (- (current-inexact-milliseconds) t0))
  (check-pred exn:fail:model-retryable? e "a silent endpoint must not hang for ever")
  (check-equal? (exn:fail:model-retryable-reason e) 'timeout)
  (check-true (< elapsed 4000) (format "returned in ~ams" (inexact->exact (round elapsed))))
  (stop!))

;; ---- the retry --------------------------------------------------------------
(test-case "a 503 is tried again; the second attempt's answer is returned"
  (define-values (attempts stop!)
    (serve! 8932 (lambda (n out) (if (= n 1) (reply! out 503 "{\"error\":\"busy\"}") (reply! out 200 OK)))))
  (define-values (code resp) (http-post-json (url 8932) BODY HDRS #:timeout 5 #:retries 1))
  (check-equal? code 200)
  (check-equal? (unbox attempts) 2 "exactly one retry")
  (stop!))

(test-case "a 400 is NOT tried again — it is our own malformed request"
  (define-values (attempts stop!) (serve! 8933 (lambda (n out) (reply! out 400 "{\"error\":\"bad\"}"))))
  (define-values (code resp) (http-post-json (url 8933) BODY HDRS #:timeout 5 #:retries 2))
  (check-equal? code 400)
  (check-equal? (unbox attempts) 1 "retrying a 4xx only spends the budget again")
  (stop!))

(test-case "retries are bounded, and the last failure is what surfaces"
  (define-values (attempts stop!) (serve! 8934 (lambda (n out) (reply! out 500 "{\"error\":\"nope\"}"))))
  (define-values (code resp) (http-post-json (url 8934) BODY HDRS #:timeout 5 #:retries 2))
  (check-equal? code 500)
  (check-equal? (unbox attempts) 3 "the original attempt plus two retries")
  (stop!))

;; ---- a 200 that is not JSON -------------------------------------------------
(test-case "HTTP 200 with a non-JSON body is named, not an opaque read error"
  (define-values (attempts stop!)
    (serve! 8935 (lambda (n out)
                   (define b (string->bytes/utf-8 "<html>gateway</html>"))
                   (fprintf out "HTTP/1.1 200 STATUS\r\nContent-Length: ~a\r\nConnection: close\r\n\r\n"
                            (bytes-length b))
                   (write-bytes b out) (flush-output out) (close-output-port out))))
  (define e (with-handlers ([exn:fail:model-retryable? values])
              (http-post-json (url 8935) BODY HDRS #:timeout 5 #:retries 0) #f))
  (check-pred exn:fail:model-retryable? e)
  (check-equal? (exn:fail:model-retryable-reason e) 'malformed)
  (check-true (regexp-match? #rx"not JSON" (exn-message e)))
  (stop!))

;; ---- the stream's idle timeout ----------------------------------------------
;; The deadline cannot bound a stream: a model that is still emitting may take
;; minutes. What must be bounded is the GAP between events.
(test-case "a stream that stalls mid-answer raises instead of blocking for ever"
  (define-values (attempts stop!)
    (serve! 8936 (lambda (n out)
                   (fprintf out "HTTP/1.1 200 STATUS\r\nContent-Type: text/event-stream\r\n\r\n")
                   (fprintf out "data: {\"choices\":[{\"delta\":{\"content\":\"hi\"}}]}\n\n")
                   (flush-output out)
                   (sync never-evt))))                     ; ...and then nothing
  (define seen (box '()))
  (define-values (code in shutdown!)
    (http-post-stream (url 8936) (hash-set BODY 'stream #t) HDRS #:timeout 5))
  (check-equal? code 200)
  (define t0 (current-inexact-milliseconds))
  (define e (with-handlers ([exn:fail:model-retryable? values])
              (read-sse-deltas in (lambda (s) (set-box! seen (cons s (unbox seen)))) #:idle 1)
              #f))
  (define elapsed (- (current-inexact-milliseconds) t0))
  (check-pred exn:fail:model-retryable? e)
  (check-equal? (exn:fail:model-retryable-reason e) 'idle)
  (check-equal? (reverse (unbox seen)) '("hi") "what did arrive was delivered before the stall")
  (check-true (< elapsed 4000) (format "returned in ~ams" (inexact->exact (round elapsed))))
  (shutdown!)
  (stop!))

;; ---- an unreachable endpoint ------------------------------------------------
(test-case "a refused connection is retryable, not a raw network error"
  (define e (with-handlers ([exn:fail:model-retryable? values])
              (http-post-json (url 8937) BODY HDRS #:timeout 2 #:retries 0) #f))
  (check-pred exn:fail:model-retryable? e)
  (check-equal? (exn:fail:model-retryable-reason e) 'network))

;; ---- the knobs --------------------------------------------------------------
(test-case "the deadlines come from the environment, with shipped defaults"
  (check-equal? (model-timeout) 120)
  (check-equal? (model-idle-timeout) 60)
  (check-equal? (model-retries) 1)
  (define old (getenv "TELEMACHUS_MODEL_TIMEOUT"))
  (putenv "TELEMACHUS_MODEL_TIMEOUT" "7")
  (check-equal? (model-timeout) 7)
  (putenv "TELEMACHUS_MODEL_TIMEOUT" "nonsense")
  (check-equal? (model-timeout) 120 "an unparseable value falls back to the default, never to 0")
  (putenv "TELEMACHUS_MODEL_TIMEOUT" "0")
  (check-equal? (model-timeout) 120 "zero would mean every call times out instantly")
  (void (if old (putenv "TELEMACHUS_MODEL_TIMEOUT" old) (putenv "TELEMACHUS_MODEL_TIMEOUT" ""))))
