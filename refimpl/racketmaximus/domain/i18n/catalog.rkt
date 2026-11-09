#lang racket/base

;; domain/i18n/catalog.rkt — message catalogs on disk + coverage diff.
;;
;; Catalog JSON:
;;   { "meta": {"locale":"en","base":true|,"fallback":"en"},
;;     "messages": { "<id>": {"text":"…","hash":"…"} } }
;;
;; The base (`en`) catalog's hash is sha1(text) — the source hash. A target
;; catalog stores, per id, the source hash it was translated against, so a later
;; English edit (new source hash) marks that translation STALE. An empty target
;; text counts as untranslated (missing).

(require json
         file/sha1
         racket/port
         racket/string
         cli-kit)                       ; jsexpr->pretty-string

(provide source-hash
         make-catalog catalog-locale catalog-messages
         catalog-ref msg-text msg-hash
         read-catalog write-catalog catalog-exists?
         build-en-catalog sync-target
         catalog-duplicate-keys
         diff coverage
         ;; the coverage floor, and the two questions it answers — exported for
         ;; the runtime policy, the CI gate and their tests
         LOCALE-COVERAGE-FLOOR locale-coverage advertised?)

;; ---- model ------------------------------------------------------------------
;; messages : (hash id-string → (cons text hash))
(struct catalog (locale fallback messages) #:transparent)

(define (msg-text m) (car m))
(define (msg-hash m) (cdr m))
(define (catalog-ref cat id) (hash-ref (catalog-messages cat) id #f))

(define (make-catalog locale fallback messages) (catalog locale fallback messages))

(define (source-hash text) (sha1 (open-input-string text)))

;; A duplicate top-level key is INVISIBLE to `read-json`, which keeps the last
;; one, so `diff` sees one message and the gate stays green while the file holds
;; two texts for one id and every reader that is not this parser picks the other
;; one. It happened: locales/en.json carried `ui.troverlimit` twice, the stale
;; wording first and the current one second, and nothing failed. The check counts
;; the id's own key token in the raw text, because the parsed catalog cannot say
;; it appeared twice.
(define (catalog-duplicate-keys path)
  (define lines (string-split (call-with-input-file path port->string) "\n"))
  (define messages (catalog-messages (read-catalog path)))
  (for/list ([id (in-list (hash-keys messages))]
             #:when (> (for/sum ([line (in-list lines)]
                                 #:when (regexp-match?
                                         (regexp (string-append
                                                  "^[ \\t]*\"" (regexp-quote id)
                                                  "\"[ \\t]*:[ \\t]*\\{"))
                                         line))
                          1)
                       1))
    id))

;; ---- io ---------------------------------------------------------------------
(define (catalog-exists? path) (file-exists? path))

(define (read-catalog path)
  (define j (call-with-input-file path read-json))
  (define meta (hash-ref j 'meta (hasheq)))
  (define msgs (hash-ref j 'messages (hasheq)))
  (define messages
    (for/hash ([(k v) (in-hash msgs)])
      (values (symbol->string k)
              (cons (hash-ref v 'text "") (hash-ref v 'hash "")))))
  (catalog (hash-ref meta 'locale "en")
           (hash-ref meta 'fallback 'null)
           messages))

(define (catalog->jsexpr cat)
  (define meta
    (let ([m (hasheq 'locale (catalog-locale cat))])
      (if (eq? (catalog-fallback cat) 'null) m (hash-set m 'fallback (catalog-fallback cat)))))
  (hasheq 'meta meta
          'messages
          (for/hasheq ([(id td) (in-hash (catalog-messages cat))])
            (values (string->symbol id) (hasheq 'text (car td) 'hash (cdr td))))))

(define (write-catalog path cat)
  (call-with-output-file path #:exists 'replace
    (lambda (out)
      (write-string (jsexpr->pretty-string (catalog->jsexpr cat)) out)
      (newline out))))

;; ---- construction -----------------------------------------------------------
;; id+defaults : (listof (list id default)) → the en base catalog
(define (build-en-catalog id+defaults)
  (define messages
    (for/fold ([h (hash)]) ([pair (in-list id+defaults)])
      (define id (car pair))
      (define default (cadr pair))
      (if (hash-has-key? h id) h                            ; first definition wins
          (hash-set h id (cons default (source-hash default))))))
  (catalog "en" 'null messages))

;; scaffold/refresh a target locale against the base: keep existing translations,
;; add any new base ids as empty (untranslated), drop unused. Empty entries carry
;; the current base hash so filling only the text marks them translated.
(define (sync-target base locale existing)
  (define base-msgs (catalog-messages base))
  (define existing-msgs (if existing (catalog-messages existing) (hash)))
  (define messages
    (for/hash ([(id btd) (in-hash base-msgs)])
      (define cur (hash-ref existing-msgs id #f))
      (values id (if (and cur (not (string=? (car cur) "")))
                     cur                                     ; keep a real translation as-is
                     (cons "" (cdr btd))))))                 ; scaffold empty @ base hash
  (catalog locale "en" messages))

;; ---- diff / coverage --------------------------------------------------------
;; returns (values missing stale unused) — sorted id lists
(define (diff base target)
  (define b (catalog-messages base))
  (define t (catalog-messages target))
  (define missing
    (for/list ([id (in-list (sort (hash-keys b) string<?))]
               #:unless (let ([m (hash-ref t id #f)]) (and m (not (string=? (car m) "")))))
      id))
  (define stale
    (for/list ([id (in-list (sort (hash-keys b) string<?))]
               #:when (let ([m (hash-ref t id #f)])
                        (and m (not (string=? (car m) "")) (not (string=? (cdr m) (cdr (hash-ref b id)))))))
      id))
  (define unused
    (for/list ([id (in-list (sort (hash-keys t) string<?))] #:unless (hash-has-key? b id)) id))
  (values missing stale unused))

;; returns (values covered total)
(define (coverage base target)
  (define b (catalog-messages base))
  (define t (catalog-messages target))
  (define total (hash-count b))
  (define covered
    (for/sum ([(id btd) (in-hash b)])
      (define m (hash-ref t id #f))
      (if (and m (not (string=? (car m) "")) (string=? (cdr m) (cdr btd))) 1 0)))
  (values covered total))


;; ---- how complete is a catalog? -------------------------------------------
;;
;; A LOCALE IS ADVERTISED ONLY IF IT IS SUBSTANTIALLY TRANSLATED. `available`
;; used to be "whichever `<locale>.json` files exist", which is right about what
;; the build can OPEN and wrong about what it can offer: `nl` and `es-419` ship
;; 190 of 1,179 messages (16%), so a switcher built on `available` offered Dutch
;; and answered five strings of every six in English. A half-translated page that
;; looks finished is worse than an obviously untranslated one, which is the same
;; rule the screenshot captions and the book's chapters live by.
;;
;; The floor is a SHARE OF `en`, measured with `coverage` above — a string counts
;; only when it is present, non-empty and still pinned to the English it was
;; translated from, so a stale translation does not count as coverage.
;;
;; 80 is chosen to mean "the reader is not being shown English and told it is
;; their language": at four strings in five translated, the fallback is an
;; occasional word rather than the body of the page. It is a floor and not a
;; target — `ja` sits at 100% and anything below 80 is a draft, which the
;; Localization Manager still shows and still lets a translator work on. Nothing
;; here deletes a catalog: a locale below the floor keeps its file, keeps its
;; rows in the manager and keeps being imported, and only stops being OFFERED.
(define LOCALE-COVERAGE-FLOOR 80)

;; → an integer percentage of the base catalog this locale covers. "en" and a
;; build with no base catalog are 100 by definition; a locale with no file is 0.
(define (locale-coverage dir loc)
  (define en (build-path dir "en.json"))
  (define tgt (build-path dir (string-append loc ".json")))
  (cond
    [(or (equal? loc "en") (not (catalog-exists? en))) 100]
    [(not (catalog-exists? tgt)) 0]
    [else
     (let-values ([(covered total) (coverage (read-catalog en) (read-catalog tgt))])
       (if (zero? total) 100 (quotient (* 100 covered) total)))]))

(define (advertised? dir loc)
  (>= (locale-coverage dir loc) LOCALE-COVERAGE-FLOOR))
