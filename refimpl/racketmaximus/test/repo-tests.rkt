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

(require rackunit db-kit/portable
         racket/file racket/port racket/list
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
