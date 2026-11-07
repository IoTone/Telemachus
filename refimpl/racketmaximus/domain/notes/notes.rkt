#lang racket/base

;; domain/notes/notes.rkt — the first ownable resource, end to end through RBAC.
;; Every operation is authorized with the AuthzService: team-visibility, private
;; (owner-only), and shared (explicit resource_grants) all flow through `can?` /
;; `require-perm`. Functions raise exn:fail:forbidden on deny (→ 403) and return
;; #f on not-found (→ 404).

(require db-kit/portable racket/list racket/string
         "../db/id.rkt"
         "org-links.rkt"
         "org-file.rkt"
         "../authz/authz.rkt")

(provide notes-create notes-list notes-count notes-get notes-update notes-delete notes-share
         ;; tags (#245) — exported for the tool, the endpoint and their tests
         notes-set-tags! notes-tag-list note-tags notes-require-write!
         tag-normalize tag-problem tags-clean MAX-TAGS MAX-TAG-CHARS
         ;; org-mode (#246 slice 1) — the closed vocabulary and its one check,
         ;; exported FOR the endpoint and the gate that pins the set as a whole
         NOTE-FORMATS format-problem
         ;; links (#246 slice 2) — exported for the endpoint and its tests
         note-links-of note-backlinks-of
         ;; the graph (#247 / ORG-13…16) — the read, its bounds and the closed
         ;; vocabulary of ways it stops, exported for the endpoint and the gate
         note-graph NOTE-GRAPH-MAX NOTE-GRAPH-DEPTH-MAX NOTE-GRAPH-STOPS
         ;; the `.org` interchange (#246 slice 3) — the endpoint composes and
         ;; parses through these, and ORG-12's refusal has one spelling
         notes-import org-text-of ORG-TAGS-REFUSAL notes-tags-writable!)

;; ---- the body's format (#246, ORG-1) ----------------------------------------
;;
;; A CLOSED VOCABULARY, in the shape `READ-DOORS`, `WORKER-STATES`,
;; `EXTRACT-REASONS` and `REVIEW-VERDICTS` already have: the console switches on
;; it and the renderer is picked from it, so a value invented in passing would
;; arrive as a note nothing can draw. `test/note-format-tests.rkt` pins the SET
;; as a literal rather than re-deriving it — a test built from this list would
;; agree with any change to it, and adding a format is a decision somebody makes
;; on purpose.
;;
;; `markdown` is FIRST because it is the default, and that order is read: the
;; column's default and this list's head must agree, or a note created with no
;; format would carry one the vocabulary leads with somewhere else.
(define NOTE-FORMATS '("markdown" "org"))

;; Refused BY NAME, never coerced to the default. A format silently substituted
;; is a note that renders as something other than what its author asked for, and
;; the author has no way to find out but to look — the call an unknown theme
;; token, an unknown classifier backend and an unknown retention field all make.
(define (format-problem fmt)
  (cond [(not (string? fmt)) "format must be a string"]
        [(member fmt NOTE-FORMATS) #f]
        [else (format "format must be one of ~a; got ~s"
                      (string-join NOTE-FORMATS ", ") fmt)]))

(define (format-clean fmt)
  (define problem (format-problem fmt))
  (when problem (raise-user-error 'notes problem))
  fmt)

;; ---- tags (#245) ------------------------------------------------------------
;;
;; TAG-3 — A TAG IS NORMALIZED, AND THE NORMALIZED FORM IS WHAT IS STORED.
;; LAY-4's `field-key?` is the other vocabulary in this tree and it is the wrong
;; one here: `^[a-z][a-z0-9_]{0,39}$` cannot express a Japanese tag, and the
;; console ships `ja`. The right precedent is the knowledge graph's dedup rule
;; (`normalize-name`: downcase, collapse whitespace) minus its company-suffix
;; list, which is about organizations rather than words in general.
;;
;; It is stored normalized rather than kept as typed and folded at read time,
;; because a tag is a FILTER KEY and not prose. That is CLS-15's lesson arriving
;; at a third asker: "Invoice", "invoices" and a trailing space are each one
;; keystroke from a label that no filter will ever match. Case is the whole of
;; what is lost, and no language this console ships has a case distinction that
;; carries meaning in a tag.
(define MAX-TAGS 20)          ; per note
(define MAX-TAG-CHARS 48)

;; ONE RULE, TWO ASKERS, and #246 is the second one. A tag and an org link's
;; target are the same question — a human-typed string matched case- and
;; whitespace-insensitively — so the implementation lives in `org-links.rkt`,
;; which has no dependencies and can therefore be required by both. TAG-3's
;; reasoning is unchanged and the behaviour is byte-identical: the cases in
;; `note-tags-tests.rkt` that pin this function's outputs are what says so.
(define (tag-normalize s) (fold-key s))

;; A control character cannot survive a round trip through a URL query, a CSV or
;; a console attribute, so it is refused rather than stripped — stripping would
;; silently store a different tag from the one somebody asked for. Checked with
;; a character walk rather than a regexp: this file would otherwise be the fourth
;; place in the tree to pay for a `pregexp` escape (`\u0000-\u001f` in a Racket
;; string literal is read before the pattern ever compiles).
(define (has-control? s)
  (for/or ([ch (in-string s)]) (or (char<? ch #\space) (char=? ch #\rubout))))

(define (tag-problem raw)
  (define t (tag-normalize raw))
  (cond [(string=? t "") "a tag cannot be empty"]
        [(has-control? t) "a tag cannot contain control characters"]
        [(> (string-length t) MAX-TAG-CHARS)
         (format "a tag is at most ~a characters" MAX-TAG-CHARS)]
        [else #f]))

;; The ONE place a caller's tags become the tags that get stored (TAG-4). Create,
;; update and the AI tool all come through here, so there is one normalization
;; rule rather than three that drift — and a drift here is two spellings of one
;; tag, which is the exact failure the normalization exists to prevent.
;; Refuses by NAME: a tag silently dropped is a filter that silently never
;; matches, which is the hardest thing on this surface to diagnose.
(define (tags-clean raws)
  (unless (list? raws)
    (raise-user-error 'notes "tags must be a list of strings"))
  (define cleaned
    (for/list ([r (in-list raws)])
      (define problem (tag-problem r))
      (when problem (raise-user-error 'notes (format "tag ~s: ~a" (format "~a" r) problem)))
      (tag-normalize r)))
  (define uniq (sort (remove-duplicates cleaned) string<?))
  (when (> (length uniq) MAX-TAGS)
    (raise-user-error 'notes
      (format "a note carries at most ~a tags; ~a given" MAX-TAGS (length uniq))))
  uniq)

;; one note's tags, sorted — the stored order is not meaningful, so it is made
;; deterministic here rather than left to the engine's
(define (note-tags conn id)
  (for/list ([r (in-list (query-rows conn "SELECT tag FROM note_tags WHERE note_id = ? ORDER BY tag" id))])
    (vector-ref r 0)))

;; every tag in a team, as note_id -> (tag ...). One query per team rather than
;; one per note: the listing already loads the team's rows and filters them in
;; Racket, so this is the same order of work and needs no IN clause built from a
;; list — "a conditional clause with a fixed argument list" is a bug this tree
;; has paid for four times.
(define (team-tag-index conn team)
  (define h (make-hash))
  (for ([r (in-list (query-rows conn "SELECT note_id, tag FROM note_tags WHERE team_id = ? ORDER BY tag DESC" team))])
    (hash-update! h (vector-ref r 0) (lambda (xs) (cons (vector-ref r 1) xs)) '()))
  h)

;; the raw write. `ON CONFLICT DO NOTHING` is what makes a tag idempotent per
;; note, so 'add needs no read-then-write and two callers racing cannot produce a
;; duplicate — the shape `grant!` and the plugin materializer already use, and
;; legal on both dialects.
(define (write-tags! conn id team tags)
  (for ([tg (in-list tags)])
    (query-exec conn
      (string-append "INSERT INTO note_tags (note_id, team_id, tag) VALUES (?, ?, ?) "
                     "ON CONFLICT (note_id, tag) DO NOTHING")
      id team tg)))

(define (with-tags conn n) (hash-set n 'tags (note-tags conn (hash-ref n 'id))))

(define SELECT
  (string-append "SELECT id, team_id, owner_user_id, visibility, title, body, "
                 "created_at, updated_at, format FROM notes"))

(define (row->note r)
  (hasheq 'id (vector-ref r 0) 'team_id (vector-ref r 1) 'owner_user_id (vector-ref r 2)
          'visibility (vector-ref r 3) 'title (vector-ref r 4) 'body (vector-ref r 5)
          'created_at (vector-ref r 6) 'updated_at (vector-ref r 7)
          ;; ORG-1 — on EVERY read, so a reader never has to assume which
          ;; renderer a note wants. RED-20's shape: the field is reported rather
          ;; than inferred, which is also what makes a default of 'markdown'
          ;; honest rather than quiet.
          'format (vector-ref r 8)))

(define (note->resource n)
  (hasheq 'resource_type "notes" 'resource_id (hash-ref n 'id)
          'team_id (hash-ref n 'team_id) 'owner_user_id (hash-ref n 'owner_user_id)
          'visibility (hash-ref n 'visibility)))

;; ---- ORG-12: for an org note the BODY is the source of truth for tags -------
;;
;; `#+FILETAGS:` is authoritative, and a `tags` field in a request against an org
;; note is REFUSED BY NAME rather than stored or silently ignored. Two homes for
;; one fact is the drift this tree names everywhere, and the home that must win
;; is the one the author can SEE — the body they are editing. A hand-edited
;; `#+FILETAGS:` line that did nothing would be worse than a refusal, and a
;; `tags` write that the next body save quietly undid would be worse still.
;;
;; THE COST IS REAL AND IS STATED RATHER THAN DISCOVERED: #245's `note_autotag`
;; cannot work on an org note, because its write path is `notes-set-tags!`. It
;; refuses here, in the one place both the tool and the endpoint reach, and the
;; message carries the remedy. A tool that rewrote the body's keyword line is the
;; obvious next decision and is not this slice's.
(define ORG-TAGS-REFUSAL
  (string-append "this note is org, so its tags come from its own #+FILETAGS: line; "
                 "edit that line in the body, or set format to markdown first"))

(define (refuse-org-tags!) (raise-user-error 'notes ORG-TAGS-REFUSAL))

;; "May this caller write this note's tags DIRECTLY?", asked on its own so a
;; caller can find out BEFORE doing something expensive. `notes-set-tags!` asks
;; the same question at the write — this is not a second copy of the rule, it is
;; the same refusal reachable one step earlier, which is exactly what
;; `notes-require-write!` exists for and for the same reason: #245's auto-tagger
;; puts a MODEL CALL between the read and the write, and without this an org note
;; spends the team's AI budget and is only then refused, with a message about
;; its format rather than about what it was asked to do.
(define (notes-tags-writable! conn id)
  (define r (get-row conn id))
  (when (and r (string=? (vector-ref r 8) "org")) (refuse-org-tags!))
  #t)

;; The tags a body ASSERTS, or #f when it asserts nothing. The absent/present
;; split is `org-file.rkt`'s and it is what stops a conversion from eating a tag
;; set: a body with no keyword line is not a body saying "no tags".
;;
;; `tags-clean` is TAG-4's one home, so an imported or hand-typed `#+FILETAGS:`
;; normalizes exactly as a tag typed into the console does — and a malformed one
;; refuses the write, with the keyword named so the author knows which line to
;; look at.
;; `fmt`, NOT `format`: this function formats its own refusal, and a parameter
;; called `format` shadows the procedure — which fails as "application: not a
;; procedure; given: \"org\"" on the one path that composes a message, i.e. only
;; when something is already wrong.
(define (clean-filetags raws)
  (with-handlers ([exn:fail? (lambda (e)
                               (raise-user-error 'notes
                                 (format "#+FILETAGS:: ~a" (exn-message e))))])
    (tags-clean raws)))

(define (body-tags body fmt)
  (and (string=? fmt "org")
       (let-values ([(_t tags _b) (org-parse body)])
         (and tags (clean-filetags tags)))))

(define (get-row conn id) (query-maybe-row conn (string-append SELECT " WHERE id = ?") id))

;; `#:filetags` IS NOT A SECOND HOME FOR TAGS AND THAT IS THE WHOLE POINT. ORG-12
;; refuses `#:tags` against an org note because the body is the truth; an IMPORT
;; read a real `#+FILETAGS:` line and is handing over exactly what that line
;; said, so it is the same home reached from a file rather than from the stored
;; body. It has to exist because `notes-import` STRIPS the keyword block to keep
;; ORG-11's byte-identical body — so by the time the create runs, the line that
;; carried the tags is no longer in the body for `body-tags` to find.
;;
;; `#f` means the file asserted nothing, which is what leaves an imported note
;; untagged rather than clearing anything.
;;
;; THE E2E GATE IS WHAT FOUND THIS, and the unit test had passed for the wrong
;; reason: its fixture's body still carried a `#+FILETAGS:` line of its own, so
;; the composed one being dropped went unnoticed while `body-tags` re-read the
;; author's. A fixture whose body has no keyword line is what makes the case real.
(define (notes-create conn p #:title [title ""] #:body [body ""] #:visibility [vis "team"]
                      #:tags [tags '()] #:format [fmt "markdown"] #:filetags [filetags #f])
  (require-perm conn p "notes:write")                       ; team-level create
  ;; cleaned BEFORE the note exists, so a malformed tag refuses the whole create
  ;; rather than leaving a note somebody has to notice is untagged (VEC-21's
  ;; order, where every validation runs before anything is written). The format
  ;; joins it for the same reason: a note stored with a format nothing can draw
  ;; is worse than a create that was refused.
  (define fmt* (format-clean fmt))
  ;; ORG-12 — refused BEFORE anything is validated or written. An empty list asks
  ;; for nothing, so there is nothing to refuse: `#:tags` defaults to `'()` and
  ;; the endpoint maps an absent key to it, which means a caller who said nothing
  ;; about tags is indistinguishable from one who sent `[]` on this path.
  (when (and (string=? fmt* "org") (pair? tags)) (refuse-org-tags!))
  (define clean (or (and filetags (clean-filetags filetags))
                    (body-tags body fmt*)
                    (tags-clean tags)))
  (define id (new-id))
  ;; ORG-7 — the edges are rewritten in the same transaction as the BODY, or a
  ;; note could exist with a body nothing had read the links out of. The row
  ;; count is also validated in there (`write-links!` refuses past
  ;; MAX-NOTE-LINKS), so a note with too many links leaves nothing behind.
  (call-with-transaction conn
    (lambda ()
      (query-exec conn
        (string-append "INSERT INTO notes (id, team_id, owner_user_id, visibility, title, body, format) "
                       "VALUES (?, ?, ?, ?, ?, ?, ?)")
        id (principal-team-id p) (principal-user-id p) vis title body fmt*)
      (write-links! conn id (principal-team-id p) body fmt*)))
  (write-tags! conn id (principal-team-id p) clean)
  (with-tags conn (row->note (get-row conn id))))

;; ---- the listing's window (#245's filter, and the page) ----------------------
;;
;; ONE HOME FOR THE WINDOW, asked by the listing AND by the count. Two spellings
;; of "which notes are in scope" is LIVE-IN's drift in the one place where the
;; symptom is a pager offering a page the listing can never fill, so
;; `notes-window` composes the WHERE clause and its arguments once and each
;; caller appends its own tail.
;;
;; THE TAG FILTER IS IN SQL NOW, AND TAG-5's RULE IS UNCHANGED BY THAT. That rule
;; is that a filter may only narrow what the caller was already allowed to see,
;; never widen it — and `can?` still runs on every row this window returns, so
;; the result set is identical whichever order two NARROWING tests are applied
;; in. What moving it buys is the only thing pagination needs: the window itself
;; is filtered, so a page of a tag search comes back full rather than being
;; whatever survived of twenty-five unfiltered rows. It is an indexed equality on
;; `idx_note_tags_note`, which is not what PERF-5 measured and declined — that
;; finding was a `LIKE` with a LEADING wildcard over bodies, which cannot use its
;; index at all. Several tags are an AND, one EXISTS each.
(define (notes-window teams wanted)
  (values (string-append
           "WHERE team_id IN (" (string-join (for/list ([_ teams]) "?") ",") ") "
           (apply string-append
                  (for/list ([_ wanted])
                    (string-append
                     "AND EXISTS (SELECT 1 FROM note_tags nt "
                     "WHERE nt.note_id = notes.id AND nt.tag = ?) "))))
          (append teams wanted)))

(define (scope-teams conn p scope)
  (if (eq? scope 'org)
      (let ([org (or (principal-org-id p) (team-org conn (principal-team-id p)))])
        (if org (org-teams-of conn org) (list (principal-team-id p))))
      (list (principal-team-id p))))

;; #:scope 'org lists across every team in the caller's company (TEN-2h); each row
;; still passes can?, so an org reader sees team-visible notes and nobody's
;; private ones, and a plain member sees exactly what they saw before
;;
;; `#:limit #f` IS UNBOUNDED AND IS THE DEFAULT, which is more than
;; compatibility here: `notes-tag-list` DERIVES the team's tag vocabulary by
;; walking this listing (TAG-1), so a default page would silently shrink that
;; vocabulary to whatever the first page happened to hold — a filter that offers
;; fewer words the more notes a team has. `list_notes` and the out-of-process
;; `notes.list` capability read it whole for the same reason. The ENDPOINT is
;; what asks for a page.
;;
;; THE ORDER CARRIES A TIEBREAK NOW, AND PAGINATION IS WHAT MAKES IT
;; LOAD-BEARING. `created_at` is TEXT `CURRENT_TIMESTAMP` at SECOND resolution
;; and `id` is a random UUID, so notes written in the same second came back in an
;; order unrelated to anything — harmless while every caller read the whole list,
;; and fatal for an offset walk, where an unstable sort shows one note twice and
;; never shows another at all. Issue #47's rule for the audit log (`at DESC,
;; at_us DESC, id DESC`) arriving at the surface where it first becomes
;; observable.
;;
;; AND IT IS ONE QUERY ACROSS THE TEAMS, NOT ONE PER TEAM APPENDED. The old shape
;; ran an ordered query per team and `append*`ed the results, so `?scope=org`
;; came back team-by-team rather than newest-first. That was true before this
;; change and was merely untidy, because nothing paged; an OFFSET into a list
;; that is not globally ordered names a different row on every request, so the
;; ordering had to become real for the window to mean anything.
(define (notes-list conn p #:scope [scope 'team] #:tags [want '()]
                    #:limit [limit #f] #:offset [offset 0])
  ;; the team-level read first, like repo-list: a token scoped without notes:read
  ;; is refused here rather than handed an empty list that looks like "no notes"
  (require-perm conn p "notes:read")
  (define teams (scope-teams conn p scope))
  (define wanted (tags-clean want))
  (define-values (where args) (notes-window teams wanted))
  (define rows
    (apply query-rows conn
           (string-append SELECT " " where "ORDER BY created_at DESC, id DESC"
                          (if limit " LIMIT ? OFFSET ?" ""))
           (append args (if limit (list limit offset) '()))))
  ;; one tag read per team, merged — see team-tag-index
  (define idx
    (for/fold ([h (hash)]) ([t (in-list teams)])
      (for/fold ([h h]) ([(k v) (in-hash (team-tag-index conn t))]) (hash-set h k v))))
  ;; CLS-27 — `can?` runs per row AFTER the window, so a PAGE may come back
  ;; shorter than its limit with notes still behind it. That is why the count
  ;; below is the pager's authority and the length of this list is not.
  (for/list ([r (in-list rows)]
             #:when (can? conn p "notes:read" #:resource (note->resource (row->note r))))
    (let ([n (row->note r)])
      (hash-set n 'tags (hash-ref idx (hash-ref n 'id) '())))))

;; THE SAME WINDOW WITHOUT THE `can?` FILTER — `repo-count`'s precedent, and its
;; stated limitation with it. It is a count and no identity, within the caller's
;; own scope and behind the same permission, and it exists because CLS-27's rule
;; means the LENGTH of a page cannot answer "how many pages are there": a page
;; emptied by a colleague's private notes would read as the end of the list. So
;; the total may exceed what the caller can ever see, and the last page may come
;; back short or even empty — which is honest, since there really are rows there
;; and they are not theirs, and it is what lets a numbered pager offer the right
;; range at all.
(define (notes-count conn p #:scope [scope 'team] #:tags [want '()])
  (require-perm conn p "notes:read")
  (define-values (where args) (notes-window (scope-teams conn p scope) (tags-clean want)))
  (apply query-value conn (string-append "SELECT COUNT(*) FROM notes " where) args))

(define (notes-get conn p id)
  (define r (get-row conn id))
  (and r (let ([n (row->note r)])
           (require-perm conn p "notes:read" #:resource (note->resource n))
           (with-tags conn n))))

;; `#:tags #f` is ABSENT and `'()` is CLEAR, which is the one place this differs
;; from #239's "blank is absent": a note whose last tag could not be removed
;; would be a field you can fill and never empty. Title/body/visibility keep
;; their own `#f`-is-absent rule, so the endpoint must map a missing JSON key to
;; #f and a `[]` to the empty list deliberately.
(define (notes-update conn p id #:title [title #f] #:body [body #f] #:visibility [vis #f]
                      #:tags [tags #f] #:format [fmt #f])
  (define r (get-row conn id))
  (and r (let ([n (row->note r)])
           (require-perm conn p "notes:write" #:resource (note->resource n))
           ;; cleaned before anything is written, so a malformed tag leaves the
           ;; note — and its previous tag set — exactly as it was
           ;; the EFFECTIVE format decides, so a request that converts to org and
           ;; sends tags in the same breath is refused rather than half-honoured
           (define effective-fmt (or fmt (hash-ref n 'format)))
           (when (and tags (string=? effective-fmt "org")) (refuse-org-tags!))
           (define clean (and tags (tags-clean tags)))
           ;; ORG-2 — CONVERTING A NOTE IS A DECLARATION, NEVER A REWRITE. This
           ;; changes how the body is RENDERED and does not touch the body.
           ;; Running the org renderer over Markdown source produces a readable
           ;; mess rather than an error, which is honest and REVERSIBLE — where
           ;; a conversion is neither, and a conversion that got one construct
           ;; wrong would have eaten the only copy.
           (define fmt* (and fmt (format-clean fmt)))
           (when title (query-exec conn "UPDATE notes SET title = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ?" title id))
           (when vis   (query-exec conn "UPDATE notes SET visibility = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ?" vis id))
           ;; THE BODY AND THE FORMAT BOTH DECIDE THE EDGES, so either one moving
           ;; re-extracts — and both of them do it in ONE transaction with the
           ;; write, which is ORG-7. The format matters because only an org note
           ;; has links at all, so converting org → markdown is what clears the
           ;; rows and markdown → org is what fills them, with no second
           ;; mechanism for either.
           ;;
           ;; The TITLE is deliberately outside this: it changes what OTHER
           ;; notes' links resolve TO, and that is read-time (migration 0074),
           ;; so there is nothing to rewrite.
           (when (or body fmt*)
             (call-with-transaction conn
               (lambda ()
                 (when body (query-exec conn "UPDATE notes SET body = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ?" body id))
                 (when fmt* (query-exec conn "UPDATE notes SET format = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ?" fmt* id))
                 (define b* (or body (hash-ref n 'body)))
                 (define f* (or fmt* (hash-ref n 'format)))
                 (write-links! conn id (hash-ref n 'team_id) b* f*)
                 ;; ORG-12 — the body's own keyword line is authoritative on
                 ;; EVERY write, in the same transaction as the body, or a
                 ;; refused tag would leave a body claiming tags nothing stored.
                 ;; `#f` means the body asserted nothing, which is what leaves a
                 ;; converted note's existing tags alone.
                 (let ([bt (body-tags b* f*)])
                   (when bt
                     (query-exec conn "DELETE FROM note_tags WHERE note_id = ?" id)
                     (write-tags! conn id (hash-ref n 'team_id) bt))))))
           (when clean
             (call-with-transaction conn
               (lambda ()
                 (query-exec conn "DELETE FROM note_tags WHERE note_id = ?" id)
                 (write-tags! conn id (hash-ref n 'team_id) clean))))
           (with-tags conn (row->note (get-row conn id))))))

;; ---- the edges a note's body declares (#246 slice 2) ------------------------
;;
;; ORG-7 — EXTRACTED ON WRITE, RESOLVED ON READ, and migration 0074's own header
;; is where the reasoning for the split lives. What the table holds is the target
;; AS WRITTEN plus its fold, written once and never rewritten; what a read does
;; is match that against the team's notes, which is an indexed equality rather
;; than the leading-wildcard `LIKE` over bodies that PERF-5 measured.
;;
;; ONLY AN ORG NOTE HAS LINKS. `[[target][description]]` is org syntax, and
;; Markdown wiki-links were DECLINED as a product question (RG-5's parked note,
;; which #246 answered for org and not for Markdown). So a Markdown note extracts
;; to nothing — which is also what makes converting org → markdown clear the
;; rows, with no second mechanism.

;; The team's notes, once, as the two things a read needs: what a fold resolves
;; to, and what `can?` needs to decide about the note at the far end.
;;
;; THE BOUND IS THE TEAM'S NOTE COUNT and it is stated rather than hidden: this
;; is one indexed scan of five small columns per links read. ORG-16 caps the
;; graph at a few dozen nodes anyway, and the alternative — a `lower(title)` join
;; in SQL — is what this deliberately does not do, because the two dialects do
;; not fold non-ASCII the same way and this console ships `ja`.
;; 🔑 THE INDEX IS THE CALLER'S OWN VIEW OF THE TEAM, AND THAT IS WHERE ORG-9 IS
;; ENFORCED — not in a branch further down.
;;
;; It held every note in the TEAM, and resolution ran against all of them, which
;; defeated ORG-9 through the one channel it had not been read against: ORG-8's
;; report is the BASELINE, so SILENCE is itself a signal. Measured, on a team
;; where root owns a private note titled "Secret Plan" and bob owns neither:
;;
;;   bob's `[[Secret Plan]]`   → ()                              — nothing at all
;;   bob's `[[No Such Thing]]` → broken, reason "missing"
;;
;; So bob learns from the ABSENCE of a report that a note with that title exists
;; in his team and is not his. And the second order is worse, because it does not
;; even need the comparison: once bob creates his OWN note titled "Secret Plan",
;; his link answers `ambiguous`, which affirmatively states that there is another
;; note of that title he cannot see.
;;
;; Filtering HERE makes the collapse structural rather than asserted: a target
;; the caller may not read is not in the index, so it resolves exactly as a
;; nonexistent one does, and the caller's own note is the unique holder of its
;; fold in the only view that matters. ORG-10 had already applied this exact rule
;; inside `resolve-target` for a CROSS-TEAM target — "treated exactly as a
;; nonexistent one" — so the fix is that rule reaching the case it was written
;; next to. `repo-get`'s collapse of a refusal and a miss.
;;
;; THE COST IS ONE `can?` PER NOTE IN THE TEAM, stated rather than hidden: both
;; readers already scanned the whole team's notes, and `notes-list` applies
;; per-row `can?` over the same set on every listing, so this is not a new cost
;; class here. A SQL predicate would be faster and would be `can?`'s rule written
;; a second time, which is the drift `repo-readable?` exists to prevent.
(define (team-note-index conn p team)
  (define by-fold (make-hash))
  (define by-id (make-hash))
  (for ([r (in-list (query-rows conn
                      (string-append "SELECT id, team_id, owner_user_id, visibility, title, "
                                     "created_at FROM notes WHERE team_id = ?") team))])
    ;; `created_at` is carried for #247's cap, which has to drop notes in SOME
    ;; order and uses the listing's own (NPG-3). The two link readers ignore it.
    (define n (hasheq 'id (vector-ref r 0) 'team_id (vector-ref r 1)
                      'owner_user_id (vector-ref r 2) 'visibility (vector-ref r 3)
                      'title (vector-ref r 4) 'created_at (vector-ref r 5)))
    (when (readable-note? conn p n)
      (hash-set! by-id (hash-ref n 'id) n)
      (hash-update! by-fold (fold-key (hash-ref n 'title)) (lambda (xs) (cons n xs)) '())))
  (cons by-fold by-id))

;; ORG-6 — a target is a note ID (what a link picker inserts, and what survives a
;; rename) or an exact case-folded TITLE within the team (what a person types).
;;
;; AN AMBIGUOUS TITLE IS A BROKEN LINK THAT SAYS IT IS AMBIGUOUS rather than one
;; of the candidates: titles are not unique, so picking one would make a link
;; mean a different note depending on which was created first. It is also why
;; org-roam links by id.
;;
;; ORG-10 — a CROSS-TEAM target is treated exactly as a nonexistent one, and the
;; index is what makes that true by construction rather than by a check: it holds
;; this team's notes and nothing else, so an id belonging to another team simply
;; does not match. `notes.id` is instance-global, so a resolution written in SQL
;; without the team clause would have resolved it. The reader learns their own
;; link does not work and learns nothing about whether an id elsewhere in the
;; instance exists — `repo-get`'s collapse of a refusal and a miss.
(define (resolve-target idx raw fold)
  (define by-fold (car idx))
  (define by-id (cdr idx))
  (define as-id (hash-ref by-id raw #f))
  (cond [as-id (values as-id #f)]
        [else
         (define hits (hash-ref by-fold fold '()))
         (cond [(null? hits) (values #f "missing")]
               [(null? (cdr hits)) (values (car hits) #f)]
               [else (values #f "ambiguous")])]))

;; The ONE write path for a note's edges, inside the caller's transaction. Rows
;; are replaced wholesale rather than diffed: the body is the truth about which
;; links it contains, and a diff is a second way to be wrong about that.
;; `fmt` for `body-tags`' reason, and this one had already shipped: the cap's
;; refusal formats a message, so with the parameter called `format` it raised a
;; contract error instead — which slice 2's own test caught only as
;; `exn:fail?`, i.e. it passed for the wrong reason. Its assertion names the
;; message now.
(define (write-links! conn id team body fmt)
  (define targets (if (string=? fmt "org") (org-link-targets body) '()))
  (when (> (length targets) MAX-NOTE-LINKS)
    (raise-user-error 'notes
      (format "a note carries at most ~a distinct links; ~a given"
              MAX-NOTE-LINKS (length targets))))
  (query-exec conn "DELETE FROM note_links WHERE src_note_id = ?" id)
  (for ([t (in-list targets)] [i (in-naturals)])
    (query-exec conn
      (string-append "INSERT INTO note_links (id, src_note_id, team_id, raw_target, "
                     "target_fold, label, ord) VALUES (?, ?, ?, ?, ?, ?, ?)")
      (new-id) id team (car t) (cadr t) (caddr t) i)))

;; ORG-8 / 🔑 ORG-9 — THE TWO ASYMMETRIES, AND THEY LOOK DIFFERENT ON PURPOSE.
;;
;; A BROKEN link is REPORTED, with its raw target and why: a link to a note that
;; does not exist is not the same as no link, it is the commonest failure this
;; feature will have (somebody deletes a note), and a link that silently became
;; plain text is how a reader concludes the editor ate their markup.
;;
;; An UNREADABLE link is DROPPED AND NOT REPORTED — no count, no placeholder, no
;; field. "There is a note here you may not read, and this one links to it" is an
;; existence oracle on a colleague's private note. A link row confers nothing
;; (QUEUE-3: the resource is authorized, never the row), and KG-3's rule is what
;; makes this trustworthy with no new authorization code.
;;
;; So there is deliberately NO `withheld` figure here, where CLS-27 and VEC-29
;; both report one. That is the difference between a bound somebody should know
;; about and a fact about somebody else's note.
(define (readable-note? conn p n)
  (can? conn p "notes:read" #:resource (note->resource n)))

(define (note-links-of conn p id)
  (define r (get-row conn id))
  (and r
       (let* ([n (row->note r)]
              [team (hash-ref n 'team_id)])
         (require-perm conn p "notes:read" #:resource (note->resource n))
         (define idx (team-note-index conn p team))
         (filter
          values
          (for/list ([row (in-list (query-rows conn
                            (string-append "SELECT raw_target, target_fold, label FROM note_links "
                                           "WHERE src_note_id = ? ORDER BY ord") id))])
            (define raw (vector-ref row 0))
            (define fold (vector-ref row 1))
            (define label (vector-ref row 2))
            (define-values (dst reason) (resolve-target idx raw fold))
            (cond
              [dst (hasheq 'target raw 'label label 'broken #f
                           'note_id (hash-ref dst 'id) 'title (hash-ref dst 'title))]
              ;; ORG-8: broken, with the raw target kept and the reason named —
              ;; and ORG-9 arrives here too, because the index is the caller's own
              ;; view. There is deliberately NO branch for "exists and is not
              ;; yours": a second test would be #110 r1's redundant guard, and
              ;; worse than redundant, because a reader would take it for the
              ;; place the rule lives and the two outcomes must be ONE answer.
              [else (hasheq 'target raw 'label label 'broken #t 'reason reason)]))))))

;; ORG-15 — `note_links` READ IN REVERSE is "what links here", one query, the
;; same authorization rule as ORG-9. In org-roam and Obsidian this is used far
;; more than the graph picture is, which is why it ships with the table rather
;; than waiting for the drawing.
;;
;; BOTH SPELLINGS OF THIS NOTE ARE ASKED FOR — its id and its folded title —
;; because ORG-6 admits both and a reader wants every inbound edge whichever way
;; its author typed it. And an inbound TITLE link only counts when this note is
;; the UNIQUE holder of that fold: if two notes share it, that link resolves to
;; neither (ORG-6), so reporting it here would make a backlink appear on a note
;; the link does not actually reach.
(define (note-backlinks-of conn p id)
  (define r (get-row conn id))
  (and r
       (let* ([n (row->note r)]
              [team (hash-ref n 'team_id)]
              [title-fold (fold-key (hash-ref n 'title))])
         (require-perm conn p "notes:read" #:resource (note->resource n))
         (define idx (team-note-index conn p team))
         (define unique-title?
           (and (not (string=? title-fold ""))
                (let ([hits (hash-ref (car idx) title-fold '())])
                  (and (pair? hits) (null? (cdr hits))))))
         (define folds (if unique-title? (list id title-fold) (list id)))
         (define rows
           (append*
            (for/list ([f (in-list (remove-duplicates folds))])
              (query-rows conn
                (string-append "SELECT src_note_id, label, raw_target FROM note_links "
                               "WHERE team_id = ? AND target_fold = ?") team f))))
         (filter
          values
          (for/list ([row (in-list rows)])
            (define src (hash-ref (cdr idx) (vector-ref row 0) #f))
            (cond
              ;; the source is gone, or it is a note this caller may not read —
              ;; and in BOTH cases there is nothing here, which is ORG-9 again:
              ;; a backlink from a colleague's private note is exactly the
              ;; existence oracle that rule is about. ONE test, because the index
              ;; is now the caller's view: an unreadable source is simply not in
              ;; it, which is the same collapse the forward read makes.
              [(not src) #f]
              [else (hasheq 'note_id (hash-ref src 'id) 'title (hash-ref src 'title)
                            'label (vector-ref row 1) 'target (vector-ref row 2))]))))))

;; ---- #247: the graph (ORG-13 / ORG-14 / ORG-16) ----------------------------
;;
;; A THIRD READER OF ONE EDGE SET, and it is in this module for the reason the
;; other two are: `team-note-index` IS the caller's own view of the team's notes
;; (ORG-9a), and `resolve-target` is the one place a stored target becomes a
;; note. A graph assembled anywhere else would have to re-ask both questions,
;; which is `executor-can-run?`'s drift in the place it has already cost the most
;; — slice 2 enforced ORG-9 by dropping an edge and that was an oracle, so a
;; second resolution written here would be a second chance to make exactly that
;; mistake. The picture is therefore a PROJECTION of what the links panel
;; already answers, never a parallel computation.
;;
;; 🔑 ORG-9a IS WHAT MAKES A PHANTOM NODE SAFE, and before it this drawing could
;; not have been built honestly. A target that resolves to nothing is drawn as an
;; unresolved node carrying the text its author typed — org-roam's and Obsidian's
;; own behaviour, and the useful half of the picture, because "four notes point
;; at a note nobody has written" is a thing to go and do. Under slice 2's
;; resolution an UNREADABLE target answered differently from a nonexistent one,
;; so such a node would have told the reader which of their colleagues' private
;; notes exist. The two answers are indistinguishable now, so the phantom says
;; only what the caller themselves wrote.
;;
;; AN AMBIGUOUS TARGET IS COUNTED AND DRAWN AS NOTHING, which is the one place
;; this read deliberately differs from ORG-9's silence. A phantom for it would
;; sit on the canvas beside the two real notes that already carry that title,
;; naming the same words three times; and a count here reveals nothing, because
;; every note involved is one the caller can read and the remedy is theirs (link
;; by id, or rename one). That is CLS-27's line read correctly — a bound somebody
;; can act on is reported, a fact about somebody else's note is not.
(define NOTE-GRAPH-MAX 150)
(define NOTE-GRAPH-SCAN 2000)
(define NOTE-GRAPH-DEPTH-MAX 3)

;; The ways this read can stop, as a CLOSED vocabulary rather than a message:
;; VEC-39's rule, and here the three have different remedies — ask for one note's
;; neighbourhood, ask for less depth, or accept that a team this size has no
;; whole-graph picture (ORG-16, and RG-9's argument that no layout rescues it).
(define NOTE-GRAPH-STOPS '("cap" "neighbourhood" "scan"))

(define (graph-node n #:focus? [focus? #f])
  (hasheq 'id (hash-ref n 'id) 'title (hash-ref n 'title)
          'missing #f 'focus focus?))

;; created_at DESC, id DESC — the notes listing's own order and its own tiebreak
;; (NPG-3), because `created_at` is TEXT at SECOND resolution and `id` is a random
;; uuid, so a cap that dropped notes by whatever the engine returned would draw a
;; different picture per query. ORG-13's determinism reaches the NODE SET too, not
;; only the layout: a seeded layout over an arbitrary subset is still arbitrary.
(define (note-newer? a b)
  (define ca (hash-ref a 'created_at ""))
  (define cb (hash-ref b 'created_at ""))
  (if (string=? ca cb)
      (string>? (hash-ref a 'id) (hash-ref b 'id))
      (string>? ca cb)))

(define (note-graph conn p #:note [focus #f] #:depth [depth 1])
  (require-perm conn p "notes:read")
  (define team (principal-team-id p))
  (define idx (team-note-index conn p team))
  (define by-id (cdr idx))
  (define d (max 1 (min NOTE-GRAPH-DEPTH-MAX (if (exact-integer? depth) depth 1))))
  ;; A FOCUS THAT IS NOT THERE AND ONE THE CALLER MAY NOT READ ARE ONE ANSWER,
  ;; because the index is the caller's view: `#f` here, which the endpoint renders
  ;; as a 404. `repo-get`'s collapse, and ORG-9a's rule arriving at a third reader.
  (cond
    [(and focus (not (hash-ref by-id focus #f))) #f]
    [else
     (define rows
       (query-rows conn
         (string-append "SELECT src_note_id, raw_target, target_fold FROM note_links "
                        "WHERE team_id = ? ORDER BY src_note_id, ord LIMIT ?")
         team NOTE-GRAPH-SCAN))
     (define scan-full? (>= (length rows) NOTE-GRAPH-SCAN))
     ;; the edge set, resolved through the caller's own index. An edge whose
     ;; SOURCE is unreadable is simply not here, which needs no test of its own:
     ;; such a note is not in the index either.
     (define phantoms (make-hash))          ; node key -> the target as written
     (define classified
       (for/list ([row (in-list rows)])
         (define src (vector-ref row 0))
         (define raw (vector-ref row 1))
         (define fold (vector-ref row 2))
         (cond
           [(not (hash-ref by-id src #f)) #f]
           [else
            (define-values (dst reason) (resolve-target idx raw fold))
            (cond
              [dst (cons src (hash-ref dst 'id))]
              [(equal? reason "ambiguous") (cons src 'ambiguous)]
              [else
               (define key (string-append "missing:" fold))
               ;; 🔑 WHICH SPELLING THE NODE IS LABELLED WITH IS DECIDED BY THE
               ;; DATA, NOT BY A ROW ORDER, and the first version of this took
               ;; whichever row arrived first — which is `ORDER BY src_note_id`,
               ;; i.e. whichever SOURCE NOTE happens to own the smallest random
               ;; uuid. Two authors who typed `[[Levee 7 survey]]` and
               ;; `[[levee 7 SURVEY]]` are pointing at one unwritten note (the
               ;; fold is the identity), so one of the two labels the node, and
               ;; a uuid deciding it means the same input draws a different
               ;; picture on every instance. ORG-13's determinism is about the
               ;; whole drawing and not only the layout, so the smallest
               ;; spelling wins: arbitrary, and a function of the targets alone.
               ;; Its own test is what found this.
               (define seen (hash-ref phantoms key #f))
               (when (or (not seen) (string<? raw seen)) (hash-set! phantoms key raw))
               (cons src key)])])))
     (define pairs (filter pair? classified))
     (define edges (filter (lambda (e) (string? (cdr e))) pairs))
     (define ambs (filter (lambda (e) (eq? (cdr e) 'ambiguous)) pairs))
     ;; undirected adjacency, for the neighbourhood walk only
     (define adj (make-hash))
     (define (link! a b) (hash-update! adj a (lambda (xs) (cons b xs)) '()))
     (for ([e (in-list edges)]) (link! (car e) (cdr e)) (link! (cdr e) (car e)))
     (define-values (keys stop)
       (if focus
           (neighbourhood focus adj d)
           (whole-team (hash-values by-id))))
     ;; A PHANTOM ONLY REACHES THE PICTURE WHEN SOMETHING THAT IS IN IT POINTS AT
     ;; IT, so the cap is spent on the team's own notes first — a team at the cap
     ;; draws no unresolved targets at all, which is the right way round: the
     ;; notes exist and the phantoms are inferred. In a NEIGHBOURHOOD one arrives
     ;; through the walk like any other node, because the adjacency is built over
     ;; the resolved edge set; a whole-team view has no walk, so they are
     ;; appended here. Sorted, for ORG-13's determinism under the cap.
     (define base (for/hash ([k (in-list keys)]) (values k #t)))
     (define wanted
       (if focus
           '()
           (sort (remove-duplicates
                  (for/list ([e (in-list edges)]
                             #:when (and (hash-ref phantoms (cdr e) #f)
                                         (hash-ref base (car e) #f)
                                         (not (hash-ref base (cdr e) #f))))
                    (cdr e)))
                 string<?)))
     (define room (max 0 (- NOTE-GRAPH-MAX (length keys))))
     (define added (if (> (length wanted) room) (take wanted room) wanted))
     (define all-keys (append keys added))
     (define stop* (or stop (and (> (length wanted) (length added)) "cap")))
     (define kept (for/hash ([k (in-list all-keys)]) (values k #t)))
     (define drawn-edges
       (for/list ([e (in-list edges)]
                  #:when (and (hash-ref kept (car e) #f) (hash-ref kept (cdr e) #f)))
         (hasheq 'from (car e) 'to (cdr e))))
     (hasheq
      'nodes (for/list ([k (in-list all-keys)])
               (cond [(hash-ref phantoms k #f)
                      => (lambda (raw)
                           (hasheq 'id k 'title raw 'missing #t 'focus #f))]
                     [else (graph-node (hash-ref by-id k) #:focus? (equal? k focus))]))
      'edges drawn-edges
      'focus (or focus 'null)
      'depth (if focus d 'null)
      'total (hash-count by-id)
      ;; 🔑 SCOPED TO THE VIEW, and the HTTP smoke is what found that it had to
      ;; be. Counted over the whole team, a reader looking at ONE note's
      ;; neighbourhood was told about an ambiguous link in a note that is not in
      ;; the picture and that they may never have seen — a figure with no
      ;; remedy beside it, which is #178's decoration. It counts the links FROM
      ;; a node that is drawn, so it is always about what is on the screen.
      'ambiguous (for/sum ([e (in-list ambs)]) (if (hash-ref kept (car e) #f) 1 0))
      'truncated (and (or stop* scan-full?) #t)
      ;; QUOTA-3's rule: the reason is ABSENT when nothing was cut, so a reader
      ;; never has to decide whether a stated one means anything. The scan bound
      ;; is reported last because it is the one an operator would be surprised by.
      'reason (cond [stop* stop*] [scan-full? "scan"] [else 'null]))]))

;; THE WHOLE-TEAM VIEW DRAWS ISOLATED NOTES TOO — it is a map, and a note nobody
;; has linked yet is exactly what somebody opening this is looking for. Past the
;; cap it is not a map of anything (ORG-16), so it keeps a deterministic prefix
;; and says so rather than pretending.
(define (whole-team notes)
  (define ordered (map (lambda (n) (hash-ref n 'id)) (sort notes note-newer?)))
  (if (> (length ordered) NOTE-GRAPH-MAX)
      (values (take ordered NOTE-GRAPH-MAX) "cap")
      (values ordered #f)))

;; ORG-16's DEFAULT: one note and what reaches it. Breadth-first and UNDIRECTED,
;; because "what links here" is the half people use (ORG-15) and a reader looking
;; at a note wants both sides of it on the canvas.
;;
;; A FRONTIER THAT WOULD CROSS THE CAP STOPS THE WALK AND IS REPORTED AS
;; `neighbourhood`, not as `cap`: the remedy is less depth, where the whole-team
;; cap's remedy is a smaller question. It takes the frontier in a SORTED order so
;; a partially drawn neighbourhood is the same one every time — ORG-13's
;; determinism again, and the reason this cannot just walk a hash's values.
(define (neighbourhood start adj d)
  (let loop ([frontier (list start)]
             [seen (hash start #t)]
             [order (list start)]
             [level 0])
    (cond
      [(or (= level d) (null? frontier)) (values (reverse order) #f)]
      [else
       (define next
         (sort (remove-duplicates
                (for*/list ([k (in-list frontier)]
                            [nb (in-list (hash-ref adj k '()))]
                            #:unless (hash-ref seen nb #f))
                  nb))
               string<?))
       (cond
         [(null? next) (values (reverse order) #f)]
         [(> (+ (length order) (length next)) NOTE-GRAPH-MAX)
          (define room (max 0 (- NOTE-GRAPH-MAX (length order))))
          (values (reverse (append (reverse (take next room)) order)) "neighbourhood")]
         [else
          (loop next
                (for/fold ([h seen]) ([k (in-list next)]) (hash-set h k #t))
                (append (reverse next) order)
                (add1 level))])])))


;; ---- ORG-11: the `.org` interchange ---------------------------------------
;;
;; THE KEYWORDS ARE THE NOTE'S METADATA IN BOTH DIRECTIONS, and the pair has to
;; be read together: `org-compose` writes `#+TITLE:` and `#+FILETAGS:` in front
;; of the body with one blank line between, and `org-parse` consumes exactly
;; that. **The round trip is byte-identical for the BODY**, which is the only
;; property a user of this cares about — asserted over eight body shapes
;; including one that starts with a blank line and one with no trailing newline.

;; The note AS A FILE. Answers `(values filename text)`, or `(values #f #f)` for
;; a note that is not there — so the endpoint can tell a miss from an empty file.
;;
;; EVERY FORMAT IS EXPORTABLE, deliberately: a Markdown note composed with these
;; two keywords is a perfectly good `.org` file whose body happens to be
;; Markdown, and refusing would make "get this note as a file" depend on a
;; declaration that says nothing about whether somebody wants one. The caller
;; asked for org; what they get is the note, in the org envelope.
(define (org-text-of conn p id)
  (define r (get-row conn id))
  (if (not r)
      (values #f #f)
      (let ([n (row->note r)])
        (require-perm conn p "notes:read" #:resource (note->resource n))
        (values (org-filename (hash-ref n 'title) (hash-ref n 'id))
                (org-compose (hash-ref n 'title) (note-tags conn id) (hash-ref n 'body))))))

;; A FILENAME IS A HEADER VALUE, so it is built from an allowlist rather than
;; escaped: a title is somebody's own words and may carry a quote, a newline or a
;; semicolon, every one of which would break out of
;; `Content-Disposition: attachment; filename="…"`. `safe-key-part`'s rule
;; (FEED-16, RG-21) at another asker — and the id is appended so two notes with
;; one title do not download over each other.
(define (org-filename title id)
  (define slug
    (let* ([f (fold-key title)]
           [kept (regexp-replace* #px"[^a-z0-9]+" f "-")]
           [trimmed (string-trim (regexp-replace* #px"-+" kept "-") "-")])
      (if (string=? trimmed "") "note" (substring trimmed 0 (min 48 (string-length trimmed))))))
  (format "~a-~a.org" slug (substring id 0 (min 8 (string-length id)))))

;; An org file in. The TAGS COME FROM THE FILE'S OWN `#+FILETAGS:` LINE and go in
;; through `#:filetags`, which is the same home ORG-12 names and not a second
;; one — see the note at `notes-create`. They still pass through `tags-clean`, so
;; an imported tag normalizes exactly as a typed one does (TAG-4).
;;
;; A FILE WITH NO `#+TITLE:` IMPORTS UNTITLED, exactly as `POST /api/notes` with
;; no title does, rather than this inventing one out of the first headline. The
;; cost is worth stating: ORG-6 resolves a link by TITLE, so an untitled import
;; is reachable by id and not by name until somebody names it.
(define (notes-import conn p text #:visibility [vis "team"])
  (define bytes-in (bytes-length (string->bytes/utf-8 (format "~a" text))))
  (when (> bytes-in MAX-ORG-IMPORT-BYTES)
    (raise-user-error 'notes
      (format (string-append "an org file imported here is at most ~a bytes; ~a given. "
                             "A larger document belongs in the repository, which is built to move one.")
              MAX-ORG-IMPORT-BYTES bytes-in)))
  (define-values (title tags body) (org-parse text))
  (notes-create conn p #:title (or title "") #:body body #:visibility vis #:format "org"
                #:filetags tags))

;; "May this caller write this note?", asked on its own so a caller can find out
;; BEFORE doing something expensive. `notes-set-tags!` asks it too — this is not
;; a second copy of the rule, it is the same `require-perm` on the same resource,
;; reachable one step earlier. #245's auto-tagger needs it because the model call
;; sits between the read and the write, and without this a viewer spent the
;; team's AI budget and was then refused: the HTTP smoke's viewer assertion is
;; what found that.
(define (notes-require-write! conn p id)
  (define r (get-row conn id))
  (and r (let ([n (row->note r)])
           (require-perm conn p "notes:write" #:resource (note->resource n))
           #t)))

;; TAG-4 — the one write path a caller reaches for tags alone. `'replace` is the
;; editor's save; `'add` is what the AI tool uses, because TAG-6 says a proposal
;; never silently removes a word somebody typed.
(define (notes-set-tags! conn p id tags #:mode [mode 'replace])
  (unless (memq mode '(replace add))
    (raise-user-error 'notes "mode must be replace or add"))
  (define r (get-row conn id))
  (and r (let ([n (row->note r)])
           ;; permission before validation: a caller who may not write this note
           ;; should not be told whether their tag was well formed
           (require-perm conn p "notes:write" #:resource (note->resource n))
           ;; ORG-12 — THE ONE PLACE BOTH THE ENDPOINT AND #245's TOOL REACH, so
           ;; the refusal is here rather than at each caller. `note_autotag`'s
           ;; write path is this function, which is why it cannot work on an org
           ;; note; the message says what to edit instead.
           (when (string=? (hash-ref n 'format) "org") (refuse-org-tags!))
           (define clean (tags-clean tags))
           ;; the cap is on the RESULT, not on the argument, or 'add could walk a
           ;; note past MAX-TAGS one proposal at a time
           (define final
             (if (eq? mode 'add)
                 (sort (remove-duplicates (append (note-tags conn id) clean)) string<?)
                 clean))
           (when (> (length final) MAX-TAGS)
             (raise-user-error 'notes
               (format "a note carries at most ~a tags; this would make ~a" MAX-TAGS (length final))))
           (call-with-transaction conn
             (lambda ()
               (query-exec conn "DELETE FROM note_tags WHERE note_id = ?" id)
               (write-tags! conn id (hash-ref n 'team_id) final)))
           (with-tags conn (row->note (get-row conn id))))))

;; TAG-1 — the team's tag list is DERIVED, never stored. And it is derived from
;; the notes the CALLER CAN READ, which is #239's PATH-6 arriving at a second
;; asker: `repo-count` deliberately does not apply `can?` because a count is a
;; count, while a folder NAME is somebody's words. A tag is somebody's words too,
;; so a tag living only on a colleague's private note must not appear in your
;; list. One readable note settles a tag, exactly as one readable object settles
;; a folder, and it costs nothing extra because the listing is already bounded by
;; the team and already authorized per row.
;;
;; The count is therefore "notes you can see with this tag", which is the honest
;; number for the thing a reader is about to click.
(define (notes-tag-list conn p #:scope [scope 'team])
  (define counts (make-hash))
  (for* ([n (in-list (notes-list conn p #:scope scope))]
         [tg (in-list (hash-ref n 'tags '()))])
    (hash-update! counts tg add1 0))
  (for/list ([tg (in-list (sort (hash-keys counts) string<?))])
    (hasheq 'tag tg 'notes (hash-ref counts tg))))

(define (notes-delete conn p id)
  (define r (get-row conn id))
  (and r (let ([n (row->note r)])
           (require-perm conn p "notes:delete" #:resource (note->resource n))
           ;; TAG-8 — a tag dies with its note. Rows naming a note that no longer
           ;; exists would keep a word in the team's derived list for ever, which
           ;; is the one way this list could lie about what is there.
           (query-exec conn "DELETE FROM note_tags WHERE note_id = ?" id)
           ;; ORG-8's PAYOFF, and the whole reason resolution is not stored: the
           ;; note's OUTGOING rows go with it, and its INBOUND ones need nothing
           ;; at all — they resolve to nothing on the next read and are reported
           ;; as broken, which is exactly what a reader whose target was deleted
           ;; should see. A stored `dst_note_id` would have needed a second
           ;; statement here and would have been a lie until it ran.
           (query-exec conn "DELETE FROM note_links WHERE src_note_id = ?" id)
           (query-exec conn "DELETE FROM notes WHERE id = ?" id)
           #t)))

;; owner (or notes:manage / operator) may share the note with another user
(define (notes-share conn p id #:user target-user #:permission [perm "notes:read"])
  ;; a grant row on a note carries a notes permission and nothing else — since a
  ;; grant DELEGATES (slice 56), the string a caller supplies must stay in scope
  (unless (and (string? perm) (regexp-match? #px"^notes:[a-z]+$" perm))
    (raise-user-error 'notes "permission must be a notes:* permission"))
  (define r (get-row conn id))
  (and r (let ([n (row->note r)])
           (unless (or (equal? (hash-ref n 'owner_user_id) (principal-user-id p))
                       (principal-is-operator p))
             (require-perm conn p "notes:manage" #:resource (note->resource n)))
           (grant! conn #:resource-type "notes" #:resource-id id
                   #:principal-type "user" #:principal-id target-user
                   #:permission perm #:by (principal-user-id p))
           #t)))
