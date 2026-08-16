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
         default-team team-owner-id count-recent-email count-recent-domain
         ;; extensible model: reserved (typed) keys vs. the attributes blob
         reserved-field-keys reserved-field? prospect-field
         ;; onboarding provider registry (SDK seam)
         register-onboarding! onboarding-config active-onboarding judge-system-prompt onboarding-names
         ;; judge-reply parsing (robust against small-model formatting)
         parse-verdict)

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
   "score fit 0-100. A plausible, complete profile — a real company name and address, a work email whose "
   "domain matches the company, a named role, and a reachable phone — RAISES confidence. Weigh any anti-abuse "
   "SIGNALS provided (e.g. many recent signups from the same domain, or a free/consumer email address) as "
   "reasons to LOWER confidence and score. Missing optional details are fine for an individual applicant and "
   "should not by themselves fail a submission. Return ONLY a JSON object: "
   "{\"valid\": true|false, \"score\": <int 0-100>, \"revenue_estimate\": \"<string>\", \"reasoning\": \"<one sentence>\"}."))

;; Extract the first balanced {...} object from an LLM reply, ignoring braces
;; inside JSON strings. Small local models wrap the object in prose or ```json
;; fences and sometimes emit a second brace-y blob, so a greedy first-{ to last-}
;; grab spans invalid text — a balance scan takes just the first real object.
(define (first-json-object s)
  (define n (string-length s))
  (let scan ([i 0])
    (cond
      [(>= i n) #f]
      [(char=? (string-ref s i) #\{)
       (let walk ([j i] [depth 0] [in-str #f] [esc #f])
         (cond
           [(>= j n) #f]                                   ; unbalanced — give up
           [esc (walk (add1 j) depth in-str #f)]
           [(and in-str (char=? (string-ref s j) #\\)) (walk (add1 j) depth in-str #t)]
           [in-str (walk (add1 j) depth (not (char=? (string-ref s j) #\")) #f)]
           [(char=? (string-ref s j) #\") (walk (add1 j) depth #t #f)]
           [(char=? (string-ref s j) #\{) (walk (add1 j) (add1 depth) #f #f)]
           [(char=? (string-ref s j) #\})
            (if (= depth 1) (substring s i (add1 j)) (walk (add1 j) (sub1 depth) #f #f))]
           [else (walk (add1 j) depth #f #f)]))]
      [else (scan (add1 i))])))

;; Parse a judge reply into a verdict hash, tolerating fences, prose, and a
;; trailing comma before } or ]. Returns #f if no usable object is found.
(define (parse-verdict reply)
  (define blob (first-json-object reply))
  (and blob
       (with-handlers ([exn:fail? (lambda (_) #f)])
         (define cleaned (regexp-replace* #px",\\s*([}\\]])" blob "\\1"))
         (define v (string->jsexpr cleaned))
         (and (hash? v) v))))

(define DEFAULT-PROVIDER
  (hasheq 'name "beta"
          'title "Join the Telemachus beta"
          'subtitle "We're onboarding a limited group of design-partner teams. Tell us about yours."
          ;; Tier-A skinnable landing defaults (all admin-editable; see slice 41)
          'logo "Telemachus"
          'eyebrow "Private beta"
          'cta "Request access"
          'footer "© Telemachus — self-hosted, privacy-first team AI."
          'theme (hasheq 'brand "#5a6cff" 'brandInk "#ffffff" 'bg "#0f1117" 'surface "#171a23"
                         'ink "#e6e8ee" 'muted "#9aa3b2" 'radius "12px" 'mode "dark"
                         'fontBody "System" 'heroBg "linear-gradient(135deg,#1c2140,#0f1117)")
          'details (list (hasheq 'heading "What you get"
                                 'body "Early access to the platform and a direct line to the team building it.")
                         (hasheq 'heading "Who it's for"
                                 'body "Teams that need self-hosted, private AI — no data leaves your infrastructure."))
          'fields (list (hasheq 'key "name"     'label "Full name"  'type "text"  'required #t)
                        (hasheq 'key "email"    'label "Work email" 'type "email" 'required #t)
                        (hasheq 'key "job_title" 'label "Your role"  'type "text"  'required #t)
                        (hasheq 'key "phone"    'label "Phone (optional)" 'type "tel" 'required #f)
                        (hasheq 'key "company"  'label "Company (optional)" 'type "text" 'required #f)
                        (hasheq 'key "company_address" 'label "Company address" 'type "textarea" 'required #f)
                        (hasheq 'key "revenue"  'label "Annual revenue" 'type "select"
                                'options (list "<$1M" "$1M–$10M" "$10M–$100M" "$100M+") 'required #f)
                        ;; team_size is NOT a reserved/typed column — it flows through the
                        ;; generic attributes blob, demonstrating the extensible model.
                        (hasheq 'key "team_size" 'label "Team size" 'type "select"
                                'options (list "1–10" "11–50" "51–200" "200+") 'required #f)
                        (hasheq 'key "use_case" 'label "What would you use Telemachus for?" 'type "textarea" 'required #t))
          'judge-system DEFAULT-JUDGE))
(register-onboarding! "beta" DEFAULT-PROVIDER)

;; ---- extensible field model -------------------------------------------------
;; Reserved keys map to typed columns (core logic queries them or dedups on them);
;; every other configured field is stored in the `attributes` JSON blob, so a new
;; program-specific field needs no migration. See docs/design/beta-onboarding-experience.md §1.
(define reserved-field-keys '("name" "email" "company" "job_title" "revenue" "use_case" "company_address" "phone"))
(define (reserved-field? key) (and (member key reserved-field-keys) #t))

;; Value of any configured field on a prospect hash — from its typed column if
;; reserved, else from the parsed attributes blob. Always returns a string. key: string.
(define (prospect-field pr key)
  (define sym (string->symbol key))
  (define typed (hash-ref pr sym 'missing))
  (cond
    [(and (not (eq? typed 'missing)) (not (sql-null? typed))) (format "~a" typed)]
    [else (let ([a (hash-ref pr 'attributes 'null)])
            (if (hash? a)
                (let ([v (hash-ref a sym "")]) (if (sql-null? v) "" (format "~a" v)))
                ""))]))

;; ---- team helpers -----------------------------------------------------------
(define (default-team conn)
  (query-maybe-value conn "SELECT id FROM teams ORDER BY created_at LIMIT 1"))

(define (team-owner-id conn team-id)
  (query-maybe-value conn
    "SELECT user_id FROM memberships WHERE team_id = ? AND role_key = 'owner' AND status = 'active' ORDER BY created_at LIMIT 1"
    team-id))

;; ---- prospects --------------------------------------------------------------
(define SELECT
  (string-append "SELECT id, name, email, company, job_title, revenue, use_case, source, status, judge, created_at, signals, "
                 "company_address, phone, attributes "
                 "FROM prospects"))

(define (parse-json* x) (if (sql-null? x) 'null (with-handlers ([exn:fail? (lambda (_) 'null)]) (string->jsexpr x))))
(define (row->prospect r)
  (hasheq 'id (vector-ref r 0) 'name (vector-ref r 1) 'email (vector-ref r 2) 'company (vector-ref r 3)
          'job_title (vector-ref r 4) 'revenue (vector-ref r 5) 'use_case (vector-ref r 6)
          'source (vector-ref r 7) 'status (vector-ref r 8)
          'judge (parse-json* (vector-ref r 9))
          'created_at (vector-ref r 10)
          'signals (parse-json* (vector-ref r 11))
          'company_address (vector-ref r 12) 'phone (vector-ref r 13)
          'attributes (parse-json* (vector-ref r 14))))

;; PUBLIC — no principal; captures a lead into the team's pipeline. Returns id.
;; created-epoch is a portable numeric timestamp for velocity windows; signals is a
;; jsexpr of anti-abuse hints the LLM judge weighs.
(define (prospect-create! conn #:team team #:name name #:email email #:company [company ""]
                          #:job-title [job-title ""] #:revenue [revenue ""] #:use-case [use-case ""]
                          #:company-address [company-address ""] #:phone [phone ""] #:attributes [attributes #f]
                          #:source [source "beta"] #:created-epoch [epoch (current-seconds)] #:signals [signals #f])
  (define id (new-id))
  (query-exec conn
    (string-append "INSERT INTO prospects (id, team_id, name, email, company, job_title, revenue, use_case, "
                   "company_address, phone, source, created_epoch, signals, attributes) "
                   "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)")
    id team name email company job-title revenue use-case company-address phone source epoch
    (if (hash? signals) (jsexpr->string signals) sql-null)
    (if (and (hash? attributes) (positive? (hash-count attributes))) (jsexpr->string attributes) sql-null))
  id)

;; velocity counters (portable numeric window on created_epoch)
(define (count-recent-email conn team email since-epoch)
  (query-value conn "SELECT COUNT(*) FROM prospects WHERE team_id = ? AND LOWER(email) = LOWER(?) AND created_epoch >= ?"
               team email since-epoch))
(define (count-recent-domain conn team domain since-epoch)
  (query-value conn "SELECT COUNT(*) FROM prospects WHERE team_id = ? AND LOWER(email) LIKE ? AND created_epoch >= ?"
               team (string-append "%@" (string-downcase domain)) since-epoch))

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

;; judge writes its verdict (no principal — runs in the queue). The verdict is
;; informational, so it always persists — even if the owner already decided
;; (the async judge can land after a qualify/reject). Status only advances out
;; of the un-reviewed states; an owner decision is never clobbered.
(define (set-prospect-judge! conn id verdict)
  (query-exec conn "UPDATE prospects SET judge = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ?"
              (jsexpr->string verdict) id)
  (query-exec conn "UPDATE prospects SET status = 'reviewed', updated_at = CURRENT_TIMESTAMP WHERE id = ? AND status IN ('new','verifying')"
              id))
