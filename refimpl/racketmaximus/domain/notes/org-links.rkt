#lang racket/base

;; domain/notes/org-links.rkt — org link syntax, read out of a body (#246 slice 2).
;;
;; NO DEPENDENCIES, ON PURPOSE, which is `keyparts.rkt`'s own shape: the fold
;; below has two askers — a link target and a #245 tag are both human-typed
;; strings matched case- and whitespace-insensitively — and the one that may not
;; require `notes.rkt` is this one, because `notes.rkt` requires it.
;;
;; THERE ARE TWO PARSERS FOR ONE SYNTAX AND THERE HAVE TO BE. `orgRender` in
;; `static/console/15-editor.js` draws the link and this reads the edge out of
;; the body, and they are in different languages, so they cannot share an
;; implementation — `repo-readable?`'s situation exactly ("a page already
;; authorized in Racket and a SQL window cannot share an implementation; the note
;; at the definition is what keeps it one rule"). What must agree is WHICH
;; targets are internal, i.e. the external-scheme set, and that is why
;; `EXTERNAL-TARGET` carries the pointer to `MD_SCHEMES` and why
;; `test/note-links-tests.rkt` pins the same inputs the e2e gate's §3c2 block
;; hands the renderer.

(require racket/list racket/string)

(provide fold-key org-link-targets md-link-targets link-targets
         typed-target SOURCE-KINDS
         EXTERNAL-TARGET external-target? MAX-NOTE-LINKS)

;; ONE RULE, TWO ASKERS. TAG-3 argued it for a tag: downcase and collapse
;; whitespace, which is the knowledge graph's dedup rule minus its
;; company-suffix list. A link target is the same question — somebody types
;; `[[Levee 7 Survey]]` for a note called `Levee 7 survey` — so `tag-normalize`
;; delegates here rather than this being a second copy of it. Case is the whole
;; of what is lost, and no language this console ships has a case distinction
;; that carries meaning in a title.
;;
;; `string-split` with no separator splits on whitespace AND drops the empties,
;; so this collapses internal runs and trims in one pass.
(define (fold-key s)
  (string-downcase (string-join (string-split (format "~a" s)) " ")))

;; ORG-6 — AN EXTERNAL TARGET CREATES NO EDGE, so it never reaches the table.
;; The graph is the team's own notes, and an external URL already has a home that
;; archives it (a bookmark, #191 slice 1). That narrowing is what keeps the entire
;; edge set inside one authorization domain.
;;
;; THE SET IS `MD_SCHEMES`' SET, and it is the one thing that must agree with the
;; renderer: there, these are what `mdSafeUrl` admits as an anchor, so a target
;; this considered internal and the renderer drew as an anchor — or the other way
;; round — would be an edge nobody can see or a link nobody can follow.
(define EXTERNAL-TARGET #px"^(?i:https?://|mailto:|/|#)")
(define (external-target? t) (regexp-match? EXTERNAL-TARGET t))

;; A note carries at most this many DISTINCT link targets, refused by name past
;; it — `tags-clean`'s call at a second asker. A silent drop is an edge that
;; never appears in a graph with nothing saying why, which is the hardest thing
;; on this surface to diagnose; the cost is that a note with 500 distinct wiki
;; links cannot be saved, and slice 3's import of somebody's real org files is
;; the thing most likely to meet it.
(define MAX-NOTE-LINKS 500)

;; `[[target][description]]` and `[[target]]`. Neither part may contain a bracket
;; or a newline, which is org's own rule and is what stops a run of links on one
;; line from being read as a single enormous target.
(define LINK-RX #px"\\[\\[([^][\n]+)\\](?:\\[([^][\n]*)\\])?\\]")

;; Answers `((raw-target fold label) ...)` in the order they appear, EXTERNAL
;; TARGETS DROPPED and DEDUPED BY FOLD keeping the first occurrence.
;;
;; DEDUPED, because an edge is a relation between two notes and two mentions of
;; it are one relation — which also bounds the row count by distinct targets
;; rather than by how often somebody repeated themselves. The FIRST label is the
;; one kept, because it is the one at the top of the note. What is given up,
;; stated: "how many times does this note mention that one" is not a question
;; this table can answer, and nobody has asked it.
(define (org-link-targets body)
  (collect-targets
   (for/list ([m (in-list (regexp-match* LINK-RX (format "~a" body) #:match-select values))])
     (cons (cadr m) (caddr m)))))

;; ---- a link to a SOURCE (#191) ----------------------------------------------
;;
;; A note may point at the document or the bookmark it was written from:
;; `doc:<object id or key>` and `bookmark:<bookmark id or URL>`. The prefix is
;; what makes the target a different KIND of thing, so it is decided here, in
;; the syntax, and never guessed from what the rest happens to match — a title
;; that looks like a key would otherwise change meaning the day somebody uploads
;; a file of that name.
;;
;; The cost, stated: a note whose TITLE begins `doc:` or `bookmark:` can no
;; longer be linked by title. Link it by id.
;;
;; Answers `(cons kind rest)` or #f. `SOURCE-KINDS` is the closed set the
;; console switches on.
(define SOURCE-KINDS '("document" "bookmark"))
(define TYPED-RX #px"^(?i:(doc|bookmark)):\\s*(.+)$")
(define (typed-target raw)
  (define m (regexp-match TYPED-RX (string-trim (format "~a" raw))))
  (and m
       (let ([rest (string-trim (caddr m))])
         (and (not (string=? rest ""))
              (cons (if (string=? (string-downcase (cadr m)) "doc") "document" "bookmark")
                    rest)))))

;; THE FOLD OF A SOURCE TARGET KEEPS ITS CASE. A repository key and a URL path
;; are both case-sensitive, so folding `doc:Reports/A.md` and `doc:reports/a.md`
;; together would dedup two different documents into one edge. Only the prefix
;; is normalized.
(define (target-fold raw)
  (define ty (typed-target raw))
  (if ty
      (string-append (if (string=? (car ty) "document") "doc:" "bookmark:") (cdr ty))
      (fold-key raw)))

;; `pairs` is `((raw . label-or-#f) ...)` in body order. Answers
;; `((raw-target fold label) ...)`, external targets dropped and deduped by fold
;; keeping the first — one rule for both syntaxes.
(define (collect-targets pairs)
  (define seen (make-hash))
  (for/fold ([out '()] #:result (reverse out))
            ([pr (in-list pairs)])
    (define raw (string-trim (car pr)))
    (define label (let ([l (cdr pr)]) (if l (string-trim l) "")))
    (define fold (target-fold raw))
    (cond [(string=? (fold-key raw) "") out]
          [(external-target? raw) out]
          [(hash-ref seen fold #f) out]
          [else (hash-set! seen fold #t) (cons (list raw fold label) out)])))

;; ---- Markdown wiki-links (#191) ---------------------------------------------
;;
;; `[[target]]` and `[[target|label]]`, which is what Obsidian users already
;; write. The pipe form rather than org's `[[target][label]]` because that is
;; the Markdown convention. Converting a note between formats keeps a bare
;; `[[target]]`; the labelled form of the other syntax stops resolving and is
;; reported as a broken link, which is visible and is undone by converting back.
;;
;; CODE IS REMOVED FIRST, fenced blocks and then inline spans, for the reason the
;; renderer lifts them out before any inline rule runs: `[[x]]` inside a code
;; block is text about a link, not a link. The fence pattern is `mdRender`'s own.
;; The patterns use real newlines; `pregexp` has no escape for one.
(define MD-FENCE-RX #px"```[^\n]*\n.*?```")
(define MD-CODE-RX #px"`[^`\n]+`")
(define MD-LINK-RX #px"\\[\\[([^][|\n]+)(?:\\|([^][\n]*))?\\]\\]")

(define (md-link-targets body)
  (define text
    (regexp-replace* MD-CODE-RX
                     (regexp-replace* MD-FENCE-RX (format "~a" body) " ")
                     " "))
  (collect-targets
   (for/list ([m (in-list (regexp-match* MD-LINK-RX text #:match-select values))])
     (cons (cadr m) (caddr m)))))

;; The ONE place a format picks its link syntax, so the write path does not
;; switch on a format string itself.
(define (link-targets body fmt)
  (if (equal? fmt "org") (org-link-targets body) (md-link-targets body)))
