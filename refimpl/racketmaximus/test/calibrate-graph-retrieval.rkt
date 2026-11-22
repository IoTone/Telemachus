#lang racket/base

;; test/calibrate-graph-retrieval.rkt — does expanding through the knowledge
;; graph find the right document more often than plain semantic search? (RG-6,
;; issue #191.)
;;
;; NOT a suite, and not named `*-tests.rkt`: it needs a live embedder AND a live
;; chat model, and the build step takes hours. `calibrate-retrieval.rkt` lives
;; here on the same terms.
;;
;;   export TMACH_EMBED_URL=… TMACH_EMBED_MODEL=bge-m3
;;   export TMACH_MODEL_URL=… TMACH_MODEL=qwen2.5:7b
;;   racket test/calibrate-graph-retrieval.rkt --db /path/rg6.db --build
;;   racket test/calibrate-graph-retrieval.rkt --db /path/rg6.db --out result.json
;;
;; TWO STEPS, ONE DATABASE FILE. `--build` stores every Markdown file of the
;; corpus as a repository document, embeds its chunks and runs the shipped
;; knowledge-graph extraction over it. It is resumable: a document that already
;; has its chunks or its extraction marker is skipped, so a run that stops can be
;; started again. Scoring (no `--build`) only reads, and embeds the questions.
;;
;; WHAT IS COMPARED, per question and per language, at the FILE level (the rule
;; `calibrate-retrieval.rkt` explains):
;;
;;   plain         the top k chunks by similarity. What `repo_retrieve` does.
;;   graph-first   entities whose NAME appears in the question pick the
;;                 documents that mention them; the same ranking is then
;;                 restricted to those documents. With no entity in the
;;                 question it is plain.
;;   graph-first+1 the same, with the entities one relation away added.
;;   vector-first  the top half of the plain answer is kept, and the rest of
;;                 the k places go to the best chunks from documents that share
;;                 an entity (or a neighbour of one) with the plain answer.
;;
;; WHY vector-first RESERVES PLACES. Expanding the candidate set and then
;; ranking by the same similarity cannot change the answer: every added chunk
;; scored below the ones already chosen. So an expansion only does anything if
;; it is given places, and half is the simplest rule to state.
;;
;; THE RANKING IS THE PRODUCT'S. Every variant filters ONE ranked list from
;; `chunks-nearest`, so no retrieval code is prototyped here beyond the choice
;; of which documents are eligible.
;;
;; THE GRAPH IS READ WITH PLAIN SQL, with no per-row permission check, because
;; the corpus is one team's and every document in it is team-visible. A product
;; version would go through `kg-find` and `kg-neighbourhood`.
;;
;; WHAT IT CANNOT SAY: the corpus is this project's documentation and the
;; questions were written by its author, so the figures compare the variants
;; with each other and are not a benchmark. A corpus of bookmarked web pages may
;; behave differently; `--docs` and `--questions` exist so one can be measured.

(require json racket/list racket/string racket/file racket/format racket/port racket/path
         db-kit db-kit/portable db-kit/migrate
         "../domain/db/migrations.rkt"
         (only-in "../config.rkt" impl-root)
         "../domain/authz/authz.rkt"
         "../domain/repo/blobs.rkt"
         (only-in "../domain/repo/repo.rkt" repo-put!)
         (only-in "../domain/repo/extract.rkt" repo-text-upsert!)
         (only-in "../domain/repo/doc-tools.rkt" current-doc-chat)
         (only-in "../domain/repo/embed-tools.rkt")
         (only-in "../domain/kg/kg-tools.rkt" extract-document validate-extraction)
         (only-in "../domain/kg/kg.rkt" normalize-name kg-upsert!)
         (only-in "../domain/quota/quota.rkt" set-limit!)
         (only-in "../domain/ai/executor.rkt" embed-exchange embed-model embed-configured?)
         (only-in "../domain/ai/chunksearch.rkt" chunks-nearest)
         "../domain/agent/registry.rkt")

(define (arg-value name default)
  (let loop ([a (vector->list (current-command-line-arguments))])
    (cond [(or (null? a) (null? (cdr a))) default]
          [(equal? (car a) name) (cadr a)]
          [else (loop (cdr a))])))
(define (flag? name) (and (member name (vector->list (current-command-line-arguments))) #t))

(define KS '(1 3 5))
(define repo-root
  (arg-value "--docs" (path->string (simplify-path (build-path impl-root 'up 'up) #f))))
(define questions-path
  (arg-value "--questions" (path->string (build-path impl-root "test" "calibration-questions.json"))))
(define questions (hash-ref (call-with-input-file questions-path read-json) 'questions))

(define (ja-key? k) (or (regexp-match? #rx"/ja/" k) (regexp-match? #rx"[.]ja[.]md$" k)))
(define (locale-of k) (if (ja-key? k) "ja" "en"))

;; every Markdown file, as a path relative to the corpus root. Files a question
;; names go FIRST, so a build that is stopped early has covered the documents
;; the scoring depends on.
(define (corpus-files)
  (define all
    (sort
     (append
      (for/list ([f (in-directory (build-path repo-root "docs"))]
                 #:when (regexp-match? #rx"[.]md$" (path->string f)))
        (path->string (find-relative-path (simplify-path (path->complete-path repo-root))
                                          (simplify-path (path->complete-path f)))))
      (for/list ([n '("README.md" "README.ja.md")] #:when (file-exists? (build-path repo-root n))) n))
     string<?))
  (define wanted
    (remove-duplicates
     (for*/list ([q (in-list questions)] [k '(en_files ja_files)] [f (in-list (hash-ref q k '()))]) f)))
  (append (filter (lambda (f) (member f all)) wanted)
          (filter (lambda (f) (not (member f wanted))) all)))

;; ---- the database -------------------------------------------------------------

(define (open-db path)
  (define conn ((db-connector (string-append "sqlite:///" path))))
  (migrate! conn all-migrations)
  conn)

(define (principal-for conn)
  (define row (query-maybe-row conn "SELECT user_id, team_id FROM memberships LIMIT 1"))
  (cond
    [row (values (user-principal conn (vector-ref row 0) (vector-ref row 1)) (vector-ref row 1))]
    [else
     (define-values (uid tid) (bootstrap! conn #:username "calibrate"))
     (for ([d '("ai.requests" "ai.tokens.total" "ai.embeddings.total")])
       (set-limit! conn "team" tid d 1000000000))
     (values (user-principal conn uid tid) tid)]))

(define (call-tool conn p name args)
  ((tool-handler (tool-by-name name)) conn p args))

;; ---- the graph step, two ways ---------------------------------------------------
;;
;; AS SHIPPED, `kg_extract` refuses a whole reply when any one snippet in it is
;; not verbatim. `--per-item` keeps what validates and drops what does not: an
;; entity stays when it has a name, a type and a snippet that really is in the
;; text; a relation stays when both its ends stayed and its own snippet is in
;; the text. The rule that nothing enters the graph without a verbatim source is
;; unchanged; what changes is that one bad item no longer costs the other ten.
;;
;; It is done by wrapping the CHAT seam, so the windowing, the merge and the
;; write are the product's own. Each reply is ALSO judged by the shipped
;; validator and the verdict is recorded, so one run reports how often the
;; shipped rule would have accepted a window.

(define (str? v) (and (string? v) (not (string=? (string-trim v) ""))))

(define (reply-json raw)
  (define a (for/first ([i (in-naturals)] [c (in-string raw)] #:when (char=? c #\{)) i))
  (define b (for/last ([i (in-naturals)] [c (in-string raw)] #:when (char=? c #\})) i))
  (and a b (> b a)
       (with-handlers ([exn:fail? (lambda (_) #f)]) (string->jsexpr (substring raw a (add1 b))))))

;; A SNIPPET IS COMPARED WITH WHITESPACE COLLAPSED. These documents are
;; hard-wrapped, so an excerpt longer than a line crosses a newline in the file
;; and the model writes a space there. That is still an excerpt of the document;
;; an exact comparison refuses it. How many were exact is counted beside it.
(define (ws s) (string-join (string-split s) " "))

(define (exact-entities j text)
  (for/sum ([e (in-list (let ([v (hash-ref j 'entities '())]) (if (list? v) v '())))])
    (if (and (hash? e) (string? (hash-ref e 'snippet #f)) (string-contains? text (hash-ref e 'snippet))) 1 0)))

;; THE STORED SNIPPET IS THE DOCUMENT'S OWN TEXT, newline and all: the excerpt
;; is located with any run of whitespace allowed between its words and what is
;; kept is what the document says there. So what reaches the graph still passes
;; the shipped character-exact check, which runs after this.
(define (locate text sn)
  (define words (string-split sn))
  (and (pair? words)
       (let ([m (regexp-match (regexp (string-join (map regexp-quote words) "[ \t\r\n]+")) text)])
         (and m (car m)))))

(define (keep-valid j text)
  (define ents
    (for/list ([e (in-list (let ([v (hash-ref j 'entities '())]) (if (list? v) v '())))]
               #:when (and (hash? e) (str? (hash-ref e 'name #f)) (str? (hash-ref e 'type #f))
                           (str? (hash-ref e 'snippet #f))
                           (locate text (hash-ref e 'snippet))))
      (hasheq 'type (hash-ref e 'type) 'name (hash-ref e 'name)
              'description (let ([d (hash-ref e 'description "")]) (if (string? d) d ""))
              'snippet (locate text (hash-ref e 'snippet)))))
  (define names (for/list ([e (in-list ents)]) (normalize-name (hash-ref e 'name))))
  (define rels
    (for/list ([r (in-list (let ([v (hash-ref j 'relations '())]) (if (list? v) v '())))]
               #:when (and (hash? r)
                           (for/and ([k '(subject predicate object snippet)]) (str? (hash-ref r k #f)))
                           (member (normalize-name (hash-ref r 'subject)) names)
                           (member (normalize-name (hash-ref r 'object)) names)
                           (locate text (hash-ref r 'snippet))))
      (hasheq 'subject (hash-ref r 'subject) 'predicate (hash-ref r 'predicate)
              'object (hash-ref r 'object) 'snippet (locate text (hash-ref r 'snippet)))))
  (hasheq 'entities ents 'relations rels))

(define (count-of j k) (let ([v (and (hash? j) (hash-ref j k '()))]) (if (list? v) (length v) 0)))

;; -> a hash of what happened, or raises
(define (extract-per-item! conn tid oid text window)
  (define stats (make-hasheq))
  (define (bump! k n) (hash-update! stats k (lambda (x) (+ x n)) 0))
  (define real (current-doc-chat))
  (define (chat prompt #:system [sys #f])
    (define doc (hash-ref (string->jsexpr prompt) 'document))
    (define-values (reply tokens) (real prompt #:system sys))
    (define j (reply-json (format "~a" reply)))
    (bump! 'windows 1)
    (cond
      [(not (hash? j)) (bump! 'unreadable 1)
                       (values (jsexpr->string (hasheq 'entities '() 'relations '())) tokens)]
      [else
       (when (null? (validate-extraction j doc)) (bump! 'shipped_ok 1))
       (define kept (keep-valid j doc))
       (when (flag? "--show-dropped")
         (for ([e (in-list (let ([v (hash-ref j 'entities '())]) (if (list? v) v '())))])
           (define sn (and (hash? e) (hash-ref e 'snippet #f)))
           (unless (and (string? sn) (string-contains? (ws doc) (ws sn)))
             (printf "    dropped ~s: ~s\n" (and (hash? e) (hash-ref e 'name #f))
                     (if (string? sn) (substring sn 0 (min 100 (string-length sn))) sn)))))
       (bump! 'entities_exact (exact-entities j doc))
       (bump! 'entities_seen (count-of j 'entities)) (bump! 'entities_kept (count-of kept 'entities))
       (bump! 'relations_seen (count-of j 'relations)) (bump! 'relations_kept (count-of kept 'relations))
       (values (jsexpr->string kept) tokens)]))
  (define-values (extraction _t _w truncated?) (extract-document text #:chat chat #:window window))
  (define version (query-value conn "SELECT current_version_id FROM repo_objects WHERE id = ?" oid))
  (kg-upsert! conn tid oid version extraction)
  (query-exec conn "DELETE FROM calib_extract WHERE object_id = ?" oid)
  (query-exec conn
    (string-append "INSERT INTO calib_extract (object_id, windows, unreadable, shipped_ok, "
                   "entities_seen, entities_kept, relations_seen, relations_kept, entities_exact) VALUES (?,?,?,?,?,?,?,?,?)")
    oid (hash-ref stats 'windows 0) (hash-ref stats 'unreadable 0) (hash-ref stats 'shipped_ok 0)
    (hash-ref stats 'entities_seen 0) (hash-ref stats 'entities_kept 0)
    (hash-ref stats 'relations_seen 0) (hash-ref stats 'relations_kept 0)
    (hash-ref stats 'entities_exact 0)))

;; the shipped tool reports what it kept and what it dropped; keep that per document so a
;; build can say how the real model fared under the shipped rule (RG-36)
(define (record-shipped! conn oid r)
  (when (hash? r)
    (query-exec conn "DELETE FROM calib_shipped WHERE object_id = ?" oid)
    (query-exec conn
      (string-append "INSERT INTO calib_shipped (object_id, windows, unreadable, entities, relations, dropped) "
                     "VALUES (?,?,?,?,?,?)")
      oid (hash-ref r 'windows 0) (hash-ref r 'windows_unreadable 0)
      (hash-ref r 'entities 0) (hash-ref r 'relations 0) (hash-ref r 'dropped 0))))

;; ---- build ----------------------------------------------------------------------

(define (build! conn p tid)
  (define per-item? (flag? "--per-item"))
  (define window-en (string->number (arg-value "--window-en" "12000")))
  (define window-ja (string->number (arg-value "--window-ja" "12000")))
  (query-exec conn
    (string-append "CREATE TABLE IF NOT EXISTS calib_extract (object_id TEXT PRIMARY KEY, windows INTEGER, "
                   "unreadable INTEGER, shipped_ok INTEGER, entities_seen INTEGER, entities_kept INTEGER, "
                   "relations_seen INTEGER, relations_kept INTEGER, entities_exact INTEGER)"))
  (query-exec conn
    (string-append "CREATE TABLE IF NOT EXISTS calib_shipped (object_id TEXT PRIMARY KEY, windows INTEGER, "
                   "unreadable INTEGER, entities INTEGER, relations INTEGER, dropped INTEGER)"))
  (define files
    (let ([all (corpus-files)] [n (string->number (arg-value "--max-files" "0"))])
      (if (and n (positive? n) (< n (length all))) (take all n) all)))
  (printf "corpus: ~a Markdown files under ~a\ngraph step: ~a\n" (length files) repo-root
          (if per-item?
              (format "per item, windows of ~a (en) / ~a (ja) characters" window-en window-ja)
              "as shipped, the tool's own default window"))
  (define failed '())
  (for ([f (in-list files)] [i (in-naturals 1)])
    (define text (file->string (build-path repo-root f)))
    (define oid
      (or (query-maybe-value conn
            "SELECT id FROM repo_objects WHERE team_id = ? AND key = ? AND deleted_at IS NULL" tid f)
          (let ([o (repo-put! conn p #:key f #:port (open-input-bytes (string->bytes/utf-8 text))
                              #:content-type "text/markdown" #:filename f #:visibility "team"
                              #:allow-empty? #t)])
            (repo-text-upsert! conn (hash-ref o 'id) (hash-ref o 'version_id) text)
            (hash-ref o 'id))))
    (define t0 (current-inexact-milliseconds))
    (define (step! label done? thunk)
      (cond
        [done? "have"]
        [else
         (with-handlers ([exn:fail? (lambda (e)
                                      (set! failed (cons (hasheq 'file f 'step label
                                                                 'error (exn-message e)) failed))
                                      "FAILED")])
           (thunk) "ok")]))
    (define blank? (string=? (string-trim text) ""))
    (define e
      (step! "embed"
             (or blank? (query-maybe-value conn "SELECT 1 FROM repo_chunks WHERE object_id = ? LIMIT 1" oid))
             (lambda () (call-tool conn p "repo_embed_chunks" (hasheq 'id oid)))))
    (define k
      (step! "extract"
             (or blank? (query-maybe-value conn "SELECT 1 FROM kg_extractions WHERE object_id = ?" oid))
             (lambda ()
               (if per-item?
                   (extract-per-item! conn tid oid text (if (ja-key? f) window-ja window-en))
                   (record-shipped! conn oid (call-tool conn p "kg_extract" (hasheq 'object oid)))))))
    (printf "~a/~a  embed ~a  graph ~a  ~as  ~a (~a chars)\n" i (length files) e k
            (~r (/ (- (current-inexact-milliseconds) t0) 1000.0) #:precision 1)
            f (string-length text))
    (flush-output))
  (printf "\nbuilt: ~a documents, ~a with chunks, ~a through the graph step, ~a entities, ~a relations\n"
          (query-value conn "SELECT COUNT(*) FROM repo_objects WHERE deleted_at IS NULL")
          (query-value conn "SELECT COUNT(DISTINCT object_id) FROM repo_chunks")
          (query-value conn "SELECT COUNT(*) FROM kg_extractions")
          (query-value conn "SELECT COUNT(*) FROM kg_entities")
          (query-value conn "SELECT COUNT(*) FROM kg_relations"))
  (let ([r (query-row conn
             (string-append "SELECT COUNT(*), COALESCE(SUM(windows),0), COALESCE(SUM(unreadable),0), "
                            "COALESCE(SUM(shipped_ok),0), COALESCE(SUM(entities_seen),0), "
                            "COALESCE(SUM(entities_kept),0), COALESCE(SUM(relations_seen),0), "
                            "COALESCE(SUM(relations_kept),0), COALESCE(SUM(entities_exact),0) FROM calib_extract"))])
    (when (positive? (vector-ref r 0))
      (printf (string-append "per-item graph step over ~a documents: ~a model replies, ~a unreadable, "
                             "~a the shipped rule would have accepted; entities kept ~a of ~a "
                             "(~a with a character-exact snippet), relations kept ~a of ~a\n")
              (vector-ref r 0) (vector-ref r 1) (vector-ref r 2) (vector-ref r 3)
              (vector-ref r 5) (vector-ref r 4) (vector-ref r 8) (vector-ref r 7) (vector-ref r 6))))
  (let ([r (query-row conn
             (string-append "SELECT COUNT(*), COALESCE(SUM(windows),0), COALESCE(SUM(unreadable),0), "
                            "COALESCE(SUM(entities),0), COALESCE(SUM(relations),0), COALESCE(SUM(dropped),0) "
                            "FROM calib_shipped"))])
    (when (positive? (vector-ref r 0))
      (printf (string-append "shipped graph step over ~a documents: ~a model replies, ~a unreadable; "
                             "kept ~a entities and ~a relations, dropped ~a items\n")
              (vector-ref r 0) (vector-ref r 1) (vector-ref r 2)
              (vector-ref r 3) (vector-ref r 4) (vector-ref r 5))))
  (unless (null? failed)
    (printf "FAILED steps (~a); run --build again to retry them:\n" (length failed))
    (for ([x (in-list (reverse failed))])
      (printf "  ~a ~a: ~a\n" (hash-ref x 'step) (hash-ref x 'file)
              (let ([m (hash-ref x 'error)]) (if (> (string-length m) 160) (substring m 0 160) m))))))

;; ---- the graph, read once -------------------------------------------------------

(struct graph (names        ; entity id -> normalized name
               on-object    ; object id -> list of entity ids
               objects-of   ; entity id -> list of object ids
               neighbours)) ; entity id -> list of entity ids

(define (load-graph conn tid)
  (define names (make-hash))
  (for ([r (in-list (query-rows conn "SELECT id, name_norm FROM kg_entities WHERE team_id = ?" tid))])
    (hash-set! names (vector-ref r 0) (vector-ref r 1)))
  (define on-object (make-hash))
  (define objects-of (make-hash))
  (for ([r (in-list (query-rows conn
                      (string-append "SELECT DISTINCT entity_id, object_id FROM kg_mentions "
                                     "WHERE team_id = ? AND entity_id IS NOT NULL") tid))])
    (hash-update! on-object (vector-ref r 1) (lambda (l) (cons (vector-ref r 0) l)) '())
    (hash-update! objects-of (vector-ref r 0) (lambda (l) (cons (vector-ref r 1) l)) '()))
  (define neighbours (make-hash))
  (for ([r (in-list (query-rows conn "SELECT subject_id, object_id FROM kg_relations WHERE team_id = ?" tid))])
    (hash-update! neighbours (vector-ref r 0) (lambda (l) (cons (vector-ref r 1) l)) '())
    (hash-update! neighbours (vector-ref r 1) (lambda (l) (cons (vector-ref r 0) l)) '()))
  (graph names on-object objects-of neighbours))

;; AN ENTITY IS "IN THE QUESTION" WHEN ITS NORMALIZED NAME APPEARS IN IT. For a
;; name written in ASCII that is a whole-word match, or "api" would be found in
;; "rapid"; Japanese has no word boundaries, so it is a substring. Very short
;; names are left out for the same reason.
(define (entities-in g text)
  (define low (normalize-name text))
  (for/list ([(id name) (in-hash (graph-names g))]
             #:when (cond
                      [(regexp-match? #px"^[ -~]+$" name)
                       (and (>= (string-length name) 3)
                            (regexp-match? (pregexp (string-append "(?<![a-z0-9])" (regexp-quote name)
                                                                   "(?![a-z0-9])"))
                                           low))]
                      [else (and (>= (string-length name) 2)
                                 (regexp-match? (regexp-quote name) low))]))
    id))

(define (with-neighbours g ids)
  (remove-duplicates
   (append ids (append* (for/list ([i (in-list ids)]) (hash-ref (graph-neighbours g) i '()))))))
(define (objects-mentioning g ids)
  (remove-duplicates (append* (for/list ([i (in-list ids)]) (hash-ref (graph-objects-of g) i '())))))

;; ---- asking --------------------------------------------------------------------

(define q-cache (make-hash))
(define (embed-question text)
  (hash-ref! q-cache text
             (lambda ()
               (define-values (vs _t _u _m) (embed-exchange (list text) #:who 'calibrate))
               (car vs))))

(define (take-at-most l n) (if (> (length l) n) (take l n) l))

;; the first k of `preferred`, topped up from `fallback` in its own order
(define (fill k preferred fallback)
  (define chosen (take-at-most preferred k))
  (take-at-most (append chosen (filter (lambda (h) (not (memq h chosen))) fallback)) k))

;; ranked: every chunk of this language, best first. -> variant name -> (k -> hits)
(define (variants g ranked text)
  (define (in-objects objs) (filter (lambda (h) (member (hash-ref h 'object_id) objs)) ranked))
  (define named (entities-in g text))
  (define first0 (objects-mentioning g named))
  (define first1 (objects-mentioning g (with-neighbours g named)))
  (define (vector-first k)
    (define keep (take-at-most ranked (quotient (add1 k) 2)))
    (define seeds (remove-duplicates (map (lambda (h) (hash-ref h 'object_id)) (take-at-most ranked k))))
    (define ents (remove-duplicates (append* (for/list ([o (in-list seeds)]) (hash-ref (graph-on-object g) o '())))))
    (define reach (filter (lambda (o) (not (member o seeds)))
                          (objects-mentioning g (with-neighbours g ents))))
    (values (fill k (append keep (in-objects reach)) ranked) reach))
  (values
   (hasheq 'plain (lambda (k) (take-at-most ranked k))
           'graph_first (lambda (k) (if (null? first0) (take-at-most ranked k) (fill k (in-objects first0) ranked)))
           'graph_first_1 (lambda (k) (if (null? first1) (take-at-most ranked k) (fill k (in-objects first1) ranked)))
           'vector_first (lambda (k) (let-values ([(hits _r) (vector-first k)]) hits)))
   ;; what the windows looked like, which says whether a restriction restricted
   (hasheq 'entities_named (length named)
           'window_0 (length first0)
           'window_1 (length first1)
           'reach_5 (let-values ([(_h reach) (vector-first 5)]) (length reach)))))

(define VARIANTS '(plain graph_first graph_first_1 vector_first))

(define (score! conn p tid)
  (define g (load-graph conn tid))
  (define docs (query-value conn "SELECT COUNT(DISTINCT object_id) FROM repo_chunks"))
  (define chunks (query-value conn "SELECT COUNT(*) FROM repo_chunks"))
  (define graphed (query-value conn "SELECT COUNT(DISTINCT object_id) FROM kg_mentions WHERE entity_id IS NOT NULL"))
  (define obj-key (make-hash))
  (for ([r (in-list (query-rows conn "SELECT id, key FROM repo_objects WHERE deleted_at IS NULL"))])
    (hash-set! obj-key (vector-ref r 0) (vector-ref r 1)))
  (printf "corpus: ~a documents with chunks (~a chunks), ~a with at least one entity; ~a entities, ~a relations\n"
          docs chunks graphed (hash-count (graph-names g))
          (query-value conn "SELECT COUNT(*) FROM kg_relations"))
  (printf "models: embed ~a\n\n" (embed-model))
  (define per-question '())
  (define totals (make-hash))   ; (locale variant k) -> hits
  (define asked (make-hash))    ; locale -> n
  (define diag (make-hash))     ; (locale key) -> sum
  (for* ([locale '("en" "ja")] [q (in-list questions)])
    (define text (hash-ref q (if (equal? locale "en") 'en 'ja)))
    (define want (hash-ref q (if (equal? locale "en") 'en_files 'ja_files) '()))
    (when (pair? want)
      (define rep (chunks-nearest conn p (embed-question text) (embed-model) #:k (max 1 chunks)))
      (define ranked (filter (lambda (h) (equal? (locale-of (hash-ref h 'key)) locale)) (hash-ref rep 'hits)))
      (define-values (vs d) (variants g ranked text))
      (hash-update! asked locale add1 0)
      (define (hit? hits) (for/or ([h (in-list hits)]) (and (member (hash-ref h 'key) want) #t)))
      (define row
        (for*/hasheq ([v (in-list VARIANTS)])
          (values v (for/list ([k (in-list KS)])
                      (define ok (hit? ((hash-ref vs v) k)))
                      (when ok (hash-update! totals (list locale v k) add1 0))
                      ok))))
      ;; could the window have held the answer at all?
      (define named-objs (objects-mentioning g (entities-in g text)))
      (define window-has
        (for/or ([o (in-list named-objs)]) (and (member (hash-ref obj-key o "") want) #t)))
      (for ([(k v) (in-hash d)]) (hash-update! diag (list locale k) (lambda (x) (+ x v)) 0))
      (when (positive? (hash-ref d 'entities_named)) (hash-update! diag (list locale 'named_any) add1 0))
      (when window-has (hash-update! diag (list locale 'window_has_answer) add1 0))
      (set! per-question
            (cons (hasheq 'id (hash-ref q 'id) 'locale locale 'results row 'windows d
                          'window_has_answer (and window-has #t)
                          'plain_top (for/list ([h (in-list (take-at-most ranked 5))]) (hash-ref h 'key)))
                  per-question))))
  (define (pct n d) (if (zero? d) 0 (inexact->exact (round (* 100.0 (/ n d))))))
  (for ([locale '("en" "ja")])
    (define n (hash-ref asked locale 0))
    (printf "~a  (~a questions)\n" locale n)
    (for ([v (in-list VARIANTS)])
      (printf "  ~a" (~a v #:width 15))
      (for ([k (in-list KS)])
        (define h (hash-ref totals (list locale v k) 0))
        (printf "r@~a ~a/~a (~a%)   " k h n (pct h n)))
      (newline))
    (printf "  questions naming an entity: ~a/~a;  answer inside the graph-first window: ~a/~a\n"
            (hash-ref diag (list locale 'named_any) 0) n
            (hash-ref diag (list locale 'window_has_answer) 0) n)
    (printf "  mean documents in the window: graph-first ~a, +1 hop ~a; reached by vector-first at k=5: ~a (of ~a)\n\n"
            (~r (/ (hash-ref diag (list locale 'window_0) 0) (max 1 n) 1.0) #:precision 1)
            (~r (/ (hash-ref diag (list locale 'window_1) 0) (max 1 n) 1.0) #:precision 1)
            (~r (/ (hash-ref diag (list locale 'reach_5) 0) (max 1 n) 1.0) #:precision 1)
            docs))
  (define out (arg-value "--out" #f))
  (when out
    (call-with-output-file out #:exists 'truncate
      (lambda (o)
        (write-json
         (hasheq 'embed_model (embed-model) 'documents docs 'chunks chunks 'documents_in_graph graphed
                 'entities (hash-count (graph-names g))
                 'asked (for/hasheq ([(k v) (in-hash asked)]) (values (string->symbol k) v))
                 'recall (for/list ([(k v) (in-hash totals)])
                           (hasheq 'locale (car k) 'variant (symbol->string (cadr k)) 'k (caddr k) 'hits v))
                 'questions (reverse per-question))
         o)))
    (printf "wrote ~a\n" out)))

(module+ main
  (define db (arg-value "--db" #f))
  (unless db (error 'calibrate "--db <path> is required; it holds the corpus between the two steps"))
  (unless (embed-configured?)
    (error 'calibrate "set TMACH_EMBED_URL and TMACH_EMBED_MODEL — this needs a live embedder"))
  (current-blob-root (string-append db ".blobs"))
  (make-directory* (current-blob-root))
  (define conn (open-db db))
  (define-values (p tid) (principal-for conn))
  (if (flag? "--build") (build! conn p tid) (score! conn p tid)))
