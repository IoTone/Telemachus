#lang info

;; The Telemachus app itself (CLIs under cli/, server under server/, shared
;; config.rkt). This is NOT a library to publish — it depends on the
;; spin-out-able packages under pkgs/ (cli-kit, db-kit, web-kit).
;;
;; Dev/CI setup:
;;   raco pkg install --link pkgs/cli-kit pkgs/db-kit pkgs/web-kit
;;   raco make config.rkt cli/*.rkt server/*.rkt test/*.rkt
;;   raco exe -o dist/telemachus-<tool> cli/telemachus-<tool>.rkt  # standalone

(define collection "telemachus")
(define version "0.1.0")

;; External catalog deps (the local pkgs/* are installed via --link, above).
(define deps '("base" "web-server-lib" "db-lib"))

(define pkg-desc "Telemachus — Racket prototype (app: CLIs + server)")
