#lang racket/base

;; test/org-interchange-tests.rkt — a note as a `.org` file (#246 slice 3),
;; decisions ORG-11 and ORG-12.
;;
;;   raco test test/org-interchange-tests.rkt
;;   DATABASE_URL="postgres://…" raco test test/org-interchange-tests.rkt
;;
;; THE ROUND TRIP IS THE PROPERTY A USER OF THIS CARES ABOUT, so it is asserted
;; BYTE-IDENTICAL over every body shape that could lose a character: one that
;; begins with a blank line, one with none at the end, one whose first line is
;; spaces, and one whose first line is a keyword this does not understand.

(require rackunit db-kit/portable racket/list racket/string
         db-kit/migrate
         "../domain/db/migrations.rkt"
         "db-fixture.rkt"
         "../domain/authz/authz.rkt"
         "../domain/notes/notes.rkt"
         "../domain/notes/note-tools.rkt"
         "../domain/notes/org-file.rkt")

(define (fresh) (define c (fresh-db #:migrate? #f)) (migrate! c all-migrations) c)
(define (setup)
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "root"))
  (values c (user-principal c uid tid) tid))

;; ---- ORG-11: compose and parse are one pair -------------------------------
(define BODIES
  (list "hello\n"
        "\nhello\n"                      ; begins with a blank line
        "hello"                          ; no trailing newline
        ""                               ; empty
        "* Heading\n\n- a\n- b\n"
        "   leading spaces\n"            ; which a trimmed blank test would eat
        "#+OPTIONS: toc:nil\nbody\n"     ; a keyword this does not understand
        "line1\n\n\nline4"))

(test-case "the body round-trips BYTE-IDENTICALLY, with and without tags"
  (for* ([b (in-list BODIES)] [tags (in-list (list '() '("levee 7" "q3")))])
    (define txt (org-compose "My Title" tags b))
    (define-values (t tg body) (org-parse txt))
    (check-equal? body b (format "body ~s with tags ~s" b tags))
    (check-equal? t "My Title")
    (check-equal? (or tg '()) tags)))

(test-case "a #+FILETAGS: line that is ABSENT is not a line saying 'no tags'"
  ;; 🔑 THE DISTINCTION THE WHOLE OF ORG-12 RESTS ON, and it is the one
  ;; `#:tags #f` vs `'()` already draws for the HTTP surface. Without it,
  ;; converting a tagged Markdown note to org would drop its entire tag set the
  ;; first time it was saved.
  (let-values ([(t tg b) (org-parse "#+TITLE: x\n\nbody\n")])
    (check-false tg "no line at all says nothing"))
  (let-values ([(t tg b) (org-parse "#+TITLE: x\n#+FILETAGS:\n\nbody\n")])
    (check-equal? tg '() "a line that is there and empty CLEARS them")))

(test-case "org's own `:` delimiter is what keeps a tag with a space whole"
  ;; org tags are `[A-Za-z0-9_@#%]+` with no spaces; a #245 tag may be `levee 7`.
  ;; Splitting on `:` round-trips one org's own grammar would not have allowed.
  (let-values ([(t tg b) (org-parse "#+FILETAGS: :levee 7:q3:\n\nx\n")])
    (check-equal? tg '("levee 7" "q3")))
  ;; …and a colon-free value is split on whitespace, because that is the form
  ;; that appears in files written elsewhere. This platform's own export always
  ;; writes the colons, so the ambiguity cannot arise from a round trip.
  (let-values ([(t tg b) (org-parse "#+FILETAGS: alpha beta\n\nx\n")])
    (check-equal? tg '("alpha" "beta"))))

(test-case "a whitespace-only line after the keywords is NOT the separator"
  ;; FOUND BY A CONTROL THAT DID NOT BITE. The separator test is `string=?` on
  ;; `""` rather than on a TRIMMED line, and with this platform's own export the
  ;; two are indistinguishable — the separator it writes is always exactly `""`
  ;; and always first. They differ only on a FOREIGN file, where a line of spaces
  ;; is content: a trimmed test eats it. So the case has to be a hand-written
  ;; file, which is exactly the thing an import exists for.
  (let-values ([(t tg b) (org-parse "#+TITLE: t\n   \nbody\n")])
    (check-equal? t "t")
    (check-equal? b "   \nbody\n" "the spaces are content and they survive")))

(test-case "a keyword this does not understand stays in the body"
  ;; ORG-4's honest failure: `#+OPTIONS:` and `#+STARTUP:` render as their own
  ;; text, and eating them silently on import would be worse. The scan consumes
  ;; only a LEADING run of the two keywords it knows.
  (let-values ([(t tg b) (org-parse "#+OPTIONS: x\n#+TITLE: t\nbody\n")])
    (check-false t "a title after an unknown keyword is not read")
    (check-equal? b "#+OPTIONS: x\n#+TITLE: t\nbody\n" "and NOTHING is lost")))

;; ---- ORG-11 through the domain --------------------------------------------
(test-case "a note exports as a file and imports back, body for body"
  (define-values (c p tid) (setup))
  (define body "* Levee 7\n\nsee [[Budget review]] and *this*\n")
  (define n (notes-create c p #:title "Levee notes" #:body body #:format "org"))
  (define-values (name text) (org-text-of c p (hash-ref n 'id)))
  (check-true (regexp-match? #px"^levee-notes-[0-9a-f]{8}\\.org$" name) name)
  (check-true (string-prefix? text "#+TITLE: Levee notes\n") text)
  (define back (notes-import c p text))
  (check-equal? (hash-ref back 'body) body "the body is byte for byte what it was")
  (check-equal? (hash-ref back 'title) "Levee notes")
  (check-equal? (hash-ref back 'format) "org")
  ;; and it is a SECOND note, not an update — an import is a create
  (check-equal? (length (notes-list c p)) 2)
  (close-db! c))

(test-case "the tags go out and come back through TAG-4's one home"
  ;; 🔑 THIS CASE USED TO PASS FOR THE WRONG REASON, and the e2e gate is what
  ;; found it. Its fixture's body carried a `#+FILETAGS:` line of its own, so the
  ;; composed one being DROPPED on import went unnoticed while `body-tags`
  ;; re-read the author's. The import strips the keyword block to keep ORG-11's
  ;; byte-identical body, so the line that carried the tags is gone by the time
  ;; the create runs — which is why `#:filetags` exists.
  ;;
  ;; The fixture therefore sets its tags the way a PERSON would, on a markdown
  ;; note, and converts: the body then has no keyword line at all, so nothing but
  ;; the export's own composition can carry the tags across.
  (define-values (c p tid) (setup))
  (define n0 (notes-create c p #:title "Tagged" #:body "the body\n" #:tags '("Levee 7" "  SURVEY ")))
  (check-equal? (hash-ref n0 'tags) '("levee 7" "survey")
                "normalized exactly as a typed tag is")
  (define n (notes-update c p (hash-ref n0 'id) #:format "org"))
  (check-equal? (hash-ref n 'tags) '("levee 7" "survey") "and the conversion kept them")
  (check-false (regexp-match? #rx"FILETAGS" (hash-ref n 'body))
               "the body carries no keyword line, so only the export can carry them")
  (define-values (name text) (org-text-of c p (hash-ref n 'id)))
  (define back (notes-import c p text))
  (check-equal? (hash-ref back 'tags) '("levee 7" "survey"))
  (check-equal? (hash-ref back 'body) "the body\n" "and the body is still byte for byte")
  (close-db! c))

(test-case "an imported file with NO #+FILETAGS: line imports untagged"
  ;; `#f` means the file asserted nothing, which leaves the note untagged rather
  ;; than clearing something — the same absent/present split the stored body uses
  (define-values (c p tid) (setup))
  (define n (notes-import c p "#+TITLE: bare\n\nbody\n"))
  (check-equal? (hash-ref n 'tags) '())
  (close-db! c))

(test-case "a malformed tag in an IMPORTED #+FILETAGS: refuses the import"
  ;; the same refusal the stored body gets, through the same `clean-filetags`
  (define-values (c p tid) (setup))
  (define long (make-string (add1 MAX-TAG-CHARS) #\a))
  (check-exn #px"#\\+FILETAGS:"
             (lambda () (notes-import c p (format "#+TITLE: t\n#+FILETAGS: :~a:\n\nx\n" long))))
  (check-equal? (length (notes-list c p)) 0)
  (close-db! c))

(test-case "a file with no #+TITLE: imports untitled rather than inventing one"
  (define-values (c p tid) (setup))
  (define n (notes-import c p "* A headline\n\nsome text\n"))
  (check-equal? (hash-ref n 'title) "")
  (check-equal? (hash-ref n 'body) "* A headline\n\nsome text\n")
  (close-db! c))

(test-case "every format is exportable, and a markdown body comes back as itself"
  ;; Refusing would make "give me this note as a file" depend on a declaration
  ;; that says nothing about whether somebody wants one.
  (define-values (c p tid) (setup))
  (define n (notes-create c p #:title "Plain" #:body "# md\n" #:tags '("x")))
  (define-values (name text) (org-text-of c p (hash-ref n 'id)))
  (check-true (string-contains? text "# md\n"))
  (check-true (string-contains? text "#+FILETAGS: :x:"))
  ;; …and importing it makes an ORG note whose body is Markdown, which is ORG-2's
  ;; readable mess rather than an error — and is reversible
  (define back (notes-import c p text))
  (check-equal? (hash-ref back 'body) "# md\n")
  (check-equal? (hash-ref back 'format) "org")
  (close-db! c))

(test-case "a filename is built from an allowlist, not escaped"
  ;; a title is somebody's own words and may carry a quote, a newline or a
  ;; semicolon, every one of which would break out of
  ;; `Content-Disposition: attachment; filename="…"`
  (define-values (c p tid) (setup))
  (define n (notes-create c p #:title "He said \"go\"; now\nwhat?" #:body "x"))
  (define-values (name text) (org-text-of c p (hash-ref n 'id)))
  (check-true (regexp-match? #px"^[a-z0-9-]+\\.org$" name) name)
  (check-false (regexp-match? #rx"[\";\n]" name) name)
  ;; a title with nothing usable in it still yields a name
  (define n2 (notes-create c p #:title "。、！" #:body "x"))
  (define-values (name2 _t2) (org-text-of c p (hash-ref n2 'id)))
  (check-true (string-prefix? name2 "note-") name2)
  (close-db! c))

(test-case "a miss is distinguishable from an empty file"
  (define-values (c p tid) (setup))
  (define-values (name text) (org-text-of c p "no-such-note"))
  (check-false name)
  (check-false text)
  (close-db! c))

(test-case "an import larger than the cap is refused by name"
  ;; the control plane drops an over-large body with NO RESPONSE AT ALL, which is
  ;; this tree's own documented trap, so the refusal sits well under that limit
  ;; and names the remedy
  (define-values (c p tid) (setup))
  (define big (make-string (add1 MAX-ORG-IMPORT-BYTES) #\x))
  (check-exn #px"at most" (lambda () (notes-import c p big)))
  (check-equal? (length (notes-list c p)) 0)
  (close-db! c))

;; ---- ORG-12: the body is the source of truth ------------------------------
(test-case "#+FILETAGS: is authoritative on every write"
  (define-values (c p tid) (setup))
  (define n (notes-create c p #:title "t" #:format "org" #:body "#+FILETAGS: :a:\n\nx\n"))
  (check-equal? (hash-ref n 'tags) '("a"))
  (define id (hash-ref n 'id))
  (check-equal? (hash-ref (notes-update c p id #:body "#+FILETAGS: :b:c:\n\nx\n") 'tags)
                '("b" "c") "editing the line edits the tags")
  (check-equal? (hash-ref (notes-update c p id #:body "#+FILETAGS:\n\nx\n") 'tags)
                '() "…and an empty line clears them")
  (check-equal? (hash-ref (notes-update c p id #:body "no keyword at all\n") 'tags)
                '() "a body with no line leaves what was there — which is now nothing")
  (close-db! c))

(test-case "converting a TAGGED markdown note to org keeps its tags"
  ;; 🔑 THE CASE THE ABSENT/PRESENT SPLIT EXISTS FOR. ORG-2 says a conversion
  ;; never rewrites the body, so a converted note has no `#+FILETAGS:` line — and
  ;; if an absent line meant "no tags" the conversion would silently destroy the
  ;; tag set somebody had built.
  (define-values (c p tid) (setup))
  (define n (notes-create c p #:title "md" #:body "# hi\n" #:tags '("levee 7" "q3")))
  (define id (hash-ref n 'id))
  (define as-org (notes-update c p id #:format "org"))
  (check-equal? (hash-ref as-org 'format) "org")
  (check-equal? (hash-ref as-org 'tags) '("levee 7" "q3") "nothing was lost")
  ;; and the author takes control by writing the line
  (check-equal? (hash-ref (notes-update c p id #:body "#+FILETAGS: :only this:\n\n# hi\n") 'tags)
                '("only this"))
  (close-db! c))

(test-case "a `tags` field against an org note is REFUSED BY NAME"
  (define-values (c p tid) (setup))
  (define id (hash-ref (notes-create c p #:title "o" #:format "org" #:body "x") 'id))
  ;; a list, and an EXPLICIT CLEAR too: `{"tags":[]}` is still `tags` in the
  ;; request, and honouring it would put a second home behind the body
  (check-exn #px"#\\+FILETAGS:" (lambda () (notes-update c p id #:tags '("a"))))
  (check-exn #px"#\\+FILETAGS:" (lambda () (notes-update c p id #:tags '())))
  ;; …and a request that converts TO org and sends tags in one breath is refused
  ;; rather than half-honoured — the EFFECTIVE format decides
  (define md (hash-ref (notes-create c p #:title "m" #:body "x") 'id))
  (check-exn #px"#\\+FILETAGS:"
             (lambda () (notes-update c p md #:format "org" #:tags '("a"))))
  (check-equal? (hash-ref (notes-get c p md) 'format) "markdown"
                "and the conversion in that same request did not land either")
  ;; converting AWAY from org makes them writable again
  (notes-update c p id #:format "markdown")
  (check-equal? (hash-ref (notes-update c p id #:tags '("fine now")) 'tags) '("fine now"))
  (close-db! c))

(test-case "notes-set-tags! refuses an org note, which is what stops #245's tool"
  (define-values (c p tid) (setup))
  (define id (hash-ref (notes-create c p #:title "o" #:format "org" #:body "x") 'id))
  (check-exn #px"#\\+FILETAGS:" (lambda () (notes-set-tags! c p id '("a"))))
  (check-exn #px"#\\+FILETAGS:" (lambda () (notes-set-tags! c p id '("a") #:mode 'add)))
  ;; THE REFUSAL IS REACHABLE ONE STEP EARLIER, which is what keeps the model
  ;; call from happening at all: `note_autotag` puts one between the read and the
  ;; write, so finding out at the write would charge the team for an answer
  ;; nothing could store.
  (check-exn #px"#\\+FILETAGS:" (lambda () (notes-tags-writable! c id)))
  (define md (hash-ref (notes-create c p #:title "m" #:body "x") 'id))
  (check-true (notes-tags-writable! c md))
  (close-db! c))

(test-case "the autotagger refuses an org note BEFORE it calls the model"
  ;; …and the control is the chat seam itself: if it is reached, the case fails.
  (define-values (c p tid) (setup))
  (define id (hash-ref (notes-create c p #:title "o" #:format "org" #:body "x") 'id))
  (define called 0)
  (check-exn #px"#\\+FILETAGS:"
             (lambda ()
               (note-autotag! c p id
                              #:chat (lambda (text #:system sys)
                                       (set! called (add1 called))
                                       (values "{\"tags\":[\"a\"]}" 10)))))
  (check-equal? called 0 "the model was never called")
  ;; the ledger is the second half of that: nothing was spent
  (check-equal? (query-value c "SELECT COUNT(*) FROM usage_ledger") 0)
  (close-db! c))

(test-case "a malformed tag in #+FILETAGS: refuses the write and names the keyword"
  (define-values (c p tid) (setup))
  (define long (make-string (add1 MAX-TAG-CHARS) #\a))
  (check-exn #px"#\\+FILETAGS:"
             (lambda () (notes-create c p #:title "t" #:format "org"
                                      #:body (format "#+FILETAGS: :~a:\n\nx\n" long))))
  (check-equal? (length (notes-list c p)) 0 "and the note is not left behind")
  (close-db! c))
