#lang racket/base

;; domain/agent/seals.rkt — the sealed-column registry a plugin may contribute.
;;
;; A rotation walks `cli/telemachus-secrets.rkt`'s list. Before this module that
;; list was the ONLY home, so a plugin that sealed a column with the platform key
;; had no way to say so and `rewrap` silently skipped it. The row kept opening
;; while TMACH_SECRET_KEY_OLD was set and stopped the day the runbook's last step
;; dropped it. `plugins/matrix/main.rkt` recorded that gap and stored its
;; credential in the environment instead.
;;
;; A plugin now declares `(provide secrets)` as DATA, the same shape and the same
;; reason `(provide migrations)` is data: a procedure could name any table and
;; nothing could tell. Each entry is
;;
;;   (list table column id-columns context-template [form])
;;
;;   table             the plugin's own table; MUST carry its x_<id>_ prefix
;;   column            the sealed column
;;   id-columns        one column name, or a list of them (in template order)
;;   context-template  literal text plus {table}, {column}, {id1}..{idN} ({id}
;;                     is {id1}); it MUST name at least one id, because one AAD
;;                     for every row is the per-row binding this exists to keep
;;   form              'text (default) or 'bytes
;;
;; The template is the point. The platform's own AAD is
;; `<column>:<id>[:<id>…]`, while a plugin may have written
;; `<table>.<id>.<column>` before this existed. A registry that only knew a
;; prefix would recompose the WRONG AAD and `rewrap` would abort on the first
;; row — `secret-unwrap` fails the GCM tag and `rewrap` deliberately stops rather
;; than skipping. A template lets the declaration state the rule the rows were
;; actually written under.
;;
;; WHAT THE REGISTRY DOES NOT COVER: a blob. A column is (row id -> stored value),
;; and a rewrap is one UPDATE. A sealed file in the blob store is (digest ->
;; bytes) with the digest naming the ciphertext, so rotating it means writing a
;; new blob and repointing the row. No column list can express that, and this
;; module does not pretend to; a product that owns the blob (RCNT's vault) owns
;; its rotation too.

(require racket/list racket/string db-kit/portable)

(provide SEAL-FORMS
         seal-spec-problem check-seals!
         seal-context-of
         record-plugin-seals! ledger-specs ledger-missing)

(define SEAL-FORMS '(text bytes))

;; The same identifier shape the migration prefix check accepts: lower-case,
;; digits and underscores, never schema-qualified.
(define (identifier? s) (and (string? s) (regexp-match? #px"^[a-z][a-z0-9_]*$" s)))

(define (id-list v)
  (cond [(string? v) (list v)]
        [(and (list? v) (pair? v) (andmap identifier? v)) v]
        [else #f]))

(define (placeholders template)
  (regexp-match* #px"\\{([A-Za-z0-9_]+)\\}" template #:match-select cadr))

(define (template-problem template n)
  (define names (placeholders template))
  (define leftover (regexp-replace* #px"\\{[A-Za-z0-9_]+\\}" template ""))
  (cond
    [(regexp-match? #px"[{}]" leftover)
     "the context template has a brace that is not a {name} placeholder"]
    [(empty? names)
     "the context template needs at least one id placeholder ({id1}); one AAD for every row is not a per-row binding"]
    [else
     (define id-names
       (filter (lambda (nm) (or (string=? nm "id") (regexp-match? #px"^id[0-9]+$" nm))) names))
     (cond
      [(empty? id-names)
       "the context template needs at least one id placeholder ({id1}); one AAD for every row is not a per-row binding"]
      [else
     (for/or ([nm (in-list names)])
       (cond
         [(member nm '("table" "column" "id")) #f]
         [(regexp-match #px"^id([0-9]+)$" nm)
          (define i (string->number (cadr (regexp-match #px"^id([0-9]+)$" nm))))
          (and (not (<= 1 i n))
               (format "the context template names {id~a} but the spec has ~a id column(s)" i n))]
         [else
          (format "the context template names {~a}, which is not {table}, {column}, {id} or {id1}..{id~a}" nm n)]))])]))

;; -> #f, or a sentence saying what is wrong. `prefix` is the plugin's own
;; `x_<id>_` prefix, so this module does not have to require the loader.
(define (seal-spec-problem prefix spec)
  (cond
    [(not (and (list? spec) (>= (length spec) 4) (<= (length spec) 5)))
     "a sealed column is (list table column id-columns context-template [form])"]
    [(not (identifier? (list-ref spec 0)))
     (format "the table ~s is not a plain lower-case identifier" (list-ref spec 0))]
    [(not (string-prefix? (list-ref spec 0) prefix))
     (format "the table ~a is not named ~a*, so it is not this plugin's to seal"
             (list-ref spec 0) prefix)]
    [(not (identifier? (list-ref spec 1)))
     (format "the column ~s is not a plain lower-case identifier" (list-ref spec 1))]
    [(not (id-list (list-ref spec 2)))
     (format "the id columns ~s are not one name or a non-empty list of names" (list-ref spec 2))]
    [(not (string? (list-ref spec 3)))
     "the context template must be a string"]
    [else
     (template-problem (list-ref spec 3) (length (id-list (list-ref spec 2))))]))

(define (form-problem spec)
  (and (> (length spec) 4)
       (not (memq (list-ref spec 4) SEAL-FORMS))
       (format "the form ~s must be one of ~a" (list-ref spec 4) SEAL-FORMS)))

(define (check-seals! id prefix v)
  (unless (list? v) (error 'plugins "~a: `secrets` must be a list" id))
  (define seen (make-hash))
  (for/list ([spec (in-list v)] [i (in-naturals)])
    (define problem (or (seal-spec-problem prefix spec) (form-problem spec)))
    (when problem (error 'plugins "~a: sealed column ~a: ~a" id i problem))
    (define key (list (list-ref spec 0) (list-ref spec 1)))
    (when (hash-has-key? seen key)
      (error 'plugins "~a: sealed column ~a.~a is declared twice" id (car key) (cadr key)))
    (hash-set! seen key #t)
    (list id
          (list-ref spec 0)
          (list-ref spec 1)
          (id-list (list-ref spec 2))
          (list-ref spec 3)
          (if (> (length spec) 4) (list-ref spec 4) 'text))))

;; <table>.<column>:<id>… is the platform's own rule, and it is what the platform
;; entries in the CLI already carry as a prefix. That is why `seal-context-of`
;; is only for the {…} templates: the two spellings must stay distinguishable,
;; because the string is authenticated data in every row ever written.
(define (seal-context-of template table column ids)
  (regexp-replace* #px"\\{([A-Za-z0-9_]+)\\}"
                   template
                   (lambda (m name)
                     (cond
                       [(string=? name "table") table]
                       [(string=? name "column") column]
                       [(string=? name "id") (car ids)]
                       [else
                        (define n (string->number (substring name 2)))
                        (list-ref ids (sub1 n))]))))

;; ---- the ledger ---------------------------------------------------------------
;; Written at boot, never deleted. A registry that only exists while a plugin
;; loads cannot serve the case that matters most: a plugin that was UNINSTALLED
;; still has rows in the database, and they still need rotating. The ledger is
;; what `status` reports and `rewrap` walks for those.

(define (table-exists? conn table)
  (with-handlers ([exn:fail? (lambda (_) #f)])
    (query-rows conn (format "SELECT 1 FROM ~a LIMIT 0" table))
    #t))

;; -> (values recorded skipped changed)
;;
;; `skipped` names a declaration whose table does not exist YET or any more: a
;; typo, or a plugin whose migration did not run. Reporting it is the point — a
;; silent skip is how a sealed column stops being rotated without anyone noticing.
;;
;; `changed` names a declaration whose TEMPLATE, id columns or form differs from
;; what the ledger already holds. The row is updated either way: a plugin that
;; corrected a wrong template must not keep being rotated under the old one, and
;; the operator has to know that rows written under the old spelling need their
;; own pass.
(define (record-plugin-seals! conn specs now)
  (define present (filter (lambda (s) (table-exists? conn (list-ref s 1))) specs))
  (define skipped (for/list ([s (in-list specs)]
                             #:unless (table-exists? conn (list-ref s 1)))
                    (format "~a.~a" (list-ref s 1) (list-ref s 2))))
  (define changed (box '()))
  (for ([s (in-list present)])
    (define plugin-id (list-ref s 0))
    (define table (list-ref s 1))
    (define col (list-ref s 2))
    (define ids (list-ref s 3))
    (define template (list-ref s 4))
    (define form (list-ref s 5))
    (define old (query-maybe-row conn
                                 "SELECT id_columns, context_template, form, plugin_id FROM plugin_seals WHERE tbl = ? AND col = ?"
                                 table col))
    (when (and old
               (not (and (equal? (vector-ref old 0) (string-join ids ","))
                         (equal? (vector-ref old 1) template)
                         (equal? (vector-ref old 2) (symbol->string form))
                         (equal? (vector-ref old 3) plugin-id))))
      (set-box! changed (cons (format "~a.~a" table col) (unbox changed))))
    (query-exec conn
                (string-append
                 "INSERT INTO plugin_seals "
                 "(plugin_id, tbl, col, id_columns, context_template, form, first_seen_epoch, last_seen_epoch) "
                 "VALUES (?,?,?,?,?,?,?,?) "
                 "ON CONFLICT (tbl, col) DO UPDATE SET "
                 "  plugin_id = excluded.plugin_id, id_columns = excluded.id_columns, "
                 "  context_template = excluded.context_template, form = excluded.form, "
                 "  last_seen_epoch = excluded.last_seen_epoch")
                plugin-id table col (string-join ids ",") template (symbol->string form) now now))
  (values (length present) skipped (reverse (unbox changed))))

;; -> (listof (list table column id-columns context-procedure form)), the same
;; spec shape `rewrap` already consumes, except that the context is a procedure
;; because a template needs the row's ids to render.
(define (ledger-rows conn)
  (if (not (table-exists? conn "plugin_seals"))
      '()
      (for/list ([r (in-list (query-rows conn
                                         (string-append
                                          "SELECT tbl, col, id_columns, context_template, form, plugin_id "
                                          "FROM plugin_seals ORDER BY tbl, col")))])
        r)))

;; A LEDGER ROW WHOSE TABLE IS GONE IS SKIPPED AND NAMED, never walked. This is
;; the state SEAL-3 exists for (a plugin uninstalled, its tables dropped), and a
;; raw SQL error there aborted `rewrap` part-way through the list, leaving the
;; database half-rotated with no diagnostic.
(define (ledger-missing conn)
  (for/list ([r (in-list (ledger-rows conn))]
             #:unless (table-exists? conn (vector-ref r 0)))
    (list (vector-ref r 0) (vector-ref r 1) (vector-ref r 5))))

(define (ledger-specs conn)
  (for/list ([r (in-list (ledger-rows conn))]
             #:when (table-exists? conn (vector-ref r 0)))
    (define table (vector-ref r 0))
    (define col (vector-ref r 1))
    (define ids (string-split (vector-ref r 2) ","))
    (define template (vector-ref r 3))
    (define form (string->symbol (vector-ref r 4)))
    (list table col ids
          (lambda (row-ids) (seal-context-of template table col row-ids))
          form)))
