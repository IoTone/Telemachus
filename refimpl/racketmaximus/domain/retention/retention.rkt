#lang racket/base

;; domain/retention/retention.rkt — retention rules, evaluated on a schedule (#86 r3).
;;
;; THIS IS WHERE TWO ISSUES CONVERGE, which is the reason it exists at all rather
;; than as two horizons in two places. #83 r2 asked for job payloads purged "on a
;; schedule (configurable retention, default 7 days)"; #86 r3 asked for a per-team
;; rule set including `purge-job-payloads-after`, evaluated by a scheduled job.
;; Those are ONE answer, and #59's own status note said so — which is why #59 built
;; the per-job LEVER (`purge-job-content!`) and deliberately left the policy open.
;; This is the policy. The sweep calls that lever and `repo-delete-tree!`; it
;; implements neither again.
;;
;; NOTHING APPLIES UNLESS CONFIGURED, and that is a deliberate deviation from
;; #83's wording. "Default 7 days" as an actual default would mean an upgrade
;; silently begins deleting every existing instance's job payloads on a timer —
;; the class of change CLAUDE.md keeps refusing ("Making these fatal
;; unconditionally would break every existing deployment"). So 7 days is the
;; documented recommendation, and the value you get when you enable payload
;; purging without naming a horizon. An instance with no policy deletes nothing.
;;
;; THE LAYERS TIGHTEN, never loosen — SESS-4's rule, and here "tighter" means
;; SHORTER. The instance sets a ceiling, an org may shorten it for its own data, a
;; team may shorten further for its own. A team cannot extend past its company's
;; obligation, and `null` (keep for ever) is the weakest value and therefore loses.

(require db-kit/portable json racket/list racket/string
         "../settings/settings.rkt"
         "../authz/authz.rkt"
         "../sched/scheduler.rkt"        ; purge-job-content!, PURGEABLE-STATUSES
         "../repo/repo.rkt")             ; repo-delete-tree!

(provide retention-fields DEFAULT-PAYLOAD-DAYS
         retention-ref retention-set! retention-problem
         effective-retention retention-sources
         retention-plan retention-apply! retention-sweep!
         legal-hold-set! legal-hold-of)

;; The three rules #86 r3 names. `max_age` is the whole object; `derived` is only
;; what a workflow produced from one, which a team may want gone long before the
;; source; `payloads` is #59's lever on a clock.
(define retention-fields '(max_age_days delete_derived_after_days purge_job_payloads_after_days))

;; #83's recommendation, applied only when payload purging is switched on without
;; a horizon. NOT a default for an unconfigured instance.
(define DEFAULT-PAYLOAD-DAYS 7)

;; ---- the documents ---------------------------------------------------------------
(define (key-for scope id)
  (case scope
    [(instance) "retention:instance"]
    [(org) (string-append "retention:org:" id)]
    [(team) (string-append "retention:team:" id)]
    [else (error 'retention "unknown scope ~a" scope)]))

(define EMPTY (hasheq 'max_age_days 'null
                      'delete_derived_after_days 'null
                      'purge_job_payloads_after_days 'null))

(define (retention-ref conn scope [id ""])
  (normalize (setting-ref conn (key-for scope id) EMPTY)))

;; Every field present, so a caller never has to distinguish "absent" from
;; "unset" — and a CORRUPT stored document reads as "no rules", not as a rule
;; nobody wrote. A control must fail closed, and for a DELETING control failing
;; closed means deleting nothing (SESS-6 reasons the same way in the other
;; direction, because there the safe state is the shipped posture).
(define (normalize doc)
  (for/fold ([h EMPTY]) ([f (in-list retention-fields)])
    (define v (and (hash? doc) (hash-ref doc f 'null)))
    (hash-set h f (if (and (exact-integer? v) (> v 0)) v 'null))))

;; -> #f, or a sentence naming the problem.
(define (retention-problem doc)
  (cond
    [(not (hash? doc)) "a retention policy must be an object"]
    [else
     (define unknown (for/list ([k (in-hash-keys doc)]
                                #:unless (memq k retention-fields)) k))
     (cond
       ;; An unknown field is REFUSED, not dropped — the call a theme token makes
       ;; (#:branding) and for the same reason: a rule that does nothing is how an
       ;; operator concludes retention is broken, and here they would conclude it
       ;; while believing data was being deleted.
       [(pair? unknown)
        (format "unknown field(s): ~a. The rules are ~a"
                (string-join (map symbol->string unknown) ", ")
                (string-join (map symbol->string retention-fields) ", "))]
       [else
        (for/or ([f (in-list retention-fields)])
          (define v (hash-ref doc f 'null))
          (cond
            [(eq? v 'null) #f]
            [(not (exact-integer? v)) (format "~a must be a whole number of days, or null" f)]
            ;; ZERO IS REFUSED. Every interval knob on this platform falls back to
            ;; its default rather than to 0, because a 0 means "immediately" — and
            ;; a retention of 0 days deletes a document the moment it is uploaded.
            ;; Here there is no safe fallback to choose, so it is an error.
            [(<= v 0) (format "~a must be at least 1 day (0 would delete on arrival)" f)]
            [(> v 36500) (format "~a is longer than a century; use null for 'keep for ever'" f)]
            [else #f]))])]))

(define (retention-set! conn scope id doc)
  (define bad (retention-problem doc))
  (when bad (raise-user-error 'retention bad))
  (setting-set! conn (key-for scope id) (normalize doc)))

;; ---- the effective policy --------------------------------------------------------
;; The SHORTEST of the three layers per field, with 'null (keep for ever) losing to
;; any number. See the header: the layers tighten and never loosen.
(define (shorter a b)
  (cond [(eq? a 'null) b]
        [(eq? b 'null) a]
        [else (min a b)]))

(define (layers conn team org)
  (list (cons 'instance (retention-ref conn 'instance))
        (cons 'org (if org (retention-ref conn 'org org) EMPTY))
        (cons 'team (if team (retention-ref conn 'team team) EMPTY))))

(define (effective-retention conn team org)
  (define ls (layers conn team org))
  (for/fold ([h EMPTY]) ([f (in-list retention-fields)])
    (hash-set h f (for/fold ([v 'null]) ([l (in-list ls)])
                    (shorter v (hash-ref (cdr l) f))))))

;; WHICH LAYER each effective value came from, because "why is my data being
;; deleted after 30 days" is the question an operator actually asks, and three
;; documents they have to diff by hand is a poor answer.
(define (retention-sources conn team org)
  (define ls (layers conn team org))
  (define eff (effective-retention conn team org))
  (for/hasheq ([f (in-list retention-fields)])
    (define v (hash-ref eff f))
    (values f (if (eq? v 'null)
                  'null
                  ;; the LAST layer that set exactly the winning value — the most
                  ;; specific one, which is the layer an operator would edit
                  (let loop ([rest ls] [found 'null])
                    (cond [(null? rest) found]
                          [(equal? (hash-ref (cdr (car rest)) f) v)
                           (loop (cdr rest) (symbol->string (car (car rest))))]
                          [else (loop (cdr rest) found)]))))))

;; ---- the legal hold (the r4 flag r3 needs) ---------------------------------------
(define (legal-hold-set! conn id on?)
  (query-exec conn "UPDATE repo_objects SET legal_hold = ? WHERE id = ?"
              (if on? (current-seconds) sql-null) id))

(define (legal-hold-of conn id)
  (define v (query-maybe-value conn "SELECT legal_hold FROM repo_objects WHERE id = ?" id))
  (and v (not (sql-null? v)) v))

;; ---- what a policy would do ------------------------------------------------------
;; A PLAN, never an action. The prefix delete learned this the hard way (DEL-4):
;; a destructive rule has to be inspectable before it runs, and a retention rule
;; runs unattended, so it is the one most in need of a dry run.
;;
;; `#:now` is a parameter so a test can age data without sleeping — the same reason
;; the lease tests expire a lease by UPDATE rather than by waiting.
(define (retention-plan conn team org #:now [now (current-seconds)])
  (define eff (effective-retention conn team org))
  (define (days->cutoff d) (and (exact-integer? d) (- now (* d 86400))))

  (define max-age (days->cutoff (hash-ref eff 'max_age_days)))
  (define derived-age (days->cutoff (hash-ref eff 'delete_derived_after_days)))
  (define payload-age (days->cutoff (hash-ref eff 'purge_job_payloads_after_days)))

  ;; Objects whose newest version is older than the cutoff. A HELD object is
  ;; excluded here, not filtered later, so a plan never lists something a rule
  ;; cannot touch — a dry run that over-promises is worse than none.
  (define (stale-objects cutoff #:derived-only? [derived-only? #f])
    (if (not cutoff)
        '()
        (query-list conn
          (string-append
           "SELECT o.id FROM repo_objects o "
           (if derived-only?
               "JOIN repo_derivations d ON d.object_id = o.id "
               "")
           "WHERE o.team_id = ? AND o.deleted_at IS NULL AND o.legal_hold IS NULL "
           ;; The newest version's age. An UNKNOWN age — a version written before
           ;; migration 0045, which backfills nothing — must mean NEVER STALE. The
           ;; obvious `COALESCE(epoch, 0)` reads those as infinitely old, so the
           ;; first instance to configure a policy would delete every document it
           ;; already had. `IS NOT NULL` is the whole safety of this rule.
           "AND (SELECT MAX(v.created_epoch) FROM repo_versions v "
           "     WHERE v.object_id = o.id) IS NOT NULL "
           "AND (SELECT MAX(v.created_epoch) FROM repo_versions v "
           "     WHERE v.object_id = o.id) < ? "
           "GROUP BY o.id")
          team cutoff)))

  (define objects (stale-objects max-age))
  (define derived (remove* objects (stale-objects derived-age #:derived-only? #t)))
  (define payloads
    (if (not payload-age)
        '()
        (query-list conn
          ;; same rule for a job: `created_epoch` arrived in 0041 with no backfill,
          ;; so a pre-0041 job has none and is exempt rather than treated as
          ;; ancient. FLEET-4 reports `oldest_queued_seconds: null` for exactly
          ;; these rows rather than guessing.
          (string-append "SELECT id FROM jobs WHERE team_id = ? AND purged_at IS NULL "
                         "AND status IN ('done', 'error', 'canceled') "
                         "AND created_epoch IS NOT NULL AND created_epoch < ?")
          team payload-age)))
  (hasheq 'policy eff
          'objects objects 'derived derived 'payloads payloads
          'held (query-value conn
                  (string-append "SELECT COUNT(*) FROM repo_objects "
                                 "WHERE team_id = ? AND legal_hold IS NOT NULL "
                                 "AND deleted_at IS NULL") team)))

;; ---- applying it ------------------------------------------------------------------
;; Each deletion goes through the lever that already exists: `repo-delete-tree!`
;; for an object (so the cascade, the per-object permission check, the blob rule
;; and the storage refund are not reimplemented) and `purge-job-content!` for a
;; payload. One audit event per deletion, as r3 asks.
(define (retention-apply! conn p team org #:now [now (current-seconds)])
  (define plan (retention-plan conn team org #:now now))
  (define deleted
    (for/sum ([id (in-list (append (hash-ref plan 'objects) (hash-ref plan 'derived)))])
      (with-handlers ([exn:fail? (lambda (e)
                                   ;; One object nobody can delete must not stop the
                                   ;; sweep — the rule the indexer lives by for one
                                   ;; bad file. It stays, and the next pass tries again.
                                   0)])
        (define r (repo-delete-tree! conn p id))
        (cond
          [r (audit! conn #:action "retention.deleted" #:actor-type "system" #:actor-id "retention"
                     #:team-id team #:resource-type "repo" #:resource-id id
                     #:meta (format "{\"objects\":~a,\"freed\":~a}"
                                    (length (hash-ref r 'deleted)) (hash-ref r 'freed)))
             1]
          [else 0]))))
  (define purged
    (for/sum ([id (in-list (hash-ref plan 'payloads))])
      (if (eq? (purge-job-content! conn id team) #t)
          (begin
            (audit! conn #:action "retention.purged" #:actor-type "system" #:actor-id "retention"
                    #:team-id team #:resource-type "job" #:resource-id id)
            1)
          0)))
  (hasheq 'deleted deleted 'purged purged 'held (hash-ref plan 'held)))

;; ---- the sweep --------------------------------------------------------------------
;; Every team that HAS a policy, plus every team in an org that has one, plus all
;; teams when the instance has one. A team with no applicable rule is never
;; scanned, which is what keeps an unconfigured instance free.
;;
;; It runs as the SYSTEM, so the per-object permission check inside
;; `repo-delete-tree!` is satisfied by an operator principal rather than skipped —
;; there is no path here that deletes without that check.
(define (retention-sweep! conn #:now [now (current-seconds)] #:principal [p #f])
  (define instance-has?
    (for/or ([f (in-list retention-fields)])
      (not (eq? (hash-ref (retention-ref conn 'instance) f) 'null))))
  (define teams
    (cond
      [instance-has? (query-list conn "SELECT id FROM teams")]
      [else
       ;; only the teams some document names, found from the settings keys
       (define keys (query-list conn
                      "SELECT key FROM instance_settings WHERE key LIKE 'retention:%'"))
       (define team-ids (for/list ([k (in-list keys)]
                                   #:when (string-prefix? k "retention:team:"))
                          (substring k (string-length "retention:team:"))))
       (define org-ids (for/list ([k (in-list keys)]
                                  #:when (string-prefix? k "retention:org:"))
                         (substring k (string-length "retention:org:"))))
       (remove-duplicates
        (append team-ids
                (for*/list ([o (in-list org-ids)]
                            [t (in-list (query-list conn "SELECT id FROM teams WHERE org_id = ?" o))])
                  t)))]))
  (for/fold ([deleted 0] [purged 0]) ([t (in-list teams)])
    (define org (query-maybe-value conn "SELECT org_id FROM teams WHERE id = ?" t))
    (define pr (or p (system-principal-for conn t)))
    (cond
      [(not pr) (values deleted purged)]
      [else
       (define r (retention-apply! conn pr t (and org (not (sql-null? org)) org) #:now now))
       (values (+ deleted (hash-ref r 'deleted)) (+ purged (hash-ref r 'purged)))])))

;; The principal a sweep acts as: the team's OWNER, so every deletion is checked
;; by `can?` exactly as that person's own call would be. There is deliberately no
;; "system can delete anything" principal — a rule must not be able to remove what
;; its own team could not.
(define (system-principal-for conn team)
  (define uid (query-maybe-value conn
                (string-append "SELECT user_id FROM memberships WHERE team_id = ? "
                               "AND role_key IN ('owner','admin') AND status = 'active' "
                               "ORDER BY role_key ASC LIMIT 1")
                team))
  (and uid (not (sql-null? uid)) (user-principal conn uid team)))
