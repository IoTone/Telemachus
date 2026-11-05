#lang racket/base

;; test/mail-tests.rkt — email delivery and notifications.
;;
;; The split between what runs against a REAL SMTP conversation and what scripts
;; the seam above it is deliberate, and it is #187's lesson either way:
;;
;;   • the TRANSPORT's cases drive `test/mock-smtp.rkt` on a real socket, because
;;     every interesting property there is at the wire — what the header says,
;;     whether a 5xx is told from a 4xx, whether the credential crossed, whether
;;     an address with a newline in it can append a header. Scripting that would
;;     leave the one path a message actually takes exercised nowhere;
;;   • the QUEUE's cases script the delivery, because their subject is the retry
;;     curve and the claim, and a test that needed a relay to prove a backoff
;;     would be a test about timing.
;;
;;   raco test test/mail-tests.rkt
;;   DATABASE_URL="postgres://…" raco test test/mail-tests.rkt

(require rackunit db-kit/portable db-kit/migrate
         racket/string racket/list racket/port json
         "../domain/db/migrations.rkt"
         "db-fixture.rkt"
         "../domain/db/id.rkt"
         "../domain/authz/authz.rkt"
         "../domain/events/events.rkt"
         "../domain/events/describe.rkt"
         "../domain/settings/settings.rkt"
         "../domain/repo/repo.rkt"
         "../domain/mail/transport.rkt"
         "../domain/mail/addresses.rkt"
         "../domain/mail/mail.rkt"
         (only-in "../domain/quota/quota.rkt" set-limit! quota-used)
         racket/runtime-path
         (only-in "../domain/repo/blobs.rkt" current-blob-root)
         (only-in racket/file make-directory*)
         (only-in racket/system system*/exit-code)
         (only-in racket/port open-output-nowhere)
         (only-in racket/file make-temporary-file file->string)
         openssl
         "mock-smtp.rkt")

;; EVERY HELPER IS DEFINED BEFORE ITS FIRST USE, and that is not style: a helper
;; placed below the case that calls it is "cannot reference an identifier before
;; its definition" at module instantiation, and these notes record that costing a
;; run twice already. This file made it three.

;; A temp blob root, so the private-document case does not write blobs into the
;; checkout's `data/` — the rule every repository test lives by.
(define (make-temporary-blob-root)
  (define d (build-path (find-system-path 'temp-dir)
                        (format "tmach-mail-~a" (current-inexact-milliseconds))))
  (make-directory* d)
  (path->string d))

(define (settle-for-test! c id)
  (query-exec c "UPDATE email_deliveries SET status = 'dead', attempts = 10 WHERE id = ?" id))

;; A PORT NOBODY ELSE IN THE SUITE BINDS, and one per wire case rather than one
;; shared: `raco test` runs these files concurrently, four of them already bind
;; fixed ports, and a case that reuses a port the previous case has only just
;; released fails as "address already in use" — which reads as a defect in the
;; thing under test and is a scheduling mistake. Grepped for first.
(define PORT-WIRE 8925)
(define PORT-AUTH 8926)
(define PORT-FAIL 8927)
;; NOTHING IS LISTENING HERE, which is what a transient failure looks like. It is
;; 1 rather than 0 because `transport-problem` refuses 0 — a port is 1 to 65535 —
;; and the first version of this fixture used 0 and failed three cases with the
;; validator's own refusal, which is the validator working.
(define PORT-DEAD 1)

(define (fresh) (define c (fresh-db #:migrate? #f)) (migrate! c all-migrations) c)

;; A transport row pointing at a port, with no credential.
(define (configure! c #:port port #:base [base "https://tmach.example.test"]
                    #:active [active #t] #:security [sec "none"]
                    #:host [host "127.0.0.1"] #:verify [verify #f])
  (transport-set! c (hasheq 'host host 'port port 'security sec
                            'from_address "tmach@example.test" 'from_name "TMach"
                            'base_url base 'active active 'verify_tls verify)))

;; A team, a member, and a verified address for them.
;;
;; THE FIRST TEAM GOES THROUGH `bootstrap!`, and it has to: permissions live in
;; the `roles` / `role_permissions` tables and a bare migrated database has no
;; rows in either, so `create-team!` + `add-member!` with role "owner" yields
;; `user-permissions` of `()` and the first `repo-put!` fails "forbidden:
;; files:write" against a perfectly good fixture. The built-in roles are seeded
;; with `team_id IS NULL`, so one bootstrap covers every later team.
(define (seed! c #:slug [slug "acme"] #:user [uname "alice"] #:addr [addr "alice@example.test"])
  (define bootstrapped? (> (query-value c "SELECT COUNT(*) FROM teams") 0))
  (define-values (uid tid)
    (cond
      [bootstrapped?
       (define t (create-team! c #:slug slug #:name (string-titlecase slug)))
       (define u (create-user! c #:username uname))
       (add-member! c #:user u #:team t #:role "owner")
       (values u t)]
      [else
       (bootstrap! c #:username uname #:org-name (string-titlecase slug) #:org-slug slug
                   #:team-name (string-titlecase slug) #:team-slug slug)]))
  (when addr (verify-address! c uid addr))
  (values tid uid))

;; CLAIM AND CONFIRM IN ONE STEP, for a fixture. `address-claim!` answers TWO
;; values, so `(void (address-claim! …))` is a result arity mismatch and not a
;; discard — the trap these notes record six times, which this file made seven.
(define (verify-address! c uid addr)
  (define-values (tok a) (address-claim! c uid addr))
  (check-equal? (address-verify! c tok) addr)
  a)

;; ---- the vocabulary ----------------------------------------------------------------
;; CLOSED IN BOTH DIRECTIONS, and the second direction is the one that matters:
;; an event in no category is an event nobody can ever be told about, which is
;; #113's shape — a capability the platform has and nothing can reach. It would
;; also be completely silent, because `mail-notify!` answers 0 and moves on.
(test-case "every category has events, and every event has a category"
  (for ([c (in-list MAIL-CATEGORIES)])
    (check-true (pair? (cdr (assoc c CATEGORY-EVENTS))) (format "~a covers nothing" c)))
  (for ([e (in-list EVENTS)])
    (check-true (and (category-of-event e) #t)
                (format "~a is in no category, so nobody can ever be told about it" e)))
  ;; and nothing invented along the way
  (for* ([kv (in-list CATEGORY-EVENTS)] [e (in-list (cdr kv))])
    (check-true (event? e) (format "~a: ~a is not an event this platform emits" (car kv) e))))

;; ---- an address ---------------------------------------------------------------------
(test-case "nothing has ever written users.email, so an address starts absent"
  (define c (fresh))
  (define-values (tid uid) (seed! c #:addr #f))
  (check-false (user-address c uid))
  (close-db! c))

(test-case "an address is not used until it has answered, and the token is single-use"
  (define c (fresh))
  (define-values (tid uid) (seed! c #:addr #f))
  (define-values (tok a) (address-claim! c uid "alice@example.test"))
  ;; CLAIMED is not VERIFIED: `users.email` holds a verified address and nothing
  ;; else (PULL-11e's rule — a field a reader learns to distrust is worse than no
  ;; field), so the pending one is readable only as `pending`.
  (check-false (user-address c uid))
  (check-equal? (hash-ref (user-address-state c uid) 'pending) "alice@example.test")
  ;; THE STORED VALUE IS NOT THE TOKEN. SEC-3's finding was that there were two
  ;; token-hashing rules and the weaker one was the one nobody looked at; this
  ;; asserts which rule is in use rather than trusting the call site.
  (define stored (query-value c "SELECT token_hash FROM email_verifications WHERE user_id = ?" uid))
  (check-not-equal? stored tok)
  (check-true (string-prefix? stored "v1:") "the one token-hashing rule, not a bare digest")
  (check-equal? (address-verify! c tok) "alice@example.test")
  (check-equal? (user-address c uid) "alice@example.test")
  ;; consumed in the same statement that matched it, so a second click verifies
  ;; nothing — and a replayed link cannot re-arm an address somebody has since
  ;; removed
  (check-false (address-verify! c tok))
  (close-db! c))

(test-case "a bad token and an expired one are one answer"
  (define c (fresh))
  (define-values (tid uid) (seed! c #:addr #f))
  (define-values (tok a) (address-claim! c uid "alice@example.test"))
  (check-false (address-verify! c "tk_nonsense"))
  ;; age the row rather than waiting a day out
  (query-exec c "UPDATE email_verifications SET expires_epoch = ? WHERE user_id = ?"
              (- (current-seconds) 10) uid)
  (check-false (address-verify! c tok))
  (check-false (user-address c uid))
  (close-db! c))

(test-case "claiming a new address does not silence the old one"
  ;; The failure this prevents: somebody with a working address mistypes a new
  ;; one and stops receiving anything until they notice. Clearing first and
  ;; verifying second is the obvious implementation and is the wrong order.
  (define c (fresh))
  (define-values (tid uid) (seed! c))
  (check-equal? (user-address c uid) "alice@example.test")
  (define-values (tok a) (address-claim! c uid "alice@newplace.test"))
  (check-equal? (user-address c uid) "alice@example.test"
                "the working address is still the one in use")
  (check-equal? (hash-ref (user-address-state c uid) 'pending) "alice@newplace.test")
  (check-equal? (address-verify! c tok) "alice@newplace.test")
  (check-equal? (user-address c uid) "alice@newplace.test")
  (close-db! c))

(test-case "an address that is not an address is refused, and a newline most of all"
  (check-false (mail-address-problem "a@b.test"))
  (check-true (string? (mail-address-problem "not-an-address")))
  (check-true (string? (mail-address-problem "a@b.test\r\nBcc: evil@x.test"))
              "a CRLF in an address is a header injection, not a formatting quirk")
  (check-true (string? (mail-address-problem "")))
  (check-true (string? (mail-address-problem 'null))))

;; ---- the layers ----------------------------------------------------------------------
(test-case "the instance layer is an OPT-IN: absence means off"
  ;; THE ONE REAL DIVERGENCE FROM `features.rkt`, where absence means enabled at
  ;; every layer. A feature switch governs whether an endpoint ANSWERS and the
  ;; behaviour that already existed is "it answers"; this governs whether the
  ;; instance SENDS MAIL TO PEOPLE, and the behaviour that already existed is
  ;; sending none. `object.created` fires on every upload, so a
  ;; features.rkt-shaped default would mail every member once per document the
  ;; first time anybody verified an address — on an UPGRADE, to an operator who
  ;; had configured nothing.
  (define c (fresh))
  (define-values (tid uid) (seed! c))
  (for ([cat (in-list MAIL-CATEGORIES)])
    (check-equal? (category-scope c cat #:user uid #:team tid) "instance"
                  (format "~a is off until an operator names it" cat)))
  (instance-categories-set! c (hasheq 'workflows #t))
  (check-false (category-scope c "workflows" #:user uid #:team tid))
  (check-equal? (category-scope c "jobs" #:user uid #:team tid) "instance")
  (close-db! c))

(test-case "a person may turn one off, and may not turn one on"
  (define c (fresh))
  (define-values (tid uid) (seed! c))
  (instance-categories-set! c (hasheq 'workflows #t))
  (user-pref-set! c uid "workflows" #f)
  (check-equal? (category-scope c "workflows" #:user uid #:team tid) "user")
  ;; AND THE OPT-OUT SURVIVES THE LAYER ABOVE MOVING. An opt-out is a standing
  ;; instruction, exactly as a team's own feature row is — the obvious bug is to
  ;; re-enable somebody silently when an operator flips the instance switch.
  (instance-categories-set! c (hasheq 'workflows #f))
  (instance-categories-set! c (hasheq 'workflows #t))
  (check-equal? (category-scope c "workflows" #:user uid #:team tid) "user")
  ;; Turning it back on REMOVES the row rather than storing a positive: absence
  ;; already means "I have not objected", and writing the positive would make one
  ;; state two rows.
  (user-pref-set! c uid "workflows" #t)
  (check-false (category-scope c "workflows" #:user uid #:team tid))
  (check-equal? (query-value c "SELECT COUNT(*) FROM email_prefs WHERE user_id = ?" uid) 0)
  ;; A person cannot reach past the instance.
  (instance-categories-set! c (hasheq))
  (user-pref-set! c uid "workflows" #t)
  (check-equal? (category-scope c "workflows" #:user uid #:team tid) "instance")
  (close-db! c))

(test-case "the scope names the FURTHEST layer that objects"
  ;; `features.rkt`'s `disabled_by`, and QVIZ-11's lesson that the precedence is
  ;; only testable where two layers apply AT ONCE — the fixture has to produce
  ;; that state or the ordering is untested while looking tested.
  (define c (fresh))
  (define-values (tid uid) (seed! c))
  (user-pref-set! c uid "workflows" #f)          ; the user objects …
  (check-equal? (category-scope c "workflows" #:user uid #:team tid) "instance"
                "… and the instance's silence is named first, because they cannot change it")
  (instance-categories-set! c (hasheq 'workflows #t))
  (check-equal? (category-scope c "workflows" #:user uid #:team tid) "user")
  (close-db! c))

(test-case "an unknown category is refused, not stored"
  (define c (fresh))
  (check-true (string? (prefs-problem (hasheq 'wat #t))))
  (check-true (string? (prefs-problem (hasheq 'workflows "yes"))))
  (check-false (prefs-problem (hasheq 'workflows #t 'jobs #f)))
  (check-exn exn:fail? (lambda () (user-pref-set! c "u" "wat" #f)))
  (close-db! c))

;; ---- the fan-out ---------------------------------------------------------------------
(test-case "nothing is queued without a transport"
  ;; What makes this subsystem safe on an upgrade, together with MAIL-5: a row
  ;; written on an instance that cannot send is a pending delivery retried ten
  ;; times and then dead, for every event, for ever.
  (define c (fresh))
  (define-values (tid uid) (seed! c))
  (instance-categories-set! c (hasheq 'jobs #t))
  (check-equal? (mail-notify! c "job.completed" tid (hasheq 'job_id "j1")) 0)
  (check-equal? (query-value c "SELECT COUNT(*) FROM email_deliveries") 0)
  ;; AND THE TRANSACTIONAL PATH TOO, which is where `mail-enqueue!`'s own guard is
  ;; the only one — a control showed that `mail-notify!` asks the same question
  ;; first, so going only through the sink left the enqueue's guard untested while
  ;; looking tested. Somebody claiming an address on an instance with no transport
  ;; must not leave a row that is retried ten times and then dies.
  (check-false (mail-enqueue-verification! c #:user uid #:address "a@example.test" #:token "tk_x"))
  (check-equal? (query-value c "SELECT COUNT(*) FROM email_deliveries") 0)
  (close-db! c))

(test-case "an unverified address receives nothing"
  (define c (fresh))
  (configure! c #:port PORT-DEAD)
  (define-values (tid uid) (seed! c #:addr #f))
  (instance-categories-set! c (hasheq 'jobs #t))
  ;; claimed but never confirmed
  (define-values (_tok _a) (address-claim! c uid "alice@example.test"))
  (check-equal? (mail-notify! c "job.completed" tid (hasheq 'job_id "j1")) 0)
  (close-db! c))

(test-case "a row with an address and no confirmation stamp receives nothing"
  ;; THE FILTER THIS COVERS WAS UNTESTED, AND A CONTROL IS WHAT SAID SO. Dropping
  ;; `email_verified_epoch IS NOT NULL` from the fan-out changed no case, because
  ;; `users.email` only ever holds a VERIFIED address (MAIL-5) and the sibling
  ;; `u.email IS NOT NULL` clause was doing all the work. So the epoch filter is
  ;; belt-and-braces, exactly as the migration says — and it is reachable: a
  ;; hand-edited row, a restored dump from a build before 0069, or a future code
  ;; path that writes the column without stamping it. This is that row, written
  ;; by hand because nothing in the tree can produce it.
  (define c (fresh))
  (configure! c #:port PORT-DEAD)
  (define-values (tid uid) (seed! c #:addr #f))
  (instance-categories-set! c (hasheq 'jobs #t))
  (query-exec c "UPDATE users SET email = ? WHERE id = ?" "alice@example.test" uid)
  (check-equal? (mail-notify! c "job.completed" tid (hasheq 'job_id "j1")) 0
                "an address nobody has confirmed is not an address this instance may use")
  (close-db! c))

(test-case "one event, one row per member who wants it"
  (define c (fresh))
  (configure! c #:port PORT-DEAD)
  (define-values (tid alice) (seed! c))
  (define bob (create-user! c #:username "bob"))
  (add-member! c #:user bob #:team tid #:role "member")
  (verify-address! c bob "bob@example.test")
  (instance-categories-set! c (hasheq 'jobs #t))
  (check-equal? (mail-notify! c "job.completed" tid (hasheq 'job_id "j1")) 2)
  (user-pref-set! c bob "jobs" #f)
  (check-equal? (mail-notify! c "job.completed" tid (hasheq 'job_id "j2")) 1)
  ;; a member of ANOTHER team hears nothing
  (define-values (tid2 carol) (seed! c #:slug "ops" #:user "carol" #:addr "carol@example.test"))
  (check-equal? (mail-notify! c "job.completed" tid (hasheq 'job_id "j3")) 1)
  (close-db! c))

(test-case "a member who may not read the document is not told it exists"
  ;; MAIL-17, and TAG-6's rule: a count is a count but somebody's words are
  ;; somebody's. On a team with private documents this is the ORDINARY case.
  (define c (fresh))
  (configure! c #:port PORT-DEAD)
  (define-values (tid alice) (seed! c))
  (define bob (create-user! c #:username "bob"))
  (add-member! c #:user bob #:team tid #:role "member")
  (verify-address! c bob "bob@example.test")
  (instance-categories-set! c (hasheq 'documents #t))
  (parameterize ([current-blob-root (make-temporary-blob-root)])
    (define ap (user-principal c alice tid))
    (define obj (repo-put! c ap #:key "private/secret.txt"
                           #:port (open-input-string "hello")
                           #:content-type "text/plain" #:visibility "private"))
    (define oid (hash-ref obj 'id))
    ;; alice owns it; bob cannot read it
    (define n (mail-notify! c "object.created" tid (hasheq 'object_id oid 'derived #f)))
    (check-equal? n 1 "only the owner is told")
    (define rcpts (notification-recipients c tid "documents" "object.created"
                                           (hasheq 'object_id oid)))
    (check-equal? (map car rcpts) (list alice)))
  (close-db! c))

;; ---- what a team may spend on telling people (MAIL-25) --------------------------------
;; The dimension exists so that a plugin calling `mail-notify!` in a loop meets a
;; limit rather than this instance's standing with the relays meeting it. Every
;; case below is about WHERE the bound sits, because that is the whole of the
;; design: at the fan-out, so the four transactional messages are outside it by
;; construction and not by a flag somebody can forget.

(define-runtime-path test-dir ".")
(define ADMISSION-RKT (build-path test-dir ".." "server" "admission.rkt"))

;; A text scan, because `server/admission.rkt` requires `kit.rkt`, which
;; instantiates the connection pool at module instantiation and reads
;; `DATABASE_URL` — and CI's sqlite leg sets that to the EMPTY STRING, which
;; `db-connector` refuses. #123 paid for exactly that: a unit test must not
;; require kit. Comment lines are stripped, which is the fourth-appearance rule
;; for a scan that would otherwise read the prose explaining what it looks for.
(define (admission-code)
  (string-join
   (for/list ([ln (in-list (string-split (file->string ADMISSION-RKT) "\n"))]
              #:unless (regexp-match? #px"^[ \t]*;" ln))
     ln)
   "\n"))

(test-case "MAIL-25: it is NOT a hold dimension, and that is load-bearing"
  ;; A hold stops a team's SCHEDULER QUEUE until the window resets. A
  ;; notification is emitted FROM a job — a workflow run completing is what fires
  ;; `run.completed` — so holding on this dimension would stop a team's actual
  ;; work because it had sent too much mail. And a delivery is not a job at all:
  ;; it is a row swept on the reaper seam, so there is no queue of deliveries for
  ;; a hold to govern. The refusal belongs at the fan-out, where the other cases
  ;; here assert it is.
  (check-false (regexp-match? (regexp (regexp-quote MAIL-QUOTA-DIM)) (admission-code))
               (string-append MAIL-QUOTA-DIM " must not reach QUOTA-HOLD-DIMS: holding on it"
                              " stops the jobs that EMIT notifications")))

(test-case "MAIL-25: a fan-out is metered per mailbox, and no limit refuses nothing"
  (define c (fresh))
  (configure! c #:port PORT-DEAD)
  (define-values (tid alice) (seed! c))
  (define bob (create-user! c #:username "bob"))
  (add-member! c #:user bob #:team tid #:role "member")
  (verify-address! c bob "bob@example.test")
  (instance-categories-set! c (hasheq 'jobs #t))
  ;; ONE EVENT TO TWO MEMBERS IS TWO, because the resource is spent per mailbox.
  (check-equal? (mail-notify! c "job.completed" tid (hasheq 'job_id "j1")) 2)
  ;; `quota-check` reports `used: 0` where no limit is set, so the ledger is what
  ;; has to be read — this file's fourth asker of that rule.
  (check-equal? (quota-used c "team" tid MAIL-QUOTA-DIM "total") 2)
  (check-equal? (mail-notify! c "job.completed" tid (hasheq 'job_id "j2")) 2)
  (check-equal? (quota-used c "team" tid MAIL-QUOTA-DIM "total") 4
                "with no limit configured nothing is refused, and the figure still accrues")
  (close-db! c))

(test-case "MAIL-25: a reached limit refuses the next event and writes no row"
  (define c (fresh))
  (configure! c #:port PORT-DEAD)
  (define-values (tid alice) (seed! c))
  (instance-categories-set! c (hasheq 'jobs #t))
  (set-limit! c "team" tid MAIL-QUOTA-DIM 2 #:window "total")
  (check-equal? (mail-notify! c "job.completed" tid (hasheq 'job_id "j1")) 1)
  (check-equal? (mail-notify! c "job.completed" tid (hasheq 'job_id "j2")) 1)
  (check-equal? (mail-notify! c "job.completed" tid (hasheq 'job_id "j3")) 0
                "the third is refused")
  ;; A refusal is not a pending row: nothing was written, so nothing will be
  ;; retried ten times and die. MAIL-10's rule, arriving through a second door.
  (check-equal? (query-value c "SELECT COUNT(*) FROM email_deliveries") 2)
  (close-db! c))

(test-case "MAIL-25: the check asks for ONE unit, not for the whole fan-out"
  ;; THE POSITIVE CONTROL FOR THE SHARPEST DECISION IN THIS SLICE. Asking for N
  ;; and refusing the lot means a team of two under a limit of one is refused
  ;; EVERY event for ever while its ledger stays at `used: 0` — a bound that
  ;; silences a team and reports that it was never reached. Swap the `1` in
  ;; `mail-notify!` for `(length recips)` and the first assertion here answers 0
  ;; and the second 0, which is that state exactly.
  (define c (fresh))
  (configure! c #:port PORT-DEAD)
  (define-values (tid alice) (seed! c))
  (define bob (create-user! c #:username "bob"))
  (add-member! c #:user bob #:team tid #:role "member")
  (verify-address! c bob "bob@example.test")
  (instance-categories-set! c (hasheq 'jobs #t))
  (set-limit! c "team" tid MAIL-QUOTA-DIM 1 #:window "total")
  (check-equal? (mail-notify! c "job.completed" tid (hasheq 'job_id "j1")) 2
                "both members are told, because there was budget for a message")
  ;; THE OVERSHOOT IS REAL AND IS STATED RATHER THAN IMPLIED: the window ends
  ;; over the limit, by at most one team's membership — the same overshoot every
  ;; AI dimension accepts between an admission estimate and a metered actual.
  (check-equal? (quota-used c "team" tid MAIL-QUOTA-DIM "total") 2)
  (check-equal? (mail-notify! c "job.completed" tid (hasheq 'job_id "j2")) 0
                "and the next event is refused, with the figure saying why")
  (close-db! c))

(test-case "MAIL-25: a TRANSACTIONAL message is outside the bound"
  ;; RESET-5 with a number in front of it. The preference layers exist so a
  ;; person can stop this instance mailing them and a person who has turned
  ;; every category off must still be able to recover their account; a quota
  ;; that could refuse a reset would be that defect again. The bound sits at the
  ;; fan-out, so this holds by construction — there is no keyword here saying
  ;; "do not count this one", which is what a check inside `mail-enqueue!` would
  ;; have needed and what the one caller that forgot it would have broken.
  (define c (fresh))
  (configure! c #:port PORT-DEAD)
  (define-values (tid alice) (seed! c))
  (instance-categories-set! c (hasheq 'jobs #t))
  (set-limit! c "team" tid MAIL-QUOTA-DIM 1 #:window "total")
  (check-equal? (mail-notify! c "job.completed" tid (hasheq 'job_id "j1")) 1)
  (check-equal? (mail-notify! c "job.completed" tid (hasheq 'job_id "j2")) 0
                "the notification budget really is exhausted")
  ;; …and all four transactional messages still go out.
  (check-true (string? (mail-enqueue-password-reset! c #:user alice
                                                     #:address "alice@example.test"
                                                     #:token "rtok"))
              "a password reset cannot be refused by a mail quota")
  (check-true (string? (mail-enqueue-verification! c #:user alice
                                                   #:address "alice2@example.test"
                                                   #:token "vtok")))
  (check-true (string? (mail-enqueue-invitation! c #:user alice
                                                 #:address "new@example.test"
                                                 #:token "itok"
                                                 #:team-name "Acme" #:inviter "alice")))
  ;; and they do not move the dimension either, so the figure keeps meaning
  ;; "notifications" rather than "mail"
  (check-equal? (quota-used c "team" tid MAIL-QUOTA-DIM "total") 1)
  (close-db! c))

(test-case "MAIL-25: a refusal is audited, with a count and not the addresses"
  (define c (fresh))
  (configure! c #:port PORT-DEAD)
  (define-values (tid alice) (seed! c))
  (define bob (create-user! c #:username "bob"))
  (add-member! c #:user bob #:team tid #:role "member")
  (verify-address! c bob "bob@example.test")
  (instance-categories-set! c (hasheq 'jobs #t))
  (set-limit! c "team" tid MAIL-QUOTA-DIM 0 #:window "total")
  (check-equal? (mail-notify! c "job.completed" tid (hasheq 'job_id "j1")) 0)
  ;; `audit-list` does not project `meta` — #59's rule, and asserting over an API
  ;; that never carried the field is how an assertion passes for the wrong
  ;; reason — so the row is read directly.
  (define row (query-maybe-row c
                (string-append "SELECT team_id, result, meta FROM audit_log "
                               "WHERE action = 'email.notify.refused'")))
  (check-true (and row #t) "a notification nobody received is otherwise pure silence")
  (check-equal? (vector-ref row 0) tid
                "the team whose members were not told, or audit-list cannot see it")
  (check-equal? (vector-ref row 1) "refused")
  (define meta (string->jsexpr (vector-ref row 2)))
  (check-equal? (hash-ref meta 'recipients) 2)
  (check-equal? (hash-ref meta 'dimension) MAIL-QUOTA-DIM)
  (check-equal? (hash-ref meta 'scope) "team")
  ;; THE LOG IS CHAINED, EXPORTED AND KEPT THROUGH AN ERASURE (DEL-7), so it
  ;; outlives every other copy — and a list of the mailboxes of everybody on a
  ;; team is the one thing here most worth not writing into it.
  (check-false (regexp-match? #px"alice@|bob@" (vector-ref row 2)))
  (close-db! c))

(test-case "MAIL-25: an event nobody was going to hear about spends nothing"
  ;; The recipients are resolved before anything is spent. On a team where every
  ;; member has turned the category off — or may not read the subject (MAIL-17) —
  ;; that is the ordinary case rather than a corner, so a check and an audit
  ;; entry per such event would be a ledger and a log full of nothing.
  (define c (fresh))
  (configure! c #:port PORT-DEAD)
  (define-values (tid alice) (seed! c))
  (instance-categories-set! c (hasheq 'jobs #t))
  (user-pref-set! c alice "jobs" #f)
  (set-limit! c "team" tid MAIL-QUOTA-DIM 0 #:window "total")
  (check-equal? (mail-notify! c "job.completed" tid (hasheq 'job_id "j1")) 0)
  (check-equal? (query-value c
                  "SELECT COUNT(*) FROM audit_log WHERE action = 'email.notify.refused'") 0
                "nothing was refused, because nothing was going to be sent")
  (close-db! c))

;; ---- what a message says -------------------------------------------------------------
(test-case "a message carries ids, a status, a slug and a link — and no content"
  ;; MAIL-9 / MTX-8, and it binds harder than it does for a chat room: an inbox
  ;; leaves the instance altogether, rests on a third party's server, is indexed
  ;; by them and is forwarded onwards by its reader.
  (define data (hasheq 'run_id "3f2a91bc-dead-beef" 'status "done"
                       'workflow "process-upload"
                       'url "/api/runs/3f2a91bc-dead-beef"
                       ;; keys no emitter sends today, here as the control: a
                       ;; composer that reached for whatever was in the payload
                       ;; would put them in somebody's inbox
                       'key "clients/Arun Patel/tax-return.pdf"
                       'title "Arun Patel 2026 return"
                       'body "the patient's name is …"))
  (define-values (subject body)
    (compose-notification "run.completed" data #:base "https://tmach.example.test"
                          #:team-name "Acme"))
  (check-true (string-contains? subject "3f2a91bc"))
  (check-true (string-contains? subject "process-upload") "a team's own word for a process")
  (check-true (string-contains? subject "Acme") "whose team, because a person is in several")
  (check-true (string-contains? body "https://tmach.example.test/#/workflows/runs/3f2a91bc-dead-beef")
              "a CONSOLE link: the payload's own url answers JSON and is useless in an inbox")
  (for ([needle (in-list '("Arun" "tax-return" "patient" "2026 return"))])
    (check-false (string-contains? subject needle) (format "subject leaked ~a" needle))
    (check-false (string-contains? body needle) (format "body leaked ~a" needle))))

(test-case "with no base URL there is no link, and the message says so"
  ;; A relative fragment in an email is not a link at all, and the instance cannot
  ;; guess its own external hostname: the Host header belongs to a CALLER and a
  ;; notification is composed by a sweep with no request in sight.
  (define-values (s b) (compose-notification "run.failed" (hasheq 'run_id "r1") #:base #f))
  (check-false (string-contains? b "#/"))
  (check-true (string-contains? b "base URL")))

(test-case "a deleted document links to the tab, not to a page that is gone"
  (check-equal? (event-console-path "object.deleted" (hasheq 'object_id "o1")) "#/repository")
  (check-equal? (event-console-path "object.created" (hasheq 'object_id "o1")) "#/repository/o1")
  ;; An id-shaped pattern with NO id is not silently turned into a tab link: it
  ;; means the payload changed shape, and a link to the wrong place is worse than
  ;; none.
  (check-false (event-console-path "run.completed" (hasheq 'status "done"))))

(test-case "a refusal keeps the value and not its control characters"
  ;; THE ONE PROPERTY `printable` EXISTS FOR WAS UNTESTED, and a control said so.
  ;; The path is reachable: `smtp-deliver!` refuses an address with a CRLF in it —
  ;; which is the whole reason `valid-address?` looks for one — and that refusal
  ;; becomes `email_deliveries.last_error` AND a line in the container log. A
  ;; newline there forges log lines, which is the same primitive as the header
  ;; injection with a different reader.
  (define t (hasheq 'host "127.0.0.1" 'port PORT-DEAD 'security "none" 'username 'null
                    'from_address "tmach@example.test" 'from_name 'null 'base_url 'null
                    'active #t 'has_password #f))
  (define msg
    (with-handlers ([exn:fail:mail? exn-message])
      (smtp-deliver! t "a@b.test\r\nBcc: evil@x.test" "s" "b")
      "it was NOT refused"))
  (check-false (regexp-match? #px"[\r\n]" msg) "a refusal must not forge a log line")
  (check-true (string-contains? msg "a@b.test")
              "and the value survives, legibly — SEC-6's line: the host survives, the credential does not")
  (check-true (string-contains? msg "Bcc")))

(test-case "a non-ASCII subject is an RFC 2047 encoded-word, because the console ships ja"
  (define enc (encode-subject "ワークフローが完了しました"))
  (check-true (string-prefix? enc "=?UTF-8?B?"))
  (check-true (string-suffix? enc "?="))
  ;; ASCII passes through, so an ordinary subject stays readable in a dead letter
  ;; an operator inspects
  (check-equal? (encode-subject "run 3f2a finished") "run 3f2a finished")
  ;; and a newline in a subject cannot append a header
  (check-false (regexp-match? #px"[\r\n]" (encode-subject "a\r\nBcc: x@y.test"))))

;; ---- the wire ------------------------------------------------------------------------
(test-case "a message really goes out, and the header is conformant"
  (define c (fresh))
  (mock-clear!)
  (start-mock-smtp! #:port PORT-WIRE)
  (configure! c #:port PORT-WIRE)
  (define-values (tid uid) (seed! c))
  (instance-categories-set! c (hasheq 'jobs #t))
  (check-equal? (mail-notify! c "job.completed" tid (hasheq 'job_id "j1" 'status "done")) 1)
  (define-values (sent _r dead) (mail-deliver-due! c))
  (check-equal? sent 1)
  (check-equal? dead 0)
  (check-equal? (mock-message-count) 1)
  (define m (mock-last-message))
  (check-equal? (mock-msg-from m) "tmach@example.test")
  (check-equal? (mock-msg-to m) (list "alice@example.test"))
  (define raw (mock-msg-data m))
  (check-true (string-contains? raw "Content-Type: text/plain; charset=utf-8"))
  (check-true (string-contains? raw "Content-Transfer-Encoding: base64"))
  (check-true (string-contains? raw "Auto-Submitted: auto-generated")
              "a notification is not a message somebody should auto-reply to")
  (check-true (string-contains? raw "Message-ID: <")
              "the delivery's own id, so a mail log and this database agree")
  ;; An ASCII display name passes through, by design, so an ordinary message
  ;; stays readable in a transcript and in a dead letter an operator inspects;
  ;; the encoding rule has its own case above, on a Japanese subject.
  (check-true (string-contains? raw "From: TMach <tmach@example.test>"))
  (stop-mock-smtp!)
  (close-db! c))

(test-case "the credential crosses the wire when there is one"
  (define c (fresh))
  (mock-clear!)
  (start-mock-smtp! #:port PORT-AUTH #:auth (cons "postmaster" "s3cret"))
  (transport-set! c (hasheq 'host "127.0.0.1" 'port PORT-AUTH 'security "none"
                            'username "postmaster" 'password "s3cret"
                            'from_address "tmach@example.test" 'base_url "https://x.test"))
  ;; THE PASSWORD IS NEVER IN A READ — #19's rule, and `webhook-list`'s.
  (define t (transport-ref c))
  (check-true (hash-ref t 'has_password))
  (check-false (hash-has-key? t 'password))
  ;; and the stored value is not the plaintext when a key is configured — the
  ;; sealing itself is `sealed-column-tests.rkt`'s subject, this only asserts the
  ;; column round-trips through the right accessor
  (check-equal? (transport-password c) "s3cret")
  (define-values (ok? err) (mail-send-test! c "ops@example.test"))
  (check-true ok? (format "the test send failed: ~a" err))
  (check-equal? (mock-message-count) 1)
  (stop-mock-smtp!)
  (close-db! c))

(test-case "a 5xx is a dead letter on the FIRST attempt; a 4xx is retried"
  ;; The whole of this subsystem's retry policy, and it is read off a reply code.
  ;; A refused recipient will be refused identically in eight hours, so nine more
  ;; attempts are nine more identical refusals — and against a relay that counts
  ;; them, a reputation cost.
  (define c (fresh))
  (mock-clear!)
  (start-mock-smtp! #:port PORT-FAIL #:fail (cons 'rcpt 550))
  (configure! c #:port PORT-FAIL)
  (define-values (tid uid) (seed! c))
  (instance-categories-set! c (hasheq 'jobs #t))
  (void (mail-notify! c "job.completed" tid (hasheq 'job_id "j1")))
  (define id (query-value c "SELECT id FROM email_deliveries WHERE category = 'jobs'"))
  (check-equal? (mail-deliver-one! c id) 'dead)
  (define row (mail-delivery-get c id))
  (check-equal? (hash-ref row 'status) "dead")
  (check-equal? (hash-ref row 'attempts) 1 "one attempt, not ten")
  ;; THE RELAY'S OWN WORDS ARE KEPT — the most useful thing an operator has for a
  ;; transport that will not answer — AND BOUNDED, because many relays echo the
  ;; message back inside a reply (FEED-6). SEC-8's `provider-detail`, in SMTP's
  ;; vocabulary.
  (define e (hash-ref row 'last_error))
  (check-true (string-contains? e "550"))
  (check-true (<= (string-length e) 440) (format "the reply was not bounded: ~a chars" (string-length e)))
  (stop-mock-smtp!)
  (mock-clear!)
  (start-mock-smtp! #:port PORT-FAIL #:fail (cons 'data 451))
  (void (mail-notify! c "job.completed" tid (hasheq 'job_id "j2")))
  (define id2 (query-value c "SELECT id FROM email_deliveries WHERE subject LIKE '%j2%'"))
  (check-equal? (mail-deliver-one! c id2) 'retry)
  (check-equal? (hash-ref (mail-delivery-get c id2) 'status) "pending")
  (stop-mock-smtp!)
  (close-db! c))

(test-case "nothing listening is transient, and the ceiling is what ends it"
  (define c (fresh))
  (configure! c #:port PORT-DEAD)                       ; nothing is there
  (define-values (tid uid) (seed! c))
  (instance-categories-set! c (hasheq 'jobs #t))
  (void (mail-notify! c "job.completed" tid (hasheq 'job_id "j1")))
  (define id (query-value c "SELECT id FROM email_deliveries"))
  (for ([n (in-range 1 MAX-ATTEMPTS)])
    ;; the claim moves the due time out, so each attempt has to be made due again
    (query-exec c "UPDATE email_deliveries SET next_attempt_epoch = ? WHERE id = ?"
                (current-seconds) id)
    (check-equal? (mail-deliver-one! c id) 'retry (format "attempt ~a" n)))
  (query-exec c "UPDATE email_deliveries SET next_attempt_epoch = ? WHERE id = ?"
              (current-seconds) id)
  (check-equal? (mail-deliver-one! c id) 'dead)
  (check-equal? (hash-ref (mail-delivery-get c id) 'attempts) MAX-ATTEMPTS
                "a dead letter reports the attempts it made, not one fewer")
  (close-db! c))

;; ---- the claim ------------------------------------------------------------------------
(test-case "two senders cannot both win one row"
  ;; WHK-1's recorded lesson, and it is why `claim-mail!` is exported: a claim
  ;; asserted through two SERIAL `mail-deliver-one!` calls cannot see the guard at
  ;; all, because the first one moves the due time — that control passed against
  ;; the unguarded version.
  ;;
  ;; EMAIL CANNOT ABSORB A DOUBLE SEND. A webhook receiver dedupes on the
  ;; delivery id it is handed; a person's inbox holds the message twice.
  (define c (fresh))
  (configure! c #:port PORT-DEAD)
  (define-values (tid uid) (seed! c))
  (instance-categories-set! c (hasheq 'jobs #t))
  (void (mail-notify! c "job.completed" tid (hasheq 'job_id "j1")))
  (define id (query-value c "SELECT id FROM email_deliveries"))
  (define row (query-maybe-row c (string-append
                                  "SELECT id, team_id, user_id, recipient, category, event, "
                                  "subject, body, attempts FROM email_deliveries WHERE id = ?") id))
  ;; both senders read the SAME row, as two replicas would
  (check-true (and (claim-mail! c id row) #t) "the first sender takes it")
  (check-false (claim-mail! c id row) "the second is refused")
  ;; WHICH CLAUSE REFUSED IT, because a control showed the answer is not the
  ;; obvious one: the first claim moved the due time at least a minute out, so
  ;; `next_attempt_epoch <= now` alone settles the race and removing the
  ;; `attempts = ?` comparison fails nothing above. The comparison is reachable
  ;; nonetheless, and this is the state: a sender reads the row, an operator
  ;; REDELIVERS it (attempts back to 0, due now), and the sender then claims —
  ;; without the comparison it would take the row and set attempts to 1, throwing
  ;; the operator's reset away.
  (settle-for-test! c id)
  (check-true (mail-redeliver! c id #:team tid))
  (define stale (query-maybe-row c (string-append
                                    "SELECT id, team_id, user_id, recipient, category, event, "
                                    "subject, body, attempts FROM email_deliveries WHERE id = ?") id))
  ;; the sender's copy says what the row said BEFORE the redelivery
  (vector-set! stale 8 9)
  (check-false (claim-mail! c id stale)
               "a sender holding a pre-redelivery read must not overwrite the reset")
  (check-equal? (hash-ref (mail-delivery-get c id #:team tid) 'attempts) 0)
  (close-db! c))

(test-case "the claim sets the due time, and the failure path does not touch it"
  ;; WHK-1's one-home rule: re-applying the backoff in the failure path yields the
  ;; same number, so a second write differs only by the seconds the conversation
  ;; took — which is why this says what it does and does not cover rather than
  ;; being trusted to catch a regression.
  (define c (fresh))
  (configure! c #:port PORT-DEAD)
  (define-values (tid uid) (seed! c))
  (instance-categories-set! c (hasheq 'jobs #t))
  (void (mail-notify! c "job.completed" tid (hasheq 'job_id "j1")))
  (define id (query-value c "SELECT id FROM email_deliveries"))
  (check-equal? (mail-deliver-one! c id) 'retry)
  (define due (query-value c "SELECT next_attempt_epoch FROM email_deliveries WHERE id = ?" id))
  (check-true (>= due (+ (current-seconds) (- (backoff-seconds 1) 5)))
              "the first retry is a minute out, which is what makes the curve honest")
  (close-db! c))

(test-case "a redelivery resets the attempts and keeps the id"
  (define c (fresh))
  (configure! c #:port PORT-DEAD)
  (define-values (tid uid) (seed! c))
  (instance-categories-set! c (hasheq 'jobs #t))
  (void (mail-notify! c "job.completed" tid (hasheq 'job_id "j1")))
  (define id (query-value c "SELECT id FROM email_deliveries"))
  (settle-for-test! c id)
  (check-true (mail-redeliver! c id #:team tid))
  (define row (mail-delivery-get c id #:team tid))
  (check-equal? (hash-ref row 'status) "pending")
  (check-equal? (hash-ref row 'attempts) 0
                "an operator redelivering has made a decision; one attempt of ten would be useless")
  (check-equal? (hash-ref row 'id) id "the id does not change, so the Message-ID is the same")
  ;; a pending row cannot be redelivered — there is nothing to decide
  (check-false (mail-redeliver! c id #:team tid))
  ;; and another team's id is a miss
  (check-false (mail-redeliver! c id #:team "someone-else"))
  (close-db! c))

;; ---- the record -----------------------------------------------------------------------
(test-case "a listing carries no body, and one delivery does"
  (define c (fresh))
  (configure! c #:port PORT-DEAD)
  (define-values (tid uid) (seed! c))
  (instance-categories-set! c (hasheq 'jobs #t))
  (void (mail-notify! c "job.completed" tid (hasheq 'job_id "j1")))
  (define l (mail-deliveries c #:team tid))
  (check-equal? (length l) 1)
  (check-false (hash-has-key? (car l) 'body)
               "a dead-letter list answers what is failing and why; a page of bodies is not that")
  (check-true (string? (hash-ref (mail-delivery-get c (hash-ref (car l) 'id) #:team tid) 'body)))
  ;; the transactional messages belong to no team, so a team's view excludes them
  (void (mail-enqueue-verification! c #:user uid #:address "x@example.test" #:token "tk_x"))
  (check-equal? (length (mail-deliveries c #:team tid)) 1)
  (check-equal? (length (mail-deliveries c)) 2 "the operator's view has both")
  (close-db! c))

;; ---- the TLS branches, which NOTHING exercised (MAIL-9) ---------------------
;;
;; `mail-tests.rkt` has said so since the slice landed: both are the same
;; `smtp-send-message` call with a different connector argument, and driving
;; either end to end needs a certificate the mock has to be given —
;; `mock-tls-encode` was the hook and nothing called it. Most real deployments
;; use STARTTLS on 587, so it was the one branch that mattered most and was
;; covered least. The LibreOffice branch's rule, closed.
;;
;; WHAT THESE CASES ESTABLISH, stated precisely, because the measurement is more
;; interesting than the coverage: the handshake really happens and the session
;; survives it in BOTH modes, AND **the client does not verify the relay's
;; certificate**. That second half is not an assumption — a self-signed
;; certificate the mock mints for itself is ACCEPTED, which is only possible
;; with verification off, and `net/smtp` is where it comes from: it calls the
;; encoder with `#:mode 'connect #:encrypt 'tls #:close-original? #t` and NO
;; `#:context`, so the default client context answers and that one does not
;; verify. The consequence is the honest one — TLS here defends against a
;; passive listener on the path and NOT against an active machine-in-the-middle
;; that can present any certificate. Making it verify is a behaviour decision
;; (it would refuse the self-signed internal relay these deployments often run),
;; so it is named rather than slipped in.

(define PORT-STARTTLS 8950)
(define PORT-TLS 8951)

;; openssl is in the devShell. A box without it SKIPS AND SAYS WHICH BRANCH went
;; unexercised, because a silent skip is how a path goes untested for a year —
;; the S3 smoke's own lesson, which this file is not going to repeat.
(define (self-signed!)
  (define ssl (find-executable-path "openssl"))
  (cond
    [(not ssl) #f]
    [else
     (define d (build-path (find-system-path 'temp-dir)
                           (format "tmach-mailtls-~a" (current-inexact-milliseconds))))
     (make-directory* d)
     (define key (build-path d "k.pem"))
     (define crt (build-path d "c.pem"))
     (define code
       (parameterize ([current-output-port (open-output-nowhere)]
                      [current-error-port (open-output-nowhere)])
         (system*/exit-code ssl "req" "-x509" "-newkey" "rsa:2048" "-nodes"
                            "-keyout" (path->string key) "-out" (path->string crt)
                            "-days" "1" "-subj" "/CN=127.0.0.1")))
     (and (zero? code) (file-exists? crt) (file-exists? key) (cons crt key))]))

;; The server half of the handshake, for both modes. `ports->ssl-ports` in
;; 'accept mode with a context carrying the certificate — which is exactly what
;; the mock's STARTTLS arm has always handed off to.
(define (accept-encoder crt key)
  (lambda (in out)
    (define ctx (ssl-make-server-context))
    (ssl-load-certificate-chain! ctx crt)
    (ssl-load-private-key! ctx key)
    (ports->ssl-ports in out #:mode 'accept #:context ctx #:close-original? #t)))

(define (tls-case label port security starttls? tls?)
  (define pair (self-signed!))
  (cond
    [(not pair)
     (printf "mail-tests: SKIPPED ~a — no openssl on PATH, so that branch went unexercised\n" label)]
    [else
     (define c (fresh))
     (mock-clear!)
     (parameterize ([mock-tls-encode (accept-encoder (car pair) (cdr pair))])
       (start-mock-smtp! #:port port #:starttls? starttls? #:tls? tls?)
       (configure! c #:port port #:security security)
       (define-values (ok? err) (mail-send-test! c "tls@example.test"))
       (stop-mock-smtp!)
       ;; THE HANDSHAKE COMPLETED AND THE SESSION SURVIVED IT, which is the whole
       ;; claim: a WHOLE message is in the mock's record, so MAIL FROM, RCPT TO,
       ;; DATA, the body and the dot were all read through the encrypted ports —
       ;; and in the implicit case the 220 itself was.
       (check-true ok? (format "~a: ~a" label err))
       (check-false err)
       (define m (mock-last-message))
       (check-true (mock-msg? m) (format "~a: a message was recorded" label))
       (check-equal? (mock-msg-to m) (list "tls@example.test"))
       (check-true (regexp-match? #px"Subject:" (mock-msg-data m))
                   (format "~a: the headers survived the wrap" label)))
     (close-db! c)]))

(test-case "MAIL-9: STARTTLS really negotiates, and the session survives it"
  ;; `net/smtp` REQUIRES the server to advertise STARTTLS in its EHLO reply and
  ;; re-sends EHLO afterwards (RFC 3207 4.2), so this also exercises the mock's
  ;; second greeting — and the advertisement must not be the FIRST line, which
  ;; the client drops as flavour text.
  (tls-case "starttls" PORT-STARTTLS "starttls" #t #f))

(test-case "MAIL-9: implicit TLS really connects, with the wrap before the 220"
  (tls-case "implicit tls" PORT-TLS "tls" #f #t))


;; ---- MAIL-26…31: the relay's certificate ---------------------------------------
;;
;; THE TWO CASES ABOVE ESTABLISH THAT THE HANDSHAKE HAPPENS. These establish what
;; it is worth, which until this slice was less than it looked: `net/smtp` passes
;; no `#:context`, so the default client context answered and that one accepts a
;; self-signed certificate — the two cases above pass against a certificate this
;; file generates for itself, which is exactly the point.
;;
;; `verify_tls` is OFF by default (MAIL-26), so the first thing asserted is that
;; the shipped posture is unchanged; everything after it is what the switch buys.

(define PORT-VERIFY 8952)

;; THE NAME IS AN ARGUMENT, not a `getenv` with a literal in it — which is what
;; ENVN-2's gate refuses and what this file's first version wrote. The gate's
;; rule is about the READ (`(getenv "TMACH_…")`), so passing the name to a helper
;; that reads it through a variable is the sanctioned shape and is exactly what
;; `content-encryption-tests` does with `TMACH_SECRET_KEY`. Composing it out of
;; pieces to slip past the pattern would be evading the gate rather than
;; satisfying it, which is the opposite of what every fix to that gate has done.
(define CA-BUNDLE-VAR "TMACH_MAIL_CA_BUNDLE")

;; `content-encryption-tests`' shape, and it has to restore even when a check
;; raises — a leaked bundle would make every later case in this file verify
;; against a trust store it did not ask for.
(define (with-env name value thunk)
  (define saved (getenv name))
  (dynamic-wind (lambda () (putenv name value))
                thunk
                (lambda () (putenv name (or saved "")))))

;; A SAN, because `/CN=127.0.0.1` IS NOT ENOUGH and the difference is invisible
;; until something verifies. OpenSSL's hostname check reads subjectAltName and an
;; IP must be there as `IP:`; a CN carrying an address has been deprecated for
;; years and `X509_check_ip` does not consult it. So the certificate the other
;; cases use — correct for them, since nothing checks a name — cannot be reused
;; here, and a test that reused it would report a NAME failure as a chain failure.
(define (self-signed/san!)
  (define ssl (find-executable-path "openssl"))
  (cond
    [(not ssl) #f]
    [else
     (define d (build-path (find-system-path 'temp-dir)
                           (format "tmach-mailverify-~a" (current-inexact-milliseconds))))
     (make-directory* d)
     (define key (build-path d "k.pem"))
     (define crt (build-path d "c.pem"))
     (define code
       (parameterize ([current-output-port (open-output-nowhere)]
                      [current-error-port (open-output-nowhere)])
         (system*/exit-code ssl "req" "-x509" "-newkey" "rsa:2048" "-nodes"
                            "-keyout" (path->string key) "-out" (path->string crt)
                            "-days" "1" "-subj" "/CN=127.0.0.1"
                            "-addext" "subjectAltName = IP:127.0.0.1")))
     (and (zero? code) (file-exists? crt) (file-exists? key) (cons crt key))]))

;; One shape for all four, because what differs between them is three arguments
;; and the expected answer — and writing them out four times is how two of them
;; end up asserting subtly different things about the same switch.
(define (verify-case label #:host host #:verify verify #:bundle bundle #:expect expect)
  (define pair (self-signed/san!))
  (cond
    [(not pair)
     (printf "mail-tests: SKIPPED ~a — no openssl on PATH, so the verification branch went unexercised\n" label)]
    [else
     (define c (fresh))
     (mock-clear!)
     ;; THE NAME IS PASSED AS A VALUE, never written as a literal `getenv` —
     ;; ENVN-2's gate fails on the literal, and it failed on the first version of
     ;; this helper. `content-encryption-tests`' `with-env` is the shape.
     (with-env CA-BUNDLE-VAR
       (if (eq? bundle 'cert) (path->string (car pair)) (or bundle ""))
       (lambda ()
        (parameterize ([mock-tls-encode (accept-encoder (car pair) (cdr pair))])
          (start-mock-smtp! #:port PORT-VERIFY #:starttls? #t #:tls? #f)
          (configure! c #:port PORT-VERIFY #:security "starttls" #:host host #:verify verify)
          (define-values (ok? err) (mail-send-test! c "tls@example.test"))
          (stop-mock-smtp!)
          (cond
            [(eq? expect 'delivered)
             (check-true ok? (format "~a: expected delivery, got: ~a" label err))
             (check-true (mock-msg? (mock-last-message))
                         (format "~a: a whole message crossed the verified connection" label))]
            [else
             (check-false ok? (format "~a: expected a refusal and the message was delivered" label))
             (check-true (string? err) (format "~a: the refusal says something" label))
             ;; IT NAMES THE SWITCH THAT ASKED (MAIL-31). openssl's own text is
             ;; identical for an untrusted issuer and for a name that does not
             ;; match, and says nothing about `verify_tls` — so an operator who
             ;; has just turned it on would read it as the relay having broken.
             (check-true (regexp-match? #px"verify_tls" err)
                         (format "~a: the refusal names the switch, not only openssl: ~a" label err))
             (check-true (string-contains? err CA-BUNDLE-VAR)
                         (format "~a: …and the way out" label))]))))
     (close-db! c)]))

(test-case "MAIL-26: the shipped default does not verify, and that is the posture an upgrade keeps"
  ;; THE DEFAULT IS ASSERTED AT THE ROW, not inferred from a delivery: a
  ;; transport written with no `verify_tls` at all must read back `false`, or the
  ;; migration's DEFAULT 0 is doing something other than what it says and every
  ;; existing instance's posture would have changed under it.
  (define c (fresh))
  (transport-set! c (hasheq 'host "127.0.0.1" 'port 2525 'security "starttls"
                            'from_address "tmach@example.test"))
  (check-false (hash-ref (transport-ref c) 'verify_tls)
               "an upgrade must not start verifying on its own")
  ;; and it is REPORTED, which is what makes a default of `false` honest rather
  ;; than quiet — an operator can see the posture without reading the module.
  (check-true (hash-has-key? (transport-ref c) 'verify_tls))
  (close-db! c))

(test-case "MAIL-28: verification with no TLS is refused, not stored inert"
  (define c (fresh))
  (check-exn exn:fail?
             (lambda ()
               (transport-set! c (hasheq 'host "127.0.0.1" 'port 2525 'security "none"
                                         'from_address "tmach@example.test"
                                         'verify_tls #t)))
             "a setting that silently does nothing is how an operator concludes the feature is broken")
  ;; and the refusal names the way out rather than only the mistake
  (check-true (regexp-match? #px"starttls|tls"
                             (transport-problem (hasheq 'host "127.0.0.1" 'port 2525
                                                        'security "none"
                                                        'from_address "a@b.test"
                                                        'verify_tls #t))))
  (close-db! c))

(test-case "MAIL-26: with verification OFF a self-signed relay is accepted, exactly as before"
  (verify-case "verify off" #:host "127.0.0.1" #:verify #f #:bundle #f #:expect 'delivered))

(test-case "MAIL-26: with verification ON and nothing trusting it, the same relay is refused"
  ;; The pair that makes the switch mean something: same certificate, same mock,
  ;; same session — only the switch moved.
  (verify-case "verify on, untrusted" #:host "127.0.0.1" #:verify #t #:bundle #f #:expect 'refused))

(test-case "MAIL-29: the CA bundle is what makes verification usable rather than merely stricter"
  ;; The internal-relay case this feature would otherwise refuse outright, and
  ;; the reason the knob exists at all: an operator with a private CA gets
  ;; verification against it instead of a choice between no TLS checking and no
  ;; mail.
  (verify-case "verify on, bundle trusts it" #:host "127.0.0.1" #:verify #t
               #:bundle 'cert #:expect 'delivered))

(test-case "MAIL-30: the NAME is checked too, and this is the case chain-only verification would pass"
  ;; THE POSITIVE CONTROL FOR HOSTNAME VERIFICATION. The bundle trusts this exact
  ;; certificate, so the chain verifies; its SAN is `IP:127.0.0.1` and the
  ;; configured host is `localhost`, which resolves to the same socket. A build
  ;; that verified the chain and not the name delivers here and reads in a
  ;; console exactly like one that checks both — which is why `verify_tls` means
  ;; both or it means nothing.
  ;; THE CONTROL IS THE SAME HOST WITH THE SWITCH OFF, and without it this case
  ;; would pass against a build where `localhost` simply does not reach the mock
  ;; — a connection failure and a name failure are one answer from the outside,
  ;; because openssl's message is the same for both and a refused socket is a
  ;; refusal too. So: `localhost` delivers with verification off, and refuses
  ;; with it on. Only the switch moved.
  (verify-case "wrong name, verification off" #:host "localhost" #:verify #f
               #:bundle 'cert #:expect 'delivered)
  (verify-case "verify on, wrong name" #:host "localhost" #:verify #t
               #:bundle 'cert #:expect 'refused))

(test-case "MAIL-31: a certificate refusal is PERMANENT, so it is not retried on the whole curve"
  ;; Ten identical handshake failures against a certificate that will never
  ;; verify is what the 5xx/4xx split exists to avoid, and a verification
  ;; failure carries no SMTP code at all — so without its own clause it reads as
  ;; transient. Asserted on the STRUCT rather than through the delivery sweep,
  ;; because `permanent?` is what the sweep branches on and it is the property,
  ;; not the number of attempts somebody counted.
  (define pair (self-signed/san!))
  (cond
    [(not pair)
     (printf "mail-tests: SKIPPED the permanence case — no openssl on PATH\n")]
    [else
     (mock-clear!)
     (with-env CA-BUNDLE-VAR ""
       (lambda ()
         (parameterize ([mock-tls-encode (accept-encoder (car pair) (cdr pair))])
           (start-mock-smtp! #:port PORT-VERIFY #:starttls? #t #:tls? #f)
           (define t (hasheq 'host "127.0.0.1" 'port PORT-VERIFY 'security "starttls"
                             'username 'null 'from_address "a@b.test" 'from_name 'null
                             'verify_tls #t))
           (define e
             (with-handlers ([exn:fail:mail? values])
               (smtp-deliver! t "to@b.test" "s" "b")
               #f))
           (stop-mock-smtp!)
           (check-true (exn:fail:mail? e) "the refusal is this subsystem's own, not a bare exn")
           (check-true (exn:fail:mail-permanent? e)
                       "a certificate that will never verify must not be retried ten times"))))]))
