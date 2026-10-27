#lang racket/base

;; server/api/repo.rkt — the document repository, its metadata, its shares
;; and its S3 keys
;;
;; Split out of main.rkt by #110 r3. The shared surface every handler here
;; needs — the pool, the request accessors, with-auth/with-mt, the response
;; constructors — is server/kit.rkt.

(provide ep-repo-fields-get ep-repo-fields-put ep-repo-attributes
         ep-repo-spans ep-repo-form-fields ep-repo-put ep-repo-list ep-repo-meta ep-repo-get
         ep-repo-visibility ep-repo-share ep-repo-unshare ep-repo-grants
         ep-repo-processing ep-share-targets ep-repo-derivations
         ep-repo-reads ep-repo-presign ep-s3-creds ep-s3-cred-create
         ep-s3-cred-revoke s3-port ep-repo-delete ep-repo-delete-prefix
         ep-repo-traces)

(require racket/string
         racket/port
         db-kit/portable
         web-server/http
         web-kit
         (only-in "../../config.rkt" max-upload-bytes)
         (only-in "../../domain/authz/authz.rkt" audit! principal-team-id principal-user-id require-perm team-org)
         (only-in "../../domain/orgs/orgs.rkt" org-teams)
         (only-in "../../domain/s3/server.rkt" s3-region)
         (only-in "../../domain/s3/sigv4.rkt" aws-uri-encode presign-query)
         (only-in "../../domain/s3/creds.rkt" s3-cred-issue! s3-cred-list s3-cred-newest s3-cred-revoke!)
         "../../domain/repo/repo.rkt"
         (only-in "../../domain/audit/reads.rkt" audit-presign-issued! object-reads)
         (only-in "../../domain/repo/extract.rkt" repo-spans-for spans-covering)
         ;; #88 req 2: what fields a form carries, so a caller knows what to send
         ;; `doc_fill_form`. The engine is pure of the repository; the `can?` is here.
         (only-in "../../domain/repo/pdfform.rkt" FORM-FIELD-KINDS pdfcpu-path pdf-form-fields qpdf-path)
         (only-in "../../domain/repo/triggers.rkt" object-processing)
         (only-in "../../domain/i18n/i18n.rkt" t)
         "../kit.rkt")

;; ---- document repository (slices 49-50) --------------------------------------
;; The data plane is deliberately NOT JSON: a document is bytes, and base64 inside a
;; JSON envelope costs a third of the wire and forces the whole file into memory at
;; both ends. Upload is a raw body with the key in the path; download streams back.
;;
;; This is the control plane the S3 front door will NOT replace (DOC-12) — sharing,
;; grants and visibility have no expression in the S3 protocol.

;; ---- team-defined object metadata (LAY-4) and extraction provenance (LAY-5) -------
;; ?attr=key:value, repeatable. Split on the FIRST colon only, so a value may
;; contain one — "location:lat:lon" is a location, not a malformed filter.
(define (attr-filters req)
  (for/list ([v (in-list (query-params req 'attr))]
             #:when (regexp-match? #rx":" v))
    (let ([i (car (regexp-match-positions #rx":" v))])
      (cons (substring v 0 (car i)) (substring v (cdr i))))))

(define (ep-repo-fields-get req)
  (with-auth req (lambda (p)
    (require-perm db-conn p "files:read")
    (json-response (hasheq 'fields (repo-fields db-conn (principal-team-id p)))))))

(define (ep-repo-fields-put req)
  (with-auth req (lambda (p)
    (require-perm db-conn p "settings:manage")
    (define fs (let ([v (hash-ref (read-json-body req) 'fields '())]) (if (list? v) v '())))
    (define out (repo-fields-set! db-conn (principal-team-id p) fs))
    (cond
      [(string? out) (err out 400)]
      [else
       (audit! db-conn #:action "repo.fields" #:actor-type "user" #:actor-id (principal-user-id p)
               #:team-id (principal-team-id p) #:resource-type "repo" #:resource-id "fields")
       (json-response (hasheq 'fields out))]))))

(define (ep-repo-attributes req id)
  (with-auth req (lambda (p)
    (require-perm db-conn p "files:read")
    (define a (let ([v (hash-ref (read-json-body req) 'attributes (hasheq))]) (if (hash? v) v (hasheq))))
    (define out (repo-set-attributes! db-conn p id a))
    (cond
      [(eq? out 'no-such-object) (err "no such document" 404)]
      [(eq? out 'forbidden) (err "forbidden: files:write" 403)]
      [(string? out) (err out 400)]
      [else
       (audit! db-conn #:action "repo.attributes" #:actor-type "user" #:actor-id (principal-user-id p)
               #:team-id (principal-team-id p) #:resource-type "repo" #:resource-id id)
       (json-response (obj-json out))]))))

(define (ep-repo-spans req id)
  (with-auth req (lambda (p)
    (require-perm db-conn p "files:read")
    (define o (repo-get db-conn p id))
    (cond
      [(not o) (err "no such document" 404)]
      [else
       (define all (repo-spans-for db-conn id))
       (define at (string->number (query-param req 'at "")))
       (json-response (hasheq 'object_id id
                              'spans (if at (spans-covering all at) all)
                              'total (length all)))]))))

;; ---- a form's fields (#88 req 2) ---------------------------------------------
;; Requirement 2's discovery half. `files:read`, because it is a reading of the
;; document — a form's field names are part of what the document SAYS, and
;; somebody who may read the PDF may read them out of it by hand anyway.
;;
;; A PDF with no form answers `fields: []`, not an error: whether a document is a
;; form is exactly what the caller is asking. A box with no pdfcpu answers 501
;; rather than 500 — the question is fine and this instance cannot answer it,
;; which is the S3 listener's rule for an unimplemented sub-resource.
(define (ep-repo-form-fields req id)
  (with-auth req (lambda (p)
    (require-perm db-conn p "files:read")
    (define o (repo-get db-conn p id))
    (cond
      [(not o) (err "no such document" 404)]
      [(not (pdfcpu-path))
       (err "this instance cannot read PDF form fields — pdfcpu is not on the server's PATH" 501)]
      [else
       (define-values (_o in) (repo-open db-conn p id))
       (define bs (if in
                      (dynamic-wind void (lambda () (port->bytes in)) (lambda () (close-input-port in)))
                      #""))
       ;; The engine's own message comes through, because it describes the
       ;; DOCUMENT's structure — which the caller can already read, holding
       ;; `files:read` on it — and because a timeout and a malformed xref table
       ;; have different remedies. #123's line: a 400 may carry what a 500 may
       ;; not, and the line is who supplied the input.
       (define-values (fields problem)
         (with-handlers ([exn:fail? (lambda (e) (values #f (exn-message e)))])
           (values (pdf-form-fields bs #:who 'form-fields) #f)))
       (cond
         [problem (err problem 400)]
         [else
          (json-response (hasheq 'object_id id 'key (hash-ref o 'key)
                                 'content_type (hash-ref o 'content_type)
                                 'fields fields 'kinds FORM-FIELD-KINDS
                                 ;; flattening is a SECOND binary, so a caller is
                                 ;; told whether `flatten: true` will work here
                                 ;; rather than finding out from a refusal
                                 'can_flatten (and (qpdf-path) #t)))])]))))

(define (obj-json o)
  (hasheq 'id (hash-ref o 'id) 'key (hash-ref o 'key)
          'visibility (hash-ref o 'visibility) 'owner_user_id (hash-ref o 'owner_user_id)
          'size (hash-ref o 'size) 'content_type (hash-ref o 'content_type)
          'filename (hash-ref o 'filename) 'version (hash-ref o 'version)
          'digest (hash-ref o 'digest)
          'created_at (hash-ref o 'created_at) 'updated_at (hash-ref o 'updated_at)
          'attributes (hash-ref o 'attributes (hasheq))))

;; Uploads land as the raw request body. `request-post-data/raw` buffers it, which is
;; why TELEMACHUS_MAX_UPLOAD exists and why DOC-15's listener is the next slice — the
;; port handed to repo-put! is honest about streaming even though what feeds it today
;; is not.
(define (ep-repo-put req key)
  (with-auth req (lambda (p)
    (with-handlers ([exn:fail:user? (lambda (e) (err (exn-message e) 400))])
      (define raw (or (request-post-data/raw req) #""))
      (define o (repo-put! db-conn p
                           #:key key
                           #:port (open-input-bytes raw)
                           #:content-type (or (req-header req #"content-type") "application/octet-stream")
                           #:filename (query-param req 'filename "")
                           #:visibility (let ([v (query-param req 'visibility "")])
                                          (and (member v VISIBILITIES) v))
                           #:max-bytes (max-upload-bytes)))
      (json-response (obj-json o) #:code 201)))))

(define (ep-repo-list req)
  (with-auth req (lambda (p)
    (define objs (repo-list db-conn p
                            #:prefix (query-param req 'prefix "")
                            #:limit (or (string->number (query-param req 'limit "100")) 100)
                            #:offset (or (string->number (query-param req 'offset "0")) 0)
                            #:shared-with-me? (member (query-param req 'shared "") '("1" "true" "yes"))
                            #:scope (scope-of req)
                            #:attrs (attr-filters req)))
    (json-response (hasheq 'objects (map obj-json objs)
                           'usage (repo-usage db-conn p))))))

(define (ep-repo-meta req id)
  (with-auth req (lambda (p)
    (define o (repo-get db-conn p id))
    (if o
         (json-response (hash-set (obj-json o) 'versions (repo-versions db-conn p id)))
         (err "not found" 404)))))

;; DOC-10: every document is served as an attachment with nosniff and a
;; script-denying CSP unless its type is on the short inline allowlist. An SVG
;; rendered inline from this origin is stored XSS with the console behind it, and
;; "any format" was a requirement about what may be STORED, not about what a browser
;; may be talked into executing.
(define (ep-repo-get req id)
  (with-auth req (lambda (p)
    (define-values (o in) (repo-open db-conn p id
                                     #:version (let ([v (query-param req 'version "")])
                                                 (and (not (string=? v "")) v))))
    (cond
      [(not in) (err "not found" 404)]
      [else
       (define ct (hash-ref o 'content_type))
       (define inline? (and (inline-safe? ct) (equal? (query-param req 'disposition "") "inline")))
       (define fname (let ([f (hash-ref o 'filename)])
                       (if (string=? f "") (car (reverse (string-split (hash-ref o 'key) "/"))) f)))
       (define safe-name (regexp-replace* #px"[^A-Za-z0-9._-]" fname "_"))
       (response/output
        #:mime-type (string->bytes/utf-8 (if inline? ct "application/octet-stream"))
        #:headers (list (make-header #"X-Content-Type-Options" #"nosniff")
                        (make-header #"Content-Security-Policy" #"default-src 'none'; sandbox")
                        (make-header #"Cache-Control" #"private, max-age=0, must-revalidate")
                        (make-header #"ETag" (string->bytes/utf-8 (string-append "\"" (hash-ref o 'digest) "\"")))
                        (make-header #"Content-Disposition"
                                     (string->bytes/utf-8
                                      (string-append (if inline? "inline" "attachment")
                                                     "; filename=\"" safe-name "\""))))
         (lambda (out)
          (dynamic-wind void
                        (lambda () (copy-port in out))
                        (lambda () (close-input-port in)))))]))))

(define (ep-repo-visibility req id)
  (with-auth req (lambda (p)
    (with-handlers ([exn:fail:user? (lambda (e) (err (exn-message e) 400))])
      (define v (fmt (read-json-body req) 'visibility))
      (define o (repo-set-visibility! db-conn p id v))
      (if o (json-response (obj-json o)) (err "not found" 404))))))

;; Sharing (DSH). The body names a principal — `{principal_type, principal_id}` —
;; and a capability (view | edit | manage, default view) with an optional
;; `expires_at` (ISO-8601 or epoch seconds). The original `{user_id}` still works
;; and means "this person, view", so existing callers are untouched.
(define (share-principal b)
  (define legacy (fmt b 'user_id))
  (define ptype  (fmt b 'principal_type))
  (define pid    (fmt b 'principal_id))
  (values (if (string=? ptype "") (if (string=? legacy "") #f "user") ptype)
          (if (string=? pid "") legacy pid)))

(define (ep-repo-share req id)
  (with-auth req (lambda (p)
    (with-handlers ([exn:fail:user? (lambda (e) (err (exn-message e) 400))])
      (define b (read-json-body req))
      (define-values (ptype pid) (share-principal b))
      (define cap (let ([c (fmt b 'capability)]) (if (string=? c "") "view" c)))
      (define exp (expiry->seconds (hash-ref b 'expires_at #f)))
      (cond
        [(string=? pid "") (err "principal_id (or user_id) is required" 400)]
        [(repo-share! db-conn p id #:principal-type ptype #:principal-id pid
                      #:capability cap #:expires-at exp)
         (json-response (hasheq 'ok #t 'grants (repo-grants db-conn p id)))]
        [else (err "not found" 404)])))))

(define (ep-repo-unshare req id)
  (with-auth req (lambda (p)
    (with-handlers ([exn:fail:user? (lambda (e) (err (exn-message e) 400))])
      (define-values (ptype pid) (share-principal (read-json-body req)))
      (cond
        [(string=? pid "") (err "principal_id (or user_id) is required" 400)]
        [(repo-unshare! db-conn p id #:principal-type ptype #:principal-id pid)
         (json-response (hasheq 'ok #t 'grants (repo-grants db-conn p id)))]
        [else (err "not found" 404)])))))

(define (ep-repo-grants req id)
  (with-auth req (lambda (p)
    (define g (repo-grants db-conn p id))
    (if g (json-response (hasheq 'grants g)) (err "not found" 404)))))

;; "Processed by": derived documents, sources, and every run that touched it (DWF step 4)
(define (ep-repo-processing req id)
  (with-auth req (lambda (p)
    (define r (object-processing db-conn p id))
    (if r (json-response r) (err "not found" 404)))))

;; who a document can be shared with: the team's people and the org's teams (DSH-6)
(define (ep-share-targets req)
  (with-auth req (lambda (p)
    (require-perm db-conn p "files:read")
    (define users
      (for/list ([r (in-list (query-rows db-conn
                       (string-append "SELECT u.id, u.username FROM memberships m JOIN users u ON u.id = m.user_id "
                                      "WHERE m.team_id = ? AND m.status = 'active' ORDER BY u.username")
                       (principal-team-id p)))])
         (hasheq 'user_id (vector-ref r 0) 'username (vector-ref r 1))))
    (define org (team-org db-conn (principal-team-id p)))
    (define teams
      (for/list ([t (in-list (if org (org-teams db-conn org) '()))])
         (hasheq 'id (hash-ref t 'id) 'name (hash-ref t 'name) 'slug (hash-ref t 'slug)
                'own (equal? (hash-ref t 'id) (principal-team-id p)))))
    (json-response (hasheq 'users users 'teams teams)))))

;; provenance: what a derived document was made from (DSH-5 / DWF-4)
(define (ep-repo-derivations req id)
  (with-auth req (lambda (p)
    (define d (repo-derivations db-conn p id))
    (if d (json-response (hasheq 'derivations d)) (err "not found" 404)))))

;; A presigned link: a time-boxed URL a browser can follow with no bearer token, so
;; the console can hand a PDF straight to the viewer. Signed with the CALLER'S OWN
;; newest S3 key, which means the link can never do more than that key can, and
;; revoking the key kills every link made with it.
;; "Who viewed this document, when, from where" (issue #84) — the question the
;; issue opens with, and the reason the events need a surface at all.
;;
;; The ROUTE's permission is `files:read`, which only gets you as far as the
;; object; `object-reads` then requires `files:manage` ON THAT OBJECT, because who
;; has looked at a document is information about the PEOPLE rather than about the
;; document. A colleague with a view grant must not be able to enumerate everyone
;; else who opened it. `manage` is already what DSH-2 requires to re-share or to
;; change visibility — the permission that means "you decide who sees this".
(define (ep-repo-reads req id)
  (with-auth req (lambda (p)
    (define o (repo-get db-conn p id))
    (cond
      [(not o) (err "not found" 404)]
      [else
       (define lim (max 1 (min 500 (or (string->number (query-param req 'limit "100")) 100))))
       (define off (max 0 (or (string->number (query-param req 'offset "0")) 0)))
       (json-response (hasheq 'object_id id
                              'reads (object-reads db-conn p o #:resource (obj->resource o)
                                                   #:limit lim #:offset off)))]))))

(define (ep-repo-presign req id)
  (with-auth req (lambda (p)
    (define o (repo-get db-conn p id))
    (define port (s3-port))
    (define cred (and o (s3-cred-newest db-conn p)))
    (cond
      [(not o) (err "not found" 404)]
      [(not port) (err "the S3 endpoint is not enabled on this instance (set TELEMACHUS_S3_PORT)" 409)]
      [(not cred) (err "create an S3 access key first — a link is signed with one" 409)]
      [else
       (define secs (max 1 (min 604800 (or (string->number (query-param req 'expires "900")) 900))))
       (define host (format "~a:~a" (if (equal? (bind-ip) "0.0.0.0") "127.0.0.1" (bind-ip)) port))
       ;; the key is signed in the form it will be sent, so encode once, here
       (define encoded-key
         (string-join (map (lambda (seg) (aws-uri-encode seg))
                           (string-split (hash-ref o 'key) "/")) "/"))
       (define path (string-append "/" (team-slug-of p) "/" encoded-key))
       (define qs (presign-query #:method "GET" #:path path
                                 #:access-key (car cred) #:secret (cdr cred)
                                 #:region (s3-region) #:host host #:expires secs))
       ;; r1: issuance is its own event, recorded where the expiry is known. An
       ;; outstanding link is the one read capability that outlives the request
       ;; that made it, so "who minted a link to this, and for how long" is a
       ;; question only this call site can answer.
       (audit-presign-issued! db-conn p o #:expires-in secs)
       (json-response (hasheq 'url (format "http://~a~a?~a" host path qs)
                              'expires_in secs
                              'key (hash-ref o 'key)))]))))

(define (ep-s3-creds req)
  (with-auth req (lambda (p) (json-response (hasheq 'credentials (s3-cred-list db-conn p)
                                                    'endpoint (s3-endpoint-url)
                                                    'region (s3-region)
                                                    'bucket (team-slug-of p))))))

(define (ep-s3-cred-create req)
  (with-auth req (lambda (p)
    (define b (read-json-body req))
    (define scopes (let ([v (hash-ref b 'scopes #f)])
                     (and (list? v) (andmap string? v) v)))
    ;; the secret is in this response and in no other, ever. With no scopes given the
    ;; issuer's own default applies — repeating a list here would silently shadow it.
    (json-response (if scopes
                       (s3-cred-issue! db-conn p #:name (fmt b 'name) #:scopes scopes)
                       (s3-cred-issue! db-conn p #:name (fmt b 'name)))
                   #:code 201))))

(define (ep-s3-cred-revoke req id)
  (with-auth req (lambda (p) (s3-cred-revoke! db-conn p id) (json-response (hasheq 'ok #t)))))

(define (team-slug-of p)
  (define v (query-maybe-value db-conn "SELECT slug FROM teams WHERE id = ?" (principal-team-id p)))
  (if (string? v) v ""))

;; What a client must be told to reach us: S3 lives on its own port because its
;; transport requirements differ (Expect: 100-continue, unbuffered bodies), and
;; path-style addressing because virtual-host style would need wildcard DNS.
(define (s3-port)
  (define raw (env* "TELEMACHUS_S3_PORT"))
  (define n (and raw (string->number raw)))
  (and n (exact-positive-integer? n) n))

(define (s3-endpoint-url)
  (define p (s3-port))
  (and p (format "http://~a:~a" (if (equal? (bind-ip) "0.0.0.0") "<host>" (bind-ip)) p)))

;; `?cascade=1` / `?detach=1` / `?dry_run=1` (issue #86 r1). Without cascade this
;; is exactly what it was: one object, one blob-release pass.
;;
;; `query-param`'s default is "" and an empty string is TRUE in Racket, so these
;; are compared against a value rather than tested for truth — the trap that made
;; every bundle sub-resource 401 the first time (issue #43).
(define (flag? req name)
  (member (query-param req name) '("1" "true" "yes" "on")))

(define (ep-repo-delete req id)
  (with-auth req (lambda (p)
    (cond
      [(flag? req 'cascade)
       (define r (repo-delete-tree! db-conn p id
                                    #:detach? (and (flag? req 'detach) #t)
                                    #:dry-run? (and (flag? req 'dry_run) #t)))
       (if r (json-response (hash-set r 'ok #t)) (err "not found" 404))]
      [(flag? req 'dry_run)
       ;; A dry run without cascade still answers, so a caller can ask "what would
       ;; this delete cost me" uniformly rather than only on the cascade path.
       (define r (repo-delete-tree! db-conn p id #:detach? #t #:dry-run? #t))
       (if r (json-response (hash-set (hash-set r 'detached '()) 'ok #t)) (err "not found" 404))]
      [else
       (if (repo-delete! db-conn p id) (json-response (hasheq 'ok #t 'id id)) (err "not found" 404))]))))

(define (ep-repo-delete-prefix req)
  (with-auth req (lambda (p)
    (define prefix (query-param req 'prefix))
    (with-handlers ([exn:fail:user? (lambda (e) (err (exn-message e) 400))])
      (json-response
       (hash-set (repo-delete-prefix! db-conn p prefix
                                      #:confirm? (and (flag? req 'confirm) #t)
                                      ;; cascade is ON unless explicitly turned off:
                                      ;; leaving derivatives behind is what #86 r1
                                      ;; exists to stop, so it is not the default
                                      #:cascade? (not (member (query-param req 'cascade) '("0" "false" "no" "off"))))
                 'ok #t))))))

(define (ep-repo-traces req id)
  (with-auth req (lambda (p)
    (define r (repo-traces db-conn p id))
    (if r (json-response r) (err "not found" 404)))))
