#lang racket/base

;; test/assets-tests.rkt — locally-hosted brand assets (slice 42): upload validation
;; (type + size), base64/data-URI handling, round-trip serve, RBAC, delete.
;; raco test test/assets-tests.rkt

(require rackunit
         db net/base64
         db-kit/migrate
         "../domain/db/migrations.rkt"
         "../domain/authz/authz.rkt"
         "../domain/beta/assets.rkt")

(define (fresh) (define c (sqlite3-connect #:database 'memory)) (migrate! c all-migrations) c)
(define (b64 bs) (bytes->string/latin-1 (base64-encode bs #"")))

(test-case "mime allowlist + kind classification"
  (check-true (asset-mime-ok? "image/png"))
  (check-true (asset-mime-ok? "font/woff2"))
  (check-false (asset-mime-ok? "application/zip"))
  (check-equal? (asset-kind-for "image/svg+xml") "image")
  (check-equal? (asset-kind-for "font/ttf") "font")
  (check-equal? (asset-kind-for "text/html") #f))

(test-case "upload → serve round-trip (bytes + mime preserved)"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice"))
  (define alice (user-principal c uid tid))
  (define id (asset-store! c alice #:mime "image/png" #:filename "logo.png" #:data-base64 (b64 #"\x89PNG\r\n\x1a\n")))
  (define-values (mime bytes) (asset-get c id))
  (check-equal? mime "image/png")
  (check-equal? bytes #"\x89PNG\r\n\x1a\n")
  (check-equal? (length (asset-list c alice)) 1)
  ;; a full data: URI payload is accepted (prefix stripped)
  (define id2 (asset-store! c alice #:mime "image/gif" #:data-base64 (string-append "data:image/gif;base64," (b64 #"GIF89a"))))
  (define-values (m2 b2) (asset-get c id2))
  (check-equal? b2 #"GIF89a")
  (check-equal? (length (asset-list c alice)) 2)
  ;; missing id → (#f #f)
  (define-values (m3 b3) (asset-get c "nope"))
  (check-false m3))

(test-case "validation: bad type, oversize, empty"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice"))
  (define alice (user-principal c uid tid))
  (check-exn exn:fail:user? (lambda () (asset-store! c alice #:mime "application/zip" #:data-base64 (b64 #"PK"))))
  (check-exn exn:fail:user? (lambda () (asset-store! c alice #:mime "image/png" #:data-base64 "")))
  ;; > 2 MiB image is rejected
  (define big (b64 (make-bytes (+ 1 (* 2 1024 1024)) 65)))
  (check-exn exn:fail:user? (lambda () (asset-store! c alice #:mime "image/png" #:data-base64 big))))

(test-case "RBAC + delete"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice"))
  (define alice (user-principal c uid tid))
  (define bob (create-user! c #:username "bob"))
  (add-member! c #:user bob #:team tid #:role "viewer")
  (define v (user-principal c bob tid))
  (check-exn exn:fail:forbidden? (lambda () (asset-store! c v #:mime "image/png" #:data-base64 (b64 #"x"))))
  (define id (asset-store! c alice #:mime "image/png" #:data-base64 (b64 #"x")))
  (check-exn exn:fail:forbidden? (lambda () (asset-list c v)))
  (check-true (asset-delete! c alice id))
  (check-equal? (length (asset-list c alice)) 0))
