#lang racket/base

;; test/sealed-coverage-tests.rkt — every sealed column is one a key rotation
;; rewrites.
;;
;; `cli/telemachus-secrets.rkt` carries the list `rewrap` walks, and
;; `define-sealed-column` is where a column is declared sealed. Nothing compared
;; the two, and they had drifted by THIRTEEN columns: job payloads, results and
;; errors, a run's and a step's inputs, outputs and errors, a run's cursor, both
;; halves of a translation, and a trigger fire's error. On an instance with
;; TMACH_ENCRYPT_CONTENT on, those rows stayed sealed under the old key through
;; a rotation, kept opening while TMACH_SECRET_KEY_OLD was set, and stopped the
;; day the runbook's last step dropped it.
;;
;;   raco test test/sealed-coverage-tests.rkt
;;
;; Three things, because the list can be wrong three ways: a declared column that
;; is not listed (case 1), a listed column the schema does not have (case 2), and
;; a listing whose context string is not the one the row was sealed under (case
;; 3, which performs a real rotation).

(require rackunit racket/string racket/list racket/file racket/port racket/runtime-path
         db-kit/portable db-kit/migrate
         "../domain/db/migrations.rkt"
         "db-fixture.rkt"
         "../domain/authz/authz.rkt"
         "../domain/authz/secretbox.rkt"
         "../domain/sched/scheduler.rkt"
         "../config.rkt"
         (only-in "../cli/telemachus-secrets.rkt" CREDENTIAL-SECRETS CONTENT-SECRETS rewrap status))

(define-runtime-path domain-dir "../domain")
(define-runtime-path plugins-dir "../plugins")

(define (fresh) (define c (fresh-db #:migrate? #f)) (migrate! c all-migrations) c)

(define (with-env* pairs thunk)
  (define saved (for/list ([p (in-list pairs)]) (cons (car p) (getenv (car p)))))
  (dynamic-wind (lambda () (for ([p (in-list pairs)]) (putenv (car p) (cdr p))))
                thunk
                (lambda () (for ([p (in-list saved)]) (putenv (car p) (or (cdr p) ""))))))

;; Two throwaway keys. Nothing is sealed with either outside this file.
(define KEY-A (make-string 64 #\a))
(define KEY-B (make-string 64 #\b))
(define K "TMACH_SECRET_KEY")
(define K-OLD "TMACH_SECRET_KEY_OLD")
(define SWITCH "TMACH_ENCRYPT_CONTENT")

;; ---- the declarations, read off the source -----------------------------------
;; A text scan over code, so comment lines are skipped: sealed.rkt's own header
;; shows three example declarations in prose.
(define (declared-columns)
  (define (rkt-files dir)
    (for/list ([f (in-directory dir)]
               #:when (and (regexp-match? #rx"[.]rkt$" (path->string f))
                           (not (regexp-match? #rx"/compiled/" (path->string f)))))
      f))
  (remove-duplicates
   (for*/list ([f (in-list (append (rkt-files domain-dir) (rkt-files plugins-dir)))]
               [line (in-list (file->lines f))]
               #:unless (regexp-match? #px"^\\s*;" line)
               [m (in-value (regexp-match #px"\\(define-sealed-column\\s+\"([a-z_.]+)\"" line))]
               #:when m)
     (cadr m))))

(define (listed-contexts) (map cadddr (append CREDENTIAL-SECRETS CONTENT-SECRETS)))

;; Sealed by calling `secret-wrap` directly rather than through the macro — the
;; three #19 sealed before the macro existed. Listed, never declared.
(define HAND-WRAPPED '("users.totp_secret" "repo_credentials.secret_key" "executors.secret_key"))

(test-case "1. every declared sealed column is listed for rotation, and nothing listed is undeclared"
  (define declared (declared-columns))
  (define listed (listed-contexts))
  ;; the scan is live: a walk that found nothing would agree with any list
  (check-true (>= (length declared) 20) (format "the scan found only ~a declarations" (length declared)))
  (check-true (and (member "jobs.payload" declared) #t))
  (define unlisted (filter (lambda (c) (not (member c listed))) declared))
  (check-equal? unlisted '()
                (format "sealed but NOT rewritten by `telemachus-secrets rewrap`: ~a"
                        (string-join unlisted ", ")))
  (define undeclared (filter (lambda (c) (not (or (member c declared) (member c HAND-WRAPPED)))) listed))
  (check-equal? undeclared '()
                (format "listed for rotation but declared nowhere: ~a" (string-join undeclared ", ")))
  (check-equal? (length listed) (length (remove-duplicates listed)) "a context is listed twice"))

(test-case "2. every listed table and column exists in the schema"
  ;; `workflow_runs.cursor` is the CONTEXT for the column `cursor_json`; a list
  ;; written from the context names would select a column that is not there.
  (define c (fresh))
  (for ([spec (in-list (append CREDENTIAL-SECRETS CONTENT-SECRETS))])
    (define ids (let ([i (caddr spec)]) (if (list? i) i (list i))))
    (check-not-exn
     (lambda () (query-rows c (format "SELECT ~a, ~a FROM ~a WHERE ~a IS NOT NULL"
                                      (string-join ids ", ") (cadr spec) (car spec) (cadr spec))))
     (format "~a.~a" (car spec) (cadr spec))))
  (close-db! c))

(test-case "3. a rotation: rows sealed under the old key open under the new one ALONE"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice" #:password "pw"))
  (define PAYLOAD-NEEDLE "levee-7 inspection, section 4")
  (define jid #f)
  ;; -- written under key A, through the real write path for a job and by hand
  ;;    for the two-key column, whose context is built here from the declaration
  (with-env* (list (cons K KEY-A) (cons K-OLD "") (cons SWITCH "1"))
    (lambda ()
      (set! jid (enqueue-job! c #:team tid #:user uid #:kind "chat"
                              #:payload (hasheq 'prompt PAYLOAD-NEEDLE)))
      (query-exec c (string-append "INSERT INTO doc_trigger_fires "
                                   "(trigger_id, version_id, object_id, error) VALUES (?, ?, ?, ?)")
                  "trg1" "ver1" "obj1"
                  (secret-wrap "doc_trigger_fires.error:trg1:ver1" "the template lacks {{total}}"))))
  (define (payload) (query-value c "SELECT payload FROM jobs WHERE id = ?" jid))
  (define (fire-error) (query-value c "SELECT error FROM doc_trigger_fires WHERE trigger_id = 'trg1'"))
  (check-true (wrapped-secret? (payload)) "the fixture really is sealed")
  (check-false (string-contains? (payload) PAYLOAD-NEEDLE))
  ;; -- the defect's precondition, asserted rather than assumed: under key B with
  ;;    no previous key, the row does not open
  (with-env* (list (cons K KEY-B) (cons K-OLD "") (cons SWITCH "1"))
    (lambda ()
      (check-exn exn:fail? (lambda () (secret-unwrap (string-append "jobs.payload:" jid) (payload))))))
  ;; -- the rotation, as the runbook runs it
  (with-env* (list (cons K KEY-B) (cons K-OLD KEY-A) (cons SWITCH "1"))
    (lambda ()
      ;; `status` is what says whether the previous key may be dropped
      (define before (with-output-to-string (lambda () (status c))))
      (check-true (string-contains? before "jobs.payload: 1 stored, 1 sealed, 0 in the clear, 1 under ANOTHER key")
                  before)
      (check-true (string-contains? before "do not drop the") before)
      (define out (with-output-to-string (lambda () (rewrap c))))
      (check-true (string-contains? out "jobs.payload") out)
      (check-true (string-contains? out "doc_trigger_fires.error trg1:ver1") out)
      (check-false (string-contains? (with-output-to-string (lambda () (status c))) "ANOTHER key"))
      ;; idempotent: the line an operator reads to know a rotation finished
      (check-true (string-contains? (with-output-to-string (lambda () (rewrap c)))
                                    "rewrapped 0 secret(s)"))))
  ;; -- and the previous key is dropped, which is the step that used to break it
  (with-env* (list (cons K KEY-B) (cons K-OLD "") (cons SWITCH "1"))
    (lambda ()
      (check-true (string-contains? (secret-unwrap (string-append "jobs.payload:" jid) (payload))
                                    PAYLOAD-NEEDLE))
      (check-equal? (secret-unwrap "doc_trigger_fires.error:trg1:ver1" (fire-error))
                    "the template lacks {{total}}")))
  (close-db! c))

(test-case "4. with the content switch OFF a rotation leaves content columns alone"
  ;; ENC's rule, unchanged by the longer list: sealing content costs content
  ;; search, so `rewrap` must not seal it on an instance that did not ask.
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice" #:password "pw"))
  (with-env* (list (cons K KEY-A) (cons K-OLD "") (cons SWITCH ""))
    (lambda ()
      (define jid (enqueue-job! c #:team tid #:user uid #:kind "chat" #:payload (hasheq 'prompt "plain")))
      (void (with-output-to-string (lambda () (rewrap c))))
      (check-false (wrapped-secret? (query-value c "SELECT payload FROM jobs WHERE id = ?" jid)))))
  (close-db! c))
