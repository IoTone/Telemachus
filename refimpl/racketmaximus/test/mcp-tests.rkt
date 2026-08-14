#lang racket/base

;; test/mcp-tests.rkt — MCP client + registration, against a Racket mock MCP
;; server (test/mock-mcp.rkt). No external deps.  raco test test/mcp-tests.rkt

(require rackunit
         racket/runtime-path
         racket/file
         json
         db
         db-kit/migrate
         "../domain/mcp/client.rkt"
         "../domain/mcp/connect.rkt"
         "../domain/agent/registry.rkt"
         "../domain/agent/run.rkt"          ; dispatch-tool
         "../domain/db/migrations.rkt"
         "../domain/authz/authz.rkt")

(define-runtime-path mock "mock-mcp.rkt")
(define (fresh) (define c (sqlite3-connect #:database 'memory)) (migrate! c all-migrations) c)

(test-case "mcp client: initialize, tools/list, tools/call"
  (define c (mcp-connect "racket" (list (path->string mock))))
  (check-equal? (map (lambda (t) (hash-ref t 'name)) (mcp-list-tools c)) '("add"))
  (check-equal? (mcp-call-tool c "add" (hasheq 'a 2 'b 3)) "5")
  (check-equal? (mcp-call-tool c "add" (hasheq 'a 40 'b 2)) "42")
  (mcp-close c))

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
