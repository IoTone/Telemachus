# HTTP API

Every route the server dispatches, in matching order, from the declared route table (`server/routes.rkt`). `auth` is how a route authenticates: **public** needs no credential; **bearer** a session or API token; **provision** the hosted-mode provisioning token; **superadmin** and **org-admin** the two multi-tenancy planes. The permission is the one the handler enforces on its main path — owner-ok and resource grants may admit a caller the role would not. A feature flag, when named, must be on for the team.

Path segments written `:name` are parameters; `*name` takes the rest of the path.

| Method | Path | Auth | Permission | Feature | Description |
|---|---|---|---|---|---|
| GET | `/` | public | — | — | The console (or the beta funnel when TELEMACHUS_HOME=beta). The HTML title is rewritten from instance branding. |
| GET | `/index.html` | public | — | — | The console. |
| GET | `/login` | public | — | — | The console, sign-in first — a URL that never depends on the beta landing. |
| GET | `/activate` | public | — | — | The console, on the magic-link activation screen (hosted mode). |
| GET | `/health` | public | — | — | Liveness: {ok, service, version}. |
| GET | `/beta-sdk.js` | public | — | — | The browser SDK a Tier-B onboarding bundle loads (window.Telemachus.beta). |
| GET | `/beta/bundle/:plugin/*path` | public | — | — | A file from a Tier-B onboarding plugin's bundle directory. |
| GET | `/beta/template` | public | — | — | The Tier-C sandboxed HTML template, localized by the experience overlay. |
| GET | `/api/config` | public | — | — | Public instance configuration: home mode, multi-tenancy flag, the localization policy (default locale, available locales, whether switching is enabled). The sign-in screen reads it before anyone has a token. |
| GET | `/api/branding` | public | — | — | Instance title, tagline and logo. Public: the sign-in screen renders them. |
| PUT | `/api/branding` | bearer | `instance:manage` | — | Set the instance title and tagline. |
| POST | `/api/branding/logo` | bearer | `instance:manage` | — | Upload the instance logo (replaces the mark and the wordmark). |
| GET | `/api/i18n/catalog` | public | — | — | The console's strings for ?locale=, resolved through the fallback chain server-side. Public: the sign-in screen needs them. |
| PUT | `/api/i18n` | bearer | `instance:manage` | — | Set the instance default locale and whether users may switch. |
| GET | `/api/l10n/coverage` | bearer | `localization:read` | — | Per-locale coverage of the Localization Manager's catalog: total, approved, machine, missing, stale. |
| GET | `/api/l10n/messages` | bearer | `localization:read` | — | The messages of one locale, filterable by ?status=, ?ns=, ?q=, paged. |
| POST | `/api/l10n/import` | bearer | `localization:manage` | — | Pull the catalogs on disk into the Manager's tables. |
| POST | `/api/l10n/export` | bearer | `localization:manage` | — | Write a locale's APPROVED strings back to locales/<locale>.json. Refuses a locale with nothing approved. |
| POST | `/api/l10n/draft` | bearer | `localization:manage` | — | Queue AI drafts for a locale's missing strings, in batches of 20 scheduler jobs, quota-metered. |
| POST | `/api/l10n/discard` | bearer | `localization:manage` | — | Remove a locale's machine drafts (never a human's work). |
| PUT | `/api/l10n/messages/:id` | bearer | `localization:translate` | — | Submit a translation for one message. |
| POST | `/api/l10n/review/:id` | bearer | `localization:review` | — | Approve or send back a translation. A translator cannot approve their own. |
| GET | `/api/beta/config` | public | — | — | The published onboarding experience's public slice (fields, copy, theme) in one language. |
| OPTIONS | `/api/beta/signup` | public | — | — | CORS preflight for a sandboxed Tier-C template. |
| OPTIONS | `/api/beta/config` | public | — | — | CORS preflight for a sandboxed Tier-C template. |
| OPTIONS | `/api/beta/challenge` | public | — | — | CORS preflight for a sandboxed Tier-C template. |
| GET | `/api/beta/experience` | bearer | — | — | The team's draft onboarding experience, including the judge prompt. |
| PUT | `/api/beta/experience` | bearer | — | — | Save a draft of the onboarding experience. |
| POST | `/api/beta/experience/publish` | bearer | — | — | Publish the saved draft; it then wins over the ENV-seeded default. |
| POST | `/api/beta/assets` | bearer | — | — | Upload an onboarding asset (logo, hero image, font), base64 in JSON, capped at 2 MiB. |
| GET | `/api/beta/assets` | bearer | — | — | List the team's onboarding assets. |
| GET | `/api/beta/asset/:id` | public | — | — | Serve one onboarding asset. Public: the funnel and the branding logo load it without a token. |
| DELETE | `/api/beta/asset/:id` | bearer | — | — | Delete an onboarding asset. |
| GET | `/api/beta/challenge` | public | — | — | A proof-of-work challenge the funnel solves before signing up. |
| POST | `/api/beta/signup` | public | — | — | Submit the onboarding form: validated against the published experience, anti-abuse gated, judged by the model when configured. |
| GET | `/api/beta/prospects` | bearer | — | — | List the prospects the funnel captured, with signals and verdicts. |
| POST | `/api/beta/prospects/:id/decide` | bearer | — | — | Accept or decline a prospect. |
| POST | `/api/bootstrap` | public | — | — | First run only: create the operator, the first org and team. Returns the operator's token. Refuses once the instance has a user. |
| POST | `/api/provision` | provision | — | — | Hosted mode: provision this instance with exactly one owner and a magic activation link. |
| POST | `/api/activate` | public | — | — | Hosted mode: redeem an activation token and set the owner's password. |
| POST | `/api/instance/suspend` | provision | — | — | Hosted mode: suspend the tenant (writes are refused with 402). |
| POST | `/api/instance/resume` | provision | — | — | Hosted mode: resume a suspended tenant. |
| POST | `/api/instance/quota` | provision | — | — | Hosted mode: set a quota limit for the tenant's team. |
| POST | `/api/login` | public | — | — | Sign in with username and password (and a TOTP code when 2FA is enabled). Returns a bearer token. |
| POST | `/api/2fa/enable` | bearer | — | — | Enable TOTP two-factor authentication for the caller; returns the secret once. |
| POST | `/api/password` | bearer | — | — | Change the caller's password. |
| GET | `/api/whoami` | bearer | — | — | The caller: user, team, operator flag, org, org role, locale, permissions. |
| POST | `/api/profile` | bearer | — | — | Update the caller's profile (display name, locale). |
| POST | `/api/members` | bearer | `members:manage` | — | Add a member to the caller's team with a role; returns the new member's first token. |
| GET | `/api/members` | bearer | — | — | The team's members and roles. |
| GET | `/api/admin/status` | bearer | `instance:manage` | — | Instance counts: users, teams, orgs, notes, tokens, audit events, tenants. |
| POST | `/api/orgs` | superadmin | `instance:manage` | — | Create a company: org, first team, owner. An explicit slug is a natural key (409 on re-run). |
| GET | `/api/orgs` | superadmin | `instance:manage` | — | List every org on the instance. |
| POST | `/api/orgs/:ref/suspend` | superadmin | `instance:manage` | — | Suspend a company (id or slug); every team in it becomes read-only. |
| POST | `/api/orgs/:ref/resume` | superadmin | `instance:manage` | — | Resume a suspended company. |
| POST | `/api/orgs/:ref/quota` | superadmin | `instance:manage` | — | Set an org-level quota; teams nest beneath it. |
| GET | `/api/orgs/:ref` | superadmin | `instance:manage` | — | One company, its teams and quotas. |
| PATCH | `/api/orgs/:ref` | superadmin | `instance:manage` | — | Rename a company and/or change its plan (a plan change re-applies the plan's caps). |
| POST | `/api/admin/seed-tenants` | superadmin | `instance:manage` | — | Seed Acme and Globex with known dev passwords — demo fixture only. |
| GET | `/api/org` | org-admin | `org:read` | — | The caller's own company. |
| GET | `/api/org/teams` | org-admin | `org:read` | — | The teams in the caller's company. |
| POST | `/api/org/teams` | org-admin | `org:manage` | — | Create a team in the caller's company. |
| POST | `/api/org/members` | org-admin | `org:manage` | — | Add a person to a team in the caller's company. |
| GET | `/api/org/audit` | org-admin | `org:read` | — | The company's audit trail. |
| POST | `/api/notes` | bearer | `notes:write` | — | Create a note with a visibility. |
| GET | `/api/notes` | bearer | `notes:read` | — | List the notes the caller can read. |
| POST | `/api/documents` | bearer | `files:write` | — | Create a text document (a repository object with content_type text/markdown). |
| GET | `/api/documents` | bearer | `files:read` | — | List text documents. |
| GET | `/api/documents/:id` | bearer | `files:read` | — | One text document with its body. |
| PUT | `/api/documents/:id` | bearer | `files:write` | — | Update a text document's title, body or visibility (a new version). |
| DELETE | `/api/documents/:id` | bearer | `files:delete` | — | Delete a text document. |
| POST | `/api/notes/:id/share` | bearer | `notes:manage` | — | Share a note with a user (owner, or notes:manage). The permission granted must be a notes:* one. |
| GET | `/api/notes/:id` | bearer | `notes:read` | — | One note. |
| PUT | `/api/notes/:id` | bearer | `notes:write` | — | Update a note. |
| DELETE | `/api/notes/:id` | bearer | `notes:delete` | — | Delete a note. |
| POST | `/api/ai/echo` | bearer | `chat:use` | — | A metered no-model echo, for exercising quotas. |
| POST | `/api/ai/chat` | bearer | `chat:use` | `chat` | One model turn. Quota-admitted (ai.requests, ai.tokens.total), governed by the team's ai.concurrency. Routing to a named executor needs instance:manage. |
| POST | `/api/ai/chat/stream` | bearer | `chat:use` | `chat` | The same turn as server-sent events, metered at the end. |
| POST | `/api/agent` | bearer | `chat:use` | `agent` | Run the tool-using agent loop over the team's enabled tools; every tool call is RBAC-checked and metered. |
| POST | `/api/translate/catalog` | bearer | `chat:use` | `translate` | Translate a whole locale catalog, placeholders preserved. |
| POST | `/api/translate` | bearer | `chat:use` | `translate` | Translate text into a target language, applying the team glossary. |
| GET | `/api/translate` | bearer | `chat:use` | — | The team's translation history. |
| POST | `/api/glossary` | bearer | `settings:manage` | — | Add or update a glossary term for a target language. |
| GET | `/api/glossary` | bearer | `chat:use` | — | The team glossary. |
| GET | `/api/ai/model` | bearer | — | — | Which model is configured (or that the simulated fallback is in use). |
| GET | `/api/executors` | bearer | — | — | The local executor and any federated ones. |
| GET | `/api/usage` | bearer | — | — | The team's quota dimensions with used, limit and remaining. |
| POST | `/api/quota` | bearer | `instance:manage` | — | Set a quota limit for the caller's team (dimension, limit, window). |
| GET | `/api/tools` | bearer | — | — | Every registered tool with its permission, source and per-team enabled state. |
| POST | `/api/tokens` | bearer | `settings:manage` | — | Issue an API token, optionally scoped; the raw token is shown once. |
| GET | `/api/tokens` | bearer | `settings:manage` | — | The team's API tokens. |
| DELETE | `/api/tokens/:id` | bearer | `settings:manage` | — | Revoke an API token. |
| GET | `/api/search` | bearer | — | `search` | Search notes, repository objects (key, filename, extracted text) and knowledge-graph entities; every row filtered by can?. |
| GET | `/api/audit` | bearer | `settings:manage` | — | The team's recent audit events. |
| POST | `/api/jobs` | bearer | `chat:use` | — | Enqueue a scheduler job of a registered kind. |
| GET | `/api/jobs` | bearer | — | — | The team's jobs, newest first. |
| POST | `/api/jobs/:id/cancel` | bearer | — | — | Cancel a queued job (a running one finishes). |
| GET | `/api/jobs/:id` | bearer | — | — | One job with its result or error. |
| GET | `/api/repo` | bearer | `files:read` | — | List repository objects by ?prefix=, paged; ?shared=1 lists only what the caller holds a live grant on and does not own. |
| POST | `/api/repo-obj/:id/share` | bearer | `files:manage` | — | Share with a user or a team in the org: {principal_type, principal_id, capability: view\|edit\|manage, expires_at?}. {user_id} still means view. |
| POST | `/api/repo-obj/:id/unshare` | bearer | `files:manage` | — | Revoke every grant a principal holds on the object. |
| GET | `/api/repo-obj/:id/grants` | bearer | `files:manage` | — | One entry per principal: capability, permissions, granted_by, expiry, expired. |
| GET | `/api/repo-obj/:id/derivations` | bearer | `files:read` | — | Provenance: what the document was derived from, by which run and step. |
| GET | `/api/repo-obj/:id/processing` | bearer | `files:read` | — | "Processed by": derived documents, sources, and every run that touched the document. |
| GET | `/api/share-targets` | bearer | `files:read` | — | Who a document can be shared with: the team's people and the org's teams. |
| POST | `/api/repo-obj/:id/visibility` | bearer | `files:manage` | — | Set private, team or shared. |
| GET | `/api/repo-obj/:id/content` | bearer | `files:read` | — | Download the bytes (?version= for history). Attachment + nosniff unless the type is on the inline allowlist. |
| POST | `/api/repo-obj/:id/presign` | bearer | `files:read` | — | A time-boxed presigned S3 URL, signed with the caller's own newest S3 key. |
| GET | `/api/repo-obj/:id` | bearer | `files:read` | — | Object metadata with its versions. |
| DELETE | `/api/repo-obj/:id` | bearer | `files:delete` | — | Delete an object (blobs are released when no other version references them). |
| PUT | `/api/repo/*key` | bearer | `files:write` | — | Upload a raw body to a key (?filename=, ?visibility=); writing an existing key adds a version. Triggers evaluate here. |
| GET | `/api/s3/credentials` | bearer | — | — | The caller's S3 access keys (secrets never shown again) and the endpoint/bucket to use them with. |
| POST | `/api/s3/credentials` | bearer | — | — | Issue an S3 access key, optionally scoped (add workflows:run for a prefix that should fire triggers). |
| DELETE | `/api/s3/credentials/:id` | bearer | — | — | Revoke an S3 access key; presigned links signed with it die with it. |
| POST | `/api/workflows` | bearer | `workflows:write` | `workflows` | Publish a workflow spec (validated; unknown fields refused); re-publishing a slug bumps its version. |
| GET | `/api/workflows` | bearer | `workflows:read` | `workflows` | The team's workflow definitions, plugin-contributed ones materialized on first look. |
| GET | `/api/workflows/schema` | public | — | — | The workflow spec format: version, step kinds, binding references, predicates. |
| POST | `/api/workflows/:slug/run` | bearer | `workflows:run` | `workflows` | Start a run with {input}; declared inputs are required and typed. Returns 202 with the run. |
| GET | `/api/doc-triggers` | bearer | `workflows:read` | `workflows` | The team's upload triggers, with the team's remaining AI budget. |
| POST | `/api/doc-triggers` | bearer | `workflows:write` | `workflows` | Create a trigger: workflow_slug, match_prefix, match_types, input, fire_on_derived. |
| GET | `/api/doc-triggers/:id` | bearer | `workflows:read` | — | One trigger with its fire history (which version, which run, or why not). |
| PATCH | `/api/doc-triggers/:id` | bearer | `workflows:write` | — | Change a trigger's fields; absent fields are left alone. |
| DELETE | `/api/doc-triggers/:id` | bearer | `workflows:write` | — | Delete a trigger and its history; the runs it started remain. |
| GET | `/api/workflows/:slug` | bearer | `workflows:read` | `workflows` | One workflow definition with its spec. |
| GET | `/api/runs` | bearer | `workflows:read` | `workflows` | The team's runs, newest first. |
| POST | `/api/runs/:id/cancel` | bearer | `workflows:run` | `workflows` | Cancel a run; a step already executing finishes, the next never starts. |
| GET | `/api/runs/:id` | bearer | `workflows:read` | `workflows` | One run with its steps, inputs, outputs and errors. |
| GET | `/api/kg/entities` | bearer | `files:read` | — | Find entities by ?q= and ?type=; only those with a mention the caller can read. |
| GET | `/api/kg/entities/:id` | bearer | `files:read` | — | One entity with its relations and mentions, each mention filtered by the source document's visibility. |
| POST | `/api/kg/extract` | bearer | `workflows:run` | `workflows` | Queue the index-knowledge workflow over the team's unextracted documents. |
| POST | `/api/admin/seed` | bearer | `settings:manage` | — | Seed sample notes and documents into the caller's team. |
| GET | `/api/metrics` | bearer | `instance:manage` | — | Operational metrics. |
| GET | `/api/features` | bearer | — | — | The team's feature flags. |
| POST | `/api/features/:name` | bearer | `settings:manage` | — | Enable or disable a feature for the team. |
| GET | `/api/plugins` | bearer | — | — | The loaded plugins with their tools and workflows. |
| GET | `/api/mcp` | bearer | — | — | Connected MCP servers. |
| GET | `/api/oop` | bearer | — | — | Connected sandboxed (out-of-process) plugins and the capabilities they may ask for. |
| POST | `/api/tools/:name` | bearer | `settings:manage` | — | Enable or disable a tool for the team. |

