#lang racket/base

;; plugins/inbox/main.rkt — a team's inbox of things that need a person.
;;
;; WHAT AN ITEM IS. Something outside the platform raised a fact that a person
;; has to answer: a monitor went down, a source changed, a partner asked for
;; something. The inbox keeps ONE row per (team, source, key) while that fact is
;; live, gives it a lifecycle a person can move it through, and answers "what is
;; waiting, how bad, and for which part of the business". It decides nothing
;; else.
;;
;; WHAT IT DELIBERATELY DOES NOT OWN (INBOX-2). The same shape as the feed queue's
;; QUEUE-2: it is an index and not a policy.
;;   • It does not know where items come from. `source` and `key` are the
;;     producer's own words; an alert manager, a regulatory watcher and a person
;;     typing into a form all use the same door.
;;   • It does not derive a severity from a title, a scope from a path, or a
;;     "material change" from a diff. The producer says how severe it is, which
;;     scope it belongs to, and whether this is a new REVISION of a fact it
;;     already raised. A plugin that guessed would be wrong quietly.
;;   • It does not own accounts. Everything is the caller's team, and a person is
;;     whoever the platform's principal says they are.
;;   • `scope_key` is a LABEL to filter and count by, not an access boundary.
;;     Hosts that need "this person sees only these scopes" enforce that in their
;;     own routes, in front of this plugin.
;;
;; THE LIFECYCLE (INBOX-3), closed and pinned by the test:
;;
;;   open ──ack──▶ acknowledged
;;   open|acknowledged|snoozed ──snooze(until)──▶ snoozed ──until passes──▶ open
;;   open|acknowledged|snoozed ──suppress──▶ suppressed
;;   acknowledged|snoozed|suppressed ──reopen──▶ open
;;   any live state ──resolve──▶ resolved                    (terminal)
;;
;; Resolved is terminal. The same (source, key) arriving after a resolve is a NEW
;; row with the next `occurrence`, never the old row dug up, so a resolved item's
;; history stays exactly what it was.
;;
;; REVISIONS (INBOX-4). Re-raising a live item with the same revision, or none, is
;; an EVIDENCE refresh: `last_seen` and `seen_count` move, nothing else does, and
;; nobody's acknowledgement is disturbed. A different revision is MATERIAL: the
;; content is replaced, and an acknowledged or snoozed item goes back to open,
;; because the person answered the old fact. A suppressed item stays suppressed
;; and takes the new content. This is what lets a producer that polls a source
;; every hour raise the same item every hour without waking anyone.
;;
;; EVERY TRANSITION IS AN EVENT (INBOX-5): `x_inbox_events` is append-only and
;; numbered per item, written in the same transaction as the state change. Who
;; acknowledged, when, and the one-line note they gave are an event, not a column
;; that the next acknowledgement overwrites.
;;
;; WHY NO PLATFORM EVENT IS EMITTED. `EVENTS` in `domain/events/events.rkt` is a
;; closed vocabulary a plugin cannot extend, so an `inbox.item.*` event would be
;; a platform change. Each transition is written to the audit log instead, and
;; the upstream ask is recorded in the plan.

(require racket/list racket/string json
         db-kit/portable
         (only-in "../../domain/authz/authz.rkt"
                  principal-team-id principal-user-id audit!)
         (only-in "../../domain/db/id.rkt" new-id)
         (only-in "../../domain/sched/scheduler.rkt" register-job-kind!))

(provide routes migrations init! tools
         ;; exported FOR the tests: the vocabulary, the transition table and the
         ;; limits are the whole of what this plugin decides, so they are pinned
         ;; rather than re-derived there.
         SEVERITIES STATES LIVE-STATES TRANSITIONS
         MAX-SNOOZE-SECONDS DEFAULT-LIMIT MAX-LIMIT
         inbox-ingest! inbox-act! inbox-get inbox-list inbox-digest inbox-wake!
         allowed-actions)

;; ---- the schema -----------------------------------------------------------------
;; Two tables, `x_inbox_…` because the loader enforces that prefix (#121).
;;
;; Epoch INTEGERS, never CURRENT_TIMESTAMP: the two dialects format it
;; differently and a comparison on it is wrong on one engine (migrations 0038,
;; 0041, 0066 are the platform's own instances). `scope_key` and `item_key` carry
;; `_key` because bare `scope` and `key` are reserved words somewhere.
;;
;; THE PARTIAL UNIQUE INDEX IS THE DEDUPE RULE: at most one non-resolved row per
;; (team, source, key). Two writers that both see "no live row" both insert, and
;; the index lets exactly one win; the loser's right answer is to run again and
;; find the winner's row, so `inbox-ingest!` does that.
(define migrations
  (list
   (list "init"
         (string-append "CREATE TABLE x_inbox_items ("
                        "  id TEXT PRIMARY KEY,"
                        "  team_id TEXT NOT NULL,"
                        "  source TEXT NOT NULL,"
                        "  item_key TEXT NOT NULL,"
                        "  kind TEXT,"
                        "  scope_key TEXT,"
                        "  severity TEXT NOT NULL,"
                        "  severity_rank INTEGER NOT NULL,"
                        "  state TEXT NOT NULL,"
                        "  title TEXT NOT NULL,"
                        "  body TEXT,"
                        "  url TEXT,"
                        "  data TEXT,"
                        "  revision TEXT,"
                        "  occurrence INTEGER NOT NULL,"
                        "  seen_count INTEGER NOT NULL,"
                        "  first_seen_epoch BIGINT NOT NULL,"
                        "  last_seen_epoch BIGINT NOT NULL,"
                        "  snooze_until_epoch BIGINT,"
                        "  ack_by TEXT,"
                        "  ack_at_epoch BIGINT,"
                        "  ack_note TEXT,"
                        "  resolved_by TEXT,"
                        "  resolved_at_epoch BIGINT,"
                        "  resolve_note TEXT,"
                        "  updated_epoch BIGINT NOT NULL)")
         (string-append "CREATE UNIQUE INDEX x_inbox_items_live ON x_inbox_items"
                        " (team_id, source, item_key) WHERE state <> 'resolved'")
         (string-append "CREATE INDEX x_inbox_items_queue ON x_inbox_items"
                        " (team_id, state, severity_rank, first_seen_epoch)")
         "CREATE INDEX x_inbox_items_scope ON x_inbox_items (team_id, scope_key)"
         (string-append "CREATE TABLE x_inbox_events ("
                        "  id TEXT PRIMARY KEY,"
                        "  item_id TEXT NOT NULL,"
                        "  team_id TEXT NOT NULL,"
                        "  seq INTEGER NOT NULL,"
                        "  at_epoch BIGINT NOT NULL,"
                        "  kind TEXT NOT NULL,"
                        "  actor_type TEXT NOT NULL,"
                        "  actor_id TEXT,"
                        "  data TEXT)")
         ;; numbered per item, and the index is what refuses two events with one
         ;; number if two writers race
         "CREATE UNIQUE INDEX x_inbox_events_seq ON x_inbox_events (item_id, seq)")))

;; ---- the vocabulary -------------------------------------------------------------
;; CLOSED and pinned by the test, as the platform's own vocabularies are: adding a
;; member is a decision somebody makes on purpose. Four severities, most severe
;; first; a producer with five levels maps two of them onto one.
(define SEVERITIES '("critical" "high" "normal" "low"))
(define (severity-rank s) (- (length SEVERITIES) (index-of SEVERITIES s)))

(define STATES '("open" "acknowledged" "snoozed" "suppressed" "resolved"))
(define LIVE-STATES '("open" "acknowledged" "snoozed" "suppressed"))

;; action -> (values from-states to-state). The one table the lifecycle is read
;; from, so the routes, the allowed-actions list and the test cannot disagree.
(define TRANSITIONS
  (hash "ack"       (cons '("open") "acknowledged")
        "snooze"    (cons '("open" "acknowledged" "snoozed") "snoozed")
        "suppress"  (cons '("open" "acknowledged" "snoozed") "suppressed")
        "reopen"    (cons '("acknowledged" "snoozed" "suppressed") "open")
        "resolve"   (cons LIVE-STATES "resolved")))

(define ACTION-ORDER '("ack" "snooze" "suppress" "reopen" "resolve"))

(define (allowed-actions state)
  (for/list ([a (in-list ACTION-ORDER)]
             #:when (member state (car (hash-ref TRANSITIONS a))))
    a))

;; A snooze is bounded so it cannot become an unnoticed mute; "until further
;; notice" is `suppress`, which is a different act with a different name.
(define MAX-SNOOZE-SECONDS (* 90 24 3600))

(define DEFAULT-LIMIT 50)
(define MAX-LIMIT 200)

;; Caps, so one item cannot carry a document. Counted in characters.
(define MAX-SOURCE 120) (define MAX-KEY 200) (define MAX-KIND 60) (define MAX-SCOPE 200)
(define MAX-TITLE 200) (define MAX-BODY 4000) (define MAX-URL 500) (define MAX-NOTE 500)
(define MAX-REVISION 200) (define MAX-DATA-BYTES 8192)

(define (bad who fmt . args) (raise-user-error who (apply format fmt args)))

;; ---- input checks ---------------------------------------------------------------
(define (req-string who name v max)
  (unless (and (string? v) (not (string=? (string-trim v) "")))
    (bad who "~a is required" name))
  (define t (string-trim v))
  (when (> (string-length t) max) (bad who "~a is longer than ~a characters" name max))
  t)

(define (opt-string who name v max)
  (cond [(or (not v) (eq? v 'null)) #f]
        [(not (string? v)) (bad who "~a must be a string" name)]
        [(string=? (string-trim v) "") #f]
        [else (let ([t (string-trim v)])
                (when (> (string-length t) max) (bad who "~a is longer than ~a characters" name max))
                t)]))

;; an item's link is shown to people, so only a web address is accepted
(define (opt-url who v)
  (define u (opt-string who "url" v MAX-URL))
  (when (and u (not (regexp-match? #px"^https?://\\S+$" u)))
    (bad who "url must be an http or https address"))
  u)

(define (opt-data who v)
  (cond [(or (not v) (eq? v 'null)) #f]
        [(not (hash? v)) (bad who "data must be a JSON object")]
        [else (let ([s (jsexpr->string v)])
                (when (> (bytes-length (string->bytes/utf-8 s)) MAX-DATA-BYTES)
                  (bad who "data is larger than ~a bytes" MAX-DATA-BYTES))
                s)]))

(define (opt-revision who v)
  (cond [(or (not v) (eq? v 'null)) #f]
        [(exact-integer? v) (number->string v)]
        [else (opt-string who "revision" v MAX-REVISION)]))

;; ---- rows -----------------------------------------------------------------------
(define COLS
  '(id team_id source item_key kind scope_key severity severity_rank state title body url data
    revision occurrence seen_count first_seen_epoch last_seen_epoch snooze_until_epoch
    ack_by ack_at_epoch ack_note resolved_by resolved_at_epoch resolve_note updated_epoch))
(define COL-SQL (string-join (map symbol->string COLS) ", "))

;; SQL NULL becomes #f inside the plugin and 'null on the wire.
(define (row->h r)
  (for/hasheq ([c (in-list COLS)] [v (in-vector r)])
    (values c (if (sql-null? v) #f v))))

(define (nl v) (if v v 'null))

(define (item->json h)
  (hasheq 'id (hash-ref h 'id) 'source (hash-ref h 'source) 'key (hash-ref h 'item_key)
          'kind (nl (hash-ref h 'kind)) 'scope (nl (hash-ref h 'scope_key))
          'severity (hash-ref h 'severity) 'state (hash-ref h 'state)
          'title (hash-ref h 'title) 'body (nl (hash-ref h 'body)) 'url (nl (hash-ref h 'url))
          'data (let ([d (hash-ref h 'data)]) (if d (string->jsexpr d) 'null))
          'revision (nl (hash-ref h 'revision))
          'occurrence (hash-ref h 'occurrence) 'seen_count (hash-ref h 'seen_count)
          'first_seen (hash-ref h 'first_seen_epoch) 'last_seen (hash-ref h 'last_seen_epoch)
          'snooze_until (nl (hash-ref h 'snooze_until_epoch))
          'ack_by (nl (hash-ref h 'ack_by)) 'ack_at (nl (hash-ref h 'ack_at_epoch))
          'ack_note (nl (hash-ref h 'ack_note))
          'resolved_by (nl (hash-ref h 'resolved_by)) 'resolved_at (nl (hash-ref h 'resolved_at_epoch))
          'resolve_note (nl (hash-ref h 'resolve_note))
          'updated (hash-ref h 'updated_epoch)
          'allowed_actions (allowed-actions (hash-ref h 'state))))

(define (load conn p id)
  (define r (query-maybe-row conn
                             (string-append "SELECT " COL-SQL " FROM x_inbox_items WHERE id = ? AND team_id = ?")
                             id (principal-team-id p)))
  (and r (row->h r)))

;; "no such item" for a miss AND for another team's id, so the answer cannot be
;; used to learn whether an id exists elsewhere (the feed queue's rule).
(define (load! who conn p id)
  (unless (string? id) (bad who "an item id is required"))
  (or (load conn p id) (bad who "no such item: ~a" id)))

;; ---- events ---------------------------------------------------------------------
(define (event! conn item-id team kind actor-type actor-id data now)
  (define seq (add1 (query-value conn "SELECT COALESCE(MAX(seq), 0) FROM x_inbox_events WHERE item_id = ?" item-id)))
  (query-exec conn
              (string-append "INSERT INTO x_inbox_events"
                             " (id, item_id, team_id, seq, at_epoch, kind, actor_type, actor_id, data)"
                             " VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)")
              (new-id) item-id team seq now kind actor-type (or actor-id sql-null)
              (if data (jsexpr->string data) sql-null)))

(define (actor-of p) (let ([u (principal-user-id p)]) (and (string? u) u)))

;; The audit log is the platform's record of who did what; the inbox's own events
;; are the record of what happened to ONE item. A refresh is neither a decision
;; nor a person's act, and a producer polling hourly would bury the log, so only
;; transitions are audited.
(define (audit-item! conn p kind id)
  (audit! conn #:action (string-append "inbox.item." kind)
          #:actor-type "user" #:actor-id (or (actor-of p) sql-null)
          #:team-id (principal-team-id p)
          #:resource-type "inbox_item" #:resource-id id))

;; ---- ingest ---------------------------------------------------------------------
;; -> (hasheq 'outcome … 'item …). outcome is one of
;;   created     a new live row
;;   reopened    a new row for a (source, key) whose earlier row was resolved
;;   refreshed   the live row's evidence moved; nothing else did
;;   revised     a new revision replaced the content; state unchanged
;;   resurfaced  a new revision replaced the content and sent an acknowledged or
;;               snoozed row back to open
(define (inbox-ingest! conn p
                       #:source source #:key key #:title title
                       #:severity [severity "normal"]
                       #:kind [kind #f] #:scope [scope #f]
                       #:body [body #f] #:url [url #f] #:data [data #f]
                       #:revision [revision #f]
                       #:now [now (current-seconds)])
  (define who 'inbox_ingest)
  (define src (req-string who "source" source MAX-SOURCE))
  (define k (req-string who "key" key MAX-KEY))
  (define ttl (req-string who "title" title MAX-TITLE))
  (unless (member severity SEVERITIES)
    (bad who "~s is not a severity this inbox has (it offers: ~a)" severity (string-join SEVERITIES ", ")))
  (define knd (opt-string who "kind" kind MAX-KIND))
  (define scp (opt-string who "scope" scope MAX-SCOPE))
  (define bdy (opt-string who "body" body MAX-BODY))
  (define lnk (opt-url who url))
  (define dat (opt-data who data))
  (define rev (opt-revision who revision))
  (define (attempt) (ingest-once! conn p now src k ttl severity knd scp bdy lnk dat rev))
  ;; A lost race surfaces as a unique-index violation on the insert. Running the
  ;; whole thing again is the right answer: it now finds the winner's row.
  (with-handlers ([exn:fail:sql? (lambda (_e) (attempt))])
    (attempt)))

(define (ingest-once! conn p now src k ttl severity knd scp bdy lnk dat rev)
  (define team (principal-team-id p))
  (define actor (actor-of p))
  (call-with-transaction conn
    (lambda ()
      (define live
        (let ([r (query-maybe-row conn
                                  (string-append "SELECT " COL-SQL " FROM x_inbox_items"
                                                 " WHERE team_id = ? AND source = ? AND item_key = ?"
                                                 " AND state <> 'resolved'")
                                  team src k)])
          (and r (row->h r))))
      (cond
        [(not live)
         (define id (new-id))
         (define prior (query-value conn
                                    (string-append "SELECT COUNT(*) FROM x_inbox_items"
                                                   " WHERE team_id = ? AND source = ? AND item_key = ?")
                                    team src k))
         (query-exec conn
                     (string-append "INSERT INTO x_inbox_items (" COL-SQL ") VALUES ("
                                    (string-join (for/list ([_c (in-list COLS)]) "?") ", ") ")")
                     id team src k (or knd sql-null) (or scp sql-null) severity (severity-rank severity)
                     "open" ttl (or bdy sql-null) (or lnk sql-null) (or dat sql-null) (or rev sql-null)
                     (add1 prior) 1 now now sql-null sql-null sql-null sql-null sql-null sql-null sql-null now)
         (define outcome (if (> prior 0) "reopened" "created"))
         (event! conn id team outcome "source" actor
                 (hasheq 'severity severity 'occurrence (add1 prior)) now)
         (audit-item! conn p outcome id)
         (hasheq 'outcome outcome 'item (item->json (load! 'inbox_ingest conn p id)))]
        [(equal? rev (hash-ref live 'revision))
         (query-exec conn
                     "UPDATE x_inbox_items SET last_seen_epoch = ?, seen_count = seen_count + 1 WHERE id = ?"
                     now (hash-ref live 'id))
         (hasheq 'outcome "refreshed" 'item (item->json (load! 'inbox_ingest conn p (hash-ref live 'id))))]
        [else
         (define id (hash-ref live 'id))
         (define state (hash-ref live 'state))
         (define wake? (and (member state '("acknowledged" "snoozed")) #t))
         (query-exec conn
                     (string-append "UPDATE x_inbox_items SET kind = ?, scope_key = ?, severity = ?,"
                                    " severity_rank = ?, title = ?, body = ?, url = ?, data = ?, revision = ?,"
                                    " last_seen_epoch = ?, seen_count = seen_count + 1, updated_epoch = ?"
                                    ;; the person answered the OLD fact, so an
                                    ;; acknowledgement or a snooze does not carry over
                                    (if wake?
                                        (string-append ", state = 'open', snooze_until_epoch = NULL,"
                                                       " ack_by = NULL, ack_at_epoch = NULL, ack_note = NULL")
                                        "")
                                    " WHERE id = ?")
                     (or knd sql-null) (or scp sql-null) severity (severity-rank severity) ttl
                     (or bdy sql-null) (or lnk sql-null) (or dat sql-null) (or rev sql-null)
                     now now id)
         (define outcome (if wake? "resurfaced" "revised"))
         (event! conn id team outcome "source" actor
                 (hasheq 'from_revision (nl (hash-ref live 'revision)) 'to_revision (nl rev)
                         'severity severity 'was state)
                 now)
         (audit-item! conn p outcome id)
         (hasheq 'outcome outcome 'item (item->json (load! 'inbox_ingest conn p id)))]))))

;; ---- acting on an item ----------------------------------------------------------
;; One entry point for the five acts, driven by TRANSITIONS. An act on an item that
;; is already in the target state changes nothing and writes nothing (idempotent),
;; so a double-click or a retried request is harmless. An act the table does not
;; allow from the current state is refused with the list of what is allowed.
(define (inbox-act! conn p id action
                    #:note [note #f] #:until [until #f]
                    #:now [now (current-seconds)])
  (define who (string->symbol (string-append "inbox_" action)))
  (unless (hash-has-key? TRANSITIONS action)
    (bad who "~s is not an act this inbox has (it offers: ~a)" action (string-join ACTION-ORDER ", ")))
  (define nt (opt-string who "note" note MAX-NOTE))
  (define team (principal-team-id p))
  (define actor (actor-of p))
  (call-with-transaction conn
    (lambda ()
      (define item (load! who conn p id))
      (define state (hash-ref item 'state))
      (define from (car (hash-ref TRANSITIONS action)))
      (define to (cdr (hash-ref TRANSITIONS action)))
      (define snooze-until
        (and (equal? action "snooze")
             (begin
               (unless (exact-integer? until) (bad who "until is required, in epoch seconds"))
               (unless (> until now) (bad who "until must be in the future"))
               (unless (<= until (+ now MAX-SNOOZE-SECONDS))
                 (bad who "a snooze is at most ~a days; use suppress for an item that should stay quiet"
                      (quotient MAX-SNOOZE-SECONDS 86400)))
               until)))
      (cond
        ;; already there, and a snooze to the same instant is also already there
        [(and (equal? state to) (not (equal? action "snooze")))
         (hasheq 'changed #f 'item (item->json item))]
        [(and (equal? action "snooze") (equal? state "snoozed")
              (equal? (hash-ref item 'snooze_until_epoch) snooze-until))
         (hasheq 'changed #f 'item (item->json item))]
        [(not (member state from))
         (bad who "an item that is ~a cannot be ~a (it can: ~a)" state
              (case action [("ack") "acknowledged"] [("snooze") "snoozed"] [("suppress") "suppressed"]
                [("reopen") "reopened"] [else "resolved"])
              (let ([ok (allowed-actions state)]) (if (null? ok) "nothing, it is resolved" (string-join ok ", "))))]
        [else
         (case action
           [("ack")
            (query-exec conn
                        (string-append "UPDATE x_inbox_items SET state = 'acknowledged', ack_by = ?, ack_at_epoch = ?,"
                                       " ack_note = ?, updated_epoch = ? WHERE id = ? AND team_id = ?")
                        (or actor sql-null) now (or nt sql-null) now id team)]
           [("snooze")
            (query-exec conn
                        (string-append "UPDATE x_inbox_items SET state = 'snoozed', snooze_until_epoch = ?,"
                                       " updated_epoch = ? WHERE id = ? AND team_id = ?")
                        snooze-until now id team)]
           [("suppress")
            (query-exec conn
                        (string-append "UPDATE x_inbox_items SET state = 'suppressed', snooze_until_epoch = NULL,"
                                       " updated_epoch = ? WHERE id = ? AND team_id = ?")
                        now id team)]
           [("reopen")
            ;; an acknowledgement belongs to the fact it answered, so reopening
            ;; clears it; the event log still says who acknowledged and when
            (query-exec conn
                        (string-append "UPDATE x_inbox_items SET state = 'open', snooze_until_epoch = NULL,"
                                       " ack_by = NULL, ack_at_epoch = NULL, ack_note = NULL,"
                                       " updated_epoch = ? WHERE id = ? AND team_id = ?")
                        now id team)]
           [("resolve")
            (query-exec conn
                        (string-append "UPDATE x_inbox_items SET state = 'resolved', snooze_until_epoch = NULL,"
                                       " resolved_by = ?, resolved_at_epoch = ?, resolve_note = ?,"
                                       " updated_epoch = ? WHERE id = ? AND team_id = ?")
                        (or actor sql-null) now (or nt sql-null) now id team)])
         (event! conn id team action "user" actor
                 (let ([h (hasheq 'from state 'to to)])
                   (let* ([h (if nt (hash-set h 'note nt) h)]
                          [h (if snooze-until (hash-set h 'until snooze-until) h)])
                     h))
                 now)
         (audit-item! conn p action id)
         (hasheq 'changed #t 'item (item->json (load! who conn p id)))]))))

;; ---- waking a snooze ------------------------------------------------------------
;; A snooze that has run out is open again. There is no timer thread (a thread
;; started at load has no team and no principal, the integrator's guide §6b), so
;; the wake is lazy: every read of the team's inbox runs it first, and the
;; `x.inbox.wake` job kind runs it on a schedule for a team that wants the event
;; log to show the wake at the time it happened rather than at the next read.
;; Each item is woken in its own transaction, and a lost race (another reader
;; woke it first, so the event number is taken) is swallowed, because the item is
;; open either way.
(define (inbox-wake! conn team-id #:now [now (current-seconds)])
  (define ids
    (query-list conn
                (string-append "SELECT id FROM x_inbox_items WHERE team_id = ? AND state = 'snoozed'"
                               " AND snooze_until_epoch <= ?")
                team-id now))
  (for/sum ([id (in-list ids)])
    (with-handlers ([exn:fail:sql? (lambda (_e) 0)])
      (call-with-transaction conn
        (lambda ()
          (define still
            (query-value conn
                         (string-append "SELECT COUNT(*) FROM x_inbox_items WHERE id = ? AND state = 'snoozed'"
                                        " AND snooze_until_epoch <= ?")
                         id now))
          (cond
            [(positive? still)
             (query-exec conn
                         (string-append "UPDATE x_inbox_items SET state = 'open', snooze_until_epoch = NULL,"
                                        " updated_epoch = ? WHERE id = ?")
                         now id)
             (event! conn id team-id "woke" "system" #f (hasheq 'from "snoozed" 'to "open") now)
             1]
            [else 0]))))))

;; ---- reading --------------------------------------------------------------------
(define (inbox-get conn p id #:now [now (current-seconds)])
  (inbox-wake! conn (principal-team-id p) #:now now)
  (define item (load! 'inbox_get conn p id))
  (hash-set (item->json item) 'events
            (for/list ([r (in-list (query-rows conn
                                               (string-append "SELECT seq, at_epoch, kind, actor_type, actor_id, data"
                                                              " FROM x_inbox_events WHERE item_id = ? AND team_id = ?"
                                                              " ORDER BY seq ASC")
                                               id (principal-team-id p)))])
              (hasheq 'seq (vector-ref r 0) 'at (vector-ref r 1) 'kind (vector-ref r 2)
                      'actor_type (vector-ref r 3)
                      'actor_id (let ([v (vector-ref r 4)]) (if (sql-null? v) 'null v))
                      'data (let ([v (vector-ref r 5)]) (if (sql-null? v) 'null (string->jsexpr v)))))))

;; `scope` is an exact label, `scope-prefix` every label that starts with it. The
;; prefix uses substr() rather than LIKE because LIKE needs `%` and `_` escaped
;; and the escape clause is spelled differently by the two dialects.
(define (scope-filter who scope prefix)
  (when (and scope prefix) (bad who "give scope or scope_prefix, not both"))
  (cond [scope (values " AND scope_key = ?" (list scope))]
        [prefix (values (format " AND substr(scope_key, 1, ~a) = ?" (string-length prefix)) (list prefix))]
        [else (values "" '())]))

(define (parse-states who v)
  (cond
    [(or (not v) (equal? v "")) '("open" "acknowledged")]
    [(equal? v "all") STATES]
    [else
     (define xs (string-split v "," #:trim? #t))
     (for ([s (in-list xs)])
       (unless (member s STATES)
         (bad who "~s is not a state this inbox has (it offers: ~a, or \"all\")" s (string-join STATES ", "))))
     (if (null? xs) (bad who "state is empty") xs)]))

(define (inbox-list conn p
                    #:states [states '("open" "acknowledged")]
                    #:severity [severity #f] #:source [source #f] #:kind [kind #f]
                    #:scope [scope #f] #:scope-prefix [prefix #f]
                    #:limit [limit DEFAULT-LIMIT] #:offset [offset 0]
                    #:now [now (current-seconds)])
  (define who 'inbox_list)
  (define team (principal-team-id p))
  (inbox-wake! conn team #:now now)
  (when (and severity (not (member severity SEVERITIES)))
    (bad who "~s is not a severity this inbox has (it offers: ~a)" severity (string-join SEVERITIES ", ")))
  (define-values (sc-sql sc-args) (scope-filter who scope prefix))
  (define lim (max 1 (min MAX-LIMIT (if (exact-nonnegative-integer? limit) limit DEFAULT-LIMIT))))
  (define off (if (exact-nonnegative-integer? offset) offset 0))
  (define sql
    (string-append "SELECT " COL-SQL " FROM x_inbox_items WHERE team_id = ?"
                   " AND state IN (" (string-join (for/list ([_s (in-list states)]) "?") ", ") ")"
                   (if severity " AND severity = ?" "")
                   (if source " AND source = ?" "")
                   (if kind " AND kind = ?" "")
                   sc-sql
                   ;; THE ORDER IS THE FEATURE: most severe first, then the one
                   ;; that has waited longest, then the id so two pages never
                   ;; disagree about where one ends.
                   " ORDER BY severity_rank DESC, first_seen_epoch ASC, id ASC"
                   " LIMIT " (number->string lim) " OFFSET " (number->string off)))
  (define args (append (list team) states (if severity (list severity) '())
                       (if source (list source) '()) (if kind (list kind) '()) sc-args))
  (for/list ([r (in-list (apply query-rows conn sql args))])
    (item->json (row->h r))))

;; What a person opening the inbox needs first, for the whole team or for one
;; scope or one scope subtree: how many are waiting in each state, how severe the
;; open ones are, how long the oldest has waited, and the few to look at first.
;; Resolved items are history and are not counted.
(define (inbox-digest conn p
                      #:scope [scope #f] #:scope-prefix [prefix #f]
                      #:top [top 5]
                      #:now [now (current-seconds)])
  (define who 'inbox_digest)
  (define team (principal-team-id p))
  (inbox-wake! conn team #:now now)
  (define-values (sc-sql sc-args) (scope-filter who scope prefix))
  (define by-state
    (for/hasheq ([r (in-list (apply query-rows conn
                                    (string-append "SELECT state, COUNT(*) FROM x_inbox_items WHERE team_id = ?"
                                                   " AND state <> 'resolved'" sc-sql " GROUP BY state")
                                    team sc-args))])
      (values (string->symbol (vector-ref r 0)) (vector-ref r 1))))
  (define open-by-severity
    (for/hasheq ([r (in-list (apply query-rows conn
                                    (string-append "SELECT severity, COUNT(*) FROM x_inbox_items WHERE team_id = ?"
                                                   " AND state = 'open'" sc-sql " GROUP BY severity")
                                    team sc-args))])
      (values (string->symbol (vector-ref r 0)) (vector-ref r 1))))
  (define oldest
    (apply query-value conn
           (string-append "SELECT MIN(first_seen_epoch) FROM x_inbox_items WHERE team_id = ?"
                          " AND state = 'open'" sc-sql)
           team sc-args))
  (hasheq 'scope (or scope 'null) 'scope_prefix (or prefix 'null) 'as_of now
          'states (for/hasheq ([s (in-list LIVE-STATES)])
                    (values (string->symbol s) (hash-ref by-state (string->symbol s) 0)))
          'open_by_severity (for/hasheq ([s (in-list SEVERITIES)])
                              (values (string->symbol s) (hash-ref open-by-severity (string->symbol s) 0)))
          'needs_attention (hash-ref by-state 'open 0)
          'oldest_open_age_seconds (if (sql-null? oldest) 'null (max 0 (- now oldest)))
          'top (if (<= top 0) '() (inbox-list conn p #:states '("open") #:scope scope #:scope-prefix prefix
                           #:limit (min 20 top) #:now now))))

;; ---- routes ---------------------------------------------------------------------
;; PERMISSIONS (INBOX-6). `inbox:read` for reads and `inbox:write` for ingest and acts. They are
;; separate from `tasks:*` because an item is raised by a producer outside the platform, so a
;; service token can hold `inbox:write` and nothing else. A member and an admin hold both, a
;; viewer reads through `*:read`, an owner holds them through `*:*`.
(define (qs q k) (let ([v (hash-ref q k #f)]) (and (string? v) (not (string=? v "")) v)))
(define (body-of args) (let ([b (hash-ref args 'body #f)]) (if (hash? b) b (hasheq))))
(define (bnum v) (and (real? v) (inexact->exact (round v))))
(define (idnum who s) (let ([n (and s (string->number s))]) (and n (exact-nonnegative-integer? n) n)))

(define (route-ingest conn p args)
  (define b (body-of args))
  (define (g k) (hash-ref b k #f))
  (inbox-ingest! conn p
                 #:source (g 'source) #:key (g 'key) #:title (g 'title)
                 #:severity (let ([v (g 'severity)]) (if (or (not v) (eq? v 'null)) "normal" v))
                 #:kind (g 'kind) #:scope (g 'scope) #:body (g 'body) #:url (g 'url)
                 #:data (g 'data) #:revision (g 'revision)))

;; ---- the workflow tool ----------------------------------------------------------
;; A workflow step or the agent raises an item through the SAME `inbox-ingest!` the route
;; uses, so the vocabulary checks, the caps, the revision rule and the race retry are not
;; written twice. The platform checks `inbox:write` before the handler runs.
(define raise-schema
  (hasheq 'type "function"
          'function
          (hasheq 'name "inbox_raise"
                  'description (string-append "Raise an item into the team's inbox, or re-raise one. One live item "
                                              "exists per (source, key): the same revision only refreshes the evidence, "
                                              "a different revision replaces the content and sends an acknowledged or "
                                              "snoozed item back to open. The answer's outcome says which happened.")
                  'parameters
                  (hasheq 'type "object"
                          'properties
                          (hasheq 'source (hasheq 'type "string" 'description "Who raised it, in the producer's own words")
                                  'key (hasheq 'type "string" 'description "The producer's id for the fact, stable across re-raises")
                                  'title (hasheq 'type "string" 'description "What a person reads first")
                                  'severity (hasheq 'type "string" 'enum SEVERITIES 'description "Defaults to normal")
                                  'kind (hasheq 'type "string" 'description "The producer's own grouping label")
                                  'scope (hasheq 'type "string" 'description "A label to filter and count by, not an access boundary")
                                  'body (hasheq 'type "string") 'url (hasheq 'type "string")
                                  'data (hasheq 'type "object" 'description "At most 8 KiB of JSON")
                                  'revision (hasheq 'type "string" 'description "A different revision is a material change"))
                          'required '("source" "key" "title")))))

(define (tool-raise conn p args) (route-ingest conn p (hasheq 'body args)))

(define tools (list (list "inbox_raise" raise-schema "inbox:write" tool-raise)))

(define (route-list conn p args)
  (define q (hash-ref args 'query (hasheq)))
  (define states (parse-states 'inbox_list (qs q 'state)))
  (define items
    (inbox-list conn p
                #:states states #:severity (qs q 'severity) #:source (qs q 'source) #:kind (qs q 'kind)
                #:scope (qs q 'scope) #:scope-prefix (qs q 'scope_prefix)
                #:limit (or (idnum 'limit (qs q 'limit)) DEFAULT-LIMIT)
                #:offset (or (idnum 'offset (qs q 'offset)) 0)))
  (hasheq 'items items 'count (length items) 'states STATES 'severities SEVERITIES
          'order "severity, then longest waiting"))

(define (route-get conn p args)
  (inbox-get conn p (hash-ref (hash-ref args 'params) 'id #f)))

(define (route-digest conn p args)
  (define q (hash-ref args 'query (hasheq)))
  (inbox-digest conn p #:scope (qs q 'scope) #:scope-prefix (qs q 'scope_prefix)))

(define ((route-act action) conn p args)
  (define b (body-of args))
  (inbox-act! conn p (hash-ref (hash-ref args 'params) 'id #f) action
              #:note (hash-ref b 'note #f)
              #:until (bnum (hash-ref b 'until #f))))

(define routes
  (list
   (list "POST" "/items" "inbox:write" route-ingest
         "Raise an item, or re-raise one. {source, key, title, severity?: critical|high|normal|low, kind?, scope?, body?, url?, data?, revision?}. One live row exists per (source, key): the same revision refreshes the evidence only, a different revision replaces the content and sends an acknowledged or snoozed item back to open, and a key that was resolved opens a new row. The answer says which: outcome is created, reopened, refreshed, revised or resurfaced.")
   (list "GET" "/items" "inbox:read" route-list
         "The team's inbox, most severe first then longest waiting. ?state= one or a comma list of open|acknowledged|snoozed|suppressed|resolved, or all (default: open and acknowledged), ?severity=, ?source=, ?kind=, ?scope= one exact scope label, ?scope_prefix= every label starting with it, ?limit=/?offset=. A snooze that has run out reads as open.")
   (list "GET" "/items/:id" "inbox:read" route-get
         "One item with its events, numbered in the order they happened: who acknowledged and when, the note they gave, every revision and wake.")
   (list "POST" "/items/:id/ack" "inbox:write" (route-act "ack")
         "Acknowledge an open item: {note?}. Someone has seen it and is on it; it stays in the inbox and stops counting as needing attention. A new revision from the producer sends it back to open.")
   (list "POST" "/items/:id/snooze" "inbox:write" (route-act "snooze")
         "Hide an item until a time: {until: epoch seconds, at most 90 days ahead, note?}. When the time passes it is open again.")
   (list "POST" "/items/:id/suppress" "inbox:write" (route-act "suppress")
         "Keep an item quiet with no end time: {note?}. The producer can keep raising it, the evidence moves and nothing wakes it. Reopen it to bring it back.")
   (list "POST" "/items/:id/reopen" "inbox:write" (route-act "reopen")
         "Bring an acknowledged, snoozed or suppressed item back to open.")
   (list "POST" "/items/:id/resolve" "inbox:write" (route-act "resolve")
         "Close an item for good: {note?}. Resolved is terminal. The same (source, key) raised later is a new row with the next occurrence.")
   (list "GET" "/digest" "inbox:read" route-digest
         "What to look at first, for the whole team or one scope: counts by state, open items by severity, how long the oldest open one has waited, and the top few. ?scope= one exact label, ?scope_prefix= a subtree. Resolved items are not counted.")))

;; ---- job kind -------------------------------------------------------------------
;; `x.inbox.wake`: wake the enqueuing team's expired snoozes now. Reads do it
;; lazily; this is for a team that schedules it (`jobs:schedule`) so the event log
;; records the wake when it happened. The principal on a job is the enqueuing
;; team and user, so the handler needs nothing from the payload.
(define (wake-job conn p _payload)
  (hasheq 'woke (inbox-wake! conn (principal-team-id p))))

(define (init!)
  (register-job-kind! "x.inbox.wake" wake-job))
