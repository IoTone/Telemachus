#lang racket/base

;; domain/db/nulls.rkt — SQL NULL at the edge of a read (#110 r5).
;;
;; `nz` was hand-written FOURTEEN times across the tree. The issue counted
;; eleven and called it a mechanical win; it is not quite, because the copies
;; were not all the same function and a single `nz` cannot be all of them. There
;; are three behaviours, and they are here under three names rather than folded
;; into one that would be wrong for eleven call sites or for three:
;;
;;   • `nz` — SQL NULL becomes `'null`, the jsexpr null. This is what a row
;;     being rendered into JSON wants, and it is eleven of the fourteen.
;;   • `nz/false` — SQL NULL becomes `#f`, for a caller that branches on the
;;     value in Racket rather than shipping it. It was spelled two different
;;     ways, `(if (sql-null? v) #f v)` in review.rkt and
;;     `(and v (not (sql-null? v)) v)` in authz.rkt, which are the SAME function
;;     on every input — the second only looks stricter.
;;   • `nz/string` — `#f` or SQL NULL becomes `""`, anything else is formatted.
;;     One caller, and it is a different job: building a string, not answering
;;     whether there was a value.
;;
;; `sql-null?` comes from db-kit/portable, which is the require every module in
;; this tree uses in place of `db` (it rewrites `?` to `$n` on PostgreSQL).

(provide nz nz/false nz/string)

(require (only-in db-kit/portable sql-null?))

(define (nz v) (if (sql-null? v) 'null v))
(define (nz/false v) (if (sql-null? v) #f v))
(define (nz/string v) (if (or (not v) (sql-null? v)) "" (format "~a" v)))
