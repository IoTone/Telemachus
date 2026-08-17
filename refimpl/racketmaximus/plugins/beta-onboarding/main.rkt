#lang racket/base

;; plugins/beta-onboarding/main.rkt — an example SDK plugin that CUSTOMIZES the beta
;; onboarding experience without touching the core. It registers a second onboarding
;; provider ("founders") via the SDK's init! hook; activate it with
;; TELEMACHUS_ONBOARDING=founders. This is how a deployer tailors landing copy, form
;; fields, and the LLM judge prompt for their own beta program.

(require "../../domain/beta/beta.rkt")   ; the onboarding SDK: register-onboarding!

(provide init!)

(define (init!)
  (register-onboarding! "founders"
    (hasheq
     'name "founders"
     'title "Telemachus Founders Program"
     'subtitle "For early-stage teams building on self-hosted AI. Tell us about your company."
     'fields (list (hasheq 'key "name"     'label "Founder name" 'type "text"  'required #t)
                   (hasheq 'key "email"    'label "Work email"   'type "email" 'required #t)
                   (hasheq 'key "company"  'label "Startup"      'type "text"  'required #t)
                   (hasheq 'key "job_title" 'label "Title"        'type "text"  'required #f)
                   (hasheq 'key "revenue"  'label "Funding stage" 'type "select"
                           'options (list "Pre-seed" "Seed" "Series A" "Series B+") 'required #f)
                   (hasheq 'key "use_case" 'label "What are you building?" 'type "textarea" 'required #t))
     'judge-system (string-append
                    "You vet founders applying to a self-hosted AI platform's founders program. Assess whether this "
                    "is a REAL early-stage company (not spam / fake / a test), estimate stage or traction, and score "
                    "fit 0-100. Return ONLY JSON: "
                    "{\"valid\": true|false, \"score\": <int 0-100>, \"revenue_estimate\": \"<stage/ARR>\", \"reasoning\": \"<one sentence>\"}."))))
