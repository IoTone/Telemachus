#lang info

;; The Telemachus app itself (CLIs under cli/, server under server/, shared
;; config.rkt). This is NOT a library to publish — it depends on the
;; spin-out-able packages under pkgs/ (cli-kit, db-kit, web-kit).
;;
;; Dev/CI setup (inside `nix develop`, which sets PLTCOLLECTS):
;;   export PLTCOLLECTS="$PWD/pkgs:"     # never `raco pkg install --link` these:
;;                                       # the collection names are global and a
;;                                       # link silently wins over PLTCOLLECTS for
;;                                       # any checkout that forgot to set it.
;;   raco make config.rkt cli/*.rkt server/*.rkt test/*.rkt
;;   raco exe -o dist/telemachus-<tool> cli/telemachus-<tool>.rkt  # standalone

(define collection "telemachus")
(define version "0.1.0")

;; External catalog deps (the local pkgs/* are installed via --link, above).
(define deps '("base" "web-server-lib" "db-lib"))

(define pkg-desc "Telemachus — Racket prototype (app: CLIs + server)")
