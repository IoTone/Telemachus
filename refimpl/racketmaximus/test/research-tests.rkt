#lang racket/base

;; #128 job 2: operator-facing variables are read through ONE accessor,
;; which tries TMACH_<name> and falls back to TELEMACHUS_<name>.
(require (only-in "../config.rkt" tmach-env))

;; test/research-tests.rkt — the research archive (#191 slice 1, RG-1/-2/-3/-11).
;;
;;   raco test test/research-tests.rkt
;;   DATABASE_URL="postgres://…" raco test test/research-tests.rkt
;;
;; THE EGRESS REFUSALS ARE FIRST, because the design says so and because they are
;; the only cases here whose failure is a vulnerability rather than a defect. A
;; bookmark is the first URL an ordinary MEMBER makes this server fetch (RG-3),
;; so case 1 drives the REAL fetcher at a real loopback listener with
;; `TMACH_EGRESS_ALLOW` deliberately set to allow that network — and asserts it
;; is refused anyway, because the allowlist belongs to `'trusted` and this
;; surface has no way to ask for it. A version of this slice that grew a
;; `'trusted` mode "for operators" fails that case by name.
;;
;; WHICH MEANS THE HAPPY PATH CANNOT USE A SOCKET, and that is stated rather than
;; worked around: the policy is doing its job, so the store path is driven through
;; `research-fetch!`'s `#:fetch` seam, which DEFAULTS to the real fetcher so no
;; production caller chooses. Case 1 is what establishes that the default really
;; is the real one — it passes no seam and is refused by name.

(require rackunit db-kit/portable db-kit/migrate
         racket/tcp racket/string racket/list racket/file racket/port json
         "../domain/db/migrations.rkt"
         "db-fixture.rkt"
         "../domain/authz/authz.rkt"
         "../domain/repo/blobs.rkt"
         (only-in "../domain/repo/repo.rkt" repo-list repo-open repo-get repo-versions repo-delete!)
         (only-in "../domain/quota/quota.rkt" quota-used set-limit!)
         (only-in "../domain/authz/secretbox.rkt" wrapped-secret?)
         "../domain/research/research.rkt")

(define BLOB-ROOT (make-temporary-file "telemachus-research-~a" 'directory))
(current-blob-root BLOB-ROOT)

(define (fresh) (define c (fresh-db #:migrate? #f)) (migrate! c all-migrations) c)

(define (owner conn)
  (define-values (u t) (bootstrap! conn #:username "alice" #:org-name "Acme" #:org-slug "acme"
                                   #:team-name "Eng" #:team-slug "eng"))
  (values u t))

(define (with-env name value thunk)
  (define saved (getenv name))
  (dynamic-wind (lambda () (putenv name value))
                thunk
                (lambda () (putenv name (or saved "")))))

;; A canned response, so the store path is exercised with no socket and no
;; policy in the way. `(values status headers body)` is `fetch`'s own shape.
(define ((canned status headers body) _url)
  (values status headers body))

(define HTML #"<html><title>Octopus</title><body>Cephalopods have eight arms.</body></html>")

(define (bookmark! c u t url #:title [title "Octopus"] #:note [note #f])
  (define id (research-create! c #:team t #:user u #:url url #:title title #:note note
                               #:created-by u))
  (check-true (string? id) (format "create answered ~a" id))
  id)

;; ---- 1. THE EGRESS REFUSAL, over a real socket, with the allowlist set ---------------
(test-case "a bookmark is 'untrusted egress: loopback is refused even where the OPERATOR allowed that network, and nothing is stored"
  (define c (fresh))
  (define-values (u t) (owner c))
  (define p (user-principal c u t))
  ;; A listener that really is there and really would answer, so the refusal
  ;; cannot pass for "it did not connect".
  (define L (tcp-listen 0 8 #t "127.0.0.1"))
  (define-values (_h port _rh _rp) (tcp-addresses L #t))
  (define served (box 0))
  (define th (thread (lambda ()
                       (with-handlers ([(lambda (_) #t) void])
                         (let loop ()
                           (define-values (i o) (tcp-accept L))
                           (set-box! served (add1 (unbox served)))
                           (fprintf o "HTTP/1.1 200 OK\r\ncontent-type: text/html\r\ncontent-length: 2\r\nconnection: close\r\n\r\nhi")
                           (flush-output o)
                           (close-output-port o) (close-input-port i)
                           (loop))))))
  (define was (tmach-env "EGRESS_ALLOW"))
  (dynamic-wind
   (lambda () (putenv "TMACH_EGRESS_ALLOW" "127.0.0.0/8"))
   (lambda ()
     (define id (bookmark! c u t (format "http://127.0.0.1:~a/metadata" port)))
     (define out (research-fetch! c p (research-get c id t)))
     (check-false (hash-ref out 'ok) "a loopback URL must be refused on this surface")
     ;; The refusal is BY POLICY and says so, which is what lets a caller tell
     ;; "we would not go there" from "it did not answer" (#142's own distinction).
     (check-equal? (hash-ref out 'reason) "refused-address"
                   (format "expected a policy refusal, got ~a" (hash-ref out 'reason)))
     (check-equal? (unbox served) 0 "nothing may reach the socket at all")
     ;; NOTHING IS STORED, which is the half that matters: a refused fetch must
     ;; not leave a document, an object id or a success time behind.
     (check-equal? (length (repo-list c p)) 0 "a refused fetch creates no document")
     (define row (research-get c id t))
     (check-equal? (hash-ref row 'object_id) 'null)
     (check-equal? (hash-ref row 'last_ok_epoch) 'null)
     (check-true (string? (hash-ref row 'last_error)) "the reason is recorded on the row")
     ;; The bookmark SURVIVES, because a site this instance will not fetch is
     ;; still a URL somebody meant to keep.
     (check-equal? (hash-ref row 'url_canon) (format "http://127.0.0.1:~a/metadata" port)))
   (lambda ()
     (putenv "TMACH_EGRESS_ALLOW" (or was ""))
     (kill-thread th)
     (tcp-close L))))

(test-case "the cloud metadata address is refused by name"
  (define c (fresh))
  (define-values (u t) (owner c))
  (define p (user-principal c u t))
  (define id (bookmark! c u t "http://169.254.169.254/latest/meta-data/"))
  (define out (research-fetch! c p (research-get c id t)))
  (check-false (hash-ref out 'ok))
  (check-equal? (hash-ref out 'reason) "refused-address")
  (check-equal? (length (repo-list c p)) 0))

;; ---- 2. a credential has nowhere to live here, so it is refused ----------------------
(test-case "userinfo in the URL is refused rather than stored or stripped"
  (check-true (string? (research-problem #:url "https://user:pass@example.com/x"
                                         #:title #f #:note #f)))
  ;; …and the ordinary case is fine, including a query, which is NOT a
  ;; credential by inspection (FEED-13's distinction).
  (check-false (research-problem #:url "https://example.com/x?token=abc&page=2"
                                 #:title "T" #:note "n"))
  (check-true (string? (research-problem #:url "ftp://example.com/x" #:title #f #:note #f)))
  (check-true (string? (research-problem #:url "not a url" #:title #f #:note #f)))
  (check-true (string? (research-problem #:url "" #:title #f #:note #f)))
  (check-true (string? (research-problem #:url "https://example.com/x" #:title #f
                                         #:note (make-string 4001 #\x)))))

;; ---- 3. RG-1: the canonicalization is NARROW, and what it leaves alone is the point ---
(test-case "canonicalization lower-cases the scheme and host, drops a default port and the fragment — and NOTHING else"
  ;; what it does
  (check-equal? (canonical-url "HTTP://Example.COM/Path") "http://example.com/Path")
  (check-equal? (canonical-url "https://example.com:443/a") "https://example.com/a")
  (check-equal? (canonical-url "http://example.com:80/a") "http://example.com/a")
  (check-equal? (canonical-url "https://example.com/a#section-3") "https://example.com/a")
  ;; THE PATH'S CASE IS KEPT: paths are case-sensitive on most servers, so
  ;; lower-casing one addresses a different resource.
  (check-equal? (canonical-url "https://example.com/CaseMatters")
                "https://example.com/CaseMatters")
  ;; what it deliberately does NOT do, each of which would merge two pages that
  ;; differ on some real site — and the failure is silent, because the second
  ;; page's bytes land as a VERSION of the first and the version chain then says
  ;; a page changed when what changed was which page was fetched.
  (check-not-equal? (canonical-url "https://example.com/a") (canonical-url "https://example.com/a/")
                    "a trailing slash is a different resource on any server that says so")
  (check-not-equal? (canonical-url "https://example.com/a?b=1&a=2")
                    (canonical-url "https://example.com/a?a=2&b=1")
                    "query order is significant to plenty of real applications")
  (check-not-equal? (canonical-url "https://example.com/a?utm_source=x")
                    (canonical-url "https://example.com/a")
                    "a tracking-parameter list is somebody's guess, and `?page=2` looks like one")
  (check-false (canonical-url "gopher://example.com") "no host-bearing http(s) URL, no identity")
  (check-false (canonical-url "")))

(test-case "the canonical URL is the identity: a duplicate is refused, and two spellings that differ are two rows"
  (define c (fresh))
  (define-values (u t) (owner c))
  (define id (bookmark! c u t "https://Example.com:443/a#frag"))
  (check-equal? (research-create! c #:team t #:user u #:url "https://example.com/a"
                                  #:title #f #:note #f #:created-by u)
                'duplicate-url
                "the same page under another spelling is the same bookmark")
  ;; …and NOT a converging create: the stored row keeps the note and the whole
  ;; version history somebody else's bookmark accumulated.
  (check-equal? (hash-ref (research-get c id t) 'title) "Octopus")
  (check-true (string? (research-create! c #:team t #:user u #:url "https://example.com/a/"
                                         #:title #f #:note #f #:created-by u))
              "a trailing slash is a different URL, so it is a second row the person can see"))

;; ---- 4. the archive -----------------------------------------------------------------
(test-case "a fetch archives the page as a repository document under research/<host>/…, with the title where search can see it"
  (define c (fresh))
  (define-values (u t) (owner c))
  (define p (user-principal c u t))
  (define id (bookmark! c u t "https://example.com/cephalopods/octopus" #:title "Octopus"))
  (define out (research-fetch! c p (research-get c id t)
                               #:fetch (canned 200 '(("content-type" . "text/html; charset=utf-8")
                                                     ("etag" . "\"abc\"")
                                                     ("last-modified" . "Tue, 04 Nov 2026 10:00:00 GMT"))
                                                HTML)))
  (check-true (hash-ref out 'ok))
  (check-equal? (hash-ref out 'content_type) "text/html")
  (check-equal? (hash-ref out 'key) (hash-ref out 'key))
  (check-true (string-prefix? (hash-ref out 'key) "research/example.com/cephalopods-octopus-")
              (format "key was ~a" (hash-ref out 'key)))
  (check-true (string-suffix? (hash-ref out 'key) ".html"))
  (define objs (repo-list c p))
  (check-equal? (length objs) 1)
  (define o (car objs))
  (check-equal? (hash-ref o 'content_type) "text/html")
  ;; FEED-17's reason, which #239's PATH-5 then made load-bearing: the title
  ;; rides in the version's FILENAME, which is what search covers and what
  ;; decides whether a listing has a human title to show instead of a path.
  (check-equal? (hash-ref o 'filename) "Octopus")
  ;; byte-identical, which is what a content-addressed archive is for
  (check-equal? (port->bytes (let-values ([(_o in) (repo-open c p (hash-ref o 'id))]) in)) HTML)
  (define row (research-get c id t))
  (check-equal? (hash-ref row 'object_id) (hash-ref o 'id))
  (check-equal? (hash-ref row 'etag) "\"abc\"")
  (check-equal? (hash-ref row 'last_modified) "Tue, 04 Nov 2026 10:00:00 GMT")
  (check-equal? (hash-ref row 'content_bytes) (bytes-length HTML))
  (check-equal? (hash-ref row 'fetches) 1)
  (check-true (hash-ref row 'archived))
  (check-equal? (hash-ref row 'last_error) 'null))

;; ---- 5. RG-2: THE PERMANENCE CASE ---------------------------------------------------
(test-case "a re-fetch is a NEW VERSION OF THE SAME KEY, so every earlier fetch's bytes stay addressable"
  (define c (fresh))
  (define-values (u t) (owner c))
  (define p (user-principal c u t))
  (define id (bookmark! c u t "https://example.com/octopus"))
  (define first
    (research-fetch! c p (research-get c id t)
                     #:fetch (canned 200 '(("content-type" . "text/html")) #"<p>eight arms</p>")))
  (define second
    (research-fetch! c p (research-get c id t)
                     #:fetch (canned 200 '(("content-type" . "text/html")) #"<p>eight arms, mostly</p>")))
  (check-true (hash-ref second 'ok))
  ;; ONE OBJECT, NOT TWO. A new object per fetch is N documents nobody can diff
  ;; and N entries in search for one page — which is the whole of what RG-2 had
  ;; to get right, and the obvious wrong implementation.
  (check-equal? (hash-ref second 'key) (hash-ref first 'key))
  (check-equal? (hash-ref second 'object_id) (hash-ref first 'object_id))
  (check-equal? (length (repo-list c p)) 1 "a re-fetch must not create a second document")
  (define vs (repo-versions c p (hash-ref first 'object_id)))
  (check-equal? (length vs) 2 "each fetch is a version")
  ;; …and the OLD bytes are still there under their own digest, which is the
  ;; sentence #191 asked for: "what did this page say when I bookmarked it".
  (check-not-equal? (hash-ref (car vs) 'digest) (hash-ref (cadr vs) 'digest))
  (check-false (hash-ref second 'unchanged) "the bytes differed, so this is not an unchanged fetch"))

(test-case "an UNCHANGED page reports so, and `unchanged` is computed against the digest held BEFORE the fetch"
  (define c (fresh))
  (define-values (u t) (owner c))
  (define p (user-principal c u t))
  (define id (bookmark! c u t "https://example.com/stable"))
  (define f (canned 200 '(("content-type" . "text/html")) HTML))
  (define a (research-fetch! c p (research-get c id t) #:fetch f))
  (check-false (hash-ref a 'unchanged) "the first fetch of a page cannot be 'unchanged'")
  (define b (research-fetch! c p (research-get c id t) #:fetch f))
  (check-true (hash-ref b 'unchanged))
  (check-equal? (hash-ref b 'sha256) (hash-ref a 'sha256))
  ;; The version row IS written, deliberately: "we looked on Tuesday and it was
  ;; the same" is a fact about the archive, and the alternative is a gap nobody
  ;; can tell from not having looked. The BYTES cost nothing — the blob store is
  ;; keyed by digest, so a stable page costs one row and no storage.
  (check-equal? (length (repo-versions c p (hash-ref a 'object_id))) 2)
  (check-equal? (hash-ref (car (repo-versions c p (hash-ref a 'object_id))) 'digest)
                (hash-ref (cadr (repo-versions c p (hash-ref a 'object_id))) 'digest)
                "identical bytes dedup to one blob"))

(test-case "a page that later answers as another TYPE does not start a second archive"
  (define c (fresh))
  (define-values (u t) (owner c))
  (define p (user-principal c u t))
  (define id (bookmark! c u t "https://example.com/report"))
  (define a (research-fetch! c p (research-get c id t)
                             #:fetch (canned 200 '(("content-type" . "text/html")) #"<p>a</p>")))
  (define b (research-fetch! c p (research-get c id t)
                             #:fetch (canned 200 '(("content-type" . "application/pdf")) #"%PDF-1.4 x")))
  (check-equal? (hash-ref b 'key) (hash-ref a 'key)
                "the key is composed ONCE and reused, whatever the type does later")
  (check-true (string-suffix? (hash-ref b 'key) ".html")
              "which is odd to read and is the trade: one archive beats two nobody can diff")
  (check-equal? (length (repo-list c p)) 1)
  ;; the VERSION carries the truth about the bytes, which is where a reader looks
  (check-equal? (hash-ref (car (repo-versions c p (hash-ref a 'object_id))) 'content_type)
                "application/pdf"))

;; ---- 6. the key is composed from somebody else's strings ------------------------------
(test-case "a hostile host or path cannot escape the key prefix"
  (define c (fresh))
  (define-values (u t) (owner c))
  (define p (user-principal c u t))
  (define id (bookmark! c u t "https://example.com/../../etc/passwd"))
  (define out (research-fetch! c p (research-get c id t)
                               #:fetch (canned 200 '(("content-type" . "text/plain")) #"x")))
  (check-true (hash-ref out 'ok))
  (define k (hash-ref out 'key))
  (check-true (string-prefix? k "research/example.com/") (format "key was ~a" k))
  (check-false (regexp-match? #rx"[.][.]/" k) (format "key was ~a" k))
  ;; two different URLs whose paths reduce to the same slug get different keys,
  ;; because the row id is in the key — a collision here would write one page's
  ;; bytes as a version of another's.
  (define id2 (bookmark! c u t "https://example.com/etc/passwd"))
  (define out2 (research-fetch! c p (research-get c id2 t)
                                #:fetch (canned 200 '(("content-type" . "text/plain")) #"y")))
  (check-not-equal? (hash-ref out2 'key) k)
  (check-equal? (length (repo-list c p)) 2)
  ;; ALSO FOUND BY A CONTROL THAT DID NOT BITE. `../../etc/passwd` is harmless
  ;; once the segments are joined with dashes — Racket answers `'up` for `..`,
  ;; so the raw slug is already `up-up-etc-passwd` — which left the slug's half
  ;; of the rule untested. What `valid-key?` actually refuses besides a `..`
  ;; segment is a BACKSLASH and a control character, and both arrive
  ;; percent-encoded in a perfectly well-formed URL.
  (define id3 (bookmark! c u t "https://example.com/a%5Cb%0Ac"))
  (define out3 (research-fetch! c p (research-get c id3 t)
                                #:fetch (canned 200 '(("content-type" . "text/plain")) #"z")))
  (check-true (hash-ref out3 'ok) (format "~a" out3))
  (check-false (regexp-match? #px"[\\ -]" (hash-ref out3 'key))
               (format "key was ~s" (hash-ref out3 'key))))

;; FOUND BY A CONTROL THAT DID NOT BITE. The case above exercises the PATH, so
;; patching `safe-key-part` out of the HOST changed nothing and the host's half
;; of the rule was untested. It is reachable: `research-problem` demands a
;; non-empty host and an http(s) scheme, and `http://../x` satisfies both while
;; `url-host` answers "..", which `valid-key?` refuses as a segment — so without
;; this the fetch would raise "invalid key" out of `repo-put!` and surface as a
;; 500 on a URL somebody typed.
(test-case "a host that reduces to a path segment cannot reach the key"
  (define c (fresh))
  (define-values (u t) (owner c))
  (define p (user-principal c u t))
  (define id (research-create! c #:team t #:user u #:url "http://../x" #:title #f #:note #f
                               #:created-by u))
  (check-true (string? id) "the URL is well formed enough to bookmark, which is the point")
  (define out (research-fetch! c p (research-get c id t)
                               #:fetch (canned 200 '(("content-type" . "text/plain")) #"x")))
  (check-true (hash-ref out 'ok) (format "~a" out))
  (check-false (regexp-match? #rx"^research/[.][.]/|/[.][.]/" (hash-ref out 'key))
               (format "key was ~a" (hash-ref out 'key)))
  (check-equal? (length (repo-list c p)) 1))

;; ---- 7. the outcome columns ----------------------------------------------------------
(test-case "`last_ok_epoch` moves only on a 2xx, so \"it last worked at\" survives a run of failures"
  (define c (fresh))
  (define-values (u t) (owner c))
  (define p (user-principal c u t))
  (define id (bookmark! c u t "https://example.com/flaky"))
  (void (research-fetch! c p (research-get c id t)
                         #:fetch (canned 200 '(("content-type" . "text/html")) HTML)))
  (define ok1 (hash-ref (research-get c id t) 'last_ok_epoch))
  (check-true (number? ok1))
  ;; The column is SECONDS, so two fetches inside one second tie and "it did not
  ;; move" would hold against a version that stamps it every time. Age the row.
  (query-exec c "UPDATE research_sources SET last_ok_epoch = ?, fetched_epoch = ? WHERE id = ?"
              (- ok1 500) (- ok1 500) id)
  (define out (research-fetch! c p (research-get c id t)
                               #:fetch (canned 503 '() #"down")))
  (check-false (hash-ref out 'ok))
  (define row (research-get c id t))
  (check-equal? (hash-ref row 'last_ok_epoch) (- ok1 500) "a failure must not move it")
  (check-true (> (hash-ref row 'fetched_epoch) (- ok1 500)) "the ATTEMPT time does move")
  (check-equal? (hash-ref row 'last_status) 503)
  (check-true (string? (hash-ref row 'last_error)))
  (check-equal? (hash-ref row 'fetches) 2 "both attempts are counted"))

;; ---- 8. RG-3: the stored reason is sealed --------------------------------------------
(test-case "`last_error` is sealed under the content switch, because it is somebody else's server's words"
  (define c (fresh))
  (define-values (u t) (owner c))
  (define p (user-principal c u t))
  (define id (bookmark! c u t "https://example.com/private-thing"))
  (with-env "TMACH_SECRET_KEY" (make-string 64 #\a)
    (lambda ()
      (with-env "TMACH_ENCRYPT_CONTENT" "1"
        (lambda ()
          (void (research-fetch! c p (research-get c id t)
                                 #:fetch (lambda (_u) (error 'x "SECRET-NEEDLE-7 leaked out of a server"))))
          (define raw (query-value c "SELECT last_error FROM research_sources WHERE id = ?" id))
          (check-true (wrapped-secret? raw) "the stored reason must be sealed")
          (check-false (string-contains? raw "SECRET-NEEDLE-7")
                       "…and the plaintext must not be in the row")
          ;; …and it still READS, through the row projection
          (check-true (string-contains? (hash-ref (research-get c id t) 'last_error)
                                        "SECRET-NEEDLE-7")))))))

;; ---- 9. the budget (FEED-9's rule, one home) ------------------------------------------
(test-case "`research.fetches` is charged per request and BEFORE it, so a refused fetch still costs"
  (define c (fresh))
  (define-values (u t) (owner c))
  (define p (user-principal c u t))
  (define id (bookmark! c u t "http://169.254.169.254/latest/meta-data/"))
  ;; Read off the LEDGER, not off `quota-check`, which reports `used: 0` when no
  ;; limit is set — the trap recorded in CLAUDE.md.
  (check-equal? (quota-used c "team" t "research.fetches" "total") 0)
  (void (research-fetch! c p (research-get c id t)))
  (check-equal? (quota-used c "team" t "research.fetches" "total") 1
                "a fetch this instance refused to make still spent its unit")
  (void (research-fetch! c p (research-get c id t)))
  (check-equal? (quota-used c "team" t "research.fetches" "total") 2))

(test-case "an exhausted budget refuses WITHOUT fetching"
  (define c (fresh))
  (define-values (u t) (owner c))
  (define p (user-principal c u t))
  (define id (bookmark! c u t "https://example.com/x"))
  (set-limit! c "team" t "research.fetches" 1 #:window "day")
  (define asked (box 0))
  (define f (lambda (_u) (set-box! asked (add1 (unbox asked)))
                    (values 200 '(("content-type" . "text/html")) HTML)))
  (check-true (hash-ref (research-fetch! c p (research-get c id t) #:fetch f) 'ok))
  (define out (research-fetch! c p (research-get c id t) #:fetch f))
  (check-false (hash-ref out 'ok))
  (check-equal? (hash-ref out 'reason) "quota")
  (check-true (hash? (hash-ref out 'quota)) "the DECISION comes back, so the endpoint can say when it resets")
  (check-equal? (unbox asked) 1 "the second request must never have been made")
  (check-equal? (length (repo-versions c p (hash-ref (research-get c id t) 'object_id))) 1))

;; ---- 10. forgetting a bookmark is not retracting the page ----------------------------
(test-case "deleting the bookmark leaves the archived document alone"
  (define c (fresh))
  (define-values (u t) (owner c))
  (define p (user-principal c u t))
  (define id (bookmark! c u t "https://example.com/keep"))
  (void (research-fetch! c p (research-get c id t)
                         #:fetch (canned 200 '(("content-type" . "text/html")) HTML)))
  (check-true (research-delete! c id t))
  (check-false (research-get c id t))
  (check-equal? (length (repo-list c p)) 1
                "the document is an ordinary repository object — the cascade, the blob release and the storage refund all live there")
  (check-false (research-delete! c id t) "deleting twice is not an error and is not a success"))

;; `archived` AND `object_id` are joined, so they cannot outlive the document.
(test-case "deleting the archived DOCUMENT withdraws `archived` rather than leaving the row claiming one"
  (define c (fresh))
  (define-values (u t) (owner c))
  (define p (user-principal c u t))
  (define id (bookmark! c u t "https://example.com/rots"))
  (define out (research-fetch! c p (research-get c id t)
                               #:fetch (canned 200 '(("content-type" . "text/html")) HTML)))
  (check-true (hash-ref (research-get c id t) 'archived))
  ;; #86's retention sweep and an ordinary delete both do this, so it is the
  ;; ordinary case rather than a corner.
  (void (repo-delete! c p (hash-ref out 'object_id)))
  (define row (research-get c id t))
  (check-false (hash-ref row 'archived)
               "a row claiming an archive that is gone is the field nobody can trust")
  (check-equal? (hash-ref row 'object_id) 'null "…and a dangling id is that in its most literal form")
  ;; …but the KEY survives, which is what makes the re-archive land where it
  ;; always was instead of starting a second archive (RG-15).
  (check-true (string? (hash-ref row 'object_key)))
  (define again (research-fetch! c p row
                                 #:fetch (canned 200 '(("content-type" . "text/html")) HTML)))
  (check-equal? (hash-ref again 'key) (hash-ref out 'key))
  (check-true (hash-ref (research-get c id t) 'archived)))

(test-case "another team's bookmark is invisible rather than forbidden"
  (define c (fresh))
  (define-values (u t) (owner c))
  (define id (bookmark! c u t "https://example.com/mine"))
  (check-false (research-get c id "some-other-team")))
