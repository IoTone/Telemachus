#lang racket/base

;; domain/beta/antispam.rkt — dependency-free, self-hosted anti-abuse for the PUBLIC
;; beta signup. No third-party CAPTCHA (privacy-first): everything is in-house and
;; deterministic. Layers (checked cheapest-first, all BEFORE any DB write or LLM
;; token spend):
;;   1. rate limit      — per-key sliding window + global cap
;;   2. signed challenge — must GET /api/beta/challenge first; HMAC-ish keyed, aged,
;;                         single-use (kills direct-POST floods + replay)
;;   3. honeypot        — a field bots fill and humans never see
;;   4. min fill-time   — reject submissions faster than a human could fill the form
;;   5. proof-of-work   — hashcash over a hash matched in Racket + JS (works over
;;                        plain HTTP, no SubtleCrypto); makes mass signups cost CPU
;;   6. heuristics      — email validity, disposable domains
;; Every function takes an explicit `now` (seconds) so it's testable without a clock.

(require racket/string
         file/sha1
         "../db/id.rkt")     ; random-token

(provide make-limiter limiter-allow?
         issue-challenge verify-challenge new-used-set
         powhash verify-pow pow-of
         valid-email? disposable-email?
         bump-blocked! blocked-stats)

;; ---- rate limiter (sliding window) ------------------------------------------
;; a limiter is (box hash key -> (listof seconds))
(define (make-limiter) (box (hash)))
(define (limiter-allow? lim key now #:max [mx 5] #:window [win 60])
  (define h (unbox lim))
  (define recent (filter (lambda (t) (> t (- now win))) (hash-ref h key '())))
  (cond
    [(>= (length recent) mx) (set-box! lim (hash-set h key recent)) #f]
    [else (set-box! lim (hash-set h key (cons now recent))) #t]))

;; ---- signed, aged, single-use challenge -------------------------------------
;; token = "nonce.issued.mac"  ; mac = sha1(secret ":" nonce ":" issued)  (keyed digest)
(define (mac secret nonce issued)
  (sha1 (open-input-string (string-append secret ":" nonce ":" (number->string issued)))))

(define (issue-challenge #:secret secret #:now now #:difficulty [difficulty 16])
  (define nonce (random-token))
  (hasheq 'challenge (string-append nonce "." (number->string now) "." (mac secret nonce now))
          'nonce nonce 'difficulty difficulty))

(define (new-used-set) (box (hash)))   ; nonce -> expiry-seconds

;; -> 'ok | 'malformed | 'bad-sig | 'expired | 'too-fast | 'replay
(define (verify-challenge token #:secret secret #:now now
                          #:min-age [min-age 2] #:max-age [max-age 1800] #:used used)
  (define parts (string-split token "."))
  (cond
    [(not (= (length parts) 3)) 'malformed]
    [else
     (define nonce (list-ref parts 0))
     (define issued (string->number (list-ref parts 1)))
     (define sig (list-ref parts 2))
     (cond
       [(not issued) 'malformed]
       [(not (string=? sig (mac secret nonce issued))) 'bad-sig]
       [(> now (+ issued max-age)) 'expired]
       [(< now (+ issued min-age)) 'too-fast]
       [(hash-has-key? (unbox used) nonce) 'replay]
       [else
        ;; consume it (prune expired entries while we're here)
        (define pruned (for/hash ([(k v) (in-hash (unbox used))] #:when (> v now)) (values k v)))
        (set-box! used (hash-set pruned nonce (+ issued max-age)))
        'ok])]))

;; ---- proof of work (FNV-1a 32-bit; matched byte-for-byte in the browser) -----
(define (powhash s)
  (for/fold ([h 2166136261]) ([b (in-bytes (string->bytes/utf-8 s))])
    (bitwise-and (* (bitwise-xor h b) 16777619) #xFFFFFFFF)))

;; valid iff the low `difficulty` bits of powhash(nonce ":" solution) are zero
(define (verify-pow nonce solution difficulty)
  (define s (format "~a" solution))
  (and (> (string-length s) 0)
       (zero? (bitwise-and (powhash (string-append nonce ":" s))
                           (sub1 (arithmetic-shift 1 difficulty))))))

;; find a solution (used by tests; the browser does this in JS)
(define (pow-of nonce difficulty)
  (define mask (sub1 (arithmetic-shift 1 difficulty)))
  (let loop ([n 0])
    (if (zero? (bitwise-and (powhash (string-append nonce ":" (number->string n))) mask)) n (loop (add1 n)))))

;; ---- cheap content heuristics -----------------------------------------------
(define (valid-email? e)
  (and (string? e) (regexp-match? #px"^[^@\\s]+@[^@\\s]+\\.[^@\\s]{2,}$" e)))

(define DISPOSABLE
  '("mailinator.com" "guerrillamail.com" "10minutemail.com" "tempmail.com" "temp-mail.org"
    "trashmail.com" "yopmail.com" "getnada.com" "dispostable.com" "sharklasers.com" "maildrop.cc"))
(define (disposable-email? e)
  (and (valid-email? e)
       (let ([dom (string-downcase (cadr (string-split e "@")))])
         (and (member dom DISPOSABLE) #t))))

;; ---- blocked counters (visibility) ------------------------------------------
(define *blocked* (box (hash)))
(define (bump-blocked! reason) (set-box! *blocked* (hash-update (unbox *blocked*) reason add1 0)))
(define (blocked-stats) (unbox *blocked*))
