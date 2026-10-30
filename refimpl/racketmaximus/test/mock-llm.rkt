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
;;
;; CHAT mode (slice 57): with MOCK_REPLY_FILE set, a request that offers NO tools
;; (a plain run-chat — extraction, translation) is answered from that file, a JSON
;; object of {"<needle>": "<reply>"}: the first needle found in the request's
;; message text wins, "*" is the default. Re-read per request, like the call file,
;; so one server scripts a whole pipeline: the extraction prompt carries the word
;; "schema", the translation prompt carries "translator".

(require racket/tcp racket/string racket/file racket/list json)

(define port (string->number (or (getenv "MOCK_PORT") "8900")))
(define call-file (or (getenv "MOCK_CALL_FILE") "/tmp/mock-call.json"))
(define reply-file (getenv "MOCK_REPLY_FILE"))
;; Answer every request with this status instead of 200, for a caller that needs
;; to see what a worker does when the model endpoint is refusing (issue #93).
;; A bad value is ignored rather than crashing the stub.
(define forced-status
  (let ([n (string->number (or (getenv "MOCK_STATUS") ""))])
    (and (exact-integer? n) (>= n 100) (< n 600) n)))

(define (chat-response parsed)
  (define table
    (with-handlers ([exn:fail? (lambda (_) (hasheq))])
      (string->jsexpr (strip-bom (file->string reply-file)))))
  ;; content may be a STRING or a list of parts (issue #18) — read both, or a
  ;; parts prompt would match no needle and every scripted scenario would look
  ;; like the default reply
  (define (content-text c)
    (cond [(string? c) c]
          [(list? c) (apply string-append
                            (for/list ([p (in-list c)]
                                       #:when (and (hash? p) (equal? (hash-ref p 'type #f) "text")
                                                   (string? (hash-ref p 'text #f))))
                              (hash-ref p 'text)))]
          [else ""]))
  (define text
    (apply string-append
           (for/list ([m (in-list (let ([m (hash-ref parsed 'messages '())]) (if (list? m) m '())))])
             (string-append (content-text (and (hash? m) (hash-ref m 'content ""))) "\n"))))
  ;; the LONGEST needle found in the request wins, so a specific needle can sit
  ;; beside a general one without depending on hash order
  (define hits
    (for/list ([(k v) (in-hash table)]
               #:when (and (not (eq? k '*)) (string? v) (string-contains? text (symbol->string k))))
      (cons (string-length (symbol->string k)) v)))
  (define reply
    (or (and (pair? hits) (cdr (argmax car hits)))
        (let ([d (hash-ref table '* #f)]) (and (string? d) d))
        "MOCK"))
  (hasheq 'id "chatcmpl-mock" 'object "chat.completion" 'model "mock"
          'usage (hasheq 'prompt_tokens 10 'completion_tokens 5 'total_tokens 15)
          'choices (list (hasheq 'index 0 'finish_reason "stop"
                                 'message (hasheq 'role "assistant" 'content reply)))))

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

;; STREAM mode: a request asking for `stream: true` gets the same scripted reply
;; back as SSE deltas, word by word, in the shape the real adapter reads
;; (`choices[0].delta.content`, then `[DONE]`). Added for #187: the streaming
;; path had no end-to-end coverage anywhere, which is how a defect that exists
;; ONLY on that path survived — the row it wrote was correct in every respect
;; except the one a team-scoped read needs.
(define (sse-chunk ev)
  (string-append "data: " (jsexpr->string ev) "\n\n"))
(define (stream-body reply)
  (define (delta c) (sse-chunk (hasheq 'id "chatcmpl-mock" 'object "chat.completion.chunk" 'model "mock"
                                       'choices (list (hasheq 'index 0 'delta (hasheq 'content c))))))
  (string-append
   (apply string-append (for/list ([w (in-list (string-split reply))]) (delta (string-append w " "))))
   (sse-chunk (hasheq 'id "chatcmpl-mock" 'object "chat.completion.chunk" 'model "mock"
                      'usage (hasheq 'prompt_tokens 10 'completion_tokens 5 'total_tokens 15)
                      'choices (list (hasheq 'index 0 'delta (hasheq) 'finish_reason "stop"))))
   "data: [DONE]\n\n"))

;; ---- EMBEDDINGS mode (#189 step 6) ---------------------------------------------
;;
;; A request carrying `input` and no `messages` is an embeddings request, so the
;; same process serves both and a harness needs one port. The vector is a
;; DETERMINISTIC BAG OF WORDS: each word is hashed into one of
;; `MOCK-EMBED-DIMS` buckets and counted.
;;
;; THAT CHOICE IS THE WHOLE POINT, not a convenience. A hash of the whole string
;; would be deterministic and useless — every text would land in a random
;; direction, so "the nearest passage" would be arbitrary and a smoke could only
;; assert that SOME passage came back. A bag of words puts texts that SHARE words
;; near each other, which is a crude stand-in for sharing meaning and is enough
;; for an end-to-end gate to assert that a question about octopuses retrieves the
;; passage about octopuses rather than the one beside it. It is NOT a stand-in
;; for a real embedder's recall — that is step 3's calibration and wants a live
;; `nomic-embed-text`, in English and Japanese.
;;
;; THE WIDTH IS A FIXTURE PARAMETER THAT DECIDES WHETHER THE GATE CAN
;; DISTINGUISH ANYTHING, and it was 32 first, which was too narrow to be useful.
;; Words collide into buckets, so a LONG text covers most of them and scores
;; respectably against any query at all — measured: at 32 dimensions a 440-byte
;; JSON classification record scored 0.276 against "cephalopods with arms" where
;; the sentence actually containing both words scored 0.144, so the gate ranked a
;; machine-generated record above the answer. 256 makes a collision between two
;; specific words unlikely, and is nearer the 768 a real checkpoint answers.
(define MOCK-EMBED-DIMS 256)

(define (word-bucket w)
  (modulo (for/fold ([h 7]) ([c (in-string (string-downcase w))])
            (modulo (+ (* h 31) (char->integer c)) 1000003))
          MOCK-EMBED-DIMS))

(define (mock-embedding text)
  (define v (make-vector MOCK-EMBED-DIMS 0.0))
  (for ([w (in-list (regexp-split #px"[^[:alnum:]]+" text))]
        #:when (> (string-length w) 0))
    (define b (word-bucket w))
    (vector-set! v b (+ 1.0 (vector-ref v b))))
  ;; a text with no word at all would be a zero vector, which the platform
  ;; deliberately refuses (VEC-22/VEC-31) — answer one, so that refusal is
  ;; reachable from a harness rather than only from a unit test
  (vector->list v))

(define (embeddings-response parsed)
  (define input (hash-ref parsed 'input '()))
  (define texts (cond [(string? input) (list input)]
                      [(list? input) (filter string? input)]
                      [else '()]))
  (hasheq 'object "list"
          'model (let ([m (hash-ref parsed 'model "mock-embed")]) (if (string? m) m "mock-embed"))
          'data (for/list ([(t i) (in-indexed texts)])
                  (hasheq 'object "embedding" 'index i 'embedding (mock-embedding t)))
          'usage (hasheq 'prompt_tokens (for/sum ([t (in-list texts)]) (string-length t))
                         'total_tokens (for/sum ([t (in-list texts)]) (string-length t)))))

(define (read-headers in)
  (let loop ([hs '()])
    (define l (read-line in 'return-linefeed))
    (if (or (eof-object? l) (string=? l "")) (reverse hs) (loop (cons l hs)))))

(define (content-length headers)
  (cond [(for/first ([h (in-list headers)] #:when (regexp-match? #rx"(?i:^content-length:)" h)) h)
         => (lambda (h) (or (string->number (string-trim (cadr (regexp-split #rx":" h)))) 0))]
        [else 0]))

;; ---- TRANSCRIPTION mode (#192) -------------------------------------------------
;;
;; A `multipart/form-data` body is a transcription request — the OpenAI
;; `/v1/audio/transcriptions` shape, the only one of the three that is not JSON.
;; Detected on the CONTENT TYPE rather than the path, because this mock reads the
;; request line and discards it.
;;
;; THE TRANSCRIPT IS THE "AUDIO" DECODED AS TEXT, which is what makes the gate
;; able to assert anything at all: a fixture puts a known sentence in the file
;; part, and the transcript is that sentence. A hash or a fixed string would be
;; deterministic and useless — the best a case could say is that SOMETHING came
;; back. It is not a claim about transcription; whether a real model hears the
;; words is a measurement, on a box with a model.
(define (multipart? headers)
  (for/or ([h (in-list headers)])
    (regexp-match? #rx"(?i:^content-type:.*multipart/form-data)" h)))

(define CRLF (string-append (string #\return) "?" (string #\newline)))

(define (multipart-field body name)
  (define pat (string-append "name=\"" name "\"" CRLF CRLF "(.*?)" CRLF "--"))
  (define m (regexp-match (pregexp pat) body))
  (and m (cadr m)))

(define FILE-PART-RX
  ;; Everything between the blank line after the file part own headers and the
  ;; boundary that follows it.
  ;;
  ;; CRLF IS A REAL CARRIAGE RETURN AND A REAL NEWLINE, not "\\r" and "\\n":
  ;; Racket regexps have no alphabetic escape for either, and `pregexp` raises
  ;; "illegal alphabetic escape" AT MODULE INSTANTIATION. Which killed this mock
  ;; the first time, so every model-backed assertion in doc-pipeline-smoke failed
  ;; with "connection refused" — while `raco make` stayed perfectly green, the
  ;; shape this project already records for a plugin that compiles and will not
  ;; load.
  (pregexp (string-append "(?s:filename=\"[^\"]*\"" CRLF
                          "[Cc]ontent-[Tt]ype:[^" (string #\return) (string #\newline) "]*" CRLF
                          CRLF "(.*?)" CRLF "--)")))

(define FILENAME-RX
  (pregexp (string-append "filename=\"([^\"]*)\"")))

(define (multipart-file-part body)
  (define m (regexp-match FILE-PART-RX body))
  (and m (cadr m)))

(define (transcription-response body)
  (define text (or (multipart-file-part body) ""))
  (define fname (let ([m (regexp-match FILENAME-RX body)]) (if m (cadr m) "")))
  (hasheq (quote text) (string-trim text)
          ;; the model the platform SENT, echoed back, so a case can assert
          ;; TMACH_TRANSCRIBE_MODEL reached the wire rather than a default
          (quote model) (or (multipart-field body "model") "")
          (quote response_format) (or (multipart-field body "response_format") "")
          ;; `verbose_json` is what the platform asks for, so the mock answers it —
          ;; including the two fields only that format carries, which is how a case
          ;; can assert the duration and the language reach the attributes.
          (quote duration) 3.5
          (quote language) "en"
          (quote filename) fname))

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
    (define offers-tools? (let ([t (hash-ref parsed 'tools '())]) (and (list? t) (pair? t))))
    ;; the embeddings branch comes FIRST: such a request has no `messages` at all,
    ;; so every test below it would read it as a first-round chat turn and answer
    ;; with a tool call, which is a 200 the platform cannot parse
    (define embeddings? (and (hash-ref parsed 'input #f) (null? msgs)))
    ;; …and the TRANSCRIPTION branch comes before both, because its body is not
    ;; JSON at all: `parsed` is an empty hash, so every test below would read it
    ;; as a first-round chat turn and answer with a tool call.
    (define transcribe? (multipart? headers))
    (define answer (cond [transcribe? (transcription-response
                                       (bytes->string/utf-8 body-bytes #\?))]
                         [embeddings? (embeddings-response parsed)]
                         [(and reply-file (not offers-tools?)) (chat-response parsed)]
                         [has-tool? (final-response)]
                         [else (tool-call-response)]))
    (define wants-stream? (and (eq? (hash-ref parsed 'stream #f) #t) (not forced-status) (not embeddings?) (not transcribe?)))
    (define payload
      (if wants-stream?
          (string->bytes/utf-8
           (stream-body (let* ([ch (hash-ref answer 'choices '())]
                               [m (and (pair? ch) (hash-ref (car ch) 'message (hasheq)))]
                               [c (and (hash? m) (hash-ref m 'content ""))])
                          (if (string? c) c ""))))
          (jsexpr->bytes answer)))
    (write-string (string-append
                   (if forced-status
                       (format "HTTP/1.1 ~a Refused\r\n" forced-status)
                       "HTTP/1.1 200 OK\r\n")
                   (if wants-stream?
                       "Content-Type: text/event-stream\r\n"
                       "Content-Type: application/json\r\n")
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
