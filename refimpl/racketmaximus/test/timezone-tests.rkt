#lang racket/base

;; test/timezone-tests.rkt — zones (#137), pinned to the IANA database itself.
;;
;; THE ORACLE IS NOT THIS CODE. Every expected number below was produced by
;; Python's `zoneinfo` reading the same tzdata, and is carried here as a literal
;; — sigv4.rkt's rule, and the only honest way to test a reimplementation of a
;; specification. A test that recomputed the answer with the module under test
;; would agree with any bug it contains.
;;
;; The cases are chosen for the assumptions a 60-minute, northern-hemisphere
;; reader makes without noticing:
;;   • Australia/Lord_Howe — a THIRTY-minute DST step
;;   • Pacific/Chatham     — a 45-minute standard offset
;;   • a 2030 instant      — past the transition table, so only the file's
;;                           POSIX footer can answer it
;;
;;   raco test test/timezone-tests.rkt

(require rackunit db-kit/portable
         db-kit/migrate
         "../domain/db/migrations.rkt"
         "db-fixture.rkt"
         "../domain/authz/authz.rkt"
         "../domain/time/zones.rkt"
         "../domain/time/tz-policy.rkt")

(define (fresh) (define c (fresh-db #:migrate? #f)) (migrate! c all-migrations) c)

;; zone → (list (instant offset abbreviation) …), from Python's zoneinfo
(define VECTORS
  (list
   (list "UTC"                 '((1768478400 0 "UTC") (1784116800 0 "UTC") (0 0 "UTC")))
   (list "Europe/London"       '((1768478400 0 "GMT") (1784116800 3600 "BST")
                                 (644198400 3600 "BST")
                                 ;; 2030, past the last transition in the file:
                                 ;; answered by the POSIX footer or not at all
                                 (1920067200 0 "GMT")))
   (list "America/Los_Angeles" '((1768478400 -28800 "PST") (1784116800 -25200 "PDT")
                                 (0 -28800 "PST") (1920067200 -28800 "PST")))
   (list "Asia/Tokyo"          '((1768478400 32400 "JST") (1784116800 32400 "JST")))
   ;; a 30-MINUTE DST step, and a historical offset that is neither
   (list "Australia/Lord_Howe" '((1768478400 39600 "+11") (1784116800 37800 "+1030")
                                 (0 36000 "AEST") (1920067200 39600 "+11")))
   (list "Asia/Kolkata"        '((1768478400 19800 "IST") (0 19800 "IST")))
   ;; a 45-MINUTE standard offset
   (list "Pacific/Chatham"     '((1768478400 49500 "+1345") (1784116800 45900 "+1245")
                                 (1920067200 49500 "+1345")))))

(test-case "offsets and abbreviations match the IANA database"
  ;; A box with no tz database answers UTC for everything, by design; there is
  ;; nothing to compare there, so say so rather than passing vacuously.
  (cond
    [(not (zoneinfo-dir))
     ;; LOUD, because a silent skip is how a path goes unexercised. The build
     ;; sandbox and the container both carry tzdata now (nix/telemachus.nix), so
     ;; this branch means somebody removed it.
     (eprintf "timezone-tests: NO TZ DATABASE — the IANA vectors did not run\n")
     (check-true #t)]
    [else
     (for ([v (in-list VECTORS)])
       (for ([c (in-list (cadr v))])
         (check-equal? (zone-offset (car v) (car c)) (cadr c)
                       (format "~a offset at ~a" (car v) (car c)))
         (check-equal? (zone-abbrev (car v) (car c)) (caddr c)
                       (format "~a abbreviation at ~a" (car v) (car c)))))]))

(test-case "a local wall-clock time becomes an instant, and says when it cannot"
  (cond
    [(not (zoneinfo-dir))
     (eprintf "timezone-tests: NO TZ DATABASE — the local->epoch cases did not run\n")
     (check-true #t)]
    [else
     ;; (zone y m d hh mm expected-epoch expected-status), oracle as above
     (define cases
       (list
        ;; the hour the clocks jump OVER: there is no such instant
        (list "Europe/London" 2027 3 28 1 30 1806197400 'nonexistent)
        ;; …and the hour they REPEAT: two instants, and we take the first
        (list "Europe/London" 2027 10 31 1 30 1824942600 'ambiguous)
        (list "Europe/London" 2027 7 1 7 0 1814421600 'ok)
        (list "America/Los_Angeles" 2027 3 14 2 30 1805020200 'nonexistent)
        (list "America/Los_Angeles" 2027 11 7 1 30 1825576200 'ambiguous)
        ;; a 30-minute jump: 02:15 does not exist on Lord Howe that morning
        (list "Australia/Lord_Howe" 2026 10 4 2 15 1791042300 'nonexistent)
        (list "Asia/Tokyo" 2026 12 25 9 0 1798156800 'ok)
        (list "Pacific/Chatham" 2027 9 26 2 50 1821881100 'nonexistent)))
     (for ([c (in-list cases)])
       (define-values (t st)
         (local->epoch (car c) (list-ref c 1) (list-ref c 2) (list-ref c 3)
                       (list-ref c 4) (list-ref c 5)))
       (check-equal? t (list-ref c 6) (format "~a instant" (car c)))
       (check-equal? st (list-ref c 7) (format "~a status" (car c))))]))

(test-case "local fields round-trip, and the calendar arithmetic is its own property"
  ;; 1970-01-01 is day 0 and was a Thursday; the rest is Hinnant's algorithm,
  ;; which is worth pinning on its own because every other answer rides on it.
  (check-equal? (days-from-civil 1970 1 1) 0)
  (check-equal? (days-from-civil 2026 10 22) 20748)
  (check-equal? (days-from-civil 2000 2 29) 11016)
  (check-equal? (days-from-civil 1900 1 1) -25567)
  (for ([d (in-list '(0 20748 11016 -25567 100000))])
    (define-values (y m dd) (civil-from-days d))
    (check-equal? (days-from-civil y m dd) d))
  (when (zoneinfo-dir)
    (define-values (y m d hh mm ss dow) (local-fields "Asia/Tokyo" 1798156800))
    (check-equal? (list y m d hh mm ss) '(2026 12 25 9 0 0))
    (check-equal? dow 5)))                              ; a Friday

(test-case "a zone name is whitelisted, not escaped"
  ;; It arrives from a database row and becomes a PATH, so traversal is the
  ;; thing to refuse — blobs.rkt's digest rule.
  (check-false (zone-exists? "../../etc/passwd"))
  (check-false (zone-exists? "/etc/passwd"))
  (check-false (zone-exists? "Europe/../../etc/passwd"))
  (check-false (zone-exists? ""))
  (when (zoneinfo-dir)
    (check-true (zone-exists? "Europe/London"))
    ;; derived from disk, never a list in the source
    (check-true (> (length (available-zones)) 100))
    (check-true (and (member "Asia/Tokyo" (available-zones)) #t))))

(test-case "an unknown zone is REFUSED, never silently substituted"
  ;; UTC is acceptable with or without a database: it needs no data and is the
  ;; fallback every layer ends at. The Nix build sandbox has no tz database, and
  ;; this assertion is what found that the first version refused it there — so
  ;; the sandbox now gets tzdata AND this stays unguarded deliberately.
  (check-false (timezone-problem "UTC"))
  (check-true (string? (timezone-problem "")))
  (check-true (string? (timezone-problem "Europe/Berlín")))
  (check-true (string? (timezone-problem "PST")))        ; an abbreviation is not a zone
  (when (zoneinfo-dir) (check-false (timezone-problem "Pacific/Chatham"))))

(test-case "the layers fall back, and DO NOT tighten"
  (define c (fresh))
  (define-values (uid tid) (bootstrap! c #:username "alice"))
  ;; nothing configured anywhere: UTC, and the instance behaves as it did before
  ;; this module existed
  (check-equal? (timezone-for c #:user uid) "UTC")
  (check-equal? (hash-ref (timezone-report c #:user uid) 'source) "default")

  (set-instance-timezone! c "Europe/London")
  (check-equal? (timezone-for c #:user uid) "Europe/London")
  (check-equal? (hash-ref (timezone-report c #:user uid) 'source) "instance")

  (define oid (create-org! c #:name "Acme" #:slug "acme"))
  (set-org-timezone! c oid "Asia/Tokyo")
  (check-equal? (timezone-for c #:user uid #:org oid) "Asia/Tokyo")
  (check-equal? (hash-ref (timezone-report c #:user uid #:org oid) 'source) "org")

  ;; A PERSON'S OWN CHOICE WINS over their company's and the instance's. This is
  ;; branding's rule, not a session policy's: a timezone is not a control, and
  ;; nobody is protected by being forced into the wrong clock. If this ever
  ;; starts reporting "org", somebody has made it tighten.
  (set-user-timezone! c uid "America/Los_Angeles")
  (check-equal? (timezone-for c #:user uid #:org oid) "America/Los_Angeles")
  (check-equal? (hash-ref (timezone-report c #:user uid #:org oid) 'source) "user")

  ;; clearing the company's leaves the user's alone
  (clear-org-timezone! c oid)
  (check-equal? (timezone-for c #:user uid #:org oid) "America/Los_Angeles")
  ;; …and a colleague with no zone of their own falls back a layer
  (check-equal? (timezone-for c #:org oid) "Europe/London")

  ;; the team-shaped caller (the scheduler's tick) resolves the org itself
  (check-equal? (timezone-for-team c tid #:user uid) "America/Los_Angeles"))

(test-case "a rendered local timestamp carries its own offset"
  (when (zoneinfo-dir)
    (check-equal? (format-local "Asia/Tokyo" 1798156800) "2026-12-25T09:00:00+09:00")
    (check-equal? (format-local "Europe/London" 1784116800) "2026-07-15T13:00:00+01:00")
    (check-equal? (format-local "America/Los_Angeles" 1768478400) "2026-01-15T04:00:00-08:00")
    ;; a 45-minute offset is not a rounding error
    (check-equal? (format-local "Pacific/Chatham" 1768478400) "2026-01-16T01:45:00+13:45")))
