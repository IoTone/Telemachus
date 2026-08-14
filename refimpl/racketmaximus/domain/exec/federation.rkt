#lang racket/base

;; domain/exec/federation.rkt — the pluggable compute seam (slice 18).
;;
;; The reference impl runs work on a single local node ("local", configured by
;; env in domain/ai/executor.rkt). Federation adds a registry of NAMED executors
;; — additional OpenAI-compatible backends (a second GPU box, a remote inference
;; node, an HPC gateway) — that run-chat can be routed to per request. The seam
;; is config-only here; standing up real remote/HPC compute plugs in behind it.
;;
;; Config (JSON):
;;   { "executors": [ { "name": "gpu-node", "url": "http://…/v1/chat/completions",
;;                      "model": "llama-70b", "key": "…" } ] }

(require json)

(provide register-executor! list-executors executor-config executor-exists? connect-executors!)

(struct ex (name url model key) #:transparent)
(define *execs* (box '()))

(define (find name) (for/or ([e (in-list (unbox *execs*))]) (and (string=? (ex-name e) name) e)))

(define (register-executor! name #:url url #:model [model "local"] #:key [key #f])
  (set-box! *execs* (cons (ex name url model key)
                          (filter (lambda (e) (not (string=? (ex-name e) name))) (unbox *execs*)))))

(define (executor-exists? name) (and (find name) #t))

;; -> (list url model key) or #f
(define (executor-config name) (let ([e (find name)]) (and e (list (ex-url e) (ex-model e) (ex-key e)))))

;; for display — never leaks keys
(define (list-executors)
  (for/list ([e (in-list (reverse (unbox *execs*)))])
    (hasheq 'name (ex-name e) 'url (ex-url e) 'model (ex-model e) 'remote #t)))

(define (connect-executors! path #:log [log void])
  (when (file-exists? path)
    (define cfg (with-handlers ([exn:fail? (lambda (_) (hasheq))]) (call-with-input-file path read-json)))
    (for ([e (in-list (let ([xs (hash-ref cfg 'executors '())]) (if (list? xs) xs '())))]
          #:when (and (hash? e) (hash-ref e 'name #f) (hash-ref e 'url #f)))
      (define name (format "~a" (hash-ref e 'name)))
      (register-executor! name #:url (format "~a" (hash-ref e 'url))
                          #:model (format "~a" (hash-ref e 'model "local"))
                          #:key (let ([k (hash-ref e 'key #f)]) (and k (format "~a" k))))
      (log (format "~a — ~a" name (hash-ref e 'url)))))
  (list-executors))
