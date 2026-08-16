#lang racket/base

;; domain/apps/translate.rkt — the Translation app (slice 17).
;;
;; A first user-facing "app" on the platform: translate text (or a whole locale
;; catalog) via the model, with a team GLOSSARY for consistent terminology and a
;; team-scoped history. Every op is authorized through the AuthzService and the
;; endpoints meter AI spend through the usual quotas. The model call is injected
;; (#:chat) so the app is testable without a live model; it defaults to run-chat.
;;
;; Dogfood: `translate-catalog!` translates a locale catalog (keys unchanged,
;; placeholders preserved) — the engine behind producing our ja/nl/es-419 files.

(require db-kit/portable
         racket/string
         json
         "../db/id.rkt"
         "../authz/authz.rkt"
         "../ai/executor.rkt")     ; run-chat, model-info

(provide translate! translate-list translate-catalog!
         glossary-add! glossary-list lang-label)

;; ---- language labels --------------------------------------------------------
(define lang-names
  (hash "en" "English" "ja" "Japanese" "nl" "Dutch" "es-419" "Latin American Spanish"
        "es" "Spanish" "fr" "French" "de" "German" "it" "Italian" "pt" "Portuguese"
        "zh" "Chinese" "ko" "Korean" "la" "Latin"))
(define (lang-label code) (hash-ref lang-names code code))

;; ---- glossary ---------------------------------------------------------------
(define (glossary-list conn p #:target-lang [tgt #f])
  (require-perm conn p "chat:use")
  (define rows
    (if tgt
        (query-rows conn "SELECT id,target_lang,term,translation FROM glossary WHERE team_id=? AND target_lang=? ORDER BY term"
                    (principal-team-id p) tgt)
        (query-rows conn "SELECT id,target_lang,term,translation FROM glossary WHERE team_id=? ORDER BY target_lang,term"
                    (principal-team-id p))))
  (for/list ([r (in-list rows)])
    (hasheq 'id (vector-ref r 0) 'target_lang (vector-ref r 1) 'term (vector-ref r 2) 'translation (vector-ref r 3))))

(define (glossary-add! conn p #:term term #:translation tr #:target-lang tgt)
  (require-perm conn p "settings:manage")             ; curating terminology is a managed action
  (define id (new-id))
  (query-exec conn
    (string-append "INSERT INTO glossary (id,team_id,target_lang,term,translation) VALUES (?,?,?,?,?) "
                   "ON CONFLICT(team_id,target_lang,term) DO UPDATE SET translation=excluded.translation")
    id (principal-team-id p) tgt term tr)
  (hasheq 'id id 'target_lang tgt 'term term 'translation tr))

;; ---- translation ------------------------------------------------------------
(define (system-prompt tgt src terms)
  (string-append
   "You are a professional translator. Translate the user's text into " (lang-label tgt)
   (if (and src (not (string=? src "auto"))) (string-append " from " (lang-label src)) "") ".\n"
   "Preserve meaning, tone, line breaks, and any placeholders such as {name} or ICU plural/select syntax EXACTLY.\n"
   "Output ONLY the translation — no preamble, no explanation, no surrounding quotes.\n"
   (if (null? terms) ""
       (string-append "Apply this glossary (term => required translation):\n"
                      (string-join (for/list ([t (in-list terms)])
                                     (string-append "- " (hash-ref t 'term) " => " (hash-ref t 'translation))) "\n")
                      "\n"))))

(define (default-chat text sys) (run-chat text #:system sys))

;; returns (values job-hash tokens-used)
(define (translate! conn p #:text text #:target-lang tgt
                    #:source-lang [src "auto"] #:use-glossary [gl? #t] #:chat [chat default-chat])
  (require-perm conn p "chat:use")
  (define terms (if gl? (glossary-list conn p #:target-lang tgt) '()))
  (define-values (reply tokens) (chat text (system-prompt tgt src terms)))
  (define id (new-id))
  (define model (hash-ref (model-info) 'model "fallback"))
  (query-exec conn
    "INSERT INTO translations (id,team_id,owner_user_id,source_lang,target_lang,source_text,result_text,model) VALUES (?,?,?,?,?,?,?,?)"
    id (principal-team-id p) (principal-user-id p) src tgt text reply model)
  (values (hasheq 'id id 'source_lang src 'target_lang tgt 'source_text text 'result reply 'model model) tokens))

(define (row->tr r)
  (hasheq 'id (vector-ref r 0) 'source_lang (vector-ref r 1) 'target_lang (vector-ref r 2)
          'source_text (vector-ref r 3) 'result (vector-ref r 4) 'model (vector-ref r 5) 'created_at (vector-ref r 6)))

(define (translate-list conn p #:limit [lim 20])
  (require-perm conn p "chat:use")
  (for/list ([r (in-list (query-rows conn
                          "SELECT id,source_lang,target_lang,source_text,result_text,model,created_at FROM translations WHERE team_id=? ORDER BY created_at DESC LIMIT ?"
                          (principal-team-id p) lim))])
    (row->tr r)))

;; ---- catalog translation (localization dogfood) -----------------------------
(define (extract-json s)
  (let ([m (regexp-match #rx"(?s:[{].*[}])" s)]) (if m (car m) s)))

;; cat: hash of key->string. returns (values translated-hash tokens)
(define (translate-catalog! conn p #:catalog cat #:target-lang tgt #:chat [chat default-chat])
  (require-perm conn p "chat:use")
  (define sys
    (string-append
     "You are a localization engine. You are given a JSON object of UI strings. "
     "Translate every string VALUE into " (lang-label tgt) ". Keep every KEY exactly as-is. "
     "Preserve placeholders like {name} and ICU plural/select syntax EXACTLY. "
     "Return ONLY a JSON object with the same keys and translated values."))
  (define-values (reply tokens) (chat (jsexpr->string cat) sys))
  (define parsed (with-handlers ([exn:fail? (lambda (_) #f)]) (string->jsexpr (extract-json reply))))
  (values (if (hash? parsed) parsed (hasheq)) tokens))
