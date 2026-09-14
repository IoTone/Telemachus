#lang racket/base

;; test/repo-tests.rkt — slices 49 & 50: the document repository.
;;   raco test test/repo-tests.rkt   (from refimpl/racketmaximus/, pkgs on PLTCOLLECTS)
;;
;; What this has to prove, in the order the requirement stated it:
;;   1. any format goes in and comes back byte-identical
;;   2. the CREATOR sets visibility, and a colleague is refused accordingly
;;   3. an overwrite versions rather than destroys
;;   4. identical bytes are stored once, and deleting one copy does not break the other
;;   5. none of it leaks across an org boundary
;;   6. storage is metered as a gauge that goes back down
;;   7. sharing with permissions: capabilities, teams, expiry, inheritance (slice 56)

(require rackunit db-kit/portable
         racket/file racket/port racket/list racket/date
         db-kit/migrate
         "../domain/db/migrations.rkt"
         "db-fixture.rkt"
         "../domain/authz/authz.rkt"
         "../domain/quota/quota.rkt"
         "../domain/repo/blobs.rkt"
         (only-in "../config.rkt" data-dir)
         "../domain/repo/repo.rkt")

;; ---- fixtures -----------------------------------------------------------------
(define BLOB-ROOT (make-temporary-file "telemachus-blobs-~a" 'directory))
(current-blob-root BLOB-ROOT)

(define (fresh)
  (define conn (fresh-db #:migrate? #f))
  (migrate! conn all-migrations)
  conn)

(define (owner-of conn #:org [org "Acme"] #:slug [slug "acme"] #:user [user "root"])
  (define-values (u team)
    (bootstrap! conn #:username user #:org-name org #:org-slug slug
                #:team-name "Engineering" #:team-slug "engineering"))
  (values (user-principal conn u team) team))

(define (member-of conn team username #:role [role "member"])
  (define u (create-user! conn #:username username #:password "pw"))
  (add-member! conn #:user u #:team team #:role role)
  (values (user-principal conn u team) u))

(define (put! conn p key bytes #:type [ct "application/octet-stream"] #:vis [vis #f])
  (repo-put! conn p #:key key #:port (open-input-bytes bytes)
             #:content-type ct #:filename "f" #:visibility vis))

(define (read-back conn p id)
  (define-values (o in) (repo-open conn p id))
  (and in (let ([bs (port->bytes in)]) (close-input-port in) bs)))

;; ---- 1. any format round-trips byte-identically --------------------------------
;; The requirement lists pdf, svg, png, jpg, docx, xml, txt, md. What actually
;; matters is that nothing assumes UTF-8 or text, so these payloads include NUL,
;; invalid UTF-8, and a byte range that would break a naive string round-trip.
(let-values ([(conn) (fresh)])
  (define-values (p team) (owner-of conn))
  (define cases
    (list (cons "doc.pdf"  (bytes-append #"%PDF-1.7\n" (make-bytes 300 0) #"\xff\xfe\x00trailer"))
          (cons "logo.svg" #"<svg xmlns='http://www.w3.org/2000/svg'><script>alert(1)</script></svg>")
          (cons "a/b/c.png" (apply bytes (for/list ([i (in-range 256)]) i)))
          (cons "sheet.docx" (bytes-append #"PK\x03\x04" (make-bytes 1000 200)))
          (cons "notes.md" #"# hello\n\nsome *markdown*\n")
          (cons "feed.xml" #"<?xml version=\"1.0\"?><r>\xc3\x28</r>")))   ; invalid UTF-8 on purpose
  (for ([c (in-list cases)])
    (define o (put! conn p (car c) (cdr c)))
    (check-equal? (read-back conn p (hash-ref o 'id)) (cdr c)
                  (format "~a round-trips byte-identically" (car c)))
    (check-equal? (hash-ref o 'size) (bytes-length (cdr c))))
  ;; …and the listing sees all of them
  (check-equal? (length (repo-list conn p)) (length cases))
  (check-equal? (map (lambda (o) (hash-ref o 'key)) (repo-list conn p #:prefix "a/"))
                '("a/b/c.png"))
  (disconnect conn))

;; ---- 2. the creator sets visibility --------------------------------------------
(let-values ([(conn) (fresh)])
  (define-values (owner team) (owner-of conn))
  (define-values (alice _a) (member-of conn team "alice"))
  (define-values (bob _b) (member-of conn team "bob"))

  (define priv (repo-put! conn alice #:key "secret.txt" #:port (open-input-bytes #"sshh")
                          #:visibility "private"))
  (define shared (repo-put! conn alice #:key "team.txt" #:port (open-input-bytes #"hello")
                            #:visibility "team"))

  ;; the creator reads their own private object
  (check-equal? (read-back conn alice (hash-ref priv 'id)) #"sshh")
  ;; a colleague cannot — not by id, and not by seeing it in a listing
  (check-exn exn:fail:forbidden? (lambda () (repo-get conn bob (hash-ref priv 'id))))
  (check-equal? (map (lambda (o) (hash-ref o 'key)) (repo-list conn bob)) '("team.txt")
                "a private object does not appear in a colleague's listing")
  ;; the team-visible one is readable by the colleague
  (check-equal? (read-back conn bob (hash-ref shared 'id)) #"hello")

  ;; the creator can open it up afterwards, and only the creator can
  (check-exn exn:fail:forbidden?
             (lambda () (repo-set-visibility! conn bob (hash-ref priv 'id) "team")))
  (repo-set-visibility! conn alice (hash-ref priv 'id) "team")
  (check-equal? (read-back conn bob (hash-ref priv 'id)) #"sshh")

  ;; …and close it again, then hand it to exactly one person
  (repo-set-visibility! conn alice (hash-ref priv 'id) "private")
  (check-exn exn:fail:forbidden? (lambda () (repo-get conn bob (hash-ref priv 'id))))
  (repo-share! conn alice (hash-ref priv 'id) #:user _b)
  (check-equal? (read-back conn bob (hash-ref priv 'id)) #"sshh"
                "an explicit grant reaches a private object")
  (check-equal? (length (repo-grants conn alice (hash-ref priv 'id))) 1)
  (repo-unshare! conn alice (hash-ref priv 'id) #:user _b)
  (check-exn exn:fail:forbidden? (lambda () (repo-get conn bob (hash-ref priv 'id)))
             "revoking the grant closes it again")

  ;; a colleague may not overwrite a private object they cannot even read
  (repo-set-visibility! conn alice (hash-ref shared 'id) "private")
  (check-exn exn:fail:forbidden?
             (lambda () (put! conn bob "team.txt" #"clobbered")))
  (disconnect conn))

;; ---- 3. overwrite versions, it does not destroy ---------------------------------
(let-values ([(conn) (fresh)])
  (define-values (p team) (owner-of conn))
  (define v1 (put! conn p "report.txt" #"first draft"))
  (define v2 (put! conn p "report.txt" #"second draft"))
  (check-equal? (hash-ref v1 'id) (hash-ref v2 'id) "the object id is stable across a rewrite")
  (check-equal? (hash-ref v2 'version) 2)
  (check-equal? (read-back conn p (hash-ref v2 'id)) #"second draft")

  (define vs (repo-versions conn p (hash-ref v2 'id)))
  (check-equal? (length vs) 2)
  (check-equal? (map (lambda (v) (hash-ref v 'version)) vs) '(2 1) "newest first")
  (check-true (hash-ref (first vs) 'current))

  ;; the old bytes are still reachable by version id
  (define old (findf (lambda (v) (= 1 (hash-ref v 'version))) vs))
  (define-values (_o in) (repo-open conn p (hash-ref v2 'id) #:version (hash-ref old 'id)))
  (check-equal? (port->bytes in) #"first draft" "an earlier version is still readable")
  (close-input-port in)

  (disconnect conn))

;; visibility is preserved across an overwrite unless the caller asks otherwise
(let-values ([(conn) (fresh)])
  (define-values (p team) (owner-of conn))
  (define o (put! conn p "k.txt" #"one" #:vis "private"))
  (define o2 (put! conn p "k.txt" #"two"))
  (check-equal? (hash-ref o2 'visibility) "private"
                "an overwrite does not re-open a private document")
  (define o3 (put! conn p "k.txt" #"three" #:vis "team"))
  (check-equal? (hash-ref o3 'visibility) "team" "…but an explicit change still applies")
  (disconnect conn))

;; ---- 4. deduplication, and that deleting one copy keeps the other -------------
(let-values ([(conn) (fresh)])
  (define-values (p team) (owner-of conn))
  (define payload (make-bytes 4096 42))
  (define a (put! conn p "a.bin" payload))
  (define b (put! conn p "b.bin" payload))
  (check-equal? (hash-ref a 'digest) (hash-ref b 'digest) "identical bytes share one address")
  (define org (hash-ref a 'org_id))
  (check-equal? (blob-size org (hash-ref a 'digest)) 4096 "stored exactly once")

  (repo-delete! conn p (hash-ref a 'id))
  (check-false (repo-get conn p (hash-ref a 'id)) "the deleted object is gone")
  (check-equal? (read-back conn p (hash-ref b 'id)) payload
                "the surviving object still resolves — the blob was not collected")

  (repo-delete! conn p (hash-ref b 'id))
  (check-false (blob-exists? org (hash-ref a 'digest))
               "with the last reference gone, so is the blob")

  ;; the key is reusable after a delete
  (define c (put! conn p "a.bin" #"fresh"))
  (check-equal? (read-back conn p (hash-ref c 'id)) #"fresh")
  (disconnect conn))

;; ---- 5. isolation ----------------------------------------------------------------
(let-values ([(conn) (fresh)])
  (define-values (acme acme-team) (owner-of conn #:org "Acme" #:slug "acme" #:user "acme-root"))
  (define globex-org (create-org! conn #:name "Globex" #:slug "globex"))
  (define globex-team (create-team! conn #:name "Ops" #:slug "ops" #:org globex-org))
  (define gu (create-user! conn #:username "globex-root" #:password "pw"))
  (add-member! conn #:user gu #:team globex-team #:role "owner")
  (define globex (user-principal conn gu globex-team))

  (define secret (repo-put! conn acme #:key "plans.txt" #:port (open-input-bytes #"acme plans")
                            #:visibility "team"))
  (check-exn exn:fail:forbidden?
             (lambda () (repo-get conn globex (hash-ref secret 'id)))
             "the org gate refuses a cross-org read before permissions are consulted")
  (check-equal? (repo-list conn globex) '() "and it is not listed")

  ;; the share API refuses a principal from another company outright (DSH-6)
  (check-exn exn:fail:user? (lambda () (repo-share! conn acme (hash-ref secret 'id) #:user gu))
             "sharing with a user of another org is refused, not silently inert")
  (check-exn exn:fail:user?
             (lambda () (repo-share! conn acme (hash-ref secret 'id) #:principal-type "team" #:principal-id globex-team)))
  ;; even an explicit grant cannot tunnel out of an org — the gate is step 0
  (grant! conn #:resource-type "repo" #:resource-id (hash-ref secret 'id)
          #:principal-type "user" #:principal-id gu #:permission "files:read")
  (check-exn exn:fail:forbidden?
             (lambda () (repo-get conn globex (hash-ref secret 'id)))
             "a grant does not defeat the org gate")

  ;; identical bytes in two orgs are stored twice, on purpose (DOC-6)
  (define payload #"the same exact bytes")
  (define a (repo-put! conn acme #:key "same.bin" #:port (open-input-bytes payload)))
  (define g (repo-put! conn globex #:key "same.bin" #:port (open-input-bytes payload)))
  (check-equal? (hash-ref a 'digest) (hash-ref g 'digest))
  (check-not-equal? (hash-ref a 'org_id) (hash-ref g 'org_id))
  (check-true (and (blob-exists? (hash-ref a 'org_id) (hash-ref a 'digest))
                   (blob-exists? (hash-ref g 'org_id) (hash-ref g 'digest)))
              "each org holds its own copy — no cross-tenant existence oracle")
  ;; deleting one org's copy leaves the other's intact
  (repo-delete! conn acme (hash-ref a 'id))
  (check-false (blob-exists? (hash-ref a 'org_id) (hash-ref a 'digest)))
  (check-true  (blob-exists? (hash-ref g 'org_id) (hash-ref g 'digest)))
  (disconnect conn))

;; ---- 6. storage is a gauge that goes back down -----------------------------------
(let-values ([(conn) (fresh)])
  (define-values (p team) (owner-of conn))
  (check-equal? (hash-ref (repo-usage conn p) 'used) 0)

  (define a (put! conn p "a.bin" (make-bytes 1000 1)))
  (define b (put! conn p "b.bin" (make-bytes 2500 2)))
  (check-equal? (hash-ref (repo-usage conn p) 'used) 3500)
  (check-equal? (hash-ref (repo-usage conn p) 'objects) 2)

  (repo-delete! conn p (hash-ref a 'id))
  (check-equal? (hash-ref (repo-usage conn p) 'used) 2500 "a delete decrements the gauge")

  ;; a limit refuses admission before anything is stored
  (set-limit! conn "team" team STORAGE-DIMENSION 3000 #:window "total")
  (check-exn exn:fail? (lambda () (put! conn p "c.bin" (make-bytes 5000 3)))
             "an over-budget upload is refused")
  (check-equal? (hash-ref (repo-usage conn p) 'used) 2500 "…and nothing was charged for it")
  (check-equal? (length (repo-list conn p)) 1 "…and no row was left behind")
  (disconnect conn))

;; ---- 7. sharing with permissions (slice 56, DSH-1…6) --------------------------------
;; Three capabilities that are permission SETS, granted row by row; only `manage`
;; re-shares; a team is a principal; grants expire; a derived document inherits at
;; creation and is independent afterwards.
(let-values ([(conn) (fresh)])
  (define-values (owner team) (owner-of conn))
  (define-values (alice _a) (member-of conn team "alice"))
  (define-values (bob _b) (member-of conn team "bob"))
  (define-values (carol _c) (member-of conn team "carol"))
  (define priv (put! conn alice "plan.txt" #"v1" #:vis "private"))
  (define pid (hash-ref priv 'id))
  (define (bob-writes!) (put! conn bob "plan.txt" #"v2 by bob"))
  ;; the grant a principal holds on an object, as the steward sees it
  (define (grant-of p* oid who)
    (for/first ([g (in-list (repo-grants conn p* oid))] #:when (equal? (hash-ref g 'principal_id) who)) g))

  ;; the sets nest, and each row says exactly what it says
  (check-equal? (capability-permissions "view") '("files:read"))
  (check-equal? (capability-permissions "edit") '("files:read" "files:write"))
  (check-true (and (member "files:manage" (capability-permissions "manage")) #t))
  (check-false (capability-permissions "owner") "an unknown capability is not a set")
  (check-equal? (permissions->capability '("files:read" "files:write")) "edit")
  (check-false (permissions->capability '("files:write")) "a lone write row is not a capability")

  ;; view: read yes, write no, re-share no (DSH-2)
  (repo-share! conn alice pid #:user _b)                      ; the original spelling = view
  (check-equal? (read-back conn bob pid) #"v1")
  (check-exn exn:fail:forbidden? bob-writes! "a viewer cannot upload a version")
  (check-exn exn:fail:forbidden? (lambda () (repo-share! conn bob pid #:user _c))
             "a viewer cannot forward what they were shown")
  (check-exn exn:fail:forbidden? (lambda () (repo-set-visibility! conn bob pid "team"))
             "…nor widen it")
  (check-exn exn:fail:forbidden? (lambda () (repo-grants conn bob pid))
             "…nor list who else has it")
  (let ([g (grant-of alice pid _b)])
    (check-equal? (hash-ref g 'capability) "view")
    (check-equal? (hash-ref g 'principal_id) _b)
    (check-equal? (hash-ref g 'expires_at) 'null)
    (check-false (hash-ref g 'expired)))

  ;; edit: write yes, re-share still no
  (repo-share! conn alice pid #:principal-type "user" #:principal-id _b #:capability "edit")
  (check-equal? (hash-ref (bob-writes!) 'version) 2 "an editor uploads a new version")
  (check-exn exn:fail:forbidden? (lambda () (repo-share! conn bob pid #:user _c))
             "an editor cannot re-share either")
  (check-equal? (hash-ref (grant-of alice pid _b) 'capability) "edit")

  ;; manage: re-share yes — and the grantee's grant is exact, not a wildcard
  (repo-share! conn alice pid #:principal-type "user" #:principal-id _b #:capability "manage")
  (check-equal? (hash-ref (grant-of alice pid _b) 'capability) "manage")
  (repo-share! conn bob pid #:user _c)
  (check-equal? (read-back conn carol pid) #"v2 by bob" "a manage grantee shared it onward")
  (check-equal? (length (repo-grants conn bob pid)) 2 "…and can see the grant list")

  ;; sharing again NARROWS: bob back to view drops the write and manage rows
  (repo-share! conn alice pid #:principal-type "user" #:principal-id _b #:capability "view")
  (check-equal? (hash-ref (grant-of alice pid _b) 'capability) "view")
  (check-equal? (hash-ref (grant-of alice pid _b) 'permissions) '("files:read"))
  (check-exn exn:fail:forbidden? bob-writes! "narrowed to view, bob cannot write again")

  ;; revoke removes every row the principal held
  (repo-unshare! conn alice pid #:principal-type "user" #:principal-id _c)
  (check-exn exn:fail:forbidden? (lambda () (repo-get conn carol pid)))
  (check-equal? (length (repo-grants conn alice pid)) 1)

  ;; bad input is refused, not stored
  (check-exn exn:fail:user? (lambda () (repo-share! conn alice pid #:user _c #:capability "owner")))
  (check-exn exn:fail:user? (lambda () (repo-share! conn alice pid #:principal-type "group" #:principal-id "g1")))
  (check-exn exn:fail:user? (lambda () (repo-share! conn alice pid #:user "")))
  (check-exn exn:fail:user? (lambda () (repo-share! conn alice pid #:user _c
                                                    #:expires-at (- (current-seconds) 60)))
             "an expiry in the past is refused")
  (check-exn exn:fail:user? (lambda () (repo-share! conn alice pid #:user "no-such-user"))
             "an unknown principal is refused rather than granted an inert row")
  (check-equal? (length (repo-grants conn alice pid)) 1 "nothing above left a row")

  ;; expiry (DSH-3): a live one opens, a lapsed one is ignored but still listed
  ;; past 2038 on purpose: an int4 column would refuse this on Postgres
  (repo-share! conn alice pid #:user _c #:expires-at (expiry->seconds "2099-01-01T00:00:00Z"))
  (check-equal? (read-back conn carol pid) #"v2 by bob" "a grant with a future expiry opens")
  (check-equal? (hash-ref (grant-of alice pid _c) 'expires_at) "2099-01-01T00:00:00Z"
                "listed as ISO-8601 UTC, and a far-future expiry round-trips")
  (grant! conn #:resource-type "repo" #:resource-id pid #:principal-type "user" #:principal-id _c
          #:permission "files:read" #:expires-at (- (current-seconds) 5))   ; lapse it directly
  (check-exn exn:fail:forbidden? (lambda () (repo-get conn carol pid)) "an expired grant opens nothing")
  (let ([g (grant-of alice pid _c)])
    (check-true (hash-ref g 'expired) "…but it is still listed, flagged")
    (check-equal? (hash-ref g 'capability) "view"))
  (repo-share! conn alice pid #:user _c)
  (check-equal? (read-back conn carol pid) #"v2 by bob" "sharing again renews a lapsed grant")
  (check-equal? (hash-ref (grant-of alice pid _c) 'expires_at) 'null)
  (repo-unshare! conn alice pid #:user _c)

  ;; a TEAM principal (DSH-6): everyone acting as the team reads it
  (repo-unshare! conn alice pid #:user _b)
  (check-exn exn:fail:forbidden? (lambda () (repo-get conn carol pid)))
  (repo-share! conn alice pid #:principal-type "team" #:principal-id team #:capability "view")
  (check-equal? (read-back conn carol pid) #"v2 by bob" "a team grant reaches a member with no row of their own")
  (check-equal? (read-back conn bob pid) #"v2 by bob")
  (let ([g (grant-of alice pid team)])
    (check-equal? (hash-ref g 'principal_type) "team")
    (check-equal? (hash-ref g 'name) "Engineering" "a team grant is listed by team name"))
  (check-exn exn:fail:user? (lambda () (repo-share! conn alice pid #:principal-type "team" #:principal-id "nope")))

  ;; the owner needs no row, and a team ADMIN holds manage by role — for what the
  ;; role reaches. A colleague's team-visible document, yes; their private one, no:
  ;; private is private from admins too, and only a grant or the owner opens it.
  (define-values (adm _adm) (member-of conn team "adm" #:role "admin"))
  (check-exn exn:fail:forbidden? (lambda () (repo-share! conn adm pid #:user _c))
             "an admin cannot share a colleague's PRIVATE document")
  (define pub (put! conn alice "memo.txt" #"for all" #:vis "team"))
  (check-exn exn:fail:forbidden? (lambda () (repo-share! conn bob (hash-ref pub 'id) #:user _c))
             "a member cannot share a colleague's team document")
  (repo-share! conn adm (hash-ref pub 'id) #:user _c #:capability "edit")
  (check-equal? (hash-ref (grant-of alice (hash-ref pub 'id) _c) 'capability) "edit")
  (check-equal? (hash-ref (repo-get conn alice (hash-ref pub 'id)) 'visibility) "shared"
                "sharing a team document narrows it")
  ;; carol needs an edit grant on the SOURCE for the inheritance check below
  (repo-share! conn alice pid #:user _c #:capability "edit")

  ;; derived documents inherit at creation, then go their own way (DSH-5)
  (define out (put! conn alice "plan.nl.txt" #"vertaling"))          ; created team-visible
  (define oid (hash-ref out 'id))
  (define inherited (repo-inherit! conn alice #:source pid #:target oid #:run-id "run-1" #:step-id "translate"))
  (check-equal? (hash-ref inherited 'visibility) "private" "the output took the source's visibility")
  (check-equal? (read-back conn carol oid) #"vertaling" "…and its live grants: carol (edit) reads it")
  (check-equal? (read-back conn bob oid) #"vertaling" "…and the team grant came along")
  (check-equal? (hash-ref (grant-of alice oid team) 'capability) "view")
  (check-equal? (hash-ref (grant-of alice oid _c) 'capability) "edit")
  (check-equal? (length (repo-grants conn alice oid)) 2)
  (let ([d (car (repo-derivations conn carol oid))])
    (check-equal? (hash-ref d 'source_object_id) pid)
    (check-equal? (hash-ref d 'source_version_id) (hash-ref (repo-get conn alice pid) 'version_id))
    (check-equal? (hash-ref d 'run_id) "run-1")
    (check-equal? (hash-ref d 'step_id) "translate"))
  (check-equal? (repo-derivations conn alice pid) '() "the source derives from nothing")
  (repo-unshare! conn alice pid #:user _c)      ; carol keeps team-wide view, loses edit
  (check-exn exn:fail:forbidden? (lambda () (put! conn carol "plan.txt" #"x")) "carol can no longer edit the source")
  (check-equal? (hash-ref (put! conn carol "plan.nl.txt" #"herzien") 'version) 2
                "narrowing the source does not narrow the translation: carol still edits it")
  (check-exn exn:fail:user? (lambda () (repo-inherit! conn alice #:source oid #:target oid)))
  (check-exn exn:fail:forbidden? (lambda () (repo-inherit! conn bob #:source pid #:target oid))
             "inheriting onto a document you do not steward is refused")
  (disconnect conn))

;; expiry parsing: what the API accepts, and what it refuses
(check-equal? (expiry->seconds "2030-01-02T03:04:05Z") (find-seconds 5 4 3 2 1 2030 #f))
(check-equal? (expiry->seconds "2030-01-02T03:04:05+02:00") (- (find-seconds 5 4 3 2 1 2030 #f) 7200))
(check-equal? (expiry->seconds "2030-01-02") (find-seconds 0 0 0 2 1 2030 #f))
(check-equal? (expiry->seconds "1893466800") 1893466800)
(check-equal? (expiry->seconds 1893466800) 1893466800)
(check-equal? (expiry->seconds 'null) #f)
(check-equal? (expiry->seconds "") #f)
(check-exn exn:fail:user? (lambda () (expiry->seconds "next tuesday")))
(check-exn exn:fail:user? (lambda () (expiry->seconds "2030-13-40")))
(check-equal? (seconds->iso8601 (find-seconds 5 4 3 2 1 2030 #f)) "2030-01-02T03:04:05Z")

;; ---- keys ------------------------------------------------------------------------
(check-true  (valid-key? "a.txt"))
(check-true  (valid-key? "reports/2026/q3.pdf"))
(check-false (valid-key? "") )
(check-false (valid-key? "/leading") )
(check-false (valid-key? "../escape") )
(check-false (valid-key? "a/../b") )
(check-false (valid-key? "a//b") )
(check-false (valid-key? "back\\slash"))
(check-false (valid-key? "nul\u0000byte") "a control byte in a key is refused")

;; active content is never in the inline allowlist (DOC-10)
(check-false (inline-safe? "image/svg+xml"))
(check-false (inline-safe? "text/html"))
(check-false (inline-safe? "application/xml"))
(check-true  (inline-safe? "application/pdf"))
(check-true  (inline-safe? "image/png"))

;; a corrupt digest never becomes a path segment
(check-false (valid-digest? "../../etc/passwd"))
(check-false (valid-digest? "ABCD"))
(check-false (valid-digest? (make-string 64 #\z)))
(check-true  (valid-digest? (make-string 64 #\a)))
(check-exn exn:fail? (lambda () (blob-get "org" "../../etc/passwd")))

(delete-directory/files BLOB-ROOT #:must-exist? #f)

;; ---- the blob root is ABSOLUTE, whatever the current directory is --------------
;;
;; Regression for a live-only failure: the default root was the relative path
;; "data/blobs", resolved at WRITE time against `current-directory`. `serve/servlet`
;; repoints that at the web server's own default web root while it handles a
;; request, so on a packaged install the first document edit tried to mkdir inside
;; the read-only Nix store and died with EACCES. Startup was healthy, every unit
;; test passed, and the console broke.
;;
;; The invariant that actually prevents it: every configured root resolves to an
;; absolute path, and resolves to the SAME path from any working directory.
(test-case "blob roots are absolute and cwd-independent"
  (define elsewhere (find-system-path 'temp-dir))

  ;; default (no TELEMACHUS_DATA_DIR)
  (parameterize ([current-blob-root #f])
    (define a (parameterize ([current-directory elsewhere]) (data-dir)))
    (define b (data-dir))
    (check-true (absolute-path? a) "data-dir must be absolute")
    (check-equal? a b "data-dir must not depend on current-directory"))

  ;; a RELATIVE override is anchored too — otherwise it reintroduces the same bug
  (define saved (getenv "TELEMACHUS_DATA_DIR"))
  (putenv "TELEMACHUS_DATA_DIR" "some-relative-state")
  (define r1 (parameterize ([current-directory elsewhere]) (data-dir)))
  (define r2 (data-dir))
  (check-true (absolute-path? r1) "a relative TELEMACHUS_DATA_DIR must still resolve absolute")
  (check-equal? r1 r2 "a relative TELEMACHUS_DATA_DIR must not depend on current-directory")
  (if saved (putenv "TELEMACHUS_DATA_DIR" saved) (putenv "TELEMACHUS_DATA_DIR" ""))

  ;; the STORE's own default root, which is what actually broke
  (parameterize ([current-blob-root #f])
    (define a (parameterize ([current-directory elsewhere]) (blob-root)))
    (check-true (absolute-path? a) "the blob store's default root must be absolute")
    (check-equal? a (blob-root) "the blob root must not depend on current-directory"))

  ;; and a write really does land where the root says, from a foreign cwd
  (define root (make-temporary-file "telemachus-cwdtest-~a" 'directory))
  (parameterize ([current-blob-root root])
    (define d (parameterize ([current-directory elsewhere])
                (blob-put! "org-cwd-test" (digest-of-bytes #"hello") (open-input-bytes #"hello") 5)
                (digest-of-bytes #"hello")))
    (check-true (blob-exists? "org-cwd-test" d) "blob written from a foreign cwd is findable")
    (check-equal? (port->bytes (blob-get "org-cwd-test" d)) #"hello"))
  (delete-directory/files root))
