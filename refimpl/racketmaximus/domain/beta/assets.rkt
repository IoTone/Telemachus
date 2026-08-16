#lang racket/base

;; domain/beta/assets.rkt — locally-hosted brand assets for the skinnable onboarding
;; landing (slice 42): logo, hero image, and an optional custom font. Uploaded by an
;; admin, stored base64 in the DB, and served from our own origin as asset://<id>.
;; No external URLs: a public beta page must not leak a prospect's IP to a CDN, and
;; assets stay deterministic with the deployment. See docs/design/beta-onboarding-experience.md §4.

(require db
         net/base64
         "../db/id.rkt"
         "../authz/authz.rkt")

(provide asset-mime-ok? asset-kind-for asset-limit
         asset-store! asset-get asset-list asset-delete!)

;; allowlisted content types → kind, with per-kind byte caps
(define IMAGE-MIMES '("image/png" "image/jpeg" "image/webp" "image/gif" "image/svg+xml"))
(define FONT-MIMES  '("font/woff2" "font/woff" "font/ttf" "font/otf"
                      "application/font-woff" "application/x-font-ttf" "application/vnd.ms-opentype"))
(define IMAGE-LIMIT (* 2 1024 1024))   ; 2 MiB
(define FONT-LIMIT  (* 2 1024 1024))   ; 2 MiB

(define (asset-mime-ok? mime) (and (or (member mime IMAGE-MIMES) (member mime FONT-MIMES)) #t))
(define (asset-kind-for mime) (cond [(member mime IMAGE-MIMES) "image"] [(member mime FONT-MIMES) "font"] [else #f]))
(define (asset-limit kind) (if (string=? kind "font") FONT-LIMIT IMAGE-LIMIT))

;; store a base64-encoded upload; validates type + decoded size. settings:manage.
;; data-base64 may be a bare base64 string or a full data: URI (prefix is stripped).
;; returns the new asset id.
(define (asset-store! conn p #:mime mime #:filename [filename ""] #:data-base64 data-base64)
  (require-perm conn p "settings:manage")
  (define kind (asset-kind-for mime))
  (unless kind (raise-user-error 'asset-store! "unsupported content type: ~a" mime))
  (define b64 (let ([m (regexp-match #rx"^data:[^;,]*;base64,(.*)$" data-base64)]) (if m (cadr m) data-base64)))
  (define bytes
    (with-handlers ([exn:fail? (lambda (_) (raise-user-error 'asset-store! "invalid base64 payload"))])
      (base64-decode (string->bytes/utf-8 b64))))
  (define size (bytes-length bytes))
  (when (> size (asset-limit kind))
    (raise-user-error 'asset-store! "~a too large: ~a bytes (max ~a)" kind size (asset-limit kind)))
  (when (= size 0) (raise-user-error 'asset-store! "empty upload"))
  (define aid (new-id))
  (query-exec conn
    "INSERT INTO onboarding_assets (id, team_id, kind, mime, filename, size, data) VALUES (?, ?, ?, ?, ?, ?, ?)"
    aid (principal-team-id p) kind mime filename size (bytes->string/latin-1 (base64-encode bytes #"")))
  aid)

;; PUBLIC (no principal) — the landing is public, so assets must be fetchable by id.
;; ids are unguessable UUIDs. Returns (values mime bytes) or (values #f #f).
(define (asset-get conn id)
  (define r (query-maybe-row conn "SELECT mime, data FROM onboarding_assets WHERE id = ?" id))
  (if r
      (values (vector-ref r 0)
              (base64-decode (string->bytes/utf-8 (vector-ref r 1))))
      (values #f #f)))

(define (asset-list conn p)
  (require-perm conn p "settings:manage")
  (for/list ([r (in-list (query-rows conn
                          "SELECT id, kind, mime, filename, size, created_at FROM onboarding_assets WHERE team_id = ? ORDER BY created_at DESC"
                          (principal-team-id p)))])
    (hasheq 'id (vector-ref r 0) 'kind (vector-ref r 1) 'mime (vector-ref r 2)
            'filename (vector-ref r 3) 'size (vector-ref r 4) 'created_at (vector-ref r 5))))

(define (asset-delete! conn p id)
  (require-perm conn p "settings:manage")
  (query-exec conn "DELETE FROM onboarding_assets WHERE id = ? AND team_id = ?" id (principal-team-id p))
  #t)
