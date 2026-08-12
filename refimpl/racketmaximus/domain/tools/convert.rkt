#lang racket/base

;; domain/tools/convert.rkt — native function-call → ToolBlock converter.
;; A model emits a native tool call (name + JSON arguments); this turns it back
;; into the (tool-type . content) the execution pipeline expects.
;;
;; The pattern-matching version of a long if/elif args.get(...) ladder: a `match`
;; on the resolved tool type.
;;
;; Provenance: the agent-loop / tool-execution *patterns* this participates in
;; descend from opencode (MIT). See ../../../../ACKNOWLEDGMENTS.md.
;;
;; NOTE: `alias-map`, `tool-tags`, and `builtin-email` below are PROVISIONAL
;; routing data carried over as a working set. They will be reconciled with
;; Telemachus's own tool catalog when that catalog is authored (the catalog is
;; also where re-written schema descriptions live). Keep this list in sync with
;; the tools the system actually registers.

(require racket/match
         racket/string
         racket/set
         json)

(provide (struct-out tool-block) function-call->tool-block)

(struct tool-block (type content) #:transparent)

;; ---- data (provisional working set; expand with the real tool catalog) ------
(define alias-map
  (hash "shell" "bash" "bash" "bash" "terminal" "bash" "command" "bash"
        "execute" "bash" "run" "bash"
        "python" "python" "code" "python"
        "search" "web_search" "web_search" "web_search" "websearch" "web_search"
        "google_search" "web_search"
        "web_fetch" "web_fetch" "webfetch" "web_fetch" "fetch" "web_fetch" "fetch_url" "web_fetch"
        "read" "read_file" "read_file" "read_file" "cat" "read_file"
        "write" "write_file" "write_file" "write_file" "save" "write_file"
        "edit" "edit_document" "edit_document" "edit_document"
        "create_document" "create_document" "update_document" "update_document"
        "suggest_document" "suggest_document"
        "search_chats" "search_chats"
        "grep" "grep" "glob" "glob" "ls" "ls" "edit_file" "edit_file"
        "pipeline" "pipeline" "manage_memory" "manage_memory"
        "manage_notes" "manage_notes" "notes" "manage_notes"
        "todo" "manage_notes" "todos" "manage_notes"
        "manage_tasks" "manage_tasks" "tasks" "manage_tasks" "schedule" "manage_tasks"
        "manage_endpoints" "manage_endpoints" "endpoints" "manage_endpoints"
        "manage_mcp" "manage_mcp" "mcp_servers" "manage_mcp"
        "manage_webhooks" "manage_webhooks" "webhooks" "manage_webhooks"
        "manage_tokens" "manage_tokens" "tokens" "manage_tokens"
        "manage_documents" "manage_documents" "documents" "manage_documents"
        "manage_settings" "manage_settings" "settings" "manage_settings"
        "preferences" "manage_settings"
        "manage_skills" "manage_skills" "skills" "manage_skills" "skill" "manage_skills"))

(define tool-tags
  (set "bash" "python" "web_search" "web_fetch" "read_file" "write_file" "edit_file"
       "grep" "glob" "ls" "create_document" "update_document" "edit_document"
       "suggest_document" "search_chats" "pipeline" "manage_memory" "manage_notes"
       "manage_tasks" "manage_endpoints" "manage_mcp" "manage_webhooks" "manage_tokens"
       "manage_documents" "manage_settings" "manage_skills" "manage_calendar"))

(define builtin-email
  (set "list_email_accounts" "send_email" "list_emails" "read_email" "reply_to_email"
       "archive_email" "delete_email" "mark_email_read" "bulk_email" "download_attachment"))

;; ---- helpers ---------------------------------------------------------------
(define (truthy v)                       ; Python-style truthiness for jsexpr values
  (cond [(or (eq? v #f) (eq? v 'null)) #f]
        [(and (string? v) (string=? v "")) #f]
        [(and (number? v) (zero? v)) #f]
        [(and (list? v) (null? v)) #f]
        [else #t]))

(define (s a k [default ""])             ; string-ish field, like args.get(k,"")
  (define v (hash-ref a k default))
  (cond [(string? v) v] [(eq? v 'null) default] [else (format "~a" v)]))

(define (json-or-empty a)                ; json.dumps(args) if args else "{}"
  (if (positive? (hash-count a)) (jsexpr->string a) "{}"))

(define (edit-blocks a)
  (string-join
   (for/list ([e (in-list (hash-ref a 'edits '()))] #:when (hash? e))
     (format "<<<FIND>>>\n~a\n<<<REPLACE>>>\n~a\n<<<END>>>" (s e 'find) (s e 'replace)))
   "\n"))

;; ---- content assembly (the match) ------------------------------------------
(define (content-for tt a)
  (match tt
    ["bash"   (s a 'command)]
    ["python" (s a 'code)]
    ["web_search"
     (define q (hash-ref a 'queries #f))
     (define content
       (cond [(and (list? q) (pair? q)) (format "~a" (car q))]
             [(truthy q) (format "~a" q)]
             [else (s a 'query)]))
     (define tf (hash-ref a 'time_filter #f))
     (if (and (not (string=? content "")) (string? tf)
              (member tf '("day" "week" "month" "year")))
         (jsexpr->string (hasheq 'query content 'time_filter tf))
         content)]
    ["read_file"
     (if (or (truthy (hash-ref a 'offset #f)) (truthy (hash-ref a 'limit #f)))
         (jsexpr->string a)
         (s a 'path))]
    [(or "grep" "glob" "ls") (json-or-empty a)]
    ["write_file" (string-append (s a 'path) "\n" (s a 'content))]
    ["edit_file"  (jsexpr->string a)]
    ["create_document"
     (string-join (append (list (s a 'title "Untitled"))
                          (if (truthy (hash-ref a 'language #f)) (list (s a 'language)) '())
                          (list (s a 'content)))
                  "\n")]
    ["edit_document"    (edit-blocks a)]
    ["suggest_document"
     (string-join
      (for/list ([x (in-list (hash-ref a 'suggestions '()))] #:when (hash? x))
        (format "<<<FIND>>>\n~a\n<<<SUGGEST>>>\n~a\n<<<REASON>>>\n~a\n<<<END>>>"
                (s x 'find) (s x 'replace) (s x 'reason)))
      "\n")]
    ["update_document" (s a 'content)]
    ["search_chats"    (s a 'query)]
    ["pipeline"        (jsexpr->string (hasheq 'steps (hash-ref a 'steps '())))]
    ["manage_memory"
     (define action (s a 'action))
     (match action
       ["add"    (string-append "add\n" (s a 'text)
                                (if (truthy (hash-ref a 'category #f)) (string-append "\n" (s a 'category)) ""))]
       ["edit"   (string-append "edit\n" (s a 'memory_id) "\n" (s a 'text))]
       ["delete" (string-append "delete\n" (s a 'memory_id))]
       ["search" (string-append "search\n" (s a 'text))]
       ["list"   (string-append "list"
                                (if (truthy (hash-ref a 'category #f)) (string-append "\n" (s a 'category)) ""))]
       [_ action])]
    [_ (jsexpr->string a)]))            ; fallback: json.dumps(args)

;; ---- the converter ---------------------------------------------------------
;; arguments: a JSON string (as native tool calls deliver it). Returns a
;; tool-block, or #f for bad JSON / unknown tool.
(define (function-call->tool-block name arguments)
  (define parsed
    (cond [(or (not arguments)
               (and (string? arguments) (string=? (string-trim arguments) ""))) (hasheq)]
          [(string? arguments) (with-handlers ([exn:fail? (lambda (_) 'bad)])
                                 (string->jsexpr arguments))]
          [(hash? arguments) arguments]
          [else 'bad]))
  (cond
    [(eq? parsed 'bad) #f]
    [else
     (define a (if (hash? parsed) parsed (hasheq)))   ; coerce non-object → {}
     (define tt (hash-ref alias-map name name))
     (cond
       [(string-prefix? tt "mcp__") (tool-block tt (json-or-empty a))]
       [(set-member? builtin-email name)
        (tool-block (string-append "mcp__email__" name) (json-or-empty a))]
       [(not (set-member? tool-tags tt)) #f]
       [else (tool-block tt (content-for tt a))])]))
