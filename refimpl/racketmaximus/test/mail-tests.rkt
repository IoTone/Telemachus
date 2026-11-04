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
         (only-in "../domain/repo/blobs.rkt" current-blob-root)
         (only-in racket/file make-directory*)
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
                    #:active [active #t] #:security [sec "none"])
  (transport-set! c (hasheq 'host "127.0.0.1" 'port port 'security sec
                            'from_address "tmach@example.test" 'from_name "TMach"
                            'base_url base 'active active)))

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
