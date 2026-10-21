#lang racket/base

;; server/api/translate.rkt — the Translation app
;;
;; Split out of main.rkt by #110 r3. The shared surface every handler here
;; needs — the pool, the request accessors, with-auth/with-mt, the response
;; constructors — is server/kit.rkt.

(provide ep-translate ep-translate-list ep-translate-catalog
         ep-glossary-list ep-glossary-add)

(require web-kit
         (only-in "../../domain/authz/authz.rkt" principal-team-id require-perm)
         (only-in "../../domain/apps/translate.rkt" glossary-add! glossary-list translate! translate-catalog! translate-list)
         (only-in "../../domain/orgs/orgs.rkt" tenant-quota-check tenant-quota-record!)
         (only-in "../../domain/quota/quota.rkt" get-limit)
         (only-in "../../domain/sched/governor.rkt" with-slot)
         (only-in "../../domain/ai/executor.rkt" estimate-tokens)
         "../kit.rkt"
         "../admission.rkt")

;; ---- Translation app --------------------------------------------------------
(define (ep-translate req)
  (with-auth req (lambda (p)
    (require-perm db-conn p "chat:use")
    (require-feature p "translate")
    (define b (read-json-body req))
    (define text (hash-ref b 'text ""))
    (define tgt (hash-ref b 'target_lang ""))
    (cond
      [(or (string=? text "") (string=? tgt "")) (err "text and target_lang required" 400)]
      [else
       (define sid (principal-team-id p))
       (define est (estimate-tokens text))
       (define rq (tenant-quota-check db-conn p "ai.requests" 1))
       (define tq (tenant-quota-check db-conn p "ai.tokens.total" est))
       (cond
         [(not (hash-ref rq 'allowed)) (quota-429 rq "ai.requests")]
         [(not (hash-ref tq 'allowed)) (quota-429 tq "ai.tokens.total")]
         [else
          (define-values (climit _w) (get-limit db-conn "team" sid "ai.concurrency"))
          (with-slot GOV (string-append "team:" sid) (or climit 2)
            (lambda (inflight)
              (define-values (job tokens)
                (translate! db-conn p #:text text #:target-lang tgt
                            #:source-lang (hash-ref b 'source_lang "auto")
                            #:use-glossary (and (hash-ref b 'use_glossary #t) #t)))
              (tenant-quota-record! db-conn p "ai.requests" 1)
              (tenant-quota-record! db-conn p "ai.tokens.total" tokens)
              (json-response (hash-set (hash-set job 'tokens_used tokens) 'concurrent inflight))))])]))))

(define (ep-translate-list req)
  (with-auth req (lambda (p) (json-response (hasheq 'translations (translate-list db-conn p))))))

(define (ep-translate-catalog req)
  (with-auth req (lambda (p)
    (require-perm db-conn p "chat:use")
    (require-feature p "translate")
    (define b (read-json-body req))
    (define cat (hash-ref b 'catalog (hasheq)))
    (define tgt (hash-ref b 'target_lang ""))
    (cond
      [(or (not (hash? cat)) (string=? tgt "")) (err "catalog (object) and target_lang required" 400)]
      [else
       (define sid (principal-team-id p))
       (define tq (tenant-quota-check db-conn p "ai.tokens.total" (estimate-tokens (format "~a" cat))))
       (cond
         [(not (hash-ref tq 'allowed)) (quota-429 tq "ai.tokens.total")]
         [else
          (define-values (climit _w) (get-limit db-conn "team" sid "ai.concurrency"))
          (with-slot GOV (string-append "team:" sid) (or climit 2)
            (lambda (_inflight)
              (define-values (out tokens) (translate-catalog! db-conn p #:catalog cat #:target-lang tgt))
              (tenant-quota-record! db-conn p "ai.tokens.total" tokens)
              (json-response (hasheq 'catalog out 'target_lang tgt 'tokens_used tokens))))])]))))

(define (ep-glossary-list req)
  (with-auth req (lambda (p) (json-response (hasheq 'glossary (glossary-list db-conn p))))))

(define (ep-glossary-add req)
  (with-auth req (lambda (p)
    (define b (read-json-body req))
    (define term (hash-ref b 'term ""))
    (define tr (hash-ref b 'translation ""))
    (define tgt (hash-ref b 'target_lang ""))
    (cond
      [(or (string=? term "") (string=? tr "") (string=? tgt "")) (err "term, translation, target_lang required" 400)]
      [else (json-response (glossary-add! db-conn p #:term term #:translation tr #:target-lang tgt))]))))
