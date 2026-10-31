#lang racket/base

;; test/inbox-tests.rkt — the inbox plugin (plugins/inbox).
;;
;; THE TABLES ARE CREATED FROM THE PLUGIN'S OWN `migrations` LIST, not from DDL
;; copied here: a test that declared its own schema would agree with any change to
;; the plugin's. The suite runs on either dialect, like the platform's own:
;;
;;   raco test test/inbox-tests.rkt                                  # SQLite
;;   DATABASE_URL=postgres://u@host:5432/db raco test test/inbox-tests.rkt

(require rackunit racket/list racket/string racket/path racket/runtime-path
         db-kit/portable db-kit/migrate
         "../domain/db/migrations.rkt"
         "db-fixture.rkt"
         "../domain/authz/authz.rkt"
         (only-in "../domain/authz/permissions.rkt" permission-doc)
         (only-in "../domain/agent/plugins.rkt" load-plugins! loaded-plugins plugin-failures
                  check-migrations! plugin-table-prefix)
         (only-in "../domain/agent/registry.rkt" tool-by-name tool-perm tool-source)
         "../plugins/inbox/main.rkt")

(define-runtime-path PLUGINS-DIR "../plugins")

(define (fresh)
  (define c (fresh-db #:migrate? #f))
  (migrate! c all-migrations)
  ;; the plugin's own DDL, exactly as the loader applies it
  (migrate! c (check-migrations! "inbox" migrations))
  c)

(define (setup)
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "root"))
  (values c (user-principal c uid tid) uid tid))

;; a second team with its own member, to prove nothing crosses
(define (other-team c)
  (define uid (create-user! c #:username "other"))
  (define tid (create-team! c #:name "Other" #:slug "other"))
  (add-member! c #:user uid #:team tid #:role "member")
  (user-principal c uid tid))

(define T0 1000000)

(define (raise! c p key #:source [source "mon"] #:title [title "Disk is full"] #:now [now T0]
                #:severity [severity "normal"] #:kind [kind #f] #:scope [scope #f] #:body [body #f]
                #:url [url #f] #:data [data #f] #:revision [revision #f])
  (inbox-ingest! c p #:source source #:key key #:title title #:now now #:severity severity
                 #:kind kind #:scope scope #:body body #:url url #:data data #:revision revision))

(define (state-of c p id #:now [now T0]) (hash-ref (inbox-get c p id #:now now) 'state))
(define (outcome r) (hash-ref r 'outcome))
(define (item r) (hash-ref r 'item))
(define (id-of r) (hash-ref (item r) 'id))
(define (ids rows) (map (lambda (r) (hash-ref r 'key)) rows))

(define (user-error-message thunk)
  (with-handlers ([exn:fail:user? exn-message]) (thunk) #f))

;; ---- 1. the closed vocabulary and the lifecycle, pinned ---------------------------
;; PINNED, not re-derived: the point of a closed vocabulary is that adding a member
;; is a decision somebody makes on purpose.
(test-case "the severities and the states are closed, pinned vocabularies"
  (check-equal? SEVERITIES '("critical" "high" "normal" "low"))
  (check-equal? STATES '("open" "acknowledged" "snoozed" "suppressed" "resolved"))
  (check-equal? LIVE-STATES '("open" "acknowledged" "snoozed" "suppressed")))

(test-case "the transition table is the lifecycle, and every row of it is pinned"
  (define (row a) (hash-ref TRANSITIONS a))
  (check-equal? (row "ack") (cons '("open") "acknowledged"))
  (check-equal? (row "snooze") (cons '("open" "acknowledged" "snoozed") "snoozed"))
  (check-equal? (row "suppress") (cons '("open" "acknowledged" "snoozed") "suppressed"))
  (check-equal? (row "reopen") (cons '("acknowledged" "snoozed" "suppressed") "open"))
  (check-equal? (row "resolve") (cons LIVE-STATES "resolved"))
  (check-equal? (sort (hash-keys TRANSITIONS) string<?) '("ack" "reopen" "resolve" "snooze" "suppress")))

(test-case "what a screen may offer is read from the same table"
  (check-equal? (allowed-actions "open") '("ack" "snooze" "suppress" "resolve"))
  (check-equal? (allowed-actions "acknowledged") '("snooze" "suppress" "reopen" "resolve"))
  (check-equal? (allowed-actions "snoozed") '("snooze" "suppress" "reopen" "resolve"))
  (check-equal? (allowed-actions "suppressed") '("reopen" "resolve"))
  (check-equal? (allowed-actions "resolved") '() "resolved is terminal: nothing is offered"))

;; ---- 2. the schema ----------------------------------------------------------------
(test-case "every table and index the plugin creates carries its own prefix"
  (check-equal? (plugin-table-prefix "inbox") "x_inbox_")
  (check-equal? (map migration-id (check-migrations! "inbox" migrations)) '("x.inbox.init")))

(test-case "the schema refuses a second live row for one (source, key), and allows one after a resolve"
  (define-values (c p uid tid) (setup))
  (define a (raise! c p "k1"))
  (check-exn exn:fail:sql?
             (lambda ()
               (query-exec c (string-append "INSERT INTO x_inbox_items (id, team_id, source, item_key, severity,"
                                            " severity_rank, state, title, occurrence, seen_count,"
                                            " first_seen_epoch, last_seen_epoch, updated_epoch)"
                                            " VALUES ('dup', ?, 'mon', 'k1', 'low', 1, 'open', 't', 1, 1, 1, 1, 1)")
                           tid))
             "the partial unique index is the dedupe rule, so two writers cannot both win")
  (inbox-act! c p (id-of a) "resolve" #:now T0)
  (check-equal? (outcome (raise! c p "k1" #:now (+ T0 5))) "reopened"))

;; ---- 3. ingest ---------------------------------------------------------------------
(test-case "raising an item creates it open, with the defaults a producer need not say"
  (define-values (c p uid tid) (setup))
  (define r (raise! c p "disk:/var"))
  (check-equal? (outcome r) "created")
  (define i (item r))
  (check-equal? (hash-ref i 'state) "open")
  (check-equal? (hash-ref i 'severity) "normal")
  (check-equal? (hash-ref i 'occurrence) 1)
  (check-equal? (hash-ref i 'seen_count) 1)
  (check-equal? (hash-ref i 'first_seen) T0)
  (check-equal? (hash-ref i 'scope) 'null)
  (check-equal? (hash-ref i 'allowed_actions) '("ack" "snooze" "suppress" "resolve")))

(test-case "raising the same item again is idempotent: one row, evidence moved, nothing else"
  (define-values (c p uid tid) (setup))
  (define a (raise! c p "k" #:revision "r1" #:severity "high"))
  (define b (raise! c p "k" #:revision "r1" #:severity "high" #:now (+ T0 60)))
  (check-equal? (outcome b) "refreshed")
  (check-equal? (id-of a) (id-of b))
  (check-equal? (hash-ref (item b) 'seen_count) 2)
  (check-equal? (hash-ref (item b) 'last_seen) (+ T0 60))
  (check-equal? (hash-ref (item b) 'first_seen) T0 "first seen does not move")
  (check-equal? (query-value c "SELECT COUNT(*) FROM x_inbox_items") 1))

(test-case "a refresh ignores changed content, because only a new revision is material"
  (define-values (c p uid tid) (setup))
  (define a (raise! c p "k" #:revision "r1" #:title "first"))
  (define b (raise! c p "k" #:revision "r1" #:title "reworded" #:now (+ T0 1)))
  (check-equal? (outcome b) "refreshed")
  (check-equal? (hash-ref (item b) 'title) "first"))

(test-case "a refresh does not disturb an acknowledgement"
  (define-values (c p uid tid) (setup))
  (define a (raise! c p "k" #:revision "r1"))
  (inbox-act! c p (id-of a) "ack" #:note "on it" #:now (+ T0 10))
  (define b (raise! c p "k" #:revision "r1" #:now (+ T0 20)))
  (check-equal? (outcome b) "refreshed")
  (check-equal? (hash-ref (item b) 'state) "acknowledged")
  (check-equal? (hash-ref (item b) 'ack_note) "on it"))

(test-case "a new revision replaces the content and sends an acknowledged item back to open"
  (define-values (c p uid tid) (setup))
  (define a (raise! c p "k" #:revision "r1" #:severity "normal"))
  (inbox-act! c p (id-of a) "ack" #:note "seen" #:now (+ T0 10))
  (define b (raise! c p "k" #:revision "r2" #:severity "critical" #:title "now worse" #:now (+ T0 20)))
  (check-equal? (outcome b) "resurfaced")
  (define i (item b))
  (check-equal? (hash-ref i 'state) "open")
  (check-equal? (hash-ref i 'title) "now worse")
  (check-equal? (hash-ref i 'severity) "critical")
  (check-equal? (hash-ref i 'revision) "r2")
  (check-equal? (hash-ref i 'ack_by) 'null "the acknowledgement answered the old fact")
  (check-equal? (hash-ref i 'ack_note) 'null))

(test-case "a new revision wakes a snoozed item, and leaves an open one open"
  (define-values (c p uid tid) (setup))
  (define a (raise! c p "k" #:revision "r1"))
  (inbox-act! c p (id-of a) "snooze" #:until (+ T0 3600) #:now T0)
  (check-equal? (outcome (raise! c p "k" #:revision "r2" #:now (+ T0 5))) "resurfaced")
  (check-equal? (state-of c p (id-of a) ) "open")
  (check-equal? (outcome (raise! c p "k" #:revision "r3" #:now (+ T0 6))) "revised"
                "an open item is not resurfaced, there is nothing to resurface from"))

(test-case "a suppressed item takes new content and stays suppressed"
  (define-values (c p uid tid) (setup))
  (define a (raise! c p "k" #:revision "r1"))
  (inbox-act! c p (id-of a) "suppress" #:now (+ T0 1))
  (define b (raise! c p "k" #:revision "r2" #:title "changed" #:now (+ T0 2)))
  (check-equal? (outcome b) "revised")
  (check-equal? (hash-ref (item b) 'state) "suppressed")
  (check-equal? (hash-ref (item b) 'title) "changed"))

(test-case "a key that was resolved opens a NEW row with the next occurrence"
  (define-values (c p uid tid) (setup))
  (define a (raise! c p "k"))
  (inbox-act! c p (id-of a) "resolve" #:note "fixed" #:now (+ T0 5))
  (define b (raise! c p "k" #:now (+ T0 99)))
  (check-equal? (outcome b) "reopened")
  (check-not-equal? (id-of a) (id-of b))
  (check-equal? (hash-ref (item b) 'occurrence) 2)
  (check-equal? (state-of c p (id-of a)) "resolved" "the old row's history stays what it was")
  (check-equal? (hash-ref (inbox-get c p (id-of a)) 'resolve_note) "fixed"))

(test-case "ingest refuses what it cannot store, naming the problem"
  (define-values (c p uid tid) (setup))
  (define msg
    (make-keyword-procedure
     (lambda (kws vals)
       (user-error-message (lambda () (keyword-apply inbox-ingest! kws vals (list c p)))))))
  (check-regexp-match #rx"source is required" (msg #:source "" #:key "k" #:title "t"))
  (check-regexp-match #rx"key is required" (msg #:source "s" #:key #f #:title "t"))
  (check-regexp-match #rx"title is required" (msg #:source "s" #:key "k" #:title "  "))
  (check-regexp-match #rx"not a severity this inbox has" (msg #:source "s" #:key "k" #:title "t" #:severity "urgent"))
  (check-regexp-match #rx"title is longer than 200" (msg #:source "s" #:key "k" #:title (make-string 201 #\a)))
  (check-regexp-match #rx"url must be an http or https" (msg #:source "s" #:key "k" #:title "t" #:url "javascript:alert(1)"))
  (check-regexp-match #rx"data must be a JSON object" (msg #:source "s" #:key "k" #:title "t" #:data "text"))
  (check-regexp-match #rx"data is larger than" (msg #:source "s" #:key "k" #:title "t"
                                                    #:data (hasheq 'x (make-string 9000 #\a))))
  (check-equal? (query-value c "SELECT COUNT(*) FROM x_inbox_items") 0 "nothing half-written"))

(test-case "data round-trips as an object, and a numeric revision is stored as text"
  (define-values (c p uid tid) (setup))
  (define r (raise! c p "k" #:data (hasheq 'host "db1" 'n 3) #:revision 7 #:url "https://example.test/x"))
  (check-equal? (hash-ref (item r) 'data) (hasheq 'host "db1" 'n 3))
  (check-equal? (hash-ref (item r) 'revision) "7")
  (check-equal? (hash-ref (item r) 'url) "https://example.test/x"))

;; ---- 4. acting ---------------------------------------------------------------------
(test-case "acknowledging records who, when and why, and is idempotent"
  (define-values (c p uid tid) (setup))
  (define id (id-of (raise! c p "k")))
  (define r (inbox-act! c p id "ack" #:note "looking now" #:now (+ T0 30)))
  (check-true (hash-ref r 'changed))
  (define i (hash-ref r 'item))
  (check-equal? (hash-ref i 'state) "acknowledged")
  (check-equal? (hash-ref i 'ack_by) uid)
  (check-equal? (hash-ref i 'ack_at) (+ T0 30))
  (check-equal? (hash-ref i 'ack_note) "looking now")
  (define again (inbox-act! c p id "ack" #:note "double click" #:now (+ T0 31)))
  (check-false (hash-ref again 'changed) "asking for the state it is in changes nothing")
  (check-equal? (hash-ref (hash-ref again 'item) 'ack_note) "looking now")
  (check-equal? (length (hash-ref (inbox-get c p id) 'events)) 2 "created, acked, and no third event"))

(test-case "an act the lifecycle does not allow is refused with what is allowed"
  (define-values (c p uid tid) (setup))
  (define id (id-of (raise! c p "k")))
  (inbox-act! c p id "suppress" #:now T0)
  (check-regexp-match #rx"an item that is suppressed cannot be acknowledged \\(it can: reopen, resolve\\)"
                      (user-error-message (lambda () (inbox-act! c p id "ack"))))
  (inbox-act! c p id "resolve" #:now T0)
  (check-regexp-match #rx"cannot be reopened \\(it can: nothing, it is resolved\\)"
                      (user-error-message (lambda () (inbox-act! c p id "reopen"))))
  (check-regexp-match #rx"not an act this inbox has"
                      (user-error-message (lambda () (inbox-act! c p id "delete")))))

(test-case "resolving is terminal and idempotent"
  (define-values (c p uid tid) (setup))
  (define id (id-of (raise! c p "k")))
  (define r (inbox-act! c p id "resolve" #:note "done" #:now (+ T0 9)))
  (check-equal? (hash-ref (hash-ref r 'item) 'resolved_by) uid)
  (check-equal? (hash-ref (hash-ref r 'item) 'resolved_at) (+ T0 9))
  (check-false (hash-ref (inbox-act! c p id "resolve" #:now (+ T0 10)) 'changed)))

(test-case "a snooze needs a future time within the bound, and says what to use for longer"
  (define-values (c p uid tid) (setup))
  (define id (id-of (raise! c p "k")))
  (define (snooze until) (user-error-message (lambda () (inbox-act! c p id "snooze" #:until until #:now T0))))
  (check-regexp-match #rx"until is required" (snooze #f))
  (check-regexp-match #rx"until must be in the future" (snooze T0))
  (check-regexp-match #rx"until must be in the future" (snooze (- T0 5)))
  (check-regexp-match #rx"at most 90 days; use suppress" (snooze (+ T0 MAX-SNOOZE-SECONDS 1)))
  (check-false (snooze (+ T0 MAX-SNOOZE-SECONDS)) "exactly the bound is allowed")
  (check-equal? (state-of c p id) "snoozed"))

(test-case "re-snoozing moves the time, and snoozing to the same instant changes nothing"
  (define-values (c p uid tid) (setup))
  (define id (id-of (raise! c p "k")))
  (check-true (hash-ref (inbox-act! c p id "snooze" #:until (+ T0 100) #:now T0) 'changed))
  (check-false (hash-ref (inbox-act! c p id "snooze" #:until (+ T0 100) #:now T0) 'changed))
  (check-true (hash-ref (inbox-act! c p id "snooze" #:until (+ T0 500) #:now T0) 'changed))
  (check-equal? (hash-ref (inbox-get c p id #:now T0) 'snooze_until) (+ T0 500)))

(test-case "a snooze that has run out reads as open, and the wake is in the event log"
  (define-values (c p uid tid) (setup))
  (define id (id-of (raise! c p "k")))
  (inbox-act! c p id "snooze" #:until (+ T0 100) #:now T0)
  (check-equal? (map (lambda (r) (hash-ref r 'state)) (inbox-list c p #:states '("snoozed") #:now (+ T0 99)))
                '("snoozed") "not yet")
  (check-equal? (ids (inbox-list c p #:now (+ T0 99))) '() "a snoozed item is not in the default list")
  (check-equal? (ids (inbox-list c p #:now (+ T0 100))) '("k") "the instant it expires, a read finds it open")
  (define events (hash-ref (inbox-get c p id #:now (+ T0 101)) 'events))
  (check-equal? (map (lambda (e) (hash-ref e 'kind)) events) '("created" "snooze" "woke"))
  (check-equal? (hash-ref (last events) 'actor_type) "system"))

(test-case "waking is idempotent and counts only what it moved, for the team it is asked about"
  (define-values (c p uid tid) (setup))
  (define q (other-team c))
  (define a (id-of (raise! c p "k")))
  (define b (id-of (raise! c q "k")))
  (inbox-act! c p a "snooze" #:until (+ T0 10) #:now T0)
  (inbox-act! c q b "snooze" #:until (+ T0 10) #:now T0)
  (check-equal? (inbox-wake! c tid #:now (+ T0 11)) 1)
  (check-equal? (inbox-wake! c tid #:now (+ T0 11)) 0)
  (check-equal? (state-of c q b) "snoozed" "the other team's snooze was not touched")
  (check-equal? (length (hash-ref (inbox-get c p a) 'events)) 3 "no second wake event"))

(test-case "reopening clears the acknowledgement, and the event log still says who and when"
  (define-values (c p uid tid) (setup))
  (define id (id-of (raise! c p "k")))
  (inbox-act! c p id "ack" #:note "mine" #:now (+ T0 5))
  (define r (inbox-act! c p id "reopen" #:now (+ T0 9)))
  (check-equal? (hash-ref (hash-ref r 'item) 'state) "open")
  (check-equal? (hash-ref (hash-ref r 'item) 'ack_by) 'null)
  (define ack-event (findf (lambda (e) (equal? (hash-ref e 'kind) "ack")) (hash-ref (inbox-get c p id) 'events)))
  (check-equal? (hash-ref ack-event 'actor_id) uid)
  (check-equal? (hash-ref ack-event 'at) (+ T0 5))
  (check-equal? (hash-ref (hash-ref ack-event 'data) 'note) "mine"))

(test-case "events are numbered in order, one sequence per item"
  (define-values (c p uid tid) (setup))
  (define a (id-of (raise! c p "a")))
  (define b (id-of (raise! c p "b")))
  (inbox-act! c p a "ack" #:now T0)
  (inbox-act! c p b "resolve" #:now T0)
  (inbox-act! c p a "resolve" #:now T0)
  (check-equal? (map (lambda (e) (hash-ref e 'seq)) (hash-ref (inbox-get c p a) 'events)) '(1 2 3))
  (check-equal? (map (lambda (e) (hash-ref e 'kind)) (hash-ref (inbox-get c p a) 'events))
                '("created" "ack" "resolve"))
  (check-equal? (map (lambda (e) (hash-ref e 'seq)) (hash-ref (inbox-get c p b) 'events)) '(1 2)))

(test-case "a transition is audited and a refresh is not"
  (define-values (c p uid tid) (setup))
  (define before (query-value c "SELECT COUNT(*) FROM audit_log WHERE action LIKE 'inbox.item.%'"))
  (define id (id-of (raise! c p "k" #:revision "r1")))
  (raise! c p "k" #:revision "r1" #:now (+ T0 1))
  (raise! c p "k" #:revision "r1" #:now (+ T0 2))
  (inbox-act! c p id "ack" #:now (+ T0 3))
  (check-equal? (- (query-value c "SELECT COUNT(*) FROM audit_log WHERE action LIKE 'inbox.item.%'") before) 2
                "created and ack; the two refreshes wrote nothing"))

;; ---- 5. teams do not cross ---------------------------------------------------------
(test-case "the same (source, key) in two teams is two items, and neither sees the other"
  (define-values (c p uid tid) (setup))
  (define q (other-team c))
  (define a (raise! c p "k" #:title "ours"))
  (define b (raise! c q "k" #:title "theirs"))
  (check-equal? (outcome a) "created")
  (check-equal? (outcome b) "created" "the dedupe rule is per team")
  (check-equal? (map (lambda (r) (hash-ref r 'title)) (inbox-list c p)) '("ours"))
  (check-equal? (map (lambda (r) (hash-ref r 'title)) (inbox-list c q)) '("theirs")))

(test-case "another team's id answers exactly as a missing one, for read and for every act"
  (define-values (c p uid tid) (setup))
  (define q (other-team c))
  (define theirs (id-of (raise! c q "k")))
  (define missing "00000000-0000-4000-8000-000000000000")
  (define (msg thunk) (user-error-message thunk))
  (check-regexp-match (regexp (string-append "no such item: " theirs)) (msg (lambda () (inbox-get c p theirs))))
  (check-regexp-match #rx"no such item" (msg (lambda () (inbox-get c p missing))))
  (for ([a (in-list '("ack" "suppress" "reopen" "resolve"))])
    (check-regexp-match #rx"no such item" (msg (lambda () (inbox-act! c p theirs a)))))
  (check-regexp-match #rx"no such item" (msg (lambda () (inbox-act! c p theirs "snooze" #:until (+ (current-seconds) 60)))))
  (check-equal? (state-of c q theirs) "open" "nothing the first team did reached it"))

;; ---- 6. reading: filters, order, scope, digest -------------------------------------
(define (seed! c p)
  ;; first_seen differs, so the order inside a severity is observable
  (raise! c p "low-old"   #:severity "low"      #:scope "org:a/sku:1" #:source "watch" #:kind "market"   #:now 100)
  (raise! c p "crit-new"  #:severity "critical" #:scope "org:a/sku:2" #:source "mon"   #:kind "infra"    #:now 300)
  (raise! c p "crit-old"  #:severity "critical" #:scope "org:a"       #:source "mon"   #:kind "infra"    #:now 200)
  (raise! c p "norm"      #:severity "normal"   #:scope "org:b"       #:source "watch" #:kind "market"   #:now 150)
  (raise! c p "noscope"   #:severity "high"                            #:source "mon"                     #:now 120))

(test-case "the list is most severe first, then longest waiting"
  (define-values (c p uid tid) (setup))
  (seed! c p)
  (check-equal? (ids (inbox-list c p #:now 400))
                '("crit-old" "crit-new" "noscope" "norm" "low-old")))

(test-case "filters narrow by severity, source and kind, and combine"
  (define-values (c p uid tid) (setup))
  (seed! c p)
  (check-equal? (ids (inbox-list c p #:severity "critical" #:now 400)) '("crit-old" "crit-new"))
  (check-equal? (ids (inbox-list c p #:source "watch" #:now 400)) '("norm" "low-old"))
  (check-equal? (ids (inbox-list c p #:kind "market" #:severity "low" #:now 400)) '("low-old"))
  (check-regexp-match #rx"not a severity" (user-error-message (lambda () (inbox-list c p #:severity "bad")))))

(test-case "scope is an exact label, and scope_prefix is a subtree"
  (define-values (c p uid tid) (setup))
  (seed! c p)
  (check-equal? (ids (inbox-list c p #:scope "org:a" #:now 400)) '("crit-old"))
  (check-equal? (ids (inbox-list c p #:scope-prefix "org:a" #:now 400)) '("crit-old" "crit-new" "low-old"))
  (check-equal? (ids (inbox-list c p #:scope-prefix "org:a/" #:now 400)) '("crit-new" "low-old"))
  (check-equal? (ids (inbox-list c p #:scope-prefix "nothing" #:now 400)) '())
  (check-regexp-match #rx"not both" (user-error-message (lambda () (inbox-list c p #:scope "a" #:scope-prefix "a")))))

(test-case "a prefix is a prefix and never a pattern: % and _ match themselves"
  (define-values (c p uid tid) (setup))
  (raise! c p "pct" #:scope "100%done")
  (raise! c p "under" #:scope "a_b")
  (raise! c p "other" #:scope "aXb")
  (check-equal? (ids (inbox-list c p #:scope-prefix "100%")) '("pct"))
  (check-equal? (ids (inbox-list c p #:scope-prefix "a_")) '("under") "a LIKE would also have matched aXb")
  (check-equal? (ids (inbox-list c p #:scope-prefix "%")) '() "a bare percent is not a wildcard"))

(test-case "the default list is the two states that need a person, and state= widens it"
  (define-values (c p uid tid) (setup))
  (define a (id-of (raise! c p "open1" #:now 10)))
  (define b (id-of (raise! c p "acked" #:now 11)))
  (define s (id-of (raise! c p "supp" #:now 12)))
  (define r (id-of (raise! c p "done" #:now 13)))
  (inbox-act! c p b "ack" #:now 20)
  (inbox-act! c p s "suppress" #:now 20)
  (inbox-act! c p r "resolve" #:now 20)
  (check-equal? (sort (ids (inbox-list c p #:now 30)) string<?) '("acked" "open1"))
  (check-equal? (sort (ids (inbox-list c p #:states STATES #:now 30)) string<?) '("acked" "done" "open1" "supp"))
  (check-equal? (ids (inbox-list c p #:states '("resolved") #:now 30)) '("done")))

(test-case "limit is clamped and offset pages without overlap"
  (define-values (c p uid tid) (setup))
  (for ([i (in-range 7)]) (raise! c p (format "k~a" i) #:now (+ 100 i)))
  (check-equal? (length (inbox-list c p #:limit 100000)) 7)
  (check-equal? (length (inbox-list c p #:limit 0)) 1 "a limit below one is one, never a refusal")
  (define page1 (ids (inbox-list c p #:limit 3 #:offset 0)))
  (define page2 (ids (inbox-list c p #:limit 3 #:offset 3)))
  (check-equal? (length (remove-duplicates (append page1 page2))) 6))

(test-case "the digest counts by state, severity and scope, and ignores resolved items"
  (define-values (c p uid tid) (setup))
  (seed! c p)
  (define crit-new (hash-ref (car (filter (lambda (r) (equal? (hash-ref r 'key) "crit-new")) (inbox-list c p #:now 400))) 'id))
  (inbox-act! c p crit-new "ack" #:now 310)
  (define extra (id-of (raise! c p "gone" #:now 50)))
  (inbox-act! c p extra "resolve" #:now 60)
  (define d (inbox-digest c p #:now 1000))
  (check-equal? (hash-ref d 'needs_attention) 4)
  (check-equal? (hash-ref d 'states) (hasheq 'open 4 'acknowledged 1 'snoozed 0 'suppressed 0))
  (check-equal? (hash-ref d 'open_by_severity) (hasheq 'critical 1 'high 1 'normal 1 'low 1))
  (check-equal? (hash-ref d 'oldest_open_age_seconds) 900 "low-old arrived at 100, now is 1000")
  (check-equal? (ids (hash-ref d 'top)) '("crit-old" "noscope" "norm" "low-old") "open items only, most severe first")
  (check-equal? (hash-ref d 'scope) 'null))

(test-case "the digest for a scope counts only that scope, and a subtree counts the subtree"
  (define-values (c p uid tid) (setup))
  (seed! c p)
  (define exact (inbox-digest c p #:scope "org:a" #:now 1000))
  (check-equal? (hash-ref exact 'needs_attention) 1)
  (check-equal? (hash-ref exact 'scope) "org:a")
  (check-equal? (ids (hash-ref exact 'top)) '("crit-old"))
  (define tree (inbox-digest c p #:scope-prefix "org:a" #:now 1000))
  (check-equal? (hash-ref tree 'needs_attention) 3)
  (check-equal? (hash-ref tree 'open_by_severity) (hasheq 'critical 2 'high 0 'normal 0 'low 1))
  (define none (inbox-digest c p #:scope "org:zzz" #:now 1000))
  (check-equal? (hash-ref none 'needs_attention) 0)
  (check-equal? (hash-ref none 'oldest_open_age_seconds) 'null "no open item, so no age, not zero")
  (check-equal? (hash-ref none 'top) '()))

(test-case "the digest is per team, and top is bounded"
  (define-values (c p uid tid) (setup))
  (define q (other-team c))
  (seed! c p)
  (check-equal? (hash-ref (inbox-digest c q #:now 1000) 'needs_attention) 0)
  (check-equal? (length (hash-ref (inbox-digest c p #:top 2 #:now 1000) 'top)) 2)
  (check-equal? (hash-ref (inbox-digest c p #:top 0 #:now 1000) 'top) '())
  (check-equal? (length (hash-ref (inbox-digest c p #:top 9999 #:now 1000) 'top)) 5 "bounded by what exists, and by 20"))

;; ---- 7. the plugin as the platform loads it ----------------------------------------
(test-case "the real loader accepts the plugin: routes, migrations, permissions"
  (load-plugins! PLUGINS-DIR)
  (define mine (filter (lambda (m) (equal? (hash-ref m 'id #f) "inbox")) (loaded-plugins)))
  (check-equal? (length mine) 1 "loaded exactly once")
  (check-false (assoc "inbox" (plugin-failures)) "and not among the failures")
  (check-equal? (hash-ref (car mine) 'migrations) '("x.inbox.init"))
  (define rs (hash-ref (car mine) 'routes))
  (check-equal? (length rs) 10 "nine single-item routes plus the batch")
  (for ([r (in-list routes)])
    (check-true (and (permission-doc (caddr r)) #t)
                (format "~a ~a names a permission the catalog describes" (car r) (cadr r)))))

(test-case "every route is reachable by the permission it names, and no write is a read"
  (for ([r (in-list routes)])
    (define method (car r))
    (define perm (caddr r))
    (check-equal? perm (if (equal? method "GET") "inbox:read" "inbox:write")
                  (format "~a ~a" method (cadr r)))))

(define (call route-method route-path p #:params [params (hasheq)] #:query [query (hasheq)] #:body [body (hasheq)] c)
  (define r (findf (lambda (r) (and (equal? (car r) route-method) (equal? (cadr r) route-path))) routes))
  ((cadddr r) c p (hasheq 'params params 'query query 'body body 'headers (hasheq))))

(test-case "the routes carry a producer's whole round trip: ingest, list, act, digest, read"
  (define-values (c p uid tid) (setup))
  (define made (call "POST" "/items" p c
                     #:body (hasheq 'source "watcher" 'key "nl:hpai" 'title "Source changed" 'severity "high"
                                    'scope "org:a/market:jp" 'kind "regulatory" 'revision "d1"
                                    'data (hasheq 'digest "d1"))))
  (check-equal? (hash-ref made 'outcome) "created")
  (define id (hash-ref (hash-ref made 'item) 'id))
  (define listed (call "GET" "/items" p c #:query (hasheq 'severity "high" 'scope_prefix "org:a/")))
  (check-equal? (hash-ref listed 'count) 1)
  (check-equal? (hash-ref listed 'order) "severity, then longest waiting")
  (define acked (call "POST" "/items/:id/ack" p c #:params (hasheq 'id id) #:body (hasheq 'note "read the page")))
  (check-equal? (hash-ref (hash-ref acked 'item) 'state) "acknowledged")
  (check-equal? (hash-ref (call "GET" "/digest" p c #:query (hasheq 'scope "org:a/market:jp")) 'needs_attention) 0)
  (define again (call "POST" "/items" p c
                      #:body (hasheq 'source "watcher" 'key "nl:hpai" 'title "Source changed" 'severity "high"
                                     'revision "d2")))
  (check-equal? (hash-ref again 'outcome) "resurfaced")
  (define one (call "GET" "/items/:id" p c #:params (hasheq 'id id)))
  (check-equal? (map (lambda (e) (hash-ref e 'kind)) (hash-ref one 'events)) '("created" "ack" "resurfaced"))
  (check-regexp-match #rx"not a state this inbox has" (user-error-message (lambda () (call "GET" "/items" p c #:query (hasheq 'state "nope")))))
  (check-regexp-match #rx"not a severity" (user-error-message (lambda () (call "POST" "/items" p c #:body (hasheq 'source "s" 'key "k" 'title "t" 'severity 3))))
                      "a wrong-typed severity is refused, not quietly defaulted"))

(test-case "a batch is one transaction: every item lands, or none does"
  (define-values (c p uid tid) (setup))
  (define made (call "POST" "/items/batch" p c
                     #:body (hasheq 'items (list (hasheq 'source "watcher" 'key "a" 'title "A")
                                                 (hasheq 'source "watcher" 'key "b" 'title "B")))))
  (check-equal? (map (lambda (x) (hash-ref x 'outcome)) made) '("created" "created"))
  (check-equal? (hash-ref (call "GET" "/items" p c) 'count) 2)
  (check-regexp-match
   #rx"title is required"
   (user-error-message
    (lambda ()
      (call "POST" "/items/batch" p c
            #:body (hasheq 'items (list (hasheq 'source "watcher" 'key "c" 'title "C")
                                        (hasheq 'source "watcher" 'key "d")))))))
  (check-equal? (query-maybe-value c "SELECT COUNT(*) FROM x_inbox_items WHERE item_key IN ('c','d')") 0
                "the good half of a refused batch is not left behind")
  (check-regexp-match
   #rx"1 to 100"
   (user-error-message (lambda () (call "POST" "/items/batch" p c #:body (hasheq 'items '()))))))

(test-case "the wake job kind registers under the plugin's own prefix and wakes only its team"
  (check-not-exn init!)
  (define-values (c p uid tid) (setup))
  (define id (id-of (raise! c p "k")))
  (inbox-act! c p id "snooze" #:until (+ (current-seconds) 1) #:now (- (current-seconds) 10))
  (sleep 1.1)
  (check-equal? (inbox-wake! c tid) 1))

;; ---- the workflow tool ------------------------------------------------------------
(define (tool-raise-via c p args) ((cadddr (car tools)) c p args))

(test-case "inbox_raise is one thin tool over the same ingest, behind inbox:write"
  (check-equal? (map car tools) '("inbox_raise"))
  (load-plugins! PLUGINS-DIR)
  (define t (tool-by-name "inbox_raise"))
  (check-true (and t #t) "the loader registered it")
  (check-equal? (tool-perm t) "inbox:write")
  (check-equal? (tool-source t) "inbox")
  (define-values (c p uid tid) (setup))
  (define a (tool-raise-via c p (hasheq 'source "wf" 'key "k1" 'title "From a workflow" 'revision "r1")))
  (check-equal? (outcome a) "created")
  (check-equal? (hash-ref (item a) 'severity) "normal" "severity defaults as the route's does")
  (check-equal? (outcome (tool-raise-via c p (hasheq 'source "wf" 'key "k1" 'title "From a workflow" 'revision "r1")))
                "refreshed" "the same revision is a refresh, by the same rule")
  (inbox-act! c p (id-of a) "ack" #:now T0)
  (check-equal? (outcome (tool-raise-via c p (hasheq 'source "wf" 'key "k1" 'title "Changed" 'revision "r2")))
                "resurfaced" "a new revision wakes an acknowledged item, by the same rule")
  (check-regexp-match #rx"not a severity"
                      (user-error-message (lambda () (tool-raise-via c p (hasheq 'source "wf" 'key "k2" 'title "t" 'severity "urgent"))))
                      "the vocabulary check is the route's own")
  (check-equal? (hash-ref (hash-ref (tool-raise-via c (other-team c) (hasheq 'source "wf" 'key "k1" 'title "x")) 'item) 'occurrence) 1
                "another team's raise of the same key is its own item"))

;; ---- the lost insert race, on two real connections --------------------------------
;; The unique index is what makes one live row per (team, source, key); the retry in
;; `inbox-ingest!` is what makes the LOSER answer correctly instead of with a 500. SQLite
;; serializes writers on one connection, so this needs Postgres: two connections on the
;; same schema, released together, 20 keys per run.
(when (postgres-fixture?)
  (test-case "two connections raising one key at once leave one live row and two good answers"
    (define key-name 'inbox-race)
    (define c1 (fresh-db #:shared key-name #:migrate? #f))
    (migrate! c1 all-migrations)
    (migrate! c1 (check-migrations! "inbox" migrations))
    (define c2 (fresh-db #:shared key-name #:migrate? #f))
    (define-values (uid tid) (bootstrap! c1 #:username "root"))
    (define p1 (user-principal c1 uid tid))
    (define p2 (user-principal c2 uid tid))
    (for ([i (in-range 20)])
      (define k (format "race-~a" i))
      (define gate (make-semaphore 0))
      (define results (make-vector 2 #f))
      (define (go slot c p)
        (thread (lambda ()
                  (semaphore-wait gate)
                  (vector-set! results slot
                               (with-handlers ([(lambda (_) #t) (lambda (e) e)])
                                 (raise! c p k #:title "Racing" #:revision "r1"))))))
      (define ts (list (go 0 c1 p1) (go 1 c2 p2)))
      (semaphore-post gate) (semaphore-post gate)
      (for-each thread-wait ts)
      (for ([r (in-vector results)])
        (check-pred hash? r (format "~a: both calls return an answer, not an exception: ~a" k r)))
      (when (andmap hash? (vector->list results))
        (check-equal? (sort (map outcome (vector->list results)) string<?) '("created" "refreshed")
                      (format "~a: one creates, the other finds the winner's row" k))
        (check-equal? (id-of (vector-ref results 0)) (id-of (vector-ref results 1))
                      (format "~a: both answers name the same item" k)))
      (check-equal? (query-value c1 (string-append "SELECT COUNT(*) FROM x_inbox_items WHERE team_id = ?"
                                                   " AND item_key = ? AND state <> 'resolved'") tid k)
                    1 (format "~a: exactly one live row" k))
      (check-equal? (query-value c1 "SELECT seen_count FROM x_inbox_items WHERE team_id = ? AND item_key = ?" tid k)
                    2 (format "~a: both raises were counted" k)))
    (close-db! c2)
    (close-db! c1)))
