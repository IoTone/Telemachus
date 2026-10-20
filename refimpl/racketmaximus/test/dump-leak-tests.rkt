#lang racket/base

;; test/dump-leak-tests.rkt — issue #83's acceptance criterion, as a whole-database
;; scan: "a SQLite/Postgres dump taken after processing a fixture contains no
;; fixture text".
;;
;; WHY A SCAN AND NOT A LIST OF COLUMNS. Sealing `jobs.payload` means editing a
;; dozen SQL sites, and the dangerous half is the WRITES: a missed read hands
;; ciphertext to `string->jsexpr` and raises, which is loud, while a missed write
;; stores plaintext silently. Auditing my own enumeration of those sites is
;; exactly the kind of check that passes because it never looked in the right
;; place — so this walks EVERY table and EVERY text column the schema actually
;; has, and names what it finds. It therefore also catches a column nobody
;; thought about, and a future one added without a thought.
;;
;; It is deliberately NOT a list of expected leaks to tick off. The assertion is
;; "nothing anywhere", and the failure message is the inventory.
;;
;;   raco test test/dump-leak-tests.rkt
;;   DATABASE_URL="postgres://…" raco test test/dump-leak-tests.rkt

(require rackunit db-kit/portable racket/string racket/list racket/file racket/port
         db-kit/migrate
         "../domain/db/migrations.rkt"
         "db-fixture.rkt"
         "../domain/authz/authz.rkt"
         "../domain/db/id.rkt"
         "../domain/repo/blobs.rkt"
         "../domain/repo/extract.rkt"
         "../domain/sched/scheduler.rkt"
         "../domain/agent/registry.rkt"
         (only-in "../domain/tools/dsl.rkt" define-tool)
         "../domain/agent/tools.rkt"
         "../domain/flow/dsl.rkt"
         "../domain/notes/notes.rkt"
         "../domain/apps/translate.rkt"
         "../domain/flow/run.rkt"
         "../config.rkt")

(define BLOB-ROOT (make-temporary-file "telemachus-leak-~a" 'directory))
(current-blob-root BLOB-ROOT)

(define (fresh) (define c (fresh-db #:migrate? #f)) (migrate! c all-migrations) c)

;; A string that cannot occur by accident, so a hit is a hit.
(define NEEDLE "ZQX-PATIENT-8831-NHS-9434765919")

(define (with-env name value thunk)
  (define saved (getenv name))
  (dynamic-wind (lambda () (putenv name value)) thunk
                (lambda () (putenv name (or saved "")))))

;; ---- the scan -------------------------------------------------------------------
;; Every table the schema has, on either dialect. `fresh-db` gives a private
;; SCHEMA per fixture on Postgres, so the listing is scoped to the current one or
;; it would walk other concurrent test files' tables.
(define (all-tables conn)
  (case (db-dialect conn)
    [(sqlite3)
     (query-list conn "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'")]
    [(postgresql)
     (query-list conn (string-append "SELECT tablename FROM pg_tables "
                                     "WHERE schemaname = current_schema()"))]
    [else '()]))

;; Column names, so the scan can report WHERE a leak is rather than only that one
;; exists — the difference between a usable failure and a puzzle.
(define (columns-of conn table)
  (case (db-dialect conn)
    [(sqlite3)
     (for/list ([r (in-list (query-rows conn (format "PRAGMA table_info(~a)" table)))])
       (vector-ref r 1))]
    [(postgresql)
     (query-list conn (string-append "SELECT column_name FROM information_schema.columns "
                                     "WHERE table_schema = current_schema() AND table_name = ?")
                 table)]
    [else '()]))

;; -> a list of "table.column" that still contain the needle.
(define (scan-for conn needle)
  (for*/list ([t (in-list (all-tables conn))]
              [c (in-list (columns-of conn t))]
              #:when (with-handlers ([exn:fail? (lambda (_) #f)])
                       ;; CAST so the comparison works on any column type without
                       ;; the scan having to know the schema; a column that cannot
                       ;; be cast is skipped rather than failing the run.
                       (> (query-value conn
                            (format "SELECT COUNT(*) FROM ~a WHERE CAST(~a AS TEXT) LIKE ?" t c)
                            (string-append "%" needle "%"))
                          0)))
    (format "~a.~a" t c)))

;; ---- the fixture work -----------------------------------------------------------
;; A realistic pass: a document with the needle in it, its extracted text, and a
;; job whose payload carries the needle and whose result echoes it — which is what
;; `infer.chat` does with a document's words.
;; A real workflow, driven through the real scheduler, so the scan sees what a
;; RUN writes: `workflow_runs.input`, each step's `input` and `output`, and the
;; run's `cursor_json` (which holds the bound values between steps). Inserting a
;; row by hand would miss three of those four.
;; `create_note` is a built-in tool, so no tool has to be registered: the note's
;; TITLE carries the needle into the step's input, and the tool's reply carries it
;; into the step's output — which is the pair this slice is about.
(define-workflow leak-probe
  #:description "Carry a string through a step's input and output"
  #:input ([subject string])
  (step write (tool create_note #:title (in subject) #:body "filed by the leak probe") #:end))

(define (run-a-workflow! c p)
  (define d (flow-publish! c p leak-probe))
  (define run (flow-run-start! c p d #:input (hasheq 'subject (string-append "Case: " NEEDLE))))
  (let loop ([n 0]) (when (and (< n 20) (process-one! c)) (loop (add1 n))))
  (hash-ref run 'id))

;; The probe also stores a TRANSLATION, because `doc_translate` writes a
;; document's text into `translations.source_text` on every pipeline translation —
;; and the scan missed that column until the probe exercised it. The chat is a
;; stub: what is under test is the COLUMN, not the model.
(define (translate-something! c p)
  (translate! c p #:text (string-append "Patient note: " NEEDLE) #:target-lang "ja"
              #:use-glossary #f
              #:chat (lambda (t sys) (values (string-append "[ja] " t) 7))))

(define (do-work! c uid tid)
  (define oid (new-id))
  (repo-text-upsert! c oid "v1" (string-append "Extracted: " NEEDLE))
  (register-job-kind! "echo-needle"
                      (lambda (conn p payload) (hasheq 'reply (hash-ref payload 'prompt ""))))
  (define j (enqueue-job! c #:team tid #:user uid #:kind "echo-needle"
                          #:payload (hasheq 'prompt (string-append "Summarise: " NEEDLE))))
  (void (process-one! c))
  ;; translate! answers TWO values (the row and the token count), and `(void x)`
  ;; takes exactly one — so this is define-values, not void.
  (define-values (_tr _toks) (translate-something! c (user-principal c uid tid)))
  (values oid j))

;; ---- 1. the control: with encryption OFF the needle IS there ---------------------
;; This is what makes the next case mean anything. A scan that cannot find the
;; needle when it is definitely present would pass the encryption case while
;; proving nothing — the shape of mistake this whole file exists to avoid.
(test-case "CONTROL: with encryption off, the scanner finds the fixture text"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice"))
  (define-values (oid j) (do-work! c uid tid))
  (define hits (scan-for c NEEDLE))
  (check-true (> (length hits) 0)
              "the scanner must be able to FIND the needle, or the next case proves nothing")
  ;; and it should be in the places we expect, which documents where the text lives
  (check-true (and (member "repo_text.content" hits) #t) (format "hits: ~a" hits))
  (check-true (and (member "jobs.payload" hits) #t) (format "hits: ~a" hits))
  (printf "  (control) the needle is in: ~a\n" (sort hits string<?))
  (close-db! c))

;; ---- 2. the acceptance criterion ------------------------------------------------
(test-case "ACCEPTANCE: with encryption on, no column anywhere holds the fixture text"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice"))
  (with-env "TELEMACHUS_SECRET_KEY" (make-string 64 #\e)
    (lambda ()
      (with-env "TELEMACHUS_ENCRYPT_CONTENT" "1"
        (lambda ()
          (define-values (oid j) (do-work! c uid tid))
          (define hits (scan-for c NEEDLE))
          (check-equal? hits '()
                        (format "a dump would still carry the fixture text in: ~a"
                                (sort hits string<?)))))))
  (close-db! c))

;; ---- 3. the boundary of what case 2 proves --------------------------------------
;; A scan can only find a leak in a table the fixture WROTE TO. `do-work!` seals
;; what it touches — `repo_text` and `jobs` — and never runs a workflow, so case 2
;; passing does NOT mean a dump of a working instance carries no document text.
;;
;; `workflow_runs.input` holds a run's bindings and `workflow_steps.input/output`
;; hold each step's — for the document pipeline that is the extracted fields and
;; the rendered form, i.e. derived content by #83 r1's wording. Those columns are
;; NOT sealed yet (slice 3; the trade is ENC-2's again, because
;; `object-processing` finds runs with a LIKE over `workflow_runs.input`).
;;
;; So this case asserts the gap rather than papering over it: the day slice 3
;; lands, it fails, and the assertion moves into case 2 where it belongs. A test
;; that quietly covered only the sealed tables would let "acceptance criterion
;; met" be claimed for a dump that still carries the text.
(test-case "a REAL workflow run leaves it only where a TOOL deliberately wrote it"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice"))
  (define p (user-principal c uid tid))
  (with-env "TELEMACHUS_SECRET_KEY" (make-string 64 #\f)
    (lambda ()
      (with-env "TELEMACHUS_ENCRYPT_CONTENT" "1"
        (lambda ()
          (define rid (run-a-workflow! c p))
          ;; FUNCTIONAL FIRST: the engine must still work with every binding
          ;; sealed. A run that failed would leave fewer columns written and the
          ;; scan below would pass for the wrong reason — the whole engine broken
          ;; is indistinguishable from the engine leaking nothing.
          (check-equal? (query-value c "SELECT status FROM workflow_runs WHERE id = ?" rid) "done"
                        "the run must COMPLETE with its bindings sealed")
          (check-equal? (query-value c "SELECT COUNT(*) FROM workflow_steps WHERE run_id = ? AND status = 'done'" rid) 1)

          (define hits (sort (scan-for c NEEDLE) string<?))
          (printf "  (workflow run) the needle is in: ~a\n" hits)
          ;; WHAT THIS PROVES, and the limit of #83's acceptance criterion.
          ;;
          ;; Every column the PLATFORM fills incidentally is sealed: the run's
          ;; input and output, each step's input and output, the cursor between
          ;; them. What is left is `notes.title` — and that is not a leak, it is
          ;; the workflow's PRODUCT. The probe runs `create_note`, so the text is
          ;; in the notes table because a workflow was told to put it there, in
          ;; the user-facing store the Notes tab reads and searches.
          ;;
          ;; So the criterion as literally written — "a dump contains no fixture
          ;; text" — is not achievable while any tool can write content anywhere:
          ;; sealing notes would mean a user cannot search their own notes, which
          ;; is ENC-2's trade applied to a far more visible capability. What IS
          ;; achievable, and is what this asserts, is that no column the platform
          ;; fills BY ITSELF retains the text.
          (check-equal? hits '("notes.title")
                        (string-append "expected only the note the workflow was told to write."
                                       " More means a platform-filled column is unsealed;"
                                       " fewer means notes stopped being written at all."))))))
  (close-db! c))

;; ---- 4. #83 r4: the FAILURE path, and the captured logs -------------------------
;; r4 is its own requirement — "error paths and logs must never include document
;; text or extracted fields; add a test that greps captured logs for fixture
;; content during failing jobs" — and the three cases above could not see it,
;; because every job they run SUCCEEDS. Nothing above ever wrote an `error`
;; column, so the scan walked four of them finding nothing and said so.
;;
;; The leak was real. `jobs.error` is `(exn-message e)` from an ARBITRARY handler,
;; and the messages this platform's own tools raise quote what they choked on by
;; design: the strict renderer names the placeholder, DWF-5's extraction names the
;; path, the knowledge-graph extractor refuses a snippet that is not a verbatim
;; substring of the text. #59 had already written down why — "a handler's message
;; can quote the input it choked on" is its reason for clearing `error` on a purge
;; — and the column was still plaintext until the row was purged, which for a
;; failed job may be never.
;;
;; The worst of the four was not a column at all: a failing TRIGGER copied the
;; message into `audit_log.meta`, the one table a retention sweep deliberately
;; never clears (DEL-7, the audit log IS the record). That copy outlived every
;; other, including the fire row #59 purges.
(define (fail-a-job! c uid tid)
  ;; a handler that raises QUOTING its input, which is what a real tool does
  (register-job-kind! "refuse-needle"
                      (lambda (conn p payload)
                        (error 'extract "could not read a total from: ~a"
                               (hash-ref payload 'prompt ""))))
  (define j (enqueue-job! c #:team tid #:user uid #:kind "refuse-needle"
                          #:payload (hasheq 'prompt (string-append "Invoice: " NEEDLE))))
  (void (process-one! c))
  j)

;; A failing workflow STEP, so `workflow_steps.error` and `workflow_runs.error`
;; are written too — three of the four error columns from one probe. The step
;; fails inside the engine, so the run's own message wraps the step's and the
;; content reaches both.
(define-tool refuse_needle_tool
  #:description "Refuse, quoting the text — what a strict tool really does"
  (text string #:description "the text to choke on"))

(register-tool! "refuse_needle_tool" refuse_needle_tool "notes:read"
  (lambda (conn p args)
    (error 'render "no value for {{total}} in: ~a" (hash-ref args 'text ""))))

(define-workflow leak-fail-probe
  #:description "Fail a step while quoting the input"
  #:input ([subject string])
  (step boom (tool refuse_needle_tool #:text (in subject)) #:end))

(define (fail-a-workflow! c p)
  (define d (flow-publish! c p leak-fail-probe))
  (define run (flow-run-start! c p d #:input (hasheq 'subject (string-append "Case: " NEEDLE))))
  (let loop ([n 0]) (when (and (< n 20) (process-one! c)) (loop (add1 n))))
  (hash-ref run 'id))

(define (failing-work! c uid tid)
  (define p (user-principal c uid tid))
  (define j (fail-a-job! c uid tid))
  (define rid (fail-a-workflow! c p))
  (values j rid))

;; CONTROL first, as case 1 is to case 2: a scan that could not find the needle
;; in a failure message would pass the sealed case while proving nothing. This
;; one also DOCUMENTS the four homes, so a future column shows up as a diff here
;; rather than as silence.
(test-case "CONTROL: with encryption off, a FAILING job leaves its input in the error columns"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice"))
  (define-values (j rid) (failing-work! c uid tid))
  (define hits (sort (scan-for c NEEDLE) string<?))
  (printf "  (control, failures) the needle is in: ~a\n" hits)
  (check-true (and (member "jobs.error" hits) #t)
              (format "a failing handler's message must be findable here: ~a" hits))
  (check-true (and (member "workflow_steps.error" hits) #t) (format "hits: ~a" hits))
  (check-true (and (member "workflow_runs.error" hits) #t) (format "hits: ~a" hits))
  (close-db! c))

(test-case "ACCEPTANCE (r4): a FAILING job leaves the text in no column and in no log"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice"))
  ;; LOGS TOO, which is the half a dump scan cannot see. Everything the failure
  ;; path writes to stdout or stderr is captured and searched: a message that is
  ;; sealed in the database and printed to the console is not protected, and a
  ;; container's logs are the copy most likely to be read by a person and shipped
  ;; to a third party.
  (define out (open-output-string))
  (define err (open-output-string))
  (with-env "TELEMACHUS_SECRET_KEY" (make-string 64 #\a)
    (lambda ()
      (with-env "TELEMACHUS_ENCRYPT_CONTENT" "1"
        (lambda ()
          (parameterize ([current-output-port out] [current-error-port err])
            (define-values (j rid) (failing-work! c uid tid))
            ;; FUNCTIONAL FIRST, as case 3 does: the failure must still be
            ;; RECORDED, or "no text anywhere" would pass for a build that
            ;; stopped recording failures at all — which is the same answer for
            ;; the opposite reason.
            (check-equal? (query-value c "SELECT status FROM jobs WHERE id = ?" j) "error")
            (check-equal? (query-value c "SELECT status FROM workflow_runs WHERE id = ?" rid) "error")
            ;; and it must still be READABLE by the person debugging it: the
            ;; message comes back through the projection, plaintext, needle and
            ;; all. Sealing a diagnostic into illegibility would be a different
            ;; bug wearing this one's clothes.
            (define job (get-job c j tid))
            (check-true (string? (hash-ref job 'error))
                        "the stored message must still be readable through the API")
            (check-true (string-contains? (hash-ref job 'error) NEEDLE)
                        "…and it must still say what it choked on"))))))
  (define hits (sort (scan-for c NEEDLE) string<?))
  (check-equal? hits '()
                (format "a dump would carry the failure's message in: ~a" hits))
  (define logged (string-append (get-output-string out) "\n" (get-output-string err)))
  (check-false (string-contains? logged NEEDLE)
               (string-append "the fixture text reached a log. Captured output:\n" logged))
  (close-db! c))
