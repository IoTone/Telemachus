#lang racket/base

;; plugins/feeds/main.rkt — the feed work queue, and proposals about what is in
;; it (issue #114 slices 5 and 6; decisions FEED-8 and FEED-10, plus QUEUE-1…9).
;;
;; A PLUGIN RATHER THAN A CORE TAB, and that was the owner's call on 27 Oct 2026
;; (question 2 on #114): a plugin owns its own tables, routes and screens today,
;; so this is buildable on seams that shipped — plugin migrations (#121), plugin
;; routes (slice 63), a bundle page (#20, #43) — while a tab inside the core
;; console is a platform change a plugin cannot make. FEED-8 had assumed as much;
;; the answer settles that a core tab is a separate decision nobody waits on.
;;
;; WHY A TABLE AT ALL, when the items are already repository documents: the queue
;; needs ordering by priority, a due-date comparison and a status filter.
;; `repo-list` does none of them, LAY-4 attribute values are STRINGS, and there is
;; no JSON SQL in both dialects — so a core implementation means typed storage and
;; a dialect-specific query. The plugin keeps typed columns instead and the
;; documents stay the source of truth: this table is an INDEX over them, and
;; every read re-authorizes the document it points at.
;;
;; AND IT IS AN INDEX, NOT A POLICY (QUEUE-2). The priority, the due date and the
;; skills are ARGUMENTS — the customer's own triage decides them, in a workflow,
;; from whatever their labels mean. A plugin that derived a priority from the word
;; "critical" appearing in a GitHub label would be guessing at somebody else's
;; conventions and would be wrong quietly.

(require racket/string racket/list racket/port racket/math json
         db-kit/portable
         (only-in "../../domain/authz/authz.rkt"
                  principal-team-id principal-user-id require-perm audit!)
         (only-in "../../domain/repo/repo.rkt" repo-get repo-open repo-derive!)
         (only-in "../../domain/ai/executor.rkt" run-chat model-configured?)
         (only-in "../../domain/ai/roles.rkt" model-role-executor)
         (only-in "../../domain/orgs/orgs.rkt" tenant-quota-record!))

(provide tools routes workflows migrations init!
         ;; THE MODEL IS A PARAMETER, as it is for every other model-backed tool
         ;; in this tree (`current-doc-chat`). The first version of this plugin
         ;; called `run-chat` directly, which made the whole proposal path
         ;; untestable without a live model — so the one case that matters most
         ;; here, "a proposal is a document and nothing acts on it", could not
         ;; have been written at all.
         current-feed-chat propose!
         ;; exported FOR the tests, which is what makes these rules checks
         ;; rather than claims (#110 r4): the vocabulary, the ordering and the
         ;; clamp are the whole of what this plugin decides.
         QUEUE-STATUSES MAX-SKILLS PRIORITY-MIN PRIORITY-MAX
         queue-upsert! queue-rows queue-set-status! clamp-priority normalize-skills)

;; ---- the schema -----------------------------------------------------------------
;; One table, named `x_feeds_…` because the loader enforces that prefix on a
;; plugin's DDL (#121) — a plugin cannot create or alter a core table, and the
;; check is what makes "a list of SQL strings" safe to accept as data.
;;
;; `object_id` is the PRIMARY KEY, which is the dedup rule: re-triaging an item
;; updates its row rather than adding a second. FEED-18 already made a re-poll of
;; an unchanged item write no new version, so the queue inherits that for free.
(define migrations
  (list
   (list "queue"
         (string-append "CREATE TABLE x_feeds_items ("
                        "  object_id TEXT PRIMARY KEY,"
                        "  team_id TEXT NOT NULL,"
                        "  feed_slug TEXT,"
                        "  title TEXT,"
                        "  priority INTEGER NOT NULL,"
                        "  due_epoch BIGINT,"
                        "  status TEXT NOT NULL,"
                        "  skills TEXT,"
                        "  updated_epoch BIGINT NOT NULL)")
         ;; the queue's own ordering, so "the first actionable task" is an index
         ;; scan rather than a sort of the team's whole backlog
         (string-append "CREATE INDEX x_feeds_items_queue ON x_feeds_items"
                        " (team_id, status, priority DESC, due_epoch)")
         "CREATE INDEX x_feeds_items_slug ON x_feeds_items (team_id, feed_slug)")))

;; ---- the vocabulary -------------------------------------------------------------
;; CLOSED, and pinned by the test. The platform's own closed vocabularies
;; (EXTRACT-REASONS, REVIEW-VERDICTS, WORKER-STATES) all earned their members by
;; something behaving differently; these four do too — `open` is offered,
;; `claimed` is somebody's, `done` and `dropped` leave the queue, and only the
;; first two are actionable.
(define QUEUE-STATUSES '("open" "claimed" "done" "dropped"))
(define ACTIONABLE '("open" "claimed"))

;; A priority is an INTEGER and the range is fixed, because the ordering is the
;; feature: an open-ended number invites one caller to pass 10 and another
;; 1,000,000, and then "the first actionable task" depends on who wrote the
;; workflow rather than on what is urgent.
(define PRIORITY-MIN 0)
(define PRIORITY-MAX 100)
(define PRIORITY-DEFAULT 50)

;; Skills are the customer's own words — a routing hint, never interpreted here.
;; Capped so one item cannot carry a paragraph, and stored as a comma-joined
;; string rather than a JSON array, because there is no JSON SQL in both dialects
;; and a `LIKE '%,racket,%'` over a normalized string is a filter both can run.
(define MAX-SKILLS 12)
(define MAX-SKILL-LENGTH 40)

(define (clamp-priority v)
  (cond
    [(not (real? v)) PRIORITY-DEFAULT]
    [else (max PRIORITY-MIN (min PRIORITY-MAX (exact-round v)))]))

;; -> a comma-delimited string with a leading and trailing comma, so a prefix
;; match cannot straddle two skills: ",racket," is in ",racket,ops," and is NOT
;; in ",racketeering,". The `differ`-shaped trap, in SQL.
(define (normalize-skills v)
  (define raw (cond [(list? v) v] [(string? v) (string-split v ",")] [else '()]))
  (define cleaned
    (remove-duplicates
     (for/list ([s (in-list raw)]
                #:when (string? s)
                #:unless (string=? (string-trim s) ""))
       (let ([t (string-downcase (string-trim s))])
         (if (> (string-length t) MAX-SKILL-LENGTH) (substring t 0 MAX-SKILL-LENGTH) t)))))
  (define kept (if (> (length cleaned) MAX-SKILLS) (take cleaned MAX-SKILLS) cleaned))
  (if (null? kept) "" (string-append "," (string-join kept ",") ",")))

(define (skills->list s)
  (if (or (not (string? s)) (string=? s "")) '() (string-split s "," #:trim? #t)))

(define (now) (current-seconds))

;; ---- the index ------------------------------------------------------------------
;; THE DOCUMENT IS AUTHORIZED, NOT THE ROW (QUEUE-3). `repo-get` answers #f for a
;; miss and RAISES on a permission failure, so both are collapsed here into one
;; answer — "not yours or not there" — exactly as the knowledge graph and the
;; worker's document read do. A queue row is a pointer; it confers nothing.
(define (readable conn p object-id)
  (with-handlers ([exn:fail? (lambda (_e) #f)])
    (repo-get conn p object-id)))

(define (queue-upsert! conn p object-id
                       #:priority [priority PRIORITY-DEFAULT]
                       #:due [due #f]
                       #:status [status "open"]
                       #:skills [skills '()]
                       #:who [who 'feed_queue_put])
  (unless (member status QUEUE-STATUSES)
    (error who "~s is not a status this queue has (it offers: ~a)" status (string-join QUEUE-STATUSES ", ")))
  (define o (readable conn p object-id))
  (unless o (error who "no such item: ~a" object-id))
  (define attrs (hash-ref o 'attributes (hasheq)))
  (define slug (let ([v (hash-ref attrs 'feed_slug #f)]) (and (string? v) v)))
  (define title (let ([v (hash-ref o 'filename #f)]) (if (string? v) v (hash-ref o 'key))))
  (define pr (clamp-priority priority))
  (define sk (normalize-skills skills))
  (define team (hash-ref o 'team_id))
  ;; One guarded statement per dialect rather than an ON CONFLICT, because the
  ;; two spell the upsert differently and `db-kit/portable` rewrites parameters,
  ;; not syntax. Delete-then-insert inside no transaction would lose the row on a
  ;; crash between them, so it is UPDATE-then-INSERT-if-nothing-moved: the update
  ;; is idempotent and the insert is the only path that can collide, which the
  ;; PRIMARY KEY then refuses rather than duplicating.
  (define moved
    (query-exec conn
                (string-append "UPDATE x_feeds_items SET team_id = ?, feed_slug = ?, title = ?,"
                               " priority = ?, due_epoch = ?, status = ?, skills = ?, updated_epoch = ?"
                               " WHERE object_id = ?")
                team (or slug sql-null) title pr (or due sql-null) status sk (now) object-id))
  (void moved)
  (unless (positive? (query-value conn "SELECT COUNT(*) FROM x_feeds_items WHERE object_id = ?" object-id))
    (query-exec conn
                (string-append "INSERT INTO x_feeds_items"
                               " (object_id, team_id, feed_slug, title, priority, due_epoch, status, skills, updated_epoch)"
                               " VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)")
                object-id team (or slug sql-null) title pr (or due sql-null) status sk (now)))
  (hasheq 'object_id object-id 'priority pr 'due (or due 'null)
          'status status 'skills (skills->list sk)
          'title title 'feed_slug (or slug 'null)))

;; `#:limit` is clamped here rather than validated, because this is a listing a
;; screen pages through and a caller asking for 10,000 wants the first page, not
;; a refusal. The platform's own listings cap the same way.
(define MAX-LIMIT 200)

(define (queue-rows conn p
                    #:status [status 'actionable]
                    #:slug [slug #f]
                    #:skill [skill #f]
                    #:limit [limit 50]
                    #:offset [offset 0])
  (define team (principal-team-id p))
  (define lim (max 1 (min MAX-LIMIT (if (exact-nonnegative-integer? limit) limit 50))))
  (define off (if (exact-nonnegative-integer? offset) offset 0))
  (define-values (status-clause status-args)
    (cond
      [(eq? status 'all) (values "" '())]
      [(eq? status 'actionable)
       (values (format " AND status IN (~a)" (string-join (map (lambda (_s) "?") ACTIONABLE) ", "))
               ACTIONABLE)]
      [(member status QUEUE-STATUSES) (values " AND status = ?" (list status))]
      [else (error 'feed_queue "~s is not a status this queue has (it offers: ~a, or \"all\")"
                   status (string-join QUEUE-STATUSES ", "))]))
  ;; THE ORDER IS THE FEATURE (QUEUE-4): priority first, then the soonest due
  ;; date, then oldest-known-first. `due_epoch` is NULL for an item with no date
  ;; and the two dialects sort NULLs opposite ways under ASC, so it is
  ;; COALESCE'd to a far horizon — an item with no deadline sorts after one with
  ;; a real deadline rather than before it on one dialect and after on the other.
  (define sql
    (string-append "SELECT object_id, feed_slug, title, priority, due_epoch, status, skills, updated_epoch"
                   " FROM x_feeds_items WHERE team_id = ?"
                   status-clause
                   (if slug " AND feed_slug = ?" "")
                   (if skill " AND skills LIKE ?" "")
                   " ORDER BY priority DESC, COALESCE(due_epoch, 99999999999) ASC, updated_epoch ASC"
                   " LIMIT " (number->string lim) " OFFSET " (number->string off)))
  (define args (append (list team) status-args
                       (if slug (list slug) '())
                       ;; `%,skill,%` — the wildcards are what make it a LIKE at
                       ;; all (without them the pattern is an equality test and
                       ;; every skill filter answers nothing, which is what the
                       ;; unit case found), and the commas are what stop
                       ;; `racket` matching `racketeering`.
                       (if skill (list (format "%,~a,%" (string-downcase (string-trim skill)))) '())))
  ;; AND THEN EVERY ROW IS AUTHORIZED ON ITS DOCUMENT, after the SQL window — the
  ;; same shape as `repo-list`'s per-row `can?`, with the same consequence CLS-27
  ;; recorded: a page can contribute fewer rows than it selected, so the count a
  ;; caller sees is "what you may read", never "what is there".
  (for*/list ([r (in-list (apply query-rows conn sql args))]
              [o (in-value (readable conn p (vector-ref r 0)))]
              #:when o)
    (hasheq 'object_id (vector-ref r 0)
            'key (hash-ref o 'key)
            'feed_slug (nz (vector-ref r 1))
            'title (nz (vector-ref r 2))
            'priority (vector-ref r 3)
            'due (nz (vector-ref r 4))
            'status (vector-ref r 5)
            'skills (skills->list (let ([s (vector-ref r 6)]) (if (string? s) s "")))
            'updated_epoch (vector-ref r 7)
            'attributes (hash-ref o 'attributes (hasheq)))))

(define (nz v) (if (sql-null? v) 'null v))

;; Changing a status is the one WRITE a person does from the screen, and it is
;; guarded on the row's own team as well as on the document — the id is
;; instance-global, so without the team clause a caller could name another
;; company's row and learn whether it exists (`org-team-resolve`'s lesson).
(define (queue-set-status! conn p object-id status #:who [who 'feed_queue_status])
  (unless (member status QUEUE-STATUSES)
    (error who "~s is not a status this queue has (it offers: ~a)" status (string-join QUEUE-STATUSES ", ")))
  (unless (readable conn p object-id) (error who "no such item: ~a" object-id))
  (define moved
    (query-value conn
                 (string-append "SELECT COUNT(*) FROM x_feeds_items"
                                " WHERE object_id = ? AND team_id = ?")
                 object-id (principal-team-id p)))
  (unless (positive? moved) (error who "no such item: ~a" object-id))
  (query-exec conn "UPDATE x_feeds_items SET status = ?, updated_epoch = ? WHERE object_id = ? AND team_id = ?"
              status (now) object-id (principal-team-id p))
  (hasheq 'object_id object-id 'status status))

;; ---- tools ----------------------------------------------------------------------
(define (obj-schema name desc props required)
  (hasheq 'type "function"
          'function (hasheq 'name name 'description desc
                            'parameters (hasheq 'type "object" 'properties props 'required required))))

(define queue-put-schema
  (obj-schema
   "feed_queue_put"
   (string-append "Put a pulled feed item on the team's work queue, or update it: priority (0-100), "
                  "an optional due date in epoch seconds, a status and a list of skills. The queue is "
                  "an INDEX over the documents, so this records what triage decided rather than deciding it.")
   (hasheq 'object (hasheq 'type "string" 'description "The item's repository object id")
           'priority (hasheq 'type "number" 'description "0 (lowest) to 100 (highest); 50 if omitted")
           'due (hasheq 'type "number" 'description "When it is due, epoch seconds")
           'status (hasheq 'type "string" 'enum QUEUE-STATUSES 'description "Defaults to open")
           'skills (hasheq 'type "array" 'items (hasheq 'type "string")
                           'description "Routing hints in the team's own words, e.g. [\"racket\",\"ops\"]"))
   '("object")))

(define (tool-queue-put conn p args)
  (define id (let ([v (hash-ref args 'object #f)]) (if (string? v) v (error 'feed_queue_put "object is required"))))
  (queue-upsert! conn p id
                 #:priority (let ([v (hash-ref args 'priority #f)]) (if (real? v) v PRIORITY-DEFAULT))
                 #:due (let ([v (hash-ref args 'due #f)]) (and (real? v) (exact-round v)))
                 #:status (let ([v (hash-ref args 'status #f)]) (if (string? v) v "open"))
                 #:skills (hash-ref args 'skills '())))

(define queue-status-schema
  (obj-schema "feed_queue_status"
              "Move a queued item to another status: open, claimed, done or dropped."
              (hasheq 'object (hasheq 'type "string" 'description "The item's repository object id")
                      'status (hasheq 'type "string" 'enum QUEUE-STATUSES 'description "The new status"))
              '("object" "status")))

(define (tool-queue-status conn p args)
  (queue-set-status! conn p
                     (let ([v (hash-ref args 'object #f)]) (if (string? v) v (error 'feed_queue_status "object is required")))
                     (let ([v (hash-ref args 'status #f)]) (if (string? v) v (error 'feed_queue_status "status is required")))))

;; ---- slice 6: a proposal, which is NOT an act -----------------------------------
;; FEED-10, confirmed by the owner on 27 Oct 2026 (question 3 on #114): the agent
;; PROPOSES and a `review` step gates anything that would act. Two things this
;; tool deliberately is not:
;;
;;   * It does not act, and there is no acting tool in v1. Nothing prevented one
;;     before this slice — `register-tool!` takes any handler — so the
;;     requirement was never to build the capability but to govern it.
;;   * It writes a DOCUMENT, not a row. A proposal is the kind of thing somebody
;;     reads, disagrees with and keeps; `<key>.proposal.md` derived from the item
;;     means "Processed by" finds it, the derivation row says which item it is
;;     about, and it inherits the item's visibility from its first byte.
(define PROPOSAL-SYSTEM
  (string-append
   "You triage work items for an operations team. You are given one item as JSON. "
   "Reply with a short Markdown proposal of at most 200 words, in three sections: "
   "'## What this is' (one or two sentences), '## Proposed action' (what a person or a "
   "script should do, concretely), and '## Why this and not something else' (the "
   "alternative you rejected). Propose only what the item itself supports. If the item "
   "does not say enough to act on, say so under 'Proposed action' and name what is "
   "missing. Never claim to have done anything — you are proposing."))

(define PROPOSAL-CAP 20000)

;; (chat prompt #:system sys #:conn c #:team t) -> (values reply tokens).
;; Temperature 0: a triage proposal wants the likeliest reading, not a creative
;; one. KG-7's rule applies — bulk work goes to the team's `utility` executor
;; when one is set — and with neither that nor a local model the refusal names
;; both, because "the reply was empty" is not what an operator needs to read.
(define (default-feed-chat prompt #:system [sys #f] #:conn [conn #f] #:team [team #f])
  (define ex (and conn team (model-role-executor conn team "utility")))
  (unless (or ex (model-configured?))
    (error 'feed_propose "no model configured — set TMACH_MODEL_URL, or a utility executor in Model roles"))
  (run-chat prompt #:system sys #:temperature 0 #:executor ex))

(define current-feed-chat (make-parameter default-feed-chat))

(define propose-schema
  (obj-schema "feed_propose"
              (string-append "Read a pulled feed item and write a PROPOSAL about what to do with it, "
                             "as a document beside the item. It proposes only — nothing acts on the "
                             "proposal until a person decides, which is what the review step in the "
                             "feed-propose workflow is for.")
              (hasheq 'object (hasheq 'type "string" 'description "The item's repository object id")
                      'run (hasheq 'type "string" 'description "The workflow run id, for provenance")
                      'step (hasheq 'type "string" 'description "The workflow step id, for provenance"))
              '("object")))

(define (propose! conn p args)
  (require-perm conn p "chat:use")
  (define id (let ([v (hash-ref args 'object #f)]) (if (string? v) v (error 'feed_propose "object is required"))))
  (define o (readable conn p id))
  (unless o (error 'feed_propose "no such item: ~a" id))
  (define-values (_o in) (repo-open conn p id))
  (unless in (error 'feed_propose "no such item: ~a" id))
  (define body
    (let ([s (dynamic-wind void (lambda () (port->string in)) (lambda () (close-input-port in)))])
      (if (> (string-length s) PROPOSAL-CAP) (substring s 0 PROPOSAL-CAP) s)))
  (define-values (reply tokens)
    ((current-feed-chat) (format "Item ~a:\n\n~a" (hash-ref o 'key) body)
                         #:system PROPOSAL-SYSTEM #:conn conn #:team (principal-team-id p)))
  (when (string=? (string-trim reply) "")
    (error 'feed_propose "the model returned an empty proposal"))
  ;; The tools meter themselves at both tiers, as every other model-backed tool
  ;; does — the scheduler bills a job's top-level tokens and a tool step's result
  ;; sits under `result`.
  (with-handlers ([exn:fail? void])
    (tenant-quota-record! conn #:team-id (principal-team-id p)
                          #:dimension "ai.tokens.total" #:amount (or tokens 0)))
  (define text
    (string-append "# Proposal for " (hash-ref o 'key) "\n\n"
                   "> A PROPOSAL, not an action. Nothing has been done to anything outside this\n"
                   "> instance. The review step on this run is what decides whether it happens.\n\n"
                   (string-trim reply) "\n"))
  (define doc (repo-derive! conn p o
                            #:key (string-append (hash-ref o 'key) ".proposal.md")
                            #:bytes (string->bytes/utf-8 text)
                            #:content-type "text/markdown"
                            #:run (let ([v (hash-ref args 'run #f)]) (and (string? v) v))
                            #:step (let ([v (hash-ref args 'step #f)]) (and (string? v) v))))
  ;; AUDITED AS A PROPOSAL, with the item named. The audit log is the record
  ;; (DEL-7 keeps it through an erasure), and "a machine proposed something about
  ;; this item" is exactly the entry somebody auditing an action later wants to
  ;; find. The team is the ITEM's, not the caller's acting team — the ninth
  ;; appearance of that `#:team-id` shape.
  (with-handlers ([exn:fail? (lambda (_e) (void))])
    (audit! conn #:action "feed.proposal.written" #:result "ok"
            #:resource-type "repo" #:resource-id id
            #:team-id (hash-ref o 'team_id)
            #:actor-type "user" #:actor-id (principal-user-id p)))
  (hasheq 'object_id (hash-ref doc 'id) 'key (hash-ref doc 'key)
          'version_id (hash-ref doc 'version_id)
          'proposal text 'item id 'acted #f))

(define tools
  (list (list "feed_queue_put"    queue-put-schema    "files:read" tool-queue-put)
        (list "feed_queue_status" queue-status-schema "files:read" tool-queue-status)
        (list "feed_propose"      propose-schema      "chat:use"   propose!)))

;; ---- routes ---------------------------------------------------------------------
;; Mounted at /api/x/feeds/… — the prefix is platform-fixed, so this can shadow
;; neither a core route nor another plugin's.
(define (route-queue conn p args)
  (define q (hash-ref args 'query))
  (define (qs k) (let ([v (hash-ref q k #f)]) (and (string? v) (not (string=? v "")) v)))
  (define status (let ([s (qs 'status)]) (cond [(not s) 'actionable] [(equal? s "all") 'all] [else s])))
  (unless (or (symbol? status) (member status QUEUE-STATUSES))
    (raise-user-error 'feed_queue (format "unknown status ~s — it offers: ~a, or \"all\""
                                          status (string-join QUEUE-STATUSES ", "))))
  (define rows (queue-rows conn p
                           #:status status
                           #:slug (qs 'feed)
                           #:skill (qs 'skill)
                           #:limit (or (string->number (or (qs 'limit) "")) 50)
                           #:offset (or (string->number (or (qs 'offset) "")) 0)))
  (hasheq 'items rows 'count (length rows)
          'statuses QUEUE-STATUSES
          'priority (hasheq 'min PRIORITY-MIN 'max PRIORITY-MAX)
          ;; the ordering is REPORTED rather than left to be inferred from the
          ;; rows, because "the first actionable task" is a promise about the
          ;; first element and a reader cannot see a sort
          'order "priority DESC, due ASC, oldest first"))

(define (route-status conn p args)
  (define id (hash-ref (hash-ref args 'params) 'id #f))
  (unless (string? id) (raise-user-error 'feed_queue_status "an item id is required"))
  (define b (hash-ref args 'body))
  (define status (and (hash? b) (let ([v (hash-ref b 'status #f)]) (and (string? v) v))))
  (unless status (raise-user-error 'feed_queue_status "status is required"))
  (unless (member status QUEUE-STATUSES)
    (raise-user-error 'feed_queue_status (format "unknown status ~s — it offers: ~a"
                                                 status (string-join QUEUE-STATUSES ", "))))
  (with-handlers ([exn:fail? (lambda (e) (raise-user-error 'feed_queue_status (exn-message e)))])
    (queue-set-status! conn p id status)))

(define routes
  (list (list "GET"  "/queue" "files:read"
              route-queue
              "The team's feed work queue, ordered by priority then soonest due date. ?status= open|claimed|done|dropped|all (default: the actionable two), ?feed= a feed slug, ?skill= one skill, ?limit=/?offset=. Every row is re-authorized on the document it points at, so the count is what the caller may read rather than what is there.")
        (list "POST" "/items/:id/status" "files:read"
              route-status
              "Move one queued item to another status: {\"status\": \"claimed\"}. Guarded on the row's own team as well as the document, because an object id is instance-global.")))

;; ---- workflows ------------------------------------------------------------------
;; Hand-written specs in the WIRE grammar rather than `define-workflow`, because
;; the macro lives in a core module and a plugin's spec is validated by the same
;; `validate-spec` either way (WF-9: the data spec is the contract).
(define triage-workflow
  (hasheq
   'spec 1 'slug "feed-triage" 'version 1
   'name "Triage a pulled feed item"
   'description "Put one pulled item on the work queue with a priority, a due date and skills. The queue is an index: this records what triage decided."
   'input (hasheq 'object_id "string" 'priority "number" 'due "number" 'skills "array")
   'steps (list (hasheq 'id "queue" 'uses "tool:feed_queue_put"
                        'with (hasheq 'object "${input.object_id}"
                                      'priority "${input.priority}"
                                      'due "${input.due}"
                                      'skills "${input.skills}")
                        'end #t))))

;; THE REVIEW STEP IS THE WHOLE POINT OF THIS SPEC (FEED-10). The proposal is
;; written, then the run PARKS on a person — a `review` step writes no job, so a
;; parked run holds no concurrency slot however long the specialist takes — and
;; every verdict ends the run, because v1 has nothing that acts. When an acting
;; tool exists it goes on the `approve` branch and nowhere else.
;;
;; FOUR EYES IS OFF, and that is LAY-3 working rather than a shortcut: the
;; subject is model-produced, so it has no human author and anyone with
;; `reviews:decide` may decide it. With the flag on, the run's initiator would be
;; named as author and then refused, so on a team of one the run could never
;; finish. A team with real reviewers adds the flag to its own copy.
(define propose-workflow
  (hasheq
   'spec 1 'slug "feed-propose" 'version 1
   'name "Propose what to do about a feed item"
   'description "An agent reads one pulled item and writes a proposal beside it; the run then parks on a person. Nothing acts on the proposal — v1 has no acting tool, and when it has one it goes on the approve branch."
   'input (hasheq 'object_id "string")
   'steps (list
           (hasheq 'id "propose" 'uses "tool:feed_propose"
                   'with (hasheq 'object "${input.object_id}"
                                 'run "${run.id}" 'step "propose"))
           (hasheq 'id "decide" 'uses "review"
                   'title "Should we do what this proposal says?"
                   'of "${steps.propose.output.proposal}"
                   'instructions (string-append
                                  "This is a PROPOSAL written by a model about one pulled item. "
                                  "Nothing has happened yet and nothing will happen automatically. "
                                  "Approve it if you intend to carry it out; send it back with a "
                                  "rationale if the proposal is close but wrong; reject it if the "
                                  "item should not be acted on at all. Your decision is recorded in "
                                  "the review chain either way.")
                   'checklist (list (hasheq 'key "plan" 'label "What you will actually do, if that differs" 'required #f))
                   'on (hasheq 'approve 'null 'revise "propose" 'reject 'null)))))

(define workflows (list triage-workflow propose-workflow))

(define (init!) (void))
