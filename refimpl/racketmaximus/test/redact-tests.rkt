#lang racket/base

;; #128 job 2: operator-facing variables are read through ONE accessor,
;; which tries TMACH_<name> and falls back to TELEMACHUS_<name>.
(require (only-in "../config.rkt" tmach-env))

;; test/redact-tests.rkt — issue #91 requirement 1: keeping identifiers out of a
;; model request (decisions RED-1…9).
;;   raco test test/redact-tests.rkt
;;
;; Three layers:
;;   1. the DETECTION, pure — the patterns, the priority between them, the token
;;      numbering, and the two refusals. A string in, a string out, no database.
;;   2. the row: that the map is sealed, that nothing but a reader of the source
;;      can open it, and that a dump does not carry the values.
;;   3. the requirement, through the real engine, against the issue's own fixture.

(require rackunit db-kit/portable db-kit/migrate
         racket/port racket/string racket/list racket/file
         json
         "../domain/db/migrations.rkt"
         "db-fixture.rkt"
         "../domain/authz/authz.rkt"
         "../domain/authz/secretbox.rkt"
         "../domain/repo/blobs.rkt"
         "../domain/repo/repo.rkt"
         "../domain/repo/redact.rkt"
         "../domain/repo/redactions.rkt"
         "../domain/repo/doc-tools.rkt"          ; registers the tool
         "../domain/agent/registry.rkt"
         "../domain/agent/tools.rkt"
         "../domain/sched/scheduler.rkt"
         "../domain/flow/run.rkt"
         (prefix-in pipeline: "../plugins/doc-pipeline/main.rkt"))

(define BLOB-ROOT (make-temporary-file "telemachus-redact-blobs-~a" 'directory))
(current-blob-root BLOB-ROOT)

(define (fresh) (define c (fresh-db #:migrate? #f)) (migrate! c all-migrations) c)

;; The issue's own acceptance fixture: "a fixture letter with names, a phone
;; number and a date of birth".
(define LETTER
  (string-append
   "Dear Ms Patel,\n\n"
   "Your claim 44719823 was received on 2026-10-14. We wrote to Arun Patel\n"
   "at arun.patel@example.com and tried to reach him on +44 20 7946 0958.\n"
   "His date of birth is 3 April 1981.\n"))

(define (up! conn p key text [ct "text/plain"])
  (repo-put! conn p #:key key #:port (open-input-bytes (string->bytes/utf-8 text))
             #:content-type ct #:filename key #:visibility "team"))

(define (redact! conn p obj #:detectors [ds #f] #:terms [terms '()])
  ((tool-handler (tool-by-name "doc_redact")) conn p
   (hash-set* (hasheq 'object (hash-ref obj 'id) 'terms terms)
              'detectors (or ds (remove "dictionary" DETECTORS)))))

;; ---- 1. the detection, pure --------------------------------------------------------
(test-case "the issue's fixture: the identifiers go, the prose stays"
  (define-values (red m counts)
    (redact LETTER #:detectors DETECTORS #:terms '("Patel" "Arun Patel")))
  ;; what the model would be shown
  (check-true (string-contains? red "Dear Ms <PERSON_1>,"))
  (check-true (string-contains? red "His date of birth is <DATE_2>."))
  (check-true (string-contains? red "received on <DATE_1>"))
  ;; and NONE of the values survive in it — asserted one at a time, because
  ;; "the redaction worked" is exactly the claim a single grep makes vacuously
  (for ([v (in-list '("Patel" "arun.patel@example.com" "+44 20 7946 0958"
                      "44719823" "2026-10-14" "3 April 1981"))])
    (check-false (string-contains? red v) (format "~a is still in the redacted text" v)))
  ;; the map is the way back, and it is complete
  (check-equal? (cdr (assoc "<EMAIL_1>" m)) "arun.patel@example.com")
  (check-equal? (cdr (assoc "<PHONE_1>" m)) "+44 20 7946 0958")
  (check-equal? (cdr (assoc "<DATE_2>" m)) "3 April 1981")
  (check-equal? (cdr (assoc "<ID_1>" m)) "44719823")
  ;; requirement 5: counts per detector, and the fixture has two dates
  (define rep (redaction-counts DETECTORS counts))
  (check-equal? (hash-ref rep 'date) 2)
  (check-equal? (hash-ref rep 'email) 1)
  (check-equal? (hash-ref rep 'phone) 1)
  (check-equal? (hash-ref rep 'id_number) 1))

(test-case "RED-3: the detector order is the PRIORITY, loosest last"
  ;; The defect this rule was written against, pinned. `phone` is a digit, then
  ;; seven to nineteen digits-and-separators, then a digit — which matches an ISO
  ;; date and an SSN exactly as many characters as their own patterns do. With
  ;; `phone` ranked first, as the first version of DETECTORS had it, both came
  ;; back as `<PHONE_n>`: the redaction was complete and the quality report was
  ;; wrong, about a letter whose dates requirement 5 exists to count.
  (define-values (red m _c)
    (redact "dob 2026-10-14 ssn 078-05-1120 tel +44 20 7946 0958" #:detectors DETECTORS))
  (check-equal? (cdr (assoc "<DATE_1>" m)) "2026-10-14")
  (check-equal? (cdr (assoc "<ID_1>" m)) "078-05-1120")
  (check-equal? (cdr (assoc "<PHONE_1>" m)) "+44 20 7946 0958")
  ;; and the ordering is the PLATFORM's, so naming the detectors the other way
  ;; round gives the same answer — a document redacted by two callers who asked
  ;; for the same work must not come back differently
  (define-values (_r2 m2 _c2)
    (redact "dob 2026-10-14 ssn 078-05-1120" #:detectors '("phone" "id_number" "date")))
  (check-equal? (cdr (assoc "<DATE_1>" m2)) "2026-10-14")
  (check-equal? (cdr (assoc "<ID_1>" m2)) "078-05-1120"))

(test-case "RED-3: the longest match wins where two begin at the same place"
  ;; TWO MATCHES MUST SHARE A START for this rule to be under test at all, and
  ;; the first version of this case used "account AB-1234567", where the two
  ;; patterns begin at different offsets — so the position sort settled it and
  ;; the length comparator never ran. The positive control is what said so:
  ;; inverting the comparison to prefer the SHORTEST match left all sixteen
  ;; cases passing.
  ;;
  ;; A caller naming both a person and their company is the ordinary way to get
  ;; here, and the shortest-match answer is visibly wrong: `<PERSON_1> Industries`
  ;; leaves the company name in the text that goes to the model.
  (define-values (red m _c)
    (redact "Patel Industries wrote to Patel." #:detectors '("dictionary")
            #:terms '("Patel" "Patel Industries")))
  (check-equal? red "<PERSON_1> wrote to <PERSON_2>.")
  (check-equal? (cdr (assoc "<PERSON_1>" m)) "Patel Industries")
  (check-equal? (cdr (assoc "<PERSON_2>" m)) "Patel")
  ;; and a span inside an accepted one is dropped rather than replaced twice
  (define-values (red2 m2 _c2) (redact "account AB-1234567 please" #:detectors DETECTORS))
  (check-equal? red2 "account <ID_1> please")
  (check-equal? (length m2) 1 "one span, not a prefix and a remainder"))

(test-case "RED-2: a token is stable within the document and the SAME value reuses it"
  ;; which is the whole reason a span becomes a token rather than a black box:
  ;; the model can see that one person appears three times.
  (define-values (red m _c)
    (redact "Patel wrote. Patel replied. Singh did not." #:detectors '("dictionary")
            #:terms '("Patel" "Singh")))
  (check-equal? red "<PERSON_1> wrote. <PERSON_1> replied. <PERSON_2> did not.")
  (check-equal? (length m) 2 "two people, two tokens, three replacements"))

(test-case "RED-2: and it is NOT stable across documents"
  ;; A token that meant the same person everywhere would be a pseudonym, and a
  ;; pseudonym is a join key: two redacted documents would tell their reader they
  ;; concern the same person, which is the disclosure this step exists to
  ;; prevent. The numbering is per document, in order of first appearance.
  (define-values (_r1 m1 _c1)
    (redact "Singh called." #:detectors '("dictionary") #:terms '("Patel" "Singh")))
  (define-values (_r2 m2 _c2)
    (redact "Patel called." #:detectors '("dictionary") #:terms '("Patel" "Singh")))
  (check-equal? (cdr (assoc "<PERSON_1>" m1)) "Singh")
  (check-equal? (cdr (assoc "<PERSON_1>" m2)) "Patel"
                "the same token means a different person in another document"))

(test-case "a dictionary term is a LITERAL, matched whole-word and case-insensitively"
  ;; RED-1: the caller supplies names, never patterns. A term with regexp
  ;; metacharacters in it is a term.
  (define-values (red m _c)
    (redact "Lee of Fleet Street. LEE again. a.b matched? a+b?"
            #:detectors '("dictionary") #:terms '("Lee" "a+b")))
  (check-true (string-contains? red "of Fleet Street") "a term is not matched inside a word")
  (check-equal? (cdr (assoc "<PERSON_1>" m)) "Lee")
  (check-true (string-contains? red "a.b matched?") "`a+b` is not a pattern…")
  ;; "Lee" and "LEE" are ONE person and share a token, because the dictionary's
  ;; value is the TERM the caller named rather than the case it was written in —
  ;; keyed on the matched text the model would be shown two people where the
  ;; caller named one, which the first version of this did.
  (check-equal? (length m) 2 "two terms, two tokens")
  (check-true (string-contains? red "<PERSON_1> again") "the upper-case one is the same person")
  (check-true (string-contains? red "<PERSON_2>?") "…and `a+b` is a literal, not a pattern"))

(test-case "RED-1: a detector the caller invents is refused by name"
  (check-false (detectors-problem '("email" "phone")))
  (define p (detectors-problem '("email" "ssn")))
  (check-true (string? p))
  (check-true (string-contains? p "unknown detector 'ssn'"))
  (check-true (string-contains? p "email, date, id_number, dictionary, phone")
              "the refusal lists what this build detects")
  ;; and the reason is stated, because "write your own pattern" is the obvious
  ;; next request and the answer is no
  (check-true (string-contains? p "rather than one the caller writes"))
  (check-true (string? (detectors-problem '())))
  (check-true (string? (detectors-problem '("email" "email"))))
  (check-true (string? (detectors-problem "email"))))

(test-case "RED-4: text already containing a token is refused, not escaped"
  (check-false (token-shaped? LETTER))
  (check-true (token-shaped? "see <PERSON_1> above"))
  (check-true (token-shaped? "<ID_12>"))
  (check-false (token-shaped? "<person_1>") "lower case is not a token")
  (check-false (token-shaped? "<PERSON>") "nor is a class with no number")
  ;; the redacted text IS token-shaped, which is what makes this check a
  ;; precondition rather than a postcondition
  (define-values (red _m _c) (redact "Patel" #:detectors '("dictionary") #:terms '("Patel")))
  (check-true (token-shaped? red)))

(test-case "a document with no identifiers redacts to itself, and says so"
  (define-values (red m counts) (redact "Thank you for your letter.\n" #:detectors DETECTORS))
  (check-equal? red "Thank you for your letter.\n")
  (check-equal? m '())
  ;; EVERY detector that ran gets a row, including a zero: a detector omitted
  ;; cannot be told from one nobody asked for, and those have opposite remedies
  (define rep (redaction-counts DETECTORS counts))
  (check-equal? (hash-count rep) (length DETECTORS))
  (for ([(k v) (in-hash rep)]) (check-equal? v 0)))

;; ---- 2. the row --------------------------------------------------------------------
(test-case "RED-5: the token map is SEALED whenever a key exists, content switch or not"
  ;; The column holds `<PERSON_1> -> Arun Patel` for every person in every
  ;; redacted document — a concordance of exactly the identifiers the step took
  ;; out of a model request. The content switch's documented default is OFF, so a
  ;; map gated on it would be stored in the clear on the ordinary instance, which
  ;; is a feature doing the opposite of its name.
  (define was-key (tmach-env "SECRET_KEY"))
  (define was-content (tmach-env "ENCRYPT_CONTENT"))
  (putenv "TMACH_SECRET_KEY" (make-string 64 #\a))
  (putenv "TMACH_ENCRYPT_CONTENT" "")        ; the documented default: OFF
  (dynamic-wind
   void
   (lambda ()
     (define conn (fresh))
     (define-values (uid tid) (bootstrap! conn #:username "alice"))
     (define alice (user-principal conn uid tid))
     (define o (up! conn alice "in/letter.txt" LETTER))
     (define r (redact! conn alice o #:detectors DETECTORS #:terms '("Patel" "Arun Patel")))
     ;; read the RAW column, the way a dump would
     (define raw (query-value conn "SELECT token_map FROM repo_redactions WHERE id = ?"
                              (hash-ref r 'redaction_id)))
     (check-true (string-prefix? raw "enc:v1:") "the stored map is ciphertext")
     (for ([v (in-list '("Patel" "arun.patel@example.com" "+44 20 7946 0958" "3 April 1981"))])
       (check-false (string-contains? raw v) (format "~a is in the raw column" v)))
     ;; and it still opens, in process
     (define-values (rec m) (redaction-get conn alice (hash-ref r 'redaction_id)))
     (check-equal? (cdr (assoc "<EMAIL_1>" m)) "arun.patel@example.com"))
   (lambda ()
     (putenv "TMACH_SECRET_KEY" (or was-key ""))
     (putenv "TMACH_ENCRYPT_CONTENT" (or was-content "")))))

(test-case "RED-6/RED-7: a map opens only for somebody who may read the document"
  (define conn (fresh))
  (define-values (uid tid) (bootstrap! conn #:username "alice"))
  (define alice (user-principal conn uid tid))
  (define bob-id (create-user! conn #:username "bob" #:password "pw"))
  (add-member! conn #:user bob-id #:team tid #:role "member")
  (define bob (user-principal conn bob-id tid))

  (define o (repo-put! conn alice #:key "in/private.txt"
                       #:port (open-input-bytes (string->bytes/utf-8 LETTER))
                       #:content-type "text/plain" #:filename "private.txt"
                       #:visibility "private"))
  (define r (redact! conn alice o))
  ;; alice may
  (define-values (rec m) (redaction-get conn alice (hash-ref r 'redaction_id)))
  (check-true (and rec #t))
  (check-true (pair? m))
  ;; bob may not, and the answer is the same shape as a miss — he is not told
  ;; that a redaction of a document he cannot see exists
  ;; a refusal and a miss are ONE answer: that somebody redacted a document bob
  ;; cannot see is itself something he should not learn, because it says the
  ;; document exists and that it had identifiers in it
  (define-values (rec-b m-b) (redaction-get conn bob (hash-ref r 'redaction_id)))
  (check-false rec-b)
  (check-false m-b)
  ;; nor does the listing leak it
  (check-equal? (redactions-for conn bob (hash-ref o 'id)) '())
  ;; a nonexistent id is a miss and not an error
  (define-values (rec2 m2) (redaction-get conn alice "no-such-redaction"))
  (check-false rec2)
  (check-false m2))

(test-case "RED-8: the redacted text is a DOCUMENT beside the source, and the row finds it"
  (define conn (fresh))
  (define-values (uid tid) (bootstrap! conn #:username "alice"))
  (define alice (user-principal conn uid tid))
  (define o (up! conn alice "in/letter.txt" LETTER))
  (define r (redact! conn alice o #:detectors DETECTORS #:terms '("Patel")))

  (define red-obj (repo-get conn alice "in/letter.txt.redacted.txt" #:by-key tid))
  (check-true (and red-obj #t) "it is beside the source, under the family key")
  ;; `repo-open` answers TWO values — the OBJECT and then the port, in that
  ;; order — and #f #f for a miss. Taking one value is "result arity mismatch",
  ;; and taking them the other way round hands `port->string` a hash; the first
  ;; run of this case made both mistakes in turn.
  (define-values (_meta port) (repo-open conn alice (hash-ref red-obj 'id)))
  (define text (port->string port))
  (check-true (string-contains? text "<PERSON_1>"))
  (check-false (string-contains? text "arun.patel@example.com")
               "the document a person can read is the redacted one")
  ;; the provenance row, so "where did this come from" is a click (DSH-5)
  (check-equal? (query-value conn (string-append "SELECT COUNT(*) FROM repo_derivations "
                                                 "WHERE object_id = ? AND source_object_id = ?")
                             (hash-ref red-obj 'id) (hash-ref o 'id))
                1)
  ;; and the record points back at it
  (define-values (rec _m) (redaction-get conn alice (hash-ref r 'redaction_id)))
  (check-equal? (hash-ref rec 'redacted_object_id) (hash-ref red-obj 'id))
  ;; requirement 5, read back later rather than only at the moment of redaction
  (define recs (redactions-for conn alice (hash-ref o 'id)))
  (check-equal? (length recs) 1)
  ;; TWO, with the single term "Patel": it matches on its own in "Ms Patel" and
  ;; again as a whole word inside "Arun Patel". Requirement 5's number is matches
  ;; and not distinct people — which is what a reviewer looking for
  ;; under-redaction wants, and is why the tool reports `replaced` beside it.
  (check-equal? (hash-ref (hash-ref (car recs) 'counts) 'dictionary) 2))

(test-case "the TOOL's result carries the tokens and never the values"
  ;; A tool result reaches a workflow step's stored output, the agent's
  ;; transcript and a console pane, which is three more copies than the sealed
  ;; row has. RED-6 says nothing serves the map; this is the same rule applied to
  ;; the thing that is served.
  (define conn (fresh))
  (define-values (uid tid) (bootstrap! conn #:username "alice"))
  (define alice (user-principal conn uid tid))
  (define o (up! conn alice "in/letter.txt" LETTER))
  (define r (redact! conn alice o #:detectors DETECTORS #:terms '("Patel" "Arun Patel")))
  (define rendered (jsexpr->string r))
  (check-true (string-contains? rendered "<EMAIL_1>") "the tokens are reported")
  (for ([v (in-list '("Patel" "arun.patel@example.com" "+44 20 7946 0958" "3 April 1981"))])
    (check-false (string-contains? rendered v) (format "~a is in the tool result" v)))
  (check-equal? (hash-ref r 'replaced) (length (hash-ref r 'tokens))))

(test-case "the refusals, through the tool"
  (define conn (fresh))
  (define-values (uid tid) (bootstrap! conn #:username "alice"))
  (define alice (user-principal conn uid tid))
  (define o (up! conn alice "in/letter.txt" LETTER))
  ;; RED-4, over a real document
  (define t (up! conn alice "in/tokened.txt" "see <PERSON_1> above\n"))
  (check-exn #rx"already contains text shaped like a redaction token"
             (lambda () (redact! conn alice t)))
  ;; the dictionary with no terms would report a letter full of names as having
  ;; none, which is the under-redaction requirement 5 exists to surface
  (check-exn #rx"would redact nothing"
             (lambda () (redact! conn alice o #:detectors '("dictionary"))))
  ;; a document whose text cannot be read is NOT an empty redaction: unlike
  ;; `doc_classify`, which classifies a photograph from its content type (CLS-9),
  ;; a redaction of nothing reads as safe to send
  (define photo (up! conn alice "in/scan.jpg" "not really a jpeg" "image/jpeg"))
  (check-exn exn:fail? (lambda () (redact! conn alice photo))))

(test-case "RED-9: the caller's own TERMS are run input, and that is a stated limit"
  ;; Not a leak and not an oversight: a workflow stores every run's input, and
  ;; `GET /api/runs/:id` hands it back to anybody with `workflows:read`. So the
  ;; names somebody asked to have redacted are visible to their colleagues. This
  ;; case exists so the assertions above — which prove the OUTPUT carries no
  ;; values — cannot be read as "nothing anywhere carries them".
  (define conn (fresh))
  (define-values (uid tid) (bootstrap! conn #:username "alice"))
  (define alice (user-principal conn uid tid))
  (register-plugin-workflow!
   "doc-pipeline"
   (findf (lambda (w) (equal? (hash-ref w 'slug) "redact-document")) pipeline:workflows))
  (define def (flow-def-by-slug conn alice "redact-document"))
  (define o (up! conn alice "in/letter.txt" LETTER))
  (define run (flow-run-start! conn alice def
                               #:input (hasheq 'object_id (hash-ref o 'id)
                                               'detectors '("dictionary") 'terms '("Arun Patel"))))
  (let loop ([n 0]) (when (and (< n 20) (process-one! conn)) (loop (add1 n))))
  (define r (flow-run-get conn alice (hash-ref run 'id)))
  (check-equal? (hash-ref r 'status) "done")
  (check-equal? (hash-ref (hash-ref r 'input) 'terms) '("Arun Patel")
                "the run reports the configuration it was given")
  ;; while the step's own output still carries no value at all
  (define out (hash-ref (hash-ref (findf (lambda (s) (equal? (hash-ref s 'step_id) "redact"))
                                         (hash-ref r 'steps))
                                  'output)
                        'result))
  (check-false (string-contains? (jsexpr->string out) "Arun Patel")))

;; ---- requirement 2: the step that redacts before it asks ---------------------------
(test-case "RED-10: rehydration is ONE pass, so <PERSON_1> does not corrupt <PERSON_11>"
  ;; The obvious implementation walks the map calling `string-replace` per pair,
  ;; and it is wrong as soon as a document has ten of anything: replacing
  ;; `<PERSON_1>` first rewrites the first eight characters of `<PERSON_11>`.
  (define m (for/list ([i (in-range 1 13)])
              (cons (format "<PERSON_~a>" i) (format "Person~a" i))))
  (define-values (out unknown)
    (rehydrate-string "<PERSON_11> wrote to <PERSON_1> about <PERSON_2>." m))
  (check-equal? out "Person11 wrote to Person1 about Person2.")
  (check-equal? unknown '())
  ;; and a VALUE that is itself token-shaped is not rewritten by a later pass —
  ;; the single pass cannot revisit what it has already emitted
  (define-values (out2 _u2)
    (rehydrate-string "<ID_1> and <ID_2>" (list (cons "<ID_1>" "<ID_2>") (cons "<ID_2>" "real"))))
  (check-equal? out2 "<ID_2> and real"))

(test-case "RED-11: a token the model invented is left verbatim and REPORTED"
  ;; Guessing the nearest token would put a real person's name in an answer about
  ;; somebody never mentioned; failing the step would throw away a whole
  ;; extraction over one hallucinated string in a rationale. Left as it is, it is
  ;; visibly wrong to the person reading the field.
  (define m (list (cons "<PERSON_1>" "Arun Patel")))
  (define-values (out unknown)
    (rehydrate-string "<PERSON_1> and <PERSON_7> and <PERSON_7> again" m))
  (check-equal? out "Arun Patel and <PERSON_7> and <PERSON_7> again")
  (check-equal? unknown '("<PERSON_7>") "reported once, not once per occurrence"))

(test-case "rehydration walks a whole jsexpr: every string VALUE, recursively"
  (define m (list (cons "<PERSON_1>" "Arun Patel") (cons "<ID_1>" "44719823")))
  (define-values (out unknown)
    (rehydrate (hasheq 'vendor "<PERSON_1>"
                       'total 1250.5
                       'items (list (hasheq 'ref "<ID_1>") (hasheq 'ref "<ID_9>"))
                       'note 'null)
               m))
  (check-equal? (hash-ref out 'vendor) "Arun Patel")
  (check-equal? (hash-ref out 'total) 1250.5 "a number is untouched")
  (check-equal? (hash-ref out 'note) 'null "and so is null")
  (check-equal? (hash-ref (second (hash-ref out 'items)) 'ref) "<ID_9>")
  (check-equal? unknown '("<ID_9>")))

(test-case "ACCEPTANCE (#91): the stub receives only tokens, the stored extraction has the values"
  ;; The issue's own acceptance criterion, word for word: "A fixture letter with
  ;; names, a phone number and a date of birth is sent to a stub executor; the
  ;; stub receives only tokens, and the stored extraction contains the real
  ;; values."
  (define conn (fresh))
  (define-values (uid tid) (bootstrap! conn #:username "alice"))
  (define alice (user-principal conn uid tid))
  (define o (up! conn alice "in/letter.txt" LETTER))
  (define seen (box #f))
  ;; the stub answers with the TOKENS it was shown, which is what a model
  ;; reasoning over redacted text would do
  (define stub
    (lambda (prompt #:system [sys #f])
      (set-box! seen prompt)
      (values (jsexpr->string (hasheq 'who "<PERSON_2>" 'phone "<PHONE_1>" 'dob "<DATE_2>")) 9)))
  (define schema
    (hasheq 'type "object" 'required '("who" "phone" "dob")
            'properties (hasheq 'who (hasheq 'type "string")
                                'phone (hasheq 'type "string")
                                'dob (hasheq 'type "string"))))
  (define r
    (parameterize ([current-doc-chat stub])
      ((tool-handler (tool-by-name "doc_extract_fields")) conn alice
       (hasheq 'text LETTER 'schema schema 'object (hash-ref o 'id)
               'redact #t 'redact_detectors DETECTORS
               'redact_terms '("Patel" "Arun Patel")))))

  ;; 1. THE STUB RECEIVED ONLY TOKENS
  (define sent (unbox seen))
  (check-true (string-contains? sent "<PERSON_1>") "the prompt was built from redacted text")
  (for ([v (in-list '("Patel" "arun.patel@example.com" "+44 20 7946 0958" "44719823" "3 April 1981"))])
    (check-false (string-contains? sent v) (format "~a reached the model" v)))

  ;; 2. THE STORED EXTRACTION CONTAINS THE REAL VALUES
  (define fields (hash-ref r 'fields))
  (check-equal? (hash-ref fields 'who) "Arun Patel")
  (check-equal? (hash-ref fields 'phone) "+44 20 7946 0958")
  (check-equal? (hash-ref fields 'dob) "3 April 1981")
  ;; …and so does the DOCUMENT, which is what a later step binds
  (define-values (_m port) (repo-open conn alice
                                      (hash-ref (repo-get conn alice "in/letter.txt.extracted.json"
                                                          #:by-key tid)
                                                'id)))
  (define stored (string->jsexpr (port->string port)))
  (check-equal? (hash-ref stored 'who) "Arun Patel")
  (check-false (string-contains? (jsexpr->string stored) "<PERSON_")
               "no token survives into the stored fields")

  ;; 3. the record says redaction was applied and which detectors ran (req 2)
  (define red (hash-ref r 'redaction))
  (check-true (hash-ref red 'applied))
  (check-equal? (hash-ref red 'detectors) DETECTORS)
  (check-equal? (hash-ref (hash-ref red 'counts) 'phone) 1)
  (check-false (hash-has-key? red 'unknown_tokens) "the model answered with nothing invented")

  ;; 4. RED-12: AND NO MAP WAS PERSISTED. The step redacts and rehydrates within
  ;; one call, so a stored map would be a concordance of identifiers kept for no
  ;; reader at all — where `doc_redact` stores one because its output is a
  ;; document something later may rehydrate against.
  (check-equal? (query-value conn "SELECT COUNT(*) FROM repo_redactions") 0))

(test-case "req 2: redaction is OFF unless asked, and then the record says so"
  (define conn (fresh))
  (define-values (uid tid) (bootstrap! conn #:username "alice"))
  (define alice (user-principal conn uid tid))
  (define seen (box #f))
  (define stub (lambda (prompt #:system [sys #f])
                 (set-box! seen prompt)
                 (values (jsexpr->string (hasheq 'who "Arun Patel")) 4)))
  (define schema (hasheq 'type "object" 'required '("who")
                         'properties (hasheq 'who (hasheq 'type "string"))))
  (define r (parameterize ([current-doc-chat stub])
              ((tool-handler (tool-by-name "doc_extract_fields")) conn alice
               (hasheq 'text LETTER 'schema schema))))
  (check-true (string-contains? (unbox seen) "Arun Patel")
              "without `redact` the prompt is the text as given — nothing changed for anybody")
  (check-false (hash-ref (hash-ref r 'redaction) 'applied)))

(test-case "req 2: doc_classify redacts for the MODEL and matches rules on the real text"
  ;; The one place requirement 2 cannot simply swap the input. A rule is
  ;; deterministic, local and never leaves the process, so matching it on tokens
  ;; buys nothing and costs correctness — here the rule keys on a phrase that
  ;; survives redaction, and the model gets the redacted text.
  (define conn (fresh))
  (define-values (uid tid) (bootstrap! conn #:username "alice"))
  (define alice (user-principal conn uid tid))
  (define o (up! conn alice "in/letter.txt" LETTER))
  (define seen (box #f))
  (define stub (lambda (prompt #:system [sys #f])
                 (set-box! seen prompt)
                 ;; `<EMAIL_1>` was minted here; `<PERSON_3>` was not — the
                 ;; detectors asked for are email and phone — so the pair tests
                 ;; both halves of RED-11 in one answer
                 (values (jsexpr->string (hasheq 'label "letter" 'confidence 0.7
                                                 'rationale "addressed to <EMAIL_1>, cc <PERSON_3>"))
                         6)))
  (define LBL (list (hasheq 'name "letter") (hasheq 'name "invoice")))
  (define r (parameterize ([current-doc-chat stub])
              ((tool-handler (tool-by-name "doc_classify")) conn alice
               (hasheq 'object (hash-ref o 'id) 'labels LBL 'backends '("llm")
                       'redact #t 'redact_detectors '("email" "phone")))))
  (check-equal? (hash-ref r 'label) "letter")
  (check-false (string-contains? (unbox seen) "arun.patel@example.com") "the model saw tokens")
  ;; the RATIONALE is the only part of a classification that can carry one, and it
  ;; is put back — the label is held to the set by an enum, so a token there is
  ;; refused before it ever reaches the rehydration
  (check-equal? (hash-ref r 'rationale)
                "addressed to arun.patel@example.com, cc <PERSON_3>")
  (check-true (hash-ref (hash-ref r 'redaction) 'applied))
  ;; the invented one is REPORTED rather than guessed at or swallowed
  (check-equal? (hash-ref (hash-ref r 'redaction) 'unknown_tokens) '("<PERSON_3>"))

  ;; …and with a RULES-only chain nothing is redacted, because no model saw it:
  ;; reporting `applied: true` there would claim a protection that was not needed
  (define r2 (parameterize ([current-doc-chat (lambda (p #:system [s #f]) (error 'test "asked"))])
               ((tool-handler (tool-by-name "doc_classify")) conn alice
                (hasheq 'object (hash-ref o 'id) 'labels LBL 'backends '("rules")
                        'rules (list (hasheq 'label "letter" 'any '("Dear")))
                        'redact #t))))
  (check-equal? (hash-ref r2 'label) "letter")
  (check-false (hash-ref (hash-ref r2 'redaction) 'applied)))

(test-case "req 2: a RULE still matches what redaction would have destroyed"
  ;; The sharp version of the rule/model split, and the positive control is what
  ;; asked for it: with the rules matched on the redacted text instead, this case
  ;; passed either way. The rule here keys on the claim number — which the
  ;; `id_number` detector replaces — so matching it on tokens finds nothing and
  ;; the chain falls through to a model that must never be reached.
  (define conn (fresh))
  (define-values (uid tid) (bootstrap! conn #:username "alice"))
  (define alice (user-principal conn uid tid))
  (define o (up! conn alice "in/letter.txt" LETTER))
  (define LBL (list (hasheq 'name "claim") (hasheq 'name "letter")))
  (define r (parameterize ([current-doc-chat
                            (lambda (p #:system [s #f])
                              (error 'test "the model was asked, so the rule did not match"))])
              ((tool-handler (tool-by-name "doc_classify")) conn alice
               (hasheq 'object (hash-ref o 'id) 'labels LBL
                       'backends '("rules" "llm")
                       'rules (list (hasheq 'label "claim" 'any '("44719823")))
                       'redact #t 'redact_detectors DETECTORS
                       'redact_terms '("Patel")))))
  (check-equal? (hash-ref r 'label) "claim"
                "the rule saw the real text, as it must — it is local and never leaves the process")
  (check-equal? (hash-ref r 'source) "rules"))

(test-case "req 2: the values go back BEFORE the schema is applied"
  ;; The schema is the CALLER's and describes real values, so validating the
  ;; model's token-bearing object against it would refuse the extraction and the
  ;; refusal would quote the token. This case is also what the control asked for:
  ;; with the two swapped, nothing else in the file noticed.
  (define conn (fresh))
  (define-values (uid tid) (bootstrap! conn #:username "alice"))
  (define alice (user-principal conn uid tid))
  ;; `+44 20 7946 0958` satisfies this; `<PHONE_1>` cannot
  (define schema
    (hasheq 'type "object" 'required '("phone")
            'properties (hasheq 'phone (hasheq 'type "string" 'pattern "^[+][0-9 ]+$"))))
  (define r (parameterize ([current-doc-chat
                            (lambda (p #:system [s #f])
                              (values (jsexpr->string (hasheq 'phone "<PHONE_1>")) 3))])
              ((tool-handler (tool-by-name "doc_extract_fields")) conn alice
               ;; a one-line `text` rather than the whole letter, so this case is
               ;; about the ORDER and nothing else: with `phone` as the only
               ;; detector the letter's ISO date is also a phone match (RED-3 is
               ;; what settles that when `date` is asked for too), so `<PHONE_1>`
               ;; there is `2026-10-14` and the case would fail for an unrelated
               ;; and much more interesting reason.
               (hasheq 'text "ring +44 20 7946 0958 today" 'schema schema 'redact #t
                       'redact_detectors '("phone")))))
  (check-equal? (hash-ref (hash-ref r 'fields) 'phone) "+44 20 7946 0958"))

(test-case "req 2: doc_translate rehydrates the DOCUMENT and leaves the row redacted"
  (define conn (fresh))
  (define-values (uid tid) (bootstrap! conn #:username "alice"))
  (define alice (user-principal conn uid tid))
  (define o (up! conn alice "in/letter.txt" LETTER))
  (define seen (box #f))
  (define stub (lambda (prompt #:system [sys #f])
                 (set-box! seen prompt)
                 (values (string-append "[ja] " prompt) 12)))
  (define r (parameterize ([current-doc-chat stub])
              ((tool-handler (tool-by-name "doc_translate")) conn alice
               (hasheq 'object (hash-ref o 'id) 'locale "ja"
                       'redact #t 'redact_detectors DETECTORS
                       'redact_terms '("Arun Patel")))))
  (check-false (string-contains? (unbox seen) "arun.patel@example.com") "the model saw tokens")
  ;; the DOCUMENT is the rehydrated translation, which is what a reader wants
  (define-values (_m port) (repo-open conn alice (hash-ref r 'object_id)))
  (define text (port->string port))
  (check-true (string-contains? text "arun.patel@example.com"))
  (check-false (string-contains? text "<EMAIL_1>"))
  ;; while `translations.source_text` holds what CROSSED THE WIRE — strictly less
  ;; content at rest than before, and the honest record of the request
  (define stored (query-value conn "SELECT source_text FROM translations LIMIT 1"))
  (check-true (string-contains? stored "<EMAIL_1>"))
  (check-false (string-contains? stored "arun.patel@example.com")))

(test-case "req 2: the refusals, and that redaction never silently does nothing"
  (define conn (fresh))
  (define-values (uid tid) (bootstrap! conn #:username "alice"))
  (define alice (user-principal conn uid tid))
  (define schema (hasheq 'type "object" 'properties (hasheq 'a (hasheq 'type "string"))))
  (define stub (lambda (p #:system [s #f]) (values "{}" 1)))
  (define (extract! args)
    (parameterize ([current-doc-chat stub])
      ((tool-handler (tool-by-name "doc_extract_fields")) conn alice
       (hash-set* args 'schema schema))))
  ;; an invented detector
  (check-exn #rx"unknown detector 'ssn'"
             (lambda () (extract! (hasheq 'text "hi" 'redact #t 'redact_detectors '("ssn")))))
  ;; the dictionary with no terms
  (check-exn #rx"would redact nothing"
             (lambda () (extract! (hasheq 'text "hi" 'redact #t 'redact_detectors '("dictionary")))))
  ;; RED-4, and here it matters MORE than for doc_redact: a token the text already
  ;; held would be put back as somebody's name, into a field stored as data
  (check-exn #rx"already contains something shaped like a redaction token"
             (lambda () (extract! (hasheq 'text "see <PERSON_1>" 'redact #t)))))

;; ---- 3. the requirement, through the real engine ------------------------------------
(test-case "requirement 1, end to end: the document a model would be shown"
  (define conn (fresh))
  (define-values (uid tid) (bootstrap! conn #:username "alice"))
  (define alice (user-principal conn uid tid))
  (register-plugin-workflow!
   "doc-pipeline"
   (findf (lambda (w) (equal? (hash-ref w 'slug) "redact-document")) pipeline:workflows))
  (define def (flow-def-by-slug conn alice "redact-document"))
  (check-true (and def #t) "the plugin workflow materialized")

  (define o (up! conn alice "in/letter.txt" LETTER))
  (define run (flow-run-start! conn alice def
                               #:input (hasheq 'object_id (hash-ref o 'id)
                                               'detectors DETECTORS
                                               'terms '("Patel" "Arun Patel"))))
  (let loop ([n 0]) (when (and (< n 20) (process-one! conn)) (loop (add1 n))))
  (define r (flow-run-get conn alice (hash-ref run 'id)))
  (check-equal? (hash-ref r 'status) "done"
                (format "the redaction finished (error: ~a)" (hash-ref r 'error)))
  (define out (hash-ref (hash-ref (findf (lambda (s) (equal? (hash-ref s 'step_id) "redact"))
                                         (hash-ref r 'steps))
                                  'output)
                        'result))
  ;; two terms and five patterns: Patel, Arun Patel, the claim number, the two
  ;; dates, the email and the telephone number
  (check-equal? (hash-ref out 'replaced) 7)
  ;; two dictionary hits, not three: the fixture names Patel twice, and the
  ;; second of those is the longer term `Arun Patel`
  (check-equal? (hash-ref (hash-ref out 'counts) 'dictionary) 2)
  ;; AND THE RUN'S OWN STORED OUTPUT CARRIES NO VALUES. The step output is a row
  ;; in `workflow_steps`, sealed only when the content switch is on — so a run
  ;; that echoed the map would undo the sealing one table along.
  (define raw (query-value conn "SELECT output FROM workflow_steps WHERE run_id = ? AND step_id = 'redact'"
                           (hash-ref run 'id)))
  (for ([v (in-list '("arun.patel@example.com" "+44 20 7946 0958" "3 April 1981"))])
    (check-false (string-contains? (format "~a" raw) v)
                 (format "~a is in the stored step output" v))))
