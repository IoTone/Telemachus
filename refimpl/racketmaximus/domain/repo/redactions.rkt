#lang racket/base

;; domain/repo/redactions.rkt — where a redaction's map back is kept
;; (issue #91 requirement 1, migration 0061). `redact.rkt` beside this is the
;; pure half: patterns in, tokens out. This is the row.
;;
;; It is its own module for the reason `annotations.rkt` is: it owns a table, and
;; the module that owns a table is the one that declares its sealed column and
;; answers for who may read it.
;;
;; RED-6: NO ROUTE RETURNS A TOKEN MAP, and that is how requirement 1's "never
;; leaves the instance" is kept — by construction rather than by a check somebody
;; has to remember. `routes.rkt` gained nothing in this slice. Rehydration
;; (requirement 2) reads the map IN PROCESS, inside the step that is about to put
;; a value back, and the only thing that crosses the wire is the redacted text
;; and the counts.
;;
;; RED-9: WHAT THIS DOES NOT PROTECT, STATED. The dictionary's terms are the
;; CALLER'S OWN INPUT, and a workflow stores every run's input in
;; `workflow_runs.input` — sealed at rest only under the content switch, and
;; handed back by `GET /api/runs/:id` to anybody holding `workflows:read`. So the
;; names somebody asked to have redacted are visible to their colleagues, and for
;; a list of names that is worth knowing rather than discovering. It is FEED-13's
;; line (a read returns the configuration as given, because an operator who
;; cannot see what they typed cannot maintain it), and requirement 2 is where the
;; terms stop being a run input and become part of a spec or a trigger. The
;; smoke asserts it, so that the refutations beside it cannot be read as "the run
;; is clean".
;;
;; RED-7: READING A MAP NEEDS `files:read` ON THE SOURCE DOCUMENT, and nothing
;; more, because the map is a strict SUBSET of that document's own text — a
;; caller who may read the document may already read every value in it, so a
;; stricter rule here would protect nothing and would stop the pipeline's own
;; steps from rehydrating.
;;
;; A REFUSAL AND A MISS ARE ONE ANSWER, in both entry points and in one place
;; (`readable`), so a caller cannot tell them apart by choosing a different
;; function — the knowledge graph's rule and `annotations.rkt`'s. That somebody
;; redacted a document you cannot see is itself something you should not learn:
;; it says the document exists and that it had identifiers in it. `repo-get`
;; raises on forbidden and answers #f for a miss, and this is where the two are
;; deliberately collapsed.

(require db-kit/portable
         json
         racket/list
         "../db/id.rkt"
         (only-in "../authz/sealed.rkt" define-sealed-column)
         (only-in "../authz/authz.rkt" principal-team-id principal-user-id)
         "repo.rkt")

(provide seal-token-map unseal-token-map
         redaction-record! redaction-get redactions-for)

;; RED-5. `#:credential` — sealed whenever a key is configured, never gated on
;; `TELEMACHUS_ENCRYPT_CONTENT`. The migration says why at length; the short
;; version is that the ordinary instance runs with the content switch OFF, and a
;; redaction that stored its identifiers in the clear there would be doing the
;; opposite of its name on the documented default.
(define-sealed-column "repo_redactions.token_map"
                      (seal-token-map unseal-token-map) (id) #:credential)

(define (now) (current-seconds))

;; the ONE place the refusal and the miss become the same answer
(define (readable conn p object-id)
  (with-handlers ([exn:fail? (lambda (_) #f)]) (repo-get conn p object-id)))

;; The caller has already read the document (and so holds `files:read`); this
;; writes the row. `#:redacted` is the derived document's id, which arrives after
;; `derive!` has returned — so it is set here rather than threaded backwards.
(define (redaction-record! conn p src #:detectors detectors #:counts counts
                           #:map token-map #:redacted [redacted #f])
  (define id (new-id))
  (query-exec conn
    (string-append "INSERT INTO repo_redactions (id, object_id, version_id, team_id, created_by, "
                   "detectors, counts, token_map, redacted_object_id, created_epoch) "
                   "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)")
    id (hash-ref src 'id) (hash-ref src 'version_id) (hash-ref src 'team_id)
    (principal-user-id p)
    (jsexpr->string detectors)
    (jsexpr->string counts)
    ;; a LIST of (token value) pairs, not a hash: `jsexpr->string` of a hash has
    ;; no stable key order across processes, and this column is sealed — so the
    ;; ciphertext would differ run to run for the same map, which makes a dump
    ;; diff unreadable and a stored value impossible to compare. The fourth
    ;; appearance of the hash-order trap in this tree.
    (seal-token-map id (jsexpr->string (for/list ([kv (in-list token-map)])
                                         (list (car kv) (cdr kv)))))
    (or redacted sql-null) (now))
  id)

(define (row->redaction r)
  (hasheq 'id (vector-ref r 0)
          'object_id (vector-ref r 1)
          'version_id (vector-ref r 2)
          'detectors (string->jsexpr (vector-ref r 3))
          'counts (string->jsexpr (vector-ref r 4))
          'redacted_object_id (let ([v (vector-ref r 6)]) (if (sql-null? v) 'null v))
          'created_epoch (vector-ref r 7)))

(define RSELECT
  (string-append "SELECT id, object_id, version_id, detectors, counts, token_map, "
                 "redacted_object_id, created_epoch FROM repo_redactions "))

;; -> (values record map) with the map as a list of (token . value), or
;; (values #f #f) when there is no such redaction for this caller. RED-7: the
;; authority is `repo-get` on the SOURCE, which raises if the caller may not read
;; it — so a map can never be opened for a document its reader cannot open.
(define (redaction-get conn p id)
  (define r (query-maybe-row conn (string-append RSELECT "WHERE id = ? AND team_id = ?")
                             id (principal-team-id p)))
  (cond
    [(not r) (values #f #f)]
    [else
     (define rec (row->redaction r))
     (define src (readable conn p (hash-ref rec 'object_id)))
     (cond
       [(not src) (values #f #f)]
       [else
        (values rec
                (for/list ([kv (in-list (string->jsexpr (unseal-token-map id (vector-ref r 5))))])
                  (cons (first kv) (second kv))))])]))

;; The records for one document, newest first — the quality report (requirement 5)
;; read back later rather than only at the moment of redaction. NO TOKEN MAP: this
;; is the listing, and a listing that carried the values would be the route RED-6
;; says does not exist.
(define (redactions-for conn p object-id)
  (define src (readable conn p object-id))
  (cond
    [(not src) '()]
    [else
     (for/list ([r (in-list (query-rows conn
                              (string-append RSELECT "WHERE object_id = ? AND team_id = ? "
                                             "ORDER BY created_epoch DESC, id DESC")
                              object-id (principal-team-id p)))])
       (row->redaction r))]))
