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
;; of the path (joined with "/", and "" when there is none). First match wins, in
;; list order — keep a
;; specific pattern (/api/workflows/schema) above the parameterized one it would
;; otherwise fall into (/api/workflows/:slug).
;;
;; `auth`: 'public (no credential), 'bearer (a session or API token — `with-auth`
;; or `current-principal`), 'provision (the hosted-mode provisioning token),
;; 'superadmin / 'org-admin (the two multi-tenancy planes, which the dispatcher
;; puts behind `with-mt` FIRST so the flag gate's 404 beats a 403), and 'handler
;; for the one route that accepts a bearer OR something else and must decide for
;; itself.
;;
;; SINCE #110 r2 THE DISPATCHER ENFORCES THIS FIELD, and `perm` too when the
;; permission is role-scoped — see `dispatch` in main.rkt for why a
;; resource-scoped permission is deliberately left to the handler. The permission is the
;; one the handler ENFORCES with require-perm on its main path; owner-ok and
;; resource grants may admit a caller the role would not (see the RBAC design).

(require racket/string racket/list)

(provide (struct-out rt) R ROUTES match-route match-routes route-params
         plugin-route-path)

;; Plugin-contributed routes (slice 63) live under ONE platform-fixed prefix that
;; carries the plugin id — /api/x/<plugin-id>/… — so a plugin cannot shadow a core
;; route or another plugin's, by construction rather than by a check.
(define PLUGIN-ROUTE-PREFIX "/api/x/")
(define (plugin-route-path plugin-id path)
  (string-append PLUGIN-ROUTE-PREFIX plugin-id "/" (regexp-replace #rx"^/+" path "")))

;; `scope` is #110 r2's: 'role means the dispatcher may check `perm` by ROLE
;; before the handler runs; 'resource means `can?` must weigh it against a
;; particular note, document or workflow definition, where owner-ok and a GRANT
;; also admit — so a role pre-check would be STRICTER than the handler's own and
;; would refuse exactly what sharing exists for (DSH-1).
;;
;; It is per ROUTE and not per permission, which is the correction this slice
;; cost: `files:read` on /api/repo-obj/:id/content has a resource to weigh, and
;; on /api/retention there is none — same permission, different answer. Deriving
;; it from the permission left /api/retention unprotected by the dispatcher while
;; looking covered, and the control that strips a handler's own check is what
;; showed it.
(struct rt (method path handler auth perm feature doc scope) #:transparent)

(define (R method path handler
           #:auth [auth 'bearer] #:perm [perm #f] #:feature [feature #f] #:doc doc
           ;; 'role by default: the common case is a permission the role decides,
           ;; and defaulting the OTHER way would silently stop the dispatcher
           ;; checking a route somebody forgot to annotate.
           #:scope [scope 'role])
  (rt method path handler auth perm feature doc scope))

(define ROUTES
  (list
   ;; ---- the console and static assets ------------------------------------------------
   (R "GET" "/"            'ui #:auth 'public #:doc "The console (or the beta funnel when TELEMACHUS_HOME=beta). The HTML title is rewritten from instance branding.")
   (R "GET" "/index.html"  'ui #:auth 'public #:doc "The console.")
   (R "GET" "/login"       'ui #:auth 'public #:doc "The console, sign-in first — a URL that never depends on the beta landing.")
   (R "GET" "/activate"    'ui #:auth 'public #:doc "The console, on the magic-link activation screen (hosted mode).")
   (R "GET" "/health"      'health #:auth 'public #:doc "Liveness: {ok, multitenant} and nothing else — version, KDF and TLS state are on GET /api/admin/status.")
   (R "GET" "/beta-sdk.js" 'beta-sdk #:auth 'public #:doc "The browser SDK a Tier-B onboarding bundle loads (window.Telemachus.beta).")
   (R "GET" "/console/*path" 'console-file #:auth 'public #:doc "One of the console's own script files (static/console/*.js), served same-origin so the console's `script-src 'self'` policy admits it with no inline block and no nonce.")
   (R "GET" "/beta/bundle/:plugin/*path" 'bundle-file #:auth 'public #:doc "A file from a Tier-B onboarding plugin's PUBLIC landing bundle (plugins/<id>/landing/) — the funnel a prospect sees before signing in.")
   ;; issue #20: the authenticated counterpart. `bundle/` is reserved by the
   ;; platform under every plugin's prefix, and core routes match before plugin
   ;; ones, so a plugin cannot serve its own screens from a public cached path.
   (R "POST" "/api/x/:plugin/bundle-ticket" 'plugin-bundle-ticket #:doc "Mint a short-lived ticket for this plugin's authenticated bundle, so its pages can be OPENED in a browser (issue #43); the first response sets it as a cookie scoped to that bundle path.")
   ;; #:auth 'handler — a BEARER or a bundle TICKET, and only the handler can tell
   ;; which (issue #43). The dispatcher must not pre-authenticate it: doing so
   ;; refuses the ticket navigation before the handler ever looks, which is what
   ;; #110 r2 did on its first run and `server-smoke.sh` caught in four
   ;; assertions. Named rather than left as 'bearer, so the exception is a
   ;; declaration instead of a surprise.
   (R "GET" "/api/x/:plugin/bundle/*path" 'plugin-bundle #:auth 'handler #:doc "A file from a loaded plugin's AUTHENTICATED bundle (plugins/<id>/bundle/): a bearer token is required — or a ticket from bundle-ticket, in ?ticket= or the cookie it sets — and the response is never cached by a shared cache.")
   (R "GET" "/beta/template" 'beta-template #:auth 'public #:doc "The Tier-C sandboxed HTML template, localized by the experience overlay.")

   ;; ---- instance: config, branding, localization ------------------------------------
   (R "GET" "/api/config"   'config #:auth 'public #:doc "Public instance configuration: home mode, multi-tenancy flag, the localization policy (default locale, available locales, whether switching is enabled). The sign-in screen reads it before anyone has a token.")
   (R "GET" "/api/branding" 'branding-get #:auth 'public #:doc "Title, tagline, logo and theme tokens. Public: the sign-in screen renders them. On a company's hostname, or for its signed-in user, the company's own (TEN-2d).")
   (R "PUT" "/api/branding" 'branding-put #:perm "instance:manage" #:doc "Set the instance title, tagline and theme. A theme token that is unknown, malformed, or below the WCAG contrast floor is a 400 naming it.")
   ;; Retention rules (#86 r3). Three scopes, because the layers tighten: the
   ;; instance sets a ceiling, an org shortens it for its own data, a team
   ;; shortens further for its own.
   (R "GET" "/api/retention" 'retention-get #:perm "files:read" #:doc "The caller's EFFECTIVE retention policy, with `sources` naming which layer set each value — instance, org or team. The layers TIGHTEN: a shorter horizon wins and `null` (keep for ever) loses to any number, so a team cannot keep data longer than its org allows. Nothing is deleted unless a rule is configured; an unconfigured instance has no rules and sweeps nothing.")
   (R "PUT" "/api/retention" 'retention-put #:perm "settings:manage" #:doc "Set the TEAM's retention rules: `max_age_days`, `delete_derived_after_days`, `purge_job_payloads_after_days`. Each is a whole number of days or null. **0 is refused** — it would delete a document on arrival — and a field nobody defined is refused rather than dropped, because a rule that does nothing while you believe data is being deleted is the worst way to be wrong. A team may only SHORTEN what its org and the instance allow.")
   (R "GET" "/api/retention/plan" 'retention-plan-get #:perm "files:read" #:doc "What the policy WOULD delete right now, and nothing else: the object trees, the derived objects, the job payloads, and how many objects a legal hold is protecting. A retention rule runs unattended, which makes it the one most in need of a dry run. An object under legal hold is absent from the plan rather than filtered later, so the plan never promises something a rule cannot touch.")
   (R "POST" "/api/repo-obj/:id/legal-hold" 'legal-hold-put #:perm "files:manage" #:scope 'resource #:doc "Place or release a legal hold on an object: `{\"hold\": true|false}`. While held, deletion BY RULE is refused — a retention sweep skips it and says how many it skipped. This is the flag r4 will build a prefix-level surface on; it ships with the rules because a schedule that deletes is a one-way door and a hold is the only thing that can stop one.")
   (R "GET" "/api/session-policy" 'session-policy-get #:perm "instance:manage" #:doc "The instance session timeouts (issue #38): idle_seconds, absolute_seconds, warn_seconds, with the shipped defaults and the accepted bounds.")
   (R "PUT" "/api/session-policy" 'session-policy-put #:perm "instance:manage" #:doc "Set the instance session timeouts. null on a field means no limit on that axis; an org may tighten these and may never loosen them.")
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
   (R "POST" "/api/login" 'login #:auth 'public #:doc "Sign in with username and password (and a TOTP code when 2FA is enabled). Returns a bearer token. Attempts are throttled per address and per account with a growing delay (429 and `Retry-After`), every attempt is audited as `user.login`, and an account may be locked outright when the operator sets TELEMACHUS_LOGIN_LOCK_FAILURES (423, cleared by an operator password reset).")
   ;; issue #118: a person's OWN sessions. No permission — these are the caller's
   ;; own rows, scoped by user_id and kind in the statement itself. Deliberately
   ;; not GET /api/tokens, which is the TEAM's API tokens behind settings:manage
   ;; and would have handed a member the team's machine credentials to read.
   (R "GET" "/api/sessions" 'sessions-list #:doc "The caller's own browser sessions — prefix, when each was created and last used, when it expires, and which one this request is holding. Never a token.")
   (R "POST" "/api/logout" 'logout #:doc "End the session this request is holding. The console's sign-out called nothing before this, so the bearer stayed valid until it expired.")
   (R "DELETE" "/api/sessions" 'sessions-revoke-others #:doc "End every OTHER session of the caller — \"sign out everywhere else\". Not everywhere: a password change already ends them all, this one keeps the session you are using.")
   (R "DELETE" "/api/sessions/:id" 'session-revoke #:doc "End one of the caller's own sessions. A session that is not theirs and one that does not exist are the same 404.")
   (R "POST" "/api/2fa/enable" '2fa-enable #:doc "Enable TOTP two-factor authentication for the caller; returns the secret and a set of single-use recovery codes, once.")
   (R "POST" "/api/2fa/recovery-codes" '2fa-codes-new #:doc "Issue a fresh set of single-use recovery codes, invalidating any outstanding ones; returned once (issue #26).")
   (R "GET" "/api/2fa/recovery-codes" '2fa-codes-get #:doc "How many of the caller's recovery codes are still unspent. Never the codes themselves.")
   (R "DELETE" "/api/2fa" '2fa-reset #:doc "Turn the caller's own TOTP off, so the old seed and its recovery codes stop working and they must enrol again.")
   (R "DELETE" "/api/admin/users/:id/2fa" 'admin-2fa-reset #:perm "instance:manage" #:doc "Revoke a user's TOTP seed (issue #19): a seed that may sit in a database dump cannot be rotated by using it, so an operator can force a re-enrolment.")
   (R "POST" "/api/password" 'password #:doc "Change the caller's password. Every session the old password could have minted is revoked, including this one, so the caller signs in again; machine tokens (api, worker) are left alone.")
   (R "GET" "/api/whoami" 'whoami #:doc "The caller: user, team, operator flag, org, org role, locale, permissions.")
   (R "POST" "/api/profile" 'profile #:doc "Update the caller's profile (display name, locale).")
   (R "POST" "/api/members" 'add-member #:perm "members:manage" #:doc "Add a member to the caller's team with a role; returns the new member's first token.")
   (R "GET" "/api/members" 'members-list #:doc "The team's members and roles.")
   (R "PATCH" "/api/members/:id" 'member-role #:perm "members:manage" #:doc "Change a member's team role: {role}. The last owner cannot be demoted — a team with no owner cannot grant anyone the permission to fix it.")
   (R "DELETE" "/api/members/:id" 'member-remove #:perm "members:manage" #:doc "Remove a member from the team: the membership is deactivated and every token they hold FOR THIS TEAM is revoked. The last owner cannot be removed.")
   (R "GET" "/api/admin/status" 'admin-status #:perm "instance:read" #:doc "Instance status: version, KDF, TLS, multi-tenancy and secrets-at-rest state, and counts of users, teams, orgs, notes, tokens, audit events, tenants.")

   ;; ---- multi-tenancy: superadmin plane, then org-admin plane ----------------------
   (R "POST" "/api/orgs" 'orgs-create #:auth 'superadmin #:perm "instance:manage" #:doc "Create a company: org, first team, owner. An explicit slug is a natural key (409 on re-run).")
   (R "GET" "/api/orgs" 'orgs-list #:auth 'superadmin #:perm "instance:manage" #:doc "List every org on the instance.")
   (R "POST" "/api/orgs/:ref/suspend" 'org-suspend #:auth 'superadmin #:perm "instance:manage" #:doc "Suspend a company (id or slug); every team in it becomes read-only.")
   (R "POST" "/api/orgs/:ref/resume" 'org-resume #:auth 'superadmin #:perm "instance:manage" #:doc "Resume a suspended company.")
   (R "POST" "/api/orgs/:ref/quota" 'org-quota #:auth 'superadmin #:perm "instance:manage" #:doc "Set an org-level quota; teams nest beneath it.")
   (R "GET" "/api/orgs/:ref" 'org-get #:auth 'superadmin #:perm "instance:manage" #:doc "One company, its teams and quotas.")
   (R "PATCH" "/api/orgs/:ref" 'org-update #:auth 'superadmin #:perm "instance:manage" #:doc "Rename a company, change its plan (re-applies the plan's caps), and/or set its hostname ({domain}, null to clear): the console on that host wears the company's branding before sign-in (TEN-2d).")
   (R "POST" "/api/admin/users/:id/password" 'admin-password-reset #:perm "instance:manage" #:doc "Set a user's password when they are locked out: {new_password}. Their sessions are revoked. The only way back in for someone who cannot sign in — there is no mail transport to send a reset link.")
   (R "POST" "/api/admin/seed-tenants" 'seed-tenants #:auth 'superadmin #:perm "instance:manage" #:doc "Seed Acme and Globex with known dev passwords — demo fixture only.")
   (R "GET" "/api/org" 'my-org #:auth 'org-admin #:perm "org:read" #:doc "The caller's own company.")
   (R "GET" "/api/org/teams" 'my-org-teams #:auth 'org-admin #:perm "org:read" #:doc "The teams in the caller's company.")
   (R "POST" "/api/org/teams" 'my-org-team-create #:auth 'org-admin #:perm "org:manage" #:doc "Create a team in the caller's company.")
   (R "POST" "/api/org/teams/:ref/quota" 'my-org-team-quota #:auth 'org-admin #:perm "org:manage" #:doc "Set ONE team's quota limit from the company plane (issue #113): {dimension, limit, window?} for a team of the caller's own company, named by id or slug. The team-tier POST /api/quota only ever sets the caller's OWN team, so without this an org admin administering several teams had to hold a token in each. A team outside the company answers 404 — it does not exist for this caller.")
   (R "POST" "/api/org/members" 'my-org-member-add #:auth 'org-admin #:perm "org:manage" #:doc "Add a person to a team in the caller's company, optionally with an org role (org_admin, org_owner, org_reader).")
   (R "PATCH" "/api/org/members/:id" 'my-org-member-role #:auth 'org-admin #:perm "org:manage" #:doc "Set or clear a person's org role — the way an existing user becomes an org_reader (TEN-2h). Never your own.")
   (R "GET" "/api/org/audit" 'my-org-audit #:auth 'org-admin #:perm "org:read" #:doc "The company's audit trail.")
   (R "GET" "/api/org/retention" 'my-org-retention-get #:auth 'org-admin #:perm "org:read" #:doc "The company's own retention rules (#86 r3). An org may SHORTEN what the instance allows for its own data and may never extend it.")
   (R "PUT" "/api/org/retention" 'my-org-retention-put #:auth 'org-admin #:perm "org:manage" #:doc "Set the company's retention rules. Same vocabulary and same refusals as the team route; the effective value for a team is the shortest of instance, org and team.")
   (R "GET" "/api/org/session-policy" 'my-org-session-policy-get #:auth 'org-admin #:perm "org:read" #:doc "The company's own session timeouts, the instance's, and the effective policy after the instance floor is applied.")
   (R "PUT" "/api/org/session-policy" 'my-org-session-policy-put #:auth 'org-admin #:perm "org:manage" #:doc "Set the company's session timeouts. Only tightening takes effect: a value looser than the instance's is answered with the instance's.")
   (R "DELETE" "/api/org/session-policy" 'my-org-session-policy-clear #:auth 'org-admin #:perm "org:manage" #:doc "Drop the company's session timeouts; its users fall back to the instance policy.")
   (R "GET" "/api/org/branding" 'my-org-branding-get #:auth 'org-admin #:perm "org:read" #:doc "The company's own branding (TEN-2d) — or the instance's, with own:false, when it has set none.")
   (R "PUT" "/api/org/branding" 'my-org-branding-put #:auth 'org-admin #:perm "org:manage" #:doc "Set the company's title, tagline, logo and theme: what the console wears on the company's hostname and for its signed-in users. Theme tokens are validated and contrast-gated exactly as the instance's are.")
   (R "DELETE" "/api/org/branding" 'my-org-branding-clear #:auth 'org-admin #:perm "org:manage" #:doc "Drop the company's branding; its users see the instance's again.")
   (R "POST" "/api/org/branding/logo" 'my-org-branding-logo #:auth 'org-admin #:perm "org:manage" #:doc "Upload the company's logo (base64) and make it the company's mark.")

   ;; ---- notes and text documents ----------------------------------------------------
   (R "POST" "/api/notes" 'notes-create #:perm "notes:write" #:doc "Create a note with a visibility.")
   (R "GET" "/api/notes" 'notes-list #:perm "notes:read" #:doc "List the notes the caller can read; ?scope=org spans every team in the company (an org_reader sees team-visible notes, never private ones).")
   (R "POST" "/api/documents" 'documents-create #:perm "files:write" #:doc "Create a text document (a repository object with content_type text/markdown).")
   (R "GET" "/api/documents" 'documents-list #:perm "files:read" #:doc "List text documents.")
   (R "GET" "/api/documents/:id" 'documents-get #:perm "files:read" #:scope 'resource #:doc "One text document with its body.")
   (R "PUT" "/api/documents/:id" 'documents-update #:perm "files:write" #:scope 'resource #:doc "Update a text document's title, body or visibility (a new version).")
   (R "DELETE" "/api/documents/:id" 'documents-delete #:perm "files:delete" #:scope 'resource #:doc "Delete a text document.")
   (R "POST" "/api/notes/:id/share" 'notes-share #:perm "notes:manage" #:scope 'resource #:doc "Share a note with a user (owner, or notes:manage). The permission granted must be a notes:* one.")
   (R "GET" "/api/notes/:id" 'notes-get #:perm "notes:read" #:scope 'resource #:doc "One note.")
   (R "PUT" "/api/notes/:id" 'notes-update #:perm "notes:write" #:scope 'resource #:doc "Update a note.")
   (R "DELETE" "/api/notes/:id" 'notes-delete #:perm "notes:delete" #:scope 'resource #:doc "Delete a note.")

   ;; ---- AI: chat, agent, translation ---------------------------------------------------
   (R "POST" "/api/ai/echo" 'ai-echo #:perm "chat:use" #:doc "A metered no-model echo, for exercising quotas.")
   (R "POST" "/api/ai/chat" 'ai-chat #:perm "chat:use" #:feature "chat" #:doc "One model turn. `prompt` is a string or a list of content parts; `response_format` ({type: text|json_object|json_schema}) rides to the model and the reply is refused if it does not honour it. Quota-admitted (ai.requests, ai.tokens.total), governed by the team's ai.concurrency. Routing to a named executor needs instance:manage. `simulated: true` on the response means NO model answered: TELEMACHUS_MODEL_URL is unset and the reply is a deterministic echo of the prompt. The key is absent on a real call.")
   (R "POST" "/api/ai/chat/stream" 'ai-chat-stream #:perm "chat:use" #:feature "chat" #:doc "The same turn as server-sent events, metered at the end. A response_format is judged after the stream ends: the final event carries `parsed`, or `schema_error` when the model did not honour it, and `simulated: true` when no model answered at all.")
   (R "POST" "/api/agent" 'agent #:perm "chat:use" #:feature "agent" #:doc "Run the tool-using agent loop over the team's enabled tools; every tool call is RBAC-checked and metered.")
   (R "POST" "/api/translate/catalog" 'translate-catalog #:perm "chat:use" #:feature "translate" #:doc "Translate a whole locale catalog, placeholders preserved.")
   (R "POST" "/api/translate" 'translate #:perm "chat:use" #:feature "translate" #:doc "Translate text into a target language, applying the team glossary.")
   (R "GET" "/api/translate" 'translate-list #:perm "chat:use" #:doc "The team's translation history.")
   (R "POST" "/api/glossary" 'glossary-add #:perm "settings:manage" #:doc "Add or update a glossary term for a target language.")
   (R "GET" "/api/glossary" 'glossary-list #:perm "chat:use" #:doc "The team glossary.")
   (R "GET" "/api/ai/model" 'ai-model #:doc "Which model is configured (or that the simulated fallback is in use).")
   (R "GET" "/api/model-roles" 'model-roles-get #:doc "Which executor the team's bulk work goes to, per role (utility: knowledge-graph and field extraction, translation drafts), and the instance default.")
   (R "PUT" "/api/model-roles" 'model-roles-put #:perm "settings:manage" #:doc "Set a team's model roles: {roles: {utility: <executor name> | null}}. The executor must exist; null returns to the instance default, then the local model.")
   (R "GET" "/api/executors" 'executors #:doc "The local executor, the env-configured push ones, and the API-created ones (push, or pull with a worker) with health.")
   (R "POST" "/api/executors" 'executor-create #:perm "instance:manage" #:doc "Create an executor: {name, mode: pull|push, model?, url?, key?, capabilities?, org_id?}. A pull executor's worker token is in this response and never again.")
   (R "DELETE" "/api/executors/:id" 'executor-retire #:perm "instance:manage" #:doc "Retire an executor: its worker token is revoked and any job it holds returns to the queue.")
   (R "GET" "/api/admin/workers" 'admin-workers #:perm "instance:read" #:doc "The worker fleet (FLEET-2): every executor with its health, what the worker reports, the job it holds, its outcomes and lease expiries over a window (?hours=, default 24), its recent failures — plus the queue: depth by kind, the oldest queued job's age, and how many queued remote jobs NO live executor can run. That last figure is the one a deep queue cannot otherwise explain: a stalled fleet and a busy one look the same from a count. Every number is derived, and a job held by a quota is NOT counted unclaimable — GET /api/jobs already says `waiting` for that.")
   (R "GET" "/api/admin/queue" 'admin-queue #:perm "instance:read" #:doc "The queue, job by job, across every team (FLEET-4): each row's age, attempt, holder, lease countdown, and — for a queued one — why the platform is holding it (`waiting`, the same reason GET /api/jobs gives) and whether any live worker can run it at all (`runnable`). Filters `kind`, `status`, `executor`, `team`; pages with `limit` (max 200) and `offset`; `total` is the count for the filter. Asked for `status=queued` the list is the claim's own order, so position 1 really is next — `order` says which ordering you got. It carries no payload and no result: a queue is managed by kind, age, team and holder, and this read crosses every team on the instance.")
   (R "POST" "/api/executors/:id/drain" 'executor-drain #:perm "instance:manage" #:doc "Take a pull executor out of rotation (FLEET-3): it is offered no new work and keeps its token, so it goes on polling and heartbeating and stays visibly alive. Reversible, unlike a retire, which revokes the token. A job it already holds is left running — stopping work in flight is what cancel is for.")
   (R "POST" "/api/executors/:id/resume" 'executor-resume #:perm "instance:manage" #:doc "Put a drained executor back in rotation (FLEET-3). It takes work again on its next claim.")
   (R "POST" "/api/org/executors" 'org-executor-create #:auth 'org-admin #:perm "org:manage" #:doc "Create an executor bound to the caller's company (TEN-2e): offered only to its teams.")
   (R "POST" "/api/workers/claim" 'worker-claim #:perm "jobs:execute" #:doc "A pull worker claims the next remote job it can run: {kinds, models, max_wait}; 204 when nothing. The job carries a lease and a claim_token, which every later write about it must carry back.")
   (R "POST" "/api/workers/state" 'worker-state #:perm "jobs:execute" #:doc "A pull worker reports what it is doing: {state} — ready, busy or paused. The one channel a worker with no job can use: a drained host has stopped claiming and holds nothing to heartbeat, so without this its silence is indistinguishable from a fault. `state` is also accepted on claim and heartbeat, so the normal loop needs no extra request; a call that names none leaves the stored state alone.")
   (R "POST" "/api/workers/jobs/:id/heartbeat" 'worker-heartbeat #:perm "jobs:execute" #:doc "Extend the lease on a job this worker holds: {claim_token}, the token the claim returned. A missing or stale token is a 409.")
   (R "POST" "/api/workers/jobs/:id/complete" 'worker-complete #:perm "jobs:execute" #:doc "Post a result: {result, claim_token}. Accepted only from the current lease holder AND the attempt the token names (a lapsed attempt cannot land on the one that replaced it); validated by the kind.")
   (R "POST" "/api/workers/jobs/:id/fail" 'worker-fail #:perm "jobs:execute" #:doc "Report a failure: {error, claim_token}. Accepted only from the current lease holder and that attempt.")
   (R "POST" "/api/workers/jobs/:id/release" 'worker-release #:perm "jobs:execute" #:doc "Hand a job back WITHOUT spending an attempt (issue #61): {claim_token, reason?} — busy, unsupported or shutdown; anything else is recorded as `other` rather than refused, since the worker has already said it cannot run the job. It goes straight back to the queue and any other worker may take it at once, while the releasing executor is not offered it again for 30 seconds — the bound on a release loop, which the untouched attempt counter cannot provide. Past 10 releases the job fails instead, naming the hosts that let it go: work no worker will run needs a person.")
   (R "POST" "/api/workers/jobs/:id/document" 'worker-document #:perm "jobs:execute" #:doc "Read a document THIS job names: {object, claim_token, version?, as?}. Three conditions, no new authorization code — the caller holds this attempt, the object id appears in the job's own payload, and the read happens as the job's user so visibility, grants and the org gate all apply. `as: \"bytes\"` (base64, capped at TELEMACHUS_MAX_UPLOAD) or `as: \"text\"`, where a scan answers {text: null, reason: \"needs-ocr\"}.")
   (R "POST" "/api/workers/jobs/:id/derive" 'worker-derive #:perm "jobs:execute" #:doc "Write a document DERIVED from one THIS job names (issue #62): {source, key, bytes_b64, claim_token, content_type?, filename?}. The write counterpart of the read above, under the same three conditions — the caller holds this attempt, `source` appears in the job's own payload, and the write happens as the job's user, so files:write, the storage quotas and the org gate all apply. The output takes the source's visibility and then its grants, is marked derived so an opted-in trigger cannot fire on a worker's own output, and is capped at TELEMACHUS_MAX_UPLOAD: a worker is not a way past the front door's ceiling. There is deliberately no standalone put — an output anchored to nothing would make the worker token a key to the team's repository.")

   ;; ---- quotas, tools, tokens, search, audit, jobs -------------------------------------
   (R "GET" "/api/usage" 'usage #:doc "The team's quota dimensions with used, limit, remaining and the window's reset time, plus `held` naming the limit that is currently holding the team's queued jobs (null when none is).")
   (R "POST" "/api/quota" 'quota-set #:perm "quota:manage" #:doc "Set a quota limit for the caller's team (dimension, limit, window). `quota:manage` and NOT `instance:manage` (issue #113): a team owner sets their own team's limit, and an org admin may too, because the company's own limit still caps whatever a team asks for (admission takes the org decision first). A team ADMIN deliberately does not hold it — spending is the steward's call.")
   (R "GET" "/api/tools" 'tools-list #:doc "Every registered tool with its permission, source and per-team enabled state.")
   (R "POST" "/api/tokens" 'tokens-create #:perm "settings:manage" #:doc "Issue an API token, optionally scoped, with a ttl in seconds (default 90 days; \"never\" for a long-lived machine token); the raw token is shown once.")
   (R "GET" "/api/tokens" 'tokens-list #:perm "settings:manage" #:doc "The team's API tokens.")
   (R "DELETE" "/api/tokens/:id" 'tokens-revoke #:perm "settings:manage" #:doc "Revoke an API token.")
   (R "GET" "/api/search" 'search #:feature "search" #:doc "Search notes, repository objects (key, filename, extracted text) and knowledge-graph entities; every row filtered by can?; ?scope=org spans the company's teams for an org_reader.")
   (R "GET" "/api/audit" 'audit #:perm "settings:manage" #:doc "The team's recent audit events.")
   (R "POST" "/api/jobs" 'jobs-create #:perm "chat:use" #:doc "Enqueue a scheduler job of a registered kind.")
   (R "GET" "/api/jobs" 'jobs-list #:doc "The team's jobs, newest first. A queued job the platform is holding carries `waiting` — {reason: \"quota\"|\"concurrency\", …}; the key is absent when nothing holds it and it is waiting only for a free worker.")
   (R "POST" "/api/jobs/:id/cancel" 'job-cancel #:doc "Cancel a job. Your own, queued or running; somebody else's needs jobs:cancel. A queued job is canceled outright; a running one goes to `canceling` — its result is discarded at once, and it stops holding its team's concurrency slot when the handler actually stops.")
   ;; Above /api/jobs/:id — first match wins in list order, and the bare pattern
   ;; would otherwise swallow this one.
   (R "DELETE" "/api/jobs/:id/content" 'job-purge #:doc "Purge a settled job's payload and result, keeping the row. Your own; somebody else's needs jobs:purge. For `infer.chat` and the document pipeline the payload IS the document's text and the result is the model's reply, so this is the lever a caller honouring a deletion request needs. Refused on a queued, running or canceling job — cancel it first, because its payload is the input a handler is about to read. Status, timings, attempt counts and the audit trail all survive; `purged_at` is reported on the job so an empty payload and a purged one can be told apart.")
   (R "GET" "/api/jobs/:id" 'job-get #:doc "One job with its result or error, and `waiting` if the platform is holding it (see GET /api/jobs).")

   ;; ---- document repository -------------------------------------------------------------
   ;; DELETE before GET on the same path is irrelevant (the method is matched too),
   ;; but it sits here so the two /api/repo entries read together.
   (R "DELETE" "/api/repo" 'repo-delete-prefix #:perm "files:delete" #:scope 'resource #:doc "Delete every object under `?prefix=`, cascading to what each one derived (#86). DRY RUN BY DEFAULT: without `confirm=1` nothing is removed and the reply is the count, the bytes and the ids that WOULD go. An empty or missing prefix is refused rather than read as \"every object in the team\". `?cascade=0` deletes only the listed objects and leaves their derivatives. The objects are found through the caller's own listing, so visibility, grants and the org gate apply exactly as on `GET /api/repo?prefix=`, and each deletion re-runs the per-object permission check.")
   (R "GET" "/api/repo" 'repo-list #:perm "files:read" #:doc "List repository objects by ?prefix=, paged; ?shared=1 lists only what the caller holds a live grant on and does not own; ?scope=org spans every team in the company (TEN-2h); ?attr=key:value narrows to objects whose team-defined metadata matches, repeatable (LAY-4).")
   (R "POST" "/api/repo-obj/:id/share" 'repo-share #:perm "files:manage" #:scope 'resource #:doc "Share with a user or a team in the org: {principal_type, principal_id, capability: view|edit|manage, expires_at?}. {user_id} still means view.")
   (R "POST" "/api/repo-obj/:id/unshare" 'repo-unshare #:perm "files:manage" #:scope 'resource #:doc "Revoke every grant a principal holds on the object.")
   (R "GET" "/api/repo-obj/:id/grants" 'repo-grants #:perm "files:manage" #:scope 'resource #:doc "One entry per principal: capability, permissions, granted_by, expiry, expired.")
   (R "GET" "/api/repo-obj/:id/derivations" 'repo-derivations #:perm "files:read" #:scope 'resource #:doc "Provenance: what the document was derived from, by which run and step.")
   (R "GET" "/api/repo-fields" 'repo-fields-get #:perm "files:read" #:doc "The team's object metadata fields: what a document may be tagged with (project, location, period, status…). Validation is required/digits/minlength/maxlength, never a regex.")
   (R "PUT" "/api/repo-fields" 'repo-fields-put #:perm "settings:manage" #:doc "Define the team's object metadata fields: {fields: [{key, label, required?, digits?, minlength?, maxlength?, help?}]}. Adding one needs no migration.")
   (R "PATCH" "/api/repo-obj/:id/attributes" 'repo-attributes #:perm "files:read" #:scope 'resource #:doc "Set a document's team-defined metadata: {attributes: {key: value}}. Needs files:write ON THE DOCUMENT. A key the team has not defined is refused, not stored; an empty value clears it.")
   (R "GET" "/api/repo-obj/:id/spans" 'repo-spans #:perm "files:read" #:scope 'resource #:doc "Where the extracted text came from: page and region per run (LAY-5). ?at=<character offset> returns only the spans covering that offset, which is how a reviewer jumps from an extracted value to the place it was read.")
   (R "GET" "/api/repo-obj/:id/processing" 'repo-processing #:perm "files:read" #:scope 'resource #:doc "\"Processed by\": derived documents, sources, and every run that touched the document.")
   ;; the chain's own two routes sit above nothing that could swallow them, but
   ;; they are kept together so a reader finds the pair
   (R "GET" "/api/admin/audit/verify" 'audit-verify #:perm "instance:read" #:doc "Verify the audit log's hash chain for one org, naming the first broken entry.")
   (R "GET" "/api/admin/audit/export" 'audit-export #:perm "instance:manage" #:doc "Export one org's audit log as JSONL over a date range, chain fields included.")
   (R "GET" "/api/repo-obj/:id/reads" 'repo-reads #:perm "files:read" #:scope 'resource #:doc "Who read this document, when and from where: reads, presign issuance and redemption, including refused attempts.")
   (R "GET" "/api/share-targets" 'share-targets #:perm "files:read" #:doc "Who a document can be shared with: the team's people and the org's teams.")
   (R "POST" "/api/repo-obj/:id/visibility" 'repo-visibility #:perm "files:manage" #:scope 'resource #:doc "Set private, team or shared.")
   (R "GET" "/api/repo-obj/:id/content" 'repo-get #:perm "files:read" #:scope 'resource #:doc "Download the bytes (?version= for history). Attachment + nosniff unless the type is on the inline allowlist.")
   (R "POST" "/api/repo-obj/:id/presign" 'repo-presign #:perm "files:read" #:scope 'resource #:doc "A time-boxed presigned S3 URL, signed with the caller's own newest S3 key.")
   ;; Above the bare /api/repo-obj/:id — first match wins in list order.
   (R "GET" "/api/repo-obj/:id/traces" 'repo-traces #:perm "files:read" #:scope 'resource #:doc "What is LEFT of an object: versions, extracted text, derived documents, derivation rows, grants, blobs still present, and jobs whose payload or result still quotes its id. The verification read for a deletion request (#86) — \"I called DELETE and got a 200\" is not evidence, and this is. `audit` is reported and is NOT a trace to drive to zero: the audit log is deliberately what survives an erasure.")
   (R "GET" "/api/repo-obj/:id" 'repo-meta #:perm "files:read" #:scope 'resource #:doc "Object metadata with its versions.")
   (R "DELETE" "/api/repo-obj/:id" 'repo-delete #:perm "files:delete" #:scope 'resource #:doc "Delete an object. Bytes are released when nothing in the ORG still references them — another version, another object, or an IN-FLIGHT upload's staged part. `?cascade=1` also deletes everything derived from it, transitively (the extracted JSON, the filled form, each translation), as ONE audited act; `?detach=1` with it keeps those objects and removes the derivation rows instead, so nothing claims to come from something that is gone. `?dry_run=1` reports what would go and changes nothing. A cascade is ALL-OR-NOTHING on permission: an object in the tree you may not delete refuses the whole operation by name, because a half-cascaded tree cannot be told apart from a finished one.")
   (R "PUT" "/api/repo/*key" 'repo-put #:perm "files:write" #:scope 'resource #:doc "Upload a raw body to a key (?filename=, ?visibility=); writing an existing key adds a version. Triggers evaluate here.")
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
   (R "GET" "/api/doc-triggers/:id" 'doc-trigger-get #:perm "workflows:read" #:scope 'resource #:doc "One trigger with its fire history (which version, which run, or why not).")
   (R "PATCH" "/api/doc-triggers/:id" 'doc-trigger-update #:perm "workflows:write" #:scope 'resource #:doc "Change a trigger's fields; absent fields are left alone.")
   (R "DELETE" "/api/doc-triggers/:id" 'doc-trigger-delete #:perm "workflows:write" #:scope 'resource #:doc "Delete a trigger and its history; the runs it started remain.")
   (R "GET" "/api/workflows/:slug" 'workflow-get #:perm "workflows:read" #:scope 'resource #:feature "workflows" #:doc "One workflow definition with its spec.")
   (R "GET" "/api/runs" 'runs-list #:perm "workflows:read" #:feature "workflows" #:doc "The team's runs, newest first.")
   (R "POST" "/api/runs/:id/cancel" 'run-cancel #:perm "workflows:run" #:feature "workflows" #:doc "Cancel a run; a step already executing finishes, the next never starts.")
   (R "GET" "/api/runs/:id" 'run-get #:perm "workflows:read" #:scope 'resource #:feature "workflows" #:doc "One run with its steps, inputs, outputs and errors.")
   (R "GET" "/api/reviews" 'reviews-list #:perm "reviews:read" #:doc "The team's review queue, newest first. ?status=pending (the default), decided, canceled or all.")
   ;; literal paths BEFORE the :id pattern — first match wins in list order, and
   ;; /api/reviews/:id would otherwise swallow both of these
   (R "GET" "/api/reviews/stats" 'review-stats #:perm "reviews:read" #:doc "How often the team let the AI's output stand: approve / revise / reject per workflow and step, with the mean time to a decision. A query over decisions already made, not a separate evaluation system. ?since=<epoch ms> narrows the window.")
   (R "GET" "/api/reviews/verify" 'review-verify #:perm "audit:read" #:doc "Walk the team's decision chain and recompute it, naming the first decision whose stored hash does not match its contents. Detects a record altered in place or removed; does NOT detect a rewrite by someone who can write the table, which would need an external anchor.")
   (R "GET" "/api/reviews/:id" 'review-get #:perm "reviews:read" #:doc "One review: what is under review, the checklist to answer, and the decision if it has been made.")
   (R "POST" "/api/reviews/:id/decide" 'review-decide #:perm "reviews:decide" #:doc "Decide a review: {verdict: approve|revise|reject, rationale, answers}. A rationale is required for revise and reject; a four-eyes review refuses the author. The run it parked resumes down the branch the verdict names.")

   ;; ---- knowledge graph ---------------------------------------------------------------
   (R "GET" "/api/kg/entities" 'kg-entities #:perm "files:read" #:doc "Find entities by ?q= and ?type=; only those with a mention the caller can read.")
   (R "GET" "/api/kg/entities/:id" 'kg-entity #:perm "files:read" #:scope 'resource #:doc "One entity with its relations and mentions, each mention filtered by the source document's visibility.")
   (R "POST" "/api/kg/extract" 'kg-extract #:perm "workflows:run" #:feature "workflows" #:doc "Queue the index-knowledge workflow over the team's unextracted documents.")

   ;; ---- administration ----------------------------------------------------------------
   (R "POST" "/api/admin/seed" 'admin-seed #:perm "settings:manage" #:doc "Seed sample notes and documents into the caller's team.")
   (R "GET" "/api/metrics" 'metrics #:perm "instance:read" #:doc "Operational metrics.")
   (R "GET" "/api/features" 'features #:doc "The team's feature flags.")
   (R "POST" "/api/features/:name" 'feature-toggle #:perm "settings:manage" #:doc "Enable or disable a feature for the team; a team may tighten what a layer above allows, never loosen it.")
   (R "GET" "/api/instance-features" 'instance-features #:perm "instance:manage" #:doc "Which features the instance allows at all; absence means allowed.")
   (R "PUT" "/api/instance-features" 'instance-features-put #:perm "instance:manage" #:doc "Turn a feature off for the whole instance; no org or team can turn it back on.")
   (R "GET" "/api/org/features" 'org-features #:perm "org:read" #:feature #f #:doc "Which features the caller's own company allows.")
   (R "PUT" "/api/org/features" 'org-features-put #:perm "org:manage" #:doc "Turn a feature off for the caller's own company; its teams cannot turn it back on.")
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
(define (match-route method segs) (match-routes ROUTES method segs))
(define (match-routes routes method segs)
  (define ss (filter (lambda (s) (not (string=? s ""))) segs))
  (let loop ([rs routes])
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
       ;; the rest of the path — possibly EMPTY: /beta/bundle/<plugin>/ (a trailing
       ;; slash, meaning the bundle's index.html) has no rest segment, and the beta
       ;; tour lands exactly there. Requiring one 404ed every Tier-B bundle root.
       (reverse (cons (string-join segs "/") acc))]
      [(null? segs) #f]
      [(string-prefix? (car pat) ":") (loop (cdr pat) (cdr segs) (cons (car segs) acc))]
      [(string=? (car pat) (car segs)) (loop (cdr pat) (cdr segs) acc)]
      [else #f])))
