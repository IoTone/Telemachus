#lang racket/base

;; Example third-party plugin. It knows nothing about Telemachus internals: it
;; provides `tools`, a list of (name schema permission handler) tuples, where the
;; schema is a plain OpenAI-compatible function-tool JSON and the handler is
;;   (conn principal args) -> string.
;; This whole file is the extension contract.

(require racket/string)

(provide tools)

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
