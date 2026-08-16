#lang racket/base

;; domain/samples/samples.rkt — seed a team with sample content + queued jobs, so a
;; fresh instance has something to look at and the queue/agent paths get exercised.
;; Operator-triggered from the Admin console (POST /api/admin/seed).

(require "../notes/notes.rkt"
         "../documents/documents.rkt"
         "../sched/scheduler.rkt"
         "../authz/authz.rkt")

(provide seed-samples!)

(define SAMPLE-NOTES
  '(("Welcome"  . "Welcome to your Telemachus workspace — this is a sample note.")
    ("Roadmap"  . "Q3: launch. Q4: scale to more teams and add the knowledge graph app.")
    ("Standup"  . "Yesterday: shipped the jobs queue. Today: the agent job kind + samples.")))

(define SAMPLE-DOCS
  '(("Onboarding guide" . "How to invite your team, set quotas, and activate features.")
    ("Release notes"    . "The workload queue now runs agent flows and is quota-metered per team.")))

;; sample jobs — exercise chat, translate, and the agent tool-loop through the queue
(define (sample-jobs conn team user)
  (list
   (enqueue-job! conn #:team team #:user user #:kind "chat"
                 #:payload (hasheq 'prompt "Give me three tips for onboarding a new team."))
   (enqueue-job! conn #:team team #:user user #:kind "translate"
                 #:payload (hasheq 'text "Welcome to the team!" 'target_lang "ja"))
   (enqueue-job! conn #:team team #:user user #:kind "agent"
                 #:payload (hasheq 'prompt "Create a note titled 'Made by the agent' with a one-line body."))))

(define (seed-samples! conn p)
  (for ([n (in-list SAMPLE-NOTES)]) (notes-create conn p #:title (car n) #:body (cdr n) #:visibility "team"))
  (for ([d (in-list SAMPLE-DOCS)]) (documents-create conn p #:title (car d) #:content (cdr d) #:visibility "team"))
  (define jobs (sample-jobs conn (principal-team-id p) (principal-user-id p)))
  (hasheq 'notes (length SAMPLE-NOTES) 'documents (length SAMPLE-DOCS) 'jobs (length jobs)))
