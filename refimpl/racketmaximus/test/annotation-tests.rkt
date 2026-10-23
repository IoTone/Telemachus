#lang racket/base

;; test/annotation-tests.rkt — a region a HUMAN drew (#65 piece 2).
;;
;;   raco test test/annotation-tests.rkt
;;
;; The four properties that carry the slice, each written so the obvious wrong
;; implementation fails it:
;;
;;   1. A REGION IS BOUND TO BYTES. It names the version it was drawn on, a new
;;      version does not move it, and `stale` is DERIVED — so re-uploading the
;;      same bytes cannot leave a row disagreeing with the object.
;;   2. ANYONE WHO MAY READ MAY ANNOTATE, and nobody else. A viewer-shared
;;      specialist can mark up; somebody with no access gets the same answer as
;;      for a document that does not exist.
;;   3. ONLY THE AUTHOR MAY EDIT. A steward may DELETE somebody's annotation and
;;      still may not rewrite it — a deliberately weaker power than deletion.
;;   4. IT DIES WITH THE DOCUMENT. An annotation naming a version that no longer
;;      exists would leave a deletion half honoured.

(require rackunit db-kit/portable db-kit/migrate
         racket/file racket/port racket/list json
         "../domain/db/migrations.rkt"
         "db-fixture.rkt"
         "../domain/authz/authz.rkt"
         "../domain/repo/blobs.rkt"
         "../domain/repo/repo.rkt"
         "../domain/repo/annotations.rkt")

(define BLOB-ROOT (make-temporary-file "telemachus-ann-~a" 'directory))
(current-blob-root BLOB-ROOT)

(define (fresh)
  (define conn (fresh-db #:migrate? #f))
  (migrate! conn all-migrations)
  conn)

(define (owner-of conn)
  (define-values (u team) (bootstrap! conn #:username "alice" #:org-name "Acme" #:org-slug "acme"
                                      #:team-name "Engineering" #:team-slug "engineering"))
  (values (user-principal conn u team) team u))

(define (member-of conn team username #:role [role "member"])
  (define u (create-user! conn #:username username #:password "pw"))
  (add-member! conn #:user u #:team team #:role role)
  (values (user-principal conn u team) u))

;; `repo-put!` answers the OBJECT, so the helper takes its id — passing the hash
;; where an id belongs is a "cannot convert given value to SQL type" at the first
;; query, which is what the first run reported.
(define (put! conn p key bytes #:vis [vis #f])
  (hash-ref (repo-put! conn p #:key key #:port (open-input-bytes bytes)
                       #:content-type "application/pdf" #:filename "f" #:visibility vis)
            'id))

(define (mark! conn p oid #:kind [kind "note"] #:body [body "the beam is undersized"]
               #:page [page 3] #:bbox [bbox '(10 20 110 60)] #:start [start #f] #:end [end #f]
               #:version [version #f] #:review [review #f])
  (annotation-create! conn p oid #:kind kind #:body body #:page page #:bbox bbox
                      #:start start #:end end #:version version #:review review))

;; ---- validation ---------------------------------------------------------------------
(test-case "an annotation must name a place, and a note must say something"
  (define (prob #:kind [kind "note"] #:body [body "x"] #:page [page 1] #:bbox [bbox '(0 0 1 1)]
                #:start [start #f] #:end [end #f])
    (annotation-problem #:kind kind #:body body #:page page #:bbox bbox #:start start #:end end))
  (check-false (prob))
  ;; a highlight needs no words — that behavioural difference is the whole reason
  ;; there are two kinds rather than one
  (check-false (prob #:kind "highlight" #:body #f))
  ;; a range with no box is a place too: this is how a reviewer marks extracted text
  (check-false (prob #:bbox #f #:start 10 #:end 20))
  (check-true (string? (prob #:kind "redaction")))
  (check-true (string? (prob #:kind "")))
  ;; A NOTE WITH NO BODY records that somebody clicked, not what they saw.
  (check-true (string? (prob #:body #f)))
  (check-true (string? (prob #:body "   ")))
  (check-true (string? (prob #:body (make-string (add1 MAX-BODY) #\x))))
  ;; a place is REQUIRED: without one this is a comment on the document, which a
  ;; note (or a review rationale) already is
  (check-true (string? (prob #:bbox #f)))
  (check-true (string? (prob #:bbox #f #:start 10)))
  ;; the bbox rule is LAY-5's, shared rather than written again
  (check-true (string? (prob #:bbox '(0 0 1))))
  (check-true (string? (prob #:bbox '(0 0 1 "x"))))
  (check-true (string? (prob #:bbox #f #:start 20 #:end 10)))
  (check-true (string? (prob #:page -1))))

;; ---- 1. a region is bound to the bytes it was drawn on --------------------------------
(test-case "a new version does not move an annotation, and `stale` is derived"
  (define c (fresh))
  (define-values (p team uid) (owner-of c))
  (define oid (put! c p "drawings/beam.pdf" #"v1 bytes"))
  (define v1 (hash-ref (repo-get c p oid) 'version_id))
  (define a (mark! c p oid))
  (check-true (string? a))
  (define listed (annotation-list c p oid))
  (check-equal? (length listed) 1)
  (check-equal? (hash-ref (car listed) 'version_id) v1)
  (check-false (hash-ref (car listed) 'stale))
  (check-equal? (hash-ref (car listed) 'page) 3)
  (check-equal? (hash-ref (car listed) 'bbox) '(10 20 110 60))
  ;; a new version lands: the region was true about bytes that are no longer the
  ;; current ones, so it is NOT shown for the current version…
  (put! c p "drawings/beam.pdf" #"v2 bytes, the beam is bigger now")
  (check-equal? (annotation-list c p oid) '())
  ;; …and it is still THERE, bound to v1 and reported as stale
  (define all (annotation-list c p oid #:version 'all))
  (check-equal? (length all) 1)
  (check-true (hash-ref (car all) 'stale))
  (check-equal? (hash-ref (car all) 'version_id) v1)
  ;; asking for that version by name shows it as current for that version
  (check-equal? (length (annotation-list c p oid #:version v1)) 1)
  ;; and a region drawn on the new bytes is not stale
  (define a2 (mark! c p oid #:body "checked"))
  (check-equal? (length (annotation-list c p oid)) 1)
  (check-false (hash-ref (car (annotation-list c p oid)) 'stale))
  (close-db! c))

(test-case "a version must belong to this document"
  (define c (fresh))
  (define-values (p team uid) (owner-of c))
  (define a-id (put! c p "a.pdf" #"aaa"))
  (define b-id (put! c p "b.pdf" #"bbb"))
  (define bv (hash-ref (repo-get c p b-id) 'version_id))
  ;; Otherwise an annotation would be bound to bytes in a document nobody checked
  ;; the caller could read — the warrant check PULL-9 makes for a worker's read.
  (check-equal? (mark! c p a-id #:version bv) 'no-such-version)
  (check-equal? (mark! c p a-id #:version "v-nonexistent") 'no-such-version)
  (close-db! c))

;; ---- 2. who may annotate --------------------------------------------------------------
(test-case "anyone who may read may annotate; somebody with no access cannot tell it exists"
  (define c (fresh))
  (define-values (p team uid) (owner-of c))
  (define-values (bob bob-id) (member-of c team "bob"))
  (define shared (put! c p "drawings/team.pdf" #"team visible"))
  (define private (put! c p "drawings/mine.pdf" #"private" #:vis "private"))
  ;; A colleague who can READ a team-visible document may mark it up. This is the
  ;; decision of the slice: requiring files:write would mean a specialist handed a
  ;; document to review could not annotate it, which is the activity itself.
  (check-true (string? (mark! c bob shared #:body "check this weld")))
  (check-equal? (length (annotation-list c p shared)) 1)
  (check-equal? (hash-ref (car (annotation-list c p shared)) 'author_user_id) bob-id)
  ;; …and a document he cannot read answers exactly as a missing one does
  (check-equal? (mark! c bob private) 'no-such-object)
  (check-equal? (annotation-list c p private) '())
  ;; the owner's own annotation on their private document is fine
  (check-true (string? (mark! c p private #:body "mine")))
  ;; while bob still sees nothing of it — the read is authorized on the OBJECT
  (check-false (annotation-list c bob private))
  (close-db! c))

(test-case "a grant that reaches the document reaches its annotations"
  (define c (fresh))
  (define-values (p team uid) (owner-of c))
  (define-values (bob bob-id) (member-of c team "bob"))
  (define oid (put! c p "drawings/mine.pdf" #"private" #:vis "private"))
  (check-false (annotation-list c bob oid))
  ;; DSH-1's `view` capability is what sharing for review gives, and it is what
  ;; makes annotating possible — the asymmetry this slice exists to remove.
  (repo-share! c p oid #:principal-type "user" #:principal-id bob-id #:capability "view")
  (check-equal? (annotation-list c bob oid) '())      ; reachable, and empty
  (check-true (string? (mark! c bob oid #:body "drawn by the reviewer")))
  (check-equal? (length (annotation-list c p oid)) 1)
  (close-db! c))

;; ---- 3. only the author may edit ------------------------------------------------------
(test-case "a steward may delete somebody's annotation and may never rewrite it"
  (define c (fresh))
  (define-values (p team uid) (owner-of c))
  (define-values (bob bob-id) (member-of c team "bob"))
  (define-values (carol carol-id) (member-of c team "carol"))
  (define oid (put! c p "drawings/team.pdf" #"team visible"))
  (define a (mark! c bob oid #:body "bob's reading"))
  ;; the author may change their own words
  (check-equal? (hash-ref (annotation-update! c bob a #:body "bob's corrected reading") 'body)
                "bob's corrected reading")
  ;; NOBODY ELSE MAY, not the document's owner and not a colleague. A correction
  ;; to somebody else's observation is your own annotation.
  (check-equal? (annotation-update! c p a #:body "actually it is fine") 'not-author)
  (check-equal? (annotation-update! c carol a #:body "no") 'not-author)
  (check-equal? (hash-ref (annotation-get c p a) 'body) "bob's corrected reading")
  ;; a patch is validated as the annotation would be, so it cannot reach a state
  ;; a create could not: clearing a note's body is refused
  (check-true (string? (annotation-update! c bob a #:body #f)))
  ;; carol holds no stewardship, so she cannot remove it either
  (check-exn exn:fail? (lambda () (annotation-delete! c carol a)))
  ;; the owner holds files:manage on their own document and may
  (check-true (annotation-delete! c p a))
  (check-equal? (annotation-list c p oid) '())
  ;; and an author may always remove their own
  (define a2 (mark! c bob oid #:body "again"))
  (check-true (annotation-delete! c bob a2))
  (close-db! c))

;; ---- 4. it dies with the document -----------------------------------------------------
(test-case "deleting the document removes the regions marked on it"
  (define c (fresh))
  (define-values (p team uid) (owner-of c))
  (define oid (put! c p "drawings/beam.pdf" #"bytes"))
  (void (mark! c p oid))
  (check-equal? (query-value c "SELECT COUNT(*) FROM repo_annotations WHERE object_id = ?" oid) 1)
  (void (repo-delete! c p oid))
  ;; An annotation naming a version that no longer exists, on a document nobody
  ;; can open, would leave a team's own deletion request half honoured.
  (check-equal? (query-value c "SELECT COUNT(*) FROM repo_annotations WHERE object_id = ?" oid) 0)
  (close-db! c))

;; ---- the review link, and the audit entry ---------------------------------------------
(test-case "regions cited by a review are read back under each document's own can?"
  (define c (fresh))
  (define-values (p team uid) (owner-of c))
  (define-values (bob bob-id) (member-of c team "bob"))
  (define shared (put! c p "drawings/team.pdf" #"team visible"))
  (define private (put! c p "drawings/mine.pdf" #"private" #:vis "private"))
  (void (mark! c p shared #:body "visible one" #:review "rev-1"))
  (void (mark! c p private #:body "private one" #:review "rev-1"))
  (check-equal? (length (annotations-for-review c p "rev-1")) 2)
  ;; A REVIEW MAY CITE A REGION IN A DOCUMENT THE READER CANNOT SEE, and this
  ;; must not be the way around that: each object is authorized on its own.
  (define bobs (annotations-for-review c bob "rev-1"))
  (check-equal? (length bobs) 1)
  (check-equal? (hash-ref (car bobs) 'body) "visible one")
  (close-db! c))

(test-case "the audit entry names the document's team and carries no body"
  (define c (fresh))
  (define-values (p team uid) (owner-of c))
  (define oid (put! c p "drawings/beam.pdf" #"bytes"))
  (define a (mark! c p oid #:body "a sentence nobody else should find in the log"))
  (define entries (audit-list c team #:limit 20))
  (define mine (filter (lambda (e) (equal? (hash-ref e 'action) "repo.annotation.create")) entries))
  ;; `audit-list` filters WHERE team_id = ?, so an entry written without the
  ;; document's team is invisible to the people whose document was marked up —
  ;; the shape that has now appeared six times.
  (check-equal? (length mine) 1)
  (define row (query-value c "SELECT meta FROM audit_log WHERE action = 'repo.annotation.create'"))
  (check-true (regexp-match? (regexp a) row))
  ;; the body lives in the annotation row, which an erasure removes; the audit log
  ;; is chained, exported and deliberately kept, so a copy here would outlive it
  (check-false (regexp-match? #rx"nobody else should find" row))
  (close-db! c))
