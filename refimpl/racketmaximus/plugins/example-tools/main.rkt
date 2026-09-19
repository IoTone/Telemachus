#lang racket/base

;; Example third-party plugin. It knows nothing about Telemachus internals: it
;; provides `tools`, a list of (name schema permission handler) tuples, where the
;; schema is a plain OpenAI-compatible function-tool JSON and the handler is
;;   (conn principal args) -> string.
;; This whole file is the extension contract.

(require racket/string
         (only-in "../../domain/sched/scheduler.rkt" register-job-kind!))

(provide tools routes init!)

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

;; A background JOB KIND (issue #21). `init!` runs at load with full SDK access,
;; and this is the documented route for a plugin to add one. The platform binds
;; the plugin's identity while init! runs, so the kind MUST be named
;; `x.<plugin-id>.<name>` — a plugin can never take a core kind's name
;; (`flow.step`, `infer.chat`) or another plugin's, and a violation fails this
;; plugin's load rather than surfacing at claim time.
;;
;; A kind's handler is (conn principal payload) -> jsexpr, run by the scheduler:
;; the job carries the enqueuing team and user, so the per-team concurrency cap,
;; quota admission, the org gate, cancellation and the lease all apply to it
;; exactly as they do to a core kind. Nothing is inherited from the plugin.
(define (word-count-job conn principal payload)
  (define text (let ([v (hash-ref payload 'text "")]) (if (string? v) v "")))
  (hasheq 'words (length (string-split text))))

(define (init!)
  (register-job-kind! "x.example-tools.word-count" word-count-job))
