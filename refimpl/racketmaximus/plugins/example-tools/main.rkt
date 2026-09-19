#lang racket/base

;; Example third-party plugin. It knows nothing about Telemachus internals: it
;; provides `tools`, a list of (name schema permission handler) tuples, where the
;; schema is a plain OpenAI-compatible function-tool JSON and the handler is
;;   (conn principal args) -> string.
;; This whole file is the extension contract.

(require racket/string)

(provide tools routes)

(define word-count-schema
  (hasheq 'type "function"
          'function (hasheq
                     'name "word_count"
                     'description "Count the number of words in a piece of text."
                     'parameters (hasheq
                                  'type "object"
                                  'properties (hasheq 'text (hasheq 'type "string"
                                                                    'description "The text to count words in"))
                                  'required '("text")))))

;; conn/principal are available for tools that need platform data; this one is pure.
(define (word-count conn principal args)
  (define text (let ([v (hash-ref args 'text "")]) (if (string? v) v "")))
  (format "~a words" (length (string-split text))))

(define tools
  (list (list "word_count" word-count-schema "chat:use" word-count)))

;; An authenticated HTTP route (slice 63): mounted by the platform at
;; /api/x/example-tools/word-count. `args` carries 'params (path), 'query and
;; 'body; the result is a jsexpr the server answers with as JSON. A user error is
;; the caller's 400. The permission is checked by the server before the handler
;; runs, like a tool's.
(define (word-count-route conn principal args)
  (define text (or (hash-ref (hash-ref args 'query) 'text #f)
                   (let ([b (hash-ref args 'body)]) (and (hash? b) (hash-ref b 'text #f)))))
  (unless (string? text) (raise-user-error 'word_count "text is required"))
  (hasheq 'words (length (string-split text)) 'chars (string-length text)))

(define routes
  (list (list "GET"  "/word-count" "chat:use" word-count-route "Count the words in ?text=.")
        (list "POST" "/word-count" "chat:use" word-count-route "Count the words in {text}.")))
