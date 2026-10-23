#lang racket/base

;; domain/repo/annotations.rkt — a region a HUMAN drew (#65 piece 2, LAY-13…17).
;;
;; LAY-5 built the seam for where a MACHINE says it read something, and #92's OCR
;; extractor fills it. This is the other half the issue named and nothing built:
;; a place in a document that a person marked, with what they said about it.
;;
;; The distinction is not cosmetic, and it is why this is a separate table rather
;; than a flag on `repo_text.spans`:
;;
;;   • A SPAN IS REPLACED, AN ANNOTATION SURVIVES. A new version supersedes the
;;     extractor's spans wholesale — they are a function of the bytes. A person's
;;     observation is not: it was true about the bytes they were looking at, so it
;;     stays, bound to the version it was drawn on, and a listing for the current
;;     version does not show it as if it applied there. `stale` is DERIVED from
;;     the object's current version, never stored, so re-uploading the same bytes
;;     cannot leave a row disagreeing with the object.
;;   • THE AUTHORITY DIFFERS. An extractor writes as the platform; a person writes
;;     as themselves, and `author_user_id` is who they are.
;;
;; WHO MAY ANNOTATE: anyone who may READ the document. This is the decision in the
;; slice and it is deliberate. Requiring `files:write` would mean a specialist
;; handed a document to review — the DSH-1 `view` capability, which is what
;; sharing for review GIVES you — could not mark it up, which is the whole
;; activity. Nothing about the document changes: the bytes, the versions and the
;; extracted text are untouched, and an annotation is attributed to its author.
;; LAY-1…3 already lets a reviewer record a verdict and a rationale on work they
;; cannot write to, and this is the same act at a finer grain.
;;
;; WHAT THAT BUYS AND WHAT IT COSTS: a colleague may annotate a team-visible
;; document of yours, and you cannot edit what they wrote — only they can, or a
;; steward with `files:manage` may remove it. A correction to somebody else's
;; observation is your own annotation, never a rewrite of theirs; that is the
;; grants table's rule (a superseding record, not an edit) and the review queue's
;; (a decided review is terminal).

(require db-kit/portable
         json
         racket/string
         racket/list
         "../db/id.rkt"
         (only-in "../authz/authz.rkt" require-perm principal-user-id principal-team-id
                  exn:fail:forbidden? audit!)
         (only-in "repo.rkt" repo-get obj->resource)
         (only-in "extract.rkt" bbox-problem)
         "../db/nulls.rkt")

(provide ANNOTATION-KINDS MAX-BODY
         annotation-problem annotation-create! annotation-list annotation-get
         annotation-update! annotation-delete! annotations-for-review)

;; CLOSED, like `WORKER-STATES` and `REVIEW-VERDICTS`. The two differ in
;; BEHAVIOUR, which is the bar for a second member: a `note` carries what somebody
;; said and is refused without it, a `highlight` marks a place and needs no words.
;; A third ("redaction") was left out on purpose — it would imply enforcement, and
;; enforcement is #91's doc_redact, not a label.
(define ANNOTATION-KINDS '("note" "highlight"))

;; A body is a person's sentence about a region, not a document. The cap is here
;; so a client cannot use this table as free storage beside the quota'd one.
(define MAX-BODY 4000)

(define (now) (current-seconds))

;; ---- validation -------------------------------------------------------------------
;; One function for create AND patch, so a patch cannot reach a state a create
;; could not — the rule the schedule, webhook and feed routes follow.
(define (annotation-problem #:kind kind #:body body #:page page #:bbox bbox
                            #:start start #:end end)
  (define (int? v) (or (not v) (exact-nonnegative-integer? v)))
  (cond
    [(not (member kind ANNOTATION-KINDS))
     (format "unknown annotation kind `~a` — one of: ~a" kind (string-join ANNOTATION-KINDS ", "))]
    [(and (string=? kind "note") (or (not (string? body)) (string=? (string-trim body) "")))
     "a `note` needs a `body` — a note with nothing in it records that somebody clicked, not what they saw"]
    [(and body (> (string-length body) MAX-BODY))
     (format "`body` may not exceed ~a characters" MAX-BODY)]
    [(not (int? page)) "`page` must be a non-negative integer"]
    [(not (int? start)) "`start` must be a non-negative integer"]
    [(not (int? end)) "`end` must be a non-negative integer"]
    [(and start end (> start end)) "`start` may not exceed `end`"]
    ;; ONE bbox rule, shared with LAY-5's spans rather than written again
    [(bbox-problem bbox)]
    ;; AN ANNOTATION MUST NAME A PLACE. Without a region or a range it is a
    ;; comment on the document as a whole, which is what a note (or a review
    ;; rationale) already is — and a table of place-less annotations would make
    ;; "show me what is marked on page 3" answer with rows that belong nowhere.
    [(not (or bbox (and start end))) "an annotation needs a place: a `bbox` (with its `page`), a `start`/`end` range, or both"]
    [else #f]))

;; ---- rows -------------------------------------------------------------------------
(define SELECT
  (string-append "SELECT id, object_id, version_id, team_id, author_user_id, kind, body, "
                 "page, bbox, start_offset, end_offset, review_id, created_epoch, updated_epoch "
                 "FROM repo_annotations "))

(define (row->ann r current-version)
  (define vid (vector-ref r 2))
  (hasheq 'id (vector-ref r 0)
          'object_id (vector-ref r 1)
          'version_id vid
          'author_user_id (vector-ref r 4)
          'kind (vector-ref r 5)
          'body (nz (vector-ref r 6))
          'page (nz (vector-ref r 7))
          'bbox (let ([b (vector-ref r 8)])
                  (if (sql-null? b) 'null (string->jsexpr b)))
          'start (nz (vector-ref r 9))
          'end (nz (vector-ref r 10))
          'review_id (nz (vector-ref r 11))
          'created_epoch (vector-ref r 12)
          'updated_epoch (nz (vector-ref r 13))
          ;; DERIVED, never stored: a column would be a second copy of a decision
          ;; the next upload re-makes, and re-uploading the same bytes would leave
          ;; a row saying "stale" about a version that is current again. Same rule
          ;; as `missing`/`stale` in the Localization Manager and `waiting` on a job.
          'stale (not (equal? vid current-version))))

(define (current-version-of conn object-id)
  (let ([v (query-maybe-value conn "SELECT current_version_id FROM repo_objects WHERE id = ?" object-id)])
    (and v (not (sql-null? v)) v)))

;; Reading an annotation is reading something ABOUT the document, so the gate is
;; the document's own `files:read` — `repo-get` raises on a refusal and answers #f
;; for a miss, and the caller collapses the two (the knowledge graph's rule).
;; ONE ANSWER FOR A REFUSAL AND A MISS, in every entry point of this module, so a
;; caller cannot be made to tell them apart by picking a different one. `repo-get`
;; raises on a permission failure and answers #f for a miss (the asymmetry
;; CLAUDE.md warns about), so the collapse is explicit and deliberate here — the
;; knowledge graph's rule, and PULL-9's. Nothing is lost from the RECORD: the
;; audit seam for reads is `repo-open`, which hands out bytes, and this hands out
;; what people wrote about them.
(define (readable conn p object-id)
  (with-handlers ([exn:fail:forbidden? (lambda (_) #f)]) (repo-get conn p object-id)))

(define (annotation-list conn p object-id #:version [version 'current] #:review [review #f])
  (define o (readable conn p object-id))
  (and o
       (let* ([cur (current-version-of conn object-id)]
              [vid (cond [(eq? version 'all) #f]
                         [(eq? version 'current) cur]
                         [else version])]
              [rows (cond
                      [review
                       (query-rows conn (string-append SELECT "WHERE object_id = ? AND review_id = ? "
                                                       "ORDER BY created_epoch, id") object-id review)]
                      [vid
                       (query-rows conn (string-append SELECT "WHERE object_id = ? AND version_id = ? "
                                                       "ORDER BY created_epoch, id") object-id vid)]
                      [else
                       (query-rows conn (string-append SELECT "WHERE object_id = ? "
                                                       "ORDER BY created_epoch, id") object-id)])])
         ;; `created_epoch` is seconds, so two annotations drawn in one second tie;
         ;; `id` breaks it, which keeps a listing stable between two reads rather
         ;; than correct about which hand moved first. A caller must not read
         ;; order as chronology at that resolution.
         (for/list ([r (in-list rows)]) (row->ann r cur)))))

(define (annotation-get conn p id)
  (define r (query-maybe-row conn (string-append SELECT "WHERE id = ?") id))
  (and r
       ;; authorized on the OBJECT, every time, rather than on the annotation's
       ;; own team_id: the document's visibility and its grants are what decide,
       ;; and a denormalized team on this row must never become a second answer.
       (let ([o (readable conn p (vector-ref r 1))])
         (and o (row->ann r (current-version-of conn (vector-ref r 1)))))))

;; -> id, or 'no-such-object (a refusal and a miss are ONE answer here, as in the
;; worker's document read and the knowledge graph), or 'no-such-version.
(define (annotation-create! conn p object-id
                            #:kind kind #:body body #:page page #:bbox bbox
                            #:start start #:end end #:version [version #f] #:review [review #f])
  (define o (readable conn p object-id))
  (cond
    [(not o) 'no-such-object]
    [else
     (define cur (current-version-of conn object-id))
     (define vid (or version cur))
     (cond
       [(not vid) 'no-such-version]
       ;; A version named explicitly must belong to THIS object, or an annotation
       ;; would be bound to bytes in a document nobody checked the caller could
       ;; read — the warrant check PULL-9 makes for a worker's document read.
       [(not (query-maybe-value conn "SELECT id FROM repo_versions WHERE id = ? AND object_id = ?"
                                vid object-id))
        'no-such-version]
       [else
        (define id (new-id))
        (query-exec conn (string-append
                          "INSERT INTO repo_annotations (id, object_id, version_id, team_id, "
                          "author_user_id, kind, body, page, bbox, start_offset, end_offset, "
                          "review_id, created_epoch) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?)")
                    id object-id vid (hash-ref o 'team_id) (principal-user-id p) kind
                    (or body sql-null) (or page sql-null)
                    (if bbox (jsexpr->string bbox) sql-null)
                    (or start sql-null) (or end sql-null) (or review sql-null) (now))
        ;; The team is the DOCUMENT's, not the caller's acting team: `audit-list`
        ;; filters `WHERE team_id = ?`, and the people who would look for this are
        ;; the ones whose document was marked up. Sixth appearance of that shape.
        (audit! conn #:action "repo.annotation.create" #:actor-type "user"
                #:actor-id (principal-user-id p) #:team-id (hash-ref o 'team_id)
                #:resource-type "repo" #:resource-id object-id
                ;; ids and the kind — never the body, and never the key (#84 r2).
                ;; The body is the annotation's own content and the row is where it
                ;; lives; the audit log is chained, exported and kept through an
                ;; erasure, so a copy here would outlive the thing it describes.
                #:meta (jsexpr->string (hasheq 'annotation_id id 'kind kind 'version_id vid)))
        id])]))

;; Only the AUTHOR may change what they wrote. Not a permission check — a
;; `files:manage` steward may remove an annotation but may not put words in
;; somebody's mouth, which a body they could edit would do.
(define (annotation-update! conn p id #:body [body 'same] #:page [page 'same] #:bbox [bbox 'same]
                            #:start [start 'same] #:end [end 'same])
  (define r (query-maybe-row conn (string-append SELECT "WHERE id = ?") id))
  (cond
    [(not r) #f]
    [(not (readable conn p (vector-ref r 1))) #f]
    [(not (equal? (vector-ref r 4) (principal-user-id p))) 'not-author]
    [else
     (define (eff v col-index parse)
       (if (eq? v 'same) (let ([x (vector-ref r col-index)]) (if (sql-null? x) #f (parse x))) v))
     (define problem
       (annotation-problem #:kind (vector-ref r 5)
                           #:body (eff body 6 values)
                           #:page (eff page 7 values)
                           #:bbox (eff bbox 8 string->jsexpr)
                           #:start (eff start 9 values)
                           #:end (eff end 10 values)))
     (cond
       [problem problem]
       [else
        (define (put! col v) (query-exec conn (format "UPDATE repo_annotations SET ~a = ? WHERE id = ?" col) v id))
        (unless (eq? body 'same) (put! "body" (or body sql-null)))
        (unless (eq? page 'same) (put! "page" (or page sql-null)))
        (unless (eq? bbox 'same) (put! "bbox" (if bbox (jsexpr->string bbox) sql-null)))
        (unless (eq? start 'same) (put! "start_offset" (or start sql-null)))
        (unless (eq? end 'same) (put! "end_offset" (or end sql-null)))
        (put! "updated_epoch" (now))
        (annotation-get conn p id)])]))

;; The author, or a steward with `files:manage` on the document — DSH-2's rule
;; (only `manage` re-shares; stewardship of what is attached to a document is the
;; same kind of act). Deleting your own needs nothing beyond having written it.
(define (annotation-delete! conn p id)
  (define r (query-maybe-row conn (string-append SELECT "WHERE id = ?") id))
  (cond
    [(not r) #f]
    [else
     (define o (readable conn p (vector-ref r 1)))
     (cond
       [(not o) #f]
       [else
        (unless (equal? (vector-ref r 4) (principal-user-id p))
          (require-perm conn p "files:manage" #:resource (obj->resource o)))
        (query-exec conn "DELETE FROM repo_annotations WHERE id = ?" id)
        (audit! conn #:action "repo.annotation.delete" #:actor-type "user"
                #:actor-id (principal-user-id p) #:team-id (hash-ref o 'team_id)
                #:resource-type "repo" #:resource-id (vector-ref r 1)
                #:meta (jsexpr->string (hasheq 'annotation_id id
                                               'own (equal? (vector-ref r 4) (principal-user-id p)))))
        #t])]))

;; What a decision was about (#65's "LAY-11 is what it would hang off"). The
;; DECISION is what the chain hashes; these are the regions it cited, read back
;; per object so each one still passes that object's own `can?` — a review may
;; cite regions in a document the reader cannot see, and this must not be the way
;; around that.
(define (annotations-for-review conn p review-id)
  (define ids (query-list conn "SELECT DISTINCT object_id FROM repo_annotations WHERE review_id = ?" review-id))
  (append*
   (for/list ([oid (in-list ids)])
     (or (annotation-list conn p oid #:review review-id) '()))))
