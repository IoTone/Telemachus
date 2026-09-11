#lang racket/base

;; domain/i18n/manager.rkt — the Localization Manager's model.
;;
;; The flagship tool, and the one that is supposed to PROVE the platform: it is
;; composed entirely from pieces that already exist — RBAC governs it, the
;; scheduler runs its AI drafts, the quota ledger meters them — and it adds no new
;; infrastructure of its own beyond two tables.
;;
;; THE CATALOGS ON DISK REMAIN THE SHIPPING ARTIFACT. `locales/*.json` is what the
;; runtime loads, what git diffs, and what the CI gate checks. These tables are the
;; workflow around them: who drafted a string, who reviewed it, whether the English
;; has moved since. `import!` pulls the catalogs in; `export` writes them back.
;; Neither is on the request path.
;;
;; Two statuses are DERIVED and never stored, because a stored copy could disagree
;; with the base catalog:
;;
;;   missing  — no row for that (message, locale), or the row's text is blank
;;   stale    — a row exists but `source_hash_at` <> the message's `source_hash`,
;;              i.e. the English changed after this translation was written
;;
;; Stored statuses are the human/machine workflow only: drafted | machine |
;; needs_review | approved.

(require db-kit/portable racket/string racket/list
         "../db/id.rkt"
         "catalog.rkt")

(provide l10n-import! l10n-export l10n-coverage l10n-list l10n-locales
         l10n-submit! l10n-review! l10n-message-ref
         l10n-status-of l10n-statuses
         draft-acceptable? l10n-discard-machine!)

;; The stored lifecycle. `missing` and `stale` are computed, so they are not here.
(define l10n-statuses '("drafted" "machine" "needs_review" "approved"))

(define (now-iso)
  (define d (seconds->date (current-seconds) #f))
  (define (p n) (if (< n 10) (format "0~a" n) (number->string n)))
  (format "~a-~a-~a ~a:~a:~a" (date-year d) (p (date-month d)) (p (date-day d))
          (p (date-hour d)) (p (date-minute d)) (p (date-second d))))

(define (s v) (if (or (not v) (sql-null? v)) "" (format "~a" v)))

;; "http.forbidden" -> "http"; a key with no dot is its own namespace.
(define (namespace-of key)
  (define i (for/first ([c (in-string key)] [n (in-naturals)] #:when (char=? c #\.)) n))
  (if i (substring key 0 i) key))

;; ---- import ------------------------------------------------------------------
;; Pull the base catalog and any target catalogs into the tables.
;;
;; Idempotent, and deliberately NON-DESTRUCTIVE in one direction: once a string is
;; in the database the database is authoritative for it, because that is where the
;; review happened. A re-import will update the ENGLISH (which is how a string goes
;; stale) but will never overwrite a translation or walk a status backwards.
;;
;; base    : catalog  (the en source of truth)
;; targets : (listof catalog)
;; -> (hash 'added n 'updated n 'deprecated n 'linked n)
(define (l10n-import! conn base targets)
  (define seen (make-hash))
  (define added 0) (define updated 0) (define linked 0)

  (for ([(key m) (in-hash (catalog-messages base))])
    (hash-set! seen key #t)
    (define text (msg-text m))
    (define hash (or (msg-hash m) (source-hash text)))
    (define row (query-maybe-row conn
                  "SELECT id, source_hash FROM l10n_messages WHERE msg_key = ?" key))
    (cond
      [(not row)
       (query-exec conn
         (string-append "INSERT INTO l10n_messages "
                        "(id, msg_key, namespace, source_text, source_hash, first_seen_at, deprecated) "
                        "VALUES (?, ?, ?, ?, ?, ?, 0)")
         (new-id) key (namespace-of key) text hash (now-iso))
       (set! added (add1 added))]
      [(not (string=? (s (vector-ref row 1)) hash))
       ;; English moved: every translation pinned to the old hash is now stale, and
       ;; that falls out of the comparison — no status has to be rewritten.
       (query-exec conn
         "UPDATE l10n_messages SET source_text = ?, source_hash = ?, deprecated = 0 WHERE id = ?"
         text hash (s (vector-ref row 0)))
       (set! updated (add1 updated))]
      [else
       ;; unchanged, but it may have been marked deprecated by an earlier import
       (query-exec conn "UPDATE l10n_messages SET deprecated = 0 WHERE id = ?" (s (vector-ref row 0)))]))

  ;; A key that vanished from the base is marked deprecated, never deleted — the
  ;; translation is somebody's work and the key may come back.
  (define deprecated
    (for/sum ([r (in-list (query-rows conn "SELECT id, msg_key FROM l10n_messages WHERE deprecated = 0"))])
      (cond [(hash-ref seen (s (vector-ref r 1)) #f) 0]
            [else (query-exec conn "UPDATE l10n_messages SET deprecated = 1 WHERE id = ?" (s (vector-ref r 0)))
                  1])))

  ;; Target catalogs: an existing shipped translation is imported as `approved`,
  ;; because it is already live in the product. A row that is already here wins.
  (for ([cat (in-list targets)])
    (define loc (catalog-locale cat))
    (for ([(key m) (in-hash (catalog-messages cat))])
      (define text (msg-text m))
      (unless (string=? (string-trim text) "")
        (define mid (query-maybe-value conn "SELECT id FROM l10n_messages WHERE msg_key = ?" key))
        (when (and mid (not (sql-null? mid)))
          (define existing (query-maybe-value conn
             "SELECT id FROM l10n_translations WHERE message_id = ? AND locale = ?" (s mid) loc))
          (unless existing
            (query-exec conn
              (string-append "INSERT INTO l10n_translations "
                             "(id, message_id, locale, text, status, source_hash_at, updated_at) "
                             "VALUES (?, ?, ?, ?, 'approved', ?, ?)")
              (new-id) (s mid) loc text (or (msg-hash m) "") (now-iso))
            (set! linked (add1 linked)))))))

  (hasheq 'added added 'updated updated 'deprecated deprecated 'linked linked))

;; ---- derived status ----------------------------------------------------------
;; (status, source-hash-at, message-hash, text) -> the status a human should see.
(define (l10n-status-of status hash-at msg-hash text)
  (cond
    [(string=? (string-trim (s text)) "") "missing"]
    [(not (string=? (s hash-at) (s msg-hash))) "stale"]
    [else (s status)]))

;; ---- reads -------------------------------------------------------------------
(define (l10n-message-ref conn id)
  (define r (query-maybe-row conn
    "SELECT id, msg_key, namespace, source_text, source_hash FROM l10n_messages WHERE id = ?" id))
  (and r (hasheq 'id (s (vector-ref r 0)) 'key (s (vector-ref r 1))
                 'namespace (s (vector-ref r 2)) 'source_text (s (vector-ref r 3))
                 'source_hash (s (vector-ref r 4)))))

;; Locales the manager knows about: every locale that has at least one row.
(define (l10n-locales conn)
  (for/list ([r (in-list (query-rows conn
                  "SELECT DISTINCT locale FROM l10n_translations ORDER BY locale"))])
    (s (vector-ref r 0))))

;; One row per base message, joined to this locale's translation if any.
;; status filter accepts the derived values too ("missing", "stale").
(define (l10n-list conn locale
                   #:status [status #f] #:namespace [ns #f]
                   #:q [q #f] #:limit [limit 50] #:offset [offset 0])
  ;; The locale is bound FIRST because it sits in the JOIN, not the WHERE — a
  ;; left join with the locale in the WHERE clause silently becomes an inner one
  ;; and every untranslated string disappears from the list.
  (define sql
    (string-append
     "SELECT m.id, m.msg_key, m.namespace, m.source_text, m.source_hash, "
     "       t.id, t.text, t.status, t.translated_by, t.reviewed_by, t.source_hash_at "
     "FROM l10n_messages m "
     "LEFT JOIN l10n_translations t ON t.message_id = m.id AND t.locale = ? "
     "WHERE m.deprecated = 0 "
     (if ns "AND m.namespace = ? " "")
     (if q "AND (m.msg_key LIKE ? OR m.source_text LIKE ?) " "")
     "ORDER BY m.msg_key"))
  (define args
    (append (list locale)
            (if ns (list ns) '())
            (if q (let ([pat (string-append "%" q "%")]) (list pat pat)) '())))
  (define rows (apply query-rows conn sql args))
  (define mapped
    (for/list ([r (in-list rows)])
      (define text (s (vector-ref r 6)))
      (define st (l10n-status-of (vector-ref r 7) (vector-ref r 10) (vector-ref r 4) text))
      (hasheq 'message_id (s (vector-ref r 0))
              'key (s (vector-ref r 1))
              'namespace (s (vector-ref r 2))
              'source_text (s (vector-ref r 3))
              'translation_id (s (vector-ref r 5))
              'text text
              'status st
              'translated_by (s (vector-ref r 8))
              'reviewed_by (s (vector-ref r 9)))))
  (define filtered
    (if status (filter (lambda (h) (string=? (hash-ref h 'status) status)) mapped) mapped))
  (define total (length filtered))
  (hasheq 'total total
          'items (let ([tail (if (> offset 0) (if (>= offset total) '() (list-tail filtered offset)) filtered)])
                   (if (> (length tail) limit) (take tail limit) tail))))

;; approved / base-count, plus the full status histogram and a per-namespace split.
(define (l10n-coverage conn locale)
  (define all (hash-ref (l10n-list conn locale #:limit 1000000) 'items))
  (define total (length all))
  (define (count-of st) (length (filter (lambda (h) (string=? (hash-ref h 'status) st)) all)))
  (define approved (count-of "approved"))
  (define by-ns
    (for/list ([grp (in-list (group-by (lambda (h) (hash-ref h 'namespace)) all))])
      (define n (length grp))
      (define ok (length (filter (lambda (h) (string=? (hash-ref h 'status) "approved")) grp)))
      (hasheq 'namespace (hash-ref (car grp) 'namespace)
              'total n 'approved ok
              'pct (if (zero? n) 0 (exact->inexact (/ (round (* 1000 (/ ok n))) 10))))))
  (hasheq 'locale locale
          'total total
          'approved approved
          'pct (if (zero? total) 0 (exact->inexact (/ (round (* 1000 (/ approved total))) 10)))
          'by_status (for/hasheq ([st (in-list (cons "missing" (cons "stale" l10n-statuses)))])
                       (values (string->symbol st) (count-of st)))
          'by_namespace (sort by-ns string<? #:key (lambda (h) (hash-ref h 'namespace)))))

;; ---- writes ------------------------------------------------------------------
;; Save a translation. Pins it to the ENGLISH IT WAS WRITTEN AGAINST, which is what
;; makes staleness self-maintaining: nothing has to notice the source changed later.
(define (l10n-submit! conn message-id locale text by #:status [status "needs_review"])
  (unless (member status l10n-statuses)
    (raise-user-error 'l10n-submit! "unknown status: ~a" status))
  (define m (l10n-message-ref conn message-id))
  (unless m (raise-user-error 'l10n-submit! "no such message: ~a" message-id))
  (define hash (hash-ref m 'source_hash))
  (define existing (query-maybe-value conn
    "SELECT id FROM l10n_translations WHERE message_id = ? AND locale = ?" message-id locale))
  (if (and existing (not (sql-null? existing)))
      (query-exec conn
        (string-append "UPDATE l10n_translations SET text = ?, status = ?, translated_by = ?, "
                       "reviewed_by = NULL, source_hash_at = ?, updated_at = ? WHERE id = ?")
        text status by hash (now-iso) (s existing))
      (query-exec conn
        (string-append "INSERT INTO l10n_translations "
                       "(id, message_id, locale, text, status, translated_by, source_hash_at, updated_at) "
                       "VALUES (?, ?, ?, ?, ?, ?, ?, ?)")
        (new-id) message-id locale text status by hash (now-iso)))
  (l10n-translation-ref conn message-id locale))

(define (l10n-translation-ref conn message-id locale)
  (define r (query-maybe-row conn
    (string-append "SELECT t.id, t.text, t.status, t.translated_by, t.reviewed_by, t.source_hash_at, m.source_hash "
                   "FROM l10n_translations t JOIN l10n_messages m ON m.id = t.message_id "
                   "WHERE t.message_id = ? AND t.locale = ?")
    message-id locale))
  (and r (hasheq 'id (s (vector-ref r 0)) 'text (s (vector-ref r 1))
                 'status (l10n-status-of (vector-ref r 2) (vector-ref r 5) (vector-ref r 6) (vector-ref r 1))
                 'stored_status (s (vector-ref r 2))
                 'translated_by (s (vector-ref r 3)) 'reviewed_by (s (vector-ref r 4)))))

;; Approve or send back. `by` is the reviewer.
;;
;; A DRAFTER CANNOT APPROVE THEIR OWN STRING. That is the whole point of having a
;; review state: a second pair of eyes, enforced here rather than asked for in the
;; UI. A machine draft has no human author, so anyone with the permission may
;; approve it — which is exactly the review the AI path needs.
(define (l10n-review! conn translation-id decision by)
  (define r (query-maybe-row conn
    "SELECT message_id, locale, translated_by, status FROM l10n_translations WHERE id = ?" translation-id))
  (unless r (raise-user-error 'l10n-review! "no such translation: ~a" translation-id))
  (define author (s (vector-ref r 2)))
  (case decision
    [(approve)
     (when (and (not (string=? author "")) (string=? author (s by)))
       (raise-user-error 'l10n-review! "a translator cannot approve their own string"))
     (query-exec conn
       "UPDATE l10n_translations SET status = 'approved', reviewed_by = ?, updated_at = ? WHERE id = ?"
       by (now-iso) translation-id)]
    [(reject)
     (query-exec conn
       "UPDATE l10n_translations SET status = 'drafted', reviewed_by = ?, updated_at = ? WHERE id = ?"
       by (now-iso) translation-id)]
    [else (raise-user-error 'l10n-review! "decision must be approve or reject")])
  (l10n-translation-ref conn (s (vector-ref r 0)) (s (vector-ref r 1))))

;; ---- draft acceptance --------------------------------------------------------
;; Is a machine draft structurally safe to put in the review queue?
;;
;; A bad draft that LOOKS finished is worse than a missing string: it sits in the
;; queue wearing a status, and a tired reviewer approves it. Every rule here was
;; added because a real reply from qwen2.5:7b got through without it:
;;
;;   1. simple placeholders match exactly — {user} renamed to {gebruiker} renders
;;      literal braces to an end user;
;;   2. brace COUNT matches — catches the stray `{}` / `{.}` appended to a sentence
;;      (no name inside, so rule 1 cannot see it, and the ICU renderer renders an
;;      empty name as "" rather than failing) and a mangled plural block;
;;   3. no newline unless the source has one — a multi-line reply is the model
;;      echoing its instructions, not translating;
;;   4. length ≤ 3× the source + 12 — "Chat" does not need 22 characters. Loose
;;      on purpose: Spanish renders "Reset to default" in 41 characters and that
;;      is correct, so a tight ratio would refuse real translations;
;;   5. no trailing colon the source does not have — the exact signature of a
;;      prompt heading echoed back ("Titel, alle verplicht:");
;;   6. no CJK characters unless the target is a CJK locale — half a Chinese
;;      sentence turned up inside a Dutch string.
;;
;; Deliberately NOT a parse with the real formatter: it is lenient by design (a
;; missing argument renders as ""), so it accepts exactly the drafts that need
;; refusing.
(define CJK-RX #px"[\u3040-\u30ff\u3400-\u4dbf\u4e00-\u9fff\uac00-\ud7af]")
(define (cjk-locale? loc)
  (and (member (car (string-split (string-downcase loc) "-")) '("ja" "zh" "ko")) #t))

(define (draft-acceptable? source draft #:locale [locale "en"])
  (define (names s) (sort (regexp-match* #px"\\{[a-zA-Z0-9_]+\\}" s) string<?))
  (define (braces s c) (for/sum ([ch (in-string s)]) (if (char=? ch c) 1 0)))
  (define (ends-colon? s) (and (> (string-length s) 0)
                               (char=? (string-ref s (sub1 (string-length s))) #\:)))
  (define d (string-trim draft))
  (and (not (string=? d ""))
       (equal? (names source) (names d))
       (= (braces source #\{) (braces d #\{))
       (= (braces source #\}) (braces d #\}))
       (or (regexp-match? #rx"\n" source) (not (regexp-match? #rx"\n" d)))
       (<= (string-length d) (+ 12 (* 3 (string-length source))))
       (or (ends-colon? source) (not (ends-colon? d)))
       (or (cjk-locale? locale) (not (regexp-match? CJK-RX d)))))

;; Throw away MACHINE drafts for a locale (optionally one namespace) so they can be
;; drafted again — after a bad model run, a prompt fix, a model change. Human work
;; is never touched: only rows with status 'machine', which by construction have
;; no translated_by. Returns the number discarded.
(define (l10n-discard-machine! conn locale #:namespace [ns #f])
  (define sql
    (string-append "SELECT t.id FROM l10n_translations t JOIN l10n_messages m ON m.id = t.message_id "
                   "WHERE t.locale = ? AND t.status = 'machine'"
                   (if ns " AND m.namespace = ?" "")))
  (define ids (apply query-list conn sql (if ns (list locale ns) (list locale))))
  (for ([id (in-list ids)])
    (query-exec conn "DELETE FROM l10n_translations WHERE id = ?" (s id)))
  (length ids))

;; ---- export ------------------------------------------------------------------
;; Build the catalog to write to locales/<locale>.json.
;;
;; APPROVED ONLY. A draft or a machine suggestion must never reach the product by
;; way of an export — review is the gate, and this is the door it guards.
;;
;; A STALE approved string still exports, carrying the hash it was written against.
;; That is not an oversight: it is what the shipped catalogs already do, it is
;; better for a user than falling back to English, and the file format records the
;; old hash so `telemachus-localize check` can still call it stale.
(define (l10n-export conn locale #:fallback [fallback "en"])
  (define rows
    (query-rows conn
      (string-append "SELECT m.msg_key, t.text, t.source_hash_at "
                     "FROM l10n_translations t JOIN l10n_messages m ON m.id = t.message_id "
                     "WHERE t.locale = ? AND t.status = 'approved' AND m.deprecated = 0 "
                     "ORDER BY m.msg_key")
      locale))
  (make-catalog locale fallback
    (for/hash ([r (in-list rows)])
      (values (s (vector-ref r 0)) (cons (s (vector-ref r 1)) (s (vector-ref r 2)))))))
