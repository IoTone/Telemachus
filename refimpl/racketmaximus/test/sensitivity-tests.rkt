#lang racket/base

;; test/sensitivity-tests.rkt — issue #91 requirement 4: where a labelled
;; document's text may go (decisions RED-24…RED-33).
;;   raco test test/sensitivity-tests.rkt
;;
;; Three layers, as the three slices before it:
;;   1. the POLICY — the two tiers, the tightening, and the four ways a request
;;      can be refused. A document in, a sentence out, no model and no socket.
;;   2. the SEAM — that the gate is asked at a place content really leaves, that
;;      it is asked BEFORE anything is sent, and that it cannot be defeated by a
;;      policy that raises.
;;   3. the REQUIREMENT, through a real tool and a real `run-chat`: the issue's
;;      own second acceptance criterion, "attempting to run an unredacted step
;;      against a disallowed executor is refused and audited".

(require rackunit db-kit/portable db-kit/migrate
         racket/port racket/string racket/list racket/file
         json
         "../domain/db/migrations.rkt"
         "db-fixture.rkt"
         "../domain/authz/authz.rkt"
         "../domain/settings/settings.rkt"
         "../domain/repo/blobs.rkt"
         "../domain/repo/repo.rkt"
         "../domain/ai/sensitivity.rkt"
         "../domain/ai/egress.rkt"
         "../domain/ai/executor.rkt"
         "../domain/ai/roles.rkt"
         "../domain/repo/classify.rkt"
         "../domain/repo/doc-tools.rkt"
         "../domain/agent/registry.rkt"
         "../domain/agent/tools.rkt")

(define BLOB-ROOT (make-temporary-file "telemachus-sens-blobs-~a" 'directory))
(current-blob-root BLOB-ROOT)

(define (fresh) (define c (fresh-db #:migrate? #f)) (migrate! c all-migrations) c)

;; a hosted backend and a loopback one, spelled once
(define FAR "http://10.255.255.1:9/v1/chat/completions")
(define NEAR "http://127.0.0.1:11434/v1/chat/completions")

(define (pol #:executors [ex '()] #:default [dm #f] #:redacted [ar #t])
  (hasheq 'executors ex 'default_model dm 'allow_redacted ar))

(define (put-instance! conn labels) (executor-policy-set! conn 'instance "" (hasheq 'labels labels)))
(define (put-org! conn org labels) (executor-policy-set! conn 'org org (hasheq 'labels labels)))

(define (refusal conn #:org [org #f] #:label [label "confidential"] #:redacted? [r #f]
                 #:executor [ex "gpu-1"] #:endpoint [u FAR])
  (sensitivity-refusal conn #:org org #:label label #:redacted? r
                       #:executor ex #:endpoint u))

;; ---- 1. the policy ----------------------------------------------------------------

(test-case "OFF UNLESS CONFIGURED: with no policy document, a labelled document goes"
  ;; The rule every default-bearing knob in this tree follows, and here the
  ;; alternative is worse than usual: a team already using an attribute called
  ;; `sensitivity` for something of its own would find every AI step refused by
  ;; an upgrade it did not ask for.
  (define conn (fresh))
  (check-false (executor-policy-configured? conn #f))
  (check-false (refusal conn #:executor "anything")))

(test-case "an executor on the label's list may see its text unredacted"
  (define conn (fresh))
  (put-instance! conn (hasheq 'confidential (pol #:executors '("gpu-1"))))
  (check-false (refusal conn #:executor "gpu-1")))

(test-case "an executor NOT on the list may not, and the refusal names both"
  (define conn (fresh))
  (put-instance! conn (hasheq 'confidential (pol #:executors '("gpu-1"))))
  (define bad (refusal conn #:executor "openai-gw"))
  (check-true (string? bad))
  (check-true (string-contains? bad "confidential"))
  (check-true (string-contains? bad "openai-gw") "the executor that was refused")
  (check-true (string-contains? bad "gpu-1") "and what IS allowed, or the message is unactionable")
  (check-false (string-contains? bad "10.255.255.1")
               "never the endpoint — the refusal is about the executor, and FEED-6's rule holds"))

(test-case "THE ALLOWLIST IS FOR UNREDACTED TEXT: the same request redacted is allowed"
  ;; Requirement 4 read as written. Tokenised text may travel to a backend that
  ;; is not on the list, because making exactly that safe is what requirements 1
  ;; and 2 are for.
  (define conn (fresh))
  (put-instance! conn (hasheq 'confidential (pol #:executors '("gpu-1"))))
  (check-true (string? (refusal conn #:executor "openai-gw" #:redacted? #f)))
  (check-false (refusal conn #:executor "openai-gw" #:redacted? #t)))

(test-case "allow_redacted false puts the list back in charge of everything"
  (define conn (fresh))
  (put-instance! conn (hasheq 'confidential (pol #:executors '("gpu-1") #:redacted #f)))
  (define bad (refusal conn #:executor "openai-gw" #:redacted? #t))
  (check-true (string? bad))
  (check-true (string-contains? bad "no executor outside its own list"))
  (check-false (refusal conn #:executor "gpu-1" #:redacted? #t) "the listed one still may"))

(test-case "A LABEL NO TIER MENTIONS IS REFUSED, and the message lists the ones that are"
  ;; The one place this slice fails CLOSED on an absence, and deliberately the
  ;; opposite of LAY-9's permissive unknown: a document somebody marked is an
  ;; assertion nobody has answered, and the only way to reach it is to remove a
  ;; label from the policy while documents still carry it.
  (define conn (fresh))
  (put-instance! conn (hasheq 'confidential (pol #:executors '("gpu-1"))))
  (define bad (refusal conn #:label "secret" #:executor "gpu-1"))
  (check-true (string? bad))
  (check-true (string-contains? bad "does not list that label"))
  (check-true (string-contains? bad "confidential") "what the policy does list"))

(test-case "a document with NO label is allowed by construction"
  ;; The OTHER absence, and it is not the same thing: nobody asserted anything.
  (define conn (fresh))
  (put-instance! conn (hasheq 'confidential (pol #:executors '())))
  (check-false (refusal conn #:label #f #:executor "openai-gw"))
  (check-false (refusal conn #:label "" #:executor "openai-gw"))
  (check-false (refusal conn #:label "   " #:executor "openai-gw")))

(test-case "A LOOPBACK BACKEND IS OUTSIDE THE POLICY ENTIRELY"
  ;; `content-logging-refusal`'s exemption one requirement earlier, for its
  ;; reason: nothing left the box, so there is nothing for an allowlist to allow.
  ;; This is what keeps the ordinary single-box instance out of the feature's way.
  (define conn (fresh))
  (put-instance! conn (hasheq 'confidential (pol #:executors '())))
  (check-false (refusal conn #:executor #f #:endpoint NEAR))
  (check-false (refusal conn #:executor "local-ish" #:endpoint "http://localhost:11434/v1"))
  (check-true (string? (refusal conn #:executor #f #:endpoint "http://10.1.2.3/v1"))
              "10.x is somebody else's network, as peer.rkt has always said"))

(test-case "a PULL executor has no endpoint and is therefore governed"
  ;; RED-21's rule: the platform does not know and must not guess which model URL
  ;; a worker will call, so an unplaceable backend counts as hosted — which is
  ;; right, because the content leaves by the job row.
  (define conn (fresh))
  (put-instance! conn (hasheq 'confidential (pol #:executors '("gpu-1"))))
  (check-true (string? (refusal conn #:executor "worker-7" #:endpoint #f)))
  (check-false (refusal conn #:executor "gpu-1" #:endpoint #f)))

(test-case "the unnamed configured model is spelled default_model, not a reserved name"
  ;; A hosted TELEMACHUS_MODEL_URL has no executor name, so it cannot be on a
  ;; list of names; a reserved member called \"default\" would collide with an
  ;; executor an operator legitimately named that.
  (define conn (fresh))
  (put-instance! conn (hasheq 'confidential (pol #:executors '("gpu-1"))))
  (define bad (refusal conn #:executor #f))
  (check-true (string? bad))
  (check-true (string-contains? bad "configured default model"))
  (put-instance! conn (hasheq 'confidential (pol #:executors '() #:default #t)))
  (check-false (refusal conn #:executor #f)))

(test-case "TIGHTEN WHERE BOTH TIERS SPEAK: intersection, AND, and a single tier standing"
  (define conn (fresh))
  (put-instance! conn (hasheq 'confidential (pol #:executors '("gpu-1" "gpu-2")
                                                 #:default #t #:redacted #t)
                              'internal (pol #:executors '("gpu-9"))))
  (put-org! conn "o1" (hasheq 'confidential (pol #:executors '("gpu-2" "gpu-3")
                                                 #:default #f #:redacted #f)
                              'house (pol #:executors '("gpu-4"))))
  (define eff (hash-ref (executor-policy-effective conn "o1") 'labels))
  ;; both named it: the permitted set is the INTERSECTION and the flag is ANDed
  (check-equal? (hash-ref (hash-ref eff 'confidential) 'executors) '("gpu-2"))
  (check-false (hash-ref (hash-ref eff 'confidential) 'allow_redacted))
  ;; BOTH flags, not just the one: a control that patched only `default_model`'s
  ;; `and` to an `or` left every case passing, which is this slice's own #113 —
  ;; a rule nothing exercises is a rule nothing holds.
  (check-false (hash-ref (hash-ref eff 'confidential) 'default_model))
  (check-true (string? (refusal conn #:org "o1" #:executor #f))
              "the instance permitting the default model does not survive the org refusing it")
  ;; only the instance named `internal`; only the org named `house`. Each stands —
  ;; were an unmentioned label a denial, the instance operator would have to
  ;; enumerate every company's own vocabulary first.
  (check-equal? (hash-ref (hash-ref eff 'internal) 'executors) '("gpu-9"))
  (check-equal? (hash-ref (hash-ref eff 'house) 'executors) '("gpu-4"))
  ;; and the decision follows the intersection
  (check-false (refusal conn #:org "o1" #:executor "gpu-2"))
  (check-true (string? (refusal conn #:org "o1" #:executor "gpu-1"))
              "an org cannot be widened by the instance's longer list")
  (check-true (string? (refusal conn #:org "o1" #:executor "gpu-3"))
              "nor the instance by the org's")
  ;; another company's document is governed by the instance alone
  (check-false (refusal conn #:org "o2" #:executor "gpu-1")))

(test-case "sources names which tiers mentioned each label"
  (define conn (fresh))
  (put-instance! conn (hasheq 'confidential (pol #:executors '("gpu-1"))))
  (put-org! conn "o1" (hasheq 'confidential (pol #:executors '("gpu-1"))
                              'house (pol #:executors '("gpu-4"))))
  (define src (executor-policy-sources conn "o1"))
  (check-equal? (hash-ref src 'confidential) '("instance" "org"))
  (check-equal? (hash-ref src 'house) '("org")))

(test-case "the document is validated, and an unknown field is refused rather than dropped"
  ;; WF-10's rule. A policy field that does nothing is how an operator comes to
  ;; believe a protection is in force.
  (check-false (executor-policy-problem (hasheq 'labels (hasheq 'a (pol)))))
  (check-true (string? (executor-policy-problem "nope")))
  (check-true (string? (executor-policy-problem (hasheq 'labels (hasheq) 'horizon 7))))
  (check-true (string? (executor-policy-problem (hasheq 'labels "nope"))))
  (check-true (string? (executor-policy-problem (hasheq 'labels (hasheq 'a (hasheq 'executor '()))))))
  (check-true (string? (executor-policy-problem (hasheq 'labels (hasheq 'a (hasheq 'executors "gpu-1"))))))
  (check-true (string? (executor-policy-problem (hasheq 'labels (hasheq 'a (hasheq 'executors '("")))))))
  (check-true (string? (executor-policy-problem (hasheq 'labels (hasheq 'a (hasheq 'default_model "yes"))))))
  (check-true (string? (executor-policy-problem (hasheq 'labels (hasheq 'a (hasheq 'allow_redacted 1))))))
  (check-true (string? (executor-policy-problem
                        (hasheq 'labels (for/hasheq ([i (in-range (add1 MAX-POLICY-LABELS))])
                                          (values (string->symbol (format "l~a" i)) (pol))))))
              "bounded, for LAY-4's reason: it is read on the path of a model call")
  ;; and the stored document always carries every field, so no reader needs
  ;; defaults of its own
  (define conn (fresh))
  (define saved (put-instance! conn (hasheq 'confidential (hasheq 'executors '("a" "a")))))
  (define e (hash-ref (hash-ref saved 'labels) 'confidential))
  (check-equal? (hash-ref e 'executors) '("a") "de-duplicated")
  (check-false (hash-ref e 'default_model) "the unnamed model is on no list until somebody says so")
  (check-true (hash-ref e 'allow_redacted) "and redacted text travels, which is what req 1-2 are for"))

(test-case "RED-34: dropping the instance document is the only way OFF"
  ;; An empty `labels` object is an operator saying "govern nothing" and is still
  ;; a CONFIGURED policy, so it refuses every label it does not mention — which
  ;; is every label. Without a way to drop the document, an operator who turned
  ;; the feature on could never turn it off, and every labelled document in the
  ;; instance would be refused for ever. A smoke fixture found this by leaving
  ;; one behind.
  (define conn (fresh))
  (put-instance! conn (hasheq 'confidential (pol #:executors '("gpu-1"))))
  (check-false (refusal conn #:executor "gpu-1"))
  (put-instance! conn (hasheq))
  (check-true (executor-policy-configured? conn #f) "an empty policy is still a policy")
  (check-true (string? (refusal conn #:executor "gpu-1"))
              "…and therefore refuses a label it no longer mentions")
  (executor-policy-clear! conn 'instance "")
  (check-false (executor-policy-configured? conn #f))
  (check-false (refusal conn #:executor "gpu-1") "dropped, and the instance is governed by nothing again"))

(test-case "a cleared org policy falls back to the instance, and to nothing when there is none"
  (define conn (fresh))
  (put-org! conn "o1" (hasheq 'house (pol #:executors '("gpu-4"))))
  (check-true (executor-policy-configured? conn "o1"))
  (check-false (refusal conn #:org "o1" #:label "house" #:executor "gpu-4"))
  (executor-policy-clear! conn 'org "o1")
  (check-false (executor-policy-configured? conn "o1"))
  (check-false (refusal conn #:org "o1" #:label "house" #:executor "anything")
               "no document at either tier is the OFF state again"))

;; ---- 2. the label comes off the document, and the seam asks ------------------------

(define (declare-sensitivity! conn team)
  (repo-fields-declare! conn team
                        (list (hasheq 'key SENSITIVITY-KEY 'label "Sensitivity"))
                        #:subject "the executor policy's label"))

(define (up! conn p key text)
  (repo-put! conn p #:key key #:port (open-input-bytes (string->bytes/utf-8 text))
             #:content-type "text/plain" #:filename key #:visibility "team"))

(test-case "the label is read off the document's own LAY-4 attributes"
  (define conn (fresh))
  (define-values (uid tid) (bootstrap! conn #:username "alice"))
  (define alice (user-principal conn uid tid))
  ;; LAY-4 REFUSES AN UNDEFINED KEY, so a test that seeds the attribute by hand
  ;; has to declare the field first — and `repo-set-attributes!` answers a STRING
  ;; rather than raising, so a case that skips this passes for the wrong reason.
  (check-true (list? (declare-sensitivity! conn tid)))
  (define o (up! conn alice "in/a.txt" "hello"))
  (check-false (hash-ref (document-egress o #f) 'label) "nothing asserted yet")
  (define o2 (repo-set-attributes! conn alice (hash-ref o 'id)
                                   (hasheq (string->symbol SENSITIVITY-KEY) "confidential")))
  (check-true (hash? o2) (format "attributes refused: ~a" o2))
  (define d (document-egress o2 #f))
  (check-equal? (hash-ref d 'label) "confidential")
  (check-false (hash-ref d 'redacted))
  (check-equal? (hash-ref d 'object) (hash-ref o 'id))
  (check-equal? (hash-ref d 'team) tid "the DOCUMENT's team, which is where the audit entry belongs")
  (check-true (hash-ref (document-egress o2 (hasheq 'applied #t)) 'redacted)
              "and requirement 2's own record is what says the text was minimised"))

(test-case "THE GATE IS ASKED BEFORE ANYTHING IS SENT, and the refusal is a row"
  ;; The pull path, because it needs no socket: a pull executor's content leaves
  ;; by the job row, so the router standing in for a worker is the thing that
  ;; must NOT be reached.
  (define asked (box 0))
  (define rows (box '()))
  (parameterize ([current-egress-document (hasheq 'label "confidential" 'redacted #f
                                                  'object "obj-1" 'team "t1" 'org #f)])
    (define old-router (unbox pull-router))
    (define old-policy (unbox egress-policy))
    (define old-logger (unbox model-request-logger))
    (dynamic-wind
     void
     (lambda ()
       (set-box! pull-router (lambda (name msgs temp rf)
                               (set-box! asked (add1 (unbox asked)))
                               (cons "pulled: ok" 7)))
       (set-box! model-request-logger
                 (lambda (#:executor e #:transport t #:model m #:endpoint u #:messages msgs
                          #:tokens tok #:status st #:error-kind ek #:http-status hs #:ms ms)
                   (set-box! rows (cons (list e t st ek) (unbox rows)))))
       (set-box! egress-policy
                 (lambda (#:executor e #:endpoint u #:document d)
                   (and (equal? e "openai-gw") "refused by test policy")))
       ;; the disallowed one: refused, the router never asked, one `refused` row
       (check-exn exn:fail? (lambda () (run-chat "hello" #:executor "openai-gw")))
       (check-equal? (unbox asked) 0 "the router was not asked, so nothing was enqueued")
       (check-equal? (unbox rows) '(("openai-gw" "pull" "refused" "policy")))
       ;; and the allowed one goes through
       (set-box! rows '())
       (define-values (reply tokens) (run-chat "hello" #:executor "gpu-1"))
       (check-equal? reply "pulled: ok")
       (check-equal? (unbox asked) 1)
       (check-equal? (map third (unbox rows)) '("ok")))
     (lambda ()
       (set-box! pull-router old-router)
       (set-box! egress-policy old-policy)
       (set-box! model-request-logger old-logger)))))

(test-case "THE OTHER TWO TRANSPORTS ASK THE SAME GATE, before any socket is opened"
  ;; RED-16 is why this needs its own case rather than trust: `model-exchange`'s
  ;; own header calls itself the one place a request leaves and it is not —
  ;; `run-chat-stream` calls `openai-llm-stream` directly — so the push and the
  ;; stream sites each had to be gated by hand one requirement ago. The addresses
  ;; here are unroutable on purpose: if the gate did NOT fire, the call would
  ;; reach a socket and fail with something about the network instead, which is
  ;; exactly what distinguishes the two outcomes.
  (define old-policy (unbox egress-policy))
  (define old-url (getenv "TELEMACHUS_MODEL_URL"))
  (define (setenv! k v) (if v (putenv k v) (putenv k "")) (void))
  (dynamic-wind
   void
   (lambda ()
     (setenv! "TELEMACHUS_MODEL_URL" FAR)
     (set-box! egress-policy (lambda (#:executor e #:endpoint u #:document d)
                               "refused by test policy"))
     (parameterize ([current-egress-document (hasheq 'label "confidential" 'redacted #f)])
       ;; push
       (define e1 (with-handlers ([exn:fail? (lambda (e) e)])
                    (model-exchange (list (hasheq 'role "user" 'content "hi")))))
       (check-true (exn:fail:user? e1) "a deliberate refusal a caller has to see, so a 400 (#123)")
       (check-true (string-contains? (exn-message e1) "refused by test policy"))
       ;; stream
       (define e2 (with-handlers ([exn:fail? (lambda (e) e)])
                    (run-chat-stream "hi" (lambda (t) (void)))))
       (check-true (exn:fail:user? e2))
       (check-true (string-contains? (exn-message e2) "refused by test policy")))
     ;; The unlabelled half is asserted WITHOUT a call, in the case below: a
     ;; request that is not stopped runs to the network, and an unroutable
     ;; address blackholes rather than refusing — so proving it was not stopped
     ;; by letting it try costs the suite the whole model timeout.
     (void))
   (lambda ()
     (setenv! "TELEMACHUS_MODEL_URL" old-url)
     (set-box! egress-policy old-policy))))

(test-case "A POLICY THAT CANNOT BE READ REFUSES, and a BREAK still escapes"
  ;; The opposite of `log-model-request!`, which swallows its own failures: a log
  ;; that does not write costs a record, a control that does not run costs
  ;; somebody their document. And `exn:fail?` rather than a catch-all, for req
  ;; 3's reason — the model deadline shuts a custodian down with a break.
  (define old-policy (unbox egress-policy))
  (dynamic-wind
   void
   (lambda ()
     (parameterize ([current-egress-document (hasheq 'label "confidential" 'redacted #f)])
       (set-box! egress-policy (lambda (#:executor e #:endpoint u #:document d)
                                 (error 'policy "the database is gone")))
       (define bad (egress-refusal "gpu-1" FAR))
       (check-true (string? bad))
       (check-true (string-contains? bad "could not be read"))
       ;; a non-failure must pass straight through
       (set-box! egress-policy (lambda (#:executor e #:endpoint u #:document d)
                                 (raise 'a-break-like-thing)))
       (check-exn (lambda (e) (eq? e 'a-break-like-thing))
                  (lambda () (egress-refusal "gpu-1" FAR))))
     ;; …and an UNLABELLED request never asks at all, which is what keeps a
     ;; broken policy from stopping every model call on the instance
     (parameterize ([current-egress-document #f])
       (check-false (egress-refusal "gpu-1" FAR))))
   (lambda () (set-box! egress-policy old-policy))))

;; ---- 3. the requirement, through a real tool --------------------------------------

(test-case "ACCEPTANCE (#91): an unredacted step against a disallowed executor is refused and audited"
  ;; The issue's second acceptance criterion, word for word. A real document with
  ;; a real label, the real `doc_classify` tool, the real `run-chat`, the real
  ;; policy — and a stub pull router standing in for the worker, which is the
  ;; thing that must never be reached.
  (define conn (fresh))
  (define-values (uid tid) (bootstrap! conn #:username "alice"))
  (define alice (user-principal conn uid tid))
  (check-true (list? (declare-sensitivity! conn tid)))
  (define o0 (up! conn alice "in/letter.txt" "Dear Ms Patel, your claim 44719823 was received."))
  (check-true (hash? (repo-set-attributes! conn alice (hash-ref o0 'id)
                                           (hasheq (string->symbol SENSITIVITY-KEY) "confidential"))))
  (put-instance! conn (hasheq 'confidential (pol #:executors '("gpu-near"))))

  (define asked (box 0))
  (define old-router (unbox pull-router))
  (define old-policy (unbox egress-policy))
  (dynamic-wind
   void
   (lambda ()
     ;; THE SAME DECISION THE SERVER INSTALLS, not a copy of it
     (set-box! egress-policy (make-egress-policy conn))
     (set-box! pull-router (lambda (name msgs temp rf)
                             (set-box! asked (add1 (unbox asked)))
                             (cons (jsexpr->string
                                    (hasheq 'label "letter" 'confidence 0.9
                                            'rationale "it opens with Dear"))
                                   11)))
     (define labels (list (hasheq 'name "letter" 'description "a letter")))
     (define (classify! #:redact [redact #f] #:executor ex)
       (parameterize ([current-doc-chat
                       (lambda (prompt #:system [sys #f])
                         (run-chat prompt #:system sys #:temperature 0 #:executor ex))])
         ((tool-handler (tool-by-name "doc_classify")) conn alice
          (hash-set* (hasheq 'object (hash-ref o0 'id) 'labels labels 'backends '("llm"))
                     'redact redact))))

     ;; 1. REFUSED — and before the worker was ever asked
     (define e (with-handlers ([exn:fail? (lambda (e) e)]) (classify! #:executor "openai-gw")))
     (check-true (exn:fail? e) "the step was refused")
     (check-true (string-contains? (exn-message e) "confidential"))
     (check-equal? (unbox asked) 0 "nothing was enqueued for a worker to run")

     ;; 2. AUDITED, in the trail of the team whose document it was
     (define rs (query-rows conn (string-append
                                  "SELECT team_id, resource_id, result, meta FROM audit_log "
                                  "WHERE action = 'ai.egress.refused'")))
     (check-equal? (length rs) 1)
     (define r (car rs))
     (check-equal? (vector-ref r 0) tid "the DOCUMENT's team — audit-list filters on it")
     (check-equal? (vector-ref r 1) (hash-ref o0 'id))
     (check-equal? (vector-ref r 2) "refused")
     (define meta (string->jsexpr (vector-ref r 3)))
     (check-equal? (hash-ref meta 'label) "confidential")
     (check-equal? (hash-ref meta 'executor) "openai-gw")
     (check-false (hash-ref meta 'redacted))
     ;; NEVER THE TEXT, AND NEVER THE KEY, which routinely carries a name — this
     ;; log is chained, exported off the box and kept through an erasure
     (define m (vector-ref r 3))
     (check-false (string-contains? m "Patel"))
     (check-false (string-contains? m "44719823"))
     (check-false (string-contains? m "in/letter.txt"))

     ;; 3. THE CONTROL THAT MAKES THE REFUSAL MEAN SOMETHING: the executor the
     ;; policy DOES list runs the same step
     (define ok (classify! #:executor "gpu-near"))
     (check-equal? (hash-ref ok 'label) "letter")
     (check-equal? (unbox asked) 1)

     ;; 4. and requirement 2's `redact` is the other way through: the same
     ;; disallowed executor may have the text once it has been minimised
     (define ok2 (classify! #:executor "openai-gw" #:redact #t))
     (check-equal? (hash-ref ok2 'label) "letter")
     (check-equal? (unbox asked) 2)
     (check-true (hash-ref (hash-ref ok2 'redaction) 'applied)))
   (lambda () (set-box! pull-router old-router) (set-box! egress-policy old-policy))))

(test-case "a document with no label runs the same step against the same executor"
  ;; The policy governs what somebody MARKED. Without this the feature would be
  ;; indistinguishable from turning the model off.
  (define conn (fresh))
  (define-values (uid tid) (bootstrap! conn #:username "bob"))
  (define bob (user-principal conn uid tid))
  (define o0 (up! conn bob "in/plain.txt" "Dear Sir, your claim was received."))
  (put-instance! conn (hasheq 'confidential (pol #:executors '())))
  (define old-router (unbox pull-router))
  (define old-policy (unbox egress-policy))
  (dynamic-wind
   void
   (lambda ()
     (set-box! egress-policy (make-egress-policy conn))
     (set-box! pull-router (lambda (name msgs temp rf)
                             (cons (jsexpr->string (hasheq 'label "letter" 'confidence 0.9
                                                           'rationale "Dear Sir"))
                                   3)))
     (define r
       (parameterize ([current-doc-chat
                       (lambda (prompt #:system [sys #f])
                         (run-chat prompt #:system sys #:temperature 0 #:executor "openai-gw"))])
         ((tool-handler (tool-by-name "doc_classify")) conn bob
          (hasheq 'object (hash-ref o0 'id) 'backends '("llm")
                  'labels (list (hasheq 'name "letter" 'description "a letter"))))))
     (check-equal? (hash-ref r 'label) "letter"))
   (lambda () (set-box! pull-router old-router) (set-box! egress-policy old-policy))))

(test-case "the evaluation harness is governed PER FIXTURE, not once for the batch"
  ;; The label is a property of each document, so binding the first fixture's for
  ;; the whole fold would govern a labelled document by an unlabelled one's
  ;; answer — and the harness sends UNREDACTED text (CLS-33: it measures the
  ;; backends as production runs them), so the policy applies to it. A refusal
  ;; lands as that backend's `error` outcome for that one document, which is
  ;; CLS-30's third outcome, rather than costing the whole report.
  (define conn (fresh))
  (define-values (uid tid) (bootstrap! conn #:username "carol"))
  (define carol (user-principal conn uid tid))
  (check-true (list? (declare-sensitivity! conn tid)))
  (check-true (list? (repo-fields-declare! conn tid EVAL-FIELDS #:subject "the fixtures")))
  (define (fixture! key text #:label [label #f])
    (define o (up! conn carol key text))
    (define a (hasheq EVAL-FIELD "letter"))
    (define r (repo-set-attributes! conn carol (hash-ref o 'id)
                                    (if label
                                        (hash-set a (string->symbol SENSITIVITY-KEY) label)
                                        a)))
    (check-true (hash? r) (format "attributes refused: ~a" r))
    r)
  (fixture! "fx/a.txt" "Dear Sir, one." #:label "confidential")
  (fixture! "fx/b.txt" "Dear Madam, two.")
  (put-instance! conn (hasheq 'confidential (pol #:executors '())))

  (define old-router (unbox pull-router))
  (define old-policy (unbox egress-policy))
  (dynamic-wind
   void
   (lambda ()
     (set-box! egress-policy (make-egress-policy conn))
     (set-box! pull-router
               (lambda (name msgs temp rf)
                 (cons (jsexpr->string (hasheq 'label "letter" 'confidence 0.9
                                                'rationale "it opens with Dear"))
                       5)))
     (define r
       (parameterize ([current-doc-chat
                       (lambda (prompt #:system [sys #f])
                         (run-chat prompt #:system sys #:temperature 0 #:executor "openai-gw"))])
         ((tool-handler (tool-by-name "doc_classify_eval")) conn carol
          (hasheq 'prefix "fx/" 'backends '("llm")
                  'labels (list (hasheq 'name "letter" 'description "a letter"))))))
     (define by-key
       (for/hash ([row (in-list (hash-ref r 'rows))])
         (values (hash-ref row 'key) (hash-ref (hash-ref row 'answers) 'llm))))
     (check-equal? (hash-count by-key) 2 "both fixtures were measured")
     (check-equal? (hash-ref (hash-ref by-key "fx/a.txt") 'outcome) "error"
                   "the labelled fixture was refused, on its own row")
     (check-true (string-contains? (hash-ref (hash-ref by-key "fx/a.txt") 'reason) "confidential"))
     (check-equal? (hash-ref (hash-ref by-key "fx/b.txt") 'outcome) "answered"
                   "and the unlabelled one still answered, which is the half a single binding loses"))
   (lambda () (set-box! pull-router old-router) (set-box! egress-policy old-policy))))
