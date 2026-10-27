#lang racket/base

;; #128 job 2: operator-facing variables are read through ONE accessor,
;; which tries TMACH_<name> and falls back to the old spelling.
(require (only-in "../../config.rkt" tmach-env))

;; domain/agent/llm.rkt — the #:llm effect: an OpenAI-compatible chat adapter.
;;
;; Splits into a PURE parser (chat-response->assistant-msg) — fully unit-tested —
;; and the impure HTTP call (openai-llm). The agent spine (loop.rkt) stays pure;
;; this is the edge. Tool calls in the response are decoded with the same
;; function-call->tool-block converter the rest of the system uses.

(require racket/port
         racket/string
         net/http-client
         net/url
         json
         "loop.rkt"                 ; assistant-msg
         "../ai/content.rkt"        ; content->text (issue #18)
         "../tools/convert.rkt")    ; function-call->tool-block

(provide chat-response->assistant-msg http-post-json
         stream-deltas->assistant-msg openai-llm-stream
         sanitize-wire-messages    ; exported for tests (wire scrub)
         read-sse-deltas http-post-stream   ; exported for tests (the idle timeout)
         (struct-out exn:fail:model-retryable)
         model-timeout model-idle-timeout model-retries)

;; Strip app-internal keys before sending messages to a provider. Internal
;; annotations like the untrusted-context `metadata` must not hit the wire —
;; many OpenAI-compatible servers reject unknown message fields. We project to
;; the OpenAI-permitted keys; the spine already builds well-formed role
;; sequences, so no further provider-quirk repair is needed here.
(define wire-allowed-keys '(role content name tool_call_id tool_calls function_call reasoning_content))
(define (sanitize-wire-messages messages)
  (for/list ([m (in-list messages)])
    (for/fold ([h (hasheq)]) ([k (in-list wire-allowed-keys)])
      (if (hash-has-key? m k) (hash-set h k (hash-ref m k)) h))))

;; canonical raw tool_call object echoed back to the model next round
(define (raw-call id name args) (hasheq 'id id 'type "function"
                                        'function (hasheq 'name name 'arguments args)))

;; ---- pure: parse a /v1/chat/completions response into an assistant-msg ------
;; Content PARTS are read here too (issue #18). A turn that carries tool calls may
;; legitimately have nothing readable as text — that is what a tool-call-only reply
;; looks like — so an unreadable content is only an error when it is ALL the model
;; said, which is the case where "" was indistinguishable from a quiet model.
(define (content-text-or-raise who c tool-calls?)
  (define-values (text problem) (content->text c))
  (when (and problem (not tool-calls?))
    (error who "the model's reply could not be read as text: ~a" problem))
  text)

(define (chat-response->assistant-msg resp)
  (define choices (hash-ref resp 'choices '()))
  (define msg (if (pair? choices) (hash-ref (car choices) 'message (hasheq)) (hasheq)))
  (define content
    (content-text-or-raise 'openai-llm (hash-ref msg 'content 'null)
                           (pair? (let ([t (hash-ref msg 'tool_calls '())]) (if (list? t) t '())))))
  ;; build (block . raw-call) pairs, dropping any the converter rejects so the
  ;; two stay aligned (loop pairs raw-call[i] with result[i]).
  (define pairs
    (for*/list ([(tc i) (in-indexed (in-list (let ([t (hash-ref msg 'tool_calls '())]) (if (list? t) t '()))))]
                [fn   (in-value (hash-ref tc 'function (hasheq)))]
                [name (in-value (hash-ref fn 'name ""))]
                [args (in-value (let ([a (hash-ref fn 'arguments "{}")]) (if (string? a) a (jsexpr->string a))))]
                [b    (in-value (function-call->tool-block name args))]
                #:when b)
      (cons b (raw-call (let ([id (hash-ref tc 'id #f)]) (if (string? id) id (format "call_~a" i)))
                        name args))))
  (assistant-msg content (map car pairs) (map cdr pairs)))

;; ---- timeouts and retries ---------------------------------------------------
;; `http-sendrecv` takes no timeout and nothing wrapped these calls, so a model
;; endpoint that accepted the connection and never answered hung the calling
;; thread for ever. In a scheduler job the lease reaper requeues the WORK after
;; 120s, but the thread stayed stuck holding its team's ai.concurrency slot, so a
;; flapping endpoint drained the pool while /health still said ok.
;;
;; The request runs in a thread under its OWN custodian: on a timeout we shut that
;; custodian down, which closes the TCP ports the request opened. Killing the
;; thread alone would leave the socket.
(define (env-num v default)               ; the VALUE since #128 job 2
  (define n (and v (string->number (string-trim v))))
  (if (and (real? n) (> n 0)) n default))

(define (model-timeout)      (env-num (tmach-env "MODEL_TIMEOUT") 120))
(define (model-idle-timeout) (env-num (tmach-env "MODEL_IDLE_TIMEOUT") 60))
(define (model-retries)      (inexact->exact (floor (env-num (tmach-env "MODEL_RETRIES") 1))))

;; A failure worth trying again: a timeout, an unreachable endpoint, a stalled
;; stream. `reason` is for the message and for tests, never for control flow.
(struct exn:fail:model-retryable exn:fail (reason) #:transparent)
(define (retryable! reason fmt . args)
  (raise (exn:fail:model-retryable (apply format fmt args) (current-continuation-marks) reason)))

;; 429 and 5xx are the server saying "later"; a 4xx is OUR malformed request and
;; retrying it only spends the budget again.
(define (retryable-code? code) (or (= code 429) (>= code 500)))

;; Run `thunk` with a deadline. Returns its value; raises on timeout. The value
;; must not hold anything owned by the custodian — the non-streaming path reads
;; its body to a string first, which is why this is safe there and why the
;; streaming path manages its own custodian instead.
(define (call-with-deadline secs who thunk)
  (define cust (make-custodian))
  (define ch (make-channel))
  (define t (parameterize ([current-custodian cust])
              (thread (lambda ()
                        (channel-put ch
                          (with-handlers ([(lambda (_) #t) (lambda (e) (cons 'raise e))])
                            (cons 'ok (thunk))))))))
  (define r (sync/timeout secs ch))
  (custodian-shutdown-all cust)
  (cond
    [(not r) (kill-thread t) (retryable! 'timeout "~a: no response within ~as" who secs)]
    [(eq? (car r) 'raise) (raise (cdr r))]
    [else (cdr r)]))

;; ---- impure: HTTP -----------------------------------------------------------
(define (status-code status) (let ([m (regexp-match #px#"\\b([0-9]{3})\\b" status)])
                               (if m (string->number (bytes->string/utf-8 (cadr m))) 0)))
(define (url-parts url)
  (define u (string->url url))
  (define ssl? (equal? (url-scheme u) "https"))
  (values (url-host u) (or (url-port u) (if ssl? 443 80)) ssl?
          (string-append "/" (string-join (map path/param-path (url-path u)) "/"))))

;; Both helpers open their OWN connection and close it, rather than calling
;; http-sendrecv, which abandons the socket under the response port — and
;; collection does not reclaim it, so every request leaked one descriptor for the
;; life of the process. Measured (PR #53): ten POSTs went 8 -> 18 descriptors with
;; http-sendrecv whether or not the response port was closed, and 7 -> 7 with
;; http-conn-open plus http-conn-close!. A worker long-polling /api/workers/claim
;; hit its 1024-descriptor limit in about five and a half hours and then failed
;; every claim with "Too many open files" while the process stayed alive.
;;
;; The deadline and the retry are the other half: http-sendrecv also takes no
;; timeout, so an endpoint that accepted the connection and never answered hung
;; the calling thread for ever, holding its team's ai.concurrency slot. The two
;; fixes are complementary — a leaked descriptor and an unbounded wait are
;; different failures of the same call — so the request runs under a deadline AND
;; closes its connection on every exit.

;; POST JSON, return (values status-code jsexpr) — non-streaming, with a deadline
;; and a bounded retry. A retry costs tokens, so the default is one.
(define (http-post-json url body-jsexpr headers
                        #:timeout [secs (model-timeout)] #:retries [tries (model-retries)])
  (define-values (host port ssl? path) (url-parts url))
  (define (once)
    (call-with-deadline secs 'model
      (lambda ()
        (with-handlers ([exn:fail:network?
                         (lambda (e) (retryable! 'network "model endpoint unreachable: ~a" (exn-message e)))])
          (define hc (http-conn-open host #:ssl? ssl? #:port port))
          ;; dynamic-wind, so the connection closes however the body exits — a server
          ;; error, a read failure, or one of the retryable! raises below. On the
          ;; DEADLINE path the thread is killed instead, and post thunks do not run
          ;; for a killed thread; the custodian in call-with-deadline is what closes
          ;; the socket there, because the connection was opened under it.
          (dynamic-wind
            void
            (lambda ()
              (define-values (status _hdrs in)
                (http-conn-sendrecv! hc path #:method #"POST"
                                     #:headers headers #:data (jsexpr->bytes body-jsexpr)))
              (define code (status-code status))
              (define body (port->string in))
              (close-input-port in)
              (define j (with-handlers ([exn:fail? (lambda (_) #f)]) (string->jsexpr body)))
              ;; A 200 whose body is not JSON is a proxy or a gateway answering for
              ;; the model; it used to raise an opaque read error deep in the parser.
              (when (and (= code 200) (not j))
                (retryable! 'malformed "model returned HTTP 200 with a body that is not JSON: ~a"
                            (substring body 0 (min 200 (string-length body)))))
              (list code (or j (hasheq 'error (substring body 0 (min 400 (string-length body)))))))
            (lambda () (http-conn-close! hc)))))))
  (let loop ([left tries] [n 1])
    (define out
      (with-handlers ([exn:fail:model-retryable?
                       (lambda (e) (if (> left 0) 'again (raise e)))])
        (define r (once))
        (if (and (> left 0) (retryable-code? (car r))) 'again r)))
    (cond
      [(eq? out 'again) (sleep (* 0.5 n)) (loop (sub1 left) (* 2 n))]
      [else (values (car out) (cadr out))])))

;; POST JSON, return (values status-code body-input-port shutdown!) — for SSE.
;;
;; A stream's body is read lazily, so the connection cannot be closed here: the
;; caller gets a `shutdown!` that closes both it and the custodian, and
;; openai-llm-stream calls it in a dynamic-wind. A connection kept open for a
;; stream is the one case where the caller owns it.
;;
;; The deadline covers connecting and the response HEADERS only — a long
;; generation is legitimate, and what bounds the body is the IDLE timeout in
;; read-sse-deltas. A streaming call is never retried: the caller has already been
;; handed tokens and replaying would duplicate them in front of the reader.
(define (http-post-stream url body-jsexpr headers #:timeout [secs (model-timeout)])
  (define-values (host port ssl? path) (url-parts url))
  (define cust (make-custodian))
  (define ch (make-channel))
  (define t (parameterize ([current-custodian cust])
              (thread (lambda ()
                        (channel-put ch
                          (with-handlers ([(lambda (_) #t) (lambda (e) (cons 'raise e))])
                            (define hc (http-conn-open host #:ssl? ssl? #:port port))
                            ;; a send that throws has no caller to hand the connection to
                            (with-handlers ([(lambda (_) #t)
                                             (lambda (e) (http-conn-close! hc) (raise e))])
                              (define-values (status _hdrs in)
                                (http-conn-sendrecv! hc path #:method #"POST"
                                                     #:headers headers #:data (jsexpr->bytes body-jsexpr)))
                              (cons 'ok (list (status-code status) in hc)))))))))
  (define r (sync/timeout secs ch))
  (cond
    [(not r) (custodian-shutdown-all cust) (kill-thread t)
             (retryable! 'timeout "model: no response headers within ~as" secs)]
    [(eq? (car r) 'raise) (custodian-shutdown-all cust) (raise (cdr r))]
    [else
     (define got (cdr r))
     (values (car got) (cadr got)
             (lambda ()
               (with-handlers ([(lambda (_) #t) void]) (http-conn-close! (caddr got)))
               (custodian-shutdown-all cust)))]))

;; ---- streaming -------------------------------------------------------------
;; Read an OpenAI SSE stream into the list of `delta` objects, invoking
;; on-content with each text chunk (for live output).
;; #:idle bounds the GAP between events, not the whole stream: a model that is
;; still emitting may legitimately take minutes, but one that stops mid-answer
;; used to leave the reader blocked in read-line for ever. Raising here hands the
;; caller a partial stream and an error, which is what the final SSE event is for.
(define (read-sse-deltas in on-content #:idle [idle (model-idle-timeout)])
  (let loop ([acc '()])
    (define line (sync/timeout idle (read-line-evt in 'any)))
    (cond
      [(not line) (retryable! 'idle "model stopped sending after ~as" idle)]
      [(eof-object? line) (reverse acc)]
      [(string-prefix? line "data:")
       (define payload (string-trim (substring line 5)))
       (cond
         [(string=? payload "[DONE]") (reverse acc)]
         [(string=? payload "") (loop acc)]
         [else
          (define chunk (with-handlers ([exn:fail? (lambda (_) #f)]) (string->jsexpr payload)))
          (cond
            [(not (hash? chunk)) (loop acc)]
            [else
             (define choices (hash-ref chunk 'choices '()))
             (define delta (if (pair? choices) (hash-ref (car choices) 'delta (hasheq)) (hasheq)))
             (let ([c (hash-ref delta 'content #f)])
               (when c (let-values ([(t _p) (content->text c)])
                         (unless (string=? t "") (on-content t)))))
             (loop (cons delta acc))])])]
      [else (loop acc)])))   ; skip blanks / comments

;; PURE: fold streamed deltas into a final assistant-msg. content chunks
;; concatenate; tool_calls arrive by `index` with name once and `arguments` in
;; pieces — reassemble per index, then decode with function-call->tool-block.
(define (stream-deltas->assistant-msg deltas)
  (define content (open-output-string))
  (define calls (make-hash))                 ; index -> mutable hash 'id/'name/'args
  (for ([d (in-list deltas)])
    (let ([c (hash-ref d 'content #f)])
      (when c (let-values ([(t _p) (content->text c)]) (write-string t content))))
    (for ([tc (in-list (let ([t (hash-ref d 'tool_calls '())]) (if (list? t) t '())))])
      (define idx (let ([i (hash-ref tc 'index 0)]) (if (number? i) i 0)))
      (define cur (hash-ref! calls idx (lambda () (make-hash (list (cons 'id #f) (cons 'name "") (cons 'args ""))))))
      (let ([id (hash-ref tc 'id #f)]) (when (string? id) (hash-set! cur 'id id)))
      (define fn (hash-ref tc 'function (hasheq)))
      (let ([n (hash-ref fn 'name #f)]) (when (and (string? n) (not (string=? n ""))) (hash-set! cur 'name n)))
      (let ([a (hash-ref fn 'arguments #f)]) (when (string? a) (hash-set! cur 'args (string-append (hash-ref cur 'args) a))))))
  (define pairs
    (for*/list ([idx (in-list (sort (hash-keys calls) <))]
                [cur  (in-value (hash-ref calls idx))]
                [name (in-value (hash-ref cur 'name))]
                [args (in-value (let ([a (hash-ref cur 'args)]) (if (string=? a "") "{}" a)))]
                [b    (in-value (function-call->tool-block name args))]
                #:when b)
      (cons b (raw-call (or (hash-ref cur 'id) (format "call_~a" idx)) name args))))
  (assistant-msg (get-output-string content) (map car pairs) (map cdr pairs)))

;; streaming #:llm — same shape as openai-llm, but reads SSE and (optionally)
;; emits content chunks live via #:on-content.
(define (openai-llm-stream #:endpoint endpoint #:model model
                           #:api-key [api-key #f] #:tools [tools '()]
                           #:temperature [temperature 0]
                           #:on-content [on-content void]
                           #:response-format [rf #f])
  (define headers
    (append (list "Content-Type: application/json")
            (if api-key (list (string-append "Authorization: Bearer " api-key)) '())))
  (lambda (messages)
    (define body (let ([b (hasheq 'model model 'messages (sanitize-wire-messages messages) 'stream #t
                                  'temperature temperature 'tool_choice "auto" 'tools tools)])
                   (if rf (hash-set b 'response_format rf) b)))
    (define-values (code in shutdown!) (http-post-stream endpoint body headers))
    ;; The connection is closed on every path, including a non-200 and an exception
    ;; thrown while the stream is read, for the same reason http-post-json does it:
    ;; an unclosed one costs a descriptor for the life of the process.
    (dynamic-wind
      void
      (lambda ()
        (unless (= code 200) (error 'openai-llm-stream "endpoint returned HTTP ~a" code))
        (stream-deltas->assistant-msg (read-sse-deltas in on-content)))
      (lambda ()
        (with-handlers ([(lambda (_) #t) void]) (close-input-port in))
        (shutdown!)))))
