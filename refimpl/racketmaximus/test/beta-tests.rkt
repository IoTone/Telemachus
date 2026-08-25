#lang racket/base

;; test/beta-tests.rkt — beta onboarding: public prospect capture, LLM-judge verdict,
;; owner review/decision, RBAC, and the pluggable onboarding provider registry.
;; raco test test/beta-tests.rkt

(require rackunit db-kit/portable
         db-kit/migrate
         "../domain/db/migrations.rkt"
         "db-fixture.rkt"
         "../domain/authz/authz.rkt"
         "../domain/beta/beta.rkt")

(define (fresh) (define c (fresh-db #:migrate? #f)) (migrate! c all-migrations) c)

(test-case "prospect lifecycle: public create → owner list/judge/decide; RBAC-gated"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice"))
  (define alice (user-principal c uid tid))
  (check-equal? (default-team c) tid)
  (check-equal? (team-owner-id c tid) uid)

  (define pid (prospect-create! c #:team tid #:name "Dana" #:email "dana@acme.com"
                                #:company "Acme" #:use-case "team chat" #:revenue "$10M–$100M"
                                #:job-title "CTO" #:phone "+1 555 0100"
                                #:company-address "1 Market St, SF"))
  (check-equal? (length (prospect-list c alice)) 1)
  (check-equal? (hash-ref (car (prospect-list c alice)) 'status) "new")
  ;; company qualifying details round-trip
  (let ([d (prospect-get c alice pid)])
    (check-equal? (hash-ref d 'job_title) "CTO")
    (check-equal? (hash-ref d 'phone) "+1 555 0100")
    (check-equal? (hash-ref d 'company_address) "1 Market St, SF"))

  (set-prospect-judge! c pid (hasheq 'valid #t 'score 82 'revenue_estimate "$50M" 'reasoning "real co"))
  (define g (prospect-get c alice pid))
  (check-equal? (hash-ref g 'status) "reviewed")
  (check-equal? (hash-ref (hash-ref g 'judge) 'score) 82)

  (check-true (prospect-decide! c alice pid "qualified"))
  (check-equal? (hash-ref (prospect-get c alice pid) 'status) "qualified")
  (check-exn exn:fail? (lambda () (prospect-decide! c alice pid "maybe")))

  ;; the async judge can land AFTER an owner decides — the verdict must still
  ;; persist, and the owner's decision must not be reverted to "reviewed"
  (set-prospect-judge! c pid (hasheq 'valid #t 'score 91 'revenue_estimate "$60M" 'reasoning "late verdict"))
  (define late (prospect-get c alice pid))
  (check-equal? (hash-ref late 'status) "qualified")               ; decision preserved
  (check-equal? (hash-ref (hash-ref late 'judge) 'score) 91)       ; verdict still stored

  ;; a viewer cannot review the pipeline
  (define bob (create-user! c #:username "bob"))
  (add-member! c #:user bob #:team tid #:role "viewer")
  (check-exn exn:fail:forbidden? (lambda () (prospect-list c (user-principal c bob tid)))))

(test-case "extensible attributes: custom fields round-trip without a column"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice"))
  (define alice (user-principal c uid tid))
  ;; reserved keys map to typed columns; anything else is a custom attribute
  (check-true (reserved-field? "email"))
  (check-true (reserved-field? "company_address"))
  (check-false (reserved-field? "team_size"))
  (check-false (reserved-field? "platform"))

  (define pid (prospect-create! c #:team tid #:name "Rae" #:email "rae@acme.com"
                                #:company "Acme" #:job-title "VP Eng"
                                #:attributes (hasheq 'team_size "51–200" 'platform "PC" 'region "EU")))
  (define d (prospect-get c alice pid))
  ;; attributes come back as a parsed hash
  (check-equal? (hash-ref (hash-ref d 'attributes) 'team_size) "51–200")
  ;; prospect-field reads uniformly across typed columns and the attributes blob
  (check-equal? (prospect-field d "company") "Acme")           ; typed column
  (check-equal? (prospect-field d "job_title") "VP Eng")       ; typed column
  (check-equal? (prospect-field d "team_size") "51–200")       ; attribute
  (check-equal? (prospect-field d "platform") "PC")            ; attribute
  (check-equal? (prospect-field d "missing_key") "")           ; absent → ""

  ;; a prospect with no custom fields stores null attributes and still reads clean
  (define p2 (prospect-create! c #:team tid #:name "Sol" #:email "sol@b.com"))
  (define d2 (prospect-get c alice p2))
  (check-equal? (prospect-field d2 "team_size") "")
  (check-equal? (hash-ref d2 'attributes) 'null))

(test-case "parse-verdict tolerates small-model formatting"
  ;; clean object
  (check-equal? (hash-ref (parse-verdict "{\"valid\": true, \"score\": 85}") 'score) 85)
  ;; ```json fence + surrounding prose
  (check-equal? (hash-ref (parse-verdict "Here is my verdict:\n```json\n{\"valid\": true, \"score\": 70}\n```\nHope this helps.") 'score) 70)
  ;; trailing comma before }
  (check-equal? (hash-ref (parse-verdict "{\"valid\": false, \"score\": 0,}") 'valid) #f)
  ;; a brace-y blob after the real object must not corrupt the parse
  (check-equal? (hash-ref (parse-verdict "{\"valid\": true, \"score\": 42}\n\nNote: use {placeholder} next time") 'score) 42)
  ;; a brace inside a string is not a nesting level
  (check-equal? (hash-ref (parse-verdict "{\"reasoning\": \"looks like a {test} account\", \"score\": 10}") 'score) 10)
  ;; no object at all → #f (handler falls back)
  (check-false (parse-verdict "I cannot produce JSON.")))

(test-case "onboarding provider registry (SDK seam)"
  (define cfg (onboarding-config))
  (check-equal? (hash-ref cfg 'name) "beta")
  (check-true (pair? (hash-ref cfg 'fields)))
  (check-true (string? (judge-system-prompt)))
  (register-onboarding! "custom" (hasheq 'name "custom" 'title "Custom" 'subtitle "" 'fields '() 'judge-system "judge X"))
  (check-true (and (member "custom" (onboarding-names)) #t)))

(test-case "velocity counters (portable epoch window) + stored signals"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice"))
  (prospect-create! c #:team tid #:name "A" #:email "a@acme.com"  #:created-epoch 1000)
  (prospect-create! c #:team tid #:name "B" #:email "b@acme.com"  #:created-epoch 1000)
  (prospect-create! c #:team tid #:name "C" #:email "c@other.com" #:created-epoch 1000)
  (check-equal? (count-recent-email c tid "a@acme.com" 500) 1)
  (check-equal? (count-recent-email c tid "A@ACME.COM" 500) 1)      ; case-insensitive
  (check-equal? (count-recent-domain c tid "acme.com" 500) 2)
  (check-equal? (count-recent-domain c tid "acme.com" 2000) 0)      ; outside the window
  (check-equal? (count-recent-domain c tid "other.com" 500) 1)
  (define pid (prospect-create! c #:team tid #:name "D" #:email "d@x.com" #:created-epoch 1000
                                #:signals (hasheq 'free_email #t 'domain_signups_24h 3)))
  (check-equal? (hash-ref (hash-ref (prospect-get c (user-principal c uid tid) pid) 'signals) 'domain_signups_24h) 3))

;; ---- configurable fields: turning them off, adding new ones -------------------
;; The form an applicant fills in is the experience document's `fields` list. Two
;; things had to become true for that to be the whole truth: `required` has to be
;; enforced from the config (it used to be decorative), and a field that is NOT in
;; the config must not be demanded anyway (a hardcoded check used to demand `name`
;; whatever the form actually showed, so removing it made the funnel unusable).

(define (probe fields body)
  (field-problem fields (lambda (k) (hash-ref body k ""))))

(test-case "required is enforced from the config, not decoration"
  (define fs (list (hasheq 'key "corporate_number" 'label "Corporate number" 'required #t)))
  (check-equal? (car (probe fs (hash))) 'required)
  (check-equal? (cadr (probe fs (hash))) "Corporate number")     ; the message names the field
  (check-false (probe fs (hash "corporate_number" "1234567890123"))))

(test-case "an optional field left blank is not an error"
  (define fs (list (hasheq 'key "phone" 'label "Phone" 'required #f)))
  (check-false (probe fs (hash)))
  (check-false (probe fs (hash "phone" ""))))

(test-case "a field that is not configured is never demanded"
  ;; the exact regression: a form with no `name` field must still accept a
  ;; submission that has no name
  (define fs (list (hasheq 'key "email" 'label "Work email" 'required #t)))
  (check-false (probe fs (hash "email" "a@corp.example"))))

(test-case "digits / minlength / maxlength — the 法人番号 shape"
  (define fs (list (hasheq 'key "corporate_number" 'label "法人番号" 'required #t
                           'digits #t 'minlength 13 'maxlength 13)))
  (check-false (probe fs (hash "corporate_number" "1234567890123")))
  (check-equal? (car (probe fs (hash "corporate_number" "12345ABC90123"))) 'digits)
  (check-equal? (car (probe fs (hash "corporate_number" "12345"))) 'too-short)
  (check-equal? (car (probe fs (hash "corporate_number" "12345678901234"))) 'too-long)
  ;; the message carries the number the operator configured, so it can say "13"
  (check-equal? (caddr (probe fs (hash "corporate_number" "12345"))) 13))

(test-case "a quoted number in a hand-written config still constrains"
  ;; TELEMACHUS_ONBOARDING_FILE is hand-authored JSON; "13" must not silently
  ;; disable the rule, which is a worse failure than rejecting the config
  (define fs (list (hasheq 'key "cn" 'label "CN" 'minlength "13")))
  (check-equal? (car (probe fs (hash "cn" "12345"))) 'too-short))

(test-case "email is structural — every other field is the operator's call"
  (check-true (structural-field? "email"))
  (for ([k (in-list '("name" "company" "revenue" "phone" "use_case" "corporate_number"))])
    (check-false (structural-field? k) k)))

(test-case "the first problem wins, in field order"
  (define fs (list (hasheq 'key "a" 'label "A" 'required #t)
                   (hasheq 'key "b" 'label "B" 'required #t)))
  (check-equal? (cadr (probe fs (hash))) "A"))

(test-case "a custom field needs no migration — it lands in the attributes blob"
  (check-false (reserved-field? "corporate_number"))
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice"))
  (define pid (prospect-create! c #:team tid #:name "N" #:email "n@corp.example"
                                #:attributes (hasheq 'corporate_number "1234567890123")))
  (define pr (prospect-get c (user-principal c uid tid) pid))
  (check-equal? (prospect-field pr "corporate_number") "1234567890123")
  ;; and a reserved one still reads from its typed column
  (check-equal? (prospect-field pr "email") "n@corp.example"))
