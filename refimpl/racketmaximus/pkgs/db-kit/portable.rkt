#lang racket/base

;; db-kit/portable — a drop-in replacement for `(require db)` that makes the same
;; SQL run on SQLite *and* PostgreSQL. It re-exports all of `db`, but overrides the
;; query-* functions to rewrite `?` placeholders into `$1,$2,…` when the connection
;; is PostgreSQL (SQLite keeps `?`). Callers change one require line; every existing
;; (query-exec conn "… ? …" a b) call becomes portable with no other changes.
;;
;; Only placeholders OUTSIDE single-quoted string literals are rewritten (doubled
;; '' escapes are handled), so literals containing `?` are left intact.

(require db)

(provide (except-out (all-from-out db)
                     query-exec query-rows query-row query-maybe-row
                     query-value query-maybe-value query-list query)
         (rename-out [q-exec query-exec] [q-rows query-rows] [q-row query-row]
                     [q-maybe-row query-maybe-row] [q-value query-value]
                     [q-maybe-value query-maybe-value] [q-list query-list] [q-query query])
         db-dialect pg-rewrite)

(define (db-dialect conn) (dbsystem-name (connection-dbsystem conn)))

;; "… ? … ? …" -> "… $1 … $2 …" (PostgreSQL), skipping quoted-string literals.
(define (pg-rewrite sql)
  (define out (open-output-string))
  (let loop ([cs (string->list sql)] [in-str #f] [n 1])
    (cond
      [(null? cs) (get-output-string out)]
      [else
       (define c (car cs))
       (cond
         [(char=? c #\')
          (cond
            [(and in-str (pair? (cdr cs)) (char=? (cadr cs) #\'))     ; '' escaped quote
             (write-char #\' out) (write-char #\' out) (loop (cddr cs) in-str n)]
            [else (write-char c out) (loop (cdr cs) (not in-str) n)])]
         [(and (char=? c #\?) (not in-str))
          (write-string (string-append "$" (number->string n)) out) (loop (cdr cs) in-str (add1 n))]
         [else (write-char c out) (loop (cdr cs) in-str n)])])))

(define (rw conn stmt)
  (if (and (string? stmt) (eq? (db-dialect conn) 'postgresql)) (pg-rewrite stmt) stmt))

(define (q-exec conn stmt . args)        (apply query-exec conn (rw conn stmt) args))
(define (q-rows conn stmt . args)        (apply query-rows conn (rw conn stmt) args))
(define (q-row conn stmt . args)         (apply query-row conn (rw conn stmt) args))
(define (q-maybe-row conn stmt . args)   (apply query-maybe-row conn (rw conn stmt) args))
(define (q-value conn stmt . args)       (apply query-value conn (rw conn stmt) args))
(define (q-maybe-value conn stmt . args) (apply query-maybe-value conn (rw conn stmt) args))
(define (q-list conn stmt . args)        (apply query-list conn (rw conn stmt) args))
(define (q-query conn stmt . args)       (apply query conn (rw conn stmt) args))
