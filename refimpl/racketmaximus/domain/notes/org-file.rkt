#lang racket/base

;; domain/notes/org-file.rkt — a note as a `.org` FILE (#246 slice 3, ORG-11/12).
;;
;; NO DEPENDENCIES, like `org-links.rkt` beside it: the compose and the parse have
;; three askers between them — the download, the import, and the FILETAGS
;; authority on every write — and none of them may be the one that owns the rule.
;;
;; 🔑 THE ABSENT/PRESENT DISTINCTION IS THE WHOLE DESIGN HERE, and it is the one
;; `#:tags #f` vs `'()` already draws for the HTTP surface (TAG-4). A
;; `#+FILETAGS:` line that is NOT THERE says nothing about the note's tags and
;; leaves them alone; a line that IS there is authoritative, including when it is
;; empty, which is how a body clears them. Without that split, converting a
;; tagged Markdown note to org would silently drop its whole tag set the first
;; time it was saved — ORG-12 makes the body the truth, and a body with no
;; keyword line is not a body saying "no tags".

(require racket/list racket/string)

(provide org-compose org-parse org-keyword-line? MAX-ORG-IMPORT-BYTES)

;; The control plane is `serve/servlet`, whose default maximum body is 1 MiB and
;; which enforces it by DROPPING THE CONNECTION WITH NO RESPONSE — this tree's
;; own documented trap. So the import refuses well under it, by name, and an org
;; file larger than this belongs in the repository (`PUT /api/repo/<key>`), which
;; runs on `web-kit/http1` and is built to move a 2 GB file.
;;
;; `POST /api/notes` is deliberately NOT capped by this: it has never had a cap,
;; and adding one here would start refusing bodies that work today.
(define MAX-ORG-IMPORT-BYTES (* 512 1024))

(define TITLE-RX    #px"^[ \t]*#\\+TITLE:[ \t]*(.*)$")
(define FILETAGS-RX #px"^[ \t]*#\\+FILETAGS:[ \t]*(.*)$")

;; Only the two keywords this understands. ANY OTHER `#+KEY:` LINE STAYS IN THE
;; BODY, which is what stops an import from eating a foreign file's `#+OPTIONS:`
;; or `#+STARTUP:` — those render as their own text (ORG-4's honest failure) and
;; losing them silently would be worse.
(define (org-keyword-line? l)
  (or (regexp-match? TITLE-RX l) (regexp-match? FILETAGS-RX l)))

;; ORG's OWN DELIMITER IS `:`, and that is what makes a round trip exact for a
;; tag this platform allows and org's own grammar would not: org tags are
;; `[A-Za-z0-9_@#%]+` with no spaces, while a #245 tag may be `levee 7`. Splitting
;; on `:` keeps it whole.
;;
;; A value with NO colon in it is split on whitespace instead, because that is
;; how the form appears in files written elsewhere. The residual ambiguity — a
;; colon-free line meaning ONE tag with a space in it — cannot arise from this
;; platform's own export, which always writes the colons.
(define (parse-filetags v)
  (define s (string-trim v))
  (cond [(string=? s "") '()]
        [(regexp-match? #rx":" s) (filter (lambda (x) (not (string=? x "")))
                                          (map string-trim (string-split s ":" #:trim? #f)))]
        [else (string-split s)]))

;; `:a:levee 7:` — org's own shape, so what this writes is a file org itself reads.
(define (compose-filetags tags)
  (string-append ":" (string-join tags ":") ":"))

;; ORG-11 — the keywords go in FRONT of the body with one blank line between, and
;; the blank line is what `org-parse` consumes back. Those two have to be read
;; together: the round trip is asserted BYTE-IDENTICAL FOR THE BODY, which is the
;; only property a user of this cares about.
(define (org-compose title tags body)
  (string-append
   (format "#+TITLE: ~a\n" (string-trim (format "~a" title)))
   (if (null? tags) "" (format "#+FILETAGS: ~a\n" (compose-filetags tags)))
   "\n"
   (format "~a" body)))

;; Answers `(values title tags body)`, where
;;   title — the `#+TITLE:` value, or #f when there is no such line
;;   tags  — the parsed list, or #f when there is NO `#+FILETAGS:` LINE AT ALL
;;           (which is not the same as `'()`, a line that is there and empty)
;;   body  — everything else, with exactly one blank line after the keyword block
;;           consumed if there was one
;;
;; THE SCAN ONLY CONSUMES A LEADING RUN of the two keywords it understands and
;; stops at the first line that is neither. A file whose first line is
;; `#+OPTIONS:` therefore keeps every line it has and its title stays in the
;; body — where `orgRender` draws it as the heading anyway, so nothing is lost on
;; screen.
;;
;; DROPPING EXACTLY ONE EMPTY LINE is what makes the round trip exact for every
;; body, including one that itself begins with a blank line: `org-compose` adds
;; one separator and this removes one.
(define (org-parse text)
  (define lines (string-split (format "~a" text) "\n" #:trim? #f))
  (let loop ([ls lines] [title #f] [tags #f])
    (cond
      [(null? ls) (values title tags "")]
      [(regexp-match TITLE-RX (car ls))
       => (lambda (m) (loop (cdr ls) (or title (string-trim (cadr m))) tags))]
      [(regexp-match FILETAGS-RX (car ls))
       => (lambda (m) (loop (cdr ls) title (or tags (parse-filetags (cadr m)))))]
      [else
       ;; one separator blank line, and one only
       ;; EXACTLY "" and not a trimmed blank: a body whose first line is spaces
       ;; must keep them, or the round trip is not byte-identical
       (define rest (if (and (pair? ls) (string=? (car ls) "")
                             (or title tags))
                        (cdr ls)
                        ls))
       (values title tags (string-join rest "\n"))])))
