#lang racket/base

;; domain/notes/note-sources.rkt — a note's link to a document or a bookmark,
;; resolved for one reader (#191).
;;
;; A note link names another note, or — with a `doc:` / `bookmark:` prefix — the
;; source the note was written from. This module turns such a target into the
;; thing it names, FOR THE CALLER: every lookup goes through the same checks the
;; document and bookmark screens make, so a link confers nothing.
;;
;; "NOT THERE" AND "NOT YOURS" ARE ONE ANSWER, `#f`, which the readers in
;; `notes.rkt` report as an ordinary missing target. A different answer for a
;; document the reader may not open would tell them it exists (ORG-9a's rule,
;; reaching a second kind of target).
;;
;; ONE TEAM. A document or bookmark in another team resolves to nothing, even a
;; document shared with the reader across teams: the notes graph is one team's
;; picture and ORG-10 already treats a cross-team note that way.
;;
;; NOTHING IS STORED ABOUT THE RESOLUTION, for the reason note-to-note links
;; store none: the target can be deleted, renamed or bookmarked later, and a
;; link written before its source exists should start working when it does.

(require racket/string
         "org-links.rkt"
         (only-in "../authz/authz.rkt" can? exn:fail:forbidden?)
         (only-in "../repo/repo.rkt" repo-get)
         (only-in "../research/research.rkt" research-get research-by-url))

(provide resolve-source make-source-resolver)

(define (present? v) (and (string? v) (not (string=? v ""))))

;; -> a node hash, or #f. `raw` is the target as written.
(define (resolve-source conn p team raw)
  (define ty (typed-target raw))
  (cond
    [(not ty) #f]
    [(string=? (car ty) "document") (document-node conn p team (cdr ty))]
    [else (bookmark-node conn p team (cdr ty))]))

;; By id first, then by key within the team. `repo-get` RAISES on a refusal and
;; answers #f for a miss; both become #f here, on purpose.
(define (document-node conn p team ref)
  (define (try thunk)
    (with-handlers ([exn:fail:forbidden? (lambda (_) #f)]) (thunk)))
  (define o
    (let ([by-id (try (lambda () (repo-get conn p ref)))])
      (if (and by-id (equal? (hash-ref by-id 'team_id) team))
          by-id
          (try (lambda () (repo-get conn p ref #:by-key team))))))
  (and o
       (equal? (hash-ref o 'team_id) team)
       (let ([name (hash-ref o 'filename "")])
         (hasheq 'kind "document"
                 'id (string-append "doc:" (hash-ref o 'id))
                 'object_id (hash-ref o 'id)
                 'key (hash-ref o 'key)
                 'title (if (present? name) name (hash-ref o 'key))))))

;; By bookmark id first, then by URL. `research:use` is the permission the
;; bookmark screen asks, so a reader without it sees a missing target.
(define (bookmark-node conn p team ref)
  (and (can? conn p "research:use")
       (let ([s (or (research-get conn ref team) (research-by-url conn team ref))])
         (and s
              (let ([title (hash-ref s 'title 'null)])
                (hasheq 'kind "bookmark"
                        'id (string-append "bookmark:" (hash-ref s 'id))
                        'source_id (hash-ref s 'id)
                        'url (hash-ref s 'url)
                        'title (if (present? title) title (hash-ref s 'url))))))))

;; One reader, one answer per target: the graph resolves every link row in a
;; team, and many rows name the same source.
(define (make-source-resolver conn p team)
  (define memo (make-hash))
  (lambda (raw)
    (hash-ref! memo raw (lambda () (resolve-source conn p team raw)))))
