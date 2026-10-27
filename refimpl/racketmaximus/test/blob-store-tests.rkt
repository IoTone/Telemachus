#lang racket/base

;; #128 job 2: operator-facing variables are read through ONE accessor,
;; which tries TMACH_<name> and falls back to TELEMACHUS_<name>.
(require (only-in "../config.rkt" tmach-env))

;; test/blob-store-tests.rkt — the blob seam at load and at boot (#119, #120).
;;
;; #119: `server/startup.rkt`'s probe took a filesystem PATH and wrote a file
;; under the LOCAL root, so it said nothing about a store that is not the local
;; filesystem. Three places claimed it probed the active store — the ops
;; documentation, s3blobs' own header and CLAUDE.md — and #82's requirement 5
;; was recorded as satisfied on the strength of that claim.
;;
;; #120: `register-blob-store!` was a bare `hash-set`, so a later plugin replaced
;; an earlier one silently. Job kinds and plugin ids both refuse and name the
;; collision; this was the only plugin-owned registry that did not.
;;
;;   raco test test/blob-store-tests.rkt

(require rackunit racket/port racket/file racket/string
         "../domain/repo/blobs.rkt"
         (only-in "../domain/sched/scheduler.rkt" current-plugin)
         (only-in "../server/startup.rkt" blob-probe-problem startup-problem-message
                  startup-problem-severity))

;; a store that works, one that cannot read back, one that lies about the bytes,
;; and one that cannot be reached at all — the four shapes #119's repro covers
(define (mem-store #:break [break #f])
  (define cells (make-hash))
  (hash 'put! (lambda (ns digest in size)
                (when (eq? break 'put) (error 'mem "endpoint unreachable"))
                (hash-set! cells (cons ns digest) (port->bytes in)))
        'get (lambda (ns digest)
               (case break
                 [(get) #f]
                 [(corrupt) (open-input-bytes #"something else entirely")]
                 [else (let ([b (hash-ref cells (cons ns digest) #f)])
                         (and b (open-input-bytes b)))]))
        'delete! (lambda (ns digest) (hash-remove! cells (cons ns digest)))
        'stat (lambda (ns digest)
                (let ([b (hash-ref cells (cons ns digest) #f)]) (and b (bytes-length b))))
        'cells cells))

(define (with-store name store thunk)
  (define old (tmach-env "BLOB_STORE"))
  (dynamic-wind
   (lambda ()
     (parameterize ([current-plugin (string-append "test-" name)])
       (register-blob-store! name store))
     (putenv "TMACH_BLOB_STORE" name))
   thunk
   (lambda () (if old (putenv "TMACH_BLOB_STORE" old) (putenv "TMACH_BLOB_STORE" "")))))

;; ---- #119: the probe goes through the ACTIVE store ---------------------------
(test-case "a working store probes clean, and leaves nothing behind"
  (define st (mem-store))
  (with-store "probe-ok" st
    (lambda ()
      (check-equal? (active-blob-store-name) "probe-ok")
      (check-false (blob-store-probe))
      ;; the probe blob is deleted — otherwise a store collects one per boot
      (check-equal? (hash-count (hash-ref st 'cells)) 0
                    "the probe cleans up after itself"))))

(test-case "a store that cannot be reached is a reason, not an exception"
  (with-store "probe-unreachable" (mem-store #:break 'put)
    (lambda ()
      (define r (blob-store-probe))
      (check-true (string? r) "a raise inside the store becomes a reported reason")
      (check-true (string-contains? r "probe-unreachable") "…naming which store")
      (check-true (string-contains? r "endpoint unreachable") "…and what it said"))))

(test-case "a store that writes and cannot read back is caught"
  ;; this is #119's repro in miniature: the OLD probe wrote a file under the
  ;; local root and passed, because it never asked this store anything
  (with-store "probe-writeonly" (mem-store #:break 'get)
    (lambda ()
      (define r (blob-store-probe))
      (check-true (string? r))
      (check-true (string-contains? r "could not read it back")))))

(test-case "…and so is one that returns the WRONG bytes"
  ;; worse than returning nothing, and digest equality is the only check this
  ;; seam can make without knowing anything else about the object
  (with-store "probe-corrupt" (mem-store #:break 'corrupt)
    (lambda ()
      (define r (blob-store-probe))
      (check-true (string? r))
      (check-true (string-contains? r "not what was written")))))

(test-case "the probe's failure REFUSES to serve, it does not warn"
  ;; the documentation has promised fatal since the s3blobs slice. An instance
  ;; that reports healthy and loses every document is the behaviour #119 found.
  (define p (blob-probe-problem (lambda () "the bucket is on fire") "s3"))
  (check-true (and p #t))
  (check-equal? (startup-problem-severity p) 'error "fatal, not advisory")
  (check-true (string-contains? (startup-problem-message p) "the bucket is on fire"))
  (check-true (string-contains? (startup-problem-message p) "s3") "…and names the active store")
  (check-false (blob-probe-problem (lambda () #f) "s3") "a clean probe is no problem"))

(test-case "a probe that RAISES is still a refusal and not a crashed boot"
  (define p (blob-probe-problem (lambda () (error 'x "kaboom")) "s3"))
  (check-true (and p #t))
  (check-true (string-contains? (startup-problem-message p) "kaboom")))

;; ---- #120: a name belongs to one plugin -------------------------------------
(test-case "a second plugin cannot take a store name, and the refusal names both"
  (parameterize ([current-plugin "alpha"])
    (register-blob-store! "contested" (mem-store)))
  (define e
    (with-handlers ([exn:fail? (lambda (e) (exn-message e))])
      (parameterize ([current-plugin "beta"])
        (register-blob-store! "contested" (mem-store)))
      'no-error))
  (check-true (string? e) "the second registration must fail, not win silently")
  (check-true (string-contains? e "alpha") "names the plugin that holds it")
  (check-true (string-contains? e "beta") "…and the one that tried")
  (check-true (string-contains? e "TMACH_BLOB_STORE")
              "…and tells the integrator what to do instead"))

(test-case "a plugin may re-register its OWN name, because the loader runs twice"
  ;; `register-extractor!`'s rule. A flat refusal of any duplicate breaks a reload.
  (parameterize ([current-plugin "gamma"])
    (register-blob-store! "mine" (mem-store))
    (check-not-exn (lambda () (register-blob-store! "mine" (mem-store))))))

(test-case "the owners are reportable, so GET /api/plugins can say who owns what"
  (parameterize ([current-plugin "delta"])
    (register-blob-store! "owned-by-delta" (mem-store)))
  (check-equal? (assoc "owned-by-delta" (blob-store-owners)) '("owned-by-delta" . "delta"))
  ;; the built-ins are the platform's and have no plugin
  (check-equal? (cdr (assoc "builtin" (blob-store-owners))) #f))
