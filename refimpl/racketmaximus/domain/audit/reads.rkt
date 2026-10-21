#lang racket/base

;; domain/audit/reads.rkt — who read a document, when, and from where (issue #84).
;;
;; `audit_log` recorded create / update / delete / share / visibility for repo
;; objects and recorded READS nowhere. A regulated deployment has to be able to
;; answer "who viewed this document" and could not.
;;
;; ONE SEAM, FOR THE SAME REASON `repo-put!` HAS ONE. Every path that hands out
;; document bytes goes through `repo-open`: the console download and the API GET,
;; the S3 listener's GetObject, HeadObject and CopyObject source, LAY-6's
;; out-of-process `repo.get`, PULL-9's worker read, the indexer, and `doc_text`
;; inside a workflow step. Auditing at each of those nine call sites would be
;; nine chances to forget — and the tenth caller, written later, would be silent.
;; So the seam records, and the CONTEXT below says which door the read came
;; through. The same move FLEET-2 made with `executor-can-run?`: one policy, many
;; askers, never re-derived.
;;
;; WHAT IS AND IS NOT A CONTENT READ. `repo-open` produces the bytes, so that is
;; what is audited. `repo-get` alone answers metadata — a listing, a share dialog,
;; a "Processed by" panel — and auditing it would bury the reads that matter in
;; rows about rendering a table. r1's "API GET" is the GET that returns the
;; document, which is `repo-open`.

(require racket/string db-kit/portable
         (only-in "../authz/authz.rkt" audit! principal-user-id require-perm)
         (only-in "../db/id.rkt" new-id)
         json
         (only-in "../db/nulls.rkt" nz))

(provide current-read-context (struct-out read-context) with-read-context
         audit-read! audit-read-denied! audit-presign-issued!
         object-reads READ-DOORS)

;; The doors a read can arrive through. A CLOSED vocabulary, like WORKER-STATES
;; and EXTRACT-REASONS: an export groups by it, so a door invented in passing
;; would arrive as a value nothing explains.
(define READ-DOORS '("api" "s3" "presign" "worker" "plugin" "run" "internal"))

;; `via`        — one of READ-DOORS. Defaults to "internal", which is honest: a
;;                read from a path that set no context is not an API read, and
;;                guessing "api" would put a false client in the record.
;; `ip` / `ua`  — the CLIENT's, carried from the listener that accepted the
;;                request; #f where there is no client (a scheduler job).
;; `request-id` — correlates the events of one request. An inbound
;;                `X-Request-Id` is honoured so a proxy's id is the one in the
;;                record; otherwise the server mints one.
;; `range`      — the REQUESTED range header, verbatim, for r2's "byte range if
;;                partial". Deliberately the request's own words rather than the
;;                satisfied range: `aws s3 cp` issues parallel ranged GETs and
;;                what an auditor needs is what each client ASKED for, beside the
;;                object's size, which the entry also carries.
;; `actor`      — an override for a read that is not a person's: the run id for a
;;                workflow step, the executor id for a worker. The principal is
;;                still the job's own user, because that is who `can?` answered
;;                for; the actor says which machine asked on their behalf.
(struct read-context (via ip ua request-id range actor-type actor-id) #:transparent)

(define current-read-context
  (make-parameter (read-context "internal" #f #f #f #f #f #f)))

(define (with-read-context ctx thunk) (parameterize ([current-read-context ctx]) (thunk)))

(define (ctx-field f [d #f]) (or (f (current-read-context)) d))

;; A fresh id when no request named one, so every entry can be correlated even
;; on a path that has no listener in front of it.
(define (request-id-or-new) (or (read-context-request-id (current-read-context)) (new-id)))

;; r2: ids, never the key. An object key is operator-authored and routinely
;; carries a name, a case number or a national id — `inbox/tanaka-hiroshi/…` —
;; so the entry stores the object and version ids and lets the key be joined
;; from `repo_objects` under the access control that table already has. This is
;; also why the trigger-failure entry stopped carrying `key` (ENC-20).
(define (read-meta obj #:extra [extra (hasheq)])
  (define base
    (hasheq 'via (ctx-field read-context-via "internal")
            'object_id (hash-ref obj 'id)
            'version_id (hash-ref obj 'version_id (lambda () 'null))))
  (define with-size
    (let ([s (hash-ref obj 'size #f)]) (if s (hash-set base 'size s) base)))
  (define with-range
    (let ([r (ctx-field read-context-range)])
      (if r (hash-set with-size 'range r) with-size)))
  (for/fold ([m with-range]) ([(k v) (in-hash extra)]) (hash-set m k v)))

;; The action distinguishes a PRESIGN REDEMPTION from an ordinary read, because
;; #84's acceptance criterion is "the export shows issuance and redemption" and a
;; reader should not have to know that `via = "presign"` means the second one.
(define (read-action)
  (if (equal? (ctx-field read-context-via) "presign") "repo.presign.redeemed" "repo.read"))

(define (actor-of p)
  (define t (ctx-field read-context-actor-type))
  (if t (values t (ctx-field read-context-actor-id)) (values "user" (principal-user-id p))))

(define (record! conn p obj action result #:extra [extra (hasheq)])
  (define-values (atype aid) (actor-of p))
  (audit! conn #:action action #:actor-type atype #:actor-id aid
          #:team-id (hash-ref obj 'team_id)
          #:org-id (hash-ref obj 'org_id 'null)
          #:resource-type "repo" #:resource-id (hash-ref obj 'id)
          #:result result
          #:ip (ctx-field read-context-ip)
          #:user-agent (ctx-field read-context-ua)
          #:request-id (request-id-or-new)
          #:meta (jsexpr->string (read-meta obj #:extra extra))))

(define (audit-read! conn p obj) (record! conn p obj (read-action) "ok"))

;; r4: a refused read is recorded with the SAME shape. This matters more than the
;; allowed one — a cross-org attempt or a missing scope is the event an auditor is
;; looking for — and it is recorded even where the API deliberately answers "does
;; not exist or is not yours" as one answer (the knowledge graph's rule, PULL-9's,
;; and the derive warrant's). The caller is told one thing; the record says which.
(define (audit-read-denied! conn p obj perm)
  (record! conn p obj (read-action) "denied" #:extra (hasheq 'permission perm)))

;; Issuance is its own event and NOT a read: nothing was read when a link was
;; minted. It is recorded where the link is signed, because that is the only
;; place that knows the expiry — and the expiry is the whole of what makes an
;; outstanding link worth auditing.
(define (audit-presign-issued! conn p obj #:expires-in secs)
  (record! conn p obj "repo.presign.issued" "ok" #:extra (hasheq 'expires_in secs)))

;; ---- reading the record back ----------------------------------------------------
;; "Who viewed this document, when, from where" is the question #84 opens with, so
;; the events need a surface or they are written and invisible. Scoped to ONE
;; object, because that is the question; the org-wide export by date range is r3.
;;
;; GATED ON `files:manage`, not on `files:read`. Who has looked at a document is
;; information about the PEOPLE, not about the document: a colleague with a view
;; grant should not be able to enumerate everyone else who opened it. `manage` is
;; what DSH-2 already requires for re-sharing and for changing visibility — the
;; permission that means "you decide who sees this" — so it is the right one for
;; "you may see who did".
;; `#:resource` is the caller's `obj->resource`, PASSED IN rather than rebuilt
;; here. repo.rkt requires this module, so the dependency can only run one way and
;; the triple cannot be imported — and writing a second copy of the shape `can?`
;; reads is the drift that makes an authorization check quietly stop matching.
;; repo.rkt exports the one implementation; this module asks for its answer.
(define (object-reads conn p obj #:resource resource #:limit [lim 100] #:offset [off 0])
  (require-perm conn p "files:manage" #:resource resource)
  (for/list ([r (in-list (query-rows conn
      (string-append
       "SELECT action, actor_type, actor_id, result, at, client_ip, user_agent, request_id, meta "
       "FROM audit_log WHERE resource_type = 'repo' AND resource_id = ? "
       ;; the four read actions, named rather than pattern-matched: a LIKE
       ;; 'repo.%' would also sweep in create, update, delete and share, which
       ;; this read is deliberately not about
       "AND action IN ('repo.read', 'repo.presign.redeemed', 'repo.presign.issued') "
       ;; issue #47's ordering: `at` first because it is right for rows written
       ;; before at_us existed, then the microsecond, then the id
       "ORDER BY at DESC, at_us DESC, id DESC LIMIT ? OFFSET ?")
      (hash-ref obj 'id) lim off))])
    (define m (with-handlers ([exn:fail? (lambda (_) (hasheq))])
                (let ([v (vector-ref r 8)]) (if (sql-null? v) (hasheq) (string->jsexpr v)))))
    (hasheq 'action (vector-ref r 0)
            'actor_type (nz (vector-ref r 1)) 'actor_id (nz (vector-ref r 2))
            'result (nz (vector-ref r 3)) 'at (format "~a" (vector-ref r 4))
            'client_ip (nz (vector-ref r 5)) 'user_agent (nz (vector-ref r 6))
            'request_id (nz (vector-ref r 7))
            'via (hash-ref m 'via 'null)
            'version_id (hash-ref m 'version_id 'null)
            'range (hash-ref m 'range 'null)
            ;; on a denied entry: WHAT the reader lacked. Absent on an allowed
            ;; one, rather than reported as the permission they had — the field
            ;; only ever answers "why was this refused".
            'permission (hash-ref m 'permission 'null)
            ;; on an issuance: how long the link it minted lives, which is the
            ;; whole of what makes an outstanding link worth auditing
            'expires_in (hash-ref m 'expires_in 'null))))
