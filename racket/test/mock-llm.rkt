#lang racket/base

;; test/mock-llm.rkt — a deterministic OpenAI-compatible /v1/chat/completions
;; server for integration tests. No model, no network out: it drives the real
;; agent loop so the end-to-end path (loop → llm HTTP adapter → tool-call
;; protocol → exec dispatch) is exercised without a live model.
;;
;; Protocol: on a request whose `messages` contain NO role:"tool" entry (i.e.
;; the first round), it emits ONE tool_call read from MOCK_CALL_FILE — a JSON
;; object {"name": "...", "arguments": "<json-string>"}. Once a tool result is
;; in the history, it emits a final assistant text ("DONE — ...") so the agent
;; loop terminates. The call file is re-read per request, so one long-lived
;; server serves every scenario (the test rewrites the file between runs).
;;
;;   MOCK_PORT=8900 MOCK_CALL_FILE=/tmp/call.json racket test/mock-llm.rkt

(require racket/tcp racket/string racket/file json)

(define port (string->number (or (getenv "MOCK_PORT") "8900")))
(define call-file (or (getenv "MOCK_CALL_FILE") "/tmp/mock-call.json"))

(define BOM (integer->char #xFEFF))
(define (strip-bom s)                                  ; tolerate a UTF-8 BOM (Windows editors)
  (if (and (> (string-length s) 0) (char=? (string-ref s 0) BOM)) (substring s 1) s))
(define (tool-call-response)
  (define spec
    (with-handlers ([exn:fail? (lambda (_) (hasheq 'name "ls" 'arguments "{}"))])
      (string->jsexpr (strip-bom (file->string call-file)))))
  (hasheq 'id "chatcmpl-mock" 'object "chat.completion" 'model "mock"
          'choices
          (list (hasheq 'index 0 'finish_reason "tool_calls"
                        'message
                        (hasheq 'role "assistant" 'content ""
                                'tool_calls
                                (list (hasheq 'id "call_1" 'type "function"
                                              'function (hasheq 'name (hash-ref spec 'name)
                                                                'arguments (hash-ref spec 'arguments)))))))))

(define (final-response)
  (hasheq 'id "chatcmpl-mock" 'object "chat.completion" 'model "mock"
          'choices (list (hasheq 'index 0 'finish_reason "stop"
                                 'message (hasheq 'role "assistant"
                                                  'content "DONE — integration step complete.")))))

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
    (read-line in 'return-linefeed)                     ; request line (ignored)
    (define headers (read-headers in))
    ;; Content-Length is a BYTE count; the body is UTF-8 (tool schemas contain
    ;; multibyte chars like →), so read bytes — read-string would count chars
    ;; and block waiting for bytes that never arrive.
    (define body-bytes (let ([b (read-bytes (content-length headers) in)])
                         (if (eof-object? b) #"" b)))
    (define parsed (with-handlers ([exn:fail? (lambda (_) (hasheq))])
                     (string->jsexpr (bytes->string/utf-8 body-bytes #\?))))
    (define msgs (let ([m (hash-ref parsed 'messages '())]) (if (list? m) m '())))
    (define has-tool? (for/or ([m (in-list msgs)] #:when (hash? m))
                        (equal? (hash-ref m 'role #f) "tool")))
    (define payload (jsexpr->bytes (if has-tool? (final-response) (tool-call-response))))
    (write-string (string-append
                   "HTTP/1.1 200 OK\r\n"
                   "Content-Type: application/json\r\n"
                   "Content-Length: " (number->string (bytes-length payload)) "\r\n"
                   "Connection: close\r\n\r\n") out)
    (write-bytes payload out)
    (flush-output out))
  (close-input-port in)
  (close-output-port out))

(define listener (tcp-listen port 64 #t "127.0.0.1"))
(printf "mock-llm on 127.0.0.1:~a (call-file ~a)\n" port call-file)
(flush-output)
(let loop ()
  (define-values (in out) (tcp-accept listener))
  (thread (lambda () (handle in out)))
  (loop))
