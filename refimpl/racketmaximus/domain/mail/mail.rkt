#lang racket/base

;; domain/mail/mail.rkt — who hears about what, and the queue that gets it to them.
;;
;; `transport.rkt` is the operator's half and knows nothing about recipients; this
;; is the other half. Three things live here and they are deliberately in one
;; module, because each is the reason the next is safe:
;;
;;   1. THE CATEGORIES — a second closed vocabulary over `EVENTS`.
;;   2. THE RESOLUTION — which people, of a team's members, hear about an event.
;;   3. THE QUEUE — webhooks' table with the URL swapped for a recipient.
;;
;; WHY A CATEGORY RATHER THAN SUBSCRIBING TO EVENTS DIRECTLY (MAIL-13). `EVENTS`
;; is what the PLATFORM emits; a category is what a PERSON subscribes to, and they
;; are not the same list. `run.completed` and `run.failed` are one want — nobody
;; asks to hear about their successes and not their failures — so a preference
;; surface built on the event names would be seven checkboxes of which two
;; matter, and it would grow a checkbox every time the platform learned to emit
;; something. The mapping is here, closed in both directions, and asserted.
;;
;; THE INSTANCE LAYER IS AN OPT-IN AND THE USER LAYER IS AN OPT-OUT, AND THAT
;; ASYMMETRY IS THE ONE REAL DIVERGENCE FROM `features.rkt` (MAIL-14). There,
;; absence means ENABLED at every layer, because a feature switch governs whether
;; an endpoint ANSWERS and the behaviour that already existed is "it answers". A
;; notification governs whether this instance SENDS MAIL TO PEOPLE, and the
;; behaviour that already existed is sending none — so absence at the instance
;; layer means OFF, and an operator names the categories their instance sends.
;;
;; That is not timidity, it is the only safe default available. `object.created`
;; fires on every upload: a team ingesting a hundred documents would, under a
;; features.rkt-shaped default, send a hundred emails to every member the first
;; time anybody verified an address — which is how an instance's own domain gets
;; blocked, and it would happen on an UPGRADE, to an operator who had configured
;; nothing. The same argument DEL-9 makes for retention having no real default and
;; PULL-15a for worker-token expiry: a default that starts doing something on a
;; timer is the wrong kind of default.
;;
;; Below the instance, the layers TIGHTEN and may never loosen — SESS-4's and
;; FEAT-1's rule. An org may turn a category off for its own people; a person may
;; turn one off for themselves, and that choice SURVIVES the layer above being
;; switched back on, because an opt-out is a standing instruction. Nobody below
;; the instance may turn one ON.
;;
;; THE FAN-OUT IS AUTHORIZED PER RECIPIENT (MAIL-17). An event is emitted for a
;; TEAM and a notification goes to PEOPLE, so this asks `can?` on the subject for
;; each one — TAG-6's rule, that a count is a count but somebody's words are
;; somebody's. A member who may not read a document must not learn from their
;; inbox that it exists, and on a team with private documents that is the ordinary
;; case rather than a corner.

(require db-kit/portable
         racket/string
         racket/list
         json
         "../db/id.rkt"
         "../db/nulls.rkt"
         (only-in "../events/events.rkt" EVENTS event?)
         (only-in "../events/describe.rkt" event-subject event-console-path short-id)
         (only-in "../settings/settings.rkt" setting-ref setting-set!)
         (only-in "../authz/authz.rkt" team-org user-principal audit!)
         ;; the team-keyed half of the tenant admission pair (MAIL-25). orgs.rkt
         ;; requires authz, quota and db and nothing of this subsystem, so this
         ;; direction is the only one there is.
         (only-in "../orgs/orgs.rkt" tenant-quota-check/team tenant-quota-record!/team)
         ;; the ONE predicate for "may this principal read this document"
         (only-in "../repo/repo.rkt" repo-readable?)
         "transport.rkt")

(provide MAIL-CATEGORIES CATEGORY-EVENTS TRANSACTIONAL-CATEGORIES MAX-ATTEMPTS
         MAIL-QUOTA-DIM
         category-of-event category? backoff-seconds
         ;; the layers
         instance-categories instance-categories-set! org-categories org-categories-set!
         user-prefs user-pref-set! category-scope category-allows?
         categories-for prefs-problem
         ;; the queue
         mail-enqueue! mail-notify! mail-deliver-due! mail-deliver-one!
         mail-deliveries mail-delivery-get mail-redeliver!
         ;; the three transactional messages
         mail-enqueue-verification! mail-enqueue-password-reset!
         mail-enqueue-invitation! mail-send-test!
         ;; composition, exported FOR the tests: what a message SAYS is the half
         ;; worth asserting without a mail server, and it is where the
         ;; never-content rule either holds or does not
         compose-notification notification-recipients
         ;; exported FOR the test: a claim asserted through two SERIAL
         ;; `mail-deliver-one!` calls cannot see the guard at all, because the
         ;; first one moves the due time — WHK-1's own recorded lesson, which
         ;; cost that slice a passing control
         claim-mail!)

;; ---- the vocabulary -----------------------------------------------------------
;; A notification category, and the events it covers. CLOSED IN BOTH DIRECTIONS:
;; every category has at least one event and every member of `EVENTS` has a
;; category, which `mail-tests.rkt` asserts — a category nothing emits is a
;; checkbox that does nothing, and an event in no category is an event nobody can
;; ever be told about, and the second is #113's shape.
;;
;; `ping` is in `workflows` rather than a category of its own: it is what
;; `POST /api/webhooks/:id/ping` emits to prove a subscription, so a person
;; testing their own notifications should receive it through a category they have
;; actually enabled.
(define CATEGORY-EVENTS
  (list (cons "workflows" '("run.completed" "run.failed" "ping"))
        (cons "jobs"      '("job.completed"))
        (cons "documents" '("object.created" "object.deleted"))
        (cons "reviews"   '("review.decided"))))

(define MAIL-CATEGORIES (map car CATEGORY-EVENTS))

;; The messages that are NOT notifications and are therefore not subject to any
;; of the layers above: a verification, which is the one message sent to an
;; UNVERIFIED address (MAIL-5); the transport test, which is sent to an address
;; the operator typed; and a password reset, which somebody asked for because
;; they cannot sign in. All three are transactional — somebody asked for this
;; exact message, now — and none is routed to a team's members.
;;
;; A RESET IS THE ONE CASE WHERE BEING TRANSACTIONAL IS A SECURITY PROPERTY AND
;; NOT A CONVENIENCE (RESET-5). The preference layers exist so a person can stop
;; this instance mailing them, and a person who has turned every category off
;; must still be able to recover their account — otherwise the preference is a
;; way to lock yourself out, permanently, from a screen that does not warn you.
;; So the categories are not consulted, and the console says so where somebody
;; turns the last one off.
(define TRANSACTIONAL-CATEGORIES '("verify" "test" "reset" "invite"))

(define (category? c) (and (member c MAIL-CATEGORIES) #t))

(define (category-of-event event)
  (for/or ([kv (in-list CATEGORY-EVENTS)])
    (and (member event (cdr kv)) (car kv))))

;; ---- the layers ---------------------------------------------------------------
(define INSTANCE-KEY "email-notify:instance")
(define (org-key org-id) (string-append "email-notify:org:" org-id))

(define (instance-categories conn) (setting-ref conn INSTANCE-KEY (hasheq)))
(define (org-categories conn org-id)
  (if org-id (setting-ref conn (org-key org-id) (hasheq)) (hasheq)))

;; An UNKNOWN category is refused, not stored — the call an unknown feature, an
;; unknown theme token and an unknown retention field all make. A checkbox that
;; silently does nothing is how an admin concludes the feature is broken.
(define (prefs-problem doc)
  (cond
    [(not (hash? doc)) "a notification document must be an object"]
    [else
     (for/or ([(k v) (in-hash doc)])
       (cond
         [(not (category? (symbol->string k)))
          (format "unknown category '~a' — known categories are: ~a"
                  k (string-join MAIL-CATEGORIES ", "))]
         [(not (boolean? v)) (format "category '~a' must be true or false" k)]
         [else #f]))]))

(define (instance-categories-set! conn doc)
  (define p (prefs-problem doc))
  (when p (error 'email-notify "~a" p))
  (setting-set! conn INSTANCE-KEY doc))

(define (org-categories-set! conn org-id doc)
  (define p (prefs-problem doc))
  (when p (error 'email-notify "~a" p))
  (setting-set! conn (org-key org-id) doc))

;; THE INSTANCE LAYER IS ASKED FOR AN EXPLICIT `true` (MAIL-14, and the module
;; header is the argument). The other two are asked whether they OBJECT, so
;; `hash-ref`'s default being #f and a stored `false` also being #f cannot confuse
;; them: the key's presence is never what either of those asks.
(define (instance-allows? doc category)
  (eq? (hash-ref doc (string->symbol category) #f) #t))

(define (blocks? doc category)
  (define k (string->symbol category))
  (and (hash-has-key? doc k) (eq? (hash-ref doc k) #f)))

;; Only ever holds a 0 — see the migration. -> a hash of category -> #f.
(define (user-prefs conn user-id)
  (for/hash ([r (in-list (query-rows conn
                           "SELECT category, enabled FROM email_prefs WHERE user_id = ?" user-id))])
    (values (vector-ref r 0) (= 0 (vector-ref r 1)))))

;; `on?` #t REMOVES the row rather than storing a true: absence already means "I
;; have not objected", and writing the positive would make one state two rows.
;; FEAT-9's rule for the instance feature card, which had to normalize away a
;; `true` somebody had written over HTTP.
(define (user-pref-set! conn user-id category on?)
  (unless (category? category) (error 'email-notify "unknown category '~a'" category))
  (if on?
      (query-exec conn "DELETE FROM email_prefs WHERE user_id = ? AND category = ?" user-id category)
      (query-exec conn
        (string-append "INSERT INTO email_prefs (user_id, category, enabled, updated_epoch) "
                       "VALUES (?, ?, 0, ?) "
                       "ON CONFLICT(user_id, category) DO UPDATE SET enabled = 0, updated_epoch = excluded.updated_epoch")
        user-id category (current-seconds))))

;; -> #f when the category is allowed, else WHICH layer said no:
;; "instance" | "org" | "user". `features.rkt`'s `disabled_by`, and for its
;; reason: "why am I not getting these" with three documents to diff by hand is a
;; poor answer, and a person seeing "instance" knows not to look in their own
;; settings.
;;
;; THE ORDER IS THE ORDER SOMEBODY WOULD WANT NAMED — the layer furthest from
;; them first, because it is the one they cannot change from where they stand.
(define (category-scope conn category #:user [user-id #f] #:team [team-id #f])
  (cond
    [(not (category? category)) "unknown"]
    [(not (instance-allows? (instance-categories conn) category)) "instance"]
    [(and team-id (blocks? (org-categories conn (team-org conn team-id)) category)) "org"]
    [(and user-id (hash-ref (user-prefs conn user-id) category #f)) "user"]
    [else #f]))

(define (category-allows? conn category #:user [user-id #f] #:team [team-id #f])
  (not (category-scope conn category #:user user-id #:team team-id)))

;; What to render on a person's own notification card: every category, whether it
;; is on for them, and which layer decided it if not.
(define (categories-for conn #:user [user-id #f] #:team [team-id #f])
  (for/list ([c (in-list MAIL-CATEGORIES)])
    (define by (category-scope conn c #:user user-id #:team team-id))
    (define base (hasheq 'category c 'enabled (not by)))
    (if by (hash-set base 'disabled_by by) base)))

;; ---- composing ----------------------------------------------------------------
;; -> (values subject body). ONE composer for both (MAIL-9), so a subject cannot
;; carry what a body refuses — and both come from `event-subject`, which is handed
;; the `emit!` payload and may not go to the database for more.
;;
;; `base` is the transport's `base_url`. WITH NONE CONFIGURED THERE IS NO LINK,
;; and the body says so rather than printing a relative fragment, which in an
;; email is not a link at all: an operator who has not told the instance its own
;; external hostname cannot be guessed at, because the Host header belongs to a
;; CALLER and this is composed by a sweep with no request in sight.
(define (compose-notification event data #:base [base #f] #:team-name [team-name #f])
  (define sentence (event-subject event data))
  (define path (event-console-path event data))
  (define link (and base path (string-append (string-trim base "/" #:left? #f) "/" path)))
  (define subject (if team-name (format "[~a] ~a" team-name sentence) sentence))
  (define body
    (string-join
     (append
      (list sentence "")
      (if link
          (list link "")
          (list "This instance has no base URL configured, so there is no link to"
                "follow — an operator can set one in Admin > Email." ""))
      (list "— TMach"
            "You are receiving this because notifications are on for your account."
            "Turn them off under your own profile in the console."))
     "\n"))
  (values subject body))

;; ---- the queue ----------------------------------------------------------------
;; Ten attempts, 60 * 2^(n-1) with a 24h ceiling — webhooks' curve, and the same
;; argument: the cap is not what stops it, the base is chosen so the FIRST retry
;; is soon, because the first retry is the one that recovers an ordinary restart
;; or a relay that was reloading its configuration.
(define MAX-ATTEMPTS 10)
(define BACKOFF-CAP 86400)
(define DELIVERY-BATCH 25)
;; A relay's own reply text is KEPT — it is the most useful thing an operator has
;; for a transport that will not answer — and BOUNDED, because a great many of
;; them echo the message back inside a reply and FEED-6's rule is that anything
;; outliving the call is a copy. SEC-8's `provider-detail`, in SMTP's vocabulary.
(define MAX-ERROR-CHARS 400)

(define (now) (current-seconds))
(define (backoff-seconds attempt) (min BACKOFF-CAP (* 60 (expt 2 (max 0 (- attempt 1))))))

(define (clip-error e) (clip (printable e) MAX-ERROR-CHARS))

;; The one INSERT. Everything that sends mail arrives here, including the two
;; transactional messages, so there is one place a row is born and one shape to
;; read in a dead-letter list.
;;
;; NOTHING IS QUEUED WITHOUT A TRANSPORT (MAIL-10). A row written on an instance
;; that cannot send is a pending delivery that will be retried ten times and die,
;; for every event, for ever — and `mail_deliveries` would fill with them. The
;; caller is told by the answer being #f.
(define (mail-enqueue! conn #:recipient recipient #:category category #:subject subject
                       #:body body #:team [team #f] #:user [user #f] #:event [event #f])
  (cond
    [(not (transport-configured? conn)) #f]
    [(mail-address-problem recipient) #f]
    [else
     (define id (new-id))
     (query-exec conn
       (string-append "INSERT INTO email_deliveries (id, team_id, user_id, recipient, category, "
                      "event, subject, body, status, attempts, next_attempt_epoch, created_epoch) "
                      "VALUES (?, ?, ?, ?, ?, ?, ?, ?, 'pending', 0, ?, ?)")
       id (or team sql-null) (or user sql-null) recipient category (or event sql-null)
       subject body (now) (now))
     id]))

;; ---- who gets it --------------------------------------------------------------
;; -> (listof (cons user-id address)). The team's ACTIVE members who have a
;; VERIFIED address and whose layers all allow this category and who may READ the
;; subject.
;;
;; `can?` IS ASKED PER RECIPIENT AND IT IS THE EXPENSIVE HALF, deliberately
;; (MAIL-17). The window is the team's membership, which is bounded by what a team
;; is; a document's readability is not something a SQL clause can express here,
;; because `can?` also admits an owner and a grant holder — VEC-28's and
;; CLS-27's asymmetry, where a SQL exclusion narrows the WINDOW and a `can?`
;; filter narrows the ANSWER.
(define (notification-recipients conn team category event data)
  (define rows
    (query-rows conn
      (string-append "SELECT u.id, u.email FROM users u "
                     "JOIN memberships m ON m.user_id = u.id "
                     "WHERE m.team_id = ? AND m.status = 'active' AND u.status = 'active' "
                     "AND u.email IS NOT NULL AND u.email_verified_epoch IS NOT NULL")
      team))
  ;; THE TWO UPPER LAYERS ARE ASKED ONCE AND THE USER LAYER IN ONE QUERY, and
  ;; that is PERF-1's defect refused rather than repeated. `job-waiting`'s own
  ;; comment said the window bounded the scan while the loop below it asked a
  ;; question about the TEAM once per candidate — 60 ms a poll at the cap. Here
  ;; the fan-out sits INLINE in the emitter's thread, on the upload path for
  ;; `object.created`, so a query per member would put the team's membership
  ;; between somebody and their own `PUT`.
  ;;
  ;; What is still per member is `repo-readable?`, and that one cannot be
  ;; batched: `can?` admits an owner and a grant holder as well as a role, which
  ;; VEC-28 and CLS-27 both record as the thing a SQL clause cannot express. It
  ;; is bounded by the members who have a CONFIRMED address, which the window
  ;; above has already narrowed to — and it is only asked at all for an event
  ;; that names a document.
  (define disabled (team-disabled-categories conn (map (lambda (r) (vector-ref r 0)) rows)))
  (define upper (category-scope conn category #:team team))
  (cond
    [upper '()]
    [else
     (for*/list ([r (in-list rows)]
                 #:do [(define uid (vector-ref r 0))
                       (define addr (vector-ref r 1))]
                 #:when (and (string? addr)
                             (not (mail-address-problem addr))
                             (not (member category (hash-ref disabled uid '())))
                             (may-read? conn uid team event data)))
       (cons uid addr))]))

;; uid -> (listof category) the person has turned off, in ONE query. An empty
;; list for a user with no row at all, because absence means "I have not
;; objected" (MAIL-16).
(define (team-disabled-categories conn uids)
  (cond
    [(null? uids) (hash)]
    [else
     ;; The placeholder list is built WITH the argument list — the mistake this
     ;; codebase has made four times is a fixed argument list beside a
     ;; conditional clause, which is not what this is. Every element is a uuid
     ;; this process read out of its own `users` table a line ago.
     (define holes (string-join (for/list ([_ uids]) "?") ", "))
     (for/fold ([h (hash)])
               ([r (in-list (apply query-rows conn
                                   (string-append "SELECT user_id, category FROM email_prefs "
                                                  "WHERE enabled = 0 AND user_id IN (" holes ")")
                                   uids))])
       (define u (vector-ref r 0))
       (hash-set h u (cons (vector-ref r 1) (hash-ref h u '()))))]))

;; Whether this person may read the thing that happened. A subject this platform
;; cannot authorize — a job, a run, a review — is a TEAM fact and membership is
;; the whole of the question; a DOCUMENT is the case `can?` exists for, and the
;; one where a team's members genuinely differ.
;;
;; A FAILURE HERE REFUSES, it does not admit. `can?` reaching an unexpected state
;; must not become "send it anyway": the cost of a withheld notification is that
;; somebody checks the console, and the cost of the other mistake is telling
;; somebody a document exists.
(define (may-read? conn uid team event data)
  (define oid (let ([v (hash-ref data 'object_id #f)]) (and (string? v) v)))
  (cond
    [(not oid) #t]
    ;; `object.deleted` names a document that no longer exists, so there is
    ;; nothing left to authorize and `repo-readable?` would answer about a missing
    ;; row — which it collapses to #f, correctly for a lister and wrongly here.
    ;; Membership is as far as this can honestly go, and the payload deliberately
    ;; carries no key (#84 r2), so the message says "document 91bc was deleted"
    ;; and nothing about what it was.
    [(equal? event "object.deleted") #t]
    [else
     (with-handlers
       ;; A FAILURE REFUSES, it does not admit: `repo-readable?` reaching an
       ;; unexpected state must not become "send it anyway", because the cost of a
       ;; withheld notification is that somebody checks the console and the cost
       ;; of the other mistake is telling somebody a document exists.
       ;;
       ;; BUT IT SAYS SO ON STDERR, and that line is there because the swallow hid
       ;; a programming error for the length of one test run: the first version
       ;; called `can?` with `#:resource-type`/`#:resource-id`, keywords it does
       ;; not take, so every document notification was refused for EVERYBODY and
       ;; the handler reported it as "nobody may read this". The same shape as
       ;; RED-17's logger box, where the swallow that protects a model call also
       ;; hides a contract change.
       ([(lambda (_) #t)
         (lambda (e)
           (eprintf "email: could not authorize ~a for ~a: ~a\n" oid uid
                    (if (exn? e) (exn-message e) e))
           #f)])
       ;; `repo-readable?` is THE ONE PREDICATE for this question — #189 step 4
       ;; added it as "the ONE predicate both listers ask" and #234 found a third
       ;; asker that had not asked it. This is the fourth, and a copy of
       ;; `can? … #:resource (obj->resource …)` here would be that mistake again
       ;; in the one place where getting it wrong discloses rather than fails.
       (and (repo-readable? conn (user-principal conn uid team) oid) #t))]))

;; ---- what a team may spend on telling people -----------------------------------
;; `mail.notifications`, COUNTING MESSAGES QUEUED TO A MAILBOX (MAIL-25) — one
;; event to five members is five, because the resource being protected is this
;; instance's standing with the relays and that is spent per mailbox, not per
;; event. A RETRY IS NOT COUNTED: the retry curve is the platform's own business,
;; and charging a team for the relay having been down would make a team's budget
;; a function of somebody else's uptime.
;;
;; THE BOUND IS ON THE FAN-OUT AND NOT ON `mail-enqueue!`, AND THAT IS WHAT MAKES
;; THE TRANSACTIONAL MESSAGES SAFE BY CONSTRUCTION. `mail-enqueue!` is also the
;; one INSERT for a verification, a reset, an invitation and the transport test,
;; so a check there would need a keyword saying "do not count this one" — a
;; per-caller exemption list, where the one caller that forgot it would silently
;; make a password reset refusable. RESET-5 is that a reset must work for somebody
;; who has turned every category off, because the alternative is a screen that
;; locks you out permanently; a quota that could refuse one would be the same
;; defect with a number in front of it. Charging here puts the bound on exactly
;; the discretionary half, by construction rather than by a flag.
;;
;; THERE IS NO DEFAULT LIMIT, so on an instance nobody configured this refuses
;; nothing — DEL-9's and PULL-15a's rule, and here it is doubly true, since the
;; instance layer is already an opt-in (MAIL-14) and the operator who turned
;; notifications on is the one person placed to say how many is too many.
;;
;; IT IS DELIBERATELY NOT IN `QUOTA-HOLD-DIMS`, and that is the sharpest decision
;; here. A hold means a team's SCHEDULER QUEUE stops until the window resets —
;; right for every AI dimension, because those are spent inside a job and holding
;; the job is holding the spend. A notification is emitted FROM a job (a workflow
;; run completing is what fires `run.completed`), so holding on this dimension
;; would stop a team's actual work because it had sent too much mail — the tail
;; wagging the dog, and an outage with no obvious cause. A delivery is not a job
;; either: it is a row swept on the reaper seam, so there is no queue of
;; deliveries for a hold to govern. The refusal belongs at the fan-out, which is
;; where it is.
(define MAIL-QUOTA-DIM "mail.notifications")

;; A REFUSAL IS AUDITED, because a notification that was not sent is otherwise
;; invisible: `mail_deliveries` is where an operator looks and a refused message
;; writes no row there, so the symptom is silence and the diagnosis is "email is
;; broken". `ai.egress.refused` is the precedent (RED-24) and so is its shape —
;; one entry per refusal, NOT deduped per window like `quota.exhausted`. That
;; dedup exists because every pool tick re-asks the same question about the same
;; queued job and would write thousands of identical rows; here each entry is
;; about a DIFFERENT event, the rate is the team's own event rate, and collapsing
;; them would throw away the only record of which events nobody was told about.
;;
;; `#:team-id` is the team whose members were not told — the ninth appearance of
;; that shape in these notes, and the reason is unchanged: `audit-list` filters
;; by team, so an entry carrying the org instead would be invisible to exactly
;; the people who stopped hearing.
;;
;; THE ADDRESSES ARE NOT IN IT, only how many there were. The log is chained,
;; exported off the box and deliberately kept through an erasure (DEL-7), so it
;; outlives every other copy — and a list of the mailboxes of everybody on a team
;; is the one thing in this subsystem most worth not writing there.
(define (note-mail-refused! conn team event category n decision)
  (with-handlers ([(lambda (_) #t)
                   ;; A failed audit write must not rescue the request, and must
                   ;; not raise into the emitter either — RED-24's rule, and this
                   ;; runs inline in whatever thread emitted the event.
                   (lambda (e)
                     (eprintf "email: could not audit a refused notification: ~a\n"
                              (if (exn? e) (exn-message e) e))
                     (void))])
    (audit! conn #:action "email.notify.refused" #:actor-type "system"
            #:team-id team #:resource-type "quota" #:resource-id MAIL-QUOTA-DIM
            #:result "refused"
            #:meta (jsexpr->string
                    (hasheq 'event event 'category category 'recipients n
                            'dimension MAIL-QUOTA-DIM
                            'scope (hash-ref decision 'subject "team")
                            'used (hash-ref decision 'used 'null)
                            'limit (hash-ref decision 'limit 'null)
                            'window (hash-ref decision 'window 'null))))))

;; THE SINK. One event in, N rows out. It runs inline in the emitter's thread —
;; `events.rkt` swallows whatever it raises, and webhooks' sink writes a row for
;; the same reason — so it must not send anything: it composes and INSERTs, and
;; the sweep does the talking.
(define (mail-notify! conn event team data)
  (define category (category-of-event event))
  (cond
    [(not category) 0]
    [(not (transport-configured? conn)) 0]
    ;; Asked ONCE for the team before the membership is even read: the instance
    ;; and org layers are a property of the TEAM, not of a person. Asking them
    ;; per member would be `job-waiting`'s per-row cost — PERF-1's own defect,
    ;; where a question about a team was asked once per candidate and one poll
    ;; at the cap ran 64 of them to return nothing.
    ;;
    ;; `notification-recipients` asks again, deliberately: it is exported and a
    ;; caller may reach it directly, and two cheap single-row lookups are a
    ;; better trade than an export that is only correct when something else
    ;; checked first.
    [(not (category-allows? conn category #:team team)) 0]
    [else
     ;; THE RECIPIENTS ARE RESOLVED BEFORE ANYTHING IS SPENT, so an event nobody
     ;; was going to hear about costs neither a quota check nor an audit entry.
     ;; On a team where every member has turned the category off — or may not read
     ;; the subject (MAIL-17) — that is the ordinary case rather than a corner.
     (define recips (notification-recipients conn team category event data))
     (define decision (and (pair? recips)
                           (tenant-quota-check/team conn team MAIL-QUOTA-DIM 1)))
     (cond
       [(null? recips) 0]
       ;; ASKED FOR ONE UNIT, NOT FOR THE WHOLE FAN-OUT, and the difference is a
       ;; pathology rather than a nicety. Asking for N and refusing the lot would
       ;; mean a team of five under a limit of three is refused EVERY event for
       ;; ever while its ledger stays at `used: 0` — a bound that silences a team
       ;; and reports that it was never reached, which is the broken-meter reading
       ;; an operator would spend a day on. Asking "is there any budget left" and
       ;; then metering what was actually queued lets the figure reach and pass
       ;; the limit, which is what says plainly what happened.
       ;;
       ;; The cost is stated rather than implied: the window may end OVER the
       ;; limit, by at most one team's membership. That is the same overshoot
       ;; every AI dimension already accepts between an admission estimate and a
       ;; metered actual, and it is bounded by what a team is.
       [(not (hash-ref decision 'allowed))
        (note-mail-refused! conn team event category (length recips) decision)
        0]
       [else
        (define base (transport-base-url conn))
        (define team-name (team-label conn team))
        (define-values (subject body)
          (compose-notification event data #:base base #:team-name team-name))
        (define n
          (for/sum ([ua (in-list recips)])
            (if (mail-enqueue! conn #:recipient (cdr ua) #:category category #:subject subject
                               #:body body #:team team #:user (car ua) #:event event)
                1 0)))
        ;; THE COUNT OF ROWS THAT WERE WRITTEN — which today is provably the
        ;; same number as `(length recips)`, and a control is what established
        ;; that rather than a reading of the code. `mail-enqueue!` answers #f on
        ;; two conditions only: no transport, which the arm at the top of this
        ;; `cond` has already refused, and an address `mail-address-problem`
        ;; rejects, which `notification-recipients` filters out BEFORE the loop.
        ;; So nothing reachable from here can make the two differ, substituting
        ;; one for the other fails no test, and the rule is STATED rather than
        ;; pinned — the LibreOffice branch's and VEC-13's shape.
        ;;
        ;; It is still `n`, for the reason the equality is worth writing down: if
        ;; `mail-enqueue!` ever gains a third refusal, this stays the honest
        ;; figure and `(length recips)` quietly starts billing a team for
        ;; messages that were never written. The `positive?` guard is the same
        ;; unreachable branch seen from the other side — it only matters if some
        ;; future refusal empties the fan-out, and a zero-amount ledger row says
        ;; nothing to anybody.
        (when (positive? n) (tenant-quota-record!/team conn team MAIL-QUOTA-DIM n))
        n])]))

;; The team's NAME in the subject, because a person is in several teams and
;; "run 3f2a finished" in an inbox does not say whose. A team's own name for
;; itself is not document content — the workflow slug's argument (MTX-8).
(define (team-label conn team)
  (define v (query-maybe-value conn "SELECT name FROM teams WHERE id = ?" team))
  (and v (not (sql-null? v)) (printable v)))

;; ---- the two transactional messages -------------------------------------------
;; The verification is THE ONE MESSAGE SENT TO AN UNVERIFIED ADDRESS (MAIL-5), and
;; saying so here is the point: every other path goes through
;; `notification-recipients`, which demands `email_verified_epoch`.
(define (mail-enqueue-verification! conn #:user user #:address address #:token token)
  (define base (transport-base-url conn))
  ;; THE TOKEN IS IN THE SEARCH STRING AND THE FRAGMENT IS THE DESTINATION, which
  ;; is not a cosmetic choice: the console reads `?verify_email=` and STRIPS it
  ;; from the address bar at once (`/activate`'s own pattern), and it cannot strip
  ;; what is in the fragment without fighting #230's router, whose whole design is
  ;; that the hash mirrors state and nothing else writes it. `#/usage` is where
  ;; the card that shows the result lives.
  (define link (and base (format "~a/?verify_email=~a#/usage"
                                 (string-trim base "/" #:left? #f) token)))
  (define body
    (string-join
     (append
      (list "Somebody — probably you — asked for this address to receive TMach"
            "notifications. Confirm it to turn them on." "")
      (if link
          (list link "")
          ;; With no base URL the token is the only thing that can be acted on, so
          ;; it is printed. It is single-use, short-lived and in the body of a
          ;; message already addressed to its own subject, which is the only
          ;; place it could go.
          (list "Confirm it with this code:" token ""))
      (list "If you did not ask for this, ignore this message — nothing is sent"
            "to an address that has not been confirmed."
            "" "— TMach"))
     "\n"))
  (mail-enqueue! conn #:recipient address #:category "verify"
                 #:subject "Confirm your TMach notification address"
                 #:body body #:user user))

;; A PASSWORD RESET LINK (RESET-5…7).
;;
;; THE LINK IS A CONSOLE PATH AND THE TOKEN IS IN THE SEARCH STRING, for the
;; verification message's reasons exactly: the console reads `?reset_token=` and
;; STRIPS it from the address bar at once, and it cannot strip what sits in the
;; fragment without fighting #230's router. `#/` is the sign-in screen, which is
;; where somebody who cannot sign in already is.
;;
;; THE MESSAGE NAMES NO USERNAME AND NO TEAM. MTX-8's rule binds hardest here:
;; this message is sent to an address somebody typed into a PUBLIC endpoint, so
;; everything in it is readable by whoever holds that mailbox, and an inbox is
;; indexed by a third party and forwarded onwards. "Somebody asked to reset the
;; password for this address" tells the holder everything they need and tells an
;; attacker who guessed an address nothing they did not already supply.
;;
;; IT SAYS WHAT TO DO IF IT WAS NOT YOU, and that sentence is load-bearing rather
;; than polite: a reset request is the one message this platform will send to a
;; person because a STRANGER asked, so the message has to be safe to ignore and
;; has to say that ignoring it is safe. Nothing changes until the link is used.
(define (mail-enqueue-password-reset! conn #:user user #:address address #:token token
                                      #:ttl-hours [ttl-hours 1])
  (define base (transport-base-url conn))
  (define link (and base (format "~a/?reset_token=~a#/"
                                 (string-trim base "/" #:left? #f) token)))
  (define body
    (string-join
     (append
      (list "Somebody asked to reset the TMach password for this address."
            (format "This link works once, and stops working in ~a."
                    (if (= ttl-hours 1) "an hour" (format "~a hours" ttl-hours)))
            "")
      (if link
          (list link "")
          ;; With no base URL the token is the only actionable thing, so it is
          ;; printed — single-use, short-lived, and in a message already
          ;; addressed to its own subject, which is the only place it could go.
          (list "Use this code to set a new password:" token ""))
      (list "If it was not you, ignore this message. Nothing has changed and"
            "nothing will: your current password still works, and this link"
            "does nothing until somebody uses it."
            "" "— TMach"))
     "\n"))
  (mail-enqueue! conn #:recipient address #:category "reset"
                 #:subject "Reset your TMach password"
                 #:body body #:user user))

;; AN INVITATION (INVITE-1…6).
;;
;; IT NAMES THE TEAM AND THE PERSON WHO SENT IT, which is the ONE place this
;; subsystem's "ids, a status and a link — never content" rule is relaxed, and
;; the relaxation is the point rather than an exception squeezed through. MTX-8
;; exists because a notification goes to somebody who may hold no `can?` on its
;; subject; an invitation goes to somebody being ASKED TO JOIN, and a message
;; that will not say by whom or to what is one a careful person is right to
;; discard as phishing. So the team's display name and the inviter's are in it,
;; and nothing else is: no document, no run, no other member's name.
;;
;; THE LINK IS `/activate?token=`, WHICH ALREADY EXISTED and already strips its
;; own token from the address bar. It is not the `?reset_token=` shape because
;; that one lands on the sign-in screen and this one lands on a screen that asks
;; for a password and a confirmation — a different question, with a route of its
;; own since hosted onboarding.
(define (mail-enqueue-invitation! conn #:user user #:address address #:token token
                                  #:team-name team-name #:inviter inviter
                                  #:ttl-hours [ttl-hours 72])
  (define base (transport-base-url conn))
  (define link (and base (format "~a/activate?token=~a"
                                 (string-trim base "/" #:left? #f) token)))
  (define days (max 1 (quotient ttl-hours 24)))
  (define body
    (string-join
     (append
      (list (format "~a has invited you to join ~a on TMach." inviter team-name)
            "" "Follow this link to choose a password and sign in."
            (format "It works once, and stops working in ~a."
                    (if (= days 1) "a day" (format "~a days" days)))
            "")
      (if link
          (list link "")
          (list "Use this code on the sign-in screen:" token ""))
      (list "If you were not expecting this, ignore this message. No account is"
            "created for you until you follow the link."
            "" "— TMach"))
     "\n"))
  (mail-enqueue! conn #:recipient address #:category "invite"
                 #:subject (format "~a invited you to join ~a on TMach" inviter team-name)
                 #:body body #:user user))

;; THE TRANSPORT TEST IS SYNCHRONOUS AND STORES ONLY THE OUTCOME — #85's ping,
;; for #85's reason: a transport nobody can test is a transport nobody trusts, and
;; an operator who has just typed a password needs to know before anybody's
;; notification depends on it. Queueing it would answer "it is queued", which is
;; not what was asked.
;;
;; -> (values ok? error-or-#f)
(define (mail-send-test! conn recipient #:password [password 'stored])
  (define t (transport-ref conn))
  (define pw (if (eq? password 'stored) (transport-password conn) password))
  (cond
    [(not t) (values #f "no transport is configured")]
    [(mail-address-problem recipient) => (lambda (p) (values #f p))]
    [else
     (define id (new-id))
     (define-values (subject body)
       (values "TMach test message"
               (string-join
                (list "This is a test of this instance's email transport."
                      ""
                      "If you are reading it, the host, the port, the security mode and the"
                      "credential are all right, and notifications can be delivered."
                      "" "— TMach")
                "\n")))
     (define-values (ok? err)
       (with-handlers ([exn:fail? (lambda (e) (values #f (clip-error (exn-message e))))])
         (smtp-deliver! t recipient subject body #:password pw #:message-id id)
         (values #t #f)))
     (transport-record-test! conn ok? err)
     ;; Recorded as a DELIVERY too, already settled, so the one list an operator
     ;; reads holds the test beside the notifications — and a failed test is a
     ;; dead letter with the relay's own words on it rather than a toast that
     ;; scrolled away.
     (query-exec conn
       (string-append "INSERT INTO email_deliveries (id, team_id, user_id, recipient, category, "
                      "event, subject, body, status, attempts, next_attempt_epoch, created_epoch, sent_epoch, last_error) "
                      "VALUES (?, NULL, NULL, ?, 'test', NULL, ?, ?, ?, 1, NULL, ?, ?, ?)")
       id recipient subject body (if ok? "sent" "dead") (now) (if ok? (now) sql-null) (or err sql-null))
     (values ok? err)]))

;; ---- the claim ----------------------------------------------------------------
;; A SENDER TAKES THE ROW BEFORE IT SENDS, and believes the claim only if a row
;; comes back — issue #17's rule, which `claim-job!` has followed since the
;; scheduler grew a second claim path, and which SCHED-14's schedule tick, #114's
;; feed poller and WHK-1's delivery sweep all reuse. WHK-1 is the one worth
;; reading before touching this: the webhook sweep selected and then POSTed for a
;; year, and on two replicas every ordinary event was liable to go out twice.
;;
;; EMAIL CANNOT ABSORB THAT. A webhook receiver dedupes on the delivery id it is
;; handed; a person's inbox holds the message twice.
;;
;; The claim MOVES `next_attempt_epoch` and leaves the row `pending` (WHK-2): a
;; `sending` status would need a lease and a second sweep to unstick a row whose
;; sender died mid-conversation, and pushing the due time out instead makes that
;; self-healing with nothing to reap.
;;
;; `attempts` IS COMPARED AS WELL AS SET, AND A CONTROL SHOWED THAT THE DUE-TIME
;; CLAUSE ALONE ALREADY SETTLES THE RACE: the first claim moves the due time at
;; least a minute out, so the second sender's `next_attempt_epoch <= now` is false
;; and it is refused with or without the comparison. Recorded rather than
;; removed, because the comparison is NOT unreachable — it is what stops a sender
;; that read the row BEFORE an operator's redelivery from overwriting the reset
;; (`mail-redeliver!` puts `attempts` back to 0 and the due time to now, which is
;; the one state in which both clauses would otherwise admit). That is the case
;; the test isolates; #110 r1's rule is about a guard that duplicates the next
;; one, and this one does not.
(define MAIL-SELECT
  (string-append "SELECT id, team_id, user_id, recipient, category, event, subject, body, attempts "
                 "FROM email_deliveries WHERE id = ? AND status = 'pending'"))

(define (claim-mail! conn id row)
  (define was (vector-ref row 8))
  (and (query-maybe-row conn
         (string-append "UPDATE email_deliveries SET attempts = ?, next_attempt_epoch = ? "
                        "WHERE id = ? AND status = 'pending' AND attempts = ? "
                        "AND next_attempt_epoch <= ? RETURNING id")
         (add1 was) (+ (now) (backoff-seconds (add1 was))) id was (now))
       row))

;; -> 'sent | 'retry | 'dead | 'gone | 'sending
(define (mail-deliver-one! conn id #:password [password 'stored])
  (define t (transport-ref conn))
  ;; `'stored` rather than #f as the default, because #f is a MEANING here: a
  ;; relay that wants no credential. A test hands one in; the sweep does not have
  ;; to know the credential exists.
  (define pw (if (eq? password 'stored) (transport-password conn) password))
  (define r0 (query-maybe-row conn MAIL-SELECT id))
  (define r (and r0 t (claim-mail! conn id r0)))
  (cond
    [(not r0) 'gone]
    ;; No transport, or it was turned off while this was queued: the delivery
    ;; stops, and it stops as `dead` rather than lingering `pending` for ever, so
    ;; somebody can see what was not sent. The subscription-turned-off arm of
    ;; `deliver-one!`, for its reason.
    [(not t) (settle! conn id 'dead "no transport is configured" 0 (vector-ref r0 8)) 'dead]
    [(not r) 'sending]
    [else
     (define attempts (add1 (vector-ref r 8)))
     (define t0 (current-inexact-milliseconds))
     (define-values (err permanent?)
       (with-handlers ([exn:fail:mail? (lambda (e) (values (clip-error (exn-message e))
                                                           (exn:fail:mail-permanent? e)))]
                       [exn:fail? (lambda (e) (values (clip-error (exn-message e)) #f))])
         (smtp-deliver! t (vector-ref r 3) (vector-ref r 6) (vector-ref r 7)
                        #:password pw #:message-id id)
         (values #f #f)))
     (define ms (inexact->exact (round (- (current-inexact-milliseconds) t0))))
     (cond
       [(not err)
        (query-exec conn (string-append "UPDATE email_deliveries SET status = 'sent', attempts = ?, "
                                        "last_error = NULL, last_latency_ms = ?, "
                                        "next_attempt_epoch = NULL, sent_epoch = ? WHERE id = ?")
                    attempts ms (now) id)
        'sent]
       ;; A PERMANENT refusal is a dead letter on the FIRST attempt. A rejected
       ;; recipient or a refused relay will refuse identically in eight hours, so
       ;; nine more attempts are nine more identical refusals and a dead letter
       ;; that took a day to admit it — and against a relay that counts them, a
       ;; reputation cost. Webhooks' 4xx/5xx split in SMTP's own vocabulary.
       [permanent? (settle! conn id 'dead err ms attempts) 'dead]
       [(>= attempts MAX-ATTEMPTS) (settle! conn id 'dead err ms attempts) 'dead]
       [else
        ;; `next_attempt_epoch` IS NOT TOUCHED: the claim already set it, to this
        ;; attempt's backoff, before the conversation started. Setting it again
        ;; would be the same arithmetic from a later clock — WHK-1's recorded
        ;; one-home rule.
        (query-exec conn (string-append "UPDATE email_deliveries SET attempts = ?, last_error = ?, "
                                        "last_latency_ms = ? WHERE id = ?")
                    attempts err ms id)
        'retry])]))

(define (settle! conn id why err ms attempts)
  (query-exec conn (string-append "UPDATE email_deliveries SET status = ?, attempts = ?, "
                                  "last_error = ?, last_latency_ms = ?, next_attempt_epoch = NULL "
                                  "WHERE id = ?")
              (symbol->string why) attempts (or err sql-null) ms id))

;; The sweep, on the pool's reaper seam. -> (values sent retried dead)
(define (mail-deliver-due! conn #:password [password 'stored])
  (define due (query-list conn
                (string-append "SELECT id FROM email_deliveries WHERE status = 'pending' "
                               "AND next_attempt_epoch <= ? ORDER BY next_attempt_epoch ASC "
                               "LIMIT " (number->string DELIVERY-BATCH))
                (now)))
  (for/fold ([s 0] [r 0] [d 0]) ([id (in-list due)])
    (case (with-handlers ([(lambda (_) #t) (lambda (_) 'retry)])
            (mail-deliver-one! conn id #:password password))
      [(sent) (values (add1 s) r d)]
      [(dead) (values s r (add1 d))]
      ;; a row another sender took between this sweep's SELECT and its claim is
      ;; counted as nothing: it was not retried by US, and counting it would make
      ;; a two-replica instance look as though it were failing
      [(sending gone) (values s r d)]
      [else (values s (add1 r) d)])))

;; ---- reading the record -------------------------------------------------------
;; THE BODY IS NOT PROJECTED. It is composed, not content (MAIL-9), so there is no
;; disclosure in it — but a dead-letter list is read to answer "what is failing
;; and why", and a page of message bodies is not that. `mail-delivery-get`
;; answers one row WITH its body, which is the "show me exactly what went out"
;; case.
(define LIST-COLS (string-append "id, team_id, user_id, recipient, category, event, subject, status, "
                                 "attempts, last_error, last_latency_ms, created_epoch, sent_epoch, "
                                 "next_attempt_epoch"))

(define (row->delivery r)
  (hasheq 'id (vector-ref r 0) 'team_id (nz (vector-ref r 1)) 'user_id (nz (vector-ref r 2))
          'recipient (vector-ref r 3) 'category (vector-ref r 4) 'event (nz (vector-ref r 5))
          'subject (vector-ref r 6) 'status (vector-ref r 7) 'attempts (vector-ref r 8)
          'last_error (nz (vector-ref r 9)) 'last_latency_ms (nz (vector-ref r 10))
          'created_epoch (vector-ref r 11) 'sent_epoch (nz (vector-ref r 12))
          'next_attempt_epoch (nz (vector-ref r 13))))

;; `#:team #f` is the INSTANCE view, for the operator: it includes the two
;; transactional categories, which belong to no team. A team's own view is scoped
;; in the STATEMENT, so another team's id is a miss and not a refusal.
(define (mail-deliveries conn #:team [team #f] #:status [status #f] #:limit [limit 50])
  (define lim (number->string (min 200 (max 1 limit))))
  (define-values (clause args)
    (cond
      [(and team status) (values " WHERE team_id = ? AND status = ?" (list team status))]
      [team (values " WHERE team_id = ?" (list team))]
      [status (values " WHERE status = ?" (list status))]
      [else (values "" '())]))
  ;; The argument list is BUILT WITH the clause — the mistake this codebase has
  ;; made four times is a fixed argument list beside a conditional one.
  (for/list ([r (in-list (apply query-rows conn
                                (string-append "SELECT " LIST-COLS " FROM email_deliveries" clause
                                               " ORDER BY created_epoch DESC, id DESC LIMIT " lim)
                                args))])
    (row->delivery r)))

(define (mail-delivery-get conn id #:team [team #f])
  (define-values (clause args)
    (if team (values " AND team_id = ?" (list team)) (values "" '())))
  (define r (apply query-maybe-row conn
                   (string-append "SELECT " LIST-COLS ", body FROM email_deliveries WHERE id = ?" clause)
                   id args))
  (and r (hash-set (row->delivery r) 'body (vector-ref r 14))))

;; A dead letter goes back to pending, due now, with its attempt count RESET: an
;; operator redelivering has made a decision, and giving them one attempt out of
;; ten already spent would make the button useless. The id does not change, so the
;; `Message-ID` is the same and a relay that already accepted it recognises it.
(define (mail-redeliver! conn id #:team [team #f])
  (define-values (clause args)
    (if team (values " AND team_id = ?" (list team)) (values "" '())))
  (and (apply query-maybe-row conn
              (string-append "UPDATE email_deliveries SET status = 'pending', attempts = 0, "
                             "next_attempt_epoch = ?, last_error = NULL WHERE id = ? "
                             "AND status <> 'pending'" clause " RETURNING id")
              (now) id args)
       #t))
