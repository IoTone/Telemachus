#lang racket/base

;; server/api/annotations.rkt — regions a person marked on a document (#65).

(provide ep-annotations-list ep-annotations-create ep-annotation-get
         ep-annotation-patch ep-annotation-delete)

(require db-kit/portable
         web-kit
         json
         (only-in "../../domain/authz/authz.rkt" principal-user-id require-perm)
         (only-in "../../domain/repo/annotations.rkt"
                  ANNOTATION-KINDS MAX-BODY annotation-create! annotation-delete!
                  annotation-get annotation-list annotation-problem annotation-update!)
         "../kit.rkt")

(define (num b k)
  (let ([v (hash-ref b k 'missing)])
    (cond [(eq? v 'missing) #f] [(eq? v 'null) #f] [(real? v) v] [else 'bad])))

(define (patch-num b k)
  (let ([v (hash-ref b k 'missing)])
    (cond [(eq? v 'missing) 'same] [(eq? v 'null) #f] [(real? v) v] [else 'bad])))

(define (bbox-of b k)
  (let ([v (hash-ref b k 'missing)])
    (cond [(eq? v 'missing) #f] [(eq? v 'null) #f] [(list? v) v] [else 'bad])))

(define (str b k [d #f])
  (let ([v (hash-ref b k 'missing)])
    (cond [(eq? v 'missing) d] [(eq? v 'null) #f] [(not v) #f] [else (format "~a" v)])))

(define (ep-annotations-list req id)
  (with-auth req (lambda (p)
    (require-perm db-conn p "files:read")
    (define v (query-param req 'version ""))
    (define rows (annotation-list db-conn p id
                                  #:version (cond [(equal? v "all") 'all]
                                                  [(and (string? v) (not (string=? v ""))) v]
                                                  [else 'current])
                                  #:review (let ([r (query-param req 'review "")])
                                             (and (string? r) (not (string=? r "")) r))))
    (cond
      ;; A refusal and a miss are ONE answer, as they are for the worker's
      ;; document read and in the knowledge graph: whether a document exists is
      ;; not a question this route should answer to somebody who cannot read it.
      [(not rows) (err "no such document" 404)]
      [else (json-response (hasheq 'object_id id 'annotations rows
                                   'kinds ANNOTATION-KINDS 'max_body MAX-BODY))]))))

(define (ep-annotations-create req id)
  (with-auth req (lambda (p)
    ;; `files:read`, deliberately, and the reasoning is in annotations.rkt: a
    ;; specialist handed a document to review holds the DSH-1 `view` capability,
    ;; and a review surface they cannot mark up is not a review surface. Nothing
    ;; about the document changes, and the row carries whose observation it is.
    (require-perm db-conn p "files:read")
    (define b (read-json-body req))
    (define kind (or (str b 'kind) "note"))
    (define body (str b 'body))
    (define page (num b 'page))
    (define bbox (bbox-of b 'bbox))
    (define start (num b 'start))
    (define end (num b 'end))
    (cond
      [(ormap (lambda (v) (eq? v 'bad)) (list page start end bbox))
       (err "`page`, `start` and `end` must be numbers and `bbox` a list of four" 400)]
      [else
       (define problem (annotation-problem #:kind kind #:body body #:page page #:bbox bbox
                                           #:start start #:end end))
       (cond
         [problem (err problem 400)]
         [else
          (define r (annotation-create! db-conn p id #:kind kind #:body body #:page page
                                        #:bbox bbox #:start start #:end end
                                        #:version (str b 'version_id)
                                        #:review (str b 'review_id)))
          (cond
            [(eq? r 'no-such-object) (err "no such document" 404)]
            [(eq? r 'no-such-version)
             (err "no such version of this document" 404)]
            [else (json-response (hasheq 'annotation (annotation-get db-conn p r)) #:code 201)])])]))))

(define (ep-annotation-get req id)
  (with-auth req (lambda (p)
    (require-perm db-conn p "files:read")
    (define a (annotation-get db-conn p id))
    (if a (json-response (hasheq 'annotation a)) (err "no such annotation" 404)))))

(define (ep-annotation-patch req id)
  (with-auth req (lambda (p)
    (require-perm db-conn p "files:read")
    (define b (read-json-body req))
    (define page (patch-num b 'page))
    (define start (patch-num b 'start))
    (define end (patch-num b 'end))
    (define bbox (let ([v (hash-ref b 'bbox 'missing)])
                   (cond [(eq? v 'missing) 'same] [(eq? v 'null) #f] [(list? v) v] [else 'bad])))
    (cond
      [(ormap (lambda (v) (eq? v 'bad)) (list page start end bbox))
       (err "`page`, `start` and `end` must be numbers and `bbox` a list of four" 400)]
      [else
       (define r (annotation-update! db-conn p id
                                     #:body (let ([v (hash-ref b 'body 'missing)])
                                              (cond [(eq? v 'missing) 'same]
                                                    [(eq? v 'null) #f]
                                                    [else (format "~a" v)]))
                                     #:page page #:bbox bbox #:start start #:end end))
       (cond
         [(not r) (err "no such annotation" 404)]
         ;; 403 and not 404: the request is fine, the person is wrong for this
         ;; item — LAY-3's four-eyes refusal takes the same line. An annotation
         ;; is somebody's own words, and a steward who may DELETE one still may
         ;; not rewrite it.
         [(eq? r 'not-author) (err "only the author may change an annotation — add your own instead" 403)]
         [(string? r) (err r 400)]
         [else (json-response (hasheq 'annotation r))])]))))

(define (ep-annotation-delete req id)
  (with-auth req (lambda (p)
    (require-perm db-conn p "files:read")
    (if (annotation-delete! db-conn p id)
        (json-response (hasheq 'ok #t))
        (err "no such annotation" 404)))))
