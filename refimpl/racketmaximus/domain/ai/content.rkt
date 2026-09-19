#lang racket/base

;; domain/ai/content.rkt — message content and response formats (issue #18).
;;
;; Two things used to be true of every chat path here, and both were silent:
;;
;;   • a message's content was a plain STRING. `(if (string? c) c "")` is what
;;     read a reply, so a provider that answered with content PARTS — the
;;     OpenAI-compatible `[{type:"text",text:"…"}]` shape that gateways and
;;     multimodal servers use — produced an empty message and no complaint.
;;   • there was no response format, so schema-shaped output had nowhere to ride
;;     and a caller wanting JSON could only ask in prose and hope.
;;
;; This module is the one place both are decided, so the agent loop, the chat
;; endpoint, the streaming endpoint and the pull wire cannot disagree.
;;
;; THE RULE FOR PARTS: text is joined, and anything that is NOT text is named in
;; a problem rather than dropped. An empty reply is a legitimate answer only when
;; the model said nothing (content null or absent, e.g. a tool-call-only turn);
;; an empty reply produced by throwing parts away is a bug that looks like a quiet
;; model, which is the failure this module exists to prevent.
;;
;; THE RULE FOR A RESPONSE FORMAT: the format is passed to the provider AND the
;; reply is checked against it here. A provider that ignores `response_format`
;; (most local servers do) must not be able to answer a schema request with prose
;; that the caller then parses as if it had conformed. The refusal names the path
;; (`$.total: expected number, got string`), the same vocabulary the document
;; pipeline's extraction refuses in (DWF-5) — and deliberately the same validator,
;; so "what conforms" has one answer on this platform.

(require racket/string racket/list json
         "../tools/jsonschema.rkt")

(provide content->text content-problem
         response-format-problem response-format-verify response-format-parse
         outer-json)

;; ---- message content --------------------------------------------------------

;; What kind of part is this, for a problem message?
(define (part-kind p)
  (cond [(not (hash? p)) "not an object"]
        [(string? (hash-ref p 'type #f)) (hash-ref p 'type)]
        [else "a part with no type"]))

;; content -> (values text problem). `problem` is #f, or a string naming why the
;; content could not be read as text. A string is itself; null/absent and an empty
;; list are the empty string with NO problem (the model said nothing, which a
;; tool-call-only turn does legitimately); a list of parts is its text parts
;; joined, and a list with no text part at all is a problem, never a quiet "".
(define (content->text c)
  (cond
    [(string? c) (values c #f)]
    [(or (eq? c 'null) (not c)) (values "" #f)]
    [(null? c) (values "" #f)]
    [(list? c)
     (define texts (for/list ([p (in-list c)]
                              #:when (and (hash? p)
                                          (equal? (hash-ref p 'type #f) "text")
                                          (string? (hash-ref p 'text #f))))
                     (hash-ref p 'text)))
     (if (pair? texts)
         (values (string-join texts "") #f)
         (values "" (format "the content carries ~a part(s) and none is text (~a)"
                            (length c) (string-join (map part-kind c) ", "))))]
    [else (values "" "the content is neither a string nor a list of parts")]))

;; Is this content sendable? -> #f, or a string naming the problem.
;;
;; Checked on the way OUT as well as in, because an unknown part shape reaches the
;; provider as an opaque 400 ("Invalid value: …") that says nothing about which
;; message was wrong. Only the two part types the platform can honestly claim to
;; pass through are allowed; adding one is a deliberate act, not an accident of
;; whatever a caller posted.
(define ALLOWED-PART-TYPES '("text" "image_url"))
(define (content-problem c)
  (cond
    [(string? c) #f]
    [(eq? c 'null) #f]
    [(list? c)
     (for/or ([p (in-list c)] [i (in-naturals)])
       (define (at msg) (format "content part ~a: ~a" i msg))
       (cond
         [(not (hash? p)) (at "not an object")]
         [(not (string? (hash-ref p 'type #f))) (at "no \"type\"")]
         [(not (member (hash-ref p 'type) ALLOWED-PART-TYPES))
          (at (format "unsupported type ~s (this platform passes ~a)"
                      (hash-ref p 'type) (string-join ALLOWED-PART-TYPES " and ")))]
         [(and (equal? (hash-ref p 'type) "text") (not (string? (hash-ref p 'text #f))))
          (at "a text part needs a string \"text\"")]
         [(and (equal? (hash-ref p 'type) "image_url")
               (not (let ([u (hash-ref p 'image_url #f)])
                      (and (hash? u) (string? (hash-ref u 'url #f))))))
          (at "an image_url part needs {\"image_url\": {\"url\": \"…\"}}")]
         [else #f]))]
    [else "content must be a string or a list of parts"]))

;; ---- response formats -------------------------------------------------------

;; The outermost {…} of a reply, parsed — a model that wraps its JSON in a fence
;; or a sentence is still read; one that returns no object at all is refused by
;; the caller. (The document pipeline's extraction reads replies the same way;
;; this is that function, shared, so the two cannot drift.)
(define (outer-json raw)
  (define a (for/first ([i (in-naturals)] [c (in-string raw)] #:when (char=? c #\{)) i))
  (define b (for/last  ([i (in-naturals)] [c (in-string raw)] #:when (char=? c #\})) i))
  (and a b (> b a)
       (with-handlers ([exn:fail? (lambda (_) #f)])
         (string->jsexpr (substring raw a (add1 b))))))

;; Is this a response format this platform accepts? -> #f, or the problem.
;; The three OpenAI shapes, and nothing invented: a caller's `response_format`
;; goes to the provider verbatim, so accepting a shape we do not understand would
;; mean forwarding it and then checking nothing.
(define (response-format-problem rf)
  (cond
    [(not (hash? rf)) "response_format must be an object"]
    [else
     (define type (hash-ref rf 'type #f))
     (cond
       [(not (string? type)) "response_format.type must be a string"]
       [(equal? type "text") #f]
       [(equal? type "json_object") #f]
       [(equal? type "json_schema")
        (define js (hash-ref rf 'json_schema #f))
        (cond
          [(not (hash? js)) "response_format.json_schema must be an object"]
          [(not (string? (hash-ref js 'name #f))) "response_format.json_schema.name must be a string"]
          [(not (hash? (hash-ref js 'schema #f))) "response_format.json_schema.schema must be an object"]
          [else #f])]
       [else (format "response_format.type ~s is not supported (text, json_object, json_schema)" type)])]))

;; text × format -> (values parsed problem). `parsed` is the JSON value the reply
;; carried ('null for a text format), `problem` a string naming why the reply does
;; not honour the format. Called on EVERY reply for a format the caller asked for,
;; including one from a provider that ignored the field.
(define (response-format-verify rf text)
  (define type (and (hash? rf) (hash-ref rf 'type #f)))
  (cond
    [(or (not rf) (equal? type "text")) (values 'null #f)]
    [else
     (define j (outer-json text))
     (cond
       [(not (hash? j))
        (values 'null "the reply does not contain a JSON object")]
       [(equal? type "json_object") (values j #f)]
       [(equal? type "json_schema")
        (define schema (hash-ref (hash-ref rf 'json_schema (hasheq)) 'schema (hasheq)))
        (define problems (validate-json schema j))
        (if (null? problems) (values j #f) (values j (string-join problems "; ")))]
       [else (values j #f)])]))

;; The parsed value of a reply already known to honour `rf` — for a caller that
;; wants the object beside the text without validating a second time.
(define (response-format-parse rf text)
  (if (or (not rf) (equal? (and (hash? rf) (hash-ref rf 'type #f)) "text"))
      'null
      (let ([j (outer-json text)]) (if (hash? j) j 'null))))
