#lang racket/base

;; cli/telemachus-worker.rkt — the reference pull worker (slice 66, PULL-7).
;;
;;   TELEMACHUS_URL=http://host:8835 TELEMACHUS_WORKER_TOKEN=tk_… \
;;   TELEMACHUS_WORKER_MODEL_URL=http://127.0.0.1:11434/v1/chat/completions \
;;   TELEMACHUS_WORKER_MODELS=qwen2.5:7b \
;;   racket cli/telemachus-worker.rkt [--once]
;;
;; A loop any language can write: long-poll a claim, heartbeat while running,
;; run the job against the local OpenAI-compatible endpoint, post the result or
;; the failure. The bearer is a worker token (scope jobs:execute) returned once
;; when the executor was created. Works through NAT and a tailnet — the worker
;; only ever connects OUT.
;;
;; A host whose model is unavailable does NOT keep claiming (issue #93). Two
;; halves, because one alone is not enough:
;;
;;   TELEMACHUS_WORKER_READY_URL   optional. A GET this worker makes before each
;;     claim; 2xx means "this host can run a job". While it says anything else
;;     the worker reports `paused` ONCE, claims nothing, and asks again every
;;     TELEMACHUS_WORKER_READY_INTERVAL seconds (default 15). The check can look
;;     at VRAM, memory, load or the clock — the platform needs no knowledge of
;;     GPUs, and with the variable unset none of this does anything.
;;
;;   …and a model call that cannot be served RELEASES the job (reason `busy`)
;;     instead of failing it, so the outage costs the job no attempt. The
;;     release is PULL-12's blameless hand-back; before this nothing sent the
;;     `busy` reason it was built for, and a host that lost its card failed
;;     three jobs and then started failing them for good.

(require racket/string racket/list racket/port json
         net/http-client net/url
         "../domain/agent/llm.rkt"       ; http-post-json, exn:fail:model-retryable
         (only-in "../domain/ai/content.rkt" content->text))

(define (env k [d #f]) (let ([v (getenv k)]) (if (and v (not (string=? v ""))) v d)))
(define BASE  (regexp-replace #rx"/+$" (env "TELEMACHUS_URL" "http://127.0.0.1:8835") ""))
;; issue #60: a worker token may now EXPIRE, and a worker that can persist the
;; next one rotates itself. The file is the durable home and the environment
;; variable is the bootstrap: the token minted when the executor was created goes
;; in the environment, and the first rotation writes the file that every later
;; start reads. With no file configured this worker behaves exactly as before and
;; says so the first time the platform asks it to rotate.
(define TOKEN-FILE (env "TELEMACHUS_WORKER_TOKEN_FILE"))
(define (read-token-file)
  (and TOKEN-FILE (file-exists? TOKEN-FILE)
       (let ([t (string-trim (call-with-input-file TOKEN-FILE port->string))])
         (and (not (string=? t "")) t))))
(define TOKEN (or (read-token-file) (env "TELEMACHUS_WORKER_TOKEN")))
(define MODEL-URL (env "TELEMACHUS_WORKER_MODEL_URL"))
(define MODEL-KEY (env "TELEMACHUS_WORKER_MODEL_KEY"))
(define MODELS (let ([m (env "TELEMACHUS_WORKER_MODELS" "")]) (filter (lambda (s) (not (string=? s ""))) (map string-trim (string-split m ",")))))
;; JUDGE-14: a loopback `laya_serve.py --port` (run it with --batch-size 1).
;; Set, it adds judge.typed to this worker's kinds; the chat endpoint is then
;; optional, so a Mac can be a judge host and nothing else.
(define LAYA-URL (let ([u (env "TELEMACHUS_WORKER_LAYA_URL")])
                   (and u (regexp-replace #rx"/+$" u ""))))
(define KINDS (append (if MODEL-URL '("infer.chat") '())
                      (if LAYA-URL '("judge.typed") '())))
(define ONCE? (member "--once" (vector->list (current-command-line-arguments))))

;; issue #93. Unset, this worker behaves exactly as before.
(define READY-URL (env "TELEMACHUS_WORKER_READY_URL"))
;; An unparseable or non-positive interval falls back to the default, never to
;; 0 — a zero here would be a hot loop against the readiness endpoint, which is
;; the platform's own rule for every other interval knob (see
;; TELEMACHUS_MAX_JOB_SECONDS, TELEMACHUS_UPLOAD_REAP_HOURS).
(define READY-INTERVAL
  (let* ([raw (env "TELEMACHUS_WORKER_READY_INTERVAL")]
         [n (and raw (string->number (string-trim raw)))])
    (if (and (real? n) (> n 0)) (inexact->exact (floor n)) 15)))
;; How long to wait after handing a job back for want of capacity. The SERVER
;; keeps this job away from this executor for RELEASE-BACKOFF (30s) and says
;; nothing about the NEXT job — so without a pause here a worker whose model is
;; down would claim the whole queue and release all of it, which past
;; MAX-RELEASES fails the jobs for good. The exact number is not load-bearing;
;; not spinning is.
(define BUSY-BACKOFF 30)

(unless TOKEN (eprintf "TELEMACHUS_WORKER_TOKEN is not set\n") (exit 2))
(when (null? KINDS)
  (eprintf "set TELEMACHUS_WORKER_MODEL_URL (an OpenAI-compatible chat endpoint) and/or TELEMACHUS_WORKER_LAYA_URL (a loopback laya_serve.py)\n")
  (exit 2))

;; The bearer is a BOX because a rotation replaces it mid-loop (issue #60), so
;; every request builds its headers from the current value rather than from a
;; list computed once at startup — the shape that would have gone on presenting
;; the retired token until the process restarted.
(define token (box TOKEN))
(define (auth) (list (string-append "Authorization: Bearer " (unbox token)) "Content-Type: application/json"))
(define (post path body)
  (http-post-json (string-append BASE path) body (auth)))

;; ---- "this host cannot serve the job" is not the job's fault (issue #93) -----

;; Raised where the MODEL could not answer for a reason that is this host's:
;; nothing listening, a gateway refusing, a request that timed out against a
;; card somebody else is holding. Distinct from exn:fail so run-job can release
;; the job instead of failing it — a plain exn:fail still means the job is bad.
(struct exn:fail:unavailable exn:fail () #:transparent)
(define (unavailable! fmt . args)
  (raise (exn:fail:unavailable (apply format fmt args) (current-continuation-marks))))

;; 502/503/504 are a gateway or a model server saying "not now"; a 4xx is our own
;; malformed request and a 500 is the model failing on THIS input — both of those
;; are the job's problem and stay failures. Same split as llm.rkt's
;; retryable-code?, minus the 500 it is willing to retry: retrying a 500 costs
;; one call, releasing a job for one tells every other worker it is unrunnable.
(define (unavailable-code? code) (member code '(502 503 504)))

;; An endpoint that cannot be served should not be distinguishable here from one
;; that is merely slow: a GPU another process is thrashing answers by timing out,
;; which is the single most common shape of the outage this guards against.
;; `malformed` is NOT one of these — a reply we cannot read is a broken model,
;; not a busy one, and the issue asks for it to stay a failure.
(define (retryable-reason-is-host? e)
  (memq (exn:fail:model-retryable-reason e) '(network timeout idle)))

;; -> (values host port ssl? path-prefix) for a base URL
(define (url-bits u0)
  (define u (string->url u0))
  (define ssl? (equal? (url-scheme u) "https"))
  (values (url-host u)
          (or (url-port u) (if ssl? 443 80))
          ssl?
          (let ([pp (string-join (map path/param-path (url-path u)) "/")])
            (if (string=? pp "") "" (string-append "/" pp)))))

;; GET a URL for its status code; 0 when the host could not be reached, could
;; not answer in time, or said something unreadable. Every one of those means
;; "not ready", so they collapse deliberately — this is a yes/no question and a
;; readiness probe that raised would take the loop down with it.
;;
;; Two things this must not get wrong, both of them lessons already paid for in
;; domain/agent/llm.rkt (see the note above http-post-json):
;;
;;   • it opens and CLOSES its own connection rather than calling http-sendrecv,
;;     which abandons the socket under the response port — collection does not
;;     reclaim it, so polling this before every claim would leak a descriptor
;;     per pass and hit the 1024 limit in hours;
;;   • it runs under a DEADLINE, because neither http-conn-open nor
;;     http-conn-sendrecv! takes one: an endpoint that accepts the connection
;;     and never answers would otherwise hang this loop for ever, which is a
;;     worse outage than the one the gate exists to survive. The request runs
;;     under its own custodian and the timeout shuts it down — killing the
;;     thread alone would leave the socket open.
(define (http-get url #:timeout [secs 10] #:headers [headers '()])
  (define cust (make-custodian))
  (define ch (make-channel))
  (define t (parameterize ([current-custodian cust])
              (thread (lambda ()
                        (channel-put
                         ch
                         (with-handlers ([(lambda (_) #t) (lambda (_) (cons 0 ""))])
                           (define-values (host port ssl? prefix) (url-bits url))
                           (define hc (http-conn-open host #:ssl? ssl? #:port port))
                           (dynamic-wind
                             void
                             (lambda ()
                               (define-values (status _h in)
                                 (http-conn-sendrecv! hc (if (string=? prefix "") "/" prefix)
                                                      #:method #"GET" #:headers headers))
                               (define body (port->string in))
                               (close-input-port in)
                               (cons (let ([m (regexp-match #px#"\\b([0-9]{3})\\b" status)])
                                       (if m (string->number (bytes->string/utf-8 (cadr m))) 0))
                                     body))
                             (lambda () (http-conn-close! hc)))))))))
  (define r (sync/timeout secs ch))
  (custodian-shutdown-all cust)
  (cond [r (values (car r) (cdr r))]
        [else (kill-thread t) (values 0 "")]))

(define (http-get-code url #:timeout [secs 10])
  (define-values (code _body) (http-get url #:timeout secs))
  code)

;; …and the same call read as JSON, for this worker's own credential plane
;; (issue #60). A body that will not parse is the same answer as no body: this
;; is a periodic check, and one that raised would take the claim loop down.
(define (http-get-json url #:headers [headers '()])
  (define-values (code body) (http-get url #:headers headers))
  (values code (with-handlers ([exn:fail? (lambda (_) (hasheq))])
                 (let ([j (string->jsexpr body)]) (if (hash? j) j (hasheq))))))

;; Can this host take a job right now? With no READY_URL set the answer is
;; always yes, which is what makes this change invisible to every worker and
;; every deployment that does not ask for it.
(define (host-ready?)
  (if (not READY-URL)
      #t
      (let ([code (http-get-code READY-URL)])
        (and (>= code 200) (< code 300)))))

;; infer.chat — forward to the model.
;; `response_format` is forwarded when the platform asked for one (issue #18), so
;; a schema request routed to a pull executor reaches the provider as it would
;; locally; the platform checks the reply against it either way.
(define (run-infer-chat payload)
  (define body
    (let ([b (hasheq 'model (let ([m (hash-ref payload 'model 'null)]) (if (string? m) m (if (pair? MODELS) (car MODELS) "local")))
                     'messages (hash-ref payload 'messages '())
                     'temperature (hash-ref payload 'temperature 0.7)
                     'stream #f)])
      (let ([rf (hash-ref payload 'response_format #f)])
        (if (and rf (not (eq? rf 'null))) (hash-set b 'response_format rf) b))))
  (define-values (code resp)
    ;; http-post-json raises exn:fail:model-retryable once its OWN retries are
    ;; spent — an unreachable endpoint, a deadline, a stalled read. Those are
    ;; this host's problem, so they hand the job back instead of failing it.
    ;; `malformed` is the exception: a model that answered with something
    ;; unreadable is broken, not busy, and the job should be failed for it.
    (with-handlers ([exn:fail:model-retryable?
                     (lambda (e)
                       (if (retryable-reason-is-host? e)
                           (unavailable! "~a" (exn-message e))
                           (raise e)))])
      (http-post-json MODEL-URL body (append (list "Content-Type: application/json")
                                             (if MODEL-KEY (list (string-append "Authorization: Bearer " MODEL-KEY)) '())))))
  (when (unavailable-code? code)
    (unavailable! "the model endpoint answered HTTP ~a" code))
  (unless (= code 200) (error 'worker "model endpoint returned HTTP ~a" code))
  (define choices (hash-ref resp 'choices '()))
  ;; a provider may answer with content PARTS; join their text rather than
  ;; posting an empty reply the platform cannot tell from a quiet model
  (define reply (if (pair? choices)
                    (let-values ([(t problem) (content->text (hash-ref (hash-ref (car choices) 'message (hasheq)) 'content ""))])
                      (when problem (error 'worker "the model's reply could not be read as text: ~a" problem))
                      t)
                    ""))
  (define tokens (let ([t (hash-ref (hash-ref resp 'usage (hasheq)) 'total_tokens #f)])
                   (if (number? t) t (max 1 (quotient (string-length reply) 4)))))
  (hasheq 'reply reply 'tokens_used tokens))

;; The job this worker is holding right now, for the shutdown flush (issue #61).
;; Cleared in a dynamic-wind at the call site, so it is right however run-job
;; exits — a release posted for a job that already completed would be refused as
;; not-holder, which is harmless but would print a confusing line on every stop.
(define held (box #f))

;; Set when the last job was handed back for want of capacity (issue #93), so
;; the next pass of the loop waits before claiming a job this host almost
;; certainly cannot run either.
(define no-capacity (box #f))

;; judge.typed — forward to laya (JUDGE-8/13/14). The payload's `request_json`
;; goes out EXACTLY as the platform composed it, and the verdict goes back
;; EXACTLY as laya wrote it: both are bytes this worker must not parse and
;; re-serialize, because the object key order inside them is part of the
;; question. http-post-json would re-encode, so this one speaks raw.
(define (run-judge-typed payload)
  (define rq (hash-ref payload 'request_json #f))
  (unless (string? rq) (error 'worker "judge.typed payload carries no request_json"))
  (define-values (host port ssl? prefix) (url-bits LAYA-URL))
  (define path (string-append prefix "/v1/systemone"))
  ;; Nothing listening, or a card somebody else is holding, is this host's
  ;; problem and not the judgment's (issue #93): hand the job back rather than
  ;; failing it. laya answers 503 while it is loading a checkpoint, which is the
  ;; ordinary case on a host that was just restarted.
  (define-values (status _hdrs in)
    (with-handlers ([exn:fail:network?
                     (lambda (e) (unavailable! "laya could not be reached: ~a" (exn-message e)))])
      (http-sendrecv host path
                     #:port port
                     #:ssl? ssl?
                     #:method #"POST"
                     #:data (string->bytes/utf-8 rq)
                     #:headers '("Content-Type: application/json"))))
  (define body (port->string in))
  (define code (let ([m (regexp-match #rx"^HTTP/[^ ]+ ([0-9]+)" status)])
                 (if m (string->number (bytes->string/utf-8 (cadr m))) 0)))
  (when (unavailable-code? code)
    (unavailable! "laya answered HTTP ~a" code))
  (unless (= code 200)
    (error 'worker "laya returned HTTP ~a: ~a" code
           (let ([b (string-trim body)]) (substring b 0 (min 300 (string-length b))))))
  (hasheq 'verdict_json body))

(define (run-job job)
  (define id (hash-ref job 'id))
  (define kind (hash-ref job 'kind))
  (define lease (let ([l (hash-ref job 'lease_seconds 120)]) (if (number? l) l 120)))
  ;; the claim's fencing token (issue #24): it goes back with every heartbeat and
  ;; with the result, so a run whose lease lapsed cannot complete the attempt that
  ;; replaced it. A worker that drops it will be refused with 409.
  (define token (let ([t (hash-ref job 'claim_token #f)]) (if (string? t) t 'null)))
  ;; what the shutdown flush would have to hand back (issue #61)
  (set-box! held (cons id token))
  ;; Heartbeat at a third of the lease while the job runs — and READ the answer.
  ;; A 409 means this attempt is no longer ours to finish: the lease lapsed and
  ;; somebody re-claimed it, or the job was canceled (SCHED-8). Either way the
  ;; right move is to stop, because the result can no longer land. The beat
  ;; thread breaks the thread doing the work; the handler below posts /fail,
  ;; which is what lets the server settle the row at once instead of waiting the
  ;; lease out. A worker in another language does the same thing: stop when the
  ;; heartbeat stops saying 200.
  (define worker-thd (current-thread))
  (define stopped (box #f))
  (define beat (thread (lambda ()
                         (let loop ()
                           (sleep (max 1 (quotient lease 3)))
                           (define-values (code resp)
                             ;; `state` rides on the heartbeat (issue #58), so an
                             ;; operator reading GET /api/executors sees "busy"
                             ;; rather than inferring it from a timestamp
                             (post (format "/api/workers/jobs/~a/heartbeat" id)
                                   (hasheq 'claim_token token 'state "busy")))
                           (cond
                             [(= code 200) (loop)]
                             [else
                              (set-box! stopped (let ([e (and (hash? resp) (hash-ref resp 'error #f))])
                                                  (if (string? e) e (format "heartbeat refused (HTTP ~a)" code))))
                              (break-thread worker-thd)])))))
  (with-handlers ([exn:break? (lambda (_)
                                (kill-thread beat)
                                (define why (or (unbox stopped) "interrupted"))
                                (post (format "/api/workers/jobs/~a/fail" id)
                                      (hasheq 'error why 'claim_token token))
                                (printf "job ~a (~a): STOPPED — ~a\n" id kind why))]
                  ;; BEFORE the exn:fail? clause below, which would otherwise
                  ;; match this too — the first matching clause wins.
                  ;;
                  ;; The model could not be served, which is this host's problem
                  ;; and not the job's (issue #93). Hand it back: the release
                  ;; spends no attempt, another worker may take it at once, and
                  ;; `busy` is the reason PULL-12 defined for exactly this and
                  ;; that nothing sent until now.
                  [exn:fail:unavailable?
                   (lambda (e)
                     (kill-thread beat)
                     (set-box! no-capacity #t)
                     (define-values (code _r)
                       (post (format "/api/workers/jobs/~a/release" id)
                             (hasheq 'claim_token token 'reason "busy")))
                     (printf "job ~a (~a): HANDED BACK — ~a~a\n" id kind (exn-message e)
                             (if (= code 200) "" (format " (release refused: HTTP ~a)" code))))]
                  [exn:fail? (lambda (e)
                               (kill-thread beat)
                               (post (format "/api/workers/jobs/~a/fail" id)
                                     (hasheq 'error (exn-message e) 'claim_token token))
                               (printf "job ~a (~a): FAILED — ~a\n" id kind (exn-message e)))])
    (define result
      (case kind
        [("infer.chat") (run-infer-chat (hash-ref job 'payload (hasheq)))]
        [("judge.typed") (run-judge-typed (hash-ref job 'payload (hasheq)))]
        [else (error 'worker "this worker does not run ~a" kind)]))
    (kill-thread beat)
    (define-values (code resp) (post (format "/api/workers/jobs/~a/complete" id)
                                     (hasheq 'result result 'claim_token token)))
    (printf "job ~a (~a): ~a\n" id kind (if (= code 200) "done" (format "complete refused (HTTP ~a)" code)))))

;; ---- rotating this host's own credential (issue #60) -------------------------

;; How often to ask. One request an hour is nothing beside a claim every twenty
;; seconds, and the platform tells us to rotate a third of the token's life
;; early, so an hourly check leaves many chances even for a short lifetime. An
;; unparseable or non-positive value falls back to the default, never to 0 — the
;; platform's rule for every interval knob.
(define TOKEN-CHECK
  (let* ([raw (env "TELEMACHUS_WORKER_TOKEN_CHECK")]
         [n (and raw (string->number (string-trim raw)))])
    (if (and (real? n) (> n 0)) (inexact->exact (floor n)) 3600)))
(define last-token-check (box 0))
(define warned-no-file (box #f))

;; A worker that cannot persist a new token MUST NOT rotate. It would receive
;; one, forget it, and go on working on the outgoing credential until the overlap
;; ended — turning a rotation it asked for into the outage the overlap exists to
;; prevent. So the file is written FIRST and the token is swapped only if that
;; succeeded; a failure leaves the old token in place, which still works.
(define (persist-token! t)
  (define tmp (string-append TOKEN-FILE ".new"))
  (call-with-output-file tmp #:exists 'truncate (lambda (o) (displayln t o)))
  ;; rename, so a reader never sees a half-written credential and a crash
  ;; between the two leaves the previous file intact
  (rename-file-or-directory tmp TOKEN-FILE #t)
  ;; the file is a credential: nobody else on the box needs to read it
  (with-handlers ([exn:fail? void]) (file-or-directory-permissions TOKEN-FILE #o600)))

(define (rotate-token!)
  (define-values (code resp) (post "/api/workers/token" (hasheq)))
  (cond
    [(and (= code 200) (hash? resp) (string? (hash-ref resp 'token #f)))
     (define new (hash-ref resp 'token))
     (with-handlers ([exn:fail? (lambda (e)
                                  (eprintf "telemachus-worker: the new token could NOT be written to ~a (~a) — still using the old one\n"
                                           TOKEN-FILE (exn-message e)))])
       (persist-token! new)
       (set-box! token new)
       (printf "telemachus-worker: worker token rotated~a\n"
               (let ([e (hash-ref resp 'expires_at 'null)])
                 (if (number? e) (format " (expires in ~as)" (max 0 (- e (current-seconds)))) ""))))]
    ;; 429 is "you asked too soon" and is not an error worth a line every hour
    [(= code 429) (void)]
    [else (eprintf "telemachus-worker: token rotation refused (HTTP ~a)\n" code)]))

;; Ask the platform, not the clock: `rotate` is its decision, so every worker in
;; every language takes the same one and the window can move without redeploying
;; a fleet.
(define (check-token!)
  (when (> (- (current-seconds) (unbox last-token-check)) TOKEN-CHECK)
    (set-box! last-token-check (current-seconds))
    (define-values (code resp)
      (with-handlers ([exn:fail? (lambda (e) (values 0 (hasheq)))])
        (http-get-json (string-append BASE "/api/workers/token") #:headers (auth))))
    (when (and (= code 200) (hash? resp) (eq? (hash-ref resp 'rotate #f) #t))
      (cond
        [TOKEN-FILE (rotate-token!)]
        [(not (unbox warned-no-file))
         (set-box! warned-no-file #t)
         (eprintf (string-append "telemachus-worker: this token expires soon and TELEMACHUS_WORKER_TOKEN_FILE is not set, "
                                 "so this worker cannot keep a new one — set it, or have an operator run "
                                 "POST /api/executors/<id>/rotate-token and redeploy\n"))]
        [else (void)]))))

(printf "telemachus-worker → ~a  models ~a  kinds ~a\n" BASE (if (null? MODELS) "(any)" (string-join MODELS ",")) (string-join KINDS ","))

;; Say so on the way out (issue #58). A worker that is stopped — Ctrl-C, a
;; systemd stop, a drain before maintenance — otherwise just goes quiet, and
;; quiet is what a CRASHED worker looks like. One request turns an operator's
;; guess into a fact; it is best-effort, because a host being torn down may have
;; no network left and failing the shutdown over that would be worse.
(define (report-paused!)
  (with-handlers ([exn:fail? void])
    (post "/api/workers/state" (hasheq 'state "paused"))
    (printf "telemachus-worker: reported paused\n")))

;; …and hand back the job it is holding, if any (issue #61). Letting the lease
;; lapse instead costs the job one of its three attempts for something that was
;; this host's business, not the job's — and a worker stopped mid-job is the most
;; ordinary way that used to happen. `shutdown` is the reason; the release spends
;; no attempt, and another worker may take the job at once rather than waiting
;; out the 120-second lease.
;;
;; Best-effort for report-paused!'s reason, and in this ORDER: the release is the
;; one that matters to the work, so it goes first in case the host dies between
;; the two requests.
(define (release-held!)
  (define h (unbox held))
  (when h
    (with-handlers ([exn:fail? void])
      (post (format "/api/workers/jobs/~a/release" (car h))
            (hasheq 'claim_token (cdr h) 'reason "shutdown"))
      (printf "telemachus-worker: released ~a on the way out\n" (car h)))))
(void (plumber-add-flush! (current-plumber) (lambda (_) (release-held!) (report-paused!))))

;; Standing down is reported ONCE per outage, not once per check (issue #93).
;; /api/workers/state is the authoritative channel (PULL-11) and a row every
;; fifteen seconds would tell an operator nothing the first one did not — while
;; making the executor's history useless for finding when the outage began.
(define stood-down (box #f))

(define (stand-down! why)
  (unless (unbox stood-down)
    (set-box! stood-down #t)
    ;; best-effort, for report-paused!'s reason: a host with no network should
    ;; not crash out of a loop whose whole job is to survive the outage
    (with-handlers ([exn:fail? void])
      (post "/api/workers/state" (hasheq 'state "paused")))
    (eprintf "telemachus-worker: ~a — reported paused, claiming nothing (re-checking every ~as)\n"
             why READY-INTERVAL)))

(define (stand-up!)
  (when (unbox stood-down)
    (set-box! stood-down #f)
    ;; no state post needed: the claim below reports `ready` itself
    (printf "telemachus-worker: ready again — claiming\n")))

(let loop ()
  (cond
    ;; The gate comes FIRST. A host that cannot run a job should not take one —
    ;; and should be visibly alive-and-refusing rather than quiet, because quiet
    ;; is what a CRASHED worker looks like (PULL-11).
    [(not (host-ready?))
     (stand-down! (format "~a is not ready" READY-URL))
     (unless ONCE? (sleep READY-INTERVAL) (loop))]
    [else
     (stand-up!)
     ;; before the claim, because the claim is what the token is FOR: a rotation
     ;; that lands between a claim and its completion would leave the result
     ;; posted with a credential this host has just replaced (it still works —
     ;; the overlap — but the ordering costs nothing and removes the question).
     (check-token!)
     (let-values ([(code resp)
                   (with-handlers ([exn:fail? (lambda (e) (values 0 (hasheq 'error (exn-message e))))])
                     (post "/api/workers/claim" (hasheq 'kinds KINDS 'models MODELS 'max_wait 20
                                                        ;; about to long-poll, so by definition
                                                        ;; there is capacity for another job
                                                        'state "ready")))])
       (cond
         [(and (= code 200) (hash? resp) (string? (hash-ref resp 'id #f)))
          (dynamic-wind void (lambda () (run-job resp)) (lambda () (set-box! held #f)))]
         [(= code 204) (void)]
         [(= code 0) (eprintf "claim: ~a (retrying)\n" (hash-ref resp 'error "?")) (sleep 3)]
         [(member code '(401 403)) (eprintf "claim refused: HTTP ~a — is the worker token valid and bound to an executor?\n" code) (exit 1)]
         [else (eprintf "claim: HTTP ~a\n" code) (sleep 3)]))
     ;; A job just came back for want of capacity. Waiting is the difference
     ;; between one released job and a queue drained into releases: the server's
     ;; cool-off protects THIS job from THIS executor and says nothing about the
     ;; next one. With a READY_URL set the gate above takes over from here.
     (when (unbox no-capacity)
       (set-box! no-capacity #f)
       (unless ONCE?
         (eprintf "telemachus-worker: no capacity — waiting ~as before claiming again\n" BUSY-BACKOFF)
         (sleep BUSY-BACKOFF)))
     (unless ONCE? (loop))]))
