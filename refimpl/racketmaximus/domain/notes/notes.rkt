#lang racket/base

;; domain/notes/notes.rkt — the first ownable resource, end to end through RBAC.
;; Every operation is authorized with the AuthzService: team-visibility, private
;; (owner-only), and shared (explicit resource_grants) all flow through `can?` /
;; `require-perm`. Functions raise exn:fail:forbidden on deny (→ 403) and return
;; #f on not-found (→ 404).

(require db-kit/portable racket/list racket/string
         "../db/id.rkt"
         "org-links.rkt"
         "../authz/authz.rkt")

(provide notes-create notes-list notes-get notes-update notes-delete notes-share
         ;; tags (#245) — exported for the tool, the endpoint and their tests
         notes-set-tags! notes-tag-list note-tags notes-require-write!
         tag-normalize tag-problem tags-clean MAX-TAGS MAX-TAG-CHARS
         ;; org-mode (#246 slice 1) — the closed vocabulary and its one check,
         ;; exported FOR the endpoint and the gate that pins the set as a whole
         NOTE-FORMATS format-problem
         ;; links (#246 slice 2) — exported for the endpoint and its tests
         note-links-of note-backlinks-of)

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

(define (get-row conn id) (query-maybe-row conn (string-append SELECT " WHERE id = ?") id))

(define (notes-create conn p #:title [title ""] #:body [body ""] #:visibility [vis "team"]
                      #:tags [tags '()] #:format [fmt "markdown"])
  (require-perm conn p "notes:write")                       ; team-level create
  ;; cleaned BEFORE the note exists, so a malformed tag refuses the whole create
  ;; rather than leaving a note somebody has to notice is untagged (VEC-21's
  ;; order, where every validation runs before anything is written). The format
  ;; joins it for the same reason: a note stored with a format nothing can draw
  ;; is worse than a create that was refused.
  (define clean (tags-clean tags))
  (define fmt* (format-clean fmt))
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

;; #:scope 'org lists across every team in the caller's company (TEN-2h); each row
;; still passes can?, so an org reader sees team-visible notes and nobody's
;; private ones, and a plain member sees exactly what they saw before
(define (notes-list conn p #:scope [scope 'team] #:tags [want '()])
  ;; the team-level read first, like repo-list: a token scoped without notes:read
  ;; is refused here rather than handed an empty list that looks like "no notes"
  (require-perm conn p "notes:read")
  (define teams
    (if (eq? scope 'org)
        (let ([org (or (principal-org-id p) (team-org conn (principal-team-id p)))])
          (if org (org-teams-of conn org) (list (principal-team-id p))))
        (list (principal-team-id p))))
  (define rows
    (append*
     (for/list ([t (in-list teams)])
       (query-rows conn (string-append SELECT " WHERE team_id = ? ORDER BY created_at DESC") t))))
  ;; one tag read per team, merged — see team-tag-index
  (define idx
    (for/fold ([h (hash)]) ([t (in-list teams)])
      (for/fold ([h h]) ([(k v) (in-hash (team-tag-index conn t))]) (hash-set h k v))))
  ;; TAG-5 — `?tag=` is repeatable and is applied AFTER the per-row `can?`, which
  ;; is LAY-4's rule for `?attr=` exactly: a filter may only narrow what the
  ;; caller was already allowed to see, never widen it. Several tags are an AND.
  (define wanted (tags-clean want))
  (define visible
    (for/list ([r (in-list rows)]
               #:when (can? conn p "notes:read" #:resource (note->resource (row->note r))))
      (let ([n (row->note r)])
        (hash-set n 'tags (hash-ref idx (hash-ref n 'id) '())))))
  (if (null? wanted)
      visible
      (filter (lambda (n)
                (for/and ([w (in-list wanted)])
                  (and (member w (hash-ref n 'tags)) #t)))
              visible)))

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
                 (write-links! conn id (hash-ref n 'team_id)
                               (or body (hash-ref n 'body))
                               (or fmt* (hash-ref n 'format))))))
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
(define (team-note-index conn team)
  (define by-fold (make-hash))
  (define by-id (make-hash))
  (for ([r (in-list (query-rows conn
                      (string-append "SELECT id, team_id, owner_user_id, visibility, title "
                                     "FROM notes WHERE team_id = ?") team))])
    (define n (hasheq 'id (vector-ref r 0) 'team_id (vector-ref r 1)
                      'owner_user_id (vector-ref r 2) 'visibility (vector-ref r 3)
                      'title (vector-ref r 4)))
    (hash-set! by-id (hash-ref n 'id) n)
    (hash-update! by-fold (fold-key (hash-ref n 'title)) (lambda (xs) (cons n xs)) '()))
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
(define (write-links! conn id team body format)
  (define targets (if (string=? format "org") (org-link-targets body) '()))
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
         (define idx (team-note-index conn team))
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
              ;; ORG-9: the far end is there and this caller may not read it, so
              ;; there is nothing here at all
              [(and dst (not (readable-note? conn p dst))) #f]
              [dst (hasheq 'target raw 'label label 'broken #f
                           'note_id (hash-ref dst 'id) 'title (hash-ref dst 'title))]
              ;; ORG-8: broken, with the raw target kept and the reason named
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
         (define idx (team-note-index conn team))
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
              ;; existence oracle that rule is about
              [(not src) #f]
              [(not (readable-note? conn p src)) #f]
              [else (hasheq 'note_id (hash-ref src 'id) 'title (hash-ref src 'title)
                            'label (vector-ref row 1) 'target (vector-ref row 2))]))))))

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
