#lang racket/base

;; domain/ai/sensitivity.rkt — where a labelled document's text may go.
;; Issue #91 requirement 4 (RED-24…RED-33).
;;
;; This is the teeth of #91. Requirements 1 and 2 built the means to minimise
;; what a model is told and requirement 3 built the record of what was sent;
;; neither one STOPS anything. What this module decides is whether a model
;; request carrying the text of a document that somebody has marked sensitive may
;; be made at all — a per-org list of the executors allowed to see that label's
;; text unredacted, and a refusal when the executor is not on it.
;;
;; THE LABEL IS A LAY-4 OBJECT ATTRIBUTE, `sensitivity`, which is why this slice
;; needs no migration and no new vocabulary: LAY-4 is already "what the team
;; ASSERTS about a document", a team defines the field and its options as it
;; defines any other, and `?attr=sensitivity:confidential` lists them for
;; nothing. The policy names labels; the team's own field definition is what
;; makes a label settable. The two can drift, and the refusal REPORTS the drift
;; (it names the labels the policy does list) rather than hiding it.
;;
;; OFF UNLESS CONFIGURED. With no policy document at either tier nothing is
;; refused, whatever a document is labelled — every default-bearing knob in this
;; tree makes the same call (the retention horizon, the worker-token lifetime,
;; `TELEMACHUS_REQUIRE_NO_CONTENT_LOGGING` one requirement earlier), and here the
;; alternative is worse than usual: a team that already uses an attribute called
;; `sensitivity` for something of its own would find every AI step refused by an
;; upgrade it did not ask for.

(require db-kit/portable json racket/list racket/string
         "../settings/settings.rkt"
         (only-in "../authz/authz.rkt" audit!)
         (only-in "egress.rkt" endpoint-hosted? endpoint-host))

(provide SENSITIVITY-KEY MAX-POLICY-LABELS
         executor-policy-ref executor-policy-set! executor-policy-clear!
         executor-policy-problem executor-policy-configured?
         executor-policy-effective executor-policy-sources
         sensitivity-refusal make-egress-policy)

;; The one attribute key, fixed like `doc_type` (CLS-7) rather than configurable:
;; a policy that named its own key would let two documents be sensitive in two
;; different vocabularies, and `?attr=` is an equality filter over one key.
(define SENSITIVITY-KEY "sensitivity")

;; A label's entry. CLOSED — an unknown field is refused rather than dropped
;; (WF-10's rule): a policy field that does nothing is how an operator comes to
;; believe a protection is in force.
(define POLICY-FIELDS '(executors default_model allow_redacted))

;; Bounded for LAY-4's reason: the document is operator-authored and is read on
;; the path of a model call.
(define MAX-POLICY-LABELS 100)
(define MAX-POLICY-EXECUTORS 50)

;; An entry that permits nothing. It is what a label present at one tier and
;; absent from the other does NOT get — see `combine` below.
(define DENY (hasheq 'executors '() 'default_model #f 'allow_redacted #f))

;; ---- the documents ---------------------------------------------------------------

(define (key-for scope id)
  (case scope
    [(instance) "executor-policy:instance"]
    [(org) (string-append "executor-policy:org:" id)]
    [else (error 'executor-policy "unknown scope ~a" scope)]))

;; #f when the tier has no document at all, which is what makes "off unless
;; configured" expressible: an EMPTY `labels` object is an operator saying
;; "govern nothing", and absence is an operator who has not been here.
(define (executor-policy-ref conn scope [id ""])
  (setting-ref conn (key-for scope id) #f))

(define (str-list v)
  (and (list? v) (andmap string? v)))

(define (entry-problem label e)
  (cond
    [(not (hash? e)) (format "label ~a: the entry must be a JSON object" label)]
    [(for/or ([k (in-hash-keys e)]) (and (not (memq k POLICY-FIELDS)) k))
     => (lambda (k) (format "label ~a: unknown field ~a (expected ~a)" label k
                            (string-join (map symbol->string POLICY-FIELDS) ", ")))]
    [(and (hash-has-key? e 'executors) (not (str-list (hash-ref e 'executors))))
     (format "label ~a: executors must be a list of executor names" label)]
    [(> (length (hash-ref e 'executors '())) MAX-POLICY-EXECUTORS)
     (format "label ~a: at most ~a executors" label MAX-POLICY-EXECUTORS)]
    [(for/or ([n (in-list (hash-ref e 'executors '()))])
       (and (string=? (string-trim n) "") n))
     (format "label ~a: an executor name cannot be empty" label)]
    [(and (hash-has-key? e 'default_model) (not (boolean? (hash-ref e 'default_model))))
     (format "label ~a: default_model must be true or false" label)]
    [(and (hash-has-key? e 'allow_redacted) (not (boolean? (hash-ref e 'allow_redacted))))
     (format "label ~a: allow_redacted must be true or false" label)]
    [else #f]))

;; -> #f, or one sentence naming what is wrong.
(define (executor-policy-problem doc)
  (cond
    [(not (hash? doc)) "the policy must be a JSON object"]
    [(for/or ([k (in-hash-keys doc)]) (and (not (eq? k 'labels)) k))
     => (lambda (k) (format "unknown field ~a (expected labels)" k))]
    [(not (hash? (hash-ref doc 'labels (hasheq)))) "labels must be a JSON object"]
    [(> (hash-count (hash-ref doc 'labels (hasheq))) MAX-POLICY-LABELS)
     (format "at most ~a labels" MAX-POLICY-LABELS)]
    [(for/or ([l (in-hash-keys (hash-ref doc 'labels (hasheq)))])
       (and (string=? (string-trim (symbol->string l)) "") l))
     "a label cannot be empty"]
    [else
     (for/or ([(l e) (in-hash (hash-ref doc 'labels (hasheq)))])
       (entry-problem l e))]))

;; Every field present and of the declared type, so a stored document is always
;; already valid and the readers below need no defaults of their own. The
;; defaults ARE the policy's posture: an executor list permits only what it
;; names, the unnamed configured model is not on any list until somebody says so
;; (`default_model` false), and redacted text may travel (`allow_redacted` true)
;; because that is what requirements 1 and 2 exist to make safe.
(define (normalize doc)
  (hasheq 'labels
          (for/hasheq ([(l e) (in-hash (hash-ref doc 'labels (hasheq)))])
            (values l (hasheq 'executors (remove-duplicates
                                          (map string-trim (hash-ref e 'executors '())))
                              'default_model (hash-ref e 'default_model #f)
                              'allow_redacted (hash-ref e 'allow_redacted #t))))))

(define (executor-policy-set! conn scope id doc)
  (define bad (executor-policy-problem doc))
  (when bad (raise-user-error 'executor-policy "~a" bad))
  (setting-set! conn (key-for scope id) (normalize doc))
  (normalize doc))

(define (executor-policy-clear! conn scope id)
  (setting-clear! conn (key-for scope id)))

;; ---- the two tiers ---------------------------------------------------------------

(define (tiers conn org)
  (filter cdr (list (cons 'instance (executor-policy-ref conn 'instance))
                    (cons 'org (and org (executor-policy-ref conn 'org org))))))

(define (executor-policy-configured? conn org)
  (pair? (tiers conn org)))

;; TIGHTEN WHERE BOTH TIERS SPEAK — SESS-4's rule, and the qualification is what
;; makes it usable on a multi-tenant instance. For a label both documents
;; mention, the instance is a ceiling: the permitted executors are the
;; INTERSECTION and both booleans are ANDed, so a company can narrow what the
;; instance allows and can never widen it. A label only ONE tier mentions is that
;; tier's to decide — were an unmentioned label a denial, the instance operator
;; would have to enumerate every company's own vocabulary before any company
;; could permit anything, and the labels are the company's.
(define (combine a b)
  (hasheq 'executors (for/list ([n (in-list (hash-ref a 'executors))]
                                #:when (member n (hash-ref b 'executors)))
                       n)
          'default_model (and (hash-ref a 'default_model) (hash-ref b 'default_model))
          'allow_redacted (and (hash-ref a 'allow_redacted) (hash-ref b 'allow_redacted))))

(define (executor-policy-effective conn org)
  (define ts (tiers conn org))
  (hasheq 'labels
          (for/hasheq ([l (in-list (remove-duplicates
                                    (append* (for/list ([t (in-list ts)])
                                               (hash-keys (hash-ref (cdr t) 'labels (hasheq)))))))])
            (values l (for/fold ([acc #f]) ([t (in-list ts)])
                        (define e (hash-ref (hash-ref (cdr t) 'labels (hasheq)) l #f))
                        (cond [(not e) acc]
                              [(not acc) e]
                              [else (combine acc e)]))))))

;; WHICH TIERS mentioned each label, because "why was my document refused" is the
;; question somebody actually asks and two documents diffed by hand is a poor
;; answer. retention-sources' shape.
(define (executor-policy-sources conn org)
  (define ts (tiers conn org))
  (for/hasheq ([(l _e) (in-hash (hash-ref (executor-policy-effective conn org) 'labels))])
    (values l (for/list ([t (in-list ts)]
                         #:when (hash-has-key? (hash-ref (cdr t) 'labels (hasheq)) l))
                (symbol->string (car t))))))

;; The effective entry for one label, or #f when no tier mentions it.
(define (label-entry conn org label)
  (and (string? label) (not (string=? (string-trim label) ""))
       (hash-ref (hash-ref (executor-policy-effective conn org) 'labels)
                 (string->symbol label) #f)))

;; ---- the decision ----------------------------------------------------------------

;; The refusal never names the document's KEY, though its reader usually owns the
;; document: the same sentence is stored as the audit entry's `reason`, and that
;; log is chained, exported off the box and kept through an erasure, so a key —
;; which routinely carries somebody's name — would outlive every other copy of it
;; (AUD-2). "The document this request carries" is what is left to say.
(define (name-of executor) (or executor "the configured default model"))

(define (allowed-str e)
  (define ns (append (sort (hash-ref e 'executors) string<?)
                     (if (hash-ref e 'default_model) '("the configured default model") '())))
  (if (null? ns) "no executor" (string-join ns ", ")))

;; -> #f to allow, or one sentence naming the label, the executor and the remedy.
;;
;;   label      the document's `sensitivity` attribute, #f when it carries none
;;   redacted?  whether the text this request carries went through requirement 2
;;   executor   the resolved executor NAME, #f for the configured default model
;;   endpoint   its URL, #f for a pull executor (which has none)
;;
;; A LOOPBACK BACKEND IS OUTSIDE THE POLICY ENTIRELY, which is the same exemption
;; `content-logging-refusal` makes one requirement earlier and for the same
;; reason: nothing left the box, so there is nothing for an allowlist to allow.
;; That is what keeps the ordinary single-box instance talking to ollama out of
;; this feature's way. A PULL executor has no endpoint and therefore counts as
;; hosted (RED-21's rule, since the platform does not know and must not guess
;; which model URL a worker will call), so a labelled document going to a worker
;; IS governed — which is right: the content leaves by the job row.
(define (sensitivity-refusal conn #:org org #:label label #:redacted? redacted?
                             #:executor executor #:endpoint endpoint)
  (cond
    [(not (and (string? label) (not (string=? (string-trim label) "")))) #f]
    [(not (executor-policy-configured? conn org)) #f]
    [(not (endpoint-hosted? endpoint)) #f]
    [else
     (define e (label-entry conn org label))
     (define listed
       (and e (if executor
                  (and (member executor (hash-ref e 'executors)) #t)
                  (hash-ref e 'default_model))))
     (cond
       ;; A LABEL NO TIER MENTIONS IS REFUSED, and this is the one place in the
       ;; slice that fails closed on an absence. It is deliberately the opposite
       ;; of LAY-9's "an absent capability is unknown and unknown is permissive",
       ;; because the two absences are not the same thing: a document with NO
       ;; label is nobody asserting anything, and is allowed by construction a
       ;; few lines above; a document somebody marked sensitive against a policy
       ;; that does not mention the mark is an assertion nobody has answered, and
       ;; the only way to reach it is to remove a label from the policy while
       ;; documents still carry it. Quietly un-protecting exactly those documents
       ;; is the worse failure.
       [(not e)
        (format (string-append
                 "the document this request carries is labelled ~a and the executor policy "
                 "does not list that label, so this instance will not send its text anywhere "
                 "(the policy lists: ~a)")
                label
                (let ([ls (sort (map symbol->string
                                     (hash-keys (hash-ref (executor-policy-effective conn org) 'labels)))
                                string<?)])
                  (if (null? ls) "no labels at all" (string-join ls ", "))))]
       [listed #f]
       ;; THE ALLOWLIST IS FOR UNREDACTED TEXT, which is requirement 4 read as
       ;; written ("prevents UNREDACTED text from reaching any executor not on
       ;; the list"). Tokenised text may travel to a backend that is not on it,
       ;; because making exactly that safe is what requirements 1 and 2 are for —
       ;; and an operator who disagrees sets `allow_redacted: false` on the label,
       ;; which puts the list back in charge of everything.
       [(and redacted? (hash-ref e 'allow_redacted)) #f]
       [redacted?
        (format (string-append
                 "the document this request carries is labelled ~a, whose policy allows no "
                 "executor outside its own list, and ~a is not on it (allowed: ~a)")
                label (name-of executor) (allowed-str e))]
       [else
        (format (string-append
                 "the document this request carries is labelled ~a and ~a is not allowed to see "
                 "that label's text unredacted (allowed: ~a) — redact the step, or add the "
                 "executor to the policy")
                label (name-of executor) (allowed-str e))])]))

;; ---- the decision, as `executor.rkt` asks it (RED-28) ----------------------------

;; The lambda `server/main.rkt` puts in `egress-policy`. It is HERE rather than
;; inline there for one reason: the acceptance test drives a real tool through a
;; real `run-chat`, so it has to install the same decision the server does, and a
;; test that installed its own copy would agree with any change to this one —
;; `executor-can-run?`'s drift, in the one place this slice could least afford it.
;;
;; `context` is a THUNK answering `(hasheq 'org o 'user u 'team t)` for the
;; request or job in flight. A thunk because the request principal is a parameter
;; in `server/kit.rkt`, and a domain module that required kit would instantiate
;; the connection pool — which is exactly how #123's rule was earned. Same shape
;; as `startup-problems`' `#:blob-probe`.
;;
;; A FAILED AUDIT WRITE DOES NOT RESCUE THE REQUEST. The refusal stands and the
;; failure goes to stderr: letting a labelled document travel because the record
;; of refusing it could not be stored would be the one failure this exists to
;; prevent.
(define (make-egress-policy conn #:context [context (lambda () (hasheq))])
  (lambda (#:executor executor #:endpoint endpoint #:document doc)
    (define ctx (context))
    ;; THE ORG IS THE DOCUMENT'S, not the caller's: a company's policy governs its
    ;; own documents, and on a cross-team share the two differ — reading it off
    ;; the principal would let a reader's company decide where another company's
    ;; document may be sent. The caller's is the fallback for a request whose
    ;; document carries none, which on a single-tenant instance is all of them.
    (define org (or (hash-ref doc 'org #f) (hash-ref ctx 'org #f)))
    (define label (hash-ref doc 'label #f))
    (define redacted? (and (hash-ref doc 'redacted #f) #t))
    (define bad (sensitivity-refusal conn #:org org #:label label #:redacted? redacted?
                                     #:executor executor #:endpoint endpoint))
    (when bad
      (with-handlers ([exn:fail? (lambda (e)
                                   (eprintf "ai.egress.refused audit: ~a\n" (exn-message e)))])
        (audit! conn #:action "ai.egress.refused" #:result "refused"
                #:actor-type "user"
                #:actor-id (or (hash-ref ctx 'user #f) sql-null)
                ;; the DOCUMENT's team, which is where somebody asking "what was
                ;; stopped" would look — `audit-list` filters on it, and this is
                ;; the eighth appearance of that shape in these notes
                #:team-id (or (hash-ref doc 'team #f) (hash-ref ctx 'team #f) sql-null)
                #:org-id org
                #:resource-type "repo" #:resource-id (or (hash-ref doc 'object #f) sql-null)
                ;; the label, the backend and the reason. NEVER the text, and
                ;; never the object KEY, which routinely carries a name (AUD-2) —
                ;; this log is chained, exported off the box and deliberately
                ;; kept through an erasure, so it outlives every other copy.
                #:meta (jsexpr->string
                        (hasheq 'label (or label 'null)
                                'executor (or executor 'null)
                                'endpoint (or (endpoint-host endpoint) 'null)
                                'redacted redacted?
                                'reason bad)))))
    bad))

