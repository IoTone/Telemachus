#lang racket/base

;; domain/apps/search.rkt — keyword search across a team's content (notes +
;; translations), RBAC-filtered: notes are checked per-row with `can?` (so private
;; notes of others never leak); translations are included only for members who may
;; use AI (chat:use). A retrieval app built entirely on existing data.

(require db
         racket/string
         "../authz/authz.rkt")

(provide search-all)

(define (like q) (string-append "%" q "%"))

(define (snippet text q)
  (define t (if (or (not text) (sql-null? text)) "" text))
  (define lo (string-downcase t))
  (define ql (string-downcase q))
  (define n (string-length lo)) (define m (string-length ql))
  (define i (let loop ([k 0])
              (cond [(> (+ k m) n) 0]
                    [(string=? (substring lo k (+ k m)) ql) k]
                    [else (loop (add1 k))])))
  (define start (max 0 (- i 30)))
  (define end (min (string-length t) (+ i m 60)))
  (string-append (if (> start 0) "…" "") (substring t start end) (if (< end (string-length t)) "…" "")))

(define (search-all conn p q #:limit [lim 20])
  (define team (principal-team-id p))
  (define pat (like q))
  (define note-hits
    (for/list ([r (in-list (query-rows conn
         (string-append "SELECT id, owner_user_id, visibility, title, body FROM notes "
                        "WHERE team_id = ? AND (title LIKE ? OR body LIKE ?) ORDER BY updated_at DESC LIMIT ?")
         team pat pat lim))]
         #:when (can? conn p "notes:read"
                      #:resource (hasheq 'resource_type "notes" 'resource_id (vector-ref r 0)
                                         'team_id team 'owner_user_id (vector-ref r 1)
                                         'visibility (vector-ref r 2))))
      (hasheq 'type "note" 'id (vector-ref r 0) 'title (vector-ref r 3)
              'snippet (snippet (vector-ref r 4) q))))
  (define tr-hits
    (if (can? conn p "chat:use")
        (for/list ([r (in-list (query-rows conn
             (string-append "SELECT id, target_lang, source_text, result_text FROM translations "
                            "WHERE team_id = ? AND (source_text LIKE ? OR result_text LIKE ?) ORDER BY created_at DESC LIMIT ?")
             team pat pat lim))])
          (hasheq 'type "translation" 'id (vector-ref r 0) 'title (string-append "→ " (vector-ref r 1))
                  'snippet (snippet (vector-ref r 2) q)))
        '()))
  (append note-hits tr-hits))
