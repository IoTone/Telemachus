#lang racket/base

;; test/mcp-tests.rkt — MCP client + registration, against a Racket mock MCP
;; server (test/mock-mcp.rkt). No external deps.  raco test test/mcp-tests.rkt

(require rackunit
         racket/string
         racket/runtime-path
         racket/file
         racket/tcp
         json
         db-kit/portable
         db-kit/migrate
         "../domain/mcp/client.rkt"
         "../domain/mcp/connect.rkt"
         "../domain/agent/registry.rkt"
         "../domain/agent/run.rkt"          ; dispatch-tool
         "../domain/db/migrations.rkt"
         "db-fixture.rkt"
         "../domain/authz/authz.rkt")

(define-runtime-path mock "mock-mcp.rkt")
(define-runtime-path mock-http "mock-mcp-http.rkt")
(define-runtime-path version-file "../VERSION")
(define (fresh) (define c (fresh-db #:migrate? #f)) (migrate! c all-migrations) c)

(test-case "mcp client: initialize, tools/list, tools/call"
  (define c (mcp-connect "racket" (list (path->string mock))))
  (check-equal? (map (lambda (t) (hash-ref t 'name)) (mcp-list-tools c)) '("add"))
  (check-equal? (mcp-call-tool c "add" (hasheq 'a 2 'b 3)) "5")
  (check-equal? (mcp-call-tool c "add" (hasheq 'a 40 'b 2)) "42")
  (mcp-close c))

;; ---- SEC-12 (#186): a remote server's error is bounded and printable -------------
;; SEC-8 recorded `domain/mcp/client.rkt` as `provider-detail`'s fourth asker and
;; left it as a refactor. It was not only a duplication: this client formatted
;; `error.message` WHOLE, and the model seam it was supposed to match turned out
;; to be missing the control-character half as well — which `mail/transport.rkt`
;; has had all along, with a comment saying "no forged log lines is a property
;; every message wants".
;;
;; It matters here for the same reason it matters there: this message becomes an
;; exception, which reaches a stored `error` column and stderr.
(test-case "mcp: a remote server's error cannot forge a log line or fill the log"
  (define c (mcp-connect "racket" (list (path->string mock))))
  (define msg
    (with-handlers ([exn:fail? (lambda (e) (exn-message e))])
      (mcp-call-tool c "boom" (hasheq))
      "the server did not refuse, so this case proved nothing"))
  (mcp-close c)
  (check-false (regexp-match? #rx"\n" msg)
               "a newline in somebody else's error must not survive into a log line")
  (check-false (regexp-match? #rx"\r" msg))
  (check-true (< (string-length msg) 500)
              (format "bounded; got ~a characters" (string-length msg)))
  (check-true (and (regexp-match? #rx"truncated" msg) #t)
              "and it says it was cut")
  ;; …and the detail SURVIVES, because it is the operator's only diagnostic for a
  ;; server that will not answer.
  (check-true (and (regexp-match? #rx"refused" msg) #t)))

(test-case "mcp registration: server tools land in the registry + dispatch via RBAC"
  (define cfg (make-temporary-file "tmx-mcp-~a.json"))
  (call-with-output-file cfg #:exists 'replace
    (lambda (out) (write-json (hasheq 'servers (list (hasheq 'name "mock" 'command "racket"
                                                             'args (list (path->string mock))))) out)))
  (connect-mcp-servers! cfg)
  (define t (tool-by-name "mcp__mock__add"))
  (check-true (and t #t))
  (check-equal? (tool-source t) "mcp:mock")
  (check-true (for/or ([s (in-list (mcp-servers))]) (string=? (hash-ref s 'name) "mock")))
  (define conn (fresh))
  (define-values (uid tid) (bootstrap! conn #:username "alice"))
  (check-equal? (dispatch-tool conn (user-principal conn uid tid) "mcp__mock__add" (hasheq 'a 10 'b 5)) "15")
  (delete-file cfg))

(test-case "mcp Streamable HTTP transport: connect, list, call"
  (define p 8913)
  (define-values (proc o i e) (subprocess #f #f #f (find-executable-path "racket") (path->string mock-http) (number->string p)))
  (let loop ([n 0])                                   ; wait for the server to bind
    (define up (with-handlers ([exn:fail? (lambda (_) #f)])
                 (define-values (ci co) (tcp-connect "127.0.0.1" p))
                 (close-input-port ci) (close-output-port co) #t))
    (unless (or up (> n 200)) (sleep 0.05) (loop (add1 n))))
  (define c (mcp-connect-http (format "http://127.0.0.1:~a/" p)))
  (check-equal? (map (lambda (t) (hash-ref t 'name)) (mcp-list-tools c)) '("add"))
  (check-equal? (mcp-call-tool c "add" (hasheq 'a 7 'b 8)) "15")
  (mcp-close c)
  (subprocess-kill proc #t))


;; A server that logs the client version must not be told a build that shipped
;; two releases ago. The constant is local to the client; VERSION is the release
;; of record, so the two are pinned here rather than read at runtime.
(module+ test
  (test-case "the announced MCP client version equals VERSION"
    (define on-disk (string-trim (file->string version-file)))
    (check-equal? mcp-client-version on-disk)))
