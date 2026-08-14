#lang racket/base

;; test/translate-tests.rkt — the Translation app: jobs, glossary (managed +
;; used in the prompt), RBAC, and catalog translation. The model call is injected
;; so these are deterministic and need no live model.  raco test test/translate-tests.rkt

(require rackunit
         db
         db-kit/migrate
         "../domain/apps/translate.rkt"
         "../domain/db/migrations.rkt"
         "../domain/authz/authz.rkt")

(define (fresh) (define c (sqlite3-connect #:database 'memory)) (migrate! c all-migrations) c)
(define (upcase-chat text sys) (values (string-upcase text) 7))

(test-case "translate!: returns result + tokens and records team history"
  (define conn (fresh))
  (define-values (uid tid) (bootstrap! conn #:username "alice"))
  (define alice (user-principal conn uid tid))
  (define-values (job tokens) (translate! conn alice #:text "hello world" #:target-lang "ja" #:chat upcase-chat))
  (check-equal? (hash-ref job 'result) "HELLO WORLD")
  (check-equal? (hash-ref job 'target_lang) "ja")
  (check-equal? tokens 7)
  (define hist (translate-list conn alice))
  (check-equal? (length hist) 1)
  (check-equal? (hash-ref (car hist) 'source_text) "hello world"))

(test-case "glossary: add (managed), upsert, and injected into the model prompt"
  (define conn (fresh))
  (define-values (uid tid) (bootstrap! conn #:username "alice"))
  (define alice (user-principal conn uid tid))
  (glossary-add! conn alice #:term "note" #:translation "メモ" #:target-lang "ja")
  (check-equal? (length (glossary-list conn alice #:target-lang "ja")) 1)
  (define seen (box ""))
  (translate! conn alice #:text "x" #:target-lang "ja"
              #:chat (lambda (text sys) (set-box! seen sys) (values text 3)))
  (check-true (regexp-match? #rx"メモ" (unbox seen)))            ; term reached the prompt
  (glossary-add! conn alice #:term "note" #:translation "覚書" #:target-lang "ja")  ; upsert
  (check-equal? (length (glossary-list conn alice #:target-lang "ja")) 1))

(test-case "glossary-add! requires settings:manage — a viewer is denied"
  (define conn (fresh))
  (define-values (uid tid) (bootstrap! conn #:username "alice"))
  (define dave (create-user! conn #:username "dave"))
  (add-member! conn #:user dave #:team tid #:role "viewer")
  (define pdave (user-principal conn dave tid))
  (check-exn exn:fail:forbidden?
             (lambda () (glossary-add! conn pdave #:term "a" #:translation "b" #:target-lang "ja"))))

(test-case "translate-catalog!: keys preserved, values translated"
  (define conn (fresh))
  (define-values (uid tid) (bootstrap! conn #:username "alice"))
  (define alice (user-principal conn uid tid))
  (define (json-chat text sys) (values "here you go: {\"greeting\":\"こんにちは\",\"bye\":\"さようなら\"}" 12))
  (define-values (out tokens)
    (translate-catalog! conn alice #:catalog (hasheq 'greeting "hello" 'bye "bye") #:target-lang "ja" #:chat json-chat))
  (check-equal? (hash-ref out 'greeting) "こんにちは")
  (check-equal? (hash-ref out 'bye) "さようなら"))
