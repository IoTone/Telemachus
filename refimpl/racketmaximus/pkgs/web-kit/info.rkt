#lang info

;; web-kit — a thin, opinionated wrapper over Racket's built-in web-server.
;; Deliberately small: the *server* is web-server (don't reinvent it); this just
;; removes boilerplate for JSON APIs. If we ever want batteries (sessions,
;; migrations, CSRF), adopt `koyo` rather than growing this.
(define collection "web-kit")
(define version "0.1.0")
(define deps '("base" "web-server-lib"))
(define pkg-desc "Thin JSON-API helpers over Racket's web-server")
