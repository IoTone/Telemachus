#lang racket/base

;; domain/beta/beta.rkt — beta onboarding: capture pre-sales PROSPECTS (not users
;; /accounts) for an internal team to vet, each judged by the LLM for validity +
;; revenue estimate. The onboarding EXPERIENCE (landing copy + form fields + judge
;; prompt) is a pluggable PROVIDER registered through the SDK, so a deployer can
;; customize it (default provider ships in plugins/beta-onboarding).

(require db
         json
         "../db/id.rkt"
         "../authz/authz.rkt")

(provide ;; prospects
         prospect-create! prospect-list prospect-get prospect-decide! set-prospect-judge!
         default-team team-owner-id
         ;; onboarding provider registry (SDK seam)
         register-onboarding! onboarding-config active-onboarding judge-system-prompt onboarding-names)

;; ---- onboarding provider registry -------------------------------------------
(define *providers* (box (hash)))
(define (register-onboarding! name provider) (set-box! *providers* (hash-set (unbox *providers*) name provider)))
(define (onboarding-names) (sort (hash-keys (unbox *providers*)) string<?))

(define (active-onboarding)
  (define want (let ([v (getenv "TELEMACHUS_ONBOARDING")]) (and v (not (string=? v "")) v)))
  (define ps (unbox *providers*))
  (or (and want (hash-ref ps want #f))
      (hash-ref ps "beta" #f)
      (let ([ks (hash-keys ps)]) (and (pair? ks) (hash-ref ps (car ks))))
      DEFAULT-PROVIDER))

;; public config the SPA renders the form from (no judge prompt leaked)
(define (onboarding-config)
  (define p (active-onboarding))
  (hasheq 'name (hash-ref p 'name "beta")
          'title (hash-ref p 'title "")
          'subtitle (hash-ref p 'subtitle "")
          'fields (hash-ref p 'fields '())))

(define (judge-system-prompt) (hash-ref (active-onboarding) 'judge-system DEFAULT-JUDGE))

;; built-in fallback provider (also registered by the shipped plugin)
(define DEFAULT-JUDGE
  (string-append
   "You vet inbound beta prospects for a self-hosted team AI platform. Given the submission, assess whether "
   "this is a REAL business prospect (not spam / fake / a test), estimate the company's annual revenue, and "
   "score fit 0-100. Return ONLY a JSON object: "
   "{\"valid\": true|false, \"score\": <int 0-100>, \"revenue_estimate\": \"<string>\", \"reasoning\": \"<one sentence>\"}."))

(define DEFAULT-PROVIDER
  (hasheq 'name "beta"
          'title "Join the Telemachus beta"
          'subtitle "We're onboarding a limited group of design-partner teams. Tell us about yours."
          'fields (list (hasheq 'key "name"     'label "Full name"  'type "text"  'required #t)
                        (hasheq 'key "email"    'label "Work email" 'type "email" 'required #t)
                        (hasheq 'key "company"  'label "Company"    'type "text"  'required #t)
                        (hasheq 'key "job_title" 'label "Your role"  'type "text"  'required #f)
                        (hasheq 'key "revenue"  'label "Annual revenue" 'type "select"
                                'options (list "<$1M" "$1M–$10M" "$10M–$100M" "$100M+") 'required #f)
                        (hasheq 'key "use_case" 'label "What would you use Telemachus for?" 'type "textarea" 'required #t))
          'judge-system DEFAULT-JUDGE))
(register-onboarding! "beta" DEFAULT-PROVIDER)

;; ---- team helpers -----------------------------------------------------------
(define (default-team conn)
  (query-maybe-value conn "SELECT id FROM teams ORDER BY created_at LIMIT 1"))

(define (team-owner-id conn team-id)
  (query-maybe-value conn
    "SELECT user_id FROM memberships WHERE team_id = ? AND role_key = 'owner' AND status = 'active' ORDER BY created_at LIMIT 1"
    team-id))

;; ---- prospects --------------------------------------------------------------
(define SELECT
  (string-append "SELECT id, name, email, company, job_title, revenue, use_case, source, status, judge, created_at "
                 "FROM prospects"))

(define (row->prospect r)
  (hasheq 'id (vector-ref r 0) 'name (vector-ref r 1) 'email (vector-ref r 2) 'company (vector-ref r 3)
          'job_title (vector-ref r 4) 'revenue (vector-ref r 5) 'use_case (vector-ref r 6)
          'source (vector-ref r 7) 'status (vector-ref r 8)
          'judge (let ([j (vector-ref r 9)])
                   (if (sql-null? j) 'null (with-handlers ([exn:fail? (lambda (_) 'null)]) (string->jsexpr j))))
          'created_at (vector-ref r 10)))

;; PUBLIC — no principal; captures a lead into the team's pipeline. Returns id.
(define (prospect-create! conn #:team team #:name name #:email email #:company [company ""]
                          #:job-title [job-title ""] #:revenue [revenue ""] #:use-case [use-case ""]
                          #:source [source "beta"])
  (define id (new-id))
  (query-exec conn
    (string-append "INSERT INTO prospects (id, team_id, name, email, company, job_title, revenue, use_case, source) "
                   "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)")
    id team name email company job-title revenue use-case source)
  id)

(define (prospect-list conn p #:limit [lim 100])
  (require-perm conn p "settings:manage")
  (for/list ([r (in-list (query-rows conn (string-append SELECT " WHERE team_id = ? ORDER BY created_at DESC LIMIT ?")
                                     (principal-team-id p) lim))])
    (row->prospect r)))

(define (prospect-get conn p id)
  (require-perm conn p "settings:manage")
  (define r (query-maybe-row conn (string-append SELECT " WHERE id = ? AND team_id = ?") id (principal-team-id p)))
  (and r (row->prospect r)))

;; owner decision: qualified | rejected
(define (prospect-decide! conn p id decision)
  (require-perm conn p "settings:manage")
  (unless (member decision '("qualified" "rejected")) (error 'prospect-decide! "bad decision: ~a" decision))
  (define exists (query-maybe-value conn "SELECT id FROM prospects WHERE id = ? AND team_id = ?" id (principal-team-id p)))
  (and exists
       (begin
         (query-exec conn "UPDATE prospects SET status = ?, decided_by = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ?"
                     decision (principal-user-id p) id)
         #t)))

;; judge writes its verdict (no principal — runs in the queue)
(define (set-prospect-judge! conn id verdict)
  (query-exec conn "UPDATE prospects SET judge = ?, status = 'reviewed', updated_at = CURRENT_TIMESTAMP WHERE id = ? AND status IN ('new','verifying','reviewed')"
              (jsexpr->string verdict) id))
