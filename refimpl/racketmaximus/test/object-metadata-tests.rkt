#lang racket/base

;; test/object-metadata-tests.rkt — LAY-4 (what a team asserts about a document)
;; and LAY-5 (where its text came from).
;;
;; repo_objects carried org, team, owner, visibility and key and nothing a team
;; could define, so project / location / period / status had nowhere to live and
;; Layer 3 had nothing to aggregate. And extract-text returned a string, throwing
;; away the page and region an extractor knew — which cannot be added later
;; without re-processing every document ever ingested.
;;
;;   raco test test/object-metadata-tests.rkt

(require rackunit db-kit/portable
         racket/file racket/list racket/port
         db-kit/migrate
         "../domain/db/migrations.rkt"
         "db-fixture.rkt"
         "../domain/authz/authz.rkt"
         (only-in "../domain/sched/scheduler.rkt" current-plugin)
         "../domain/repo/blobs.rkt"
         "../domain/repo/extract.rkt"
         "../domain/repo/repo.rkt")

(define BLOB-ROOT (make-temporary-file "tmx-meta-blobs-~a" 'directory))
(current-blob-root BLOB-ROOT)
(define (fresh) (define c (fresh-db #:migrate? #f)) (migrate! c all-migrations) c)
(define (setup)
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "root"))
  (values c (user-principal c uid tid) tid))
(define (doc c p key [body "text"])
  (repo-put! c p #:key key #:port (open-input-string body) #:content-type "text/plain"))

(define SURVEY
  (list (hasheq 'key "structure" 'label "Structure" 'required #t)
        (hasheq 'key "surveyed"  'label "Surveyed on")
        (hasheq 'key "risk"      'label "Risk score" 'digits #t 'maxlength "1")))

;; ---- LAY-4: defining the fields --------------------------------------------------
(test-case "a team defines its own fields, and a malformed definition is refused"
  (define-values (c p tid) (setup))
  (check-equal? (repo-fields c tid) '() "nothing defined to begin with")
  (check-equal? (repo-fields-set! c tid SURVEY) SURVEY)
  (check-equal? (length (repo-fields c tid)) 3)
  (check-true (string? (repo-fields-set! c tid (list (hasheq 'key "Bad Key" 'label "x")))))
  (check-true (string? (repo-fields-set! c tid (list (hasheq 'key "ok")))) "a field needs a label")
  (check-true (regexp-match? #rx"unknown setting"
    (repo-fields-set! c tid (list (hasheq 'key "ok" 'label "Ok" 'pattern "^x$")))) )
  (check-true (regexp-match? #rx"share a key"
    (repo-fields-set! c tid (list (hasheq 'key "a" 'label "A") (hasheq 'key "a" 'label "Again")))))
  (disconnect c))

;; ---- LAY-4: setting values -------------------------------------------------------
(test-case "a document carries what the team asserts about it"
  (define-values (c p tid) (setup))
  (repo-fields-set! c tid SURVEY)
  (define o (doc c p "surveys/one.txt"))
  (check-equal? (hash-ref o 'attributes) (hasheq) "nothing asserted yet")
  (define out (repo-set-attributes! c p (hash-ref o 'id)
                                    (hasheq 'structure "levee-7" 'surveyed "2026-10-12")))
  (check-equal? (hash-ref (hash-ref out 'attributes) 'structure) "levee-7")
  ;; and it survives a re-read
  (check-equal? (hash-ref (hash-ref (repo-get c p (hash-ref o 'id)) 'attributes) 'surveyed) "2026-10-12")
  ;; a later call MERGES rather than replacing — setting the risk must not drop the structure
  (repo-set-attributes! c p (hash-ref o 'id) (hasheq 'risk "3"))
  (define a (hash-ref (repo-get c p (hash-ref o 'id)) 'attributes))
  (check-equal? (hash-ref a 'structure) "levee-7")
  (check-equal? (hash-ref a 'risk) "3")
  ;; an empty value clears one
  (repo-set-attributes! c p (hash-ref o 'id) (hasheq 'risk ""))
  (check-false (hash-has-key? (hash-ref (repo-get c p (hash-ref o 'id)) 'attributes) 'risk))
  (disconnect c))

(test-case "the vocabulary is the funnel's, and an undefined key is refused not stored"
  (define-values (c p tid) (setup))
  (repo-fields-set! c tid SURVEY)
  (define o (doc c p "surveys/two.txt"))
  ;; a key nobody defined would be a value nothing can display or filter on
  (check-true (regexp-match? #rx"not a field this team has defined"
    (repo-set-attributes! c p (hash-ref o 'id) (hasheq 'depth "4m"))))
  ;; `digits` and `maxlength`, shared with domain/fields
  (check-true (regexp-match? #rx"Risk score"
    (repo-set-attributes! c p (hash-ref o 'id) (hasheq 'structure "l7" 'risk "high"))))
  (check-true (regexp-match? #rx"Risk score"
    (repo-set-attributes! c p (hash-ref o 'id) (hasheq 'structure "l7" 'risk "42"))))
  ;; `required` is enforced on the MERGED result, so clearing a required field fails
  (repo-set-attributes! c p (hash-ref o 'id) (hasheq 'structure "l7"))
  (check-true (regexp-match? #rx"Structure"
    (repo-set-attributes! c p (hash-ref o 'id) (hasheq 'structure ""))))
  (disconnect c))

(test-case "setting metadata needs files:write ON THE DOCUMENT"
  (define-values (c p tid) (setup))
  (repo-fields-set! c tid SURVEY)
  (define o (doc c p "surveys/three.txt"))
  (define bob (create-user! c #:username "bob"))
  (add-member! c #:user bob #:team tid #:role "viewer")        ; *:read — no files:write
  (check-equal? (repo-set-attributes! c (user-principal c bob tid) (hash-ref o 'id)
                                      (hasheq 'structure "l7"))
                'forbidden)
  (disconnect c))

;; ---- LAY-4: what Layer 3 aggregates over ------------------------------------------
(test-case "listing narrows by what the team asserted"
  (define-values (c p tid) (setup))
  (repo-fields-set! c tid SURVEY)
  (define a (doc c p "surveys/a.txt")) (define b (doc c p "surveys/b.txt")) (define d (doc c p "surveys/c.txt"))
  (repo-set-attributes! c p (hash-ref a 'id) (hasheq 'structure "levee-7" 'surveyed "2026-01"))
  (repo-set-attributes! c p (hash-ref b 'id) (hasheq 'structure "levee-7" 'surveyed "2026-06"))
  (repo-set-attributes! c p (hash-ref d 'id) (hasheq 'structure "bridge-2"))
  (define (keys-for . kv) (sort (map (lambda (o) (hash-ref o 'key)) (repo-list c p #:attrs kv)) string<?))
  (check-equal? (keys-for '("structure" . "levee-7")) '("surveys/a.txt" "surveys/b.txt")
                "every survey of one structure — which is what tracking it over time needs")
  (check-equal? (keys-for '("structure" . "levee-7") '("surveyed" . "2026-06")) '("surveys/b.txt")
                "filters stack")
  (check-equal? (keys-for '("structure" . "nothing")) '())
  (check-equal? (length (repo-list c p)) 3 "no filter, no narrowing")
  (disconnect c))

;; ---- LAY-5: provenance ---------------------------------------------------------------
(define (span s e pg) (hasheq 'start s 'end e 'page pg 'bbox (list 10 20 30 40)))

(test-case "an extractor may report WHERE the text came from, and it is stored"
  (define-values (c p tid) (setup))
  (parameterize ([current-plugin "ocr"])
    (register-extractor! "application/x-scan"
                         (lambda (in ct) (values "crack width 0.8mm" #f (list (span 0 5 1) (span 6 11 1))))))
  (define o (repo-put! c p #:key "scan.bin" #:port (open-input-string "...")
                       #:content-type "application/x-scan"))
  (define-values (text reason spans) (extract-text/spans (open-input-string "...") "application/x-scan"))
  (check-equal? text "crack width 0.8mm")
  (check-equal? (length spans) 2)
  (repo-text-upsert! c (hash-ref o 'id) (hash-ref o 'version_id) text #:spans spans)
  (define stored (repo-spans-for c (hash-ref o 'id)))
  (check-equal? (length stored) 2)
  (check-equal? (hash-ref (car stored) 'page) 1)
  (check-equal? (hash-ref (car stored) 'bbox) '(10 20 30 40))
  ;; the point of the whole thing: an offset in the text resolves to a region
  (check-equal? (length (spans-covering stored 7)) 1)
  (check-equal? (hash-ref (car (spans-covering stored 7)) 'start) 6)
  (check-equal? (spans-covering stored 99) '())
  (unregister-extractor! "application/x-scan")
  (disconnect c))

(test-case "a two-value extractor still works — provenance is additive"
  ;; every plugin extractor written before LAY-5 answers with two values
  (parameterize ([current-plugin "old"])
    (register-extractor! "application/x-old" (lambda (in ct) (values "just text" #f))))
  (define-values (text reason spans) (extract-text/spans (open-input-string "x") "application/x-old"))
  (check-equal? text "just text")
  (check-equal? spans '())
  ;; and the 2-value extract-text is unchanged for every existing caller
  (define-values (t2 r2) (extract-text (open-input-string "x") "application/x-old"))
  (check-equal? t2 "just text")
  (unregister-extractor! "application/x-old"))

(test-case "a malformed span is dropped, and the text is never lost with it"
  (parameterize ([current-plugin "sloppy"])
    (register-extractor! "application/x-sloppy"
                         (lambda (in ct) (values "kept" #f
                                                 (list (span 0 4 1)
                                                       (hasheq 'start 5)                    ; no end
                                                       (hasheq 'start 2 'end 1)             ; end before start
                                                       (hasheq 'start 0 'end 4 'bbox '(1 2))  ; short bbox
                                                       "not even a hash")))))
  (define-values (text reason spans) (extract-text/spans (open-input-string "x") "application/x-sloppy"))
  (check-equal? text "kept" "provenance is an enrichment — losing a region must not cost the text")
  (check-equal? (length spans) 1)
  (unregister-extractor! "application/x-sloppy"))

(test-case "a span pointing past the cap is dropped, because it could never resolve"
  (parameterize ([current-plugin "big"])
    (register-extractor! "application/x-huge"
                         (lambda (in ct)
                           (values (make-string (* 2 EXTRACT-CAP) #\x) #f
                                   (list (span 0 10 1) (span (- (* 2 EXTRACT-CAP) 5) (* 2 EXTRACT-CAP) 9))))))
  (define-values (text reason spans) (extract-text/spans (open-input-string "x") "application/x-huge"))
  (check-equal? (string-length text) EXTRACT-CAP)
  (check-equal? (length spans) 1)
  (check-equal? (hash-ref (car spans) 'page) 1)
  (unregister-extractor! "application/x-huge"))

(test-case "a document extracted before provenance existed answers with no spans, not an error"
  (define-values (c p tid) (setup))
  (define o (doc c p "old.txt" "plain"))
  (repo-text-upsert! c (hash-ref o 'id) (hash-ref o 'version_id) "plain")
  (check-equal? (repo-spans-for c (hash-ref o 'id)) '())
  (check-equal? (repo-spans-for c "no-such-object") '())
  (disconnect c))
