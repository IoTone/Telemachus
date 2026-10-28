#lang racket/base

;; #128 job 2: operator-facing variables are read through ONE accessor,
;; which tries TMACH_<name> and falls back to TELEMACHUS_<name>.
(require (only-in "../../config.rkt" tmach-env))

;; domain/time/zones.rkt — what the clock on somebody's wall says (issue #137).
;;
;; Every date computation in this tree was UTC: `(seconds->date secs #f)`,
;; uniformly, which is right for a stored timestamp and useless for scheduling
;; anything a person expects at a particular hour. This module is the one place
;; that knows about zones, and it holds NO database — it is a filesystem read and
;; arithmetic, so it is unit-testable without a server (peer.rkt's and
;; startup.rkt's move). The resolution of whose zone applies is the next module
;; up, domain/time/tz-policy.rkt.
;;
;; BUILT FROM THE SPEC AND PINNED TO VECTORS, which is sigv4.rkt's rule and for
;; the same reason: the alternative was a Racket package the Nix pin does not
;; carry, and a timezone that is subtly wrong twice a year is worse than none.
;; The oracle is the IANA database itself, read through Python's `zoneinfo` —
;; `test/zone-tests.rkt` carries its answers as literals, including the three
;; shapes a 60-minute assumption gets wrong: a 30-minute DST STEP (Lord Howe),
;; a 45-minute standard offset (Chatham), and a southern-hemisphere year where
;; summer time wraps the new year (Sao Paulo's history).
;;
;; TWO SOURCES IN EVERY FILE, AND THE SECOND IS THE ONE THAT MATTERS HERE.
;; tzdata is built "slim" now: the transition TABLE stops where a zone's rule
;; became regular (Europe/London's last entry is in the 1990s), and everything
;; after that is described by a POSIX TZ string in the file's FOOTER
;; (`GMT0BST,M3.5.0/1,M10.5.0`). A reader that only walks the table answers
;; today's question with a rule from thirty years ago — and a scheduler asks
;; exclusively about the future, so the footer is not an edge case here, it is
;; the normal path.

(require racket/file racket/list racket/string racket/path)

(provide zoneinfo-dir available-zones zone-exists?
         zone-offset zone-abbrev local-fields local->epoch
         days-from-civil civil-from-days)

;; ---- where the database is ----------------------------------------------------
;; `TELEMACHUS_ZONEINFO` first for a deployment that ships its own copy, then
;; TZDIR (what Nix sets when tzdata is on the closure), then the system path.
;; THE CONTAINER NEEDS THIS DECLARED: the image has no shell and no
;; /usr/share/zoneinfo, so without tzdata and TZDIR on the wrapper every zone
;; lookup would fail there while working on every developer's box.
(define (zoneinfo-dir)
  (define candidates
    (filter values (list (tmach-env "ZONEINFO")
                         (getenv "TZDIR")
                         "/usr/share/zoneinfo")))
  (for/first ([d (in-list candidates)]
              #:when (and (not (string=? d "")) (directory-exists? d)))
    d))

;; The zones are DERIVED FROM DISK, never a list in the source — the rule
;; `available` locales live by. An instance cannot offer a zone it has no data
;; for, and a tzdata upgrade needs no code change.
;;
;; A directory holds more than zones (zone.tab, leapseconds, the posix/ and
;; right/ mirrors), so membership is decided by the file's own MAGIC rather than
;; by its name.
(define SKIP-DIRS '("posix" "right"))
(define zone-cache (make-hash))      ; name -> parsed zone or 'bad
(define names-cache (box #f))

(define (tzif-file? p)
  (with-handlers ([exn:fail? (lambda (_) #f)])
    (call-with-input-file p (lambda (in) (equal? (read-bytes 4 in) #"TZif")))))

(define (available-zones)
  (or (unbox names-cache)
      (let ([d (zoneinfo-dir)])
        (define out
          (if (not d)
              '()
              (sort
               (let loop ([dir d] [prefix ""])
                 (append*
                  (for/list ([e (in-list (directory-list dir))])
                    (define name (path->string e))
                    (define full (build-path dir e))
                    (cond
                      [(and (directory-exists? full) (member name SKIP-DIRS)) '()]
                      [(directory-exists? full) (loop full (string-append prefix name "/"))]
                      [(tzif-file? full) (list (string-append prefix name))]
                      [else '()]))))
               string<?)))
        ;; UTC is in the list even with no database behind it, for the reason
        ;; `zone-exists?` says.
        (set-box! names-cache (if (member "UTC" out) out (cons "UTC" out)))
        (unbox names-cache))))


;; UTC IS ALWAYS KNOWN, with or without a database. It needs no data — the offset
;; is zero by definition — and it is the documented fallback every layer ends at,
;; so an instance refusing to let anybody SET the value it is already using would
;; be incoherent. Found by the Nix build sandbox, which has no tz database at all:
;; `timezone-problem "UTC"` refused, and on such a box nobody could set a
;; timezone at all.
(define (zone-exists? z)
  (or (and (string? z) (string=? z "UTC"))
      (and (zone-of z) #t)))

;; ---- the file -----------------------------------------------------------------
;; transitions : vector of epoch seconds, ascending
;; types       : vector of (utoff isdst abbrev) matching each transition
;; first-type  : what applies before the earliest transition
;; footer      : the POSIX rule for everything after the last transition, or #f
(struct zone (transitions types first-type footer) #:transparent)

(define (zone-of name)
  (define cached (hash-ref zone-cache name 'none))
  (cond
    [(eq? cached 'bad) #f]
    [(not (eq? cached 'none)) cached]
    [else
     (define z (with-handlers ([exn:fail? (lambda (_) #f)]) (read-zone name)))
     (hash-set! zone-cache name (or z 'bad))
     z]))

;; A zone name is a PATH SEGMENT list and arrives from a database row, so it is
;; whitelisted rather than escaped — blobs.rkt's digest rule. `..` is the whole
;; reason: this reads a file named by user input.
(define ZONE-RX #px"^[A-Za-z][A-Za-z0-9_+-]*(/[A-Za-z0-9_+-]+)*$")

(define (read-zone name)
  (define dir (zoneinfo-dir))
  (and dir
       (regexp-match? ZONE-RX name)
       (let ([p (apply build-path dir (string-split name "/"))])
         (and (file-exists? p)
              (call-with-input-file p parse-tzif)))))

(define (u8 in) (let ([b (read-byte in)]) (if (eof-object? b) (error 'tzif "truncated") b)))
(define (ube in n)
  (for/fold ([v 0]) ([_ (in-range n)]) (+ (* v 256) (u8 in))))
(define (sbe in n)
  (define v (ube in n))
  (define lim (arithmetic-shift 1 (- (* 8 n) 1)))
  (if (>= v lim) (- v (* 2 lim)) v))

(define (parse-tzif in)
  (unless (equal? (read-bytes 4 in) #"TZif") (error 'tzif "not a TZif file"))
  (define version (u8 in))
  (read-bytes 15 in)                                    ; reserved
  (define-values (isutcnt isstdcnt leapcnt timecnt typecnt charcnt)
    (values (ube in 4) (ube in 4) (ube in 4) (ube in 4) (ube in 4) (ube in 4)))
  (cond
    ;; A v2+ file carries the whole thing twice: a 32-bit block for ancient
    ;; readers and a 64-bit one. Skip the first outright — reading it and then
    ;; "upgrading" is how a 2038 bug gets written in 2026.
    [(not (= version 0))
     (skip-block in 4 timecnt typecnt charcnt leapcnt isstdcnt isutcnt)
     (unless (equal? (read-bytes 4 in) #"TZif") (error 'tzif "no 64-bit block"))
     (u8 in) (read-bytes 15 in)
     (define-values (u2 s2 l2 t2 ty2 c2)
       (values (ube in 4) (ube in 4) (ube in 4) (ube in 4) (ube in 4) (ube in 4)))
     (define z (read-block in 8 t2 ty2 c2 l2 s2 u2))
     (zone (zone-transitions z) (zone-types z) (zone-first-type z) (read-footer in))]
    [else (read-block in 4 timecnt typecnt charcnt leapcnt isstdcnt isutcnt)]))

(define (skip-block in w timecnt typecnt charcnt leapcnt isstdcnt isutcnt)
  (read-bytes (+ (* timecnt w) timecnt (* typecnt 6) charcnt
                 (* leapcnt (+ w 4)) isstdcnt isutcnt)
              in))

(define (read-block in w timecnt typecnt charcnt leapcnt isstdcnt isutcnt)
  (define times (for/vector ([_ (in-range timecnt)]) (sbe in w)))
  (define idxs  (for/vector ([_ (in-range timecnt)]) (u8 in)))
  (define infos (for/vector ([_ (in-range typecnt)])
                  (let* ([utoff (sbe in 4)] [isdst (u8 in)] [desig (u8 in)])
                    (list utoff (= isdst 1) desig))))
  (define chars (read-bytes charcnt in))
  (read-bytes (+ (* leapcnt (+ w 4)) isstdcnt isutcnt) in)
  (define (abbrev-at i)
    (define bs (subbytes chars i))
    (define end (or (for/first ([k (in-range (bytes-length bs))] #:when (= 0 (bytes-ref bs k))) k)
                    (bytes-length bs)))
    (bytes->string/utf-8 (subbytes bs 0 end)))
  (define (type-of i)
    (define t (vector-ref infos i))
    (list (car t) (cadr t) (abbrev-at (caddr t))))
  (define types (for/vector ([i (in-vector idxs)]) (type-of i)))
  ;; Before the first transition: the first NON-DST type, which is what the
  ;; spec says to use and is not always type 0.
  (define first-type
    (or (for/first ([i (in-range (vector-length infos))]
                    #:when (not (cadr (vector-ref infos i))))
          (type-of i))
        (and (> (vector-length infos) 0) (type-of 0))
        (list 0 #f "UTC")))
  (zone times types first-type #f))

(define (read-footer in)
  (define line (read-line in 'any))
  (define s (if (eof-object? line) "" (string-trim line)))
  (and (not (string=? s "")) (parse-posix-tz s)))

;; ---- the POSIX TZ footer ------------------------------------------------------
;; std offset [dst [offset] [,start[/time],end[/time]]]
;;
;; THE SIGN IS INVERTED: `PST8` means UTC-8. POSIX states the offset you ADD to
;; local time to get UTC, which is the opposite of what everything else in this
;; file means by an offset, and getting it backwards is a sixteen-hour error that
;; still looks like a plausible time of day.
(struct posix-rule (std-off std-abbr dst-off dst-abbr start end) #:transparent)
;; start/end: (list kind m w d secs) — kind 'M | 'J | 'n

(define NAME-RX #px"^(<[^>]+>|[A-Za-z]{3,})")
(define OFF-RX  #px"^([+-]?)([0-9]{1,3})(?::([0-9]{1,2}))?(?::([0-9]{1,2}))?")

(define (strip-brackets s)
  (if (and (> (string-length s) 1) (char=? (string-ref s 0) #\<))
      (substring s 1 (- (string-length s) 1))
      s))

(define (parse-posix-tz s)
  (define (take-name str)
    (define m (regexp-match NAME-RX str))
    (and m (values* (strip-brackets (car m)) (substring str (string-length (car m))))))
  (define (take-offset str)
    (define m (regexp-match OFF-RX str))
    (and m
         (let* ([sign (if (string=? (cadr m) "-") -1 1)]
                [h (string->number (caddr m))]
                [mi (or (and (cadddr m) (string->number (cadddr m))) 0)]
                [se (or (and (list-ref m 4) (string->number (list-ref m 4))) 0)]
                ;; negated here, once: everything downstream means "seconds east"
                [off (* -1 sign (+ (* h 3600) (* mi 60) se))])
           (values* off (substring str (string-length (car m)))))))
  (with-handlers ([exn:fail? (lambda (_) #f)])
    (define-values (std-abbr r1) (take-name s))
    (define-values (std-off r2) (take-offset r1))
    (cond
      [(string=? r2 "") (posix-rule std-off std-abbr #f #f #f #f)]
      [else
       (define-values (dst-abbr r3) (take-name r2))
       (define-values (dst-off r4)
         (if (or (string=? r3 "") (char=? (string-ref r3 0) #\,))
             ;; "one hour ahead" is the POSIX default when no DST offset is given
             (values* (+ std-off 3600) r3)
             (take-offset r3)))
       (define parts (string-split r4 ","))
       (cond
         [(< (length parts) 2) (posix-rule std-off std-abbr dst-off dst-abbr #f #f)]
         [else
          (posix-rule std-off std-abbr dst-off dst-abbr
                      (parse-when (car parts)) (parse-when (cadr parts)))])])))

;; `values*` exists because `(and m (values …))` is not legal in an expression
;; position that expects one value; the handlers above turn a parse failure into
;; #f, so a raise is the right failure here.
(define (values* a b) (values a b))

;; Mm.w.d/time | Jn/time | n/time — the time defaults to 02:00:00 and may be
;; negative or past 24h (tzdata really does use /24 and /2:45).
(define (parse-when str)
  (define bits (string-split str "/"))
  (define spec (car bits))
  (define secs
    (if (null? (cdr bits))
        7200
        (let* ([t (cadr bits)]
               [neg? (and (> (string-length t) 0) (char=? (string-ref t 0) #\-))]
               [t2 (if (or neg? (and (> (string-length t) 0) (char=? (string-ref t 0) #\+)))
                       (substring t 1) t)]
               [f (map string->number (string-split t2 ":"))]
               [h (or (and (pair? f) (car f)) 0)]
               [mi (if (> (length f) 1) (list-ref f 1) 0)]
               [se (if (> (length f) 2) (list-ref f 2) 0)]
               [v (+ (* h 3600) (* mi 60) se)])
          (if neg? (- v) v))))
  (cond
    [(char=? (string-ref spec 0) #\M)
     (define f (map string->number (string-split (substring spec 1) ".")))
     (list 'M (car f) (cadr f) (caddr f) secs)]
    [(char=? (string-ref spec 0) #\J)
     (list 'J (string->number (substring spec 1)) 0 0 secs)]
    [else (list 'n (string->number spec) 0 0 secs)]))

;; ---- civil calendar ------------------------------------------------------------
;; Hinnant's days_from_civil / civil_from_days, proleptic Gregorian, no table and
;; no library. Both directions are needed: fields from an instant, and an instant
;; from fields — the second is what "07:00 on a Monday" requires.
(define (days-from-civil y m d)
  (define y* (if (<= m 2) (- y 1) y))
  (define era (quotient (if (>= y* 0) y* (- y* 399)) 400))
  (define yoe (- y* (* era 400)))
  (define doy (+ (quotient (+ (* 153 (+ m (if (> m 2) -3 9))) 2) 5) (- d 1)))
  (define doe (+ (* yoe 365) (quotient yoe 4) (- (quotient yoe 100)) doy))
  (+ (* era 146097) doe -719468))

(define (civil-from-days z)
  (define z* (+ z 719468))
  (define era (quotient (if (>= z* 0) z* (- z* 146096)) 146097))
  (define doe (- z* (* era 146097)))
  (define yoe (quotient (- doe (quotient doe 1460) (- (quotient doe 36524)) (quotient doe 146096)) 365))
  (define y (+ yoe (* era 400)))
  (define doy (- doe (+ (* 365 yoe) (quotient yoe 4) (- (quotient yoe 100)))))
  (define mp (quotient (+ (* 5 doy) 2) 153))
  (define d (+ (- doy (quotient (+ (* 153 mp) 2) 5)) 1))
  (define m (+ mp (if (< mp 10) 3 -9)))
  (values (if (<= m 2) (+ y 1) y) m d))

(define (leap? y) (and (= 0 (modulo y 4)) (or (not (= 0 (modulo y 100))) (= 0 (modulo y 400)))))
(define (dow-of-days days) (modulo (+ days 4) 7))      ; 1970-01-01 was a Thursday

;; The epoch second of a POSIX rule's transition in a given local year. The rule
;; is written in LOCAL time, so the caller adds the offset in force just before
;; the change — std for the spring transition, dst for the autumn one, which is
;; what POSIX says and what makes the comparison below right at the boundary.
(define (rule-instant r y base-off)
  (define kind (car r))
  (define secs (list-ref r 4))
  (define day
    (cond
      [(eq? kind 'M)
       (define m (list-ref r 1)) (define w (list-ref r 2)) (define d (list-ref r 3))
       (define first-of-month (days-from-civil y m 1))
       (define shift (modulo (- d (dow-of-days first-of-month)) 7))
       (define candidate (+ first-of-month shift (* 7 (- w 1))))
       ;; w = 5 means "the last such weekday", which may be the 4th
       (define dim (days-in-month y m))
       (if (>= (- candidate first-of-month) dim) (- candidate 7) candidate)]
      [(eq? kind 'J)
       ;; Julian day 1-365, 29 February NEVER counted
       (define n (list-ref r 1))
       (define jan1 (days-from-civil y 1 1))
       (+ jan1 (- n 1) (if (and (> n 59) (leap? y)) 1 0))]
      [else (+ (days-from-civil y 1 1) (list-ref r 1))]))
  (- (+ (* day 86400) secs) base-off))

(define (days-in-month y m)
  (cond [(member m '(1 3 5 7 8 10 12)) 31]
        [(member m '(4 6 9 11)) 30]
        [(leap? y) 29]
        [else 28]))

;; -> (values utoff abbrev) from the footer rule at instant t
(define (posix-at r t)
  (cond
    [(or (not (posix-rule-dst-off r)) (not (posix-rule-start r)))
     (values (posix-rule-std-off r) (posix-rule-std-abbr r))]
    [else
     (define-values (y _m _d) (civil-from-days (floor (/ (+ t (posix-rule-std-off r)) 86400))))
     (define start (rule-instant (posix-rule-start r) y (posix-rule-std-off r)))
     (define end   (rule-instant (posix-rule-end r)   y (posix-rule-dst-off r)))
     (define dst?
       (if (< start end)
           (and (>= t start) (< t end))               ; northern hemisphere
           (or (>= t start) (< t end))))              ; southern: summer wraps the year
     (if dst?
         (values (posix-rule-dst-off r) (posix-rule-dst-abbr r))
         (values (posix-rule-std-off r) (posix-rule-std-abbr r)))]))

;; ---- the public answers --------------------------------------------------------
;; -> (values utoff abbrev) for a zone at an instant, or (values 0 "UTC") for a
;; zone with no data. NEVER raises: this is read on the request path and by the
;; scheduler's tick, and a missing zone file must not take either down.
(define (zone-info z t)
  (define Z (zone-of z))
  (cond
    [(not Z) (values 0 "UTC")]
    [else
     (define ts (zone-transitions Z))
     (define n (vector-length ts))
     (define last-t (and (> n 0) (vector-ref ts (- n 1))))
     (cond
       ;; THE FOOTER WINS PAST THE LAST TRANSITION, which for a scheduler is
       ;; almost always the case — see the header.
       [(and (zone-footer Z) (or (= n 0) (>= t last-t)))
        (posix-at (zone-footer Z) t)]
       [(or (= n 0) (< t (vector-ref ts 0)))
        (values (car (zone-first-type Z)) (caddr (zone-first-type Z)))]
       [else
        (define i (let loop ([lo 0] [hi (- n 1)])
                    (if (>= lo hi) lo
                        (let ([mid (quotient (+ lo hi 1) 2)])
                          (if (<= (vector-ref ts mid) t) (loop mid hi) (loop lo (- mid 1)))))))
        (define ty (vector-ref (zone-types Z) i))
        (values (car ty) (caddr ty))])]))

(define (zone-offset z t) (let-values ([(off _a) (zone-info z t)]) off))
(define (zone-abbrev z t) (let-values ([(_o a) (zone-info z t)]) a))

;; Local wall-clock fields: (values year month day hour minute second dow)
(define (local-fields z t)
  (define local (+ t (zone-offset z t)))
  (define days (floor (/ local 86400)))
  (define rem (- local (* days 86400)))
  (define-values (y m d) (civil-from-days days))
  (values y m d (quotient rem 3600) (quotient (modulo rem 3600) 60) (modulo rem 60)
          (dow-of-days days)))

;; The inverse, and the half with the honest answers in it:
;; -> (values epoch status), status being
;;    'ok         — exactly one instant has these local fields
;;    'nonexistent — the clocks jumped over it (spring forward); the epoch
;;                   returned is the instant of the jump, and a CALLER DECIDES
;;                   what that means. #135's tick records it as a skip.
;;    'ambiguous  — the clocks repeated it (autumn); the FIRST occurrence is
;;                  returned, because firing early and once beats firing twice.
;;
;; TWO PROBES, ONE EITHER SIDE OF THE DAY, and the reason is that the offset
;; depends on the instant while the instant is what we are solving for. No DST
;; shift exceeds a couple of hours, so the offsets 24h before and 24h after the
;; naive reading bracket whatever happens in between; each gives a candidate
;; instant, and a candidate is REAL only if the offset actually in force there
;; is the one used to compute it. Counting the real ones is what distinguishes
;; the three answers — a single round-trip check cannot, because in the repeated
;; hour BOTH candidates round-trip and the naive version silently reports `ok`
;; for whichever it happened to try first (measured: it returned the SECOND
;; occurrence of London's repeated 01:30, i.e. it fired an hour late).
(define (local->epoch z y m d [hh 0] [mm 0] [ss 0])
  (define naive (+ (* (days-from-civil y m d) 86400) (* hh 3600) (* mm 60) ss))
  (define offs (remove-duplicates (list (zone-offset z (- naive 86400))
                                        (zone-offset z (+ naive 86400)))))
  (define real (sort (for/list ([o (in-list offs)]
                                #:when (= o (zone-offset z (- naive o))))
                       (- naive o))
                     <))
  (cond
    [(= (length real) 1) (values (car real) 'ok)]
    ;; the clocks repeated this local time: the FIRST occurrence, because firing
    ;; early and once beats firing twice
    [(> (length real) 1) (values (car real) 'ambiguous)]
    ;; the clocks jumped over it. The instant returned is the one the
    ;; PRE-transition offset implies — the moment the jump happened — and a
    ;; CALLER decides what that means. #135's tick records it as a skip rather
    ;; than inventing an hour that did not exist.
    [else (values (apply max (for/list ([o (in-list offs)]) (- naive o))) 'nonexistent)]))
