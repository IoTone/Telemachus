#lang racket/base

;; test/document-paths-tests.rkt — a project is a key PREFIX (#239).
;; raco test test/document-paths-tests.rkt
;; DATABASE_URL="postgres://…" raco test test/document-paths-tests.rkt
;;
;; The file runs whole on both dialects ON PURPOSE: the first case is about a LIKE
;; escape whose default differs between them in OPPOSITE directions, so a suite
;; that only ever ran on SQLite would have reported the bug and a suite that only
;; ever ran on PostgreSQL would have reported nothing at all.

(require rackunit db-kit/portable
         racket/file racket/list racket/string
         db-kit/migrate
         "../domain/db/migrations.rkt"
         "db-fixture.rkt"
         "../domain/authz/authz.rkt"
         "../domain/repo/blobs.rkt"
         "../domain/repo/repo.rkt"
         "../domain/apps/search.rkt"
         "../domain/documents/documents.rkt")

(define BLOB-ROOT (make-temporary-file "telemachus-path-blobs-~a" 'directory))
(current-blob-root BLOB-ROOT)

(define (fresh) (define c (fresh-db #:migrate? #f)) (migrate! c all-migrations) c)
(define (put! c p key [ct "application/pdf"])
  (repo-put! c p #:key key #:port (open-input-bytes #"x") #:content-type ct
             #:filename (last (string-split key "/")) #:visibility "team"))
(define (keys-of objs) (sort (for/list ([o (in-list objs)]) (hash-ref o 'key)) string<?))
(define (folder-names r) (for/list ([f (in-list (hash-ref r 'prefixes))]) (hash-ref f 'name)))

;; ---- 1. an underscore in a prefix -------------------------------------------
;; THE CASE THE FEATURE WOULD HAVE MET ON DAY ONE. `_` is a LIKE wildcard, so the
;; prefix is escaped — and the escape means nothing unless the statement names an
;; escape character. SQLite has none by default, so the escaped pattern asked for a
;; literal backslash and matched NOTHING; PostgreSQL's LIKE takes backslash as its
;; default escape, so the same code was correct there. Both halves are asserted: the
;; prefix finds its own objects, and it does NOT find the one that `_`-as-wildcard
;; would have matched.
(test-case "a prefix containing _ matches its own folder and nothing else"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice"))
  (define p (user-principal c uid tid))
  (put! c p "levee_7/survey.pdf")
  (put! c p "leveeX7/other.pdf")          ; `_` as a wildcard would match this
  (put! c p "levee-7/other.pdf")
  (check-equal? (keys-of (repo-list c p #:prefix "levee_7/")) '("levee_7/survey.pdf"))
  (check-equal? (repo-count c p #:prefix "levee_7/") 1)
  ;; the same window, so the same answer — `repo-count` exists to tell a short page
  ;; from the last page, and it told a different story from the listing
  (check-equal? (repo-count c p #:prefix "levee_7/")
                (length (repo-list c p #:prefix "levee_7/")))
  ;; …and a `%` in a prefix is a prefix, not "everything"
  (put! c p "100%/done.pdf")
  (check-equal? (keys-of (repo-list c p #:prefix "100%/")) '("100%/done.pdf")))

;; ---- 2. a document is filed where the caller says ---------------------------
(test-case "documents-create #:key files into a project, and the default is unchanged"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice"))
  (define p (user-principal c uid tid))
  (define filed (documents-create c p #:title "Chapter 1" #:key "levee-7/chapters/01.md"
                                  #:content "# one"))
  (check-equal? (hash-ref filed 'key) "levee-7/chapters/01.md")
  ;; the key is REPORTED, or the console cannot show which project a document is in
  (check-equal? (hash-ref (documents-get c p (hash-ref filed 'id)) 'key)
                "levee-7/chapters/01.md")
  ;; no key: the composed default, exactly as before
  (define dflt (documents-create c p #:title "Loose Note" #:content "x"))
  (check-true (string-prefix? (hash-ref dflt 'key) DEFAULT-PREFIX))
  (check-true (string-suffix? (hash-ref dflt 'key) ".md"))
  ;; a blank key is an ABSENT key, not a refusal — an empty form field is the
  ;; ordinary way to say "wherever you like"
  (check-true (string-prefix? (hash-ref (documents-create c p #:title "Blank" #:key "  "
                                                          #:content "x") 'key)
                              DEFAULT-PREFIX))
  ;; A KEY ENDING IN `/` IS A FOLDER — the console sends the project it is looking
  ;; at, and `levee-7/` as a literal key would be refused for its empty last
  ;; segment, so the obvious spelling of "put it here" had to mean something.
  (define under (documents-create c p #:title "Chapter Two" #:key "levee-7/chapters/"
                                  #:content "# two"))
  (check-true (string-prefix? (hash-ref under 'key) "levee-7/chapters/chapter-two-"))
  (check-true (string-suffix? (hash-ref under 'key) ".md"))
  ;; an UNUSABLE key is still refused, by the one validator that has always run
  (check-exn exn:fail? (lambda () (documents-create c p #:title "bad" #:key "../escape.md"
                                                    #:content "x"))))

;; ---- 3. a filed document is still a document --------------------------------
;; The window used to be the `documents/` key prefix, so this is the case that
;; forced it to become the content type: a chapter filed into a project would
;; otherwise vanish from the tab that wrote it.
(test-case "the documents listing is the content type, not the documents/ prefix"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice"))
  (define p (user-principal c uid tid))
  (documents-create c p #:title "Chapter 1" #:key "levee-7/chapters/01.md" #:content "# one")
  (documents-create c p #:title "Loose" #:content "x")
  (check-equal? (length (hash-ref (documents-list c p) 'documents)) 2)
  ;; …and `#:prefix` is one project's
  (check-equal? (for/list ([d (in-list (hash-ref (documents-list c p #:prefix "levee-7/")
                                                 'documents))])
                  (hash-ref d 'title))
                '("Chapter 1"))
  ;; an uploaded markdown file is a text document too — the fold's own point, and
  ;; the asymmetry this removes: the same object presented two ways
  (put! c p "levee-7/notes.md" "text/markdown")
  (check-equal? (length (hash-ref (documents-list c p #:prefix "levee-7/") 'documents)) 2)
  ;; a PDF beside it is not
  (put! c p "levee-7/survey.pdf")
  (check-equal? (length (hash-ref (documents-list c p #:prefix "levee-7/") 'documents)) 2))

;; ---- 4. the pipeline's own output stays out ---------------------------------
;; CLS-26 at a third lister. Without it the tab fills with `<key>.form.md` and
;; `<key>.<locale>.md`, which is what widening the window to markdown would
;; otherwise have bought.
(test-case "a derived markdown document is not listed"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice"))
  (define p (user-principal c uid tid))
  (define src (put! c p "levee-7/report.md" "text/markdown"))
  (check-equal? (length (hash-ref (documents-list c p) 'documents)) 1)
  ;; `repo-derive!` takes the SOURCE OBJECT positionally and its bytes as bytes —
  ;; it reads the source's visibility off it (DWF-4's order), which an id could not
  ;; give it.
  (repo-derive! c p src #:key "levee-7/report.md.form.md"
                #:bytes #"filled" #:content-type "text/markdown")
  (check-equal? (for/list ([d (in-list (hash-ref (documents-list c p) 'documents))])
                  (hash-ref d 'key))
                '("levee-7/report.md")))

;; ---- 5. the folders under a prefix ------------------------------------------
(test-case "repo-prefixes derives the folders and only the immediate ones"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice"))
  (define p (user-principal c uid tid))
  (for ([k '("levee-7/chapters/01.md" "levee-7/survey.pdf" "levee_8/a.pdf" "loose.pdf")])
    (put! c p k))
  (define top (repo-prefixes c p))
  (check-equal? (folder-names top) '("levee-7" "levee_8"))
  (check-false (hash-ref top 'truncated))
  ;; a trailing slash, so the answer is usable as the next prefix verbatim
  (check-equal? (for/list ([f (in-list (hash-ref top 'prefixes))]) (hash-ref f 'prefix))
                '("levee-7/" "levee_8/"))
  ;; one level down — and the `_` folder is reachable, which case 1 is about
  (check-equal? (folder-names (repo-prefixes c p #:prefix "levee-7/")) '("chapters"))
  (check-equal? (folder-names (repo-prefixes c p #:prefix "levee_8/")) '())
  ;; `#:immediate?` is this folder's own objects, not its subtree
  (check-equal? (keys-of (repo-list c p #:prefix "levee-7/" #:immediate? #t))
                '("levee-7/survey.pdf"))
  (check-equal? (keys-of (repo-list c p #:prefix "levee-7/"))
                '("levee-7/chapters/01.md" "levee-7/survey.pdf"))
  (check-equal? (repo-count c p #:prefix "levee-7/" #:immediate? #t) 1)
  (check-equal? (repo-count c p #:prefix "levee-7/") 2))

;; ---- 6. a folder name is somebody's words -----------------------------------
;; The disclosure argument for applying `can?` here where `repo-count` deliberately
;; does not: `legal/acme-dispute/` names the thing it holds. A member must not be
;; handed the names of a colleague's private tree and then shown an empty folder.
(test-case "a folder holding only another member's private documents is not offered"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice"))
  (define alice (user-principal c uid tid))
  (define bob (create-user! c #:username "bob"))
  (add-member! c #:user bob #:team tid #:role "member")
  (define pbob (user-principal c bob tid))
  (repo-put! c alice #:key "legal/acme-dispute/brief.pdf" #:port (open-input-bytes #"x")
             #:content-type "application/pdf" #:filename "brief.pdf" #:visibility "private")
  (put! c alice "shared-work/plan.pdf")
  (check-equal? (folder-names (repo-prefixes c alice)) '("legal" "shared-work"))
  (check-equal? (folder-names (repo-prefixes c pbob)) '("shared-work"))
  ;; a folder with a readable object BESIDE the private one is still offered —
  ;; "may I see anything in here", which is why one readable row settles it
  (put! c alice "legal/acme-dispute/filing.pdf")
  (check-equal? (folder-names (repo-prefixes c pbob)) '("legal" "shared-work")))

;; ---- 7. search presents a filed document as a document ----------------------
(test-case "search calls a filed markdown object a document, by content type"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice"))
  (define p (user-principal c uid tid))
  (documents-create c p #:title "Levee Seven Report" #:key "levee-7/report.md"
                    #:content "the levee was surveyed")
  (define hits (search-all c p "levee"))
  (define docs (for/list ([h (in-list hits)] #:when (equal? (hash-ref h 'type) "document")) h))
  (check-equal? (length docs) 1)
  ;; and it carries its human TITLE, not its key — which is the whole reason the
  ;; presentation test exists
  (check-equal? (hash-ref (car docs) 'title) "Levee Seven Report")
  ;; …and its PATH beside it, which is the whole of "which project is this in"
  (check-equal? (hash-ref (car docs) 'key) "levee-7/report.md"))

;; ---- 8. …and an uploaded markdown file is still a FILE ----------------------
;; `type` decides an AFFORDANCE — the console offers Download on a `file` row and
;; uses the title as the download filename — so widening it to every markdown
;; object would silently take the download button off every `.md` in the
;; repository. `index-tests` is what reported that, and these are the three shapes
;; that have to be told apart.
(test-case "a title is told from a filename, and both from a path"
  ;; a document written in the tab: a real title
  (check-true  (title-like? "levee-7/chapters/01.md" "Chapter One" "text/markdown"))
  ;; an ordinary upload: the filename it came from
  (check-false (title-like? "notes/minutes.md" "minutes.md" "text/markdown"))
  ;; `repo-put! #:filename key`, which fixtures and several callers do
  (check-false (title-like? "notes/minutes.md" "notes/minutes.md" "text/markdown"))
  ;; no filename at all — the key is the only thing there is to show
  (check-false (title-like? "notes/minutes.md" "" "text/markdown"))
  ;; and only a TEXT document has a title in the first place
  (check-false (title-like? "reports/q3.pdf" "Q3 Report" "application/pdf")))

(delete-directory/files BLOB-ROOT #:must-exist? #f)
