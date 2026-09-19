#lang racket/base

;; test/content-tests.rkt — message content parts and response formats (issue #18).
;;
;; The bug these pin is a SILENT one: `(if (string? c) c "")` read every reply, so
;; a provider answering with content parts produced an empty message and no
;; complaint. Every case here therefore checks the text that comes out AND that an
;; unreadable content is named rather than quietly empty.
;;   raco test test/content-tests.rkt

(require rackunit
         "../domain/ai/content.rkt"
         "../domain/ai/executor.rkt"          ; parse-chat-response
         "../domain/agent/llm.rkt"            ; chat-response->assistant-msg
         "../domain/agent/loop.rkt")          ; assistant-msg-text

(define (text-of c) (let-values ([(t _p) (content->text c)]) t))
(define (problem-of c) (let-values ([(_t p) (content->text c)]) p))

(test-case "content->text: a string, nothing, and parts"
  (check-equal? (text-of "plain") "plain")
  (check-false (problem-of "plain"))
  ;; a tool-call-only turn has no content, and that is not a problem
  (check-equal? (text-of 'null) "")
  (check-false (problem-of 'null))
  (check-equal? (text-of '()) "")
  (check-false (problem-of '()))
  ;; the shape that used to become ""
  (define parts (list (hasheq 'type "text" 'text "Hello, ")
                      (hasheq 'type "text" 'text "world")))
  (check-equal? (text-of parts) "Hello, world")
  (check-false (problem-of parts))
  ;; text parts are taken even when something else rides along
  (check-equal? (text-of (list (hasheq 'type "image_url" 'image_url (hasheq 'url "http://x/y.png"))
                               (hasheq 'type "text" 'text "the invoice")))
                "the invoice"))

(test-case "content->text: content that carries no text is named, never quietly empty"
  (define p (problem-of (list (hasheq 'type "image_url" 'image_url (hasheq 'url "http://x/y.png")))))
  (check-true (and p #t))
  (check-regexp-match #rx"none is text" p)
  (check-regexp-match #rx"image_url" p)                    ; says WHAT arrived
  (check-regexp-match #rx"no type" (problem-of (list (hasheq 'text "loose"))))
  (check-regexp-match #rx"neither a string nor a list" (problem-of 42)))

(test-case "content-problem: what may be SENT"
  (check-false (content-problem "a string is fine"))
  (check-false (content-problem 'null))
  (check-false (content-problem (list (hasheq 'type "text" 'text "hi"))))
  (check-false (content-problem (list (hasheq 'type "image_url" 'image_url (hasheq 'url "http://x/y.png")))))
  (check-regexp-match #rx"unsupported type" (content-problem (list (hasheq 'type "input_audio"))))
  (check-regexp-match #rx"no \"type\"" (content-problem (list (hasheq 'text "hi"))))
  (check-regexp-match #rx"needs a string" (content-problem (list (hasheq 'type "text" 'text 7))))
  (check-regexp-match #rx"image_url" (content-problem (list (hasheq 'type "image_url" 'image_url "http://x"))))
  (check-regexp-match #rx"part 1:" (content-problem (list (hasheq 'type "text" 'text "ok")
                                                          (hasheq 'type "nope"))))   ; names WHICH part
  (check-regexp-match #rx"string or a list" (content-problem 42)))

(test-case "response-format-problem: the three OpenAI shapes and nothing invented"
  (check-false (response-format-problem (hasheq 'type "text")))
  (check-false (response-format-problem (hasheq 'type "json_object")))
  (check-false (response-format-problem
                (hasheq 'type "json_schema"
                        'json_schema (hasheq 'name "invoice" 'schema (hasheq 'type "object")))))
  (check-regexp-match #rx"not supported" (response-format-problem (hasheq 'type "yaml")))
  (check-regexp-match #rx"must be a string" (response-format-problem (hasheq 'type 3)))
  (check-regexp-match #rx"must be an object" (response-format-problem "json"))
  (check-regexp-match #rx"json_schema.name" (response-format-problem
                                             (hasheq 'type "json_schema" 'json_schema (hasheq 'schema (hasheq)))))
  (check-regexp-match #rx"json_schema.schema" (response-format-problem
                                               (hasheq 'type "json_schema" 'json_schema (hasheq 'name "x")))))

(define INVOICE
  (hasheq 'type "json_schema"
          'json_schema (hasheq 'name "invoice"
                               'schema (hasheq 'type "object"
                                               'properties (hasheq 'total (hasheq 'type "number")
                                                                   'currency (hasheq 'type "string"))
                                               'required '("total" "currency")))))

(test-case "response-format-verify: a schema is CHECKED, not merely requested"
  ;; the case that matters: a provider that ignores response_format and answers prose
  (define-values (p1 e1) (response-format-verify INVOICE "I could not find an invoice."))
  (check-regexp-match #rx"does not contain a JSON object" e1)
  ;; conforming, even wrapped in a fence and a sentence (the model's usual habit)
  (define-values (p2 e2) (response-format-verify INVOICE "Sure:\n```json\n{\"total\": 42, \"currency\": \"JPY\"}\n```"))
  (check-false e2)
  (check-equal? (hash-ref p2 'total) 42)
  ;; wrong type, and the refusal names the path — the pipeline's DWF-5 vocabulary
  (define-values (_p3 e3) (response-format-verify INVOICE "{\"total\": \"42\", \"currency\": \"JPY\"}"))
  (check-regexp-match #rx"[$][.]total" e3)
  (check-regexp-match #rx"expected number" e3)
  ;; a missing required field is refused too
  (define-values (_p4 e4) (response-format-verify INVOICE "{\"total\": 42}"))
  (check-regexp-match #rx"currency" e4)
  ;; json_object asks only for an object
  (define-values (p5 e5) (response-format-verify (hasheq 'type "json_object") "{\"anything\": true}"))
  (check-false e5)
  (check-true (hash? p5))
  ;; text, and no format at all, never refuse
  (define-values (_p6 e6) (response-format-verify (hasheq 'type "text") "prose"))
  (check-false e6)
  (define-values (_p7 e7) (response-format-verify #f "prose"))
  (check-false e7))

(test-case "outer-json reads the outermost object, or nothing"
  (check-equal? (hash-ref (outer-json "noise {\"a\": {\"b\": 1}} trailing") 'a) (hasheq 'b 1))
  (check-false (outer-json "no object here"))
  (check-false (outer-json "{not json}")))

(test-case "parse-chat-response reads a parts reply instead of emptying it"
  ;; a string reply, as before
  (define-values (r1 t1) (parse-chat-response
                          (hasheq 'choices (list (hasheq 'message (hasheq 'content "Hi"))))))
  (check-equal? r1 "Hi")
  (check-false t1)
  ;; parts: this returned "" before the fix
  (define-values (r2 _t2) (parse-chat-response
                           (hasheq 'choices (list (hasheq 'message (hasheq 'content (list (hasheq 'type "text" 'text "Hi")
                                                                                          (hasheq 'type "text" 'text " there"))))))))
  (check-equal? r2 "Hi there")
  ;; content that carries no text at all is an error, not an empty answer
  (check-exn #rx"could not be read as text"
             (lambda () (parse-chat-response
                         (hasheq 'choices (list (hasheq 'message (hasheq 'content (list (hasheq 'type "image_url"
                                                                                                'image_url (hasheq 'url "http://x")))))))))))

(test-case "the agent parser reads parts too, and tolerates a tool-call-only turn"
  (define msg (chat-response->assistant-msg
               (hasheq 'choices (list (hasheq 'message (hasheq 'content (list (hasheq 'type "text" 'text "done"))))))))
  (check-equal? (assistant-msg-text msg) "done")
  ;; no readable content, but the turn is a tool call — legitimate, not an error
  (define tc (hasheq 'id "call_1" 'type "function"
                     'function (hasheq 'name "notes_list" 'arguments "{}")))
  (define msg2 (chat-response->assistant-msg
                (hasheq 'choices (list (hasheq 'message (hasheq 'content 'null 'tool_calls (list tc)))))))
  (check-equal? (assistant-msg-text msg2) "")
  ;; …but unreadable content with NOTHING else is the silent-empty case
  (check-exn #rx"could not be read as text"
             (lambda () (chat-response->assistant-msg
                         (hasheq 'choices (list (hasheq 'message (hasheq 'content (list (hasheq 'type "audio"))))))))))

(test-case "run-chat refuses a malformed prompt and a format it cannot honour"
  (check-false (model-configured?))                        ; no model in the unit suite
  ;; a parts prompt works against the simulated fallback: the TEXT is what it echoes
  (define-values (reply _t) (run-chat (list (hasheq 'type "text" 'text "hello")
                                            (hasheq 'type "text" 'text " world"))))
  (check-equal? reply "HELLO WORLD")
  (check-exn #rx"unsupported type" (lambda () (run-chat (list (hasheq 'type "video")))))
  (check-exn #rx"not supported" (lambda () (run-chat "hi" #:response-format (hasheq 'type "yaml"))))
  ;; the fallback cannot honour a schema, and must say so rather than hand back an
  ;; upper-cased echo as if it had
  (check-exn #rx"no model configured"
             (lambda () (run-chat "hi" #:response-format (hasheq 'type "json_object")))))
