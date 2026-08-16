#lang racket/base

;; test/mock-chat.rkt — a minimal OpenAI-compatible chat endpoint that echoes the
;; model it received and the last user message, so a test can prove WHICH backend
;; answered.  racket test/mock-chat.rkt [PORT]

(require racket/tcp racket/string json)

(define argv (current-command-line-arguments))
(define port (string->number (if (> (vector-length argv) 0) (vector-ref argv 0) "11500")))

(define (last-user msgs)
  (for/fold ([acc ""]) ([m (in-list (if (list? msgs) msgs '()))]
                        #:when (and (hash? m) (equal? (hash-ref m 'role #f) "user")))
    (format "~a" (hash-ref m 'content ""))))

(define (read-headers in)
  (let loop ([hs '()])
    (define l (read-line in 'return-linefeed))
    (if (or (eof-object? l) (string=? l "")) (reverse hs) (loop (cons l hs)))))
(define (content-length headers)
  (cond [(for/first ([h (in-list headers)] #:when (regexp-match? #rx"(?i:^content-length:)" h)) h)
         => (lambda (h) (or (string->number (string-trim (cadr (regexp-split #rx":" h)))) 0))]
        [else 0]))

(define (handle in out)
  (with-handlers ([exn:fail? (lambda (_) (void))])
    (read-line in 'return-linefeed)
    (define headers (read-headers in))
    (define body (let ([b (read-bytes (content-length headers) in)]) (if (eof-object? b) #"" b)))
    (define req (with-handlers ([exn:fail? (lambda (_) (hasheq))]) (string->jsexpr (bytes->string/utf-8 body #\?))))
    (define model (format "~a" (hash-ref req 'model "?")))
    (define reply (format "[~a] ~a" model (last-user (hash-ref req 'messages '()))))
    (define resp
      (hasheq 'choices (list (hasheq 'index 0 'finish_reason "stop"
                                     'message (hasheq 'role "assistant" 'content reply)))
              'usage (hasheq 'total_tokens 42)))
    (define payload (jsexpr->bytes resp))
    (write-string (string-append "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
                                 "Content-Length: " (number->string (bytes-length payload)) "\r\n"
                                 "Connection: close\r\n\r\n") out)
    (write-bytes payload out)
    (flush-output out))
  (close-input-port in)
  (close-output-port out))

(define listener (tcp-listen port 64 #t "127.0.0.1"))
(printf "mock-chat on 127.0.0.1:~a\n" port)
(flush-output)
(let loop ()
  (define-values (i o) (tcp-accept listener))
  (thread (lambda () (handle i o)))
  (loop))
