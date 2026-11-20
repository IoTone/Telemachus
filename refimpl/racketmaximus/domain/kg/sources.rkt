#lang racket/base

;; domain/kg/sources.rkt: documents a plugin keeps, lent to the knowledge graph.
;;
;; The graph's mention rule is that a fact is visible iff one of its mentions is on a
;; document the caller may read. The repository is one authority on "may read"; this is the
;; seam for the others. A plugin registers a source, the platform asks it four questions, and
;; from then on its documents are enumerated, extracted, cited and forgotten exactly as a
;; repository document is.
;;
;; FOUR PROCEDURES AND NOT ONE, BECAUSE THE COSTS DIFFER. `see` is asked once per mention on
;; every graph read; `text` is asked once per document and only when it is about to be sent
;; to a model. One call that returned the text would decrypt a document to answer a citation,
;; and a graph read with forty mentions would decrypt forty texts.
;;
;;   #:list    (conn p team limit)      -> (listof doc-id)          enumerate, capped
;;   #:see     (conn p team doc-id)     -> (hasheq 'key <string>) or #f
;;   #:version (conn p team doc-id)     -> string or #f             the current version
;;   #:text    (conn p team doc-id)     -> string or #f             #f or "" means no text
;;
;; `team` is the team the QUESTION is about, never a permission the platform checks. `see` is
;; asked with the team the mention was recorded for; a bare id is resolved with the caller's
;; own team. A source must treat #f as "not readable", because an operator principal has no team.

(require racket/string
         (only-in "../sched/scheduler.rkt" current-plugin))

(provide register-extraction-source! unregister-extraction-source! extraction-source
         extraction-sources SOURCE-NAME-PATTERN
         kg-source-id kg-source-id? kg-source-id-split
         source-list source-see source-version source-text source-window)

;; ONE HOME FOR THE GRAMMAR. The name is validated at registration and re-used to parse an
;; encoded id, so a name that registration accepts is a name parsing accepts. The colon is
;; excluded because the encoded id splits on the FIRST one and the rest is the plugin's own
;; document id, which may be anything at all.
(define SOURCE-NAME-PATTERN "[a-z][a-z0-9._-]{0,63}")
(define SOURCE-NAME-RX (pregexp (format "^~a$" SOURCE-NAME-PATTERN)))
;; `pregexp` matches STRINGS and answers STRINGS, where a `#px` literal is a byte pattern and
;; would need bytes->string/utf-8 on each group. `(?s:...)` is scoped so `.` crosses a newline,
;; which a document id may contain. A scoped flag group is NOT a capture, so the text needs its
;; own parentheses around it.
(define KG-SOURCE-ID-RX (pregexp (format "^kg-src:(~a):((?s:.+))$" SOURCE-NAME-PATTERN)))

(define *sources* (make-hash))            ; name -> (cons owner fns)

(define (register-extraction-source! name fns)
  (define nm (and (string? name) (regexp-match? SOURCE-NAME-RX name) name))
  (unless nm
    (error 'register-extraction-source!
           "a source name must match ~a and must not contain ':', because the encoded document id splits on the first one: ~s"
           SOURCE-NAME-PATTERN name))
  (unless (hash? fns) (error 'register-extraction-source! "~a: the source must be a hash of procedures" nm))
  (for ([k '(list see version text)])
    (unless (procedure? (hash-ref fns k #f))
      (error 'register-extraction-source! "~a: ~a must be a procedure" nm k)))
  ;; the register-extractor! rule (extract.rkt:141): ownership comes from the loader's
  ;; parameter, a second claim by a DIFFERENT owner is refused, and re-registering your own is
  ;; fine because the loader may run twice in one process.
  (define pid (current-plugin))
  (define owner (let ([e (hash-ref *sources* nm #f)]) (and e (car e))))
  (when (and owner (not (equal? owner pid)))
    (error 'register-extraction-source! "source ~s is already claimed by plugin ~a" nm owner))
  (hash-set! *sources* nm (cons pid fns))
  nm)

(define (unregister-extraction-source! name) (hash-remove! *sources* name))
(define (extraction-source name) (let ([e (hash-ref *sources* (and (string? name) name) #f)]) (and e (cdr e))))
(define (extraction-sources) (sort (hash-keys *sources*) string<?))

;; THE PLUGIN NEVER COMPOSES THIS ID and the platform takes one apart nowhere else, so the
;; format has one home. A repository id is a UUIDv4 (`db/id.rkt:18-26`), which is hex and
;; dashes, so it cannot begin with the prefix and the two id spaces cannot collide.
;; IT VALIDATES, because an id that does not parse does not fail loudly: it makes every mention
;; written under it invisible on the next read, which is a document that silently contributes
;; nothing. Registration would have refused this name and the pattern cannot match an empty doc
;; id, so both are refused here too rather than producing an id that resolves to nothing.
(define (kg-source-id source doc-id)
  (unless (and (string? source) (regexp-match? SOURCE-NAME-RX source))
    (error 'kg-source-id "not a source name this registry accepts: ~s" source))
  (unless (and (string? doc-id) (not (string=? doc-id "")))
    (error 'kg-source-id "~a: a document id must be a non-empty string, not ~s" source doc-id))
  (format "kg-src:~a:~a" source doc-id))

(define (kg-source-id? v) (and (string? v) (regexp-match? KG-SOURCE-ID-RX v) #t))

;; -> (cons source-name doc-id) or #f
(define (kg-source-id-split v)
  (define m (and (string? v) (regexp-match KG-SOURCE-ID-RX v)))
  (and m (cons (list-ref m 1) (list-ref m 2))))

;; ---- one seam for calling a plugin ----------------------------------------
;; A plugin that raises must not take a graph read down, which is LAY-7's rule for an
;; extractor ("a plugin that raises is 'failed, never an exception"). The swallow is not
;; silent: a bug in a source would otherwise read as "this team has no facts", so the reason
;; goes to stderr once per failed call, RED-17's posture for a swallow that protects a request.
(define (source-call name which key . args)
  (define fns (extraction-source name))
  (cond
    ;; the source was unregistered between the list and the question, or the name never parsed.
    ;; One answer, the same one an absent document gets.
    [(not fns) #f]
    [else
     (with-handlers ([exn:fail?
                      (lambda (e)
                        (eprintf "kg source ~a: ~a failed: ~a\n" name which
                                (let ([m (exn-message e)])
                                  (if (> (string-length m) 400) (substring m 0 400) m)))
                        #f)])
       (apply (hash-ref fns key) args))]))

;; each wrapper narrows the answer to the shape the rest of the file may rely on, so no call
;; site has to defend against a plugin returning something else
(define (source-list name conn p team limit)
  (let ([xs (source-call name "list" 'list conn p team limit)])
    (if (list? xs) (filter string? xs) '())))

(define (source-see name conn p team doc-id)
  (define r (source-call name "see" 'see conn p team doc-id))
  (and (hash? r) (string? (hash-ref r 'key #f)) r))

(define (source-version name conn p team doc-id)
  (define v (source-call name "version" 'version conn p team doc-id))
  (and (string? v) (not (string=? v "")) v))

(define (source-text name conn p team doc-id)
  (define t (source-call name "text" 'text conn p team doc-id))
  (and (string? t) t))

;; HOW MUCH OF A DOCUMENT GOES INTO ONE MODEL CALL, if the source wants to say. Optional, because
;; most sources have no reason to: the platform's default is a 7B model's window. It is asked per
;; document because a source may know that one document is prose and another is a table, and it is
;; looked up directly rather than through `source-call` so that a source which does not provide it
;; is silent rather than noisy on stderr for every document.
(define (source-window name conn p team doc-id default)
  (define fns (extraction-source name))
  (define f (and fns (hash-ref fns 'window #f)))
  (define v (and f (source-call name "window" 'window conn p team doc-id)))
  (if (and (integer? v) (> v 0)) v default))
