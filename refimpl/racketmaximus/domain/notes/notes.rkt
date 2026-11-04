#lang racket/base

;; domain/notes/notes.rkt — the first ownable resource, end to end through RBAC.
;; Every operation is authorized with the AuthzService: team-visibility, private
;; (owner-only), and shared (explicit resource_grants) all flow through `can?` /
;; `require-perm`. Functions raise exn:fail:forbidden on deny (→ 403) and return
;; #f on not-found (→ 404).

(require db-kit/portable racket/list racket/string
         "../db/id.rkt"
         "../authz/authz.rkt")

(provide notes-create notes-list notes-get notes-update notes-delete notes-share
         ;; tags (#245) — exported for the tool, the endpoint and their tests
         notes-set-tags! notes-tag-list note-tags notes-require-write!
         tag-normalize tag-problem tags-clean MAX-TAGS MAX-TAG-CHARS)

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

(define (tag-normalize s)
  ;; `string-split` with no separator splits on whitespace AND drops the empties,
  ;; so this collapses internal runs and trims in one pass
  (string-downcase (string-join (string-split (format "~a" s)) " ")))

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
  "SELECT id, team_id, owner_user_id, visibility, title, body, created_at, updated_at FROM notes")

(define (row->note r)
  (hasheq 'id (vector-ref r 0) 'team_id (vector-ref r 1) 'owner_user_id (vector-ref r 2)
          'visibility (vector-ref r 3) 'title (vector-ref r 4) 'body (vector-ref r 5)
          'created_at (vector-ref r 6) 'updated_at (vector-ref r 7)))

(define (note->resource n)
  (hasheq 'resource_type "notes" 'resource_id (hash-ref n 'id)
          'team_id (hash-ref n 'team_id) 'owner_user_id (hash-ref n 'owner_user_id)
          'visibility (hash-ref n 'visibility)))

(define (get-row conn id) (query-maybe-row conn (string-append SELECT " WHERE id = ?") id))

(define (notes-create conn p #:title [title ""] #:body [body ""] #:visibility [vis "team"]
                      #:tags [tags '()])
  (require-perm conn p "notes:write")                       ; team-level create
  ;; cleaned BEFORE the note exists, so a malformed tag refuses the whole create
  ;; rather than leaving a note somebody has to notice is untagged (VEC-21's
  ;; order, where every validation runs before anything is written)
  (define clean (tags-clean tags))
  (define id (new-id))
  (query-exec conn
    "INSERT INTO notes (id, team_id, owner_user_id, visibility, title, body) VALUES (?, ?, ?, ?, ?, ?)"
    id (principal-team-id p) (principal-user-id p) vis title body)
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
                      #:tags [tags #f])
  (define r (get-row conn id))
  (and r (let ([n (row->note r)])
           (require-perm conn p "notes:write" #:resource (note->resource n))
           ;; cleaned before anything is written, so a malformed tag leaves the
           ;; note — and its previous tag set — exactly as it was
           (define clean (and tags (tags-clean tags)))
           (when title (query-exec conn "UPDATE notes SET title = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ?" title id))
           (when body  (query-exec conn "UPDATE notes SET body = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ?" body id))
           (when vis   (query-exec conn "UPDATE notes SET visibility = ?, updated_at = CURRENT_TIMESTAMP WHERE id = ?" vis id))
           (when clean
             (call-with-transaction conn
               (lambda ()
                 (query-exec conn "DELETE FROM note_tags WHERE note_id = ?" id)
                 (write-tags! conn id (hash-ref n 'team_id) clean))))
           (with-tags conn (row->note (get-row conn id))))))

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
