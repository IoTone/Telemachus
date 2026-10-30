#lang racket/base

;; test/help-tests.rkt — #183 slice 1: the help corpus, its ingest and the
;; nearest-passage read.
;;   raco test test/help-tests.rkt
;;   DATABASE_URL=postgres://… raco test test/help-tests.rkt
;;
;; The embedding seam is SCRIPTED (`current-help-embed`), as every unit test of
;; #189 scripts its own, so none of this needs an endpoint — and the script is a
;; **bag of words**, which is what makes the central assertion sayable at all: a
;; question that shares words with a passage lands near it, so "a question about
;; rotating a key retrieves the secrets runbook and not the container one" is a
;; property rather than "something came back". It is a crude stand-in and is NOT
;; a recall measurement; that is #189 step 3's calibration, in both languages.

(require rackunit db-kit/portable racket/file racket/list racket/string
         db-kit/migrate
         "../domain/db/migrations.rkt"
         "db-fixture.rkt"
         "../domain/ai/vectors.rkt"
         "../domain/ai/chunk.rkt"
         "../domain/help/helpstore.rkt"
         "../domain/help/helpindex.rkt"
         "../domain/help/helpsearch.rkt"
         "../domain/help/answer.rkt"
         "../domain/authz/authz.rkt"
         (only-in "../domain/quota/quota.rkt" quota-used))

(define (fresh)
  (define conn (fresh-db #:migrate? #f))
  (migrate! conn all-migrations)
  conn)

;; ENVN‑2: the variable NAME is passed as a value, never spelled as a literal
;; inside a `getenv` call — `test/env-names-tests.rkt` gates exactly that.
(define KEY-VAR "TMACH_SECRET_KEY")
(define CONTENT-VAR "TMACH_ENCRYPT_CONTENT")

(define (with-env* pairs thunk)
  (define saved (for/list ([kv (in-list pairs)]) (cons (car kv) (getenv (car kv)))))
  (dynamic-wind
    (lambda () (for ([kv (in-list pairs)]) (putenv (car kv) (or (cdr kv) ""))))
    thunk
    (lambda () (for ([kv (in-list saved)]) (putenv (car kv) (or (cdr kv) ""))) (void))))

;; ---- the scripted embedder ----------------------------------------------------
(define DIMS 256)
(define calls (box '()))
(define (reset-calls!) (set-box! calls '()))
(define (request-count) (length (unbox calls)))

(define (bucket w)
  (modulo (for/fold ([h 7]) ([c (in-string (string-downcase w))])
            (modulo (+ (* h 31) (char->integer c)) 1000003))
          DIMS))

;; ASCII words, plus EACH non-ASCII character as its own token. The second half
;; is not decoration: `[[:alnum:]]` is ASCII-only here, so splitting on its
;; complement reduced every Japanese fixture to no words at all and a zero
;; vector — which `help-replace-doc!` correctly refuses (VEC‑22), so twelve cases
;; failed naming the Japanese README. A per-character bag is a crude but
;; serviceable stand-in for a language with no spaces, and it is what lets the
;; locale cases have Japanese content to retrieve.
(define (tokens text) (regexp-match* #px"[A-Za-z0-9]+|[^[:ascii:]]" text))

(define (bag text)
  (define v (make-vector DIMS 0.0))
  (for ([w (in-list (tokens text))] #:when (> (string-length w) 0))
    (vector-set! v (bucket w) (+ 1.0 (vector-ref v (bucket w)))))
  v)

(define (script-embed texts)
  (set-box! calls (cons (length texts) (unbox calls)))
  (values (for/list ([t (in-list texts)]) (bag t))
          (for/sum ([t (in-list texts)]) (string-length t))))

(define MODEL "test-embed")

(define (ingest! conn root #:force? [force? #f] #:prune? [prune? #t] #:locales [ls '("en" "ja")])
  (parameterize ([current-help-embed script-embed])
    (help-ingest! conn (list root)
                  #:locales ls #:model MODEL #:force? force? #:prune? prune?
                  #:relative-to (let-values ([(base _n _d) (split-path
                                                            (simplify-path
                                                             (path->complete-path root) #f))])
                                  (and (path? base) (path->string base))))))

;; ---- a documentation tree -----------------------------------------------------
;;
;; Four files, written so the bag-of-words embedder can tell them apart: the
;; distinguishing words of each appear in no other. The two `ja` spellings this
;; repository really uses are both here — a directory segment and a `.ja.md`
;; suffix.
(define (make-tree)
  (define root (make-temporary-file "telemachus-help-~a" 'directory))
  (define (put rel text)
    (define p (build-path root rel))
    (define-values (base _n _d) (split-path p))
    (make-directory* base)
    (call-with-output-file p #:exists 'truncate (lambda (o) (display text o)))
    p)
  (put "ops/secrets.md"
       (string-append
        "# Secrets at rest\n\n"
        "## Rotating the key\n\n"
        "Rotation rewraps every sealed column under a freshly generated key.\n"
        "Keep the previous key available while the rewrap runs.\n"))
  (put "ops/container.md"
       (string-append
        "# Running in a container\n\n"
        "## The image\n\n"
        "The image has no shell, so a healthcheck must use the exec form.\n"
        "Mount a writable tmpfs for uploads.\n"))
  (put "book/ja/01-intro.md"
       (string-append
        "<!-- source-sha1: deadbeef -->\n"
        "# はじめに\n\n"
        "## 構成\n\n"
        "プラットフォームの構成について説明します。\n"))
  (put "README.ja.md" "# 読本\n\n日本語の概要です。\n")
  root)

;; =============================================================================
(test-case "1. an ingest stores documents and chunks, with paths relative to the tree"
  (define conn (fresh))
  (define root (make-tree))
  (reset-calls!)
  (define rep (ingest! conn root))
  (check-equal? (length (hash-ref rep 'ingested)) 4)
  (check-equal? (hash-ref rep 'chunks) 4)       ; each fixture file is one chunk
  (check-true (> (request-count) 0))
  (define base (let-values ([(_b n _d) (split-path root)]) (path->string n)))
  (define paths (help-doc-paths conn))
  (check-true (and (member (string-append base "/ops/secrets.md") paths) #t)
              "the stored path is relative to the tree's parent, so it reads like a repo path")
  (define d (help-doc-by-path conn (string-append base "/ops/secrets.md")))
  (check-equal? (hash-ref d 'title) "Secrets at rest" "the title is the first ATX heading")
  (check-equal? (hash-ref d 'locale) "en")
  (check-equal? (hash-ref d 'chunks) 1)
  (close-db! conn))

(test-case "2. the locale comes from the path, against a closed set"
  (define ls '("en" "ja"))
  (check-equal? (help-locale-of "docs/book/ja/04-authz.md" ls) "ja" "a directory segment")
  (check-equal? (help-locale-of "docs/reference/ja/api.md" ls) "ja")
  (check-equal? (help-locale-of "README.ja.md" ls) "ja" "a .ja.md suffix")
  (check-equal? (help-locale-of "docs/ops/container.md" ls) "en" "no marker is the default")
  (check-equal? (help-locale-of "docs/book/en/02-x.md" ls) "en")
  ;; HELP‑10's reason for a closed set rather than a two-letter grammar: a
  ;; directory that merely happens to be two characters long is not a language,
  ;; and a mis-tagged document is INVISIBLE — never retrieved for the locale
  ;; that should have found it.
  (check-equal? (help-locale-of "docs/qa/plan.md" ls) "en"
                "a two-letter directory that is not a shipped locale is not a locale")
  (check-equal? (help-locale-of "docs/book/fr/01.md" ls) "en"
                "a locale this build ships no catalog for is not recognised"))

(test-case "3. an unchanged file costs no model request; --force re-embeds"
  (define conn (fresh))
  (define root (make-tree))
  (ingest! conn root)
  (reset-calls!)
  (define again (ingest! conn root))
  (check-equal? (length (hash-ref again 'ingested)) 0)
  (check-equal? (length (hash-ref again 'unchanged)) 4)
  (check-equal? (hash-ref again 'requests) 0 "HELP‑9: the hash is the staleness test")
  (check-equal? (request-count) 0 "and the embedder was not called at all")
  (reset-calls!)
  (define forced (ingest! conn root #:force? #t))
  (check-equal? (length (hash-ref forced 'ingested)) 4)
  (check-true (> (request-count) 0))
  ;; An EDIT is detected without --force, which is the ordinary case.
  (define p (build-path root "ops/container.md"))
  (call-with-output-file p #:exists 'truncate
    (lambda (o) (display "# Running in a container\n\nNow it mentions tmpfs twice.\n" o)))
  (reset-calls!)
  (define edited (ingest! conn root))
  (check-equal? (length (hash-ref edited 'ingested)) 1)
  (check-equal? (length (hash-ref edited 'unchanged)) 3)
  (close-db! conn))

(test-case "4. a file the tree no longer has is forgotten, unless --no-prune"
  (define conn (fresh))
  (define root (make-tree))
  (ingest! conn root)
  (check-equal? (length (help-doc-paths conn)) 4)
  (delete-file (build-path root "ops/container.md"))
  (define kept (ingest! conn root #:prune? #f))
  (check-equal? (hash-ref kept 'pruned) '() "--no-prune: ingesting one subtree must not delete the rest")
  (check-equal? (length (help-doc-paths conn)) 4)
  (define rep (ingest! conn root))
  (check-equal? (length (hash-ref rep 'pruned)) 1)
  (check-equal? (length (help-doc-paths conn)) 3)
  (check-false (help-doc-by-path conn (car (hash-ref rep 'pruned))))
  (close-db! conn))

(test-case "5. HELP‑6: the embedded text carries the title and heading; the offsets quote the raw text"
  (define conn (fresh))
  (define root (make-tree))
  (ingest! conn root)
  (define base (let-values ([(_b n _d) (split-path root)]) (path->string n)))
  (define d (help-doc-by-path conn (string-append base "/ops/secrets.md")))
  (define text (help-text-for conn (hash-ref d 'id)))
  ;; the question is answered out of the file that shares its words
  (define rep (parameterize ([current-help-embed script-embed])
                (help-passages conn (bag "rotating a key and rewrapping sealed columns") MODEL
                               #:k 2 #:locale "en")))
  (define top (car (hash-ref rep 'passages)))
  (check-equal? (hash-ref top 'path) (string-append base "/ops/secrets.md"))
  ;; THE FIRST CHUNK OF A DOCUMENT HAS NO HEADING ABOVE IT, and that is the rule
  ;; rather than a gap: `help-heading-before` scans the text BEFORE the chunk's
  ;; start, and for chunk 0 there is none — the headings are inside it. The
  ;; document's TITLE is what carries the context there, which is one of the two
  ;; reasons the composition includes it. Case 15 asserts a real heading, on a
  ;; fixture long enough to have a chunk that is not the first.
  (check-equal? (hash-ref top 'heading) "")
  ;; the stored offsets index the raw file text, NOT the embedded composition
  (check-equal? (hash-ref top 'text)
                (substring text (hash-ref top 'start) (hash-ref top 'end)))
  (check-false (string-contains? (hash-ref top 'text) "Secrets at rest\nRotating the key")
               "the title/heading prefix is for the vector and the prompt, never for the quote")
  ;; …and the composition really is what was embedded
  (check-equal? (help-chunk-embed-text "T" "H" "body") "T\nH\nbody")
  (check-equal? (help-chunk-embed-text "T" "" "body") "T\nbody"
                "a chunk above the first heading composes without a blank line")
  (close-db! conn))

(test-case "6. the nearest passage is the nearest, and the order is by score"
  (define conn (fresh))
  (define root (make-tree))
  (ingest! conn root)
  (define base (let-values ([(_b n _d) (split-path root)]) (path->string n)))
  (define rep (help-passages conn (bag "the image has no shell so the healthcheck uses exec")
                             MODEL #:k 2 #:locale "en"))
  (define ps (hash-ref rep 'passages))
  (check-equal? (length ps) 2)
  (check-equal? (hash-ref (car ps) 'path) (string-append base "/ops/container.md"))
  (check-true (>= (hash-ref (car ps) 'score) (hash-ref (cadr ps) 'score)))
  (check-equal? (hash-ref rep 'locale) "en")
  (check-false (hash-ref rep 'truncated))
  (check-equal? (hash-ref rep 'dropped) 0)
  (close-db! conn))

(test-case "7. HELP‑12: the locale is a SQL filter, and a fallback says which locale answered"
  (define conn (fresh))
  (define root (make-tree))
  (ingest! conn root)
  ;; a Japanese question is answered out of the Japanese pages only
  (define ja (help-nearest conn (bag "構成 について") MODEL #:k 5 #:locale "ja"))
  (check-equal? (hash-ref ja 'locale) "ja")
  (check-equal? (hash-ref ja 'scanned) 2 "only the two ja documents were in the window")
  (for ([h (in-list (hash-ref ja 'hits))])
    (check-equal? (hash-ref h 'locale) "ja"))
  ;; a locale the corpus holds nothing for falls back and REPORTS the fallback,
  ;; rather than silently answering in another language
  (define fr (help-nearest conn (bag "rotating a key") MODEL #:k 2
                           #:locale "fr" #:fallback-locale "en"))
  (check-equal? (hash-ref fr 'locale) "en" "the locale that actually answered")
  (check-true (> (length (hash-ref fr 'hits)) 0))
  ;; …and with no fallback asked for, nothing is invented
  (define bare (help-nearest conn (bag "rotating a key") MODEL #:k 2 #:locale "fr"))
  (check-equal? (hash-ref bare 'locale) "fr")
  (check-equal? (hash-ref bare 'hits) '())
  (check-equal? (hash-ref bare 'scanned) 0)
  (close-db! conn))

(test-case "8. the model filter is in SQL, so another checkpoint's vectors are never scored"
  (define conn (fresh))
  (define root (make-tree))
  (ingest! conn root)
  (define rep (help-nearest conn (bag "rotating a key") "some-other-model" #:k 3))
  (check-equal? (hash-ref rep 'hits) '())
  (check-equal? (hash-ref rep 'scanned) 0
                "VEC‑20: filtered in SQL, so a foreign row costs no decode and cannot be scored")
  (close-db! conn))

(test-case "9. a directionless question is refused by name"
  (define conn (fresh))
  (define root (make-tree))
  (ingest! conn root)
  (check-exn #px"no direction"
             (lambda () (help-nearest conn (make-vector DIMS 0.0) MODEL)))
  (check-exn #px"positive integer"
             (lambda () (help-nearest conn (bag "x") MODEL #:k 0)))
  (close-db! conn))

(test-case "10. HELP‑13: a passage whose document text moved under it is dropped, not clamped"
  (define conn (fresh))
  (define root (make-tree))
  (ingest! conn root)
  (define base (let-values ([(_b n _d) (split-path root)]) (path->string n)))
  (define d (help-doc-by-path conn (string-append base "/ops/secrets.md")))
  ;; a state no code path produces: the text replaced without its chunks, which
  ;; is what racing an ingest would look like
  (query-exec conn "UPDATE help_docs SET content = ? WHERE id = ?" "short" (hash-ref d 'id))
  (define rep (help-passages conn (bag "rotating a key and rewrapping sealed columns")
                             MODEL #:k 3 #:locale "en"))
  (check-equal? (hash-ref rep 'dropped) 1)
  (check-true (hash-ref rep 'truncated) "a dropped hit is reported, not absorbed")
  (for ([p (in-list (hash-ref rep 'passages))])
    (check-false (equal? (hash-ref p 'doc_id) (hash-ref d 'id))))
  (close-db! conn))

(test-case "11. help-available? names which half is missing, and decides nothing"
  (define conn (fresh))
  (check-equal? (help-available? conn #f) "unconfigured")
  (check-equal? (help-available? conn #t) "empty" "an embedder but no corpus")
  (define root (make-tree))
  (ingest! conn root)
  (check-false (help-available? conn #t))
  (check-false (help-available? conn #t "ja"))
  (check-equal? (help-available? conn #t "fr") "locale-empty")
  (check-equal? (help-available? conn #f "en") "unconfigured"
                "the embedder is reported first: it is the half an operator sets")
  (close-db! conn))

(test-case "12. HELP‑5: the vector column is NOT sealed, with a key configured and content on"
  ;; The deliberate divergence from `repo_chunks.vector`, pinned in the one
  ;; environment where the difference shows: a key IS configured and the content
  ;; switch IS on, which is exactly when a `#:bytes` content column seals. The
  ;; source text here is the product's published documentation, so sealing would
  ;; protect nothing and would add a column `rewrap` must walk — which is how a
  ;; sealed value becomes silently unrotatable. Without this case the absence of
  ;; a seal is indistinguishable from having forgotten one.
  (with-env* (list (cons KEY-VAR (make-string 64 #\c)) (cons CONTENT-VAR "1"))
    (lambda ()
      (define conn (fresh))
      (define root (make-tree))
      (ingest! conn root)
      (define raw (query-value conn
                    (string-append "SELECT c.vector FROM help_chunks c JOIN help_docs d "
                                   "ON d.id = c.doc_id ORDER BY d.path ASC LIMIT 1")))
      (check-true (bytes? raw))
      (check-equal? (vec-width raw) DIMS
                    "the stored bytes are the packed float32 vector itself, readable with no key")
      (define v (vec-unpack raw))
      (check-true (vec-unit? v) "and still a unit vector, which is what makes the read a dot product")
      (close-db! conn))))

(test-case "13. a file with no chunkable text is recorded as nothing, so an ingest terminates"
  (define conn (fresh))
  (define root (make-temporary-file "telemachus-help-~a" 'directory))
  (call-with-output-file (build-path root "blank.md") #:exists 'truncate
    (lambda (o) (display "   \n\n  \n" o)))
  (define rep (ingest! conn root))
  (check-equal? (length (hash-ref rep 'empty)) 1
                "VEC‑23's rule: an operator repeating an ingest until it reports no work must finish")
  (check-equal? (hash-ref rep 'chunks) 0)
  ;; and it is not offered again
  (define again (ingest! conn root))
  (check-equal? (length (hash-ref again 'unchanged)) 1)
  (check-equal? (length (hash-ref again 'ingested)) 0)
  (close-db! conn))

(test-case "14. the stats, the clear, and what a model change means"
  (define conn (fresh))
  (define root (make-tree))
  (ingest! conn root)
  (define st (help-stats conn))
  (check-equal? (hash-ref st 'documents) 4)
  (check-equal? (hash-ref st 'chunks) 4)
  (check-equal? (hash-ref st 'models) (list MODEL))
  (define by-locale (for/hash ([l (in-list (hash-ref st 'locales))])
                      (values (hash-ref l 'locale) (hash-ref l 'documents))))
  (check-equal? (hash-ref by-locale "en") 2)
  (check-equal? (hash-ref by-locale "ja") 2)
  (check-equal? (help-locales conn) '("en" "ja")
                "derived from what was ingested, never stored")
  (check-equal? (help-clear! conn) 4)
  (check-equal? (help-chunk-count conn) 0)
  (check-equal? (help-locales conn) '())
  (close-db! conn))

(test-case "15. a chunk's offsets are CHUNK‑1's coordinates into the stored text"
  ;; The property step 5 of #189 relies on and this corpus inherits: the chunker
  ;; indexes the string it was given, the store keeps that same string, so a hit
  ;; resolves to a substring with no mapping in between and nothing to disagree.
  (define conn (fresh))
  (define root (make-temporary-file "telemachus-help-~a" 'directory))
  (define body (string-append "# Long page\n\n## First\n\n"
                              (make-string 1500 #\a) "\n\n## Second\n\n"
                              (make-string 1500 #\b) "\n"))
  (call-with-output-file (build-path root "long.md") #:exists 'truncate
    (lambda (o) (display body o)))
  (ingest! conn root)
  (define d (car (for/list ([p (in-list (help-doc-paths conn))]) (help-doc-by-path conn p))))
  (check-true (> (hash-ref d 'chunks) 1) "the fixture is longer than one chunk")
  (define text (help-text-for conn (hash-ref d 'id)))
  (check-equal? text body "the stored text is the file's text, byte for byte")
  (define-values (cs _t) (chunk-text body))
  (for ([c (in-list cs)])
    (check-equal? (substring text (hash-ref c 'start) (hash-ref c 'end)) (hash-ref c 'text)))
  ;; …and the heading a later chunk is cited under is the section it sits in
  (check-equal? (help-heading-before body 0) "" "nothing precedes the first chunk")
  (check-equal? (help-heading-before body 40) "First")
  (check-equal? (help-heading-before body (- (string-length body) 10)) "Second")
  (define rows (query-rows conn
                 (string-append "SELECT c.idx, c.heading FROM help_chunks c JOIN help_docs d "
                                "ON d.id = c.doc_id ORDER BY c.idx ASC")))
  (check-equal? (vector-ref (car rows) 1) "" "chunk 0: the title carries the context")
  ;; `(and … #t)`: `member` answers a TAIL, so `check-true` on it fails while
  ;; printing the list that proves it right — the fourth appearance of that shape
  ;; in these suites.
  (check-true (and (ormap (lambda (r) (member (vector-ref r 1) '("First" "Second"))) rows) #t)
              "a later chunk is stored under the heading it sits beneath")
  (close-db! conn))

;; =============================================================================
;; slice 2: the answer. The CHAT seam is scripted too, so none of this needs a
;; model either — and it is a SECOND parameter from the embedding one, which is
;; what makes "the floor refuses before any model is called" a thing a case can
;; assert rather than hope.

(define chat-calls (box '()))
(define (reset-chat!) (set-box! chat-calls '()))
(define (chat-count) (length (unbox chat-calls)))

;; `reply` is a thunk or a string; the prompt it was given is recorded so a case
;; can assert what the model was actually shown.
(define (scripted-chat reply)
  (lambda (prompt #:system [sys #f] #:executor [ex #f])
    (set-box! chat-calls (cons (hasheq 'prompt prompt 'system sys) (unbox chat-calls)))
    (values (if (procedure? reply) (reply prompt) reply) 42)))

(define (embed-one text) (values (bag text) (string-length text)))

(define (seed-corpus!)
  (define conn (fresh))
  (define-values (uid tid) (bootstrap! conn #:username "alice"))
  (define root (make-tree))
  (ingest! conn root)
  (values conn (user-principal conn uid tid) tid root))

;; The environment `help-answer` reads: an embedder configured (so
;; `help-available?` does not refuse first) and a model configured (so the chat
;; branch is reached). Both are spelled as NAMES, never as literals inside a
;; `getenv` (ENVN‑2).
(define EMBED-URL-VAR "TMACH_EMBED_URL")
(define EMBED-MODEL-VAR "TMACH_EMBED_MODEL")
(define MODEL-URL-VAR "TMACH_MODEL_URL")

(define (with-help-env thunk #:model-url [murl "http://127.0.0.1:1/v1/chat/completions"])
  (with-env* (list (cons EMBED-URL-VAR "http://127.0.0.1:1/v1/embeddings")
                   (cons EMBED-MODEL-VAR MODEL)
                   (cons MODEL-URL-VAR murl))
             thunk))

;; THE FLOOR IS PASSED EXPLICITLY, AND THE REASON IS WORTH KNOWING. The scripted
;; embedder is a bag of words over 256 buckets, so a seven-word question against
;; a thirty-token passage scores around **0.28** — well under
;; `HELP-SCORE-FLOOR`, which is set from what a REAL embedder produces (0.55–0.8
;; measured against `nomic-embed-text`). With the default every case below would
;; answer `nothing-relevant`, which is how five of them failed first. So the
;; floor is 0 except in the case that is ABOUT the floor, and nothing else here
;; depends on a provisional number.
(define (ask conn p q #:reply [reply "see [X]"] #:k [k 3] #:locale [locale "en"]
             #:floor [floor 0.0])
  (parameterize ([current-help-embed-one embed-one]
                 [current-help-chat (scripted-chat reply)])
    (help-answer conn p q #:locale locale #:fallback-locale "en" #:k k #:floor floor)))

(test-case "16. an answer cites, and every citation is resolved from the passages retrieved"
  (with-help-env (lambda ()
    (define-values (conn p tid root) (seed-corpus!))
    (define base (let-values ([(_b n _d) (split-path root)]) (path->string n)))
    (define secrets (string-append base "/ops/secrets.md"))
    (reset-chat!)
    (define rep (ask conn p "rotating a key and rewrapping sealed columns"
                     #:reply (format "Rotation rewraps every sealed column [~a]." secrets)))
    (check-false (hash-ref rep 'reason) "answered")
    (check-equal? (length (hash-ref rep 'citations)) 1)
    (define c (car (hash-ref rep 'citations)))
    (check-equal? (hash-ref c 'path) secrets)
    (check-equal? (hash-ref c 'title) "Secrets at rest"
                  "the citation carries the title and offsets from the HIT, never retyped by the model")
    (check-true (exact-nonnegative-integer? (hash-ref c 'start)))
    (check-equal? (chat-count) 1)
    ;; the model was shown the passages, with their paths, and told which language
    (define shown (hash-ref (car (unbox chat-calls)) 'prompt))
    (check-true (string-contains? shown secrets))
    (check-true (string-contains? shown "Answer in: en"))
    (check-true (string-contains? (hash-ref (car (unbox chat-calls)) 'system) "ONLY the numbered passages"))
    (close-db! conn))))

(test-case "17. HELP‑16: a path the model invented is DROPPED and reported"
  (with-help-env (lambda ()
    (define-values (conn p tid root) (seed-corpus!))
    (define base (let-values ([(_b n _d) (split-path root)]) (path->string n)))
    (define secrets (string-append base "/ops/secrets.md"))
    (define rep (ask conn p "rotating a key and rewrapping sealed columns"
                     #:reply (format "Yes [~a], and also [docs/ops/does-not-exist.md]." secrets)))
    (check-equal? (for/list ([c (hash-ref rep 'citations)]) (hash-ref c 'path)) (list secrets))
    (check-equal? (hash-ref rep 'invented_citations) '("docs/ops/does-not-exist.md")
                  "a model that names a plausible file it was never shown is the one failure this cannot have")
    (check-false (hash-ref rep 'reason))
    (close-db! conn))))

(test-case "18. an answer that cites nothing is `uncited` and is still returned"
  (with-help-env (lambda ()
    (define-values (conn p tid root) (seed-corpus!))
    (define rep (ask conn p "rotating a key and rewrapping sealed columns"
                     #:reply "The documentation does not cover that."))
    (check-equal? (hash-ref rep 'reason) "uncited"
                  "usually the model declining, which is what it was asked to do")
    (check-equal? (hash-ref rep 'citations) '())
    (check-equal? (hash-ref rep 'answer) "The documentation does not cover that."
                  "returned, so a caller can render a refusal differently rather than lose it")
    (close-db! conn))))

(test-case "19. HELP‑15: the floor refuses BEFORE any model is called"
  (with-help-env (lambda ()
    (define-values (conn p tid root) (seed-corpus!))
    (reset-chat!)
    ;; a question with no word in common with any fixture: the bag-of-words
    ;; embedder puts it in buckets nothing occupies, so the top score is 0
    (define rep (ask conn p "zzzqqq wwwvvv yyyxxx" #:floor HELP-SCORE-FLOOR))
    (check-equal? (hash-ref rep 'reason) "nothing-relevant")
    (check-equal? (hash-ref rep 'answer) 'null)
    (check-equal? (chat-count) 0
                  "the honest refusal costs no tokens, which is the whole reason the floor is first")
    (check-true (< (hash-ref rep 'score) HELP-SCORE-FLOOR))
    ;; …and a question that DOES match is refused by a floor set above its score,
    ;; which is the half a zero-scoring question cannot establish
    (reset-chat!)
    (define near (ask conn p "rotating a key and rewrapping sealed columns" #:floor 0.99))
    (check-equal? (hash-ref near 'reason) "nothing-relevant")
    (check-true (> (hash-ref near 'score) 0.0) "it really did retrieve something")
    (check-equal? (chat-count) 0)
    (close-db! conn))))

(test-case "20. with no model the PASSAGES still come back, with `no-model`"
  (with-help-env #:model-url ""
    (lambda ()
      (define-values (conn p tid root) (seed-corpus!))
      (reset-chat!)
      (define rep (ask conn p "rotating a key and rewrapping sealed columns"))
      (check-equal? (hash-ref rep 'reason) "no-model")
      (check-equal? (chat-count) 0)
      (check-true (> (length (hash-ref rep 'passages)) 0)
                  "`content_search: false`'s posture — report what did not run, keep what did")
      (close-db! conn))))

(test-case "21. the three ways the corpus itself can be unavailable"
  (define-values (conn p tid root) (seed-corpus!))
  ;; no embedder at all
  (with-env* (list (cons EMBED-URL-VAR "") (cons EMBED-MODEL-VAR ""))
    (lambda ()
      (check-equal? (hash-ref (ask conn p "anything") 'reason) "unconfigured")))
  (with-help-env (lambda ()
    (check-equal? (hash-ref (ask conn p "anything" #:locale "fr") 'reason) "locale-empty")
    (help-clear! conn)
    (check-equal? (hash-ref (ask conn p "anything") 'reason) "empty")))
  (close-db! conn))

(test-case "22. HELP‑21: it charges ai.help.total and ai.requests, and NOT ai.tokens.total"
  (with-help-env (lambda ()
    (define-values (conn p tid root) (seed-corpus!))
    (ask conn p "rotating a key and rewrapping sealed columns")
    (check-true (> (quota-used conn "team" tid "ai.help.total" "total") 0)
                "its own dimension, so an operator can bound help specifically")
    (check-equal? (quota-used conn "team" tid "ai.tokens.total" "total") 0
                  "#183's own point: folding help into the 2,000/day completion budget is what makes it stop at lunchtime")
    (check-true (>= (quota-used conn "team" tid "ai.requests" "total") 2)
                "the dimension counts calls to a model and this is two of them")
    ;; a refusal below the floor still spent the EMBEDDING, so it still bills it —
    ;; metering only successes makes a failing path free (FEED‑9's rule)
    (define before (quota-used conn "team" tid "ai.help.total" "total"))
    (ask conn p "zzzqqq wwwvvv yyyxxx")
    (check-true (> (quota-used conn "team" tid "ai.help.total" "total") before))
    (close-db! conn))))

(test-case "23. help-cited-paths reads what a model really writes"
  (check-equal? (help-cited-paths "see [docs/a.md]") '("docs/a.md"))
  (check-equal? (help-cited-paths "[docs/a.md] and [docs/b.md], then [docs/a.md] again")
                '("docs/a.md" "docs/b.md") "de-duplicated, in the order cited")
  (check-equal? (help-cited-paths "spaced [ docs/a.md ]") '("docs/a.md") "trimmed")
  (check-equal? (help-cited-paths "nothing here") '())
  (check-equal? (help-cited-paths "a [markdown](link) is not a citation") '("markdown")
                "stated rather than cured: a bracketed word is indistinguishable from a path here, which is why an invented one is DROPPED by resolution rather than trusted"))

(test-case "24. an empty question is refused by name"
  (with-help-env (lambda ()
    (define-values (conn p tid root) (seed-corpus!))
    (check-exn #px"question is required" (lambda () (ask conn p "   ")))
    (check-exn #px"question is required" (lambda () (ask conn p "")))
    (close-db! conn))))
