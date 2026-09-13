#lang racket/base

;; server/routes.rkt — the HTTP surface, declared (slice 60, DOCGEN-2).
;;
;; Every route is one entry: method, path pattern, the handler's KEY, the
;; permission it enforces (if any), how it authenticates, the feature flag it
;; sits behind, and one line of documentation. `route` in server/main.rkt
;; dispatches over this list, and `telemachus-docs` renders docs/reference/api.md
;; from it — so the table is the documentation, and public-ness is DECLARED rather
;; than a comment beside a cond clause. main.rkt refuses to boot if an entry names
;; a handler it does not have, or has a handler no entry names.
;;
;; This module is pure data on purpose: no database, no server, so the docs CLI
;; can require it without booting anything.
;;
;; Path patterns: literal segments, `:name` for one segment, `*name` for the rest
;; of the path (joined with "/"). First match wins, in list order — keep a
;; specific pattern (/api/workflows/schema) above the parameterized one it would
;; otherwise fall into (/api/workflows/:slug).
;;
;; `auth`: 'public (no credential), 'bearer (a session or API token — `with-auth`
;; or `current-principal`), 'provision (the hosted-mode provisioning token),
;; 'superadmin / 'org-admin (the two multi-tenancy planes). The permission is the
;; one the handler ENFORCES with require-perm on its main path; owner-ok and
;; resource grants may admit a caller the role would not (see the RBAC design).

(require racket/string racket/list)

(provide (struct-out rt) ROUTES match-route route-params)

(struct rt (method path handler auth perm feature doc) #:transparent)

(define (R method path handler
           #:auth [auth 'bearer] #:perm [perm #f] #:feature [feature #f] #:doc doc)
  (rt method path handler auth perm feature doc))

(define ROUTES
  (list
   ;; ---- the console and static assets ------------------------------------------------
   (R "GET" "/"            'ui #:auth 'public #:doc "The console (or the beta funnel when TELEMACHUS_HOME=beta). The HTML title is rewritten from instance branding.")
   (R "GET" "/index.html"  'ui #:auth 'public #:doc "The console.")
   (R "GET" "/login"       'ui #:auth 'public #:doc "The console, sign-in first — a URL that never depends on the beta landing.")
   (R "GET" "/activate"    'ui #:auth 'public #:doc "The console, on the magic-link activation screen (hosted mode).")
   (R "GET" "/health"      'health #:auth 'public #:doc "Liveness: {ok, service, version}.")
   (R "GET" "/beta-sdk.js" 'beta-sdk #:auth 'public #:doc "The browser SDK a Tier-B onboarding bundle loads (window.Telemachus.beta).")
   (R "GET" "/beta/bundle/:plugin/*path" 'bundle-file #:auth 'public #:doc "A file from a Tier-B onboarding plugin's bundle directory.")
   (R "GET" "/beta/template" 'beta-template #:auth 'public #:doc "The Tier-C sandboxed HTML template, localized by the experience overlay.")

   ;; ---- instance: config, branding, localization ------------------------------------
   (R "GET" "/api/config"   'config #:auth 'public #:doc "Public instance configuration: home mode, multi-tenancy flag, the localization policy (default locale, available locales, whether switching is enabled). The sign-in screen reads it before anyone has a token.")
   (R "GET" "/api/branding" 'branding-get #:auth 'public #:doc "Instance title, tagline and logo. Public: the sign-in screen renders them.")
   (R "PUT" "/api/branding" 'branding-put #:perm "instance:manage" #:doc "Set the instance title and tagline.")
   (R "POST" "/api/branding/logo" 'branding-logo #:perm "instance:manage" #:doc "Upload the instance logo (replaces the mark and the wordmark).")
   (R "GET" "/api/i18n/catalog" 'i18n-catalog #:auth 'public #:doc "The console's strings for ?locale=, resolved through the fallback chain server-side. Public: the sign-in screen needs them.")
   (R "PUT" "/api/i18n" 'i18n-put #:perm "instance:manage" #:doc "Set the instance default locale and whether users may switch.")
   (R "GET" "/api/l10n/coverage" 'l10n-coverage #:perm "localization:read" #:doc "Per-locale coverage of the Localization Manager's catalog: total, approved, machine, missing, stale.")
   (R "GET" "/api/l10n/messages" 'l10n-messages #:perm "localization:read" #:doc "The messages of one locale, filterable by ?status=, ?ns=, ?q=, paged.")
   (R "POST" "/api/l10n/import" 'l10n-import #:perm "localization:manage" #:doc "Pull the catalogs on disk into the Manager's tables.")
   (R "POST" "/api/l10n/export" 'l10n-export #:perm "localization:manage" #:doc "Write a locale's APPROVED strings back to locales/<locale>.json. Refuses a locale with nothing approved.")
   (R "POST" "/api/l10n/draft" 'l10n-draft #:perm "localization:manage" #:doc "Queue AI drafts for a locale's missing strings, in batches of 20 scheduler jobs, quota-metered.")
   (R "POST" "/api/l10n/discard" 'l10n-discard #:perm "localization:manage" #:doc "Remove a locale's machine drafts (never a human's work).")
   (R "PUT" "/api/l10n/messages/:id" 'l10n-submit #:perm "localization:translate" #:doc "Submit a translation for one message.")
   (R "POST" "/api/l10n/review/:id" 'l10n-review #:perm "localization:review" #:doc "Approve or send back a translation. A translator cannot approve their own.")

   ;; ---- beta onboarding ----------------------------------------------------------------
   (R "GET" "/api/beta/config" 'beta-config #:auth 'public #:doc "The published onboarding experience's public slice (fields, copy, theme) in one language.")
   (R "OPTIONS" "/api/beta/signup" 'cors-preflight #:auth 'public #:doc "CORS preflight for a sandboxed Tier-C template.")
   (R "OPTIONS" "/api/beta/config" 'cors-preflight #:auth 'public #:doc "CORS preflight for a sandboxed Tier-C template.")
   (R "OPTIONS" "/api/beta/challenge" 'cors-preflight #:auth 'public #:doc "CORS preflight for a sandboxed Tier-C template.")
   (R "GET" "/api/beta/experience" 'beta-experience-get #:doc "The team's draft onboarding experience, including the judge prompt.")
   (R "PUT" "/api/beta/experience" 'beta-experience-put #:doc "Save a draft of the onboarding experience.")
   (R "POST" "/api/beta/experience/publish" 'beta-experience-publish #:doc "Publish the saved draft; it then wins over the ENV-seeded default.")
   (R "POST" "/api/beta/assets" 'beta-asset-upload #:doc "Upload an onboarding asset (logo, hero image, font), base64 in JSON, capped at 2 MiB.")
   (R "GET" "/api/beta/assets" 'beta-assets #:doc "List the team's onboarding assets.")
   (R "GET" "/api/beta/asset/:id" 'beta-asset #:auth 'public #:doc "Serve one onboarding asset. Public: the funnel and the branding logo load it without a token.")
   (R "DELETE" "/api/beta/asset/:id" 'beta-asset-delete #:doc "Delete an onboarding asset.")
   (R "GET" "/api/beta/challenge" 'beta-challenge #:auth 'public #:doc "A proof-of-work challenge the funnel solves before signing up.")
   (R "POST" "/api/beta/signup" 'beta-signup #:auth 'public #:doc "Submit the onboarding form: validated against the published experience, anti-abuse gated, judged by the model when configured.")
   (R "GET" "/api/beta/prospects" 'beta-prospects #:doc "List the prospects the funnel captured, with signals and verdicts.")
   (R "POST" "/api/beta/prospects/:id/decide" 'beta-decide #:doc "Accept or decline a prospect.")

   ;; ---- accounts, sessions, hosted provisioning ---------------------------------------
   (R "POST" "/api/bootstrap" 'bootstrap #:auth 'public #:doc "First run only: create the operator, the first org and team. Returns the operator's token. Refuses once the instance has a user.")
   (R "POST" "/api/provision" 'provision #:auth 'provision #:doc "Hosted mode: provision this instance with exactly one owner and a magic activation link.")
   (R "POST" "/api/activate" 'activate #:auth 'public #:doc "Hosted mode: redeem an activation token and set the owner's password.")
   (R "POST" "/api/instance/suspend" 'tenant-suspend #:auth 'provision #:doc "Hosted mode: suspend the tenant (writes are refused with 402).")
   (R "POST" "/api/instance/resume" 'tenant-resume #:auth 'provision #:doc "Hosted mode: resume a suspended tenant.")
   (R "POST" "/api/instance/quota" 'instance-quota #:auth 'provision #:doc "Hosted mode: set a quota limit for the tenant's team.")
   (R "POST" "/api/login" 'login #:auth 'public #:doc "Sign in with username and password (and a TOTP code when 2FA is enabled). Returns a bearer token.")
   (R "POST" "/api/2fa/enable" '2fa-enable #:doc "Enable TOTP two-factor authentication for the caller; returns the secret once.")
   (R "POST" "/api/password" 'password #:doc "Change the caller's password.")
   (R "GET" "/api/whoami" 'whoami #:doc "The caller: user, team, operator flag, org, org role, locale, permissions.")
   (R "POST" "/api/profile" 'profile #:doc "Update the caller's profile (display name, locale).")
   (R "POST" "/api/members" 'add-member #:perm "members:manage" #:doc "Add a member to the caller's team with a role; returns the new member's first token.")
   (R "GET" "/api/members" 'members-list #:doc "The team's members and roles.")
   (R "GET" "/api/admin/status" 'admin-status #:perm "instance:manage" #:doc "Instance counts: users, teams, orgs, notes, tokens, audit events, tenants.")

   ;; ---- multi-tenancy: superadmin plane, then org-admin plane ----------------------
   (R "POST" "/api/orgs" 'orgs-create #:auth 'superadmin #:perm "instance:manage" #:doc "Create a company: org, first team, owner. An explicit slug is a natural key (409 on re-run).")
   (R "GET" "/api/orgs" 'orgs-list #:auth 'superadmin #:perm "instance:manage" #:doc "List every org on the instance.")
   (R "POST" "/api/orgs/:ref/suspend" 'org-suspend #:auth 'superadmin #:perm "instance:manage" #:doc "Suspend a company (id or slug); every team in it becomes read-only.")
   (R "POST" "/api/orgs/:ref/resume" 'org-resume #:auth 'superadmin #:perm "instance:manage" #:doc "Resume a suspended company.")
   (R "POST" "/api/orgs/:ref/quota" 'org-quota #:auth 'superadmin #:perm "instance:manage" #:doc "Set an org-level quota; teams nest beneath it.")
   (R "GET" "/api/orgs/:ref" 'org-get #:auth 'superadmin #:perm "instance:manage" #:doc "One company, its teams and quotas.")
   (R "PATCH" "/api/orgs/:ref" 'org-update #:auth 'superadmin #:perm "instance:manage" #:doc "Rename a company and/or change its plan (a plan change re-applies the plan's caps).")
   (R "POST" "/api/admin/seed-tenants" 'seed-tenants #:auth 'superadmin #:perm "instance:manage" #:doc "Seed Acme and Globex with known dev passwords — demo fixture only.")
   (R "GET" "/api/org" 'my-org #:auth 'org-admin #:perm "org:read" #:doc "The caller's own company.")
   (R "GET" "/api/org/teams" 'my-org-teams #:auth 'org-admin #:perm "org:read" #:doc "The teams in the caller's company.")
   (R "POST" "/api/org/teams" 'my-org-team-create #:auth 'org-admin #:perm "org:manage" #:doc "Create a team in the caller's company.")
   (R "POST" "/api/org/members" 'my-org-member-add #:auth 'org-admin #:perm "org:manage" #:doc "Add a person to a team in the caller's company.")
   (R "GET" "/api/org/audit" 'my-org-audit #:auth 'org-admin #:perm "org:read" #:doc "The company's audit trail.")

   ;; ---- notes and text documents ----------------------------------------------------
   (R "POST" "/api/notes" 'notes-create #:perm "notes:write" #:doc "Create a note with a visibility.")
   (R "GET" "/api/notes" 'notes-list #:perm "notes:read" #:doc "List the notes the caller can read.")
   (R "POST" "/api/documents" 'documents-create #:perm "files:write" #:doc "Create a text document (a repository object with content_type text/markdown).")
   (R "GET" "/api/documents" 'documents-list #:perm "files:read" #:doc "List text documents.")
   (R "GET" "/api/documents/:id" 'documents-get #:perm "files:read" #:doc "One text document with its body.")
   (R "PUT" "/api/documents/:id" 'documents-update #:perm "files:write" #:doc "Update a text document's title, body or visibility (a new version).")
   (R "DELETE" "/api/documents/:id" 'documents-delete #:perm "files:delete" #:doc "Delete a text document.")
   (R "POST" "/api/notes/:id/share" 'notes-share #:perm "notes:manage" #:doc "Share a note with a user (owner, or notes:manage). The permission granted must be a notes:* one.")
   (R "GET" "/api/notes/:id" 'notes-get #:perm "notes:read" #:doc "One note.")
   (R "PUT" "/api/notes/:id" 'notes-update #:perm "notes:write" #:doc "Update a note.")
   (R "DELETE" "/api/notes/:id" 'notes-delete #:perm "notes:delete" #:doc "Delete a note.")

   ;; ---- AI: chat, agent, translation ---------------------------------------------------
   (R "POST" "/api/ai/echo" 'ai-echo #:perm "chat:use" #:doc "A metered no-model echo, for exercising quotas.")
   (R "POST" "/api/ai/chat" 'ai-chat #:perm "chat:use" #:feature "chat" #:doc "One model turn. Quota-admitted (ai.requests, ai.tokens.total), governed by the team's ai.concurrency. Routing to a named executor needs instance:manage.")
   (R "POST" "/api/ai/chat/stream" 'ai-chat-stream #:perm "chat:use" #:feature "chat" #:doc "The same turn as server-sent events, metered at the end.")
   (R "POST" "/api/agent" 'agent #:perm "chat:use" #:feature "agent" #:doc "Run the tool-using agent loop over the team's enabled tools; every tool call is RBAC-checked and metered.")
   (R "POST" "/api/translate/catalog" 'translate-catalog #:perm "chat:use" #:feature "translate" #:doc "Translate a whole locale catalog, placeholders preserved.")
   (R "POST" "/api/translate" 'translate #:perm "chat:use" #:feature "translate" #:doc "Translate text into a target language, applying the team glossary.")
   (R "GET" "/api/translate" 'translate-list #:perm "chat:use" #:doc "The team's translation history.")
   (R "POST" "/api/glossary" 'glossary-add #:perm "settings:manage" #:doc "Add or update a glossary term for a target language.")
   (R "GET" "/api/glossary" 'glossary-list #:perm "chat:use" #:doc "The team glossary.")
   (R "GET" "/api/ai/model" 'ai-model #:doc "Which model is configured (or that the simulated fallback is in use).")
   (R "GET" "/api/executors" 'executors #:doc "The local executor and any federated ones.")

   ;; ---- quotas, tools, tokens, search, audit, jobs -------------------------------------
   (R "GET" "/api/usage" 'usage #:doc "The team's quota dimensions with used, limit and remaining.")
   (R "POST" "/api/quota" 'quota-set #:perm "instance:manage" #:doc "Set a quota limit for the caller's team (dimension, limit, window).")
   (R "GET" "/api/tools" 'tools-list #:doc "Every registered tool with its permission, source and per-team enabled state.")
   (R "POST" "/api/tokens" 'tokens-create #:perm "settings:manage" #:doc "Issue an API token, optionally scoped; the raw token is shown once.")
   (R "GET" "/api/tokens" 'tokens-list #:perm "settings:manage" #:doc "The team's API tokens.")
   (R "DELETE" "/api/tokens/:id" 'tokens-revoke #:perm "settings:manage" #:doc "Revoke an API token.")
   (R "GET" "/api/search" 'search #:feature "search" #:doc "Search notes, repository objects (key, filename, extracted text) and knowledge-graph entities; every row filtered by can?.")
   (R "GET" "/api/audit" 'audit #:perm "settings:manage" #:doc "The team's recent audit events.")
   (R "POST" "/api/jobs" 'jobs-create #:perm "chat:use" #:doc "Enqueue a scheduler job of a registered kind.")
   (R "GET" "/api/jobs" 'jobs-list #:doc "The team's jobs, newest first.")
   (R "POST" "/api/jobs/:id/cancel" 'job-cancel #:doc "Cancel a queued job (a running one finishes).")
   (R "GET" "/api/jobs/:id" 'job-get #:doc "One job with its result or error.")

   ;; ---- document repository -------------------------------------------------------------
   (R "GET" "/api/repo" 'repo-list #:perm "files:read" #:doc "List repository objects by ?prefix=, paged; ?shared=1 lists only what the caller holds a live grant on and does not own.")
   (R "POST" "/api/repo-obj/:id/share" 'repo-share #:perm "files:manage" #:doc "Share with a user or a team in the org: {principal_type, principal_id, capability: view|edit|manage, expires_at?}. {user_id} still means view.")
   (R "POST" "/api/repo-obj/:id/unshare" 'repo-unshare #:perm "files:manage" #:doc "Revoke every grant a principal holds on the object.")
   (R "GET" "/api/repo-obj/:id/grants" 'repo-grants #:perm "files:manage" #:doc "One entry per principal: capability, permissions, granted_by, expiry, expired.")
   (R "GET" "/api/repo-obj/:id/derivations" 'repo-derivations #:perm "files:read" #:doc "Provenance: what the document was derived from, by which run and step.")
   (R "GET" "/api/repo-obj/:id/processing" 'repo-processing #:perm "files:read" #:doc "\"Processed by\": derived documents, sources, and every run that touched the document.")
   (R "GET" "/api/share-targets" 'share-targets #:perm "files:read" #:doc "Who a document can be shared with: the team's people and the org's teams.")
   (R "POST" "/api/repo-obj/:id/visibility" 'repo-visibility #:perm "files:manage" #:doc "Set private, team or shared.")
   (R "GET" "/api/repo-obj/:id/content" 'repo-get #:perm "files:read" #:doc "Download the bytes (?version= for history). Attachment + nosniff unless the type is on the inline allowlist.")
   (R "POST" "/api/repo-obj/:id/presign" 'repo-presign #:perm "files:read" #:doc "A time-boxed presigned S3 URL, signed with the caller's own newest S3 key.")
   (R "GET" "/api/repo-obj/:id" 'repo-meta #:perm "files:read" #:doc "Object metadata with its versions.")
   (R "DELETE" "/api/repo-obj/:id" 'repo-delete #:perm "files:delete" #:doc "Delete an object (blobs are released when no other version references them).")
   (R "PUT" "/api/repo/*key" 'repo-put #:perm "files:write" #:doc "Upload a raw body to a key (?filename=, ?visibility=); writing an existing key adds a version. Triggers evaluate here.")
   (R "GET" "/api/s3/credentials" 's3-creds #:doc "The caller's S3 access keys (secrets never shown again) and the endpoint/bucket to use them with.")
   (R "POST" "/api/s3/credentials" 's3-cred-create #:doc "Issue an S3 access key, optionally scoped (add workflows:run for a prefix that should fire triggers).")
   (R "DELETE" "/api/s3/credentials/:id" 's3-cred-revoke #:doc "Revoke an S3 access key; presigned links signed with it die with it.")

   ;; ---- workflows, triggers, runs ------------------------------------------------------
   (R "POST" "/api/workflows" 'workflows-create #:perm "workflows:write" #:feature "workflows" #:doc "Publish a workflow spec (validated; unknown fields refused); re-publishing a slug bumps its version.")
   (R "GET" "/api/workflows" 'workflows-list #:perm "workflows:read" #:feature "workflows" #:doc "The team's workflow definitions, plugin-contributed ones materialized on first look.")
   (R "GET" "/api/workflows/schema" 'workflow-schema #:auth 'public #:doc "The workflow spec format: version, step kinds, binding references, predicates.")
   (R "POST" "/api/workflows/:slug/run" 'workflow-run #:perm "workflows:run" #:feature "workflows" #:doc "Start a run with {input}; declared inputs are required and typed. Returns 202 with the run.")
   (R "GET" "/api/doc-triggers" 'doc-triggers-list #:perm "workflows:read" #:feature "workflows" #:doc "The team's upload triggers, with the team's remaining AI budget.")
   (R "POST" "/api/doc-triggers" 'doc-triggers-create #:perm "workflows:write" #:feature "workflows" #:doc "Create a trigger: workflow_slug, match_prefix, match_types, input, fire_on_derived.")
   (R "GET" "/api/doc-triggers/:id" 'doc-trigger-get #:perm "workflows:read" #:doc "One trigger with its fire history (which version, which run, or why not).")
   (R "PATCH" "/api/doc-triggers/:id" 'doc-trigger-update #:perm "workflows:write" #:doc "Change a trigger's fields; absent fields are left alone.")
   (R "DELETE" "/api/doc-triggers/:id" 'doc-trigger-delete #:perm "workflows:write" #:doc "Delete a trigger and its history; the runs it started remain.")
   (R "GET" "/api/workflows/:slug" 'workflow-get #:perm "workflows:read" #:feature "workflows" #:doc "One workflow definition with its spec.")
   (R "GET" "/api/runs" 'runs-list #:perm "workflows:read" #:feature "workflows" #:doc "The team's runs, newest first.")
   (R "POST" "/api/runs/:id/cancel" 'run-cancel #:perm "workflows:run" #:feature "workflows" #:doc "Cancel a run; a step already executing finishes, the next never starts.")
   (R "GET" "/api/runs/:id" 'run-get #:perm "workflows:read" #:feature "workflows" #:doc "One run with its steps, inputs, outputs and errors.")

   ;; ---- knowledge graph ---------------------------------------------------------------
   (R "GET" "/api/kg/entities" 'kg-entities #:perm "files:read" #:doc "Find entities by ?q= and ?type=; only those with a mention the caller can read.")
   (R "GET" "/api/kg/entities/:id" 'kg-entity #:perm "files:read" #:doc "One entity with its relations and mentions, each mention filtered by the source document's visibility.")
   (R "POST" "/api/kg/extract" 'kg-extract #:perm "workflows:run" #:feature "workflows" #:doc "Queue the index-knowledge workflow over the team's unextracted documents.")

   ;; ---- administration ----------------------------------------------------------------
   (R "POST" "/api/admin/seed" 'admin-seed #:perm "settings:manage" #:doc "Seed sample notes and documents into the caller's team.")
   (R "GET" "/api/metrics" 'metrics #:perm "instance:manage" #:doc "Operational metrics.")
   (R "GET" "/api/features" 'features #:doc "The team's feature flags.")
   (R "POST" "/api/features/:name" 'feature-toggle #:perm "settings:manage" #:doc "Enable or disable a feature for the team.")
   (R "GET" "/api/plugins" 'plugins #:doc "The loaded plugins with their tools and workflows.")
   (R "GET" "/api/mcp" 'mcp #:doc "Connected MCP servers.")
   (R "GET" "/api/oop" 'oop #:doc "Connected sandboxed (out-of-process) plugins and the capabilities they may ask for.")
   (R "POST" "/api/tools/:name" 'tool-toggle #:perm "settings:manage" #:doc "Enable or disable a tool for the team.")))

;; ---- matching --------------------------------------------------------------------------
(define (pattern-segments path)
  (filter (lambda (s) (not (string=? s ""))) (string-split path "/" #:trim? #f)))

;; the names bound by a pattern, in order — the handler receives them positionally
(define (route-params r)
  (for/list ([seg (in-list (pattern-segments (rt-path r)))]
             #:when (or (string-prefix? seg ":") (string-prefix? seg "*")))
    (substring seg 1)))

;; -> (values entry param-values) or (values #f #f)
(define (match-route method segs)
  (define ss (filter (lambda (s) (not (string=? s ""))) segs))
  (let loop ([rs ROUTES])
    (cond
      [(null? rs) (values #f #f)]
      [(not (string=? (rt-method (car rs)) method)) (loop (cdr rs))]
      [else
       (define m (match-pattern (pattern-segments (rt-path (car rs))) ss))
       (if m (values (car rs) m) (loop (cdr rs)))])))

;; -> a list of bound values, or #f
(define (match-pattern pat segs)
  (let loop ([pat pat] [segs segs] [acc '()])
    (cond
      [(null? pat) (and (null? segs) (reverse acc))]
      [(string-prefix? (car pat) "*")
       ;; the rest of the path, at least one segment
       (and (pair? segs) (reverse (cons (string-join segs "/") acc)))]
      [(null? segs) #f]
      [(string-prefix? (car pat) ":") (loop (cdr pat) (cdr segs) (cons (car segs) acc))]
      [(string=? (car pat) (car segs)) (loop (cdr pat) (cdr segs) acc)]
      [else #f])))
